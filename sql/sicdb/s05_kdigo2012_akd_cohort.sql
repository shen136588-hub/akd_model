-- =============================================================================
-- s05_kdigo2012_akd_cohort.sql — SICdb KDIGO 2012 版 AKD Cohort (v1.0)
-- Author: 米好 for 朝阳
-- Date  : 2026-07-28
--
-- 目的: 外部验证第 2 库 (欧洲, 高质量真实 baseline Cr + 院外死亡随访)。
--       忠实移植 MIMIC 26_kdigo2012_akd_cohort.sql (v1.1) 的 ADQI-16 严格版
--       AKD 判定逻辑, 保证三库标签定义完全一致。
--
-- 与 MIMIC 版关键差异 (SICdb 数据结构适配):
--   ① 时间: SICdb 全部为「相对入院的秒 offset」。INTERVAL 换算成秒:
--      7d=604800, 24h=86400, 48h=172800, 14d=1209600, 6d=518400。
--   ② ID: stay_id = caseid (SICdb 每 case 即一次 ICU 住院)。保留 subject_id
--      供后续患者级划分。
--   ③ 死亡时点: cases.offsetofdeath (秒, 相对入院, 与 charttime 同锚点)。
--      SICdb 追踪院外死亡 → 死亡随访质量优于 MIMIC/eICU (差异化卖点)。
--   ④ 出院时点: cases.timeofstay (秒, = 出院相对入院 offset)。
--   ⑤ RRT@T7: 上游 s04 已排除 rrt_flag 患者, 竞争风险 RRT@T7 恒 FALSE。
--
-- 数据源:
--   cohort + T0 : sicdb.kdigo2012_aki_after_icu_12h_no_rrt (t0_sec)
--   staging     : sicdb.kdigo2012_stages (charttime_offset 秒, aki_stage_creat)
--   死亡/出院   : sicdb.cases (offsetofdeath, timeofstay)
--
-- AKD 判定 (与 MIMIC 26 号完全同构): 1死亡≤T7→1; 2RRT@T7→1(恒FALSE);
--   3随访<48h→NULL; 4D7 stage≥1且T7附近有Cr→1; 5D7 stage≥1无Cr→NULL;
--   6D7 stage<1且持续恢复→0; 7D7 stage<1不持续→NULL
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_akd_cohort CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_akd_cohort AS
WITH

-- 1. cohort: 入 ICU 12h 后首次 AKI, 已排除 RRT
cohort AS (
    SELECT DISTINCT
        v.subject_id,
        v.hadm_id,
        v.stay_id
    FROM sicdb.kdigo2012_aki_after_icu_12h_no_rrt v
),

-- 2. T0: AKI 首发秒 offset
t0 AS (
    SELECT
        stay_id,
        MIN(t0_sec) AS t0_sec
    FROM sicdb.kdigo2012_aki_after_icu_12h_no_rrt
    GROUP BY stay_id
),

-- 3. death + discharge (秒, 相对入院)
info AS (
    SELECT
        ch.stay_id,
        c.offsetofdeath AS death_sec,       -- NULL 表示存活
        -- ★ 2026-08-06 FIX (随访终点对齐): 原用 c.timeofstay, 但那是 **ICU** 时长
        --    (sicdb.icustays 里它就是 icu_los_sec 的源字段), 不是住院出院。
        --    MIMIC 用 dischtime(住院出院, 85.3% 晚于 ICU 出室)、eICU 用
        --    hospitaldischargeoffset(住院出院) → SICdb 用 ICU 时长严重不对齐,
        --    与课题红线「随访 = ICU 期 + 同次住院病房 Cr」矛盾。
        --    实测: 52.8% 病例的真实肌酐记录超出 timeofstay; 2102 例被它卡住,
        --    其中 1896 例被误判 early_discharge_or_transfer (随访中位数 0.0h)。
        --    hospitalstaydays 是天数(double), ×86400 转秒; 少数异常例(住院<ICU)
        --    用 GREATEST 兑底回 timeofstay, 保证单调不变差。
        GREATEST(
            (COALESCE(c.hospitalstaydays, 0) * 86400)::BIGINT,
            c.timeofstay
        ) AS disch_sec                     -- 住院出院相对入院秒 offset
    FROM sicdb.cases c
    JOIN cohort ch ON ch.stay_id = c.caseid
),

-- 4. base: 预计算窗口 (秒)
base AS (
    SELECT
        c.*,
        i.death_sec,
        i.disch_sec,
        t.t0_sec,
        t.t0_sec + 604800 AS t7_sec,               -- T0 + 7d
        t.t0_sec + 604800 - 172800 AS t7_assess_low -- T7 - 48h
    FROM cohort c
    JOIN t0 t USING (stay_id)
    JOIN info i USING (stay_id)
),

-- 5. kd_window_all: 扩展到 T0+14d
kd_window_all AS (
    SELECT
        b.stay_id,
        b.t0_sec,
        b.t7_sec,
        b.t7_assess_low,
        k.charttime_offset AS charttime,
        k.aki_stage_creat AS stage
    FROM base b
    JOIN sicdb.kdigo2012_stages k ON k.stay_id = b.stay_id
    WHERE
        k.aki_stage_creat IS NOT NULL
        AND k.charttime_offset BETWEEN b.t0_sec AND b.t0_sec + 1209600
),

