-- =============================================================================
-- e27b_kdigo2012_with_rrt_akd_cohort.sql — eICU AKD Cohort (含 RRT, v1.0)
-- Author: 米好 for 朝阳    Date: 2026-08-02
--
-- e27_kdigo2012_akd_cohort.sql 的「不排除 RRT」孪生视图。原视图保留不动。
-- 上游: eicu.kdigo2012_aki_after_icu_720m (e25b, WITH RRT)
--
-- 与 e27 相同的时间口径 (全部为 since-ICU-intime 分钟 offset):
--   7d=10080  24h=1440  48h=2880  14d=20160  72h=4320
--
-- 相对 e27 的三处方法学新增 (与 MIMIC 26b 完全同构):
--   ① 慢性透析/ESRD (rrt_before_t0 / rrt_before_icu / esrd_or_rrt_history)
--      → akd_flag=NULL, exclusion_reason='chronic_dialysis_or_rrt_before_t0'
--   ② RRT 净化影响窗 = [rrt_first_off, rrt_last_off + 4320]。窗内 Cr 不采信
--      "恢复方向"(stage<1), 但 stage>=1 仍可用于确认未恢复 (方向安全)。
--   ③ RRT@T7 ([T7-24h, T7+24h] 内有 RRT) → AKD=1 (等同 AKD stage 3D)。
--      注意: e27 里该分支恒 FALSE, 本视图是真实可触发的。
--
-- ⚠️ eICU 死亡时点局限沿用 e27: 院内死亡用 hospitaldischargeoffset 近似。
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_with_rrt_akd_cohort CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_with_rrt_akd_cohort AS
WITH

cohort AS (
    SELECT DISTINCT
        v.patienthealthsystemstayid,
        v.patientunitstayid,
        v.hospitaladmitoffset,
        v.hospitaldischargeoffset,
        v.unitdischargeoffset,
        v.rrt_ever,
        v.rrt_first_off,
        v.rrt_last_off,
        v.rrt_before_t0,
        v.rrt_before_icu,
        v.esrd_or_rrt_history
    FROM eicu.kdigo2012_aki_after_icu_720m v
    WHERE v.stayid_order = 1
),

t0 AS (
    SELECT
        patientunitstayid,
        MIN(t0_aki_relaxed) AS t0_off
    FROM eicu.kdigo2012_aki_after_icu_720m
    WHERE stayid_order = 1
    GROUP BY patientunitstayid
),

death AS (
    SELECT
        c.patientunitstayid,
        CASE WHEN d.hosp_mort = 1 THEN d.hospitaldischargeoffset END AS death_off
    FROM cohort c
    JOIN eicu.icustay_detail d USING (patientunitstayid)
),

base AS (
    SELECT
        c.*,
        t.t0_off,
        t.t0_off + 10080 AS t7_off,
        t.t0_off + 10080 - 1440 AS rrt_low,
        t.t0_off + 10080 + 1440 AS rrt_high,
        t.t0_off + 10080 - 2880 AS t7_assess_low,
        c.rrt_first_off AS clear_win_lo,
        (c.rrt_last_off + 4320) AS clear_win_hi
    FROM cohort c JOIN t0 t USING (patientunitstayid)
),

kd_window_all AS (
    SELECT
        b.patientunitstayid,
        b.t0_off,
        b.t7_off,
        b.t7_assess_low,
        k.chartoffset,
        k.aki_stage_creat AS stage,
        (
            b.clear_win_lo IS NOT NULL
            AND k.chartoffset >= b.clear_win_lo
            AND k.chartoffset <= b.clear_win_hi
        ) AS in_rrt_clear_window
    FROM base b
    JOIN eicu.kdigo2012_stages k
      ON k.patientunitstayid = b.patientunitstayid
    WHERE
        k.aki_stage_creat IS NOT NULL
        AND k.chartoffset BETWEEN b.t0_off AND b.t0_off + 20160
),

