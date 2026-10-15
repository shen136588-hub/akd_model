#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
fig_shap.py  --  SHAP figures for the manuscript (locked XGBoost, Plan B tier1).

Dependence plots are drawn manually rather than via shap.dependence_plot so the
x axis can be inverse-RobustScaler-transformed back to real clinical units;
plotting scaled values would make the figure unreadable to clinicians.

Outputs into --outdir:
  fig_shap_beeswarm.png          beeswarm, MIMIC test, top 20 columns
  fig_shap_grouped_bar.png       cross-cohort grouped importance (non-diag, %)
  fig_shap_dependence.png        6 dependence panels in raw clinical units
  fig_shap_waterfall_pos.png     one true-positive AKD case
  fig_shap_waterfall_neg.png     one true-negative case
Usage:
  python fig_shap.py --shapdir results/shap_xgb_B_tier1 \
      --dataset ../feature_pipeline_v2/dataset_B --outdir results/shap_xgb_B_tier1/figs
"""
import argparse
import json
import os

import joblib
import matplotlib
import numpy as np
import pandas as pd

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from step1_shap_xgboost import build_names, inverse_axis  # noqa: E402

PRETTY = {
    "creat_lab__last": "Creatinine, last value (mg/dL)",
    "creat_lab__slope": "Creatinine trajectory, last-minus-first (mg/dL)",
    "creat_lab__max": "Creatinine, maximum (mg/dL)",
    "creat_lab__mean": "Creatinine, mean (mg/dL)",
    "cr_baseline": "Baseline creatinine (mg/dL)",
    "bun__last": "BUN, last value (mg/dL)",
    "sbp__last": "Systolic BP, last value (mmHg)",
    "uo_rt_6hr__last": "Urine output rate 6h, last (mL/kg/h)",
    "uo_rt_24hr__nobs": "Urine output 24h, number of observations",
    "potassium__mean": "Potassium, mean (mmol/L)",
    "vent_level__mean": "Ventilation level, mean (ordinal)",
    "sapsii": "SAPS II",
    "aniongap__last": "Anion gap, last (mmol/L)",
    "fio2_value_max__last": "FiO2 max, last",
    "hemoglobin__slope": "Hemoglobin trajectory (g/dL)",
}


def label_of(name):
    return PRETTY.get(name, name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shapdir", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    import shap

    meta = json.load(open(os.path.join(args.dataset, "feature_meta.json"),
                          encoding="utf-8"))
    names, ts_cols, st_cols = build_names(meta)
    names = list(names)
    ts_scaler = joblib.load(os.path.join(args.dataset,
                                         "ts_robust_scaler.pkl"))
    st_scaler = joblib.load(os.path.join(args.dataset,
                                         "static_robust_scaler.pkl"))

    z = np.load(os.path.join(args.shapdir, "shap_values_mimic_test.npz"))
    X, sv, y = z["X"], z["shap"].astype(np.float64), z["y"]
    base = float(z["base_value"])
    print(">>> MIMIC test n=%d  AKD+=%d" % (len(y), int(y.sum())))

    # ---------------- 1. beeswarm ----------------
    disp = [label_of(n) for n in names]
    plt.figure()
    shap.summary_plot(sv, X, feature_names=disp, max_display=20, show=False,
                      plot_size=(9.0, 7.0))
    ax = plt.gca()
    ax.set_xlabel("SHAP value (impact on log-odds of AKD)", fontsize=10)
    plt.tight_layout()
    f1 = os.path.join(args.outdir, "fig_shap_beeswarm.png")
    plt.savefig(f1, dpi=300, bbox_inches="tight")
    plt.close("all")
    print(">>> wrote %s" % f1)

    # ---------------- 2. cross-cohort grouped bar (non-diag, % share) ----
    gnd = pd.read_csv(os.path.join(args.shapdir,
                                   "shap_grouped_nondiag.csv"), index_col=0)
    top = gnd.head(15)
    series = [("pct_mimic_test", "MIMIC-IV test"),
              ("pct_eicu", "eICU-CRD"), ("pct_sicdb", "SICdb")]
    series = [(c, lab) for c, lab in series if c in top.columns]
    fig, axb = plt.subplots(figsize=(9.0, 6.2))
    ypos = np.arange(len(top))
    h = 0.8 / len(series)
    colors = ["#2c6fbb", "#e8973c", "#4aa564"]
    for i, (c, lab) in enumerate(series):
        axb.barh(ypos + i * h, top[c].values, h, label=lab,
                 color=colors[i % 3], edgecolor="none")
    axb.set_yticks(ypos + h * (len(series) - 1) / 2)
    axb.set_yticklabels(top.index, fontsize=9)
    axb.invert_yaxis()
    axb.set_xlabel("Share of total mean |SHAP| among non-diagnosis "
                   "features (%)", fontsize=10)
    axb.legend(fontsize=9, frameon=False)
    axb.grid(axis="x", alpha=0.3, linestyle=":")
    axb.set_axisbelow(True)
    plt.tight_layout()
    f2 = os.path.join(args.outdir, "fig_shap_grouped_bar.png")
    plt.savefig(f2, dpi=300, bbox_inches="tight")
    plt.close("all")
    print(">>> wrote %s" % f2)

    # ---------------- 3. dependence panels in raw units ----------------
    panels = ["creat_lab__last", "creat_lab__slope", "cr_baseline",
              "bun__last", "uo_rt_6hr__last", "sbp__last"]
    panels = [p for p in panels if p in names]
    fig, axes = plt.subplots(2, 3, figsize=(13.5, 7.6))
    axinfo = {}
    for axd, nm in zip(axes.ravel(), panels):
        j = names.index(nm)
        xs = X[:, j].astype(np.float64)
        xr, ok = inverse_axis(nm, xs, ts_scaler, ts_cols, st_scaler, st_cols)
        s = sv[:, j]
        # clip x for display only, so extreme outliers do not flatten the plot
        lo, hi = np.percentile(xr, [0.5, 99.5])
        keep = (xr >= lo) & (xr <= hi)
        axd.axhline(0, color="grey", lw=0.8, ls="--", alpha=0.7)
        sc = axd.scatter(xr[keep], s[keep], c=y[keep], cmap="coolwarm",
                         s=5, alpha=0.55, edgecolors="none")
        xl = label_of(nm) + ("" if ok else " [scaled]")
        axd.set_xlabel(xl, fontsize=9)
        axd.set_ylabel("SHAP (log-odds)", fontsize=9)
        axd.tick_params(labelsize=8)
        axinfo[nm] = {"x_lo": float(lo), "x_hi": float(hi),
                      "shap_lo": float(s[keep].min()),
                      "shap_hi": float(s[keep].max()),
                      "inverse_ok": bool(ok),
                      "n_shown": int(keep.sum()), "n_total": int(len(xr))}
    cb = fig.colorbar(sc, ax=axes, shrink=0.6, ticks=[0, 1], pad=0.02)
    cb.ax.set_yticklabels(["no AKD", "AKD"])
    cb.ax.tick_params(labelsize=8)
    f3 = os.path.join(args.outdir, "fig_shap_dependence.png")
    plt.savefig(f3, dpi=300, bbox_inches="tight")
    plt.close("all")
    print(">>> wrote %s" % f3)

    # ---------------- 4/5. waterfalls ----------------
    import scipy.special as sp
    prob = sp.expit(sv.sum(1) + base)
    for tag, want in [("pos", 1), ("neg", 0)]:
        cand = np.where(y == want)[0]
        # a confidently AND correctly classified, near-median-confidence case
        pr = prob[cand]
        sel = cand[np.argsort(np.abs(pr - (0.85 if want else 0.15)))[0]]
        e = shap.Explanation(values=sv[sel], base_values=base,
                             data=X[sel], feature_names=disp)
        plt.figure()
        shap.plots.waterfall(e, max_display=14, show=False)
        plt.gcf().set_size_inches(9.0, 5.6)
        plt.title("AKD %s case, predicted probability %.3f, observed %s"
                  % ("positive" if want else "negative", prob[sel],
                     "AKD" if want else "no AKD"), fontsize=10)
        plt.tight_layout()
        fo = os.path.join(args.outdir, "fig_shap_waterfall_%s.png" % tag)
        plt.savefig(fo, dpi=300, bbox_inches="tight")
        plt.close("all")
        print(">>> wrote %s (idx=%d p=%.3f)" % (fo, sel, prob[sel]))
        axinfo["waterfall_" + tag] = {"idx": int(sel),
                                      "prob": float(prob[sel]),
                                      "y": int(y[sel])}

    with open(os.path.join(args.outdir, "fig_meta.json"), "w",
              encoding="utf-8") as f:
        json.dump(axinfo, f, ensure_ascii=False, indent=2)
    print(">>> ALL FIGURES DONE")


if __name__ == "__main__":
    main()