-- 6. 逐条标注
kd_labeled AS (
    SELECT
        *,
        MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_sec)
            OVER (PARTITION BY stay_id) AS first_stage0_sec,
        CASE
            WHEN
                MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_sec)
                    OVER (PARTITION BY stay_id) IS NOT NULL
                AND charttime > MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_sec)
                    OVER (PARTITION BY stay_id)
                AND charttime <= MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_sec)
                    OVER (PARTITION BY stay_id) + 604800
                THEN 1 ELSE 0
        END AS within_recovery_week,
        CASE WHEN charttime BETWEEN t0_sec AND t7_sec THEN 1 ELSE 0 END AS within_t7_window
    FROM kd_window_all
),

-- 7. 聚合 per-stay
kd_agg AS (
    SELECT
        stay_id,
        (ARRAY_AGG(stage ORDER BY charttime DESC)
            FILTER (WHERE within_t7_window = 1))[1] AS stage_at_7d,
        (ARRAY_AGG(charttime ORDER BY charttime DESC)
            FILTER (WHERE within_t7_window = 1))[1] AS stage_at_7d_sec,
        -- ★ 2026-08-06 FIX: has_cr_near_t7 已移到独立 CTE real_cr_near_t7,
        --    改用 kdigo2012_creatinine 的「真实抽血点」, 不再用 ffill 网格。
        --    原因: sicdb.kdigo2012_stages 是 1h forward-fill 网格(间隔恒 1h,
        --    164.5 行/例), 只要患者在院就必然「有行」, 会把 48h 前的旧值当成
        --    「T7 附近有测量」; 而 MIMIC/eICU 的 stages 是原始抽血点(间隔众数
        --    6~12h, 8~14 行/例)。语义不等价 -> 三库不可通约。
        MIN(charttime) FILTER (WHERE stage < 1 AND charttime <= t7_sec) AS first_stage0_sec,
        (MAX(CASE
            WHEN within_recovery_week = 1
                AND charttime > first_stage0_sec + 172800
                AND stage >= 1
            THEN 1 ELSE 0 END) = 1)::BOOLEAN AS has_rebound,
        MAX(CASE WHEN within_recovery_week = 1 THEN charttime END) AS recovery_week_end
    FROM kd_labeled
    GROUP BY stay_id
),

-- ★ 7b. real_cr_near_t7 (2026-08-06 NEW): 基于真实抽血点判定 T7 附近是否有测量
--     与 MIMIC/eICU 的 has_cr_near_t7 语义完全对齐(那两库 stages 本身就是抽血点)。
real_cr_near_t7 AS (
    SELECT
        b.stay_id,
        (COUNT(k.charttime_offset) > 0) AS has_cr_near_t7,
        MAX(k.charttime_offset)        AS last_real_cr_near_t7_sec
    FROM base b
    LEFT JOIN sicdb.kdigo2012_creatinine k
        ON  k.stay_id = b.stay_id
        AND k.charttime_offset >= b.t7_assess_low
        AND k.charttime_offset <= b.t7_sec
    GROUP BY b.stay_id
),

-- 8. last_cr
-- ★ 2026-08-06 FIX: 改从 kdigo2012_creatinine (真实抽血) 取随访终点。
--    原先从 ffill 网格取 MAX, 网格会延伸到 ICU+7d → 系统性高估 followup_duration,
--    使「随访<48h → NULL」分支失效。真实抽血点才是真随访能力。
last_cr AS (
    SELECT
        b.stay_id,
        MAX(k.charttime_offset) AS last_cr_sec
    FROM base b
    JOIN sicdb.kdigo2012_creatinine k ON k.stay_id = b.stay_id
    GROUP BY b.stay_id
),

-- 9. 持续恢复
sustained_recovery AS (
    SELECT
        ka.stay_id,
        (
            ka.first_stage0_sec IS NOT NULL
            AND ka.stage_at_7d < 1
            AND COALESCE(ka.has_rebound, FALSE) = FALSE
            AND (COALESCE(ka.recovery_week_end, b.t7_sec) - ka.first_stage0_sec) >= 172800
            AND (
                LEAST(
                    COALESCE(b.death_sec, 9223372036854775807),
                    b.disch_sec,
                    COALESCE(lc.last_cr_sec, 9223372036854775807)
                ) - b.t0_sec
            ) >= 172800
        ) AS is_sustained_recovery,
        CASE
            WHEN ka.first_stage0_sec IS NOT NULL
                THEN (COALESCE(ka.recovery_week_end, ka.stage_at_7d_sec) - ka.first_stage0_sec)
        END AS recovery_duration_sec,
        COALESCE(ka.has_rebound, FALSE) AS has_rebound
    FROM kd_agg ka
    JOIN base b USING (stay_id)
    LEFT JOIN last_cr lc USING (stay_id)
)

