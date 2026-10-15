#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
model_simple_tf.py  --  a deliberately PLAIN Transformer encoder for AKD.

Why not Informer: our sequence is only 25 (plan A) / 37 (plan B) steps.
Informer's ProbSparse attention + distilling exist to tame O(L^2) at L in the
hundreds-to-thousands range; at L=37 they add machinery without buying anything,
and they make the "why did the deep model behave this way" story harder to tell.
So the comparator here is a textbook post-LN Transformer encoder:

  value+mask embedding -> learned positional encoding -> N x TransformerEncoder
  -> masked mean pooling -> concat static -> MLP head -> logit

Kept intentionally small (d_model=64, 2 layers, 4 heads) because n_train=6278.
"""
import torch
import torch.nn as nn


class SimpleTransformer(nn.Module):
    def __init__(self, n_ts, n_static, d_model=64, nhead=4, num_layers=2,
                 dim_ff=128, dropout=0.1, max_len=64):
        super().__init__()
        self.n_ts = n_ts
        # value projection + a parallel mask projection: missingness is signal
        self.val_proj = nn.Linear(n_ts, d_model)
        self.mask_proj = nn.Linear(n_ts, d_model)
        self.pos = nn.Parameter(torch.zeros(1, max_len, d_model))
        nn.init.trunc_normal_(self.pos, std=0.02)
        enc = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=nhead, dim_feedforward=dim_ff,
            dropout=dropout, batch_first=True, norm_first=False)
        self.enc = nn.TransformerEncoder(enc, num_layers=num_layers)
        self.norm = nn.LayerNorm(d_model)
        self.head = nn.Sequential(
            nn.Linear(d_model + n_static, 64),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(64, 1),
        )

    def forward(self, x_ts, mask, x_static):
        # x_ts:[B,T,F]  mask:[B,T,F] (1=observed)  x_static:[B,S]
        h = self.val_proj(x_ts) + self.mask_proj(mask)
        h = h + self.pos[:, : h.size(1), :]
        step_obs = mask.amax(dim=2)                     # [B,T] 1 if any obs
        pad = step_obs < 0.5
        # a fully-padded row would make softmax produce NaN -> keep step 0 alive
        pad[:, 0] = False
        h = self.enc(h, src_key_padding_mask=pad)
        h = self.norm(h)
        w = (~pad).float().unsqueeze(-1)
        pooled = (h * w).sum(dim=1) / w.sum(dim=1).clamp(min=1.0)
        return self.head(torch.cat([pooled, x_static], dim=1)).squeeze(-1)


def count_params(m):
    return sum(p.numel() for p in m.parameters() if p.requires_grad)
