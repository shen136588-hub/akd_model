-- 23_kdigo2012_stage_step1.sql  (2026-07-22)
-- =============================================================================
-- KDIGO 2012 严格版 per-timepoint 分期 (parallel to 18_kdigo_stage_step1)
--
--   * 仅对 kdigo2012_aki_onset.t0_aki_relaxed 非空的 stay 计算
--   * 仅保留 charttime >= t0_aki_relaxed 的时点 (含 t0)
--   * 分期 CASE 加入 creat_low_past_48hr + 0.3 阈值 (KDIGO 2012 §2.1.2, 严格 Stage 1/3)
--   * UO 分期沿用 kdigo_uo_step3
--   * 关联键都带 stay_id, 避免上次那种 fan-out
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_stage_step1 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_stage_step1 AS
WITH cr_base AS (
    SELECT
        cr.subject_id, cr.hadm_id, cr.stay_id, cr.charttime,
        cr.creat, cr.creat_low_past_48hr, cr.creat_low_past_7day,
        cr_b.cr_baseline,
        ki.kd_diagnosis, ki.icd_kd_diagnosis,
        CASE WHEN cr.rt_active IS NULL THEN 'no' ELSE 'yes' END AS rrt_72hr_prior_and_24hr_post
    FROM mimiciv_derived.cr_baseline_step1 cr
    LEFT JOIN mimiciv_derived.cr_baseline_union cr_b ON cr.hadm_id = cr_b.hadm_id
    LEFT JOIN mimiciv_derived.aki_or_ckd        ki   ON cr.hadm_id = ki.hadm_id
),
cr_stg AS (
    SELECT b.*,
      CASE
        WHEN b.cr_baseline IS NULL THEN NULL
        -- Stage 3
        WHEN b.creat >= b.cr_baseline * 3.0 THEN 3
        WHEN b.creat >= 4
             AND (b.creat >= b.cr_baseline + 0.3
               OR (b.creat_low_past_48hr IS NOT NULL AND b.creat >= b.creat_low_past_48hr + 0.3)
               OR b.creat >= 1.5 * b.cr_baseline)
          THEN 3
        -- Stage 2
        WHEN b.creat >= b.cr_baseline * 2.0 THEN 2
        -- Stage 1
        WHEN b.creat >= b.cr_baseline + 0.3 THEN 1
        WHEN b.creat_low_past_48hr IS NOT NULL AND b.creat >= b.creat_low_past_48hr + 0.3 THEN 1
        WHEN b.creat >= b.cr_baseline * 1.5 THEN 1
        -- 亚临床 0.5 (保留原逻辑, 供 AKD / sub-AKI 敏感性分析)
        WHEN b.creat >= b.cr_baseline * 1.2 AND b.creat < b.cr_baseline * 1.5 THEN 0.5
        WHEN b.creat >= b.cr_baseline + 0.2 AND b.creat < b.cr_baseline + 0.3 THEN 0.5
        ELSE 0
      END AS aki_stage_creat
    FROM cr_base b
),
uo_stg AS (
    SELECT
        uo.hadm_id, uo.stay_id, uo.charttime, uo.weight,
        ki.kd_diagnosis AS kd_diagnosis, ki.icd_kd_diagnosis,
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
    LEFT JOIN mimiciv_derived.aki_or_ckd        ki   ON uo.hadm_id = ki.hadm_id
    LEFT JOIN mimiciv_derived.cr_baseline_union cr_b ON uo.hadm_id = cr_b.hadm_id
),
tm_stg AS (
    SELECT hadm_id, stay_id, charttime FROM cr_stg
    UNION
    SELECT hadm_id, stay_id, charttime FROM uo_stg
),
onset AS (
    SELECT stay_id, t0_aki_relaxed
    FROM mimiciv_derived.kdigo2012_aki_onset
    WHERE t0_aki_relaxed IS NOT NULL
)
SELECT
    COALESCE(cr.hadm_id, uo.hadm_id) AS hadm_id,
    tm.stay_id,
    tm.charttime,
    o.t0_aki_relaxed,
    COALESCE(cr.cr_baseline, uo.cr_baseline)                                 AS cr_baseline,
    cr.creat_low_past_48hr,
    cr.creat_low_past_7day,
    cr.rrt_72hr_prior_and_24hr_post,
    COALESCE(cr.kd_diagnosis, uo.kd_diagnosis)                               AS kd_diagnosis,
    COALESCE(cr.icd_kd_diagnosis, uo.icd_kd_diagnosis)                       AS icd_kd_diagnosis,
    cr.creat,
    cr.aki_stage_creat,
    uo.uo_rt_6hr, uo.uo_rt_12hr, uo.uo_rt_24hr, uo.aki_stage_uo,
    CASE
      WHEN (COALESCE(cr.kd_diagnosis, uo.kd_diagnosis) LIKE '%ckd%'
            AND COALESCE(cr.cr_baseline, uo.cr_baseline) >= 1.5)
        OR COALESCE(cr.icd_kd_diagnosis, uo.icd_kd_diagnosis) LIKE 'Dependence on renal dialysis'
      THEN cr.aki_stage_creat
      ELSE GREATEST(COALESCE(cr.aki_stage_creat, 0), COALESCE(uo.aki_stage_uo, 0))
    END AS aki_stage
FROM tm_stg tm
JOIN onset o
  ON tm.stay_id  = o.stay_id
 AND tm.charttime >= o.t0_aki_relaxed
LEFT JOIN cr_stg cr
  ON tm.hadm_id   = cr.hadm_id
 AND tm.stay_id  IS NOT DISTINCT FROM cr.stay_id
 AND tm.charttime = cr.charttime
LEFT JOIN uo_stg uo
  ON tm.hadm_id   = uo.hadm_id
 AND tm.stay_id  IS NOT DISTINCT FROM uo.stay_id
 AND tm.charttime = uo.charttime;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_step1_key
  ON mimiciv_derived.kdigo2012_stage_step1 (hadm_id, stay_id, charttime);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_step1_stay_time
  ON mimiciv_derived.kdigo2012_stage_step1 (stay_id, charttime);
ANALYZE mimiciv_derived.kdigo2012_stage_step1;

\echo '=== kdigo2012_stage_step1 (从 t0 起分期, KDIGO 2012 严格 CASE) 已创建 ==='
