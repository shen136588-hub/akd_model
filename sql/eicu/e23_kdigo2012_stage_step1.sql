-- e23_kdigo2012_stage_step1.sql  (2026-07-22)
-- =============================================================================
-- eICU KDIGO 2012 严格版 per-timepoint 分期
-- 逻辑与 MIMIC 23 号完全一致, 适配 eICU 字段
-- 仅 t0 之后的时点, 分期 CASE 加入 creat_low_past_48hr + 0.3 阈值
-- 依赖: akistage_creatinine_step2, kdigo2012_aki_onset, akistage_uo_step3
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_stage_step1 CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_stage_step1 AS
WITH cr_stg AS (
    SELECT
        cr.patientunitstayid,
        cr.chartoffset,
        cr.cr_baseline,
        cr.creatinine,
        cr.creat_low_past_48hr,
        cr.kd_diagnosis,
        cr.kd_diagnosis_string,
        cr.rrt_72hr_prior_and_24hr_post,
        CASE
          WHEN cr.cr_baseline IS NULL THEN NULL
          -- Stage 3
          WHEN cr.creatinine >= cr.cr_baseline * 3.0 THEN 3
          WHEN cr.creatinine >= 4
               AND (cr.creatinine >= cr.cr_baseline + 0.3
                 OR (cr.creat_low_past_48hr IS NOT NULL AND cr.creatinine >= cr.creat_low_past_48hr + 0.3)
                 OR cr.creatinine >= 1.5 * cr.cr_baseline)
            THEN 3
          -- Stage 2
          WHEN cr.creatinine >= cr.cr_baseline * 2.0 THEN 2
          -- Stage 1
          WHEN cr.creatinine >= cr.cr_baseline + 0.3 THEN 1
          WHEN cr.creat_low_past_48hr IS NOT NULL AND cr.creatinine >= cr.creat_low_past_48hr + 0.3 THEN 1
          WHEN cr.creatinine >= cr.cr_baseline * 1.5 THEN 1
          -- 亚临床 0.5
          WHEN cr.creatinine >= cr.cr_baseline * 1.2 AND cr.creatinine < cr.cr_baseline * 1.5 THEN 0.5
          WHEN cr.creatinine >= cr.cr_baseline + 0.2 AND cr.creatinine < cr.cr_baseline + 0.3 THEN 0.5
          ELSE 0
        END AS aki_stage_creat
    FROM eicu.akistage_creatinine_step2 cr
),
uo_stg AS (
    SELECT
        uo.patientunitstayid,
        uo.chartoffset,
        uo.weight,
        ki.kd_diagnosis,
        ki.kd_diagnosis_string,
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
    FROM eicu.akistage_uo_step3 uo
    LEFT JOIN eicu.aki_or_ckd        ki   ON uo.patientunitstayid = ki.patientunitstayid
    LEFT JOIN eicu.cr_baseline_union cr_b ON uo.patientunitstayid = cr_b.patientunitstayid
),
tm_stg AS (
    SELECT patientunitstayid, chartoffset FROM cr_stg
    UNION
    SELECT patientunitstayid, chartoffset FROM uo_stg
),
onset AS (
    SELECT patientunitstayid, t0_aki_relaxed
    FROM eicu.kdigo2012_aki_onset
    WHERE t0_aki_relaxed IS NOT NULL
)
SELECT
    COALESCE(cr.patientunitstayid, uo.patientunitstayid) AS patientunitstayid,
    tm.chartoffset,
    o.t0_aki_relaxed,
    COALESCE(cr.cr_baseline, uo.cr_baseline)                           AS cr_baseline,
    cr.creat_low_past_48hr,
    cr.rrt_72hr_prior_and_24hr_post,
    COALESCE(cr.kd_diagnosis, uo.kd_diagnosis)                         AS kd_diagnosis,
    COALESCE(cr.kd_diagnosis_string, uo.kd_diagnosis_string)           AS kd_diagnosis_string,
    cr.creatinine,
    cr.aki_stage_creat,
    uo.uo_rt_6hr, uo.uo_rt_12hr, uo.uo_rt_24hr, uo.aki_stage_uo,
    CASE
      WHEN (LOWER(COALESCE(cr.kd_diagnosis, uo.kd_diagnosis)) LIKE ANY (ARRAY['%ckd%','%cki%','%esrd%'])
            AND COALESCE(cr.cr_baseline, uo.cr_baseline) >= 1.5)
      THEN cr.aki_stage_creat
      ELSE GREATEST(COALESCE(cr.aki_stage_creat, 0), COALESCE(uo.aki_stage_uo, 0))
    END AS aki_stage
FROM tm_stg tm
JOIN onset o
  ON tm.patientunitstayid = o.patientunitstayid
 AND tm.chartoffset      >= o.t0_aki_relaxed
LEFT JOIN cr_stg cr
  ON tm.patientunitstayid = cr.patientunitstayid
 AND tm.chartoffset       = cr.chartoffset
LEFT JOIN uo_stg uo
  ON tm.patientunitstayid = uo.patientunitstayid
 AND tm.chartoffset       = uo.chartoffset;

CREATE INDEX IF NOT EXISTS idx_eicu_kdigo2012_step1_stay
  ON eicu.kdigo2012_stage_step1 (patientunitstayid, chartoffset);
ANALYZE eicu.kdigo2012_stage_step1;

\echo '=== eicu.kdigo2012_stage_step1 (从 t0 起分期, KDIGO 2012 严格 CASE) 已创建 ==='