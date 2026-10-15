#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
external_eval_baselines.py  —  external validation of locked LR/XGB baselines
Author: mihao for zhaoyang    Date: 2026-07-29

Loads locked MIMIC baseline models (model_logreg.pkl / model_xgboost.pkl) and
runs inference on external npz (eICU/SICdb) using the SAME feature construction
(summarize_ts + static concat) as train_baselines.py. NEVER refits.

The external npz was produced by 03b_external_transform.py with the SAME MIMIC
scaler/imputer, so feature scale is aligned; the summary-stat feature order is
identical (40 ts feats x 7 stats + 43 static = 323).

Usage:
  python external_eval_baselines.py --models runs/baseline_A \
      --external ../../eicu/feature_pipeline_v2/dataset_A_ext/external_final_nodiag.npz \
      --cohort eicu --outdir results/external_nodiag
"""
import argparse
import json
import os

import joblib
import numpy as np

from metrics_v2 import full_report
from train_baselines import summarize_ts


def build_features(npz_path):
    z = np.load(npz_path)
    Xt = summarize_ts(z["X_ts"], z["mask"])
    X = np.concatenate([Xt, z["X_static"]], axis=1).astype(np.float32)
    return X, z["y"].astype(int)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True, help="dir with model_logreg.pkl/model_xgboost.pkl")
    ap.add_argument("--external", required=True)
    ap.add_argument("--cohort", required=True, choices=["eicu", "sicdb"])
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    X, y = build_features(args.external)
    print(f">>> [{args.cohort}] feat dim={X.shape[1]}, n={len(y)}, AKD+={int(y.sum())} ({y.mean():.1%})")

    out = {"cohort": args.cohort, "external_file": args.external,
           "n": int(len(y)), "n_pos": int(y.sum())}
    for name in ["logreg", "xgboost"]:
        mpath = os.path.join(args.models, f"model_{name}.pkl")
        model = joblib.load(mpath)
        p = model.predict_proba(X)[:, 1]
        rep = full_report(y, p, n_boot=1000, seed=args.seed)
        out[name] = rep
        np.savez(os.path.join(args.outdir, f"{args.cohort}_{name}_pred.npz"), y=y, p=p)
        print(f"  [{name:8s}] AUROC={rep['auroc']:.3f} {tuple(round(v,3) for v in rep['auroc_ci'])} "
              f"AUPRC={rep['auprc']:.3f} Brier={rep['brier']:.3f} slope={rep['calib_slope']:.2f}")

    rp = os.path.join(args.outdir, f"{args.cohort}_baseline_report.json")
    with open(rp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(">>> report ->", rp)


if __name__ == "__main__":
    main()