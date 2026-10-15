#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
03b_external_transform.py  (v2 feature pipeline - external validation transform)
Author: mihao for zhaoyang    Date: 2026-07-29

GOAL: transform an EXTERNAL cohort (eICU / SICdb) assembled_A into a model-ready
      *_external_final.npz using the LOCKED MIMIC artifacts. NEVER refit anything.

Locked MIMIC artifacts consumed (from --mimic_dataset, default dataset_A):
  * feature_meta.json  -> ts_feature_cols (order+set), dropped_ts_cols,
                          train_median_ts, static_feature_cols(_final), n_grid,
                          diag_embed_dim
  * ts_robust_scaler.pkl      -> transform time-series numeric cols
  * static_robust_scaler.pkl  -> transform static numeric cols
  * diag_pca.pkl              -> (full diag mode) PCA transform of BERT emb
  * static_train_median (in feature_meta) -> static numeric median fallback

Cross-cohort robustness (differs from 03 which fits on MIMIC train):
  * gender: MIMIC 'M/F'; eICU already 0/1 numeric; SICdb 'M/F'. Unified ->
    gender_bin = 1 if male. Handles both string and numeric encodings.
  * race:   race_bin = 1 if White/Caucasian else 0 (FIXED semantic, not per-cohort
            top). SICdb race all-NaN -> race_bin=0 (documented limitation).
  * ckd_stage / dialysis_dep: same regex as MIMIC. SICdb diag is German ->
    will under-detect (documented limitation).
  * sepsis3_bin: t/true/1 -> 1.

Imputation / scaling strictly reuse MIMIC train stats:
  * drop the SAME ts cols as MIMIC (feature_meta.dropped_ts_cols)
  * per-stay ffill/bfill, then MIMIC train_median_ts fallback (NOT external median)
  * physiologic derivation identical to 03 (po2 by spo2, be = bicarb-24)
  * ts/static RobustScaler = MIMIC locked, transform only

diag modes:
  * --no_diag (fast): diag PCA block = zeros(diag_embed_dim). Matches how 04
    back-fills missing diag (np.zeros), so the locked ckpt input dim is preserved.
  * --diag (full): encode diag_text with SAME frozen BioClinicalBERT mean-pool,
    then MIMIC diag_pca.pkl transform (NOT refit).

Usage:
  python 03b_external_transform.py --indir <cohort>/assembled_A \
      --outdir <cohort>/dataset_A_ext --mimic_dataset ../mimic/.../dataset_A \
      --cohort eicu --no_diag
