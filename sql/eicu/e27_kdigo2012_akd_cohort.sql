-- =============================================================================
-- e27_kdigo2012_akd_cohort.sql — eICU KDIGO 2012 版 AKD Cohort (v1.0)
-- Author: 米好 for 朝阳
-- Date  : 2026-07-28
--
-- 目的: 外部验证第 1 库。忠实移植 MIMIC 26_kdigo2012_akd_cohort.sql (v1.1)
--       的 ADQI-16 严格版 AKD 判定逻辑, 保证三库标签定义完全一致。
--
-- 与 MIMIC 版关键差异 (eICU 数据结构适配):
--   ① 时间: eICU 全部为「相对 ICU intime 的分钟 offset」, 无 timestamp。
--      所有 INTERVAL 换算成分钟:  7d=10080, 24h=1440, 48h=2880,
--      14d=20160, 6d=8640。
--   ② ID: 用 patientunitstayid (单次 ICU stay), 对应 MIMIC stay_id。
--   ③ 死亡时点: eICU 无精确死亡时刻。院内死亡 (icustay_detail.hosp_mort=1)
--      用 hospitaldischargeoffset 近似死亡分钟 offset; 存活者 NULL。
--      —— 此为 eICU 固有限制, 需在敏感性分析中说明。
--   ④ RRT@T7: 上游 e25 视图已整体排除任何出现在 rrt_treatment /
--      id_rrt_without_record 的患者, 故 cohort 内无 RRT 患者, 竞争风险
--      RRT@T7 分支恒 FALSE (记录于论文局限)。
--   ⑤ 出院时点 dischtime → hospitaldischargeoffset (分钟)。
--
-- 数据源:
--   cohort + T0 : eicu.kdigo2012_aki_after_icu_720m_without_rrt (stayid_order=1)
--   staging     : eicu.kdigo2012_stages (chartoffset 分钟, aki_stage_creat)
--   死亡/出院   : eicu.icustay_detail (hosp_mort, hospitaldischargeoffset)
--
-- AKD 判定 (与 MIMIC 26 号完全同构):
--   1. 死亡 ≤T7 (≥T0-24h)                      → AKD=1
--   2. RRT @T7                                  → AKD=1 (eICU 恒 FALSE)
--   3. 随访 <48h                                → NULL
--   4. D7 stage≥1 且 [T7-48h,T7] 有 Cr          → AKD=1
--   5. D7 stage≥1 但 T7 附近无 Cr               → NULL
--   6. D7 stage<1 且"恢复后一周"持续恢复        → AKD=0
--   7. D7 stage<1 但恢复不持续                  → NULL
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_akd_cohort CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_akd_cohort AS
WITH

-- 1. cohort: 入 ICU 720min 后首次 AKI, 已排除 RRT, 仅首次 ICU stay
cohort AS (
    SELECT DISTINCT
        v.patienthealthsystemstayid,
        v.patientunitstayid,
        v.hospitaladmitoffset,
        v.hospitaldischargeoffset,
        v.unitdischargeoffset
    FROM eicu.kdigo2012_aki_after_icu_720m_without_rrt v
    WHERE v.stayid_order = 1
),

-- 2. T0: AKI 首发分钟 offset (t0_aki_relaxed, 上游已保证 >= intime+720min)
t0 AS (
    SELECT
        patientunitstayid,
        MIN(t0_aki_relaxed) AS t0_off
    FROM eicu.kdigo2012_aki_after_icu_720m_without_rrt
    WHERE stayid_order = 1
    GROUP BY patientunitstayid
),

-- 3. death: 院内死亡用 hospitaldischargeoffset 近似 (分钟 offset since intime)
death AS (
    SELECT
        c.patientunitstayid,
        CASE WHEN d.hosp_mort = 1 THEN d.hospitaldischargeoffset END AS death_off
    FROM cohort c
    JOIN eicu.icustay_detail d USING (patientunitstayid)
),

-- 4. base: 预计算所有时间窗口 (分钟)
base AS (
    SELECT
        c.*,
        t.t0_off,
        t.t0_off + 10080 AS t7_off,              -- T0 + 7d
        t.t0_off + 10080 - 1440 AS rrt_low,      -- T7 - 24h
        t.t0_off + 10080 + 1440 AS rrt_high,     -- T7 + 24h
        t.t0_off + 10080 - 2880 AS t7_assess_low -- T7 - 48h
    FROM cohort c JOIN t0 t USING (patientunitstayid)
),

-- 5. kd_window_all: 扩展窗口到 T0+14d
kd_window_all AS (
    SELECT
        b.patientunitstayid,
        b.t0_off,
        b.t7_off,
        b.t7_assess_low,
        k.chartoffset,
        k.aki_stage_creat AS stage
    FROM base b
    JOIN eicu.kdigo2012_stages k ON k.patientunitstayid = b.patientunitstayid
    WHERE
        k.aki_stage_creat IS NOT NULL
        AND k.chartoffset BETWEEN b.t0_off AND b.t0_off + 20160
),

