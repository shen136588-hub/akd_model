#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
train_zoo.py  --  model zoo for the AKD prediction comparison (tier1, Plan B)
Author: mihao for zhaoyang    Date: 2026-08-11

Adds RF / LightGBM / SVM / MLP to the existing LR + XGBoost baselines.
Design constraints (so the comparison is honest):
  * SAME split, SAME features, SAME seed as train_baselines.py
    (imports summarize_ts + load from it -- single source of truth)
  * scale-sensitive models (SVM, MLP) carry their OWN StandardScaler INSIDE an
    sklearn Pipeline, so external validation applies the identical transform
    and never refits anything.
  * every model is persisted as model_<name>.pkl with a predict_proba API,
    which is exactly what external_eval_zoo.py expects.

Usage:
  python train_zoo.py --dataset ../feature_pipeline_v2/dataset_B --outdir runs/zoo_B
"""
import argparse
import json
import os
import time

import joblib
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.neural_network import MLPClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from metrics_v2 import full_report
from train_baselines import load


def clean(X):
    """guard against inf / NaN leaking into scale-sensitive models"""
    return np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip", default="", help="comma list to skip, e.g. svm")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    skip = {s.strip() for s in args.skip.split(",") if s.strip()}

    Xtr, ytr = load(args.dataset, "train")
    Xva, yva = load(args.dataset, "val")
    Xte, yte = load(args.dataset, "test")
    Xtr, Xva, Xte = clean(Xtr), clean(Xva), clean(Xte)

    n_pos = int(ytr.sum())
    spw = (len(ytr) - n_pos) / n_pos
    print(">>> feat dim=%d  train=%d val=%d test=%d  spw=%.3f"
          % (Xtr.shape[1], len(ytr), len(yva), len(yte), spw))

    # train+val for models that need no early stopping
    Xtrv = np.concatenate([Xtr, Xva])
    ytrv = np.concatenate([ytr, yva])

    out = {}
    if os.path.exists(os.path.join(args.outdir, "report.json")):
        out = json.load(open(os.path.join(args.outdir, "report.json"),
                             encoding="utf-8"))

    def record(name, model, p_te, extra=""):
        rep = full_report(yte, p_te, n_boot=1000, seed=args.seed)
        out[name] = rep
        np.savez(os.path.join(args.outdir, "pred_%s_test.npz" % name),
                 y=yte, p=p_te)
        joblib.dump(model, os.path.join(args.outdir, "model_%s.pkl" % name))
        print("  [%-9s] AUROC=%.4f %s AUPRC=%.3f Brier=%.3f slope=%.2f %s"
              % (name, rep["auroc"],
                 tuple(round(v, 3) for v in rep["auroc_ci"]),
                 rep["auprc"], rep["brier"], rep["calib_slope"], extra))
        with open(os.path.join(args.outdir, "report.json"), "w",
                  encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)

    # ---------------- Random Forest ----------------
    if "rf" not in skip:
        t = time.time()
        rf = RandomForestClassifier(
            n_estimators=600, max_depth=None, min_samples_leaf=5,
            max_features="sqrt", class_weight="balanced_subsample",
            n_jobs=-1, random_state=args.seed)
        rf.fit(Xtrv, ytrv)
        record("rf", rf, rf.predict_proba(Xte)[:, 1],
               "(%.0fs)" % (time.time() - t))

    # ---------------- LightGBM ----------------
    if "lightgbm" not in skip:
        import lightgbm as lgb
        t = time.time()
        lg = lgb.LGBMClassifier(
            n_estimators=2000, learning_rate=0.05, num_leaves=31,
            max_depth=-1, min_child_samples=20, subsample=0.8,
            subsample_freq=1, colsample_bytree=0.8, reg_lambda=1.0,
            scale_pos_weight=spw, random_state=args.seed, n_jobs=-1,
            verbose=-1)
        lg.fit(Xtr, ytr, eval_set=[(Xva, yva)], eval_metric="average_precision",
               callbacks=[lgb.early_stopping(50, verbose=False),
                          lgb.log_evaluation(0)])
        record("lightgbm", lg, lg.predict_proba(Xte)[:, 1],
               "best_iter=%s (%.0fs)" % (lg.best_iteration_, time.time() - t))

    # ---------------- SVM (RBF, scaled, probability) ----------------
    if "svm" not in skip:
        t = time.time()
        sv = Pipeline([
            ("sc", StandardScaler()),
            ("svc", SVC(C=1.0, kernel="rbf", gamma="scale",
                        class_weight="balanced", probability=True,
                        random_state=args.seed)),
        ])
        sv.fit(Xtrv, ytrv)
        record("svm", sv, sv.predict_proba(Xte)[:, 1],
               "(%.0fs)" % (time.time() - t))

    # ---------------- MLP ----------------
    if "mlp" not in skip:
        t = time.time()
        ml = Pipeline([
            ("sc", StandardScaler()),
            ("mlp", MLPClassifier(
                hidden_layer_sizes=(256, 64), activation="relu",
                alpha=1e-3, batch_size=256, learning_rate_init=1e-3,
                max_iter=300, early_stopping=True, n_iter_no_change=20,
                validation_fraction=0.15, random_state=args.seed)),
        ])
        ml.fit(Xtrv, ytrv)
        record("mlp", ml, ml.predict_proba(Xte)[:, 1],
               "iters=%d (%.0fs)"
               % (ml.named_steps["mlp"].n_iter_, time.time() - t))

    print(">>> done -> %s" % os.path.join(args.outdir, "report.json"))
    print(">>> models: %s" % ", ".join(sorted(out.keys())))


if __name__ == "__main__":
    main()
