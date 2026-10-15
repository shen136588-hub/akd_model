-- =============================================================================
-- s04b_kdigo2012_aki_after_icu_12h.sql  (SICdb, WITH-RRT version, 2026-08-02)
-- Author: 米好 for 朝阳
--
-- 目的: s04_kdigo2012_aki_after_icu_12h_no_rrt.sql 的「不排除 RRT」孪生视图。
--       原视图保留不动。与 MIMIC 25b / eICU e25b 结构对齐。
--
-- 与 s04 的唯一结构差异:
--   * eligible_stays 不再 EXCEPT (rrt ∪ id_rrt_without_record)
--   * 新增 RRT 标注列 (供 s05b 做竞争风险与净化窗校正):
--       rrt_ever            该 stay 是否有 dialysis_active=1 记录
--       rrt_first_sec       首次活跃 RRT 的秒 offset (相对入院, 与 charttime 同锚)
--       rrt_last_sec        末次活跃 RRT 的秒 offset
--       rrt_before_t0       首次 RRT 早于 AKI 诊断 T0
--       esrd_or_rrt_history 来自 id_rrt_without_record, 或 cases.hoursofcrrt 提示
--                           长期 CRRT, 或 aki_or_ckd 诊断文本提示透析依赖
--
-- ⚠️ SICdb 优势: cases.hoursofcrrt 直接给出 CRRT 总时长, 是三库中唯一可直接量化
--    RRT 暴露强度的库 → 含 RRT 分析里可做 "RRT 时长 vs AKD" 的剂量反应。
--
-- 时间口径: 全部为「相对入院的秒 offset」; ICU intime = icustays.icu_offset_sec。
-- 依赖: kdigo2012_stages, rrt, id_rrt_without_record, icustays, aki_or_ckd, cases
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_aki_after_icu_12h CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_aki_after_icu_12h AS
WITH
rrt_flag AS (
    SELECT
        stay_id,
        TRUE AS rrt_ever,
        MIN(charttime_offset) AS rrt_first_sec,
        MAX(charttime_offset) AS rrt_last_sec
    FROM sicdb.rrt
    WHERE stay_id IS NOT NULL AND dialysis_active = 1
    GROUP BY stay_id
),

rrt_history AS (
    SELECT DISTINCT stay_id
    FROM sicdb.id_rrt_without_record
    WHERE stay_id IS NOT NULL
),

aki_positive_stays AS (
    SELECT DISTINCT stay_id
    FROM sicdb.kdigo2012_stages
    WHERE charttime_offset > 0
      AND aki_stage_creat >= 1
),

-- ★ 无 RRT 排除 (与 s04 的唯一差异)
eligible_stays AS (
    SELECT stay_id FROM aki_positive_stays
),

aki AS (
    SELECT
        st.stay_id,
        st.charttime_offset,
        st.charttime_hours,
        st.t0_sec,
        st.charttime_hours_since_t0,
        st.aki_stage_creat,
        st.aki_stage_uo,
        st.rrt_flag,
        st.aki_stage,
        ROW_NUMBER() OVER (
            PARTITION BY st.stay_id ORDER BY st.charttime_offset
        ) AS offset_order
    FROM sicdb.kdigo2012_stages st
    WHERE st.stay_id IN (SELECT stay_id FROM eligible_stays)
      AND st.aki_stage_creat IS NOT NULL
      AND st.charttime_offset >= 0
),

qualifying_stays AS (
    SELECT a.stay_id, MIN(a.charttime_offset) AS first_aki_offset
    FROM aki a
    JOIN sicdb.icustays ie ON ie.stay_id = a.stay_id
    WHERE a.aki_stage_creat >= 1
      AND (a.t0_sec - ie.icu_offset_sec) >= 43200
    GROUP BY a.stay_id
)

SELECT
    ie.subject_id,
    ie.hadm_id,
    aki.stay_id,
    aki.charttime_offset,
    aki.charttime_hours,
    ROUND(aki.charttime_offset / 60.0, 2)  AS chartoffset_minute_since_intime,
    aki.offset_order,
    aki.t0_sec,
    aki.charttime_hours_since_t0,
    qs.first_aki_offset,
    ROUND(qs.first_aki_offset / 3600.0, 2) AS first_aki_hours,
    aki.aki_stage_creat,
    aki.aki_stage_uo,
    aki.aki_stage,
    aki.rrt_flag,
    kd.kd_diagnosis,
    kd.icd_kd_diagnosis,
    -- ★ RRT 标注列
    COALESCE(rf.rrt_ever, FALSE) AS rrt_ever,
    rf.rrt_first_sec,
    rf.rrt_last_sec,
    (rf.rrt_first_sec IS NOT NULL AND rf.rrt_first_sec < aki.t0_sec)
        AS rrt_before_t0,
    (rf.rrt_first_sec IS NOT NULL AND rf.rrt_first_sec < ie.icu_offset_sec)
        AS rrt_before_icu,
    cs.hoursofcrrt,
    (
        rh.stay_id IS NOT NULL
        OR LOWER(COALESCE(kd.kd_diagnosis, '')) LIKE '%rrt%'
        OR LOWER(COALESCE(kd.kd_diagnosis, '')) LIKE '%dialys%'
        OR LOWER(COALESCE(kd.icd_kd_diagnosis, '')) LIKE '%z99.2%'
    ) AS esrd_or_rrt_history
FROM aki
JOIN qualifying_stays qs ON aki.stay_id = qs.stay_id
LEFT JOIN sicdb.icustays   ie ON aki.stay_id = ie.stay_id
LEFT JOIN sicdb.aki_or_ckd kd ON aki.stay_id = kd.stay_id
LEFT JOIN rrt_flag         rf ON rf.stay_id = aki.stay_id
LEFT JOIN rrt_history      rh ON rh.stay_id = aki.stay_id
LEFT JOIN sicdb.cases      cs ON cs.caseid = aki.stay_id
ORDER BY aki.stay_id, aki.offset_order;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_12h_withrrt_stay
    ON sicdb.kdigo2012_aki_after_icu_12h (stay_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_12h_withrrt_stay_offset
    ON sicdb.kdigo2012_aki_after_icu_12h (stay_id, charttime_offset);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_12h_withrrt_rrt
    ON sicdb.kdigo2012_aki_after_icu_12h (rrt_ever);
ANALYZE sicdb.kdigo2012_aki_after_icu_12h;

\echo '=== sicdb.kdigo2012_aki_after_icu_12h (WITH RRT, v1.0) 已创建 ==='
