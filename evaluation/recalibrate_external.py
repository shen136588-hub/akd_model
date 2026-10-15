#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
recalibrate_external.py  —  external-cohort recalibration + DCA + comparison plots
Author: mihao for zhaoyang    Date: 2026-07-29

TRIPOD-AI external-validation calibration补救. The locked Informer shows calib
slope 0.57-0.63 externally (over-confident). We evaluate recalibration:

  Scenario 1 (DEPLOYMENT, honest): fit calibrator on MIMIC VAL predictions
    (never touches external labels), apply to MIMIC test + eICU + SICdb.
    -> reflects real prospective use (no external outcomes needed).

  Scenario 2 (CEILING, optimistic): fit calibrator on the external cohort's OWN
    predictions via 5-fold CV (uses external labels). Reported as the best-case
    calibration a cohort-specific refit could reach. Clearly flagged optimistic.

Calibrators: Platt (logistic on logit) and Isotonic.
Discrimination (AUROC/AUPRC) is INVARIANT to monotone recalibration; we report
Brier + calib slope/intercept before/after, plus DCA net-benefit, and figures.

Inputs (pred npz with keys y,p):
  MIMIC:  runs/informer_A/pred_val.npz, pred_test.npz
  EXT:    results/external_nodiag/{eicu,sicdb}_pred.npz

Usage:
  python recalibrate_external.py --outdir results/external_nodiag/recalib
