-- =============================================================================
-- s05b_kdigo2012_with_rrt_akd_cohort.sql — SICdb AKD Cohort (含 RRT, v1.0)
-- Author: 米好 for 朝阳    Date: 2026-08-02
--
-- s05_kdigo2012_akd_cohort.sql 的「不排除 RRT」孪生视图。原视图保留不动。
-- 上游: sicdb.kdigo2012_aki_after_icu_12h (s04b, WITH RRT)
--
-- 时间口径 (秒 offset, 相对入院) 沿用 s05:
--   7d=604800  24h=86400  48h=172800  14d=1209600  72h=259200
--
-- 相对 s05 的三处方法学新增 (与 MIMIC 26b / eICU e27b 完全同构):
--   ① 慢性透析/ESRD (rrt_before_t0 / rrt_before_icu / esrd_or_rrt_history)
--      → akd_flag=NULL, exclusion_reason='chronic_dialysis_or_rrt_before_t0'
--   ② RRT 净化影响窗 = [rrt_first_sec, rrt_last_sec + 259200]。窗内 Cr 不采信
--      "恢复方向"(stage<1), stage>=1 仍可确认未恢复。
--   ③ RRT@T7 ([T7-24h, T7+24h] 内有 dialysis_active=1) → AKD=1。
--      s05 该分支恒 FALSE, 本视图真实可触发。
--
-- ★ SICdb 独有: 输出 hoursofcrrt (CRRT 总时长, 小时) → 含 RRT 分析里唯一可做
--   "RRT 暴露剂量 vs AKD/远期结局" 的库, 建议作为该子分析的主库。
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_with_rrt_akd_cohort CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_with_rrt_akd_cohort AS
WITH

cohort AS (
    SELECT DISTINCT
        v.subject_id,
        v.hadm_id,
        v.stay_id,
        v.rrt_ever,
        v.rrt_first_sec,
        v.rrt_last_sec,
        v.rrt_before_t0,
        v.rrt_before_icu,
        v.esrd_or_rrt_history,
        v.hoursofcrrt
    FROM sicdb.kdigo2012_aki_after_icu_12h v
),

t0 AS (
    SELECT
        stay_id,
        MIN(t0_sec) AS t0_sec
    FROM sicdb.kdigo2012_aki_after_icu_12h
    GROUP BY stay_id
),

info AS (
    SELECT
        ch.stay_id,
        c.offsetofdeath AS death_sec,
        -- ★ 2026-08-06 FIX (随访终点对齐): 同 s05。原 c.timeofstay 是 **ICU** 时长,
        --    非住院出院; MIMIC/eICU 均用住院出院 → 改用 hospitalstaydays。
        GREATEST(
            (COALESCE(c.hospitalstaydays, 0) * 86400)::BIGINT,
            c.timeofstay
        ) AS disch_sec
    FROM sicdb.cases c
    JOIN cohort ch ON ch.stay_id = c.caseid
),

base AS (
    SELECT
        c.*,
        i.death_sec,
        i.disch_sec,
        t.t0_sec,
        t.t0_sec + 604800 AS t7_sec,
        t.t0_sec + 604800 - 86400 AS rrt_low,
        t.t0_sec + 604800 + 86400 AS rrt_high,
        t.t0_sec + 604800 - 172800 AS t7_assess_low,
        c.rrt_first_sec AS clear_win_lo,
        (c.rrt_last_sec + 259200) AS clear_win_hi
    FROM cohort c
    JOIN t0 t USING (stay_id)
    JOIN info i USING (stay_id)
),

kd_window_all AS (
    SELECT
        b.stay_id,
        b.t0_sec,
        b.t7_sec,
        b.t7_assess_low,
        k.charttime_offset AS charttime,
        k.aki_stage_creat AS stage,
        (
            b.clear_win_lo IS NOT NULL
            AND k.charttime_offset >= b.clear_win_lo
            AND k.charttime_offset <= b.clear_win_hi
        ) AS in_rrt_clear_window
    FROM base b
    JOIN sicdb.kdigo2012_stages k ON k.stay_id = b.stay_id
    WHERE
        k.aki_stage_creat IS NOT NULL
        AND k.charttime_offset BETWEEN b.t0_sec AND b.t0_sec + 1209600
),

