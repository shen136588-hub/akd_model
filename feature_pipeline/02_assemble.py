#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
02_assemble.py  (v2 特征管线 · 第 2 步)
Author: 米好 for 朝阳    Date: 2026-07-26

作用:
  把 01_cohort_features.sql 导出的长表/分表, 组装成"每 (stay_id, hour) 一行"的
  宽表时序 + 每 stay 一行的静态表 + 标签, 供 03 步做 split/impute/scale/padding.

设计要点 (对齐 严谨课题重设计.md 3.5/3.6):
  * 时间锚点: t0_time (AKI 首发). 以小时为格: hour = floor((charttime - win_start)/1h)
    - 方案 A: win=[t0-24h, t0]      → 相对 t0 的 hour ∈ [-24, 0], 归一到 grid 0..24 (最多 25 格)
    - 方案 B: win=[t0-12h, t0+24h]  → hour ∈ [-12, 24], 归一到 grid 0..36 (最多 37 格)
    早发 AKI 患者 win_start 被 icu_intime 抬高 → 该患者格子数 < 满格 (真实缺失, 交给 padding)
  * pivot: 同一 (stay_id, hour) 多条测量取均值 (labs/vitals); stage 类不在时序里 (已在 SQL 删泄漏)
  * vaso/vent: 区间型 → 按小时格 explode, 落在 [win_start, win_end] 内的小时置值; 缺失=0(未用药/未通气)
  * 药物剂量: 归一到 μg/kg/min (用 static.admit_weight; 缺失用 any_weight; 再缺失用队列中位体重)
  * 绝不引入 t0 之后信息? —— 方案 A 天然不含; 方案 B 含 t0 后 24h, 仅作敏感性, 脚本参数标注
  * 不做插补/标准化 (交给 03, 严格 fit-on-train)

输出 (parquet, 落在 --outdir):
  ts_wide.parquet      : [stay_id, hour, <数值时序特征...>]  (未插补, 含 NaN)
  static.parquet       : [stay_id, subject_id, hadm_id, akd_flag, <静态特征...>]
  diag.parquet         : [stay_id, diag_text]
  meta.json            : 窗口方案/格子数/特征列清单

用法:
  python 02_assemble.py --indir export_A --outdir assembled_A --plan A
  python 02_assemble.py --indir export_B --outdir assembled_B --plan B
