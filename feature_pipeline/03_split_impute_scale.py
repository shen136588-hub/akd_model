#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
03_split_impute_scale.py  (v2 特征管线 · 第 3 步)
Author: 米好 for 朝阳    Date: 2026-07-26

作用:
  在 02 组装好的宽表基础上, 完成 (严格无泄漏):
    1. 患者级 (subject_id) 分层 60/20/20 划分 train/val/test
    2. 高缺失时序列剔除 (阈值在 TRAIN 上计算)
    3. 时序插补: 组内 ffill+bfill → TRAIN median 兜底 (median 只在 train 拟合)
       + 生理衍生填补 (po2 按 spo2 分段; be = bicarb-24; lactate 按 be 分段)
    4. mask 通道: 记录每个 (stay,hour,feat) 是否原始观测 (1) vs 填补/padding (0)
    5. padding: 每 stay reindex 到 0..n_grid-1 满格
    6. 静态特征: 数值 RobustScaler(fit train) + 分类编码 + ckd/dialysis 解析
    7. 落盘 npz (train/val/test) + 拟合工件 (impute_stats/scaler/feature_cols/split)

修复的泄漏点 (对齐 严谨课题重设计.md 二.2/3/4):
  * split 按 subject_id, 同一患者不跨集
  * median / scaler / 高缺失阈值 全部 fit-on-train, val/test 仅 transform
  * 独立 test 集 (20%), 不参与任何调参/early-stop

用法:
  python 03_split_impute_scale.py --indir assembled_A --outdir dataset_A --seed 42
  python 03_split_impute_scale.py --indir assembled_B --outdir dataset_B --seed 42