kd_labeled AS (
    SELECT
        *,
        MIN(charttime) FILTER (
            WHERE stage < 1 AND charttime <= t7_sec AND NOT in_rrt_clear_window
        ) OVER (PARTITION BY stay_id) AS first_stage0_sec,
        CASE
            WHEN
                MIN(charttime) FILTER (
                    WHERE stage < 1 AND charttime <= t7_sec AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY stay_id) IS NOT NULL
                AND charttime > MIN(charttime) FILTER (
                    WHERE stage < 1 AND charttime <= t7_sec AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY stay_id)
                AND charttime <= MIN(charttime) FILTER (
                    WHERE stage < 1 AND charttime <= t7_sec AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY stay_id) + 604800
                THEN 1 ELSE 0
        END AS within_recovery_week,
        CASE WHEN charttime BETWEEN t0_sec AND t7_sec THEN 1 ELSE 0 END
            AS within_t7_window
    FROM kd_window_all
),

kd_agg AS (
    SELECT
        stay_id,
        (ARRAY_AGG(stage ORDER BY charttime DESC) FILTER (
            WHERE within_t7_window = 1 AND (NOT in_rrt_clear_window OR stage >= 1)
        ))[1] AS stage_at_7d,
        (ARRAY_AGG(charttime ORDER BY charttime DESC) FILTER (
            WHERE within_t7_window = 1 AND (NOT in_rrt_clear_window OR stage >= 1)
        ))[1] AS stage_at_7d_sec,
        MIN(charttime) FILTER (
            WHERE stage < 1 AND charttime <= t7_sec AND NOT in_rrt_clear_window
        ) AS first_stage0_sec,
        (MAX(CASE
            WHEN within_recovery_week = 1
                AND charttime > first_stage0_sec + 172800
                AND stage >= 1
            THEN 1 ELSE 0 END) = 1)::BOOLEAN AS has_rebound,
        MAX(CASE WHEN within_recovery_week = 1 THEN charttime END)
            AS recovery_week_end,
        COUNT(*) FILTER (WHERE in_rrt_clear_window AND stage < 1)
            AS n_cr_dropped_by_rrt_window
    FROM kd_labeled
    GROUP BY stay_id
),

-- ★ real_cr_near_t7 (2026-08-06 NEW): 基于真实抽血点判定 T7 附近是否有测量。
--     与 MIMIC/eICU 语义对齐(那两库 stages 本身就是抽血点)。
--     ★ 保留 RRT 净化影响窗规则: 窗内的「恢复方向」(stage<1) Cr 不采信,
--       但 stage>=1 仍可确认未恢复 → 与原 ffill 版 FILTER 条件一致。
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
        AND (
            b.clear_win_lo IS NULL
            OR NOT (k.charttime_offset >= b.clear_win_lo
                    AND k.charttime_offset <= b.clear_win_hi)
            OR k.aki_stage_creat >= 1
        )
    GROUP BY b.stay_id
),

-- ★ 2026-08-06 FIX: last_cr 改从 kdigo2012_creatinine (真实抽血) 取随访终点。
--    原先从 ffill 网格取 MAX, 网格现已延伸到 ICU+7d → 系统性高估
--    followup_duration, 使「随访<48h → NULL」分支失效。
last_cr AS (
    SELECT
        b.stay_id,
        MAX(k.charttime_offset) AS last_cr_sec
    FROM base b
    JOIN sicdb.kdigo2012_creatinine k ON k.stay_id = b.stay_id
    GROUP BY b.stay_id
),

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
                THEN (COALESCE(ka.recovery_week_end, ka.stage_at_7d_sec)
                      - ka.first_stage0_sec)
        END AS recovery_duration_sec,
        COALESCE(ka.has_rebound, FALSE) AS has_rebound
    FROM kd_agg ka
    JOIN base b USING (stay_id)
    LEFT JOIN last_cr lc USING (stay_id)
),

rrt_at_7d AS (
    SELECT
        b.stay_id,
        TRUE AS rrt_active_at_7d
    FROM base b
    WHERE EXISTS (
        SELECT 1 FROM sicdb.rrt r
        WHERE r.stay_id = b.stay_id
          AND r.dialysis_active = 1
          AND r.charttime_offset BETWEEN b.rrt_low AND b.rrt_high
    )
)

