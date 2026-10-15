-- 19_kdigo_stages.sql
-- Final KDIGO staging view
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo_stages CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo_stages AS
WITH aki AS
(
  SELECT
    hadm_id, stay_id,
    CASE WHEN MAX(aki_stage) > 0 THEN 'yes' ELSE 'no' END AS aki
  FROM mimiciv_derived.kdigo_stage_step1
  GROUP BY hadm_id, stay_id
),
kdigo AS
(
  SELECT
    kd.hadm_id,
    kd.stay_id,
    kd.charttime,
    kd.cr_baseline,
    kd.creat_low_past_48hr,
    kd.rrt_72hr_prior_and_24hr_post,
    kd.kd_diagnosis,
    kd.icd_kd_diagnosis,
    kd.creat,
    CASE
      WHEN aki.aki LIKE 'yes' AND kd.rrt_72hr_prior_and_24hr_post LIKE 'yes' THEN 3
      ELSE kd.aki_stage_creat
    END AS aki_stage_creat,
    kd.uo_rt_6hr,
    kd.uo_rt_12hr,
    kd.uo_rt_24hr,
    kd.aki_stage_uo,
    aki.aki
  FROM mimiciv_derived.kdigo_stage_step1 kd
  LEFT JOIN aki ON kd.stay_id = aki.stay_id
),
kds AS
(
  SELECT *,
    CASE
      WHEN (kd_diagnosis LIKE '%ckd%' AND cr_baseline >= 1.5)
        OR icd_kd_diagnosis LIKE 'Dependence on renal dialysis'
      THEN aki_stage_creat  -- CKD or dialysis patients: skip UO criteria for AKI diagnosis and staging
      ELSE GREATEST(aki_stage_creat, aki_stage_uo)
    END AS aki_stage
  FROM kdigo
)
SELECT
  kds.hadm_id,
  kds.stay_id,
  icu.intime,
  icu.outtime,
  adm.admittime,
  adm.dischtime,
  kds.charttime,
  ROUND(EXTRACT(EPOCH FROM (kds.charttime - icu.intime)) / 60) AS chartoffset_minute,
  kds.cr_baseline,
  kds.creat_low_past_48hr,
  kds.rrt_72hr_prior_and_24hr_post,
  kds.kd_diagnosis,
  kds.icd_kd_diagnosis,
  kds.creat,
  kds.aki_stage_creat,
  kds.uo_rt_6hr,
  kds.uo_rt_12hr,
  kds.uo_rt_24hr,
  kds.aki_stage_uo,
  kds.aki,
  kds.aki_stage
FROM kds kds
LEFT JOIN mimiciv_icu.icustays icu ON kds.stay_id = icu.stay_id
LEFT JOIN mimiciv_hosp.admissions adm ON kds.hadm_id = adm.hadm_id;