kd_labeled AS (
    SELECT
        *,
        MIN(chartoffset) FILTER (
            WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
        ) OVER (PARTITION BY patientunitstayid) AS first_stage0_off,
        CASE
            WHEN
                MIN(chartoffset) FILTER (
                    WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY patientunitstayid) IS NOT NULL
                AND chartoffset > MIN(chartoffset) FILTER (
                    WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY patientunitstayid)
                THEN 1 ELSE 0
        END AS after_first_recovery,
        CASE
            WHEN
                MIN(chartoffset) FILTER (
                    WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY patientunitstayid) IS NOT NULL
                AND chartoffset > MIN(chartoffset) FILTER (
                    WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY patientunitstayid)
                AND chartoffset <= MIN(chartoffset) FILTER (
                    WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
                ) OVER (PARTITION BY patientunitstayid) + 10080
                THEN 1 ELSE 0
        END AS within_recovery_week,
        CASE WHEN chartoffset BETWEEN t0_off AND t7_off THEN 1 ELSE 0 END
            AS within_t7_window
    FROM kd_window_all
),

kd_agg AS (
    SELECT
        patientunitstayid,
        (ARRAY_AGG(stage ORDER BY chartoffset DESC) FILTER (
            WHERE within_t7_window = 1 AND (NOT in_rrt_clear_window OR stage >= 1)
        ))[1] AS stage_at_7d,
        (ARRAY_AGG(chartoffset ORDER BY chartoffset DESC) FILTER (
            WHERE within_t7_window = 1 AND (NOT in_rrt_clear_window OR stage >= 1)
        ))[1] AS stage_at_7d_off,
        MAX(CASE
            WHEN chartoffset >= t7_assess_low AND chartoffset <= t7_off
                 AND (NOT in_rrt_clear_window OR stage >= 1)
            THEN 1 ELSE 0 END)::BOOLEAN AS has_cr_near_t7,
        MIN(chartoffset) FILTER (
            WHERE stage < 1 AND chartoffset <= t7_off AND NOT in_rrt_clear_window
        ) AS first_stage0_off,
        (MAX(CASE
            WHEN within_recovery_week = 1
                AND chartoffset > first_stage0_off + 2880
                AND stage >= 1
            THEN 1 ELSE 0 END) = 1)::BOOLEAN AS has_rebound,
        MAX(CASE WHEN within_recovery_week = 1 THEN chartoffset END)
            AS recovery_week_end,
        COUNT(*) FILTER (WHERE in_rrt_clear_window AND stage < 1)
            AS n_cr_dropped_by_rrt_window
    FROM kd_labeled
    GROUP BY patientunitstayid
),

last_cr AS (
    SELECT
        b.patientunitstayid,
        MAX(k.chartoffset) AS last_cr_off
    FROM base b
    JOIN eicu.kdigo2012_stages k
      ON k.patientunitstayid = b.patientunitstayid
    WHERE k.aki_stage_creat IS NOT NULL
    GROUP BY b.patientunitstayid
),

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
                THEN (COALESCE(ka.recovery_week_end, ka.stage_at_7d_off)
                      - ka.first_stage0_off)
        END AS recovery_duration_min,
        COALESCE(ka.has_rebound, FALSE) AS has_rebound
    FROM kd_agg ka
    JOIN base b USING (patientunitstayid)
    LEFT JOIN death d USING (patientunitstayid)
    LEFT JOIN last_cr lc USING (patientunitstayid)
),

rrt_at_7d AS (
    SELECT
        b.patientunitstayid,
        TRUE AS rrt_active_at_7d
    FROM base b
    WHERE EXISTS (
        SELECT 1 FROM eicu.rrt_treatment r
        WHERE r.patientunitstayid = b.patientunitstayid
          AND r.treatmentoffset BETWEEN b.rrt_low AND b.rrt_high
    )
)