SELECT
    b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.death_sec,
    b.disch_sec,
    b.t0_sec,
    b.t7_sec,

    COALESCE(b.rrt_ever, FALSE) AS rrt_ever,
    b.rrt_first_sec,
    b.rrt_last_sec,
    COALESCE(b.rrt_before_icu, FALSE) AS rrt_before_icu,
    COALESCE(b.rrt_before_t0, FALSE) AS rrt_before_t0,
    COALESCE(b.esrd_or_rrt_history, FALSE) AS esrd_or_rrt_history,
    b.hoursofcrrt,
    (b.rrt_first_sec IS NOT NULL AND b.rrt_first_sec >= b.t0_sec)
        AS rrt_started_after_t0,
    (
        b.rrt_first_sec IS NOT NULL
        AND b.rrt_first_sec >= b.t0_sec
        AND b.rrt_last_sec < b.rrt_low
    ) AS rrt_weaned_before_t7,
    COALESCE(ka.n_cr_dropped_by_rrt_window, 0) AS n_cr_dropped_by_rrt_window,

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
    COALESCE(r.rrt_active_at_7d, FALSE) AS rrt_active_at_7d,

    (LEAST(
        COALESCE(b.death_sec, 9223372036854775807),
        b.disch_sec,
        COALESCE(lc.last_cr_sec, 9223372036854775807)
    ) - b.t0_sec) AS followup_duration_sec,

    CASE
        -- 0. 慢性透析 / T0 前 RRT → 定义不适用
        WHEN
            COALESCE(b.rrt_before_t0, FALSE)
            OR COALESCE(b.rrt_before_icu, FALSE)
            OR COALESCE(b.esrd_or_rrt_history, FALSE) THEN NULL

        WHEN (
            b.death_sec IS NOT NULL
            AND b.death_sec >= b.t0_sec - 86400
            AND b.death_sec <= b.t7_sec
        ) THEN 1

        -- RRT@T7: 本视图真实可触发
        WHEN COALESCE(r.rrt_active_at_7d, FALSE) THEN 1

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

    CASE
        WHEN
            COALESCE(b.rrt_before_t0, FALSE)
            OR COALESCE(b.rrt_before_icu, FALSE)
            OR COALESCE(b.esrd_or_rrt_history, FALSE)
            THEN 'chronic_dialysis_or_rrt_before_t0'

        WHEN (LEAST(
            COALESCE(b.death_sec, 9223372036854775807), b.disch_sec,
            COALESCE(lc.last_cr_sec, 9223372036854775807)
        ) - b.t0_sec) < 172800
        AND NOT (
            b.death_sec IS NOT NULL
            AND b.death_sec >= b.t0_sec - 86400
            AND b.death_sec <= b.t7_sec
        )
        AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
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
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
            AND (LEAST(
                COALESCE(b.death_sec, 9223372036854775807), b.disch_sec,
                COALESCE(lc.last_cr_sec, 9223372036854775807)
            ) - b.t0_sec) >= 172800
            THEN CASE
                WHEN ka.stage_at_7d IS NULL
                    AND COALESCE(ka.n_cr_dropped_by_rrt_window, 0) > 0
                    THEN 'cr_unusable_during_rrt_clearance_window'
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
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
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
LEFT JOIN rrt_at_7d r USING (stay_id)
LEFT JOIN sustained_recovery sr USING (stay_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sicdb_kd2012_withrrt_akd_stay
    ON sicdb.kdigo2012_with_rrt_akd_cohort (stay_id);
CREATE INDEX IF NOT EXISTS idx_sicdb_kd2012_withrrt_akd_flag
    ON sicdb.kdigo2012_with_rrt_akd_cohort (akd_flag);
CREATE INDEX IF NOT EXISTS idx_sicdb_kd2012_withrrt_akd_rrt
    ON sicdb.kdigo2012_with_rrt_akd_cohort (rrt_ever);

ANALYZE sicdb.kdigo2012_with_rrt_akd_cohort;

\echo '=== sicdb.kdigo2012_with_rrt_akd_cohort v1.0 (含 RRT) 已创建 ==='
