# AKD Prediction: Multicenter External Validation of Machine Learning Models

Analysis code for the manuscript **"Development and Multicenter External Validation of
Machine Learning Models for Early Prediction of Acute Kidney Disease in Critically Ill
Patients with Acute Kidney Injury"** (under review).

The pipeline trains eight models spanning five classes on MIMIC-IV and evaluates them on
two held-out external cohorts (eICU-CRD, SICdb) with **fully locked preprocessing** —
nothing is ever fit on external data (TRIPOD+AI type-3 evaluation).

---

## Repository layout

```
sql/                        # Cohort + label construction (PostgreSQL)
  mimic/                    #   KDIGO-2012 AKI chain -> AKD label (MIMIC-IV 3.1)
  eicu/                     #   Same logic ported to eICU-CRD 2.0
  sicdb/                    #   Same logic ported to SICdb 1.0.8
feature_pipeline/           # CSV -> wide parquet -> impute/scale -> .npz
  02_assemble.py            #   hourly time grid assembly (37 steps, 12h before to 24h after AKI)
  03_split_impute_scale.py  #   patient-level 60/20/20 split; fit imputer/scaler/PCA on TRAIN only
  03b_external_transform.py #   apply the LOCKED MIMIC artifacts to eICU/SICdb (never refits)
  04_diag_embedding.py      #   Bio_ClinicalBERT diagnosis embedding -> 32-d PCA
  run_pipeline.py           #   orchestrates the SQL feature export
models/                     # (reserved)
training/
  informer2020/             # vendored Informer modules (attn/encoder/embed) + original LICENSE
  model_v2.py               # AKDNet: Informer ProbAttention encoder + static MLP -> logit
  model_simple_tf.py        # capacity-controlled plain Transformer
  train_baselines.py        # logistic regression + XGBoost
  train_zoo.py              # random forest / LightGBM / kernel SVM / MLP (same split & seed)
  train_informer.py         # AKDNet trainer (BCEWithLogitsLoss, AMP, early stop)
  train_simple_tf.py        # plain-Transformer trainer
  metrics_v2.py             # AUROC/AUPRC/Brier/calibration slope/DCA + 2000x bootstrap CI
evaluation/
  external_eval.py          # locked PyTorch ckpt -> eICU/SICdb inference + report.json
  external_eval_baselines.py# same for LR / XGBoost
  external_eval_zoo.py      # same for RF / LightGBM / SVM / MLP
  recalibrate_external.py   # post-hoc Platt/isotonic recalibration ceiling (S1' analysis)
  recalibrate_xgb.py        # recalibration for the primary XGBoost model
  summarize_results.py      # aggregate reports -> tables + calibration/DCA figures
  dump_val_preds.py         # export validation-split predictions
explainability/
  shap_xgb.py               # SHAP for the locked primary XGBoost model (never refits)
  shap_sensitivity.py       # SHAP robustness analyses
  fig_shap.py               # manuscript SHAP figures
docs/
```

## Data access (required before anything runs)

This repository contains **no patient data**. The three source databases are credentialed
and cannot be redistributed:

| Database | Version used | Access |
|---|---|---|
| MIMIC-IV | 3.1 | <https://physionet.org/content/mimiciv/> (credentialed) |
| eICU-CRD | 2.0 | <https://physionet.org/content/eicu-crd/> (credentialed) |
| SICdb | 1.0.8 | <https://physionet.org/content/sicdb/> (contributor approval) |

Load each database into a local PostgreSQL instance, then run the `sql/<db>/` scripts in
filename order to build the AKI staging chain and the AKD cohort tables
(`kdigo2012_akd_cohort`, tier-1 no-RRT; `*_with_rrt_*`, tier-2 sensitivity).

## Cohort and label definitions (as in the manuscript)

- **AKI**: KDIGO 2012 serum-creatinine criteria; onset T0 = first time stage >= 1,
  at least 12 h after ICU admission (ICU-acquired AKI with a pre-AKI observation window).
