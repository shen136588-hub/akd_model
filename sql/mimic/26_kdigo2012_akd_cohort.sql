-- =============================================================================
-- 26_kdigo2012_akd_cohort.sql — KDIGO 2012 版 AKD Cohort (v1.1)
-- Author: 米好 for 朝阳
-- Date  : 2026-07-24
--
-- 设计依据:
--   * KDIGO 2012 AKI 诊断与分期标准 (Section 2.1.1, 2.1.2)
--   * ADQI-16 (Chawla et al., 2017, Nat Rev Nephrol): AKD = AKI stage ≥1 持续 ≥7d
--   * 结构对标 mimiciv_akd_cohort_v0.4.sql
--
-- 数据源 (KDIGO 2012 管线):
--   cohort + T0 : mimiciv_derived.kdigo2012_aki_after_icu_720m_without_rrt
--   staging     : mimiciv_derived.kdigo2012_stages
--   RRT         : mimiciv_derived.rrt_active
--   death       : mimiciv_hosp.admissions + mimiciv_hosp.patients
--
-- 前置修正 (21_kdigo2012_aki_diagnosis v2, 2026-07-24):
--   标准 B 1.5× 参考值从 creat_low_past_7day 改为 cr_baseline, 与 KDIGO 2012
--   "≥1.5 times baseline" 一致, 诊断与分期参考值统一, 消除 stage_at_t0 < 1 的 artifact.
--
-- v1.0 vs 旧 26_kdigo2012_akd_cohort 关键变化:
--   ① stay_id JOIN (非 hadm_id): 避免多次 ICU 住院的跨 stay 污染
--   ② AKD=1 要求 [T7-48h, T7] 内有 Cr 确认 (has_cr_near_t7)
--   ③ AKD=0 要求"后面一周"持续恢复: 首次 stage<1 在 T7 前,
--      且恢复后一周内无反弹 (允许 48h 内短暂波动)
--   ④ 性能优化: 窗口函数替代相关子查询, 单次扫描 kdigo2012_stages
--   ⑤ 死亡下限: death ≥ T0-24h (排除 T0 前已死亡)
--
-- v1.1 修正 (2026-07-24):
--   ⑥ patients.dod::timestamp 精度补齐.
--   ⑦ sustained_recovery 追加"总随访 ≥48h"约束.
--
-- 索引依赖:
--   idx_kdigo2012_stages_stay_time ON kdigo2012_stages(stay_id, charttime)
--   idx_kdigo2012_720m_stay        ON kdigo2012_aki_after_icu_720m_without_rrt(stay_id)
--   idx_rrt_stay_time              ON rrt_active(stay_id, charttime)
--
-- ADQI-16 判定逻辑:
--   * AKD = AKI stage ≥1 持续 ≥7 days
--   * 死亡 ≤T7 / RRT @T7 → AKD=1 (竞争风险)
--   * 恢复必须持续 ("后面一周"无反弹), 允许 48h 内波动
-- =============================================================================

-- ==========================================================================
-- 前置索引 (仅首次执行)
-- ==========================================================================
CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_stay_time
ON mimiciv_derived.kdigo2012_stages (stay_id, charttime)
WHERE aki_stage_creat IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_720m_stay
ON mimiciv_derived.kdigo2012_aki_after_icu_720m_without_rrt (stay_id);

CREATE INDEX IF NOT EXISTS idx_rrt_stay_time
ON mimiciv_derived.rrt_active (stay_id, charttime);

-- ==========================================================================
-- 创建物化视图
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_akd_cohort CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_akd_cohort AS
WITH

-- 1. cohort: KDIGO 2012 管线, 入 ICU 720min 后首次 AKI, 排除 RRT, 仅首次 ICU stay
cohort AS (
    SELECT DISTINCT
        v.subject_id,
        v.hadm_id,
        v.stay_id,
        v.intime,
        v.outtime,
        v.admittime,
        v.dischtime
    FROM mimiciv_derived.kdigo2012_aki_after_icu_720m_without_rrt v
    WHERE v.stayid_order = 1
),

-- 2. T0: AKI 首发时间 (来自 kdigo2012_aki_onset → t0_aki_relaxed)
--     25 已通过 t0_aki_relaxed - intime >= 12h 确保均为 ICU-onset AKI
t0 AS (
    SELECT
        stay_id,
        MIN(t0_aki_relaxed) AS t0_time
    FROM mimiciv_derived.kdigo2012_aki_after_icu_720m_without_rrt
    WHERE stayid_order = 1
    GROUP BY stay_id
),