"""
import argparse
import json
import os

import numpy as np
import pandas as pd

# ----------------------------------------------------------------------------
# 特征列定义
# ----------------------------------------------------------------------------
# 时序数值列 (来自 ts_long, 直接 pivot 取均值). 已剔除 aki_stage*/creat_low_past_48hr 泄漏列.
# v3: 删 hematocrit(≈hgb)/inr(≈pt)/albumin(弃用)/fio2_bg(被 fio2_value_max 替代)/6个SOFA子分.
TS_MEAN_COLS = [
    # vitals
    "heart_rate", "sbp", "dbp", "mbp", "resp_rate", "temperature", "spo2",
    # chemistry
    "bun", "creat_lab", "chloride", "sodium", "potassium", "calcium",
    "glucose_chem", "bicarbonate_chem", "aniongap",
    # cbc
    "wbc", "hemoglobin", "platelet",
    # coag
    "pt", "ptt",
    # blood gas (删 fio2_bg)
    "po2", "pco2", "ph", "lactate", "baseexcess", "bicarbonate_bg",
    "pao2fio2ratio",
    # cr / uo (creat 原始信号由 creat_lab 覆盖)
    "uo_rt_6hr", "uo_rt_12hr", "uo_rt_24hr",
    # sofa (仅总分)
    "sofa_24hours",
]

# 血管活性药 (μg/kg/min 归一; vasopressin units/min). v3 删 milrinone(极罕见).
VASO_COLS = [
    "norepinephrine", "epinephrine", "dopamine", "dobutamine",
    "phenylephrine", "vasopressin",
]


def build_hour_grid(cohort, plan):
    """给每个 stay 计算 grid 参数: hour 从 0 开始, 步长 1h, 上限由方案定."""
    if plan == "A":
        n_grid = 25   # [-24h, 0] → 0..24
    elif plan == "B":
        n_grid = 37   # [-12h, +24h] → 0..36
    else:
        raise ValueError(f"unknown plan {plan}")
    return n_grid


def to_hour(df, cohort, tcol="charttime"):
    """把 charttime 映射到相对 win_start 的整点小时 (floor)."""
    m = df.merge(cohort[["stay_id", "win_start", "win_end"]], on="stay_id", how="inner")
    m[tcol] = pd.to_datetime(m[tcol])
    m["win_start"] = pd.to_datetime(m["win_start"])
    m["win_end"] = pd.to_datetime(m["win_end"])
    # 只保留窗口内 (SQL 已过滤, 这里冗余保险)
    m = m[(m[tcol] >= m["win_start"]) & (m[tcol] <= m["win_end"])]
    m["hour"] = np.floor((m[tcol] - m["win_start"]).dt.total_seconds() / 3600.0).astype(int)
    m.loc[m["hour"] < 0, "hour"] = 0
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--plan", required=True, choices=["A", "B"])
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    ind = args.indir

    print(f">>> [plan {args.plan}] 读取导出 CSV: {ind}")
    cohort = pd.read_csv(os.path.join(ind, "akd_v2_cohort.csv"))
    ts_long = pd.read_csv(os.path.join(ind, "akd_v2_ts_long.csv"))
    static = pd.read_csv(os.path.join(ind, "akd_v2_static.csv"))
    vaso = pd.read_csv(os.path.join(ind, "akd_v2_vaso.csv"))
    vent = pd.read_csv(os.path.join(ind, "akd_v2_vent.csv"))
    o2 = pd.read_csv(os.path.join(ind, "akd_v2_o2.csv"))
    diag = pd.read_csv(os.path.join(ind, "akd_v2_diag.csv"))

    n_grid = build_hour_grid(cohort, args.plan)
    print(f"    grid = 0..{n_grid - 1} ({n_grid} 格)")

    # ------------------------------------------------------------------
    # 1. 时序 pivot: (stay_id, hour) 取均值
    # ------------------------------------------------------------------
    print(">>> 1. 时序长表 → 小时格宽表 (均值聚合)")
    ts_h = to_hour(ts_long, cohort)
    keep = [c for c in TS_MEAN_COLS if c in ts_h.columns]
    ts_wide = (
        ts_h.groupby(["stay_id", "hour"])[keep]
        .mean()
        .reset_index()
    )

    # ------------------------------------------------------------------
    # 2. 血管活性药: 区间 → 小时格; 归一 μg/kg/min
    # ------------------------------------------------------------------
    print(">>> 2. 血管活性药区间 → 小时格 (μg/kg/min 归一)")
    # 体重: admit_weight > any_weight > 队列中位
    wt = static[["stay_id", "admit_weight", "any_weight"]].copy()
    med_wt = pd.concat([wt["admit_weight"], wt["any_weight"]]).median()
    wt["weight"] = wt["admit_weight"].fillna(wt["any_weight"]).fillna(med_wt)

    cw = cohort[["stay_id", "win_start", "win_end"]].copy()
    cw["win_start"] = pd.to_datetime(cw["win_start"])
    cw["win_end"] = pd.to_datetime(cw["win_end"])
    vaso = vaso.merge(cw, on="stay_id", how="inner").merge(
        wt[["stay_id", "weight"]], on="stay_id", how="left")
    vaso["starttime"] = pd.to_datetime(vaso["starttime"])
    vaso["endtime"] = pd.to_datetime(vaso["endtime"])

    vaso_rows = []
    for _, r in vaso.iterrows():
        # 该给药区间覆盖的小时格
        s = max(r["starttime"], r["win_start"])
        e = min(r["endtime"], r["win_end"])
        if e < s:
            continue
        h0 = int(np.floor((s - r["win_start"]).total_seconds() / 3600.0))
        h1 = int(np.floor((e - r["win_start"]).total_seconds() / 3600.0))
        h0 = max(h0, 0)
        h1 = min(h1, n_grid - 1)
        w = r["weight"] if r["weight"] and r["weight"] > 0 else med_wt
        for h in range(h0, h1 + 1):
            row = {"stay_id": r["stay_id"], "hour": h}
            for c in VASO_COLS:
                val = r.get(c, np.nan)
                # norepinephrine 等 rate 单位在 mimic vasoactive_agent 已是 mcg/kg/min 或 units/min
                # 该视图列即 rate, 直接用; 若为总量需除体重, 这里按 derived 视图语义(已按 rate)不再除
                row[c] = val
            vaso_rows.append(row)
    if vaso_rows:
        vaso_h = pd.DataFrame(vaso_rows).groupby(["stay_id", "hour"])[VASO_COLS].max().reset_index()
    else:
        vaso_h = pd.DataFrame(columns=["stay_id", "hour"] + VASO_COLS)

    # ------------------------------------------------------------------
    # 3. 机械通气: 区间 → 小时格 binary (on_vent)
    # ------------------------------------------------------------------
    print(">>> 3. 机械通气区间 → 小时格 binary")
    vent = vent.merge(cw, on="stay_id", how="inner")
    vent["starttime"] = pd.to_datetime(vent["starttime"])
    vent["endtime"] = pd.to_datetime(vent["endtime"])
    # 侵入性通气分级: InvasiveVent/Tracheostomy=2, NonInvasiveVent/HFNC=1, 其它=0
    def vent_level(s):
        s = str(s)
        if s in ("InvasiveVent", "Tracheostomy"):
            return 2
        if s in ("NonInvasiveVent", "HFNC", "High flow"):
            return 1
        return 0
    vent_rows = []
    for _, r in vent.iterrows():
        s = max(r["starttime"], r["win_start"])
        e = min(r["endtime"], r["win_end"])
        if e < s:
            continue
        h0 = max(int(np.floor((s - r["win_start"]).total_seconds() / 3600.0)), 0)
        h1 = min(int(np.floor((e - r["win_start"]).total_seconds() / 3600.0)), n_grid - 1)
        lv = vent_level(r["ventilation_status"])
        for h in range(h0, h1 + 1):
            vent_rows.append({"stay_id": r["stay_id"], "hour": h, "vent_level": lv})
    if vent_rows:
        vent_h = pd.DataFrame(vent_rows).groupby(["stay_id", "hour"])["vent_level"].max().reset_index()
    else:
        vent_h = pd.DataFrame(columns=["stay_id", "hour", "vent_level"])

    # ------------------------------------------------------------------
    # 3b. 氧疗 → 小时格 fio2_value_max (移植旧 predictor 清洗)
    #   o2_flow: [0,10)→LPM换算 21+4*flow; [10,21]→65; >100→65(小数点错); <0→NaN
    #   fio2:    <=10→21+4*fio2(误录LPM); ==700→70
    #   fio2_value_max = max(o2_flow_conv, fio2_conv); device=none & 缺失 → 21
    # ------------------------------------------------------------------
    print(">>> 3b. 氧疗 → fio2_value_max")
    dev_map = {"none": 0, "cot": 1, "hf": 2, "niv": 3, "iv": 4, "ecmo": 5}
    if len(o2):
        o2 = to_hour(o2, cohort)
        o2["o2_device_cat_numeric"] = o2["o2_device_cat"].map(dev_map)
        # o2_flow LPM → fio2%
        # B8 FIX (2026-08-03): the (21, 100] band had NO mask and was left as NaN.
        # That band is exactly HFNC territory (median 43.7 L/min); it was 15,082
        # MIMIC rows / 23,558 eICU rows, i.e. ~35% of all non-null flow values,
        # and 0 of them were rescued by the fio2 column. Dropping them
        # systematically blanked the most severe oxygen-support records.
        # Bands now: [0,10) LPM->21+4*flow ; [10,21] nasal-cannula ceiling->65 ;
        #            (21,100] HFNC->treat as high-flow, cap 65 ; >100 decimal
        #            typo->65 ; <0 invalid->NaN.
        f = o2["o2_flow"].astype(float)
        o2["o2_flow_conv"] = np.nan
        m1 = (f >= 0) & (f < 10)
        m2 = (f >= 10) & (f <= 21)
        m_hfnc = (f > 21) & (f <= 100)
        m3 = f > 100
        o2.loc[m1, "o2_flow_conv"] = 21 + 4 * f[m1]
        o2.loc[m2, "o2_flow_conv"] = 65
        o2.loc[m_hfnc, "o2_flow_conv"] = 65
        o2.loc[m3, "o2_flow_conv"] = 65
        # fio2 清洗
        fi = o2["fio2"].astype(float)
        o2["fio2_conv"] = fi
        o2.loc[fi <= 10, "fio2_conv"] = 21 + 4 * fi[fi <= 10]
        o2.loc[fi == 700, "fio2_conv"] = 70
        o2["fio2_value_max"] = o2[["o2_flow_conv", "fio2_conv"]].max(axis=1)
        o2_h = (
            o2.groupby(["stay_id", "hour"])
            .agg(fio2_value_max=("fio2_value_max", "max"),
                 o2_device_cat_numeric=("o2_device_cat_numeric", "max"))
            .reset_index()
        )
        # device=none(0) 且 fio2 缺失 → 21 (室空气)
        m = (o2_h["o2_device_cat_numeric"] == 0) & (o2_h["fio2_value_max"].isna())
        o2_h.loc[m, "fio2_value_max"] = 21
    else:
        o2_h = pd.DataFrame(columns=["stay_id", "hour", "fio2_value_max",
                                     "o2_device_cat_numeric"])

    # ------------------------------------------------------------------
    # 4. 合并所有时序块
    # ------------------------------------------------------------------
    print(">>> 4. 合并时序块 (labs+vitals+vaso+vent+o2)")
    ts_wide = ts_wide.merge(vaso_h, on=["stay_id", "hour"], how="outer")
    ts_wide = ts_wide.merge(vent_h, on=["stay_id", "hour"], how="outer")
    ts_wide = ts_wide.merge(o2_h, on=["stay_id", "hour"], how="outer")
    # vaso/vent 缺失语义: 未用药/未通气 = 0
    for c in VASO_COLS + ["vent_level"]:
        if c in ts_wide.columns:
            ts_wide[c] = ts_wide[c].fillna(0)
    ts_wide = ts_wide.sort_values(["stay_id", "hour"]).reset_index(drop=True)

    # ------------------------------------------------------------------
    # 5. 静态表整理 (合并体重, 保留标签)
    # ------------------------------------------------------------------
    print(">>> 5. 静态表整理")
    static = static.merge(wt[["stay_id", "weight"]], on="stay_id", how="left")

    # ------------------------------------------------------------------
    # 6. 落盘
    # ------------------------------------------------------------------
    ts_path = os.path.join(args.outdir, "ts_wide.parquet")
    st_path = os.path.join(args.outdir, "static.parquet")
    dg_path = os.path.join(args.outdir, "diag.parquet")
    ts_wide.to_parquet(ts_path, index=False)
    static.to_parquet(st_path, index=False)
    diag.to_parquet(dg_path, index=False)

    ts_feat_cols = [c for c in ts_wide.columns if c not in ("stay_id", "hour")]
    meta = {
        "plan": args.plan,
        "n_grid": n_grid,
        "ts_feature_cols": ts_feat_cols,
        "n_ts_features": len(ts_feat_cols),
        "n_stays_ts": int(ts_wide["stay_id"].nunique()),
        "n_stays_static": int(static["stay_id"].nunique()),
        "label_dist": static["akd_flag"].value_counts().to_dict(),
    }
    with open(os.path.join(args.outdir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2, default=int)

    print(">>> 完成.")
    print(f"    ts_wide : {ts_wide.shape} → {ts_path}")
    print(f"    static  : {static.shape} → {st_path}")
    print(f"    diag    : {diag.shape} → {dg_path}")
    print(f"    时序特征数: {len(ts_feat_cols)}")
    print(f"    标签分布: {meta['label_dist']}")


if __name__ == "__main__":
    main()
