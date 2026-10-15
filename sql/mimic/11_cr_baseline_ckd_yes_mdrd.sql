-- 11_cr_baseline_ckd_yes_mdrd.sql  v4 (2026-07-14)
-- CKD 患者 MDRD 反推基线（按 CKD 分期分档）
-- 对齐 SICdb 01b_cr_baseline_estimated.sql
--
-- 变更:
--   * CKD unspecified / rf unspecified / Dependence on renal dialysis 保守走 CKD3 (eGFR=45)
--     -> 避免这些患者掉入非 CKD 分支高估基线
--   * ESRD / renal dialysis 归 CKD5 (eGFR=7.5) 或按 stage5 处理
--   * race 未知按 white 处理

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_ckd_yes_mdrd CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_ckd_yes_mdrd AS
WITH id_rt_without_record AS (
    SELECT DISTINCT hadm_id FROM mimiciv_derived.id_rrt_without_record
),
cr_ba_mdrd AS (
    SELECT
        ckd.subject_id,
        ckd.hadm_id,
        ckd.kd_diagnosis,
        ckd.icd_kd_diagnosis,
        COALESCE(pt.race, 'white') AS race,
        pt.gender,
        pt.age,
        CASE
            WHEN ckd.kd_diagnosis LIKE '%ckd5%' THEN 5
            WHEN ckd.kd_diagnosis LIKE '%ckd4%' THEN 4
            WHEN ckd.kd_diagnosis LIKE '%ckd3%' THEN 3
            WHEN ckd.kd_diagnosis LIKE '%ckd2%' THEN 2
            WHEN ckd.kd_diagnosis LIKE '%ckd1%' THEN 1
            WHEN ckd.icd_kd_diagnosis LIKE '%Dependence on renal dialysis%' THEN 5
            WHEN ckd.kd_diagnosis LIKE '%esrd%' THEN 5
            WHEN ckd.kd_diagnosis LIKE '%ckd unspecified%' THEN 3   -- 保守走 CKD3
            WHEN ckd.kd_diagnosis LIKE '%rf unspecified%'  THEN 3
            WHEN ckd.kd_diagnosis LIKE '%ckd%'             THEN 3   -- 兜底：任何未细分的 ckd
            ELSE NULL
        END AS ckd_stage
    FROM mimiciv_derived.aki_or_ckd ckd
    INNER JOIN mimiciv_derived.agr pt ON ckd.hadm_id = pt.hadm_id
    WHERE ckd.hadm_id NOT IN (SELECT DISTINCT hadm_id FROM id_rt_without_record)
      AND (ckd.kd_diagnosis LIKE '%ckd%'
        OR ckd.kd_diagnosis LIKE '%esrd%'
        OR ckd.kd_diagnosis LIKE '%rf unspecified%'
        OR ckd.icd_kd_diagnosis LIKE '%Dependence on renal dialysis%')
      AND pt.age > 0
      AND pt.gender IN ('M', 'F')
),
stage_egfr AS (
    SELECT *,
        CASE
            WHEN ckd_stage = 1 THEN 95
            WHEN ckd_stage = 2 THEN 75
            WHEN ckd_stage = 3 THEN 45
            WHEN ckd_stage = 4 THEN 22.5
            WHEN ckd_stage = 5 THEN 7.5
            ELSE NULL
        END AS stage_egfr
    FROM cr_ba_mdrd
    WHERE ckd_stage IS NOT NULL
),
calculated_cr AS (
    SELECT *,
        CASE WHEN race = 'black' THEN 1.212 ELSE 1.0 END AS race_factor,
        CASE WHEN gender = 'F' THEN 0.742 ELSE 1.0 END AS gender_factor,
        POWER(age, -0.203) AS age_factor
    FROM stage_egfr
    WHERE stage_egfr > 0
)
SELECT
    c.subject_id,
    c.hadm_id,
    c.kd_diagnosis,
    c.icd_kd_diagnosis,
    c.race, c.gender, c.age,
    c.ckd_stage,
    c.stage_egfr,
    ROUND(
        POWER(
            (175 * age_factor * gender_factor * race_factor) / NULLIF(stage_egfr, 0),
            1.0 / 1.154
        )::numeric, 2
    ) AS cr_baseline_mdrd,
    'mdrd_ckd' || c.ckd_stage AS cr_baseline_mdrd_method
FROM calculated_cr c;

CREATE INDEX IF NOT EXISTS idx_crb_yes_mdrd_hadm ON mimiciv_derived.cr_baseline_ckd_yes_mdrd (hadm_id);

\echo '=== cr_baseline_ckd_yes_mdrd v4 (unspecified→CKD3, dialysis→CKD5, race 未知→white) 已创建 ==='
