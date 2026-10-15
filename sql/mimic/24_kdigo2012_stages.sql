-- 24_kdigo2012_stages.sql  (2026-07-22)
-- =============================================================================
-- KDIGO 2012 严格版最终 stage 视图 (parallel to 19_kdigo_stages)
--
--   * 输入: kdigo2012_stage_step1 (已仅含 t0 之后时点)
--   * 添加 icustay + hospital 时间戳, chartoffset_minute vs intime,
--     以及 chartoffset_minute_since_t0
--   * stage-level "aki=yes 且当前时点 rrt='yes' → stage 3" 覆盖 (与旧 19 一致)
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_stages CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_stages AS
WITH aki AS (
    SELECT hadm_id, stay_id,
           CASE WHEN MAX(aki_stage) > 0 THEN 'yes' ELSE 'no' END AS aki
    FROM mimiciv_derived.kdigo2012_stage_step1
    GROUP BY hadm_id, stay_id
),
kdigo AS (
    SELECT
        kd.hadm_id, kd.stay_id, kd.charttime, kd.t0_aki_relaxed,
        kd.cr_baseline, kd.creat_low_past_48hr, kd.creat_low_past_7day,
        kd.rrt_72hr_prior_and_24hr_post,
        kd.kd_diagnosis, kd.icd_kd_diagnosis, kd.creat,
        CASE
          WHEN aki.aki LIKE 'yes' AND kd.rrt_72hr_prior_and_24hr_post LIKE 'yes' THEN 3
          ELSE kd.aki_stage_creat
        END AS aki_stage_creat,
        kd.uo_rt_6hr, kd.uo_rt_12hr, kd.uo_rt_24hr, kd.aki_stage_uo,
        aki.aki
    FROM mimiciv_derived.kdigo2012_stage_step1 kd
    LEFT JOIN aki ON kd.hadm_id = aki.hadm_id AND kd.stay_id = aki.stay_id
),
kds AS (
    SELECT *,
      CASE
        WHEN (kd_diagnosis LIKE '%ckd%' AND cr_baseline >= 1.5)
          OR icd_kd_diagnosis LIKE 'Dependence on renal dialysis'
        THEN aki_stage_creat
        ELSE GREATEST(COALESCE(aki_stage_creat, 0), COALESCE(aki_stage_uo, 0))
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
    kds.t0_aki_relaxed,
    kds.charttime,
    ROUND(EXTRACT(EPOCH FROM (kds.charttime - icu.intime))    / 60) AS chartoffset_minute,
    ROUND(EXTRACT(EPOCH FROM (kds.charttime - kds.t0_aki_relaxed)) / 60) AS chartoffset_minute_since_t0,
    kds.cr_baseline,
    kds.creat_low_past_48hr,
    kds.creat_low_past_7day,
    kds.rrt_72hr_prior_and_24hr_post,
    kds.kd_diagnosis,
    kds.icd_kd_diagnosis,
    kds.creat,
    kds.aki_stage_creat,
    kds.uo_rt_6hr, kds.uo_rt_12hr, kds.uo_rt_24hr,
    kds.aki_stage_uo,
    kds.aki,
    kds.aki_stage
FROM kds
LEFT JOIN mimiciv_icu.icustays   icu ON kds.stay_id = icu.stay_id
LEFT JOIN mimiciv_hosp.admissions adm ON kds.hadm_id = adm.hadm_id;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_key
  ON mimiciv_derived.kdigo2012_stages (hadm_id, stay_id, charttime);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_stay_time
  ON mimiciv_derived.kdigo2012_stages (stay_id, charttime);
ANALYZE mimiciv_derived.kdigo2012_stages;

\echo '=== kdigo2012_stages (KDIGO 2012 严格版最终视图) 已创建 ==='