"""
import argparse
import json
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold

from metrics_v2 import calibration_slope_intercept, decision_curve

EPS = 1e-6


def _logit(p):
    p = np.clip(p, EPS, 1 - EPS)
    return np.log(p / (1 - p))


def fit_platt(y, p):
    lr = LogisticRegression(penalty=None, solver="lbfgs", max_iter=1000)
    lr.fit(_logit(p).reshape(-1, 1), y)
    return lr


def apply_platt(lr, p):
    return lr.predict_proba(_logit(p).reshape(-1, 1))[:, 1]


def fit_isotonic(y, p):
    ir = IsotonicRegression(out_of_bounds="clip")
    ir.fit(p, y)
    return ir


def brier(y, p):
    return float(np.mean((p - y) ** 2))


def calib_stats(y, p):
    slope, intercept = calibration_slope_intercept(y, p)
    return dict(brier=brier(y, p), calib_slope=slope, calib_intercept=intercept)


def cv_recalib(y, p, method, seed=42):
    """Scenario 2: cohort-specific recalibration via 5-fold CV (out-of-fold preds)."""
    y = np.asarray(y).astype(int)
    p = np.asarray(p).astype(float)
    oof = np.zeros_like(p)
    skf = StratifiedKFold(n_splits=5, shuffle=True, random_state=seed)
    for tr, te in skf.split(p, y):
        if method == "platt":
            m = fit_platt(y[tr], p[tr])
            oof[te] = apply_platt(m, p[te])
        else:
            m = fit_isotonic(y[tr], p[tr])
            oof[te] = m.predict(p[te])
    return oof


def reliability_points(y, p, n_bins=10):
    bins = np.linspace(0, 1, n_bins + 1)
    idx = np.digitize(p, bins) - 1
    idx = np.clip(idx, 0, n_bins - 1)
    xs, ys, ns = [], [], []
    for b in range(n_bins):
        m = idx == b
        if m.sum() > 0:
            xs.append(float(p[m].mean()))
            ys.append(float(y[m].mean()))
            ns.append(int(m.sum()))
    return np.array(xs), np.array(ys), np.array(ns)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=".")
    ap.add_argument("--outdir", default="results/external_nodiag/recalib")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    b = args.base
    val = np.load(os.path.join(b, "runs/informer_A/pred_val.npz"))
    test = np.load(os.path.join(b, "runs/informer_A/pred_test.npz"))
    eicu = np.load(os.path.join(b, "results/external_nodiag/eicu_pred.npz"))
    sicdb = np.load(os.path.join(b, "results/external_nodiag/sicdb_pred.npz"))

    # ---- fit deployment calibrators on MIMIC VAL ----
    platt = fit_platt(val["y"], val["p"])
    iso = fit_isotonic(val["y"], val["p"])

    cohorts = {
        "mimic_test": (test["y"], test["p"]),
        "eicu": (eicu["y"], eicu["p"]),
        "sicdb": (sicdb["y"], sicdb["p"]),
    }

    report = {}
    for name, (y, p) in cohorts.items():
        y = np.asarray(y).astype(int)
        p = np.asarray(p).astype(float)
        entry = {"n": int(len(y)), "prevalence": float(y.mean()),
                 "raw": calib_stats(y, p)}
        # Scenario 1: MIMIC-val calibrators
        p_platt = apply_platt(platt, p)
        p_iso = iso.predict(p)
        entry["deploy_platt"] = calib_stats(y, p_platt)
        entry["deploy_isotonic"] = calib_stats(y, p_iso)
        # Scenario 2: cohort-specific CV recalibration (optimistic ceiling)
        p_cv_platt = cv_recalib(y, p, "platt")
        p_cv_iso = cv_recalib(y, p, "isotonic")
        entry["cohort_platt_cv"] = calib_stats(y, p_cv_platt)
        entry["cohort_isotonic_cv"] = calib_stats(y, p_cv_iso)
        # DCA on best deployment (platt) vs raw
        entry["dca_raw"] = decision_curve(y, p)
        entry["dca_deploy_platt"] = decision_curve(y, p_platt)
        report[name] = entry
        # stash arrays for plotting
        entry["_arrays"] = dict(y=y, raw=p, platt=p_platt, iso=p_iso)

    # ---- figure 1: reliability curves (raw vs deploy-platt) 3 cohorts ----
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))
    for ax, name in zip(axes, ["mimic_test", "eicu", "sicdb"]):
        arr = report[name]["_arrays"]
        for lab, key, style in [("raw", "raw", "o-"), ("recal(Platt)", "platt", "s-")]:
            xs, ys, ns = reliability_points(arr["y"], arr[key], n_bins=10)
            ax.plot(xs, ys, style, label=lab, alpha=0.8)
        ax.plot([0, 1], [0, 1], "k--", lw=1, label="ideal")
        r = report[name]
        ax.set_title("%s (n=%d, AKD+=%.0f%%) raw slope=%.2f -> Platt slope=%.2f" % (
            name, r["n"], 100 * r["prevalence"],
            r["raw"]["calib_slope"], r["deploy_platt"]["calib_slope"]))
        ax.set_xlabel("predicted probability")
        ax.set_ylabel("observed frequency")
        ax.legend(loc="upper left", fontsize=8)
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
    fig.suptitle("External calibration: raw vs MIMIC-val Platt recalibration (Informer plan A, no-diag)")
    fig.tight_layout()
    f1 = os.path.join(args.outdir, "calibration_reliability.png")
    fig.savefig(f1, dpi=140)
    plt.close(fig)

    # ---- figure 2: DCA 3 cohorts ----
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))
    for ax, name in zip(axes, ["mimic_test", "eicu", "sicdb"]):
        dca = report[name]["dca_deploy_platt"]
        pts = [d["pt"] for d in dca]
        ax.plot(pts, [d["nb_model"] for d in dca], "o-", label="model (recal)")
        ax.plot(pts, [d["nb_all"] for d in dca], "--", label="treat all")
        ax.plot(pts, [0] * len(pts), "k-", lw=0.8, label="treat none")
        ax.set_title("%s DCA" % name)
        ax.set_xlabel("threshold probability")
        ax.set_ylabel("net benefit")
        ax.legend(fontsize=8)
    fig.suptitle("Decision curve analysis (recalibrated, Informer plan A, no-diag)")
    fig.tight_layout()
    f2 = os.path.join(args.outdir, "dca_curves.png")
    fig.savefig(f2, dpi=140)
    plt.close(fig)

    # ---- strip arrays before json ----
    for name in report:
        report[name].pop("_arrays", None)
    with open(os.path.join(args.outdir, "recalib_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # ---- console summary ----
    print("=== Recalibration summary (Brier / calib slope) ===")
    print("%-12s %-18s %-18s %-18s" % ("cohort", "raw", "deploy-Platt", "cohort-iso-CV"))
    for name in ["mimic_test", "eicu", "sicdb"]:
        r = report[name]
        print("%-12s B=%.3f s=%.2f      B=%.3f s=%.2f      B=%.3f s=%.2f" % (
            name,
            r["raw"]["brier"], r["raw"]["calib_slope"],
            r["deploy_platt"]["brier"], r["deploy_platt"]["calib_slope"],
            r["cohort_isotonic_cv"]["brier"], r["cohort_isotonic_cv"]["calib_slope"]))
    print(">>> figures:", f1, f2)
    print(">>> report:", os.path.join(args.outdir, "recalib_report.json"))


if __name__ == "__main__":
    main()