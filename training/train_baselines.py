#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
train_baselines.py  —  对照模型 (LR / XGBoost), 证明 Transformer 增益
Author: 米好 for 朝阳    Date: 2026-07-26

特征: 时序做摘要统计 (mean/std/min/max/last/slope) 展平 + 静态特征 concat → 表格模型.
      与 Informer 用同一 split, 同一 test 锁定评估.

用法:
  python train_baselines.py --dataset ../feature_pipeline_v2/dataset_A --outdir runs/baseline_A
"""
import argparse
import json
import os

import joblib
import numpy as np
from sklearn.linear_model import LogisticRegression
from xgboost import XGBClassifier

from metrics_v2 import full_report


def summarize_ts(X_ts, mask):
    # X_ts:[N,T,F]  →  统计量展平 [N, F*6]
    N, T, F = X_ts.shape
    feats = []
    feats.append(X_ts.mean(axis=1))
    feats.append(X_ts.std(axis=1))
    feats.append(X_ts.min(axis=1))
    feats.append(X_ts.max(axis=1))
    feats.append(X_ts[:, -1, :])                       # last step
    # slope: 末 - 首
    feats.append(X_ts[:, -1, :] - X_ts[:, 0, :])
    # 观测计数 (mask 均值)
    feats.append(mask.mean(axis=1))
    return np.concatenate(feats, axis=1)


def load(dataset, split):
    z = np.load(os.path.join(dataset, f"{split}_final.npz"))
    Xt = summarize_ts(z["X_ts"], z["mask"])
    X = np.concatenate([Xt, z["X_static"]], axis=1)
    return X.astype(np.float32), z["y"].astype(int)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    Xtr, ytr = load(args.dataset, "train")
    Xva, yva = load(args.dataset, "val")
    Xte, yte = load(args.dataset, "test")
    # LR 用 train+val 拟合 (无需早停); XGB 用 val 早停
    print(f">>> feat dim={Xtr.shape[1]}, train={len(ytr)} val={len(yva)} test={len(yte)}")

    n_pos = ytr.sum()
    n_neg = len(ytr) - n_pos
    spw = n_neg / n_pos

    out = {}

    # ---- Logistic Regression ----
    Xtrv = np.concatenate([Xtr, Xva]); ytrv = np.concatenate([ytr, yva])
    lr = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
    lr.fit(Xtrv, ytrv)
    p_te = lr.predict_proba(Xte)[:, 1]
    out["logreg"] = full_report(yte, p_te, n_boot=1000, seed=args.seed)
    np.savez(os.path.join(args.outdir, "pred_logreg_test.npz"), y=yte, p=p_te)
    joblib.dump(lr, os.path.join(args.outdir, "model_logreg.pkl"))
    print(f"  [LR  test] AUROC={out['logreg']['auroc']:.3f} AUPRC={out['logreg']['auprc']:.3f} "
          f"Brier={out['logreg']['brier']:.3f}")

    # ---- XGBoost ----
    xgb = XGBClassifier(
        n_estimators=400, max_depth=4, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8, min_child_weight=5,
        reg_lambda=1.0, scale_pos_weight=spw, eval_metric="aucpr",
        early_stopping_rounds=30, tree_method="hist", random_state=args.seed,
    )
    xgb.fit(Xtr, ytr, eval_set=[(Xva, yva)], verbose=False)
    p_te = xgb.predict_proba(Xte)[:, 1]
    out["xgboost"] = full_report(yte, p_te, n_boot=1000, seed=args.seed)
    np.savez(os.path.join(args.outdir, "pred_xgboost_test.npz"), y=yte, p=p_te)
    joblib.dump(xgb, os.path.join(args.outdir, "model_xgboost.pkl"))
    print(f"  [XGB test] AUROC={out['xgboost']['auroc']:.3f} AUPRC={out['xgboost']['auprc']:.3f} "
          f"Brier={out['xgboost']['brier']:.3f} best_iter={xgb.best_iteration}")

    with open(os.path.join(args.outdir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(">>> done →", os.path.join(args.outdir, "report.json"))


if __name__ == "__main__":
    main()
