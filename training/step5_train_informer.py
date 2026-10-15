#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
train_informer.py  —  AKD Informer-encoder 训练 + 锁定 test 评估
Author: 米好 for 朝阳    Date: 2026-07-26

要点 (对齐 严谨课题重设计.md 3.7/3.8):
  * 类不平衡: BCEWithLogitsLoss(pos_weight=n_neg/n_pos on TRAIN)
  * AMP 混合精度; early-stop 依据 VAL AUPRC (不用 test)
  * test 一次性锁定评估 (加载 best ckpt)
  * 完整 TRIPOD-AI 指标 (metrics_v2.full_report)

用法:
  python train_informer.py --dataset ../dataset_A --outdir runs/informer_A
"""
import argparse
import json
import os

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

from step0_metrics import full_report
from step1_model_informer import AKDNet


def load_split(dataset, split):
    z = np.load(os.path.join(dataset, f"{split}_final.npz"))
    return (torch.tensor(z["X_ts"], dtype=torch.float32),
            torch.tensor(z["mask"], dtype=torch.float32),
            torch.tensor(z["X_static"], dtype=torch.float32),
            torch.tensor(z["y"], dtype=torch.float32))


def make_loader(dataset, split, bs, shuffle):
    xt, m, xs, y = load_split(dataset, split)
    return DataLoader(TensorDataset(xt, m, xs, y), batch_size=bs, shuffle=shuffle)


@torch.no_grad()
def predict(model, loader, device):
    model.eval()
    ps, ys = [], []
    for xt, m, xs, y in loader:
        xt, m, xs = xt.to(device), m.to(device), xs.to(device)
        logit = model(xt, m, xs)
        ps.append(torch.sigmoid(logit).cpu().numpy())
        ys.append(y.numpy())
    return np.concatenate(ys), np.concatenate(ps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--patience", type=int, default=8)
    ap.add_argument("--bs", type=int, default=64)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--wd", type=float, default=1e-4)
    ap.add_argument("--d_model", type=int, default=256)
    ap.add_argument("--n_heads", type=int, default=4)
    ap.add_argument("--e_layers", type=int, default=3)
    ap.add_argument("--d_ff", type=int, default=512)
    ap.add_argument("--dropout", type=float, default=0.2)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--no_mask_channel", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(">>> device", device)

    fmeta = json.load(open(os.path.join(args.dataset, "feature_meta.json"), encoding="utf-8"))
    n_ts = fmeta["n_ts_features"]
    n_static = fmeta["n_static_features_final"]
    print(f">>> n_ts={n_ts}, n_static={n_static}, T={fmeta['n_grid']}")

    tr = make_loader(args.dataset, "train", args.bs, True)
    va = make_loader(args.dataset, "val", args.bs, False)
    te = make_loader(args.dataset, "test", args.bs, False)

    # pos_weight from train
    _, _, _, ytr = load_split(args.dataset, "train")
    n_pos = float(ytr.sum())
    n_neg = float(len(ytr) - n_pos)
    pos_weight = torch.tensor([n_neg / n_pos], device=device)
    print(f">>> pos_weight={pos_weight.item():.3f} (neg={int(n_neg)}, pos={int(n_pos)})")

    model = AKDNet(
        n_ts_feat=n_ts, n_static_feat=n_static, d_model=args.d_model,
        n_heads=args.n_heads, e_layers=args.e_layers, d_ff=args.d_ff,
        dropout=args.dropout, use_mask_channel=not args.no_mask_channel,
    ).to(device)
    n_param = sum(p.numel() for p in model.parameters())
    print(f">>> model params: {n_param/1e6:.2f}M")

    # B3 FIX (2026-08-03): persist the architecture next to best.pt so that
    # external_eval.py can rebuild the exact same network instead of assuming
    # hardcoded defaults. Without this, any non-default arch (e.g. from
    # tune_informer.py) silently could not be externally validated.
    model_cfg = dict(
        d_model=args.d_model, n_heads=args.n_heads, e_layers=args.e_layers,
        d_ff=args.d_ff, dropout=args.dropout,
        use_mask_channel=not args.no_mask_channel,
        n_ts_feat=n_ts, n_static_feat=n_static, n_param=int(n_param),
        source="train_informer.py",
    )
    with open(os.path.join(args.outdir, "model_config.json"), "w",
              encoding="utf-8") as f:
        json.dump(model_cfg, f, ensure_ascii=False, indent=2)
    print(">>> model_config.json written (consumed by external_eval.py)")

    crit = nn.BCEWithLogitsLoss(pos_weight=pos_weight)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.wd)
    sched = torch.optim.lr_scheduler.ReduceLROnPlateau(opt, mode="max", factor=0.5, patience=3)
    scaler = torch.cuda.amp.GradScaler(enabled=(device.type == "cuda"))

    best_auprc, best_ep, bad = -1.0, -1, 0
    ckpt = os.path.join(args.outdir, "best.pt")
    for ep in range(1, args.epochs + 1):
        model.train()
        tot = 0.0
        for xt, m, xs, y in tr:
            xt, m, xs, y = xt.to(device), m.to(device), xs.to(device), y.to(device)
            opt.zero_grad()
            with torch.cuda.amp.autocast(enabled=(device.type == "cuda")):
                logit = model(xt, m, xs)
                loss = crit(logit, y)
            scaler.scale(loss).backward()
            scaler.unscale_(opt)
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            scaler.step(opt)
            scaler.update()
            tot += loss.item() * len(y)
        yv, pv = predict(model, va, device)
        from sklearn.metrics import average_precision_score, roc_auc_score
        va_auprc = average_precision_score(yv, pv)
        va_auroc = roc_auc_score(yv, pv)
        sched.step(va_auprc)
        print(f"  ep{ep:02d} loss={tot/len(ytr):.4f} val_auprc={va_auprc:.4f} val_auroc={va_auroc:.4f}")
        if va_auprc > best_auprc:
            best_auprc, best_ep, bad = va_auprc, ep, 0
            torch.save(model.state_dict(), ckpt)
        else:
            bad += 1
            if bad >= args.patience:
                print(f"  early stop @ep{ep} (best ep{best_ep} auprc={best_auprc:.4f})")
                break

    # ---- 锁定 test 评估 ----
    print(">>> load best, evaluate VAL + TEST")
    model.load_state_dict(torch.load(ckpt, map_location=device))
    out = {}
    for name, loader in [("val", va), ("test", te)]:
        y, p = predict(model, loader, device)
        rep = full_report(y, p, n_boot=1000, seed=args.seed)
        out[name] = rep
        np.savez(os.path.join(args.outdir, f"pred_{name}.npz"), y=y, p=p)
        print(f"  [{name}] AUROC={rep['auroc']:.3f} {rep['auroc_ci']} "
              f"AUPRC={rep['auprc']:.3f} Brier={rep['brier']:.3f} "
              f"slope={rep['calib_slope']:.2f}")
    out["config"] = vars(args)
    out["best_epoch"] = best_ep
    out["val_best_auprc"] = best_auprc
    with open(os.path.join(args.outdir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(">>> done. report →", os.path.join(args.outdir, "report.json"))


if __name__ == "__main__":
    main()
