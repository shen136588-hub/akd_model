#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
model_v2.py  —  自包含 Informer-encoder AKD 分类模型 (含静态特征融合 + mask)
Author: 米好 for 朝阳    Date: 2026-07-26

复用 Informer2020 的 ProbAttention / Encoder / ConvLayer, 但:
  * 干净 embedding: TokenEmbedding(Conv1d) + PositionalEmbedding, 去掉 temporal(无需 x_mark)
  * 输入 = [时序特征 F | mask 通道 F] 拼接 → enc_in = 2F (mask 作为显式通道)
  * 序列级 padding mask (来自逐特征 mask 的 any) 用于 attention + masked mean-pool
  * 静态特征 (含 diag PCA) 经 MLP, 与时序 pooled 表征 concat → 分类头
  * 输出单 logit (BCEWithLogitsLoss, 支持 pos_weight)
"""
import os
import sys

import torch
import torch.nn as nn

# 复用 Informer2020 模块
_INF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "informer2020")
if _INF not in sys.path:
    sys.path.insert(0, _INF)
from models.attn import AttentionLayer, ProbAttention, FullAttention  # noqa: E402
from models.encoder import ConvLayer, Encoder, EncoderLayer  # noqa: E402
from models.embed import PositionalEmbedding, TokenEmbedding  # noqa: E402


class TSEncoder(nn.Module):
    """时序编码: token+pos embedding → Informer encoder (ProbAttention)."""

    def __init__(self, enc_in, d_model=256, n_heads=4, e_layers=3, d_ff=512,
                 dropout=0.2, attn="prob", activation="gelu", distil=True):
        super().__init__()
        self.token_emb = TokenEmbedding(enc_in, d_model)
        self.pos_emb = PositionalEmbedding(d_model)
        self.drop = nn.Dropout(dropout)
        Attn = ProbAttention if attn == "prob" else FullAttention
        self.encoder = Encoder(
            [
                EncoderLayer(
                    AttentionLayer(
                        Attn(False, 5, attention_dropout=dropout, output_attention=False),
                        d_model, n_heads, mix=False),
                    d_model, d_ff, dropout=dropout, activation=activation,
                ) for _ in range(e_layers)
            ],
            [ConvLayer(d_model) for _ in range(e_layers - 1)] if distil else None,
            norm_layer=nn.LayerNorm(d_model),
        )
        self.d_model = d_model
        self.distil = distil

    def forward(self, x):
        # x: [B, T, enc_in]
        h = self.drop(self.token_emb(x) + self.pos_emb(x))
        h, _ = self.encoder(h, attn_mask=None)  # [B, T', d_model]  (distil 会缩短 T)
        return h


class AKDNet(nn.Module):
    """Informer-encoder + 静态特征融合 分类器."""

    def __init__(self, n_ts_feat, n_static_feat, d_model=256, n_heads=4,
                 e_layers=3, d_ff=512, dropout=0.2, attn="prob", distil=True,
                 static_hidden=64, head_hidden=128, use_mask_channel=True):
        super().__init__()
        self.use_mask_channel = use_mask_channel
        enc_in = n_ts_feat * 2 if use_mask_channel else n_ts_feat
        self.ts_encoder = TSEncoder(
            enc_in, d_model=d_model, n_heads=n_heads, e_layers=e_layers,
            d_ff=d_ff, dropout=dropout, attn=attn, distil=distil)
        self.static_mlp = nn.Sequential(
            nn.Linear(n_static_feat, static_hidden), nn.ReLU(),
            nn.Dropout(dropout), nn.Linear(static_hidden, static_hidden), nn.ReLU(),
        )
        self.head = nn.Sequential(
            nn.Linear(d_model + static_hidden, head_hidden), nn.ReLU(),
            nn.Dropout(dropout), nn.Linear(head_hidden, 1),
        )

    def forward(self, x_ts, mask, x_static):
        # x_ts:[B,T,F]  mask:[B,T,F] (1=观测)  x_static:[B,S]
        if self.use_mask_channel:
            x = torch.cat([x_ts, mask], dim=-1)  # [B,T,2F]
        else:
            x = x_ts
        h = self.ts_encoder(x)                   # [B,T',d_model]
        pooled = h.mean(dim=1)                   # global avg (distil 后等长, 直接均值)
        s = self.static_mlp(x_static)
        z = torch.cat([pooled, s], dim=-1)
        return self.head(z).squeeze(-1)          # [B]
