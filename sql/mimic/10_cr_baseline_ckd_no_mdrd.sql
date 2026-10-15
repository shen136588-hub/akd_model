-- 10_cr_baseline_ckd_no_mdrd.sql  v4 (2026-07-14)
-- 非 CKD 患者 MDRD 反推基线（Tier 3 兜底）
-- 对齐 SICdb 01b_cr_baseline_estimated.sql 的目标 eGFR 分层
--
-- 变更:
--   * 用 mimiciv_derived.aki_or_ckd 的 kd_diagnosis LIKE '%ckd%' /
--     icd_kd_diagnosis LIKE '%Dependence on renal dialysis%' 排除 CKD/透析患者
--   * 目标 eGFR: age<50 → 100; age>=50 → 75
--   * race 未知按 white 处理（1.0 factor）

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_ckd_no_mdrd CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_ckd_no_mdrd AS
WITH id_ckd AS (
    SELECT DISTINCT hadm_id
    FROM mimiciv_derived.aki_or_ckd
    WHERE kd_diagnosis LIKE '%ckd%'
       OR icd_kd_diagnosis LIKE '%Dependence on renal dialysis%'
),
eligible_patients AS (
    SELECT DISTINCT subject_id, hadm_id
    FROM mimiciv_derived.cr_baseline_step1
    WHERE hadm_id NOT IN (SELECT hadm_id FROM id_ckd)
),
patient_data AS (
    SELECT
        cr.subject_id,
        cr.hadm_id,
        COALESCE(pt.race, 'white') AS race,   -- race 未知时按 white 处理
        pt.gender,
        pt.age,
        CASE WHEN pt.age < 50 THEN 100 ELSE 75 END AS target_egfr
    FROM eligible_patients cr
    INNER JOIN mimiciv_derived.agr pt ON cr.hadm_id = pt.hadm_id
    WHERE pt.age > 0
      AND pt.gender IN ('M', 'F')
),
calculated_scr AS (
    SELECT
        *,
        CASE WHEN race = 'black' THEN 1.212 ELSE 1.0 END AS race_factor,
        CASE WHEN gender = 'F' THEN 0.742 ELSE 1.0 END AS gender_factor,
        POWER(age, -0.203) AS age_factor
    FROM patient_data
    WHERE target_egfr > 0
)
SELECT
    subject_id, hadm_id, race, gender, age, target_egfr,
    ROUND(
        POWER(
            (175 * age_factor * gender_factor * race_factor) / NULLIF(target_egfr, 0),
            1.0 / 1.154
        )::numeric, 2
    ) AS cr_baseline_mdrd,
    CASE WHEN age < 50 THEN 'mdrd_no_ckd_age_lt50' ELSE 'mdrd_no_ckd_age_ge50' END AS cr_baseline_mdrd_method
FROM calculated_scr;

CREATE INDEX IF NOT EXISTS idx_crb_no_mdrd_hadm ON mimiciv_derived.cr_baseline_ckd_no_mdrd (hadm_id);

\echo '=== cr_baseline_ckd_no_mdrd v4 (race 未知按 white, method 列可审计) 已创建 ==='