-- 3. death
--    patients.dod 为 date 类型, 直接 ::timestamp 会得 00:00:00, 系统性早于真实死亡
--    时刻 0-24h. 保守取当日 23:59:59 (dod + 1 day - 1 second), 避免 dod 早于 dischtime
--    导致的 followup_duration 低估.
death AS (
    SELECT
        b.stay_id,
        COALESCE(
            a.deathtime,
            p.dod::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 second'
        ) AS death_time
    FROM cohort b
    JOIN mimiciv_hosp.admissions a USING (hadm_id)
    JOIN mimiciv_hosp.patients p ON a.subject_id = p.subject_id
),

-- 4. base (预计算所有时间窗口)
base AS (
    SELECT
        c.*,
        t.t0_time,
        t.t0_time + INTERVAL '7 days' AS t7_time,
        t.t0_time + INTERVAL '7 days' - INTERVAL '24 hours' AS rrt_low,
        t.t0_time + INTERVAL '7 days' + INTERVAL '24 hours' AS rrt_high,
        t.t0_time + INTERVAL '7 days' - INTERVAL '48 hours' AS t7_assess_low
    FROM cohort c JOIN t0 t USING (stay_id)
),

-- ★ 5. kd_window_all: 扩展窗口到 T0+14d (支持"后面一周"持续恢复检查)
--    使用 stay_id JOIN (非 hadm_id), 避免多次 ICU 住院的跨 stay 污染
kd_window_all AS (
    SELECT
        b.stay_id,
        b.t0_time,
        b.t7_time,
        b.t7_assess_low,
        k.charttime,
        k.aki_stage_creat AS stage
    FROM base b
    JOIN mimiciv_derived.kdigo2012_stages k ON k.stay_id = b.stay_id
    WHERE
        k.aki_stage_creat IS NOT NULL
        AND k.charttime BETWEEN b.t0_time AND b.t0_time + INTERVAL '14 days'
),

-- ★ 6. 一次性标注: 每条记录在哪个区间
kd_labeled AS (
    SELECT
        *,
        -- 首次恢复时间 (在 T7 前)
        MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
            OVER (PARTITION BY stay_id) AS first_stage0_time,
        -- 是否在首次恢复后
        CASE
            WHEN
                MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
                    OVER (PARTITION BY stay_id)
                IS NOT NULL
                AND charttime > MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
                    OVER (PARTITION BY stay_id)
                THEN 1
            ELSE 0
        END AS after_first_recovery,
        -- 是否在"恢复后一周"窗口内
        -- [first_stage0, first_stage0 + 7d], 这是持续恢复的检测窗口
        CASE
            WHEN
                MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
                    OVER (PARTITION BY stay_id)
                IS NOT NULL
                AND charttime > MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
                    OVER (PARTITION BY stay_id)
                AND charttime <= MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time)
                    OVER (PARTITION BY stay_id)
                + INTERVAL '7 days'
                THEN 1
            ELSE 0
        END AS within_recovery_week,
        -- 是否在 T7 窗口 [T0, T7] 内 (主判定窗口)
        CASE WHEN charttime BETWEEN t0_time AND t7_time THEN 1 ELSE 0 END AS within_t7_window
    FROM kd_window_all
),

-- ★ 7. 单次聚合: 所有 per-stay 指标
kd_agg AS (
    SELECT
        stay_id,
        -- D7 状态: [T0, T7] 窗口内最后一条 (用 FILTER 确保只取窗口内)
        (
            ARRAY_AGG(stage ORDER BY charttime DESC)
            FILTER (WHERE within_t7_window = 1)
        )[1
        ] AS stage_at_7d,
        (
            ARRAY_AGG(charttime ORDER BY charttime DESC)
            FILTER (WHERE within_t7_window = 1)
        )[1
        ] AS stage_at_7d_time,
        -- T7 附近 [T7-48h, T7] 有 Cr?
        MAX(CASE
            WHEN charttime >= t7_assess_low AND charttime <= t7_time
                THEN 1
            ELSE 0
        END)::BOOLEAN AS has_cr_near_t7,
        -- 首次恢复时间 (T7 前)
        MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_time) AS first_stage0_time,
        -- ★ 反弹: 仅检测"恢复后一周内"的反弹 (不超过 T7)
        --    [first_recovery + 48h, MIN(first_recovery + 7d, T7)]
        --    允许恢复后 48h 内的短暂波动, 但一周内不能有确定的反弹
        (MAX(CASE
            WHEN
                within_recovery_week = 1
                AND charttime > first_stage0_time + INTERVAL '48 hours'
                AND stage >= 1
                THEN 1
            ELSE 0
        END) = 1)::BOOLEAN AS has_rebound,
        -- 恢复后一周的结束点 (封顶 T7)
        MAX(CASE WHEN within_recovery_week = 1 THEN charttime END) AS recovery_week_end
    FROM kd_labeled
    GROUP BY stay_id
),

