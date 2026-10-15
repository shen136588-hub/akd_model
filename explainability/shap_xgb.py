#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
shap_xgb.py  --  SHAP interpretability for the LOCKED XGBoost main model.

Design constraints (so nothing already reported can move):
  * loads runs/baseline_B/model_xgboost.pkl as-is; NEVER refits
  * reuses train_baselines.load / summarize_ts so the 316 columns are the
    exact same object the model was fitted on (single source of truth)
  * TreeExplainer with exact tree path dependent SHAP (no sampling), so
    values are deterministic and reproducible
  * SHAP is computed on MIMIC test (locked hold-out) and on BOTH external
    cohorts, because cross-cohort agreement of the explanation is part of
    the transferability story, not a decoration

Outputs (all into --outdir):
  shap_values_<cohort>.npz        raw SHAP matrices (log-odds units)
  shap_importance.csv             per-column mean|SHAP| in all 3 cohorts
  shap_grouped.csv                importance aggregated to clinical variables
  shap_top_table.md              manuscript-ready top-20 table with CI
  shap_stability.json            rank agreement across cohorts
Usage:
  python shap_xgb.py --dataset ../feature_pipeline_v2/dataset_B \
      --model runs/baseline_B/model_xgboost.pkl \
      --eicu <eicu npz> --sicdb <sicdb npz> --outdir results/shap_xgb_B_tier1
