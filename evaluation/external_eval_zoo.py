#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
external_eval_zoo.py  --  external validation for the model zoo.

Handles BOTH families in one pass:
  * sklearn-style pickles (rf / lightgbm / svm / mlp / logreg / xgboost)
    -> tabular features via summarize_ts, identical to train_baselines.py
  * the plain Transformer (simple_tf) -> sequence input, arch rebuilt from
    model_config.json written at train time

NEVER refits. The external npz already carries MIMIC's locked scaler/imputer.
"""
import argparse
import json
import os

import joblib
import numpy as np

from metrics_v2 import full_report
from train_baselines import summarize_ts

SK_MODELS = ["rf", "lightgbm", "svm", "mlp"]


def tabular(npz_path):
    z = np.load(npz_path)
    Xt = summarize_ts(z["X_ts"], z["mask"])
    X = np.concatenate([Xt, z["X_static"]], axis=1).astype(np.float32)
    X = np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)
    return X, z["y"].astype(int)


def eval_simple_tf(run_dir, npz_path, bs=256):
    import torch
    from torch.utils.data import DataLoader, TensorDataset

    from model_simple_tf import SimpleTransformer

    cfg = json.load(open(os.path.join(run_dir, "model_config.json"),
                         encoding="utf-8"))
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model = SimpleTransformer(**cfg).to(dev)
    model.load_state_dict(torch.load(os.path.join(run_dir, "best.pt"),
                                     map_location=dev))
    model.eval()
    z = np.load(npz_path)
    ds = TensorDataset(
        torch.tensor(z["X_ts"], dtype=torch.float32),
        torch.tensor(z["mask"], dtype=torch.float32),
        torch.tensor(z["X_static"], dtype=torch.float32),
        torch.tensor(z["y"], dtype=torch.float32))
    dl = DataLoader(ds, batch_size=bs, shuffle=False)
    ps, ys = [], []
    with torch.no_grad():
        for xt, m, xs, y in dl:
            lg = model(xt.to(dev), m.to(dev), xs.to(dev))
            ps.append(torch.sigmoid(lg).cpu().numpy())
            ys.append(y.numpy())
    return np.concatenate(ys).astype(int), np.concatenate(ps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zoo", default=None, help="dir with model_<name>.pkl")
    ap.add_argument("--tf_run", default=None, help="simple_tf run dir")
    ap.add_argument("--external", required=True)
    ap.add_argument("--cohort", required=True, choices=["eicu", "sicdb"])
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    out = {"cohort": args.cohort, "external_file": args.external}
    rp = os.path.join(args.outdir, "%s_zoo_report.json" % args.cohort)
    if os.path.exists(rp):
        out = json.load(open(rp, encoding="utf-8"))

    def save(name, y, p):
        rep = full_report(y, p, n_boot=1000, seed=args.seed)
        out[name] = rep
        np.savez(os.path.join(args.outdir, "%s_%s_pred.npz"
                              % (args.cohort, name)), y=y, p=p)
        print("  [%-9s] AUROC=%.4f %s AUPRC=%.3f Brier=%.3f slope=%.2f"
              % (name, rep["auroc"],
                 tuple(round(v, 3) for v in rep["auroc_ci"]),
                 rep["auprc"], rep["brier"], rep["calib_slope"]))
        with open(rp, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)

    if args.zoo:
        X, y = tabular(args.external)
        out["n"] = int(len(y))
        out["n_pos"] = int(y.sum())
        print(">>> [%s] tabular feat dim=%d n=%d AKD+=%d (%.1f%%)"
              % (args.cohort, X.shape[1], len(y), y.sum(), 100 * y.mean()))
        for name in SK_MODELS:
            mp = os.path.join(args.zoo, "model_%s.pkl" % name)
            if not os.path.exists(mp):
                print("  [%-9s] SKIP (no pkl)" % name)
                continue
            save(name, y, joblib.load(mp).predict_proba(X)[:, 1])

    if args.tf_run:
        y, p = eval_simple_tf(args.tf_run, args.external)
        print(">>> [%s] simple_tf n=%d" % (args.cohort, len(y)))
        save("simple_tf", y, p)

    print(">>> report -> %s" % rp)


if __name__ == "__main__":
    main()
