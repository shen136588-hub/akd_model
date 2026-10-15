#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
shap_sensitivity.py  --  isolate the diag-block artefact and verify SHAP.

Why this exists
---------------
The main analysis (external validation, Plan B / no_diag) feeds the external
cohorts a diag PCA block that is IDENTICALLY ZERO by construction
(03b_external_transform.py --no_diag). A constant column can never move a
prediction, so its SHAP is structurally near zero externally. Comparing
diag_pca_* importance across cohorts is therefore meaningless, and the raw
"share of total" percentages are NOT comparable between MIMIC and external.

This script:
  1. verifies the zero-block claim numerically
  2. recomputes the importance ranking on the 284 NON-diag columns only,
     renormalised, which IS comparable across cohorts
  3. runs the same SHAP on the full_diag external npz, where the diag block
     carries real values, as a positive control
  4. checks SHAP additivity against the model's own margin output
Usage:
  python shap_sensitivity.py --dataset ../feature_pipeline_v2/dataset_B \
      --model runs/baseline_B/model_xgboost.pkl \
      --shapdir results/shap_xgb_B_tier1 \
      --eicu_diag <...> --sicdb_diag <...>
"""
import argparse
import json
import os

import joblib
import numpy as np
import pandas as pd
from scipy.stats import spearmanr

from shap_xgb import build_names, load_external


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--model", default="runs/baseline_B/model_xgboost.pkl")
    ap.add_argument("--shapdir", required=True)
    ap.add_argument("--eicu_diag", default=None)
    ap.add_argument("--sicdb_diag", default=None)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    import shap

    meta = json.load(open(os.path.join(args.dataset, "feature_meta.json"),
                          encoding="utf-8"))
    names, ts_cols, st_cols = build_names(meta)
    names = np.asarray(names)
    is_diag = np.asarray([n.startswith("diag_pca_") for n in names])
    print(">>> columns total=%d  diag=%d  non-diag=%d"
          % (len(names), is_diag.sum(), (~is_diag).sum()))

    model = joblib.load(args.model)
    out = {}

    # ---- 1. verify the zero-block claim + SHAP mass on diag ----
    zb = {}
    for c in ["mimic_test", "eicu", "sicdb"]:
        f = os.path.join(args.shapdir, "shap_values_%s.npz" % c)
        z = np.load(f)
        X, sv = z["X"], z["shap"]
        Xd = X[:, is_diag]
        zb[c] = {
            "n": int(X.shape[0]),
            "diag_block_all_zero": bool(np.all(Xd == 0)),
            "diag_block_absmax": float(np.abs(Xd).max()),
            "diag_shap_absmax": float(np.abs(sv[:, is_diag]).max()),
            "diag_share_of_mean_abs_shap_pct": float(
                100 * np.abs(sv[:, is_diag]).mean(0).sum()
                / np.abs(sv).mean(0).sum()),
        }
        print("  [%-10s] all_zero=%s  X absmax=%.4g  SHAP absmax=%.4g  "
              "diag share=%.2f%%"
              % (c, zb[c]["diag_block_all_zero"], zb[c]["diag_block_absmax"],
                 zb[c]["diag_shap_absmax"],
                 zb[c]["diag_share_of_mean_abs_shap_pct"]))
    out["zero_block_check"] = zb

    # ---- 2. ranking restricted to non-diag columns ----
    imp = pd.read_csv(os.path.join(args.shapdir, "shap_importance.csv"))
    nd = imp[~imp["feature"].str.startswith("diag_pca_")].copy()
    cols = [c for c in nd.columns if c.startswith("mean_abs_")]
    for c in cols:
        nd["pct_nondiag_" + c.replace("mean_abs_", "")] = (
            100 * nd[c] / nd[c].sum())
    nd = nd.sort_values("mean_abs_mimic_test", ascending=False)
    nd.to_csv(os.path.join(args.shapdir, "shap_importance_nondiag.csv"),
              index=False, encoding="utf-8")

    gnd = nd.groupby("group")[cols].sum()
    gnd["n_cols"] = nd.groupby("group").size()
    for c in cols:
        gnd["pct_" + c.replace("mean_abs_", "")] = 100 * gnd[c] / gnd[c].sum()
    gnd = gnd.sort_values("mean_abs_mimic_test", ascending=False)
    gnd.to_csv(os.path.join(args.shapdir, "shap_grouped_nondiag.csv"),
               encoding="utf-8")
    print(">>> non-diag grouped top12 (renormalised shares):")
    show = ["mean_abs_mimic_test", "pct_mimic_test", "pct_eicu", "pct_sicdb",
            "n_cols"]
    show = [c for c in show if c in gnd.columns]
    print(gnd.head(12)[show].round(3).to_string())

    st = {}
    for tag in ["eicu", "sicdb"]:
        c = "mean_abs_%s" % tag
        if c not in nd.columns:
            continue
        st[tag] = {
            "spearman_all_nondiag_columns": float(
                spearmanr(nd["mean_abs_mimic_test"], nd[c]).statistic),
            "spearman_nondiag_groups": float(
                spearmanr(gnd["mean_abs_mimic_test"], gnd[c]).statistic),
            "top20_column_overlap": len(
                set(nd.head(20)["feature"])
                & set(nd.sort_values(c, ascending=False).head(20)["feature"])),
            "top10_group_overlap": len(
                set(gnd.head(10).index)
                & set(gnd.sort_values(c, ascending=False).head(10).index)),
        }
    out["nondiag_stability"] = st
    print(">>> non-diag stability: " + json.dumps(st, ensure_ascii=False))

    # ---- 3. positive control on full_diag external npz ----
    expl = shap.TreeExplainer(model,
                              feature_perturbation="tree_path_dependent")
    pc = {}
    for tag, path in [("eicu", args.eicu_diag), ("sicdb", args.sicdb_diag)]:
        if not path or not os.path.exists(path or ""):
            print("  skip positive control %s (no full_diag npz)" % tag)
            continue
        X, y = load_external(path)
        sv = np.asarray(expl.shap_values(X, check_additivity=True),
                        dtype=np.float64)
        if sv.ndim == 3:
            sv = sv[:, :, -1]
        m = np.abs(sv).mean(0)
        share = 100 * m[is_diag].sum() / m.sum()
        pc[tag] = {
            "n": int(len(y)),
            "diag_block_absmax": float(np.abs(X[:, is_diag]).max()),
            "diag_share_of_mean_abs_shap_pct": float(share),
            "diag_share_nodiag_pct": zb[tag][
                "diag_share_of_mean_abs_shap_pct"],
            "top_nondiag_feature": str(
                names[~is_diag][int(np.argmax(m[~is_diag]))]),
        }
        # does the non-diag ranking survive adding the real diag block?
        r = spearmanr(nd.set_index("feature").loc[
            names[~is_diag], "mean_abs_%s" % tag], m[~is_diag]).statistic
        pc[tag]["spearman_nondiag_vs_nodiag_run"] = float(r)
        print("  [%-6s full_diag] n=%d diag absmax=%.3f  diag SHAP share "
              "%.2f%% (vs %.2f%% in no_diag)  nondiag rank rho=%.4f"
              % (tag, len(y), pc[tag]["diag_block_absmax"], share,
                 pc[tag]["diag_share_nodiag_pct"], r))
    out["positive_control_full_diag"] = pc

    # ---- 4. additivity vs model margin ----
    # NB: the model was early-stopped (best_iteration=229), and both
    # predict_proba and TreeExplainer honour that by using the first
    # best_iteration+1 trees. Comparing against ALL boosted rounds is the
    # WRONG reference and produces a spurious additivity failure.
    nt = int(getattr(model, "best_iteration", None) or 0) + 1
    print(">>> additivity reference: first %d trees of %d"
          % (nt, model.get_booster().num_boosted_rounds()))
    add = {"n_trees_used": nt,
           "n_trees_total": int(model.get_booster().num_boosted_rounds())}
    for c in ["mimic_test", "eicu", "sicdb"]:
        z = np.load(os.path.join(args.shapdir, "shap_values_%s.npz" % c))
        X, sv = z["X"], z["shap"]
        base = float(z["base_value"])
        import xgboost as xgb
        dm = xgb.DMatrix(np.ascontiguousarray(X, dtype=np.float32))
        margin = model.get_booster().predict(
            dm, output_margin=True, iteration_range=(0, nt))
        recon = sv.sum(1) + base
        d = float(np.abs(recon - margin).max())
        # also check the SHAP-reconstructed probability vs predict_proba
        pp = model.predict_proba(
            np.ascontiguousarray(X, dtype=np.float32))[:, 1]
        dp = float(np.abs(1.0 / (1.0 + np.exp(-recon)) - pp).max())
        add[c] = {"max_abs_diff_margin": d, "max_abs_diff_prob": dp,
                  "base_value": base, "ok": bool(d < 1e-3 and dp < 1e-4)}
        print("  [%-10s] additivity max|sum(SHAP)+base - margin| = %.3e  "
              "prob max|d| = %.3e  %s"
              % (c, d, dp, "OK" if add[c]["ok"] else "FAIL"))
    out["additivity"] = add

    p = os.path.join(args.shapdir, "shap_sensitivity.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(">>> wrote %s" % p)


if __name__ == "__main__":
    main()