- **AKD (ADQI 16)**: AKI stage >= 1 persisting at day 7 (T0 + 168 h). Death within 7 days
  is classified as AKD (competing-risk event). RRT-dependent patients -> tier-2 cohort.
- **Baseline creatinine**: three-tier hierarchy — (1) mean of out-patient values 365–7 d
  before admission (eICU: structured past-history entry); (2) in-hospital near-window
  min/p10/p20 rules; (3) MDRD back-calculation (used for 84 eICU patients, 0.64%, only).
- **Features**: 39 hourly time-series (vitals, labs, urine output, SOFA, vasopressors,
  ventilation; lactate and blood-gas bicarbonate excluded for >95% missingness) +
  11 static features + 32-d PCA of the Bio_ClinicalBERT diagnosis embedding
  (81.4% explained variance) — 37 time steps over a 36-hour peri-AKI window.

## Reproduction order

```bash
conda create -n akd python=3.11 && conda activate akd
pip install -r requirements.txt          # torch per your CUDA build

# 1. SQL: cohorts, labels, feature exports (per database, in filename order)
# 2. Feature pipeline (MIMIC development set)
python feature_pipeline/run_pipeline.py            # SQL -> CSV
python feature_pipeline/02_assemble.py             # CSV -> hourly parquet
python feature_pipeline/03_split_impute_scale.py   # split + fit transforms -> dataset npz
python feature_pipeline/04_diag_embedding.py       # BioBERT -> PCA -> merge into X_static

# 3. Training (all models share the same patient-level split, seed 42)
python training/train_baselines.py --dataset <mimic_dataset> --outdir runs/baseline_B
python training/train_zoo.py        --dataset <mimic_dataset> --outdir runs/zoo_B
python training/train_informer.py   --dataset <mimic_dataset> --outdir runs/informer_B
python training/train_simple_tf.py  --dataset <mimic_dataset> --outdir runs/simple_tf_B

# 4. External validation (locked artifacts; never refits)
python feature_pipeline/03b_external_transform.py --mimic_dataset <mimic_dataset> ...
python evaluation/external_eval.py            # Informer
python evaluation/external_eval_baselines.py  # LR / XGBoost
python evaluation/external_eval_zoo.py        # RF / LightGBM / SVM / MLP
python evaluation/external_eval.py --simple_tf ...  # plain Transformer

# 5. Recalibration ceiling + summary
python evaluation/recalibrate_external.py ...
python evaluation/summarize_results.py ...

# 6. Explainability
python explainability/shap_xgb.py ...
python explainability/fig_shap.py ...
```

Exact command lines and paths are environment-specific; the entry points above mirror the
run order used for the manuscript results.

## Key design guarantees

- **No leakage**: imputation medians, RobustScaler, diagnosis PCA, and all model weights
  are fit on the MIMIC-IV training split only; external cohorts are transformed and
  evaluated with those locked artifacts (`03b_external_transform.py`, `external_eval*`).
- **Single split**: every model sees the same patient-level 60/20/20 split (seed 42).
- **TRIPOD+AI metrics**: AUROC/AUPRC/Brier/calibration slope with 2,000-resample
  bootstrap CIs, DeLong comparisons against XGBoost with BH correction, decision-curve
  net benefit over the 0.20–0.50 threshold band (`training/metrics_v2.py`).

## Third-party components

`training/informer2020/` vendors the attention/encoder/embedding modules adapted from the
Informer2020 codebase (Zhou et al., AAAI 2021); the original `LICENSE` is retained.
Diagnosis embedding uses `emilyalsentzer/Bio_ClinicalBERT` from Hugging Face.

## Citation

If you use this code, please cite the manuscript (citation details will be added upon
publication) and the underlying databases (MIMIC-IV, eICU-CRD, SICdb per their
data-use agreements).

## Contact

Corresponding author: Xufeng Chen (cxfyx@njmu.edu.cn).
Issues about the code: please open a GitHub issue.
