-- =============================================================================
-- e25b_kdigo2012_aki_after_icu_720m.sql   (eICU, WITH-RRT version, 2026-08-02)
-- Author: 米好 for 朝阳
--
-- 目的: e25_kdigo2012_aki_after_icu_720m_without_rrt.sql 的「不排除 RRT」孪生视图。
--       原视图保留不动。本视图供含 RRT 人群分析, 与 MIMIC 25b 结构对齐。
--
-- 与 e25 的唯一结构差异:
--   * 删除 `patientunitstayid NOT IN (rrt_treatment ∪ id_rrt_without_record)`
--   * 新增 RRT 标注列 (供 e27b 做竞争风险与净化窗校正):
--       rrt_ever            该 stay 是否出现在 rrt_treatment
--       rrt_first_off       首次 RRT 的分钟 offset (since ICU intime)
--       rrt_last_off        末次 RRT 的分钟 offset
--       rrt_before_t0       首次 RRT 早于 AKI 诊断 T0
--       esrd_or_rrt_history 来自 id_rrt_without_record (透析史无活跃记录)
--                           或 kd_diagnosis/kd_diagnosis_string 提示 ESRD/透析依赖
--
-- ⚠️ eICU 局限: rrt_treatment 来自 treatment/intakeoutput 记录, 时间分辨率与
--    完整性均低于 MIMIC inputevents; 慢性透析(ESRD)识别主要依赖 pasthistory 文本。
--    这些限制需在论文写明, 且 eICU 含 RRT 队列应作为次要外验。
--
-- 依赖: kdigo2012_stages, rrt_treatment, id_rrt_without_record
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_aki_after_icu_720m CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_aki_after_icu_720m AS
WITH
rrt_flag AS (
    -- eicu.rrt_treatment 列名为 treatmentoffset (非 chartoffset), 已核实 pg_attribute。
    SELECT
        patientunitstayid,
        TRUE AS rrt_ever,
        MIN(treatmentoffset) AS rrt_first_off,
        MAX(treatmentoffset) AS rrt_last_off
    FROM eicu.rrt_treatment
    GROUP BY patientunitstayid
),

rrt_history AS (
    SELECT DISTINCT patientunitstayid
    FROM eicu.id_rrt_without_record
),

aki_creat AS (
    SELECT st.patienthealthsystemstayid,
           st.patientunitstayid,
           st.hospitaladmitoffset,
           st.hospitaldischargeoffset,
           st.unitdischargeoffset,
           st.chartoffset AS chartoffset_minute_since_intime,
           st.t0_aki_relaxed,
           st.cr_baseline,
           st.creat_low_past_48hr,
           st.rrt_72hr_prior_and_24hr_post,
           st.kd_diagnosis,
           st.kd_diagnosis_string,
           st.creatinine,
           st.uo_rt_6hr, st.uo_rt_12hr, st.uo_rt_24hr,
           st.aki_stage_uo,
           st.aki_stage_creat,
           st.aki_stage,
           st.aki
    FROM eicu.kdigo2012_stages st
),

aki AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY patientunitstayid
               ORDER BY chartoffset_minute_since_intime
           ) AS offset_order
    FROM aki_creat
    WHERE patientunitstayid IN (
        SELECT DISTINCT patientunitstayid
        FROM aki_creat
        WHERE aki_stage_creat >= 1 AND chartoffset_minute_since_intime >= 0
    )
    -- ★ 无 RRT 排除 (与 e25 的唯一差异)
    AND aki_stage_creat IS NOT NULL
    AND chartoffset_minute_since_intime >= 0
),

aki_icu_onset AS (
    SELECT DISTINCT patientunitstayid
    FROM aki
    WHERE t0_aki_relaxed >= 720
)

SELECT
    aki.patienthealthsystemstayid,
    aki.patientunitstayid,
    RANK() OVER (
        PARTITION BY aki.patienthealthsystemstayid
        ORDER BY aki.hospitaladmitoffset
    ) AS stayid_order,
    aki.hospitaladmitoffset,
    aki.hospitaldischargeoffset,
    aki.unitdischargeoffset,
    aki.chartoffset_minute_since_intime,
    aki.t0_aki_relaxed,
    aki.offset_order,
    aki.cr_baseline,
    aki.creat_low_past_48hr,
    aki.rrt_72hr_prior_and_24hr_post,
    aki.kd_diagnosis,
    aki.kd_diagnosis_string,
    aki.creatinine,
    aki.aki_stage_creat,
    aki.uo_rt_6hr, aki.uo_rt_12hr, aki.uo_rt_24hr,
    aki.aki_stage_uo,
    aki.aki_stage,
    aki.aki,
    -- ★ RRT 标注列
    COALESCE(rf.rrt_ever, FALSE) AS rrt_ever,
    rf.rrt_first_off,
    rf.rrt_last_off,
    (rf.rrt_first_off IS NOT NULL AND rf.rrt_first_off < aki.t0_aki_relaxed)
        AS rrt_before_t0,
    (rf.rrt_first_off IS NOT NULL AND rf.rrt_first_off < 0) AS rrt_before_icu,
    (
        rh.patientunitstayid IS NOT NULL
        OR LOWER(COALESCE(aki.kd_diagnosis, '')) LIKE '%rrt%'
        OR LOWER(COALESCE(aki.kd_diagnosis_string, '')) LIKE '%esrd%'
        OR LOWER(COALESCE(aki.kd_diagnosis_string, '')) LIKE '%dialysis%'
    ) AS esrd_or_rrt_history
FROM aki
LEFT JOIN rrt_flag rf ON rf.patientunitstayid = aki.patientunitstayid
LEFT JOIN rrt_history rh ON rh.patientunitstayid = aki.patientunitstayid
WHERE aki.patientunitstayid IN (SELECT patientunitstayid FROM aki_icu_onset)
ORDER BY aki.patientunitstayid, aki.offset_order;

CREATE INDEX IF NOT EXISTS idx_eicu_kd2012_720m_withrrt_stay
  ON eicu.kdigo2012_aki_after_icu_720m (patientunitstayid);
CREATE INDEX IF NOT EXISTS idx_eicu_kd2012_720m_withrrt_rrt
  ON eicu.kdigo2012_aki_after_icu_720m (rrt_ever);
ANALYZE eicu.kdigo2012_aki_after_icu_720m;

\echo '=== eicu.kdigo2012_aki_after_icu_720m (WITH RRT, v1.0) 已创建 ==='