-- 8. 持续恢复: 首次恢复在 T7 前, T7 时仍 stage<1, 恢复后一周内无反弹
--    v1.1: 追加"总随访 ≥48h"约束, 与主判定优先级 3 (随访<48h → NULL) 语义对齐,
--    避免 is_sustained_recovery=TRUE 但整体随访不足的语义矛盾.
sustained_recovery AS (
    SELECT
        ka.stay_id,
        (
            ka.first_stage0_time IS NOT NULL
            AND ka.stage_at_7d < 1
            AND COALESCE(ka.has_rebound, FALSE) = FALSE
            -- 恢复窗口至少 48h
            AND (
                COALESCE(ka.recovery_week_end, b.t7_time)
                - ka.first_stage0_time
            ) >= INTERVAL '48 hours'
            -- v1.1: 总随访 (T0 → LEAST(死亡, 出院, 末次Cr)) 也须 ≥48h
            AND (
                LEAST(
                    COALESCE(d.death_time, 'infinity'::TIMESTAMP),
                    b.dischtime,
                    COALESCE(lc.last_cr_time, 'infinity'::TIMESTAMP)
                ) - b.t0_time
            ) >= INTERVAL '48 hours'
        ) AS is_sustained_recovery,
        CASE
            WHEN ka.first_stage0_time IS NOT NULL
                THEN (
                    COALESCE(ka.recovery_week_end, ka.stage_at_7d_time)
                    - ka.first_stage0_time
                )
        END AS recovery_duration,
        COALESCE(ka.has_rebound, FALSE) AS has_rebound
    FROM kd_agg ka
    JOIN base b ON ka.stay_id = b.stay_id
    LEFT JOIN death d ON d.stay_id = ka.stay_id
    LEFT JOIN (
        SELECT
            bb.stay_id,
            MAX(k.charttime) AS last_cr_time
        FROM base bb
        JOIN mimiciv_derived.kdigo2012_stages k ON k.stay_id = bb.stay_id
        WHERE k.aki_stage_creat IS NOT NULL
        GROUP BY bb.stay_id
    ) lc ON lc.stay_id = ka.stay_id
),

-- 9. 全量 last_cr (用于随访终点, 从扩展窗口获取)
last_cr AS (
    SELECT
        b.stay_id,
        MAX(k.charttime) AS last_cr_time
    FROM base b
    JOIN mimiciv_derived.kdigo2012_stages k ON k.stay_id = b.stay_id
    WHERE k.aki_stage_creat IS NOT NULL
    GROUP BY b.stay_id
),

-- 10. RRT at T7
rrt_at_7d AS (
    SELECT
        b.stay_id,
        TRUE AS rrt_active_at_7d
    FROM base b
    WHERE EXISTS (
        SELECT 1 FROM mimiciv_derived.rrt_active r
        WHERE
            r.stay_id = b.stay_id
            AND r.rt_active = 1
            AND r.charttime BETWEEN b.rrt_low AND b.rrt_high
    )
)