"""
import argparse
import json
import os

import joblib
import numpy as np
import pandas as pd

from train_baselines import load as tab_load
from train_baselines import summarize_ts

# summarize_ts appends blocks in this exact order, one block per statistic,
# each block spanning all timeseries features
STATS = ["mean", "std", "min", "max", "last", "slope", "nobs"]
# statistics that are location+scale (need center) vs scale-only
AFFINE = {"mean", "min", "max", "last"}
SCALE_ONLY = {"std", "slope"}


def build_names(meta):
    ts = list(meta["ts_feature_cols"])
    st = list(meta["static_feature_cols_final"])
    names = []
    for s in STATS:
        names += ["%s__%s" % (c, s) for c in ts]
    names += st
    return names, ts, st


def group_of(name, ts_cols):
    """map a column to its clinical variable (for aggregated importance)"""
    if "__" in name:
        base = name.split("__")[0]
        return base if base in ts_cols else name
    if name.startswith("diag_pca_"):
        return "diag_text_block"
    return name


def load_external(path):
    z = np.load(path)
    Xt = summarize_ts(z["X_ts"], z["mask"])
    X = np.concatenate([Xt, z["X_static"]], axis=1).astype(np.float32)
    X = np.nan_to_num(X, nan=0.0, posinf=0.0, neginf=0.0)
    return X, z["y"].astype(int)


def inverse_axis(name, vals, ts_scaler, ts_cols, st_scaler, st_cols):
    """scaled -> raw clinical units, for readable dependence plots.
    returns (values, ok) where ok=False means no inverse is defined."""
    if "__" in name:
        base, stat = name.split("__")
        if stat == "nobs":
            return vals, False
        # ts_scaler was fitted on feat_cols minus vent_level
        scale_cols = [c for c in ts_cols if c != "vent_level"]
        if base not in scale_cols:
            return vals, False
        j = scale_cols.index(base)
        sc = ts_scaler.scale_[j]
        ce = ts_scaler.center_[j]
        if stat in AFFINE:
            return vals * sc + ce, True
        if stat in SCALE_ONLY:
            return vals * sc, True
        return vals, False
    if name in st_cols:
        # only the 6 numeric static columns were scaled
        num = ["age", "obs_hours", "weight", "cr_baseline", "sapsii",
               "sofa_baseline"]
        if name in num:
            j = num.index(name)
            return vals * st_scaler.scale_[j] + st_scaler.center_[j], True
    return vals, False


def boot_ci(absv, n_boot, seed):
    """bootstrap CI of mean|SHAP| by resampling patients"""
    rng = np.random.default_rng(seed)
    n = absv.shape[0]
    keep = np.zeros((n_boot, absv.shape[1]), dtype=np.float32)
    for b in range(n_boot):
        idx = rng.integers(0, n, n)
        keep[b] = absv[idx].mean(axis=0)
    lo = np.percentile(keep, 2.5, axis=0)
    hi = np.percentile(keep, 97.5, axis=0)
    return lo, hi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--model", default="runs/baseline_B/model_xgboost.pkl")
    ap.add_argument("--eicu", default=None)
    ap.add_argument("--sicdb", default=None)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--n_boot", type=int, default=500)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    import shap

    meta = json.load(open(os.path.join(args.dataset, "feature_meta.json"),
                          encoding="utf-8"))
    names, ts_cols, st_cols = build_names(meta)

    model = joblib.load(args.model)
    booster = model.get_booster()
    nfeat = booster.num_features()
    assert nfeat == len(names), (
        "column count mismatch: model=%d names=%d" % (nfeat, len(names)))
    print(">>> model rounds=%d  best_iteration=%s  features=%d"
          % (booster.num_boosted_rounds(), getattr(model, "best_iteration",
                                                   None), nfeat))

    cohorts = {}
    Xte, yte = tab_load(args.dataset, "test")
    cohorts["mimic_test"] = (np.nan_to_num(Xte, nan=0.0, posinf=0.0,
                                           neginf=0.0), yte)
    if args.eicu:
        cohorts["eicu"] = load_external(args.eicu)
    if args.sicdb:
        cohorts["sicdb"] = load_external(args.sicdb)

    explainer = shap.TreeExplainer(model, feature_perturbation="tree_path_dependent")
    print(">>> explainer base_value (log-odds) = %.4f"
          % float(np.ravel(explainer.expected_value)[0]))

    imp = pd.DataFrame({"feature": names})
    imp["group"] = [group_of(n, ts_cols) for n in names]
    sv_store = {}
    for cname, (X, y) in cohorts.items():
        sv = explainer.shap_values(X, check_additivity=True)
        sv = np.asarray(sv, dtype=np.float64)
        if sv.ndim == 3:                       # (n, f, class) safety
            sv = sv[:, :, -1]
        absv = np.abs(sv).astype(np.float32)
        m = absv.mean(axis=0)
        imp["mean_abs_%s" % cname] = m
        # signed direction: rank corr between feature value and its SHAP
        dirs = np.zeros(sv.shape[1])
        for j in range(sv.shape[1]):
            xv = X[:, j]
            if np.std(xv) < 1e-12 or np.std(sv[:, j]) < 1e-12:
                dirs[j] = np.nan
                continue
            rx = pd.Series(xv).rank().to_numpy()
            rs = pd.Series(sv[:, j]).rank().to_numpy()
            dirs[j] = np.corrcoef(rx, rs)[0, 1]
        imp["dir_%s" % cname] = dirs
        if cname == "mimic_test":
            lo, hi = boot_ci(absv, args.n_boot, args.seed)
            imp["ci_lo_mimic"] = lo
            imp["ci_hi_mimic"] = hi
        np.savez_compressed(
            os.path.join(args.outdir, "shap_values_%s.npz" % cname),
            shap=sv.astype(np.float32), X=X.astype(np.float32), y=y,
            base_value=np.ravel(explainer.expected_value)[0])
        sv_store[cname] = (sv, X, y)
        print("  [%-10s] n=%d  mean|SHAP| sum=%.4f  top=%s"
              % (cname, len(y), m.sum(), names[int(np.argmax(m))]))

    imp = imp.sort_values("mean_abs_mimic_test", ascending=False)
    imp.to_csv(os.path.join(args.outdir, "shap_importance.csv"),
               index=False, encoding="utf-8")

    # ---- grouped to clinical variables ----
    cols = [c for c in imp.columns if c.startswith("mean_abs_")]
    g = imp.groupby("group")[cols].sum()
    g["n_cols"] = imp.groupby("group").size()
    g = g.sort_values("mean_abs_mimic_test", ascending=False)
    for c in cols:
        g["pct_" + c.replace("mean_abs_", "")] = 100 * g[c] / g[c].sum()
    g.to_csv(os.path.join(args.outdir, "shap_grouped.csv"), encoding="utf-8")
    print(">>> grouped top10:")
    print(g.head(10).round(4).to_string())

    # ---- cross-cohort stability ----
    stab = {}
    if len(cols) > 1:
        from scipy.stats import spearmanr
        base = "mean_abs_mimic_test"
        for c in cols:
            if c == base:
                continue
            tag = c.replace("mean_abs_", "")
            r_all = spearmanr(imp[base], imp[c]).statistic
            top = imp.head(20)
            r_top = spearmanr(top[base], top[c]).statistic
            rg = spearmanr(g[base], g[c]).statistic
            gt = g.head(20)
            rgt = spearmanr(gt[base], gt[c]).statistic
            # overlap of top-20 sets
            s1 = set(imp.head(20)["feature"])
            s2 = set(imp.sort_values(c, ascending=False).head(20)["feature"])
            g1 = set(g.head(20).index)
            g2 = set(g.sort_values(c, ascending=False).head(20).index)
            stab[tag] = {
                "spearman_all_columns": float(r_all),
                "spearman_top20_columns": float(r_top),
                "spearman_all_groups": float(rg),
                "spearman_top20_groups": float(rgt),
                "top20_column_overlap": len(s1 & s2),
                "top20_group_overlap": len(g1 & g2),
                "top20_groups_missing_externally": sorted(g1 - g2),
            }
    with open(os.path.join(args.outdir, "shap_stability.json"), "w",
              encoding="utf-8") as f:
        json.dump(stab, f, ensure_ascii=False, indent=2)
    print(">>> stability: " + json.dumps(stab, ensure_ascii=False))

    # ---- manuscript table ----
    lines = []
    lines.append("### SHAP global importance, locked XGBoost (Plan B, tier1)")
    lines.append("")
    hdr = ("| Rank | Feature | mean abs SHAP (log-odds) MIMIC test "
           "| 95% CI | direction rho | eICU | SICdb |")
    lines.append(hdr)
    lines.append("|---|---|---|---|---|---|---|")
    for i, (_, r) in enumerate(imp.head(20).iterrows(), start=1):
        lines.append("| %d | %s | %.4f | %.4f-%.4f | %s | %s | %s |" % (
            i, r["feature"], r["mean_abs_mimic_test"],
            r["ci_lo_mimic"], r["ci_hi_mimic"],
            ("%.2f" % r["dir_mimic_test"]) if not np.isnan(
                r["dir_mimic_test"]) else "n/a",
            ("%.4f" % r["mean_abs_eicu"]) if "mean_abs_eicu" in imp else "-",
            ("%.4f" % r["mean_abs_sicdb"]) if "mean_abs_sicdb" in imp else "-",
        ))
    lines.append("")
    lines.append("### Aggregated to clinical variables (top 15)")
    lines.append("")
    lines.append("| Rank | Variable | n columns | sum mean abs SHAP "
                 "| share of total (%) |")
    lines.append("|---|---|---|---|---|")
    for i, (k, r) in enumerate(g.head(15).iterrows(), start=1):
        lines.append("| %d | %s | %d | %.4f | %.1f |" % (
            i, k, int(r["n_cols"]), r["mean_abs_mimic_test"],
            r["pct_mimic_test"]))
    with open(os.path.join(args.outdir, "shap_top_table.md"), "w",
              encoding="utf-8") as f:
        f.write(chr(10).join(lines) + chr(10))
    print(">>> wrote " + os.path.join(args.outdir, "shap_top_table.md"))
    print(">>> DONE")


if __name__ == "__main__":
    main()
