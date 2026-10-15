-- e24_kdigo2012_stages.sql  (2026-07-22)
-- =============================================================================
-- eICU KDIGO 2012 严格版最终 stage 视图
-- 添加 hospital 时间戳, RRT stage3 覆盖
-- 依赖: kdigo2012_stage_step1, patient
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_stages CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_stages AS
WITH aki AS (
    SELECT patientunitstayid,
           CASE WHEN MAX(aki_stage) > 0 THEN 'yes' ELSE 'no' END AS aki
    FROM eicu.kdigo2012_stage_step1
    GROUP BY patientunitstayid
),
kdigo AS (
    SELECT
        kd.patientunitstayid,
        kd.chartoffset,
        kd.t0_aki_relaxed,
        kd.cr_baseline,
        kd.creat_low_past_48hr,
        kd.rrt_72hr_prior_and_24hr_post,
        kd.kd_diagnosis, kd.kd_diagnosis_string,
        kd.creatinine,
        CASE
          WHEN aki.aki = 'yes' AND kd.rrt_72hr_prior_and_24hr_post = 'yes' THEN 3
          ELSE kd.aki_stage_creat
        END AS aki_stage_creat,
        kd.uo_rt_6hr, kd.uo_rt_12hr, kd.uo_rt_24hr,
        kd.aki_stage_uo,
        aki.aki
    FROM eicu.kdigo2012_stage_step1 kd
    LEFT JOIN aki ON kd.patientunitstayid = aki.patientunitstayid
),
kds AS (
    SELECT *,
      CASE
        WHEN LOWER(kd_diagnosis) LIKE ANY (ARRAY['%ckd%','%cki%','%esrd%']) AND cr_baseline >= 1.5
        THEN aki_stage_creat
        ELSE GREATEST(COALESCE(aki_stage_creat, 0), COALESCE(aki_stage_uo, 0))
      END AS aki_stage
    FROM kdigo
)
SELECT
    pt.patienthealthsystemstayid,
    kds.patientunitstayid,
    pt.hospitaladmitoffset,
    pt.hospitaldischargeoffset,
    pt.unitdischargeoffset,
    kds.t0_aki_relaxed,
    kds.chartoffset,
    kds.chartoffset - kds.t0_aki_relaxed AS chartoffset_since_t0,
    kds.cr_baseline,
    kds.creat_low_past_48hr,
    kds.rrt_72hr_prior_and_24hr_post,
    kds.kd_diagnosis,
    kds.kd_diagnosis_string,
    kds.creatinine,
    kds.aki_stage_creat,
    kds.uo_rt_6hr, kds.uo_rt_12hr, kds.uo_rt_24hr,
    kds.aki_stage_uo,
    kds.aki,
    kds.aki_stage
FROM kds
LEFT JOIN eicu.patient pt ON kds.patientunitstayid = pt.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_eicu_kdigo2012_stages_stay
  ON eicu.kdigo2012_stages (patientunitstayid, chartoffset);
ANALYZE eicu.kdigo2012_stages;

\echo '=== eicu.kdigo2012_stages (KDIGO 2012 严格版最终视图) 已创建 ==='