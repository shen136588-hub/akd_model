#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
external_eval.py  —  TRIPOD-AI external validation of locked MIMIC Informer ckpt
Author: mihao for zhaoyang    Date: 2026-07-29

Loads the locked MIMIC best.pt + feature_meta, runs inference on external
npz (eICU / SICdb), full TRIPOD-AI metrics (AUROC, AUPRC, Brier, calibration,
DCA). Outputs report.json per cohort.

Usage:
  python external_eval.py --ckpt runs/informer_A/best.pt --dataset ../dataset_A \
      --external ../../eicu/feature_pipeline_v2/dataset_A_ext/external_final_nodiag.npz \
      --cohort eicu --outdir ../results/external_nodiag
"""
import argparse
import json
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "training"))

import numpy as np
import torch
from torch.utils.data import DataLoader, TensorDataset

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from step0_metrics import full_report
from step1_model_informer import AKDNet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True, help="MIMIC best.pt path")
    ap.add_argument("--dataset", required=True, help="MIMIC dataset_A dir (for feature_meta)")
    ap.add_argument("--external", required=True, help="external npz file")
    ap.add_argument("--cohort", required=True, choices=["eicu", "sicdb"])
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--bs", type=int, default=128)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--arch_config", default=None,
                    help="JSON with AKDNet kwargs (d_model/n_heads/e_layers/d_ff/"
                         "dropout/attn/distil). Default: look for model_config.json "
                         "next to --ckpt, else fall back to train_informer.py defaults.")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f">>> [{args.cohort}] device={device}")

    # ---- load locked model config ----
    fmeta = json.load(open(os.path.join(args.dataset, "feature_meta.json"), encoding="utf-8"))
    n_ts = fmeta["n_ts_features"]
    n_static = fmeta["n_static_features_final"]
    print(f"    n_ts={n_ts}, n_static={n_static}, T={fmeta['n_grid']}")

    # ---- resolve architecture (B3 FIX, 2026-08-03) ----
    # Previously the arch was hardcoded to train_informer.py's defaults, so any
    # checkpoint produced by tune_informer.py (which searches d_model 128-512,
    # e_layers 2-4, n_heads 4/8, attn prob/full, distil) would fail to load with
    # a shape mismatch -- runs/informer_tuned was effectively un-evaluatable.
    # Resolution order: --arch_config > model_config.json beside ckpt > defaults.
    ARCH_DEFAULTS = dict(d_model=256, n_heads=4, e_layers=3, d_ff=512,
                         dropout=0.2, use_mask_channel=True)
    arch = dict(ARCH_DEFAULTS)
    cfg_path = args.arch_config or os.path.join(
        os.path.dirname(os.path.abspath(args.ckpt)), "model_config.json")
    if os.path.exists(cfg_path):
        raw = json.load(open(cfg_path, encoding="utf-8"))
        picked = {k: v for k, v in raw.items()
                  if k in ("d_model", "n_heads", "e_layers", "d_ff", "dropout",
                           "attn", "distil", "use_mask_channel")}
        arch.update(picked)
        print(f"    arch <- {cfg_path}: {picked}")
    else:
        print(f"    arch <- defaults (no model_config.json at {cfg_path})")

    model = AKDNet(n_ts_feat=n_ts, n_static_feat=n_static, **arch).to(device)
    try:
        model.load_state_dict(torch.load(args.ckpt, map_location=device))
    except RuntimeError as e:
        raise SystemExit(
            f"\n!!! state_dict mismatch loading {args.ckpt}\n"
            f"    arch used: {arch}\n"
            f"    If this ckpt came from tune_informer.py, pass its tuned\n"
            f"    hyperparameters via --arch_config <config.json>.\n"
            f"    Original error: {e}\n")
    model.eval()
    n_param = sum(p.numel() for p in model.parameters())
    print(f"    model params: {n_param/1e6:.2f}M, ckpt loaded from {args.ckpt}")

    # ---- load external data ----
    ext = np.load(args.external)
    xt = torch.tensor(ext["X_ts"], dtype=torch.float32)
    m = torch.tensor(ext["mask"], dtype=torch.float32)
    xs = torch.tensor(ext["X_static"], dtype=torch.float32)
    y = torch.tensor(ext["y"], dtype=torch.float32)
    dl = DataLoader(TensorDataset(xt, m, xs, y), batch_size=args.bs, shuffle=False)
    print(f"    loaded {args.external}: X_ts={xt.shape}, X_static={xs.shape}, "
          f"AKD+={int(y.sum())}/{len(y)} ({y.mean():.1%})")

    # ---- inference ----
    ps, ys = [], []
    with torch.no_grad():
        for bxt, bm, bxs, by in dl:
            bxt, bm, bxs = bxt.to(device), bm.to(device), bxs.to(device)
            logit = model(bxt, bm, bxs)
            ps.append(torch.sigmoid(logit).cpu().numpy())
            ys.append(by.numpy())
    y_pred = np.concatenate(ys)
    p_pred = np.concatenate(ps)
    print(f"    inference done, n={len(y_pred)}, AKD+={int(y_pred.sum())}/{len(y_pred)}")

    # ---- TRIPOD-AI metrics ----
    rep = full_report(y_pred, p_pred, n_boot=1000, seed=args.seed)
    out = {
        "cohort": args.cohort,
        "ckpt": args.ckpt,
        "external_file": args.external,
        "diag_mode": "nodiag" if "nodiag" in args.external else "diag",
        "n": int(len(y_pred)),
        "n_pos": int(y_pred.sum()),
        **rep,
    }
    report_path = os.path.join(args.outdir, f"{args.cohort}_report.json")
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    # also save predictions
    np.savez(os.path.join(args.outdir, f"{args.cohort}_pred.npz"), y=y_pred, p=p_pred)
    print(f">>> [{args.cohort}] AUROC={rep['auroc']:.3f} {rep['auroc_ci']} "
          f"AUPRC={rep['auprc']:.3f} Brier={rep['brier']:.3f} "
          f"slope={rep['calib_slope']:.2f}")
    print(f"    report -> {report_path}")


if __name__ == "__main__":
    main()