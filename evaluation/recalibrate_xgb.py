#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
recalibrate_xgb.py  --  deployment-grade recalibration of the locked XGBoost model
Author: mihao for zhaoyang    Date: 2026-08-03

WHY
---
Discrimination transfers well across cohorts (Plan A eICU XGB AUROC 0.704,
SICdb 0.731) but calibration does not: measured slopes were eICU 0.85 and
SICdb 1.20, i.e. the risk numbers themselves are off even though the ranking is
fine. A slope < 1 means over-confident (predictions too extreme), > 1 means
under-confident. For a bedside AKD risk score the absolute probability is what
drives decisions, so we must recalibrate.

HONEST vs OPTIMISTIC
--------------------
Scenario DEPLOY   : calibrator fitted on MIMIC VAL only, then frozen and applied
                    to MIMIC test / eICU / SICdb. Never sees external labels.
                    This is what a real prospective deployment can do.
Scenario CEILING  : calibrator fitted on each external cohort's own data via
                    5-fold CV (out-of-fold). Uses external labels, so it is
                    optimistic; reported only as the upper bound reachable by a
                    site-specific refit. MUST be labelled as such in the paper.

AUROC / AUPRC are invariant under monotone recalibration, so they are reported
once (unchanged) as a sanity check; the action is in Brier / slope / intercept
and in the decision curves.

Key constraint: the XGBoost model itself is NEVER refitted. We load the locked
model_xgboost.pkl and only reproduce its val predictions (which train_baselines.py
did not save), then fit a 1-parameter Platt / isotonic map on top.

Usage
-----
  python recalibrate_xgb.py --plan A --results results/external_nodiag_fix
  python recalibrate_xgb.py --plan B --results results/external_B_nodiag_fix
