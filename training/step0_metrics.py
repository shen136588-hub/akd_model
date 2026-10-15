#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
metrics_v2.py  —  TRIPOD-AI 评估指标
Author: 米好 for 朝阳    Date: 2026-07-26
"""
import numpy as np
from sklearn.metrics import (
    average_precision_score, brier_score_loss, confusion_matrix, roc_auc_score,
)


def bootstrap_ci(y, p, fn, n_boot=1000, seed=42):
    rng = np.random.default_rng(seed)
    n = len(y)
    stats = []
    for _ in range(n_boot):
        idx = rng.integers(0, n, n)
        if len(np.unique(y[idx])) < 2:
            continue
        stats.append(fn(y[idx], p[idx]))
    if not stats:
        return (np.nan, np.nan)
    return (float(np.percentile(stats, 2.5)), float(np.percentile(stats, 97.5)))


def calibration_slope_intercept(y, p):
    """logistic 重拟合: logit(y) ~ a + b*logit(p). b=slope, a=intercept."""
    from sklearn.linear_model import LogisticRegression
    eps = 1e-6
    p = np.clip(p, eps, 1 - eps)
    lo = np.log(p / (1 - p)).reshape(-1, 1)
    try:
        lr = LogisticRegression(penalty=None, solver="lbfgs", max_iter=1000)
        lr.fit(lo, y)
        return float(lr.coef_[0][0]), float(lr.intercept_[0])
    except Exception:
        return np.nan, np.nan


def metrics_at_threshold(y, p, thr):
    yp = (p >= thr).astype(int)
    tn, fp, fn, tp = confusion_matrix(y, yp, labels=[0, 1]).ravel()
    sens = tp / (tp + fn) if (tp + fn) else np.nan
    spec = tn / (tn + fp) if (tn + fp) else np.nan
    ppv = tp / (tp + fp) if (tp + fp) else np.nan
    npv = tn / (tn + fn) if (tn + fn) else np.nan
    return dict(threshold=thr, sens=sens, spec=spec, ppv=ppv, npv=npv,
                tp=int(tp), fp=int(fp), tn=int(tn), fn=int(fn))


def youden_threshold(y, p):
    from sklearn.metrics import roc_curve
    fpr, tpr, thr = roc_curve(y, p)
    j = tpr - fpr
    return float(thr[np.argmax(j)])


def threshold_at_sensitivity(y, p, target=0.90):
    from sklearn.metrics import roc_curve
    fpr, tpr, thr = roc_curve(y, p)
    ok = np.where(tpr >= target)[0]
    return float(thr[ok[-1]]) if len(ok) else 0.0


def net_benefit(y, p, pt):
    """决策曲线单点 net benefit."""
    n = len(y)
    yp = (p >= pt).astype(int)
    tp = np.sum((yp == 1) & (y == 1))
    fp = np.sum((yp == 1) & (y == 0))
    if pt >= 1:
        return 0.0
    return tp / n - fp / n * (pt / (1 - pt))


def decision_curve(y, p, pts=None):
    if pts is None:
        pts = np.arange(0.05, 0.41, 0.05)
    prev = float(np.mean(y))
    out = []
    for pt in pts:
        nb_model = net_benefit(y, p, pt)
        nb_all = prev - (1 - prev) * (pt / (1 - pt)) if pt < 1 else 0.0
        out.append(dict(pt=round(float(pt), 3), nb_model=float(nb_model),
                        nb_all=float(nb_all), nb_none=0.0))
    return out


def full_report(y, p, n_boot=1000, seed=42):
    y = np.asarray(y).astype(int)
    p = np.asarray(p).astype(float)
    auroc = roc_auc_score(y, p)
    auprc = average_precision_score(y, p)
    brier = brier_score_loss(y, p)
    slope, intercept = calibration_slope_intercept(y, p)
    auroc_ci = bootstrap_ci(y, p, roc_auc_score, n_boot, seed)
    auprc_ci = bootstrap_ci(y, p, average_precision_score, n_boot, seed)
    thr_y = youden_threshold(y, p)
    thr_s90 = threshold_at_sensitivity(y, p, 0.90)
    rep = dict(
        auroc=float(auroc), auroc_ci=auroc_ci,
        auprc=float(auprc), auprc_ci=auprc_ci,
        brier=float(brier), calib_slope=slope, calib_intercept=intercept,
        prevalence=float(np.mean(y)),
        at_youden=metrics_at_threshold(y, p, thr_y),
        at_sens90=metrics_at_threshold(y, p, thr_s90),
        dca=decision_curve(y, p),
    )
    return rep