SELECT
    b.patienthealthsystemstayid,
    b.patientunitstayid,
    b.hospitaladmitoffset,
    b.hospitaldischargeoffset,
    b.unitdischargeoffset,
    d.death_off,
    b.t0_off,
    b.t7_off,

    COALESCE(b.rrt_ever, FALSE) AS rrt_ever,
    b.rrt_first_off,
    b.rrt_last_off,
    COALESCE(b.rrt_before_icu, FALSE) AS rrt_before_icu,
    COALESCE(b.rrt_before_t0, FALSE) AS rrt_before_t0,
    COALESCE(b.esrd_or_rrt_history, FALSE) AS esrd_or_rrt_history,
    (b.rrt_first_off IS NOT NULL AND b.rrt_first_off >= b.t0_off)
        AS rrt_started_after_t0,
    (
        b.rrt_first_off IS NOT NULL
        AND b.rrt_first_off >= b.t0_off
        AND b.rrt_last_off < b.rrt_low
    ) AS rrt_weaned_before_t7,
    COALESCE(ka.n_cr_dropped_by_rrt_window, 0) AS n_cr_dropped_by_rrt_window,

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
    COALESCE(r.rrt_active_at_7d, FALSE) AS rrt_active_at_7d,

    (LEAST(
        COALESCE(d.death_off, 2147483647),
        b.hospitaldischargeoffset,
        COALESCE(lc.last_cr_off, 2147483647)
    ) - b.t0_off) AS followup_duration_min,

    CASE
        -- 0. 慢性透析 / T0 前 RRT → 定义不适用
        WHEN
            COALESCE(b.rrt_before_t0, FALSE)
            OR COALESCE(b.rrt_before_icu, FALSE)
            OR COALESCE(b.esrd_or_rrt_history, FALSE) THEN NULL

        WHEN (
            d.death_off IS NOT NULL
            AND d.death_off >= b.t0_off - 1440
            AND d.death_off <= b.t7_off
        ) THEN 1

        -- RRT@T7: 本视图真实可触发
        WHEN COALESCE(r.rrt_active_at_7d, FALSE) THEN 1

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

    CASE
        WHEN
            COALESCE(b.rrt_before_t0, FALSE)
            OR COALESCE(b.rrt_before_icu, FALSE)
            OR COALESCE(b.esrd_or_rrt_history, FALSE)
            THEN 'chronic_dialysis_or_rrt_before_t0'

        WHEN (LEAST(
            COALESCE(d.death_off, 2147483647), b.hospitaldischargeoffset,
            COALESCE(lc.last_cr_off, 2147483647)
        ) - b.t0_off) < 2880
        AND NOT (
            d.death_off IS NOT NULL
            AND d.death_off >= b.t0_off - 1440
            AND d.death_off <= b.t7_off
        )
        AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
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
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
            AND (LEAST(
                COALESCE(d.death_off, 2147483647), b.hospitaldischargeoffset,
                COALESCE(lc.last_cr_off, 2147483647)
            ) - b.t0_off) >= 2880
            THEN CASE
                WHEN ka.stage_at_7d IS NULL
                    AND COALESCE(ka.n_cr_dropped_by_rrt_window, 0) > 0
                    THEN 'cr_unusable_during_rrt_clearance_window'
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
            AND NOT COALESCE(r.rrt_active_at_7d, FALSE)
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
LEFT JOIN rrt_at_7d r USING (patientunitstayid)
LEFT JOIN sustained_recovery sr USING (patientunitstayid);

CREATE UNIQUE INDEX IF NOT EXISTS idx_eicu_kd2012_withrrt_akd_stay
    ON eicu.kdigo2012_with_rrt_akd_cohort (patientunitstayid);
CREATE INDEX IF NOT EXISTS idx_eicu_kd2012_withrrt_akd_flag
    ON eicu.kdigo2012_with_rrt_akd_cohort (akd_flag);
CREATE INDEX IF NOT EXISTS idx_eicu_kd2012_withrrt_akd_rrt
    ON eicu.kdigo2012_with_rrt_akd_cohort (rrt_ever);

ANALYZE eicu.kdigo2012_with_rrt_akd_cohort;

\echo '=== eicu.kdigo2012_with_rrt_akd_cohort v1.0 (含 RRT) 已创建 ==='