"""
import argparse
import json
import os
import re

import joblib
import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import RobustScaler

# vaso/vent 在 02 已填 0, 语义=未用药/未通气, 不参与缺失剔除与 median 兜底
NO_IMPUTE_COLS = [
    "norepinephrine", "epinephrine", "dopamine", "dobutamine",
    "phenylephrine", "vasopressin", "milrinone", "vent_level",
]

# 静态数值列 (RobustScaler) - v3 删 charlson_comorbidity_index
STATIC_NUM_COLS = [
    "age", "obs_hours", "weight", "cr_baseline", "sapsii", "sofa_baseline",
]
# 静态二元列 (0/1) - v3 删合并症/Charlson, 已清空
STATIC_BIN_COLS = []


def parse_ckd_stage(text):
    """从 kd_diagnosis 文本提取 CKD 分级: 取最大数字分级; 仅 unspecified→1; 无 ckd→0."""
    if pd.isna(text):
        return 0
    s = str(text).lower()
    nums = [int(x) for x in re.findall(r"ckd\s*([1-5])", s)]
    if nums:
        return max(nums)
    if "ckd" in s:
        return 1  # unspecified CKD 占位为轻度
    return 0


def build_static(static, train_ids):
    """静态特征工程. 数值列 scaler 仅在 train fit."""
    df = static.copy()
    # gender M/F → 1/0
    df["gender_bin"] = (df["gender"].astype(str).str.upper().str[0] == "M").astype(int)
    # race: 白人 vs 其它 (原始仅 2 类)
    races = df["race"].astype(str)
    top_race = races.value_counts().index[0]
    df["race_bin"] = (races == top_race).astype(int)
    # sepsis3 bool → int
    df["sepsis3_bin"] = df["sepsis3"].astype(str).str.lower().isin(["true", "1", "t"]).astype(int)
    # ckd 分级 + 透析依赖
    df["ckd_stage"] = df["kd_diagnosis"].apply(parse_ckd_stage)
    df["dialysis_dep"] = df["icd_kd_diagnosis"].astype(str).str.lower().str.contains(
        "dependence on renal dialysis").astype(int)

    # 数值列缺失: train median 兜底
    num_cols = [c for c in STATIC_NUM_COLS if c in df.columns]
    train_mask = df["stay_id"].isin(train_ids)
    med = df.loc[train_mask, num_cols].median()
    df[num_cols] = df[num_cols].fillna(med)

    # RobustScaler fit on train
    scaler = RobustScaler()
    scaler.fit(df.loc[train_mask, num_cols])
    df[num_cols] = scaler.transform(df[num_cols])

    static_feat_cols = (
        num_cols
        + STATIC_BIN_COLS
        + ["gender_bin", "race_bin", "sepsis3_bin", "ckd_stage", "dialysis_dep"]
    )
    static_feat_cols = [c for c in static_feat_cols if c in df.columns]
    return df, static_feat_cols, scaler, med.to_dict()


def physio_impute(ts, feat_cols):
    """生理衍生填补 (在 pivot 宽表上, 逐行规则, 不引入跨集统计)."""
    t = ts.copy()
    # po2 按 spo2 分段 (仅当两列都在)
    if "po2" in feat_cols and "spo2" in feat_cols:
        m = t["po2"].isna()
        t.loc[m & (t["spo2"] >= 95), "po2"] = 95
        t.loc[m & (t["spo2"] < 95) & (t["spo2"] >= 90), "po2"] = 75
        t.loc[m & (t["spo2"] < 90) & (t["spo2"] >= 70), "po2"] = 50
        t.loc[m & (t["spo2"] < 70), "po2"] = 35
    # be = bicarbonate_chem - 24
    if "baseexcess" in feat_cols and "bicarbonate_chem" in feat_cols:
        t.loc[t["baseexcess"].isna(), "baseexcess"] = t["bicarbonate_chem"] - 24
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--split_ids", default=None,
                    help="reuse an existing split_ids.json instead of re-randomising"
                         " (required when comparing against locked artifacts)")
    ap.add_argument("--miss_thresh", type=float, default=0.95,
                    help="train 缺失率 > 此值的时序列剔除")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    meta = json.load(open(os.path.join(args.indir, "meta.json"), encoding="utf-8"))
    n_grid = meta["n_grid"]
    ts = pd.read_parquet(os.path.join(args.indir, "ts_wide.parquet"))
    static = pd.read_parquet(os.path.join(args.indir, "static.parquet"))

    # ------------------------------------------------------------------
    # 1. 患者级分层划分 60/20/20
    # ------------------------------------------------------------------
    print(">>> 1. subject_id 患者级分层 60/20/20")
    pat = static[["subject_id", "stay_id", "akd_flag"]].drop_duplicates("stay_id")
    # 患者级标签 (一个 subject 取其任一 stay 的 akd; 这里 stayid_order=1 基本一人一 stay)
    pat_lab = pat.groupby("subject_id")["akd_flag"].max().reset_index()
    if args.split_ids:
        # ADDED 20260813: reuse a locked split so a rebuild stays comparable
        # with the artifacts trained before it (see bfill-leak fix).
        with open(args.split_ids, encoding="utf-8") as f:
            locked = json.load(f)
        stay2split = {}
        for k in ["train", "val", "test"]:
            for sid in locked[k]:
                stay2split[int(sid)] = k
        have = set(static["stay_id"].astype(int))
        want = set(stay2split)
        assert have == want, (
            "cohort differs from the locked split: "
            "only_here=%d only_locked=%d"
            % (len(have - want), len(want - have)))
        static["split"] = static["stay_id"].astype(int).map(stay2split)
        print("    reused locked split from %s" % args.split_ids)
        # a patient must not straddle two splits
        chk = static.groupby("subject_id")["split"].nunique()
        assert int(chk.max()) == 1, "locked split leaks across subjects"
    else:
        tr_sub, tmp_sub = train_test_split(
            pat_lab, test_size=0.4, random_state=args.seed,
            stratify=pat_lab["akd_flag"])
        val_sub, te_sub = train_test_split(
            tmp_sub, test_size=0.5, random_state=args.seed,
            stratify=tmp_sub["akd_flag"])
        sub2split = {}
        for s in tr_sub["subject_id"]:
            sub2split[s] = "train"
        for s in val_sub["subject_id"]:
            sub2split[s] = "val"
        for s in te_sub["subject_id"]:
            sub2split[s] = "test"
        static["split"] = static["subject_id"].map(sub2split)
    split_ids = {
        k: static.loc[static["split"] == k, "stay_id"].tolist()
        for k in ["train", "val", "test"]
    }
    train_ids = set(split_ids["train"])
    for k in ["train", "val", "test"]:
        n = len(split_ids[k])
        pos = int(static.loc[static["split"] == k, "akd_flag"].sum())
        print(f"    {k}: {n} stays, AKD+={pos} ({pos / n:.1%})")

    # ------------------------------------------------------------------
    # 2. 高缺失时序列剔除 (阈值在 train 上算)
    # ------------------------------------------------------------------
    print(">>> 2. 高缺失时序列剔除 (train)")
    feat_all = [c for c in meta["ts_feature_cols"] if c in ts.columns]
    impute_cols = [c for c in feat_all if c not in NO_IMPUTE_COLS]
    ts_train = ts[ts["stay_id"].isin(train_ids)]
    miss_train = ts_train[impute_cols].isna().mean()
    drop_cols = miss_train[miss_train > args.miss_thresh].index.tolist()
    print(f"    剔除 (train 缺失率>{args.miss_thresh:.0%}): {drop_cols}")
    feat_cols = [c for c in feat_all if c not in drop_cols]
    ts = ts[["stay_id", "hour"] + feat_cols]
    impute_cols = [c for c in impute_cols if c not in drop_cols]

    # ------------------------------------------------------------------
    # 3. 生理衍生填补 + 记录原始观测 mask (在 padding 前)
    # ------------------------------------------------------------------
    print(">>> 3. 生理衍生填补 + 原始 mask")
    ts = physio_impute(ts, feat_cols)

    # ------------------------------------------------------------------
    # 4. padding 到满格 + 组内 ffill/bfill + train median 兜底
    #    mask: 原始观测(非NaN且非padding)=1
    # ------------------------------------------------------------------
    print(">>> 4. padding + 组内 ffill/bfill + train median 兜底")
    train_median = ts[ts["stay_id"].isin(train_ids)][impute_cols].median()

    # B1 FIX (2026-08-03): sort all_ids ascending.
    # `mask` is taken from ts_full in MultiIndex (all_ids) order, but ts_full is
    # later reset_index().sort_values(["stay_id","hour"]) before reshaping into
    # X_ts. If all_ids were not already ascending, mask rows and X_ts rows would
    # describe DIFFERENT stays -> silent data corruption.
    # static["stay_id"] came from `SELECT * FROM akd_v2_static` with NO ORDER BY,
    # so its order is not guaranteed by PostgreSQL (it only happened to be
    # ascending). Sorting here makes the two orders provably identical.
    all_ids = sorted(static["stay_id"].tolist())
    full_index = pd.MultiIndex.from_product(
        [all_ids, range(n_grid)], names=["stay_id", "hour"])
    ts_full = ts.set_index(["stay_id", "hour"]).reindex(full_index)
    # mask: reindex 后非 NaN 即原始观测
    mask = (~ts_full[feat_cols].isna()).astype(np.float32)
    # vaso/vent 的 0 是真实语义, mask 视为观测
    for c in NO_IMPUTE_COLS:
        if c in feat_cols:
            mask[c] = 1.0
    ts_full = ts_full.reset_index()

    # 组内 ffill/bfill (仅对 impute_cols; vaso/vent 已在 02 填 0, reindex 后的新行需补 0)
    # FIXED 20260813 -- CROSS-STAY BFILL LEAK. groupby().ffill() returns a frame
    # WITHOUT the grouping key, so the chained .bfill() used to run GLOBALLY and
    # cross stay boundaries: a stay whose column was entirely missing inherited
    # the NEXT patient value instead of the train median. This one also affected
    # TRAINING (16.2% of stay x column cells, 70.3% of stays). transform() keeps
    # both fills inside the group -- do NOT revert to the chained form.
    ts_full[impute_cols] = (
        ts_full.groupby("stay_id")[impute_cols].transform(
            lambda s: s.ffill().bfill())
    )
    # vaso/vent padding 行填 0
    for c in NO_IMPUTE_COLS:
        if c in feat_cols:
            ts_full[c] = ts_full[c].fillna(0)
    # 仍缺 (整段全空) → train median
    ts_full[impute_cols] = ts_full[impute_cols].fillna(train_median)
    # 兜底: 万一 median 也 NaN (train 该列极端) → 0
    ts_full[feat_cols] = ts_full[feat_cols].fillna(0)

    # ------------------------------------------------------------------
    # 5. 时序 RobustScaler (fit train, 仅数值时序; vaso/vent 也一并缩放除外 vent_level)
    # ------------------------------------------------------------------
    print(">>> 5. 时序 RobustScaler (fit train)")
    scale_cols = [c for c in feat_cols if c != "vent_level"]
    ts_scaler = RobustScaler()
    tr_rows = ts_full["stay_id"].isin(train_ids)
    ts_scaler.fit(ts_full.loc[tr_rows, scale_cols])
    ts_full[scale_cols] = ts_scaler.transform(ts_full[scale_cols])

    # ------------------------------------------------------------------
    # 6. 静态特征
    # ------------------------------------------------------------------
    print(">>> 6. 静态特征工程 (scaler fit train)")
    static2, static_feat_cols, st_scaler, st_med = build_static(static, train_ids)

    # ------------------------------------------------------------------
    # 7. 组装张量 (N, T, F) 并按 split 落盘
    # ------------------------------------------------------------------
    print(">>> 7. 组装张量 + 落盘 npz")
    F = len(feat_cols)
    ts_full = ts_full.sort_values(["stay_id", "hour"])
    # reshape: 每 stay n_grid 行
    ts_arr = ts_full[feat_cols].to_numpy(np.float32).reshape(-1, n_grid, F)
    mask_arr = mask.to_numpy(np.float32).reshape(-1, n_grid, F)
    ids_order = ts_full["stay_id"].to_numpy().reshape(-1, n_grid)[:, 0]

    # 对齐静态 + 标签
    static2 = static2.set_index("stay_id").loc[ids_order].reset_index()
    static_arr = static2[static_feat_cols].to_numpy(np.float32)
    y = static2["akd_flag"].to_numpy(np.int64)
    split_arr = static2["split"].to_numpy()

    for k in ["train", "val", "test"]:
        sel = split_arr == k
        np.savez_compressed(
            os.path.join(args.outdir, f"{k}.npz"),
            X_ts=ts_arr[sel], mask=mask_arr[sel],
            X_static=static_arr[sel], y=y[sel],
            stay_id=ids_order[sel],
        )
        print(f"    {k}: X_ts={ts_arr[sel].shape}, X_static={static_arr[sel].shape}, "
              f"AKD+={int(y[sel].sum())}/{sel.sum()}")

    # 工件
    joblib.dump(ts_scaler, os.path.join(args.outdir, "ts_robust_scaler.pkl"))
    joblib.dump(st_scaler, os.path.join(args.outdir, "static_robust_scaler.pkl"))
    artifacts = {
        "plan": meta["plan"],
        "n_grid": n_grid,
        "ts_feature_cols": feat_cols,
        "n_ts_features": F,
        "static_feature_cols": static_feat_cols,
        "n_static_features": len(static_feat_cols),
        "dropped_ts_cols": drop_cols,
        "miss_thresh": args.miss_thresh,
        "seed": args.seed,
        "train_median_ts": {k: float(v) for k, v in train_median.items()},
        "static_train_median": {k: float(v) for k, v in st_med.items()},
        "split_counts": {k: len(v) for k, v in split_ids.items()},
    }
    with open(os.path.join(args.outdir, "feature_meta.json"), "w", encoding="utf-8") as f:
        json.dump(artifacts, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.outdir, "split_ids.json"), "w", encoding="utf-8") as f:
        json.dump(split_ids, f, ensure_ascii=False, indent=2, default=int)

    print(">>> 完成.")
    print(f"    时序特征 {F} 个, 静态特征 {len(static_feat_cols)} 个, 时间步 {n_grid}")


if __name__ == "__main__":
    main()