-- ==========================================================================
-- 主查询
-- ==========================================================================
SELECT
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.death_sec,
    b.disch_sec,
    b.t0_sec,
    b.t7_sec,

    (
        b.death_sec IS NOT NULL
        AND b.death_sec >= b.t0_sec - 86400
        AND b.death_sec <= b.t7_sec
    ) AS death_within_7d,

    COALESCE(ka.stage_at_7d, 0)::NUMERIC AS stage_at_7d,
    ka.stage_at_7d_sec,
    COALESCE(rc.has_cr_near_t7, FALSE) AS has_cr_near_t7,
    ka.first_stage0_sec,
    COALESCE(sr.is_sustained_recovery, FALSE) AS is_sustained_recovery,
    sr.recovery_duration_sec,
    COALESCE(sr.has_rebound, FALSE) AS has_rebound,
    FALSE AS rrt_active_at_7d,   -- SICdb cohort 已排除全部 RRT 患者

    (LEAST(
        COALESCE(b.death_sec, 9223372036854775807),
        b.disch_sec,
        COALESCE(lc.last_cr_sec, 9223372036854775807)
    ) - b.t0_sec) AS followup_duration_sec,

    -- ================================================================
    -- AKD 标签 (与 MIMIC 26 号完全同构)
    -- ================================================================
    CASE
        WHEN (
            b.death_sec IS NOT NULL
            AND b.death_sec >= b.t0_sec - 86400
            AND b.death_sec <= b.t7_sec
        ) THEN 1

        WHEN FALSE THEN 1   -- RRT@T7: SICdb 恒 FALSE

        WHEN (LEAST(
            COALESCE(b.death_sec, 9223372036854775807), b.disch_sec,
            COALESCE(lc.last_cr_sec, 9223372036854775807)
        ) - b.t0_sec) < 172800 THEN NULL

        WHEN COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(rc.has_cr_near_t7, FALSE) = TRUE THEN 1

        WHEN COALESCE(ka.stage_at_7d, 0) >= 1
            AND COALESCE(rc.has_cr_near_t7, FALSE) = FALSE THEN NULL

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
            COALESCE(b.death_sec, 9223372036854775807), b.disch_sec,
            COALESCE(lc.last_cr_sec, 9223372036854775807)
        ) - b.t0_sec) < 172800
        AND NOT (
            b.death_sec IS NOT NULL
            AND b.death_sec >= b.t0_sec - 86400
            AND b.death_sec <= b.t7_sec
        )
            THEN CASE
                WHEN b.death_sec IS NOT NULL
                    AND b.death_sec >= b.t0_sec - 86400
                    AND b.death_sec <= b.t0_sec + 172800
                    THEN 'early_death_lt48h'
                WHEN (b.disch_sec - b.t0_sec) < 172800
                    THEN 'early_discharge_or_transfer'
                ELSE 'insufficient_followup_lt48h'
            END

        WHEN COALESCE(rc.has_cr_near_t7, FALSE) = FALSE
            AND NOT (
                b.death_sec IS NOT NULL
                AND b.death_sec >= b.t0_sec - 86400
                AND b.death_sec <= b.t7_sec
            )
            AND (LEAST(
                COALESCE(b.death_sec, 9223372036854775807), b.disch_sec,
                COALESCE(lc.last_cr_sec, 9223372036854775807)
            ) - b.t0_sec) >= 172800
            THEN CASE
                WHEN ka.stage_at_7d IS NULL THEN 'no_cr_in_entire_window'
                WHEN (b.disch_sec - b.t0_sec) < 604800
                    THEN 'discharged_before_day7_no_near_t7_measurement'
                WHEN lc.last_cr_sec < b.t7_assess_low
                    THEN 'last_cr_before_t7_window'
                ELSE 'no_cr_near_day7_other'
            END

        WHEN COALESCE(ka.stage_at_7d, 99) < 1
            AND COALESCE(sr.is_sustained_recovery, FALSE) = FALSE
            AND NOT (
                b.death_sec IS NOT NULL
                AND b.death_sec >= b.t0_sec - 86400
                AND b.death_sec <= b.t7_sec
            )
            THEN CASE
                WHEN ka.first_stage0_sec IS NULL
                    THEN 'recovery_status_uncertain_no_stage0_record'
                WHEN COALESCE(sr.has_rebound, FALSE) = TRUE
                    THEN 'rebound_second_aki_after_initial_recovery'
                ELSE 'recovery_not_sustained_unconfirmed'
            END
    END AS exclusion_reason

FROM base b
LEFT JOIN kd_agg ka USING (stay_id)
LEFT JOIN real_cr_near_t7 rc USING (stay_id)
LEFT JOIN last_cr lc USING (stay_id)
LEFT JOIN sustained_recovery sr USING (stay_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sicdb_kdigo2012_akd_cohort_stay
    ON sicdb.kdigo2012_akd_cohort (stay_id);
CREATE INDEX IF NOT EXISTS idx_sicdb_kdigo2012_akd_cohort_flag
    ON sicdb.kdigo2012_akd_cohort (akd_flag);

ANALYZE sicdb.kdigo2012_akd_cohort;

\echo '=== sicdb.kdigo2012_akd_cohort v1.0 (ADQI-16 严格版, 秒 offset) 已创建 ==='