-- 6. 逐条标注区间
kd_labeled AS (
    SELECT
        *,
        MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
            OVER (PARTITION BY patientunitstayid) AS first_stage0_off,
        CASE
            WHEN
                MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
                    OVER (PARTITION BY patientunitstayid) IS NOT NULL
                AND chartoffset > MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
                    OVER (PARTITION BY patientunitstayid)
                THEN 1 ELSE 0
        END AS after_first_recovery,
        CASE
            WHEN
                MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
                    OVER (PARTITION BY patientunitstayid) IS NOT NULL
                AND chartoffset > MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
                    OVER (PARTITION BY patientunitstayid)
                AND chartoffset <= MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off)
                    OVER (PARTITION BY patientunitstayid) + 10080
                THEN 1 ELSE 0
        END AS within_recovery_week,
        CASE WHEN chartoffset BETWEEN t0_off AND t7_off THEN 1 ELSE 0 END AS within_t7_window
    FROM kd_window_all
),

-- 7. 单次聚合: per-stay 指标
kd_agg AS (
    SELECT
        patientunitstayid,
        (ARRAY_AGG(stage ORDER BY chartoffset DESC)
            FILTER (WHERE within_t7_window = 1))[1] AS stage_at_7d,
        (ARRAY_AGG(chartoffset ORDER BY chartoffset DESC)
            FILTER (WHERE within_t7_window = 1))[1] AS stage_at_7d_off,
        MAX(CASE WHEN chartoffset >= t7_assess_low AND chartoffset <= t7_off
            THEN 1 ELSE 0 END)::BOOLEAN AS has_cr_near_t7,
        MIN(chartoffset) FILTER (WHERE stage < 1 AND chartoffset <= t7_off) AS first_stage0_off,
        (MAX(CASE
            WHEN within_recovery_week = 1
                AND chartoffset > first_stage0_off + 2880
                AND stage >= 1
            THEN 1 ELSE 0 END) = 1)::BOOLEAN AS has_rebound,
        MAX(CASE WHEN within_recovery_week = 1 THEN chartoffset END) AS recovery_week_end
    FROM kd_labeled
    GROUP BY patientunitstayid
),

-- 8. 全量 last_cr (随访终点)
last_cr AS (
    SELECT
        b.patientunitstayid,
        MAX(k.chartoffset) AS last_cr_off
    FROM base b
    JOIN eicu.kdigo2012_stages k ON k.patientunitstayid = b.patientunitstayid
    WHERE k.aki_stage_creat IS NOT NULL
    GROUP BY b.patientunitstayid
),

-- 9. 持续恢复判定 (含总随访 >=48h 约束)
sustained_recovery AS (
    SELECT
        ka.patientunitstayid,
        (
            ka.first_stage0_off IS NOT NULL
            AND ka.stage_at_7d < 1
            AND COALESCE(ka.has_rebound, FALSE) = FALSE
            AND (COALESCE(ka.recovery_week_end, b.t7_off) - ka.first_stage0_off) >= 2880
            AND (
                LEAST(
                    COALESCE(d.death_off, 2147483647),
                    b.hospitaldischargeoffset,
                    COALESCE(lc.last_cr_off, 2147483647)
                ) - b.t0_off
            ) >= 2880
        ) AS is_sustained_recovery,
        CASE
            WHEN ka.first_stage0_off IS NOT NULL
                THEN (COALESCE(ka.recovery_week_end, ka.stage_at_7d_off) - ka.first_stage0_off)
        END AS recovery_duration_min,
        COALESCE(ka.has_rebound, FALSE) AS has_rebound
    FROM kd_agg ka
    JOIN base b USING (patientunitstayid)
    LEFT JOIN death d USING (patientunitstayid)
    LEFT JOIN last_cr lc USING (patientunitstayid)
)

