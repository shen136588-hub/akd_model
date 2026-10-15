-- 13_akistage_creatinine_step2.sql
-- Add cr_baseline and CKD/RRT info on top of cr_baseline_step1
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akistage_creatinine_step2 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.akistage_creatinine_step2 AS
SELECT
    cr.subject_id,
    cr.hadm_id,
    cr.stay_id,
    cr.intime,
    cr.outtime,
    cr.admittime,
    cr.dischtime,
    cr.charttime,
    cr.creat,
    cr.creat_low_past_48hr,
    cr_b.cr_baseline,
    ki.kd_diagnosis,
    ki.icd_kd_diagnosis,
    CASE
        WHEN cr.rt_active IS NULL THEN 'no'
        ELSE 'yes'
    END AS rrt_72hr_prior_and_24hr_post,
    cr.all_rttimes,
    cr.rt_active
FROM mimiciv_derived.cr_baseline_step1 cr
LEFT JOIN mimiciv_derived.cr_baseline_union cr_b ON cr.hadm_id = cr_b.hadm_id
LEFT JOIN mimiciv_derived.aki_or_ckd ki ON cr.hadm_id = ki.hadm_id;
