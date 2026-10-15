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
training/                   # files are prefixed in dependency/run order (step0 -> step6)
  informer2020/             # vendored Informer modules (attn/encoder/embed) + original LICENSE
  step0_metrics.py          # AUROC/AUPRC/Brier/calibration slope/DCA + 2000x bootstrap CI
  step1_model_informer.py   # AKDNet: Informer ProbAttention encoder + static MLP -> logit
  step2_model_transformer.py# capacity-controlled plain Transformer
  step3_train_lr_xgboost.py # logistic regression + XGBoost
  step4_train_rf_lightgbm_svm_mlp.py  # RF / LightGBM / kernel SVM / MLP (same split & seed)
  step5_train_informer.py   # AKDNet trainer (BCEWithLogitsLoss, AMP, early stop)
  step6_train_transformer.py# plain-Transformer trainer
evaluation/                 # step1 -> step7 in run order
  step1_external_eval_informer.py            # locked PyTorch ckpt -> eICU/SICdb inference
  step2_external_eval_lr_xgboost.py          # same for LR / XGBoost
  step3_external_eval_rf_lightgbm_svm_mlp.py # same for RF / LightGBM / SVM / MLP
  step4_recalibrate_external.py              # post-hoc Platt/isotonic recalibration ceiling
  step5_recalibrate_xgboost.py               # recalibration for the primary XGBoost model
  step6_summarize_results.py                 # aggregate reports -> tables + calib/DCA figures
  step7_dump_val_predictions.py              # export validation-split predictions
explainability/
  step1_shap_xgboost.py     # SHAP for the locked primary XGBoost model (never refits)
  step2_shap_sensitivity.py # SHAP robustness analyses
  step3_fig_shap.py         # manuscript SHAP figures
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
python training/step3_train_lr_xgboost.py --dataset <mimic_dataset> --outdir runs/baseline_B
python training/step4_train_rf_lightgbm_svm_mlp.py --dataset <mimic_dataset> --outdir runs/zoo_B
python training/step5_train_informer.py   --dataset <mimic_dataset> --outdir runs/informer_B
python training/step6_train_transformer.py --dataset <mimic_dataset> --outdir runs/simple_tf_B

# 4. External validation (locked artifacts; never refits)
python feature_pipeline/03b_external_transform.py --mimic_dataset <mimic_dataset> ...
python evaluation/step1_external_eval_informer.py            # Informer
python evaluation/step2_external_eval_lr_xgboost.py          # LR / XGBoost
python evaluation/step3_external_eval_rf_lightgbm_svm_mlp.py # RF / LightGBM / SVM / MLP
python evaluation/step1_external_eval_informer.py --simple_tf ...  # plain Transformer

# 5. Recalibration ceiling + summary
python evaluation/step4_recalibrate_external.py ...
python evaluation/step6_summarize_results.py ...

# 6. Explainability
python explainability/step1_shap_xgboost.py ...
python explainability/step3_fig_shap.py ...
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
  net benefit over the 0.20–0.50 threshold band (`training/step0_metrics.py`).

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
