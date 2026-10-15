-- s01_kdigo2012_creatinine.sql  (2026-07-22)
-- =============================================================================
-- SICdb KDIGO 2012 严格版: 肌酐分期 + 诊断标志 (per-timepoint)
--
-- 在 sicdb.kdigo_creatinine 基础上:
--   1) 增加 cr_low_7d (7d 窗口 MIN)
--   2) 增加 KDIGO 2012 诊断标志 (crit_48h_delta, crit_7d_15x_strict/relaxed)
--   3) 改良分期 CASE: Stage 1 / Stage 3 加入 cr_low_48h + 0.3 路径
--      (creat ≥ cr_low_48h + 0.3 触发 Stage 1; Stage 3 的 creat≥4 判定也加此条件)
-- v2 (2026-07-28, C-1 同步): 诊断标志 crit_7d_15x/is_aki 的 1.5× 参考值从 cr_low_7d
--   改为 cr_baseline, 与 KDIGO 2012 "≥1.5 times baseline" 及分期 CASE 基准统一,
--   与 MIMIC 21 v2 / eICU e21 v2 口径完全对齐。分期 CASE 本就用 cr_baseline, 无需改。
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_creatinine CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_creatinine AS
WITH cr_with_7d_low AS (
    SELECT
        k.*,
        -- 7d 窗口最低值 (并行计算)
        MIN(k.creat) OVER (
            PARTITION BY k.stay_id
            ORDER BY k.charttime_offset
            RANGE BETWEEN 604800 PRECEDING AND CURRENT ROW
        ) AS cr_low_7d
    FROM sicdb.kdigo_creatinine k
)
SELECT
    stay_id,
    charttime_offset,
    charttime_hours,
    creat,
    cr_baseline,
    cr_low_48h,
    cr_low_7d,
    rrt_72hr_prior_and_24hr_post,
    (creat - cr_low_48h)                                                    AS cr_delta_48h,
    CASE WHEN cr_baseline > 0 THEN creat / cr_baseline ELSE NULL END        AS cr_ratio_baseline,
    -- KDIGO 2012 诊断标志 (Criterion A + B)
    (cr_low_48h IS NOT NULL AND creat >= cr_low_48h + 0.3)                  AS crit_48h_delta,
    (cr_low_7d IS NOT NULL AND cr_baseline IS NOT NULL
     AND creat >= 1.5 * cr_baseline
     AND cr_low_7d <= cr_baseline)                                          AS crit_7d_15x_strict,
    (cr_low_7d IS NOT NULL AND cr_baseline IS NOT NULL
     AND creat >= 1.5 * cr_baseline
     AND cr_low_7d <= cr_baseline + 0.1)                                    AS crit_7d_15x_relaxed,
    ((cr_low_48h IS NOT NULL AND creat >= cr_low_48h + 0.3)
     OR (cr_low_7d IS NOT NULL AND cr_baseline IS NOT NULL
         AND creat >= 1.5 * cr_baseline
         AND cr_low_7d <= cr_baseline))                                     AS is_aki_strict,
    ((cr_low_48h IS NOT NULL AND creat >= cr_low_48h + 0.3)
     OR (cr_low_7d IS NOT NULL AND cr_baseline IS NOT NULL
         AND creat >= 1.5 * cr_baseline
         AND cr_low_7d <= cr_baseline + 0.1))                               AS is_aki_relaxed,
    -- ★ KDIGO 2012 严格分期 (改良 CASE, 含 cr_low_48h + 0.3 路径)
    CASE
        WHEN cr_baseline IS NULL THEN NULL
        -- Stage 3
        WHEN creat >= cr_baseline * 3.0                                      THEN 3
        WHEN creat >= 4.0
             AND (creat >= cr_baseline + 0.3
               OR (cr_low_48h IS NOT NULL AND creat >= cr_low_48h + 0.3)
               OR creat >= 1.5 * cr_baseline)                                THEN 3
        -- Stage 2
        WHEN creat >= cr_baseline * 2.0                                      THEN 2
        -- Stage 1
        WHEN creat >= cr_baseline + 0.3                                      THEN 1
        WHEN cr_low_48h IS NOT NULL AND creat >= cr_low_48h + 0.3            THEN 1
        WHEN creat >= cr_baseline * 1.5                                      THEN 1
        -- 亚临床 0.5
        WHEN creat >= cr_baseline * 1.2 AND creat < cr_baseline * 1.5        THEN 0.5
        WHEN creat >= cr_baseline + 0.2 AND creat < cr_baseline + 0.3        THEN 0.5
        ELSE 0
    END::numeric                                                             AS aki_stage_creat
FROM cr_with_7d_low;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_cr_stay
    ON sicdb.kdigo2012_creatinine (stay_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_cr_stay_time
    ON sicdb.kdigo2012_creatinine (stay_id, charttime_offset);
ANALYZE sicdb.kdigo2012_creatinine;

\echo '=== kdigo2012_creatinine (KDIGO 2012 严格版, 含诊断标志 + 改良 CASE) 已创建 ==='