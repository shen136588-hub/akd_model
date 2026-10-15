#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""summarize_results.py — 汇总 Informer/LR/XGB 在 A/B 的 test 结果 + 校准/DCA 图"""
import json, os
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from sklearn.calibration import calibration_curve

BASE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(BASE, "runs")


def load_report(path):
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else None


def fmt_ci(ci):
    if ci is None or len(ci) < 2 or np.isnan(ci[0]):
        return ""
    return f"({ci[0]:.3f}-{ci[1]:.3f})"


def main():
    rows = []
    for plan in ["A", "B"]:
        r = load_report(os.path.join(RUNS, f"informer_{plan}", "report.json"))
        if r is not None:
            rows.append(("Informer", plan, r["test"]))
    for plan in ["A", "B"]:
        r = load_report(os.path.join(RUNS, f"baseline_{plan}", "report.json"))
        if r is not None:
            for m in ["logreg", "xgboost"]:
                rows.append((m, plan, r[m]))

    lines = []
    hdr = f"{'model':<10}{'plan':<6}{'AUROC':<20}{'AUPRC':<10}{'Brier':<8}{'slope':<7}{'sens@Y':<8}{'spec@Y':<8}"
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for name, plan, t in rows:
        y = t["at_youden"]
        lines.append(
            f"{name:<10}{plan:<6}{t['auroc']:.3f} {fmt_ci(t['auroc_ci']):<13}"
            f"{t['auprc']:.3f}     {t['brier']:.3f}   {t['calib_slope']:.2f}   "
            f"{y['sens']:.3f}   {y['spec']:.3f}")
    out = "\n".join(lines)
    print(out)
    open(os.path.join(RUNS, "summary_table.txt"), "w", encoding="utf-8").write(out)

    # 校准图 + DCA (方案 A 主结果)
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))
    ax = axes[0]
    for name, color in [("informer_A", "C0"), ("baseline_A", "C1")]:
        if "baseline" in name:
            for m, c in [("logreg", "C1"), ("xgboost", "C2")]:
                f = os.path.join(RUNS, name, f"pred_{m}_test.npz")
                if os.path.exists(f):
                    z = np.load(f)
                    fp, mp = calibration_curve(z["y"], z["p"], n_bins=10, strategy="quantile")
                    ax.plot(mp, fp, "o-", label=m, color=c)
        else:
            f = os.path.join(RUNS, name, "pred_test.npz")
            if os.path.exists(f):
                z = np.load(f)
                fp, mp = calibration_curve(z["y"], z["p"], n_bins=10, strategy="quantile")
                ax.plot(mp, fp, "o-", label="informer", color=color)
    ax.plot([0, 1], [0, 1], "k--", alpha=0.5)
    ax.set_xlabel("Predicted probability")
    ax.set_ylabel("Observed frequency")
    ax.set_title("Calibration (plan A, test)")
    ax.legend()

    ax = axes[1]
    r = load_report(os.path.join(RUNS, "informer_A", "report.json"))
    if r is not None:
        dca = r["test"]["dca"]
        pts = [d["pt"] for d in dca]
        ax.plot(pts, [d["nb_model"] for d in dca], "o-", label="Informer", color="C0")
        ax.plot(pts, [d["nb_all"] for d in dca], "--", label="Treat all", color="gray")
        ax.plot(pts, [d["nb_none"] for d in dca], ":", label="Treat none", color="black")
    rb = load_report(os.path.join(RUNS, "baseline_A", "report.json"))
    if rb is not None:
        for m, c in [("logreg", "C1"), ("xgboost", "C2")]:
            dca = rb[m]["dca"]
            ax.plot([d["pt"] for d in dca], [d["nb_model"] for d in dca], "o-", label=m, color=c)
    ax.set_xlabel("Threshold probability")
    ax.set_ylabel("Net benefit")
    ax.set_title("Decision curve (plan A, test)")
    ax.legend()
    fig.tight_layout()
    figpath = os.path.join(RUNS, "calibration_dca_A.png")
    fig.savefig(figpath, dpi=130)
    print(">>> figure ->", figpath)


if __name__ == "__main__":
    main()