"""
import argparse
import json
import os

import joblib
import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from sklearn.isotonic import IsotonicRegression  # noqa: E402
from sklearn.linear_model import LogisticRegression  # noqa: E402
from sklearn.metrics import average_precision_score, roc_auc_score  # noqa: E402
from sklearn.model_selection import StratifiedKFold  # noqa: E402

from metrics_v2 import calibration_slope_intercept, decision_curve  # noqa: E402

EPS = 1e-6
HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------
# feature construction: must byte-for-byte match train_baselines.py
# --------------------------------------------------------------------------
def summarize_ts(X_ts, mask):
    feats = [
        X_ts.mean(axis=1),
        X_ts.std(axis=1),
        X_ts.min(axis=1),
        X_ts.max(axis=1),
        X_ts[:, -1, :],
        X_ts[:, -1, :] - X_ts[:, 0, :],
        mask.mean(axis=1),
    ]
    return np.concatenate(feats, axis=1)


def load_split(dataset, split):
    z = np.load(os.path.join(dataset, f"{split}_final.npz"))
    X = np.concatenate([summarize_ts(z["X_ts"], z["mask"]), z["X_static"]], axis=1)
    return X.astype(np.float32), z["y"].astype(int)


# --------------------------------------------------------------------------
# calibrators
# --------------------------------------------------------------------------
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


def cv_recalib(y, p, method, seed=42):
    y = np.asarray(y).astype(int)
    p = np.asarray(p).astype(float)
    oof = np.zeros_like(p)
    for tr, te in StratifiedKFold(5, shuffle=True, random_state=seed).split(p, y):
        if method == "platt":
            oof[te] = apply_platt(fit_platt(y[tr], p[tr]), p[te])
        else:
            oof[te] = fit_isotonic(y[tr], p[tr]).predict(p[te])
    return oof


def stats(y, p):
    slope, intercept = calibration_slope_intercept(y, p)
    return dict(
        brier=float(np.mean((p - y) ** 2)),
        calib_slope=float(slope),
        calib_intercept=float(intercept),
        auroc=float(roc_auc_score(y, p)),
        auprc=float(average_precision_score(y, p)),
        mean_pred=float(p.mean()),
        observed=float(np.asarray(y).mean()),
    )


def reliability(y, p, n_bins=10):
    bins = np.linspace(0, 1, n_bins + 1)
    idx = np.clip(np.digitize(p, bins) - 1, 0, n_bins - 1)
    xs, ys, ns = [], [], []
    for b in range(n_bins):
        m = idx == b
        if m.sum() >= 10:
            xs.append(float(p[m].mean()))
            ys.append(float(np.asarray(y)[m].mean()))
            ns.append(int(m.sum()))
    return np.array(xs), np.array(ys), np.array(ns)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", choices=["A", "B"], required=True)
    ap.add_argument("--results", required=True,
                    help="results dir holding {eicu,sicdb}_xgboost_pred.npz")
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    base = HERE
    dataset = os.path.join(base, "..", "feature_pipeline_v2", f"dataset_{args.plan}")
    runs = os.path.join(base, "runs", f"baseline_{args.plan}")
    resdir = os.path.join(base, args.results)
    outdir = args.outdir or os.path.join(resdir, "recalib_xgb")
    os.makedirs(outdir, exist_ok=True)

    print(f">>> plan {args.plan}")
    print(f"    dataset : {os.path.normpath(dataset)}")
    print(f"    model   : {os.path.normpath(runs)}/model_xgboost.pkl")
    print(f"    results : {os.path.normpath(resdir)}")
    print(f"    outdir  : {os.path.normpath(outdir)}")

    xgb = joblib.load(os.path.join(runs, "model_xgboost.pkl"))

    # ---- reproduce MIMIC val predictions (train_baselines.py never saved them) ----
    # The model is loaded as-is; this is inference only, no refit.
    Xva, yva = load_split(dataset, "val")
    p_va = xgb.predict_proba(Xva)[:, 1]
    print(f"    MIMIC val: n={len(yva)}, AKD+={yva.mean()*100:.1f}%, "
          f"AUROC={roc_auc_score(yva, p_va):.4f}")

    # sanity: regenerated test preds must match the locked pred_xgboost_test.npz
    Xte, yte = load_split(dataset, "test")
    p_te = xgb.predict_proba(Xte)[:, 1]
    locked = np.load(os.path.join(runs, "pred_xgboost_test.npz"))
    max_dev = float(np.abs(locked["p"] - p_te).max())
    label_ok = bool((locked["y"] == yte).all())
    print(f"    reproducibility check vs locked test preds: "
          f"max|dp|={max_dev:.2e}, labels identical={label_ok}")
    if max_dev > 1e-5 or not label_ok:
        raise SystemExit("!!! cannot reproduce locked test predictions - aborting; "
                         "the feature construction or model file has drifted.")

    # ---- freeze deployment calibrators on MIMIC val ----
    platt = fit_platt(yva, p_va)
    iso = fit_isotonic(yva, p_va)
    a = float(platt.coef_[0][0])
    b = float(platt.intercept_[0])
    print(f"    deployment Platt map: logit(p') = {a:.4f} * logit(p) + {b:.4f}")

    eicu = np.load(os.path.join(resdir, "eicu_xgboost_pred.npz"))
    sicdb = np.load(os.path.join(resdir, "sicdb_xgboost_pred.npz"))
    cohorts = {
        "mimic_test": (yte, p_te),
        "eicu": (eicu["y"].astype(int), eicu["p"].astype(float)),
        "sicdb": (sicdb["y"].astype(int), sicdb["p"].astype(float)),
    }

    report = {
        "plan": args.plan,
        "model": "xgboost",
        "results_dir": args.results,
        "platt_deploy": {"slope_on_logit": a, "intercept": b},
        "mimic_val": {"n": int(len(yva)), "prevalence": float(yva.mean())},
        "cohorts": {},
    }
    arrays = {}

    for name, (y, p) in cohorts.items():
        e = {"n": int(len(y)), "prevalence": float(y.mean()), "raw": stats(y, p)}
        p_pl = apply_platt(platt, p)
        p_is = iso.predict(p)
        e["deploy_platt"] = stats(y, p_pl)
        e["deploy_isotonic"] = stats(y, p_is)
        e["ceiling_platt_cv"] = stats(y, cv_recalib(y, p, "platt", args.seed))
        e["ceiling_isotonic_cv"] = stats(y, cv_recalib(y, p, "isotonic", args.seed))
        e["dca_raw"] = decision_curve(y, p)
        e["dca_deploy_platt"] = decision_curve(y, p_pl)
        report["cohorts"][name] = e
        arrays[name] = dict(y=y, raw=p, platt=p_pl, iso=p_is)
        np.savez(os.path.join(outdir, f"{name}_recal_pred.npz"),
                 y=y, p_raw=p, p_platt=p_pl, p_isotonic=p_is)

    joblib.dump({"platt": platt, "isotonic": iso},
                os.path.join(outdir, "calibrators_mimic_val.pkl"))

    # ---- figure: reliability, raw vs deployment Platt ----
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.8))
    for ax, name in zip(axes, ["mimic_test", "eicu", "sicdb"]):
        arr = arrays[name]
        for lab, key, st in [("raw", "raw", "o-"), ("Platt (MIMIC-val)", "platt", "s-")]:
            xs, ys, _ = reliability(arr["y"], arr[key])
            ax.plot(xs, ys, st, alpha=0.85, label=lab)
        ax.plot([0, 1], [0, 1], "k--", lw=1, label="ideal")
        r = report["cohorts"][name]
        ax.set_title("%s  n=%d, AKD+=%.0f%%\nslope %.2f -> %.2f | Brier %.3f -> %.3f"
                     % (name, r["n"], 100 * r["prevalence"],
                        r["raw"]["calib_slope"], r["deploy_platt"]["calib_slope"],
                        r["raw"]["brier"], r["deploy_platt"]["brier"]), fontsize=9)
        ax.set_xlabel("predicted probability")
        ax.set_ylabel("observed frequency")
        ax.set_xlim(0, 1)
        ax.set_ylim(0, 1)
        ax.legend(loc="upper left", fontsize=8)
    fig.suptitle(f"XGBoost plan {args.plan}: deployment recalibration "
                 f"(calibrator frozen on MIMIC val, external labels unused)")
    fig.tight_layout()
    f1 = os.path.join(outdir, "calibration_reliability_xgb.png")
    fig.savefig(f1, dpi=140)
    plt.close(fig)

    # ---- figure: DCA raw vs recalibrated ----
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.8))
    for ax, name in zip(axes, ["mimic_test", "eicu", "sicdb"]):
        r = report["cohorts"][name]
        pts = [d["pt"] for d in r["dca_deploy_platt"]]
        ax.plot(pts, [d["nb_model"] for d in r["dca_raw"]], "o-", ms=3,
                label="model (raw)")
        ax.plot(pts, [d["nb_model"] for d in r["dca_deploy_platt"]], "s-", ms=3,
                label="model (recalibrated)")
        ax.plot(pts, [d["nb_all"] for d in r["dca_deploy_platt"]], "--",
                label="treat all")
        ax.axhline(0, color="k", lw=0.8, label="treat none")
        ax.set_title(f"{name} DCA", fontsize=9)
        ax.set_xlabel("threshold probability")
        ax.set_ylabel("net benefit")
        ax.legend(fontsize=8)
    fig.suptitle(f"Decision curve analysis, XGBoost plan {args.plan}")
    fig.tight_layout()
    f2 = os.path.join(outdir, "dca_xgb.png")
    fig.savefig(f2, dpi=140)
    plt.close(fig)

    with open(os.path.join(outdir, "recalib_xgb_report.json"), "w",
              encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # ---- console summary ----
    print()
    print("=" * 94)
    print(f"XGBoost plan {args.plan} recalibration  (AUROC/AUPRC invariant under "
          f"monotone maps)")
    print("=" * 94)
    hdr = "%-11s %-24s %-24s %-24s" % (
        "cohort", "RAW", "DEPLOY Platt (honest)", "CEILING iso-CV (optimistic)")
    print(hdr)
    for name in ["mimic_test", "eicu", "sicdb"]:
        r = report["cohorts"][name]
        print("%-11s B=%.3f s=%.2f i=%+.2f  B=%.3f s=%.2f i=%+.2f  B=%.3f s=%.2f i=%+.2f"
              % (name,
                 r["raw"]["brier"], r["raw"]["calib_slope"], r["raw"]["calib_intercept"],
                 r["deploy_platt"]["brier"], r["deploy_platt"]["calib_slope"],
                 r["deploy_platt"]["calib_intercept"],
                 r["ceiling_isotonic_cv"]["brier"], r["ceiling_isotonic_cv"]["calib_slope"],
                 r["ceiling_isotonic_cv"]["calib_intercept"]))
    print()
    print("mean predicted vs observed risk:")
    for name in ["mimic_test", "eicu", "sicdb"]:
        r = report["cohorts"][name]
        print("  %-11s observed=%.3f | raw pred=%.3f | Platt pred=%.3f | iso pred=%.3f"
              % (name, r["raw"]["observed"], r["raw"]["mean_pred"],
                 r["deploy_platt"]["mean_pred"], r["deploy_isotonic"]["mean_pred"]))
    print()
    print(">>> figures:", f1)
    print("            ", f2)
    print(">>> report :", os.path.join(outdir, "recalib_xgb_report.json"))


if __name__ == "__main__":
    main()
