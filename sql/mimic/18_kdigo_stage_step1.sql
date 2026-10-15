-- 18_kdigo_stage_step1.sql
-- KDIGO staging step 1: calculate creatinine and UO stages, take max
-- Adapted for MIMIC-IV 3.1 schema
--
-- v2 (2026-07-22) 去重修复:
--   tm_stg JOIN cr_stg / uo_stg 原本只用 (hadm_id, charttime),
--   而 tm_stg 里 stay_id 是携带列(不参与 join), 导致同一 (hadm, charttime)
--   在两侧各有 N 行时形成笛卡儿放大 (N x N).
--   → 在 JOIN 键补上 stay_id, 用 IS NOT DISTINCT FROM 兼容 NULL 的 stay.

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo_stage_step1 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo_stage_step1 AS
WITH cr_stg AS
(
  SELECT
    cr.hadm_id, cr.stay_id, cr.charttime,
    cr.cr_baseline,
    cr.creat,
    cr.creat_low_past_48hr,
    cr.kd_diagnosis,
    cr.icd_kd_diagnosis,
    cr.rrt_72hr_prior_and_24hr_post,
    CASE
      WHEN cr.cr_baseline IS NULL THEN NULL
      WHEN cr.creat >= (cr.cr_baseline * 3.0) THEN 3
      WHEN cr.creat >= 4
        AND (cr.creat >= cr.cr_baseline + 0.3 OR cr.creat >= (1.5 * cr.cr_baseline))
        THEN 3
      WHEN cr.creat >= (cr.cr_baseline * 2.0) THEN 2
      WHEN cr.creat >= (cr.cr_baseline + 0.3) THEN 1
      WHEN cr.creat >= (cr.cr_baseline * 1.5) THEN 1
      WHEN cr.creat >= cr.cr_baseline * 1.2 AND cr.creat < cr.cr_baseline * 1.5 THEN 0.5
      WHEN cr.creat >= cr.cr_baseline + 0.2 AND cr.creat < cr.cr_baseline + 0.3 THEN 0.5
      ELSE 0
    END AS aki_stage_creat
  FROM mimiciv_derived.akistage_creatinine_step2 cr
),
uo_stg AS
(
  SELECT
    uo.hadm_id, uo.stay_id, uo.charttime,
    uo.weight,
    ki.kd_diagnosis AS kd_diagnosis,
    ki.icd_kd_diagnosis,
    cr_b.cr_baseline,
    uo.uo_rt_6hr, uo.uo_rt_12hr, uo.uo_rt_24hr,
    CASE
      WHEN uo.uo_rt_6hr IS NULL AND uo.uo_rt_12hr IS NULL AND uo.uo_rt_24hr IS NULL THEN NULL
      WHEN uo.uo_tm_6hr < 4 AND uo.uo_tm_12hr < 8 AND uo.uo_tm_24hr < 18 THEN NULL
      WHEN uo.uo_tm_24hr >= 18 AND uo.uo_rt_24hr < 0.3 THEN 3
      WHEN uo.uo_tm_12hr >= 8 AND uo.uo_rt_12hr = 0 THEN 3
      WHEN uo.uo_tm_12hr >= 8 AND uo.uo_rt_12hr < 0.5 THEN 2
      WHEN uo.uo_tm_6hr >= 4 AND uo.uo_rt_6hr < 0.5 THEN 1
      ELSE 0
    END AS aki_stage_uo
  FROM mimiciv_derived.kdigo_uo_step3 uo
  LEFT JOIN mimiciv_derived.aki_or_ckd ki ON uo.hadm_id = ki.hadm_id
  LEFT JOIN mimiciv_derived.cr_baseline_union cr_b ON uo.hadm_id = cr_b.hadm_id
),
tm_stg AS
(
  SELECT hadm_id, stay_id, charttime FROM cr_stg
  UNION                   -- 用 UNION (DISTINCT) 去重, 避免同键重复
  SELECT hadm_id, stay_id, charttime FROM uo_stg
)
SELECT
  COALESCE(cr.hadm_id, uo.hadm_id) AS hadm_id,
  tm.stay_id,
  tm.charttime,
  COALESCE(cr.cr_baseline, uo.cr_baseline) AS cr_baseline,
  cr.creat_low_past_48hr,
  cr.rrt_72hr_prior_and_24hr_post,
  COALESCE(cr.kd_diagnosis, uo.kd_diagnosis) AS kd_diagnosis,
  COALESCE(cr.icd_kd_diagnosis, uo.icd_kd_diagnosis) AS icd_kd_diagnosis,
  cr.creat,
  cr.aki_stage_creat,
  uo.uo_rt_6hr, uo.uo_rt_12hr, uo.uo_rt_24hr,
  uo.aki_stage_uo,
  CASE
    WHEN (COALESCE(cr.kd_diagnosis, uo.kd_diagnosis) LIKE '%ckd%'
          AND COALESCE(cr.cr_baseline, uo.cr_baseline) >= 1.5)
      OR COALESCE(cr.icd_kd_diagnosis, uo.icd_kd_diagnosis) LIKE 'Dependence on renal dialysis'
    THEN cr.aki_stage_creat
    ELSE GREATEST(cr.aki_stage_creat, uo.aki_stage_uo)
  END AS aki_stage
FROM tm_stg tm
LEFT JOIN cr_stg cr
  ON tm.hadm_id = cr.hadm_id
 AND tm.stay_id IS NOT DISTINCT FROM cr.stay_id   -- ★ 加 stay_id, 兼容 NULL
 AND tm.charttime = cr.charttime
LEFT JOIN uo_stg uo
  ON tm.hadm_id = uo.hadm_id
 AND tm.stay_id IS NOT DISTINCT FROM uo.stay_id   -- ★ 加 stay_id, 兼容 NULL
 AND tm.charttime = uo.charttime;

CREATE INDEX IF NOT EXISTS idx_kdigo_stage_step1_key
  ON mimiciv_derived.kdigo_stage_step1 (hadm_id, stay_id, charttime);
ANALYZE mimiciv_derived.kdigo_stage_step1;

\echo '=== kdigo_stage_step1 v2 (dedup: join by hadm+stay+charttime) ==='
