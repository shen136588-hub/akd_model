#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
train_simple_tf.py  --  train the plain Transformer encoder (tier1, Plan B).

Mirrors train_informer.py's contract so downstream tooling just works:
  * same dataset dir / same split / same seed
  * writes best.pt + model_config.json (so external_eval can rebuild the arch)
  * early stopping on val AUPRC
"""
import argparse
import json
import os

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

from step0_metrics import full_report
from step2_model_transformer import SimpleTransformer, count_params


def load(dataset, split):
    z = np.load(os.path.join(dataset, "%s_final.npz" % split))
    return (torch.tensor(z["X_ts"], dtype=torch.float32),
            torch.tensor(z["mask"], dtype=torch.float32),
            torch.tensor(z["X_static"], dtype=torch.float32),
            torch.tensor(z["y"], dtype=torch.float32))


@torch.no_grad()
def predict(model, dl, dev):
    model.eval()
    ps, ys = [], []
    for xt, m, xs, y in dl:
        lg = model(xt.to(dev), m.to(dev), xs.to(dev))
        ps.append(torch.sigmoid(lg).cpu().numpy())
        ys.append(y.numpy())
    return np.concatenate(ys).astype(int), np.concatenate(ps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--bs", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--d_model", type=int, default=64)
    ap.add_argument("--nhead", type=int, default=4)
    ap.add_argument("--layers", type=int, default=2)
    ap.add_argument("--dim_ff", type=int, default=128)
    ap.add_argument("--dropout", type=float, default=0.1)
    ap.add_argument("--patience", type=int, default=12)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    dev = "cuda" if torch.cuda.is_available() else "cpu"

    tr = load(args.dataset, "train")
    va = load(args.dataset, "val")
    te = load(args.dataset, "test")
    n_ts = tr[0].shape[2]
    n_static = tr[2].shape[1]
    T = tr[0].shape[1]
    print(">>> device=%s  n_ts=%d n_static=%d T=%d" % (dev, n_ts, n_static, T))

    dl_tr = DataLoader(TensorDataset(*tr), batch_size=args.bs, shuffle=True,
                       drop_last=False)
    dl_va = DataLoader(TensorDataset(*va), batch_size=256, shuffle=False)
    dl_te = DataLoader(TensorDataset(*te), batch_size=256, shuffle=False)

    cfg = dict(n_ts=n_ts, n_static=n_static, d_model=args.d_model,
               nhead=args.nhead, num_layers=args.layers, dim_ff=args.dim_ff,
               dropout=args.dropout, max_len=max(64, T))
    model = SimpleTransformer(**cfg).to(dev)
    print(">>> params: %.3fM" % (count_params(model) / 1e6))
    with open(os.path.join(args.outdir, "model_config.json"), "w",
              encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

    ytr = tr[3].numpy()
    spw = float((len(ytr) - ytr.sum()) / ytr.sum())
    lossf = nn.BCEWithLogitsLoss(
        pos_weight=torch.tensor(spw, device=dev))
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-2)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    best, bad, hist = -1.0, 0, []
    ck = os.path.join(args.outdir, "best.pt")
    for ep in range(1, args.epochs + 1):
        model.train()
        tot = 0.0
        for xt, m, xs, y in dl_tr:
            opt.zero_grad()
            lg = model(xt.to(dev), m.to(dev), xs.to(dev))
            loss = lossf(lg, y.to(dev))
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            tot += float(loss) * len(y)
        sched.step()
        yv, pv = predict(model, dl_va, dev)
        rv = full_report(yv, pv, n_boot=0, seed=args.seed)
        hist.append(dict(epoch=ep, loss=tot / len(ytr),
                         val_auroc=rv["auroc"], val_auprc=rv["auprc"]))
        star = ""
        if rv["auprc"] > best:
            best, bad = rv["auprc"], 0
            torch.save(model.state_dict(), ck)
            star = "  *saved"
        else:
            bad += 1
        print("  ep%03d loss=%.4f val_auroc=%.4f val_auprc=%.4f%s"
              % (ep, tot / len(ytr), rv["auroc"], rv["auprc"], star))
        if bad >= args.patience:
            print("  early stop at epoch %d" % ep)
            break

    model.load_state_dict(torch.load(ck, map_location=dev))
    yt, pt = predict(model, dl_te, dev)
    rep = full_report(yt, pt, n_boot=1000, seed=args.seed)
    np.savez(os.path.join(args.outdir, "pred_simple_tf_test.npz"), y=yt, p=pt)
    with open(os.path.join(args.outdir, "report.json"), "w",
              encoding="utf-8") as f:
        json.dump({"test": rep, "val_best_auprc": best, "history": hist,
                   "config": cfg}, f, ensure_ascii=False, indent=2)
    print(">>> TEST AUROC=%.4f %s AUPRC=%.3f Brier=%.3f slope=%.2f"
          % (rep["auroc"], tuple(round(v, 3) for v in rep["auroc_ci"]),
             rep["auprc"], rep["brier"], rep["calib_slope"]))


if __name__ == "__main__":
    main()