"""
import argparse
import json
import os
import re

import joblib
import numpy as np
import pandas as pd

# vaso/vent: filled 0 in 02, semantic = no drug / no vent (same as 03)
NO_IMPUTE_COLS = [
    "norepinephrine", "epinephrine", "dopamine", "dobutamine",
    "phenylephrine", "vasopressin", "milrinone", "vent_level",
]
STATIC_NUM_COLS = [
    "age", "obs_hours", "weight", "cr_baseline", "sapsii", "sofa_baseline",
]


def parse_ckd_stage(text):
    if pd.isna(text):
        return 0
    s = str(text).lower()
    nums = [int(x) for x in re.findall(r"ckd\s*([1-5])", s)]
    if nums:
        return max(nums)
    if "ckd" in s:
        return 1
    return 0


def gender_to_bin(v):
    """robust male=1. handles 'M'/'F', 'Male'/'Female', 1/0, '1.0'/'0.0'."""
    s = str(v).strip().lower()
    if s in ("m", "male", "1", "1.0"):
        return 1
    if s in ("f", "female", "0", "0.0"):
        return 0
    # numeric fallback
    try:
        return 1 if float(s) >= 0.5 else 0
    except (ValueError, TypeError):
        return 0


def race_to_bin(v):
    """FIXED semantic: white/caucasian = 1 else 0 (align MIMIC top_race=White)."""
    s = str(v).strip().lower()
    if "white" in s or "caucasian" in s:
        return 1
    return 0


def physio_impute(ts, feat_cols):
    t = ts.copy()
    if "po2" in feat_cols and "spo2" in feat_cols:
        m = t["po2"].isna()
        t.loc[m & (t["spo2"] >= 95), "po2"] = 95
        t.loc[m & (t["spo2"] < 95) & (t["spo2"] >= 90), "po2"] = 75
        t.loc[m & (t["spo2"] < 90) & (t["spo2"] >= 70), "po2"] = 50
        t.loc[m & (t["spo2"] < 70), "po2"] = 35
    if "baseexcess" in feat_cols and "bicarbonate_chem" in feat_cols:
        t.loc[t["baseexcess"].isna(), "baseexcess"] = t["bicarbonate_chem"] - 24
    return t


# B9 FIX (2026-08-03): SICdb diag_text is NOT a bare ICD code -- it is
# "<ICD-10 code> <German description>", e.g.
#     "I71.0 Dissektion der Aorta [jeder Abschnitt]"
# The old implementation split on whitespace and appended every non-ICD token
# verbatim, so the German prose leaked straight into the text handed to
# BioClinicalBERT (an English-only clinical model). Measured on 1198 SICdb
# stays: 522 rows (43.6%) still contained umlauts after "mapping", and mean
# text length was 81.7 chars vs 35.9 for the clean version -- i.e. more than
# half the tokens were untranslated German noise.
# Fix: extract ICD-10 codes with a regex and discard the surrounding prose.
ICD10_CODE_RE = re.compile(r"\b([A-Z]\d{2}(?:\.\d+)?)\b")


def map_icd_to_english(diag, verbose=True):
    """SICdb diag_text = "<ICD-10 code> <German description>".

    Pull out the ICD-10 code(s) by regex, map each to its WHO English title via
    simple_icd_10 (falling back to the 3-char parent category), de-duplicate,
    and DROP the German description entirely. This makes SICdb diag text
    genuinely comparable to the English clinical text in MIMIC/eICU.

    If no valid code can be recovered the raw string is kept, so a row never
    silently becomes empty.
    """
    import simple_icd_10 as icd

    def _title(c):
        for v in (c, c.replace(".", "")):
            if icd.is_valid_item(v):
                return icd.get_description(v)
        pre = c.split(".")[0]
        return icd.get_description(pre) if icd.is_valid_item(pre) else None

    stats = {"fallback": 0}

    def one(code):
        s = str(code).strip()
        if not s:
            return ""
        titles, seen = [], set()
        for c in ICD10_CODE_RE.findall(s):
            t = _title(c)
            if t and t not in seen:
                seen.add(t)
                titles.append(t)
        if not titles:
            stats["fallback"] += 1
            return s
        return ", ".join(titles)

    d = diag.copy()
    d["diag_text"] = d["diag_text"].fillna("").apply(one)
    if verbose:
        n_ok = int((d["diag_text"].str.len() > 0).sum())
        print(f"    ICD->EN mapped: {n_ok}/{len(d)} non-empty, "
              f"{stats['fallback']} kept raw (no ICD-10 code found); ex:",
              d.loc[d["diag_text"].str.len() > 0, "diag_text"].head(3).tolist(), flush=True)
    return d


def encode_diag_pca(diag, sids, mimic_dataset, pca_dim, use_gpu=True, icd_map=False):
    """Full diag: same frozen BioClinicalBERT mean-pool + MIMIC PCA transform."""
    import glob
    import torch
    from transformers import AutoModel, AutoTokenizer

    def _resolve_local_model():
        root = os.path.join(
            os.path.expanduser("~"), ".cache", "huggingface", "hub",
            "models--emilyalsentzer--Bio_ClinicalBERT", "snapshots")
        for snap in glob.glob(os.path.join(root, "*")):
            if os.path.exists(os.path.join(snap, "model.safetensors")) and \
               os.path.exists(os.path.join(snap, "config.json")) and \
               os.path.exists(os.path.join(snap, "vocab.txt")):
                return snap
        return "emilyalsentzer/Bio_ClinicalBERT"

    diag = diag.copy()
    if icd_map:
        diag = map_icd_to_english(diag)
    diag["diag_text"] = diag["diag_text"].fillna("")
    uniq = diag["diag_text"].drop_duplicates().tolist()
    device = torch.device("cuda" if (use_gpu and torch.cuda.is_available()) else "cpu")
    print("    diag encode device=", device, "unique=", len(uniq), flush=True)
    src = _resolve_local_model()
    tok = AutoTokenizer.from_pretrained(src)
    model = AutoModel.from_pretrained(src, use_safetensors=True).to(device)
    model.eval()
    parts = []
    bs = 128
    with torch.no_grad():
        for i in range(0, len(uniq), bs):
            batch = [t if isinstance(t, str) and t.strip() else "" for t in uniq[i:i + bs]]
            enc = tok(batch, truncation=True, max_length=128,
                      padding="max_length", return_tensors="pt").to(device)
            hidden = model(**enc).last_hidden_state
            m = enc["attention_mask"].unsqueeze(-1).float()
            emb = ((hidden * m).sum(1) / m.sum(1).clamp(min=1e-9)).cpu().numpy().astype(np.float32)
            parts.append(emb)
    uemb = np.vstack(parts).astype(np.float32)
    text2emb = {t: uemb[i] for i, t in enumerate(uniq)}
    emb = np.vstack([text2emb[t] for t in diag["diag_text"]]).astype(np.float32)
    pca = joblib.load(os.path.join(mimic_dataset, "diag_pca.pkl"))
    emb_pca = pca.transform(emb).astype(np.float32)
    stay2pca = {sid: emb_pca[i] for i, sid in enumerate(diag["stay_id"].tolist())}
    return np.vstack([stay2pca.get(s, np.zeros(pca_dim, np.float32)) for s in sids]).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True, help="external assembled_A dir")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--mimic_dataset", required=True, help="locked MIMIC dataset_A dir")
    ap.add_argument("--cohort", required=True, choices=["eicu", "sicdb"])
    ap.add_argument("--no_diag", action="store_true", help="fast: diag block = zeros")
    ap.add_argument("--icd_map", action="store_true",
                    help="map ICD-10 codes -> English titles before BERT (SICdb)")
    ap.add_argument("--no_gpu", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    # ---- locked MIMIC artifacts ----
    fmeta = json.load(open(os.path.join(args.mimic_dataset, "feature_meta.json"), encoding="utf-8"))
    n_grid = fmeta["n_grid"]
    feat_cols = fmeta["ts_feature_cols"]           # final kept ts cols (order matters)
    train_median_ts = pd.Series(fmeta["train_median_ts"])
    static_med = fmeta["static_train_median"]
    diag_dim = fmeta.get("diag_embed_dim", 32)
    static_num = [c for c in STATIC_NUM_COLS if c in fmeta["static_feature_cols"]]
    ts_scaler = joblib.load(os.path.join(args.mimic_dataset, "ts_robust_scaler.pkl"))
    st_scaler = joblib.load(os.path.join(args.mimic_dataset, "static_robust_scaler.pkl"))
    scale_cols = [c for c in feat_cols if c != "vent_level"]
    print(f">>> [{args.cohort}] locked MIMIC: n_ts={len(feat_cols)}, n_grid={n_grid}, "
          f"diag_dim={diag_dim}, static_num={static_num}")

    # ---- external data ----
    meta_ext = json.load(open(os.path.join(args.indir, "meta.json"), encoding="utf-8"))
    assert meta_ext["n_grid"] == n_grid, f"n_grid mismatch {meta_ext['n_grid']} vs {n_grid}"
    ts = pd.read_parquet(os.path.join(args.indir, "ts_wide.parquet"))
    static = pd.read_parquet(os.path.join(args.indir, "static.parquet"))

    # ---- align ts columns to MIMIC kept set (add missing as NaN, keep order) ----
    for c in feat_cols:
        if c not in ts.columns:
            ts[c] = np.nan
            print(f"    [warn] ts col missing in external, filled NaN: {c}")
    impute_cols = [c for c in feat_cols if c not in NO_IMPUTE_COLS]

    # ---- physio derive ----
    ts = physio_impute(ts, feat_cols)

    # ---- padding + per-stay ffill/bfill + MIMIC train_median fallback ----
    # B1 FIX (2026-08-03): sort ascending. `mask` is built in MultiIndex(all_ids)
    # order while ts_arr is built after sort_values(["stay_id","hour"]); if all_ids
    # is not ascending the two tensors describe different stays (silent
    # corruption). External static.parquet comes from `SELECT * FROM akd_v2_static`
    # with no ORDER BY, so ascending order is not guaranteed by PostgreSQL.
    all_ids = sorted(static["stay_id"].tolist())
    full_index = pd.MultiIndex.from_product([all_ids, range(n_grid)], names=["stay_id", "hour"])
    ts_full = ts.set_index(["stay_id", "hour"]).reindex(full_index)
    mask = (~ts_full[feat_cols].isna()).astype(np.float32)
    for c in NO_IMPUTE_COLS:
        if c in feat_cols:
            mask[c] = 1.0
    ts_full = ts_full.reset_index()
    # FIXED 20260813 -- CROSS-STAY BFILL LEAK. groupby().ffill() returns a frame
    # WITHOUT the grouping key, so the chained .bfill() used to run GLOBALLY and
    # cross stay boundaries: a stay whose column was entirely missing inherited
    # the NEXT patient value instead of the locked train median. Footprint was
    # 25.0% of stay x column cells in eICU, 20.3% in SICdb, 16.2% in MIMIC
    # internal (70-99% of stays touched). transform() keeps both fills inside
    # the group -- do NOT revert to the chained form.
    ts_full[impute_cols] = ts_full.groupby("stay_id")[impute_cols].transform(
        lambda s: s.ffill().bfill())
    for c in NO_IMPUTE_COLS:
        if c in feat_cols:
            ts_full[c] = ts_full[c].fillna(0)
    ts_full[impute_cols] = ts_full[impute_cols].fillna(train_median_ts)  # MIMIC median
    ts_full[feat_cols] = ts_full[feat_cols].fillna(0)

    # ---- ts scaler transform (locked) ----
    ts_full[scale_cols] = ts_scaler.transform(ts_full[scale_cols])

    # ---- static feature build (cross-cohort robust) ----
    df = static.copy()
    df["gender_bin"] = df["gender"].apply(gender_to_bin)
    df["race_bin"] = df["race"].apply(race_to_bin)
    df["sepsis3_bin"] = df["sepsis3"].astype(str).str.lower().isin(["true", "1", "t"]).astype(int)
    df["ckd_stage"] = df["kd_diagnosis"].apply(parse_ckd_stage)
    df["dialysis_dep"] = df["icd_kd_diagnosis"].astype(str).str.lower().str.contains(
        "dependence on renal dialysis").astype(int)
    # numeric fallback: MIMIC train median (NOT external)
    for c in static_num:
        if c in df.columns:
            df[c] = df[c].fillna(static_med.get(c, 0.0))
        else:
            df[c] = static_med.get(c, 0.0)
    df[static_num] = st_scaler.transform(df[static_num])
    static_feat_cols = fmeta["static_feature_cols"]  # 11 base cols, order locked
    for c in static_feat_cols:
        if c not in df.columns:
            df[c] = 0.0
            print(f"    [warn] static col missing, filled 0: {c}")

    # ---- assemble tensors ----
    ts_full = ts_full.sort_values(["stay_id", "hour"])
    F = len(feat_cols)
    ts_arr = ts_full[feat_cols].to_numpy(np.float32).reshape(-1, n_grid, F)
    mask_arr = mask.to_numpy(np.float32).reshape(-1, n_grid, F)
    ids_order = ts_full["stay_id"].to_numpy().reshape(-1, n_grid)[:, 0]

    df = df.set_index("stay_id").loc[ids_order].reset_index()
    static_base = df[static_feat_cols].to_numpy(np.float32)
    y = df["akd_flag"].to_numpy(np.int64)

    # ---- diag block ----
    if args.no_diag:
        diag_feat = np.zeros((len(ids_order), diag_dim), np.float32)
        print(">>> diag: ZERO block (fast mode)")
    else:
        diag = pd.read_parquet(os.path.join(args.indir, "diag.parquet"))
        diag_feat = encode_diag_pca(diag, ids_order, args.mimic_dataset, diag_dim,
                                    use_gpu=not args.no_gpu, icd_map=args.icd_map)
        print(">>> diag: full BERT + MIMIC PCA transform", diag_feat.shape)
    static_arr = np.concatenate([static_base, diag_feat], axis=1)

    tag = "nodiag" if args.no_diag else "diag"
    out = os.path.join(args.outdir, f"external_final_{tag}.npz")
    np.savez_compressed(out, X_ts=ts_arr, mask=mask_arr, X_static=static_arr,
                        y=y, stay_id=ids_order)
    print(f">>> saved {out}")
    print(f"    X_ts={ts_arr.shape}, X_static={static_arr.shape} "
          f"(base {static_base.shape[1]} + diag {diag_feat.shape[1]}), "
          f"AKD+={int(y.sum())}/{len(y)} ({y.mean():.1%})")
    # sanity vs locked model expected dim
    exp = fmeta["n_static_features_final"]
    assert static_arr.shape[1] == exp, f"static dim {static_arr.shape[1]} != locked {exp}"
    print(f"    static dim OK = {exp} (matches locked ckpt)")


if __name__ == "__main__":
    main()
