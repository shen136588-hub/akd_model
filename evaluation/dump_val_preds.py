#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
dump_val_preds.py  --  emit MIMIC val predictions for every locked model.

Needed for honest ("deployment") recalibration: the calibrator must be fitted
on data that is neither the training set nor the external cohort. MIMIC val is
the only such split. train_baselines.py / train_zoo.py only persisted test
predictions, so we regenerate val predictions from the LOCKED artefacts
(pkl / best.pt) -- no refitting, so this cannot change any reported metric.
"""
import argparse
import os

import joblib
import numpy as np

from train_baselines import load as tab_load


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--split", default="val")
    ap.add_argument("--suffix", default="",
                    help="run-dir suffix, e.g. _pri for the retrained models")
    args = ap.parse_args()

    X, y = tab_load(args.dataset, args.split)
    X = np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)
    print(">>> %s: X=%s  y=%d  prev=%.3f"
          % (args.split, X.shape, len(y), y.mean()))

    sfx = args.suffix
    jobs = [("runs/baseline_B" + sfx, "logreg"),
            ("runs/baseline_B" + sfx, "xgboost"),
            ("runs/zoo_B" + sfx, "rf"),
            ("runs/zoo_B" + sfx, "lightgbm"),
            ("runs/zoo_B" + sfx, "svm"),
            ("runs/zoo_B" + sfx, "mlp")]
    for d, name in jobs:
        mp = os.path.join(d, "model_%s.pkl" % name)
        if not os.path.exists(mp):
            print("  skip %s (missing)" % name)
            continue
        p = joblib.load(mp).predict_proba(X)[:, 1]
        out = os.path.join(d, "pred_%s_%s.npz" % (name, args.split))
        np.savez(out, y=y, p=p)
        print("  [%-9s] -> %s   mean_p=%.3f" % (name, out, p.mean()))

    # simple transformer
    import json

    import torch
    from torch.utils.data import DataLoader, TensorDataset

    from model_simple_tf import SimpleTransformer
    rd = "runs/simple_tf_B" + sfx
    cfg = json.load(open(os.path.join(rd, "model_config.json"),
                         encoding="utf-8"))
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model = SimpleTransformer(**cfg).to(dev)
    model.load_state_dict(torch.load(os.path.join(rd, "best.pt"),
                                     map_location=dev))
    model.eval()
    z = np.load(os.path.join(args.dataset, "%s_final.npz" % args.split))
    dl = DataLoader(TensorDataset(
        torch.tensor(z["X_ts"], dtype=torch.float32),
        torch.tensor(z["mask"], dtype=torch.float32),
        torch.tensor(z["X_static"], dtype=torch.float32),
        torch.tensor(z["y"], dtype=torch.float32)), batch_size=256)
    ps, ys = [], []
    with torch.no_grad():
        for xt, m, xs, yy in dl:
            ps.append(torch.sigmoid(
                model(xt.to(dev), m.to(dev), xs.to(dev))).cpu().numpy())
            ys.append(yy.numpy())
    p = np.concatenate(ps)
    yv = np.concatenate(ys).astype(int)
    out = os.path.join(rd, "pred_simple_tf_%s.npz" % args.split)
    np.savez(out, y=yv, p=p)
    print("  [simple_tf] -> %s   mean_p=%.3f" % (out, p.mean()))
    assert np.array_equal(yv, y.astype(int)), "val label order mismatch!"
    print(">>> label order consistent across tabular and sequence loaders")


if __name__ == "__main__":
    main()