-- ==========================================================================
-- 主查询
-- ==========================================================================
SELECT
    b.patienthealthsystemstayid,
    b.patientunitstayid,
    b.hospitaladmitoffset,
    b.hospitaldischargeoffset,
    b.unitdischargeoffset,
    d.death_off,
    b.t0_off,
    b.t7_off,

    (
        d.death_off IS NOT NULL
        AND d.death_off >= b.t0_off - 1440
        AND d.death_off <= b.t7_off
    ) AS death_within_7d,

    COALESCE(ka.stage_at_7d, 0)::NUMERIC AS stage_at_7d,
    ka.stage_at_7d_off,
    COALESCE(ka.has_cr_near_t7, FALSE) AS has_cr_near_t7,
    ka.first_stage0_off,
    COALESCE(sr.is_sustained_recovery, FALSE) AS is_sustained_recovery,
    sr.recovery_duration_min,
    COALESCE(sr.has_rebound, FALSE) AS has_rebound,
    FALSE AS rrt_active_at_7d,   -- eICU cohort 已排除全部 RRT 患者

    (LEAST(
        COALESCE(d.death_off, 2147483647),
        b.hospitaldischargeoffset,
        COALESCE(lc.last_cr_off, 2147483647)
    ) - b.t0_off) AS followup_duration_min,

    -- ================================================================
    -- AKD 标签 (与 MIMIC 26 号完全同构)
    -- ================================================================
    CASE
        WHEN (
            d.death_off IS NOT NULL
            AND d.death_off >= b.t0_off - 1440
            AND d.death_off <= b.t7_off
        ) THEN 1

        -- RRT@T7: eICU 恒 FALSE, 保留分支结构
        WHEN FALSE THEN 1

        WHEN (LEAST(
            COALESCE(d.death_off, 2147483647), b.hospitaldischargeoffset,
            COALESCE(lc.last_cr_off, 2147483647)
        ) - b.t0_off) < 2880 THEN NULL

        WHEN COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(ka.has_cr_near_t7, FALSE) = TRUE THEN 1

        WHEN COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(ka.has_cr_near_t7, FALSE) = FALSE THEN NULL

        WHEN COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = TRUE THEN 0

        WHEN COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = FALSE THEN NULL
    END AS akd_flag,

    -- ================================================================
    -- 排除原因
    -- ================================================================
    CASE
        WHEN (LEAST(
            COALESCE(d.death_off, 2147483647), b.hospitaldischargeoffset,
            COALESCE(lc.last_cr_off, 2147483647)
        ) - b.t0_off) < 2880
        AND NOT (
            d.death_off IS NOT NULL
            AND d.death_off >= b.t0_off - 1440
            AND d.death_off <= b.t7_off
        )
            THEN CASE
                WHEN d.death_off IS NOT NULL
                    AND d.death_off >= b.t0_off - 1440
                    AND d.death_off <= b.t0_off + 2880
                    THEN 'early_death_lt48h'
                WHEN (b.hospitaldischargeoffset - b.t0_off) < 2880
                    THEN 'early_discharge_or_transfer'
                ELSE 'insufficient_followup_lt48h'
            END

        WHEN COALESCE(ka.has_cr_near_t7, FALSE) = FALSE
            AND NOT (
                d.death_off IS NOT NULL
                AND d.death_off >= b.t0_off - 1440
                AND d.death_off <= b.t7_off
            )
            AND (LEAST(
                COALESCE(d.death_off, 2147483647), b.hospitaldischargeoffset,
                COALESCE(lc.last_cr_off, 2147483647)
            ) - b.t0_off) >= 2880
            THEN CASE
                WHEN ka.stage_at_7d IS NULL THEN 'no_cr_in_entire_window'
                WHEN (b.hospitaldischargeoffset - b.t0_off) < 10080
                    THEN 'discharged_before_day7_no_near_t7_measurement'
                WHEN lc.last_cr_off < b.t7_assess_low
                    THEN 'last_cr_before_t7_window'
                ELSE 'no_cr_near_day7_other'
            END

        WHEN COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = FALSE
            AND NOT (
                d.death_off IS NOT NULL
                AND d.death_off >= b.t0_off - 1440
                AND d.death_off <= b.t7_off
            )
            THEN CASE
                WHEN ka.first_stage0_off IS NULL
                    THEN 'recovery_status_uncertain_no_stage0_record'
                WHEN COALESCE(sr.has_rebound, FALSE) = TRUE
                    THEN 'rebound_second_aki_after_initial_recovery'
                ELSE 'recovery_not_sustained_unconfirmed'
            END
    END AS exclusion_reason

FROM base b
LEFT JOIN death d USING (patientunitstayid)
LEFT JOIN kd_agg ka USING (patientunitstayid)
LEFT JOIN last_cr lc USING (patientunitstayid)
LEFT JOIN sustained_recovery sr USING (patientunitstayid);

CREATE UNIQUE INDEX IF NOT EXISTS idx_eicu_kdigo2012_akd_cohort_stay
    ON eicu.kdigo2012_akd_cohort (patientunitstayid);
CREATE INDEX IF NOT EXISTS idx_eicu_kdigo2012_akd_cohort_flag
    ON eicu.kdigo2012_akd_cohort (akd_flag);

ANALYZE eicu.kdigo2012_akd_cohort;

\echo '=== eicu.kdigo2012_akd_cohort v1.0 (ADQI-16 严格版, 分钟 offset) 已创建 ==='