-- ==========================================================================
-- 主查询
-- ==========================================================================
SELECT
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.intime AS icu_intime,
    b.outtime AS icu_outtime,
    b.admittime,
    b.dischtime,
    d.death_time,
    b.t0_time,
    b.t7_time,

    (
        d.death_time IS NOT NULL
        AND d.death_time >= b.t0_time - INTERVAL '24 hours'
        AND d.death_time <= b.t7_time
    ) AS death_within_7d,

    COALESCE(ka.stage_at_7d, 0)::NUMERIC AS stage_at_7d,
    ka.stage_at_7d_time,
    COALESCE(ka.has_cr_near_t7, FALSE) AS has_cr_near_t7,
    ka.first_stage0_time,
    COALESCE(sr.is_sustained_recovery, FALSE) AS is_sustained_recovery,
    sr.recovery_duration,
    COALESCE(sr.has_rebound, FALSE) AS has_rebound,
    COALESCE(r.rrt_active_at_7d, FALSE) AS rrt_active_at_7d,

    (LEAST(
        COALESCE(d.death_time, 'infinity'::TIMESTAMP),
        b.dischtime,
        COALESCE(lc.last_cr_time, 'infinity'::TIMESTAMP)
    )
    - b.t0_time) AS followup_duration,

    -- ================================================================
    -- AKD 标签
    -- ================================================================
    CASE
        -- 1. 死亡 ≤T7 (≥T0-24h)
        WHEN (
            d.death_time IS NOT NULL
            AND d.death_time >= b.t0_time - INTERVAL '24 hours'
            AND d.death_time <= b.t7_time
        ) THEN 1

        -- 2. RRT @T7
        WHEN COALESCE(r.rrt_active_at_7d, FALSE) THEN 1

        -- 3. 随访 < 48h → NULL
        WHEN (LEAST(
            COALESCE(d.death_time, 'infinity'::TIMESTAMP), b.dischtime,
            COALESCE(lc.last_cr_time, 'infinity'::TIMESTAMP)
        ) - b.t0_time)
        < INTERVAL '48 hours' THEN NULL

        -- 4. D7 stage ≥ 1 且有 T7 附近 Cr 确认 → AKD=1
        WHEN
            COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(ka.has_cr_near_t7, FALSE) = TRUE THEN 1

        -- 5. D7 stage ≥ 1 但无 T7 附近 Cr → NULL (无法确认持续到D7)
        WHEN
            COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(ka.has_cr_near_t7, FALSE) = FALSE THEN NULL

        -- 6. D7 stage < 1 且"后面一周"持续恢复 → AKD=0
        --    不需要 has_cr_near_t7: 恢复质量由 sustained_recovery 保证
        WHEN
            COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = TRUE THEN 0

        -- 7. D7 stage < 1 但恢复不持续 → NULL
        WHEN
            COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = FALSE THEN NULL
    END AS akd_flag,

    -- ================================================================
    -- 排除原因
    -- ================================================================
    CASE
        WHEN (LEAST(
            COALESCE(d.death_time, 'infinity'::TIMESTAMP), b.dischtime,
            COALESCE(lc.last_cr_time, 'infinity'::TIMESTAMP)
        ) - b.t0_time)
        < INTERVAL '48 hours'
        AND NOT (
            d.death_time IS NOT NULL
            AND d.death_time >= b.t0_time - INTERVAL '24 hours'
            AND d.death_time <= b.t7_time
        )
        AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
            THEN CASE
                WHEN
                    d.death_time IS NOT NULL
                    AND d.death_time >= b.t0_time - INTERVAL '24 hours'
                    AND d.death_time <= b.t0_time + INTERVAL '48 hours'
                    THEN 'early_death_lt48h'
                WHEN (b.dischtime - b.t0_time) < INTERVAL '48 hours'
                    THEN 'early_discharge_or_transfer'
                ELSE 'insufficient_followup_lt48h'
            END

        WHEN
            COALESCE(ka.has_cr_near_t7, FALSE) = FALSE
            AND NOT (
                d.death_time IS NOT NULL
                AND d.death_time >= b.t0_time - INTERVAL '24 hours'
                AND d.death_time <= b.t7_time
            )
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
            AND (LEAST(
                COALESCE(d.death_time, 'infinity'::TIMESTAMP), b.dischtime,
                COALESCE(lc.last_cr_time, 'infinity'::TIMESTAMP)
            ) - b.t0_time)
            >= INTERVAL '48 hours'
            THEN CASE
                WHEN ka.stage_at_7d IS NULL THEN 'no_cr_in_entire_window'
                WHEN (b.dischtime - b.t0_time) < INTERVAL '7 days'
                    THEN 'discharged_before_day7_no_near_t7_measurement'
                WHEN lc.last_cr_time < b.t7_assess_low
                    THEN 'last_cr_before_t7_window'
                ELSE 'no_cr_near_day7_other'
            END

        WHEN
            COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = FALSE
            AND NOT (
                d.death_time IS NOT NULL
                AND d.death_time >= b.t0_time - INTERVAL '24 hours'
                AND d.death_time <= b.t7_time
            )
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
            THEN CASE
                WHEN ka.first_stage0_time IS NULL
                    THEN 'recovery_status_uncertain_no_stage0_record'
                WHEN COALESCE(sr.has_rebound, FALSE) = TRUE
                    THEN 'rebound_second_aki_after_initial_recovery'
                WHEN
                    ka.stage_at_7d IS NOT NULL AND ka.stage_at_7d < 1
                    AND ka.first_stage0_time IS NOT NULL
                    AND COALESCE(sr.has_rebound, FALSE) = FALSE
                    THEN 'recovery_confirmed_but_insufficient_followup_after_recovery'
                ELSE 'recovery_not_sustained_unconfirmed'
            END
    END AS exclusion_reason

FROM base b
LEFT JOIN death d USING (stay_id)
LEFT JOIN kd_agg ka USING (stay_id)
LEFT JOIN last_cr lc USING (stay_id)
LEFT JOIN rrt_at_7d r USING (stay_id)
LEFT JOIN sustained_recovery sr USING (stay_id);

-- ==========================================================================
-- 索引
-- ==========================================================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_kdigo2012_akd_cohort_stay ON mimiciv_derived.kdigo2012_akd_cohort (stay_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_akd_cohort_hadm ON mimiciv_derived.kdigo2012_akd_cohort (hadm_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_akd_cohort_flag ON mimiciv_derived.kdigo2012_akd_cohort (akd_flag);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_akd_cohort_t0 ON mimiciv_derived.kdigo2012_akd_cohort (t0_time);

ANALYZE mimiciv_derived.kdigo2012_akd_cohort;

\echo '=== kdigo2012_akd_cohort v1.1 (KDIGO 2012, ADQI-16 严格版) 已创建 ==='
