-- =============================================================================
-- 25b_kdigo2012_aki_after_icu_720m.sql  (WITH RRT, 2026-08-04)
-- Author: 米好 for 朝阳
--
-- 与 25 号(without_rrt)的唯一差异: 不排除 RRT 患者
-- 其余逻辑完全一致 — kdigo2012 Cr 标准 + 入 ICU >= 12h + AKI onset
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_aki_after_icu_720m CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_aki_after_icu_720m AS
CREATE MATERIALIZED VIEW IF NOT EXISTS mimiciv_derived.kdigo2012_aki_after_icu_720m
TABLESPACE pg_default
AS
 WITH rrt_flag AS (
         SELECT rrt_active.stay_id,
            true AS rrt_ever,
            min(rrt_active.charttime) AS rrt_first_time
           FROM mimiciv_derived.rrt_active
          WHERE rrt_active.rt_active = 1 AND rrt_active.stay_id IS NOT NULL
          GROUP BY rrt_active.stay_id
        ), rrt_history AS (
         SELECT DISTINCT id_rrt_without_record.stay_id
           FROM mimiciv_derived.id_rrt_without_record
          WHERE id_rrt_without_record.stay_id IS NOT NULL
        ), aki AS (
         SELECT st.hadm_id,
            st.stay_id,
            st.intime,
            st.outtime,
            st.admittime,
            st.dischtime,
            st.t0_aki_relaxed,
            st.charttime,
            st.chartoffset_minute,
            st.chartoffset_minute_since_t0,
            st.cr_baseline,
            st.creat_low_past_48hr,
            st.creat_low_past_7day,
            st.rrt_72hr_prior_and_24hr_post,
            st.kd_diagnosis,
            st.icd_kd_diagnosis,
            st.creat,
            st.aki_stage_creat,
            st.uo_rt_6hr,
            st.uo_rt_12hr,
            st.uo_rt_24hr,
            st.aki_stage_uo,
            st.aki,
            st.aki_stage,
            row_number() OVER (PARTITION BY st.stay_id ORDER BY st.chartoffset_minute) AS offset_order
           FROM mimiciv_derived.kdigo2012_stages st
          WHERE (st.stay_id IN ( SELECT DISTINCT kdigo2012_stages.stay_id
                   FROM mimiciv_derived.kdigo2012_stages
                  WHERE kdigo2012_stages.chartoffset_minute > 0::numeric AND kdigo2012_stages.aki_stage_creat >= 1::numeric)) AND st.aki_stage_creat IS NOT NULL AND st.chartoffset_minute >= 0::numeric
        ), aki_icu_onset AS (
         SELECT DISTINCT aki_1.stay_id
           FROM aki aki_1
          WHERE (aki_1.t0_aki_relaxed - aki_1.intime) >= '12:00:00'::interval
        )
 SELECT ad.subject_id,
    aki.hadm_id,
    aki.stay_id,
    rank() OVER (PARTITION BY aki.hadm_id ORDER BY aki.intime) AS stayid_order,
    aki.intime,
    aki.outtime,
    aki.admittime,
    aki.dischtime,
    aki.t0_aki_relaxed,
    aki.charttime,
    aki.chartoffset_minute AS chartoffset_minute_since_intime,
    aki.chartoffset_minute_since_t0,
    aki.offset_order,
    aki.cr_baseline,
    aki.creat_low_past_48hr,
    aki.creat_low_past_7day,
    aki.rrt_72hr_prior_and_24hr_post,
    aki.kd_diagnosis,
    aki.icd_kd_diagnosis,
    aki.creat,
    aki.aki_stage_creat,
    aki.uo_rt_6hr,
    aki.uo_rt_12hr,
    aki.uo_rt_24hr,
    aki.aki_stage_uo,
    aki.aki,
    aki.aki_stage,
    COALESCE(rf.rrt_ever, false) AS rrt_ever,
    rf.rrt_first_time,
    rf.rrt_first_time IS NOT NULL AND rf.rrt_first_time < aki.intime AS rrt_before_icu,
    rf.rrt_first_time IS NOT NULL AND rf.rrt_first_time < aki.t0_aki_relaxed AS rrt_before_t0,
    rh.stay_id IS NOT NULL OR lower(COALESCE(aki.kd_diagnosis, ''::text)) ~~ '%rrt%'::text OR lower(COALESCE(aki.icd_kd_diagnosis, ''::text)) ~~ '%dependence on renal dialysis%'::text AS esrd_or_rrt_history
   FROM aki
     LEFT JOIN mimiciv_hosp.admissions ad ON ad.hadm_id = aki.hadm_id
     LEFT JOIN rrt_flag rf ON rf.stay_id = aki.stay_id
     LEFT JOIN rrt_history rh ON rh.stay_id = aki.stay_id
  WHERE (aki.stay_id IN ( SELECT aki_icu_onset.stay_id
           FROM aki_icu_onset))
  ORDER BY aki.stay_id, aki.offset_order
WITH DATA;

ALTER TABLE IF EXISTS mimiciv_derived.kdigo2012_aki_after_icu_720m
    OWNER TO postgres;


CREATE INDEX idx_kdigo2012_720m_withrrt_rrt
    ON mimiciv_derived.kdigo2012_aki_after_icu_720m USING btree
    (rrt_ever)
    

CREATE INDEX idx_kdigo2012_720m_withrrt_stay
    ON mimiciv_derived.kdigo2012_aki_after_icu_720m USING btree
    (stay_id)
    


ANALYZE mimiciv_derived.kdigo2012_aki_after_icu_720m;

\echo '=== kdigo2012_aki_after_icu_720m (WITH RRT) 已创建 ==='
