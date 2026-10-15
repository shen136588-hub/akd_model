-- s02_kdigo2012_aki_onset.sql  (2026-07-22)
-- =============================================================================
-- SICdb 每 stay 的 AKI 首发时间 (t0)
-- 依赖: kdigo2012_creatinine
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_aki_onset CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_aki_onset AS
SELECT
    stay_id,
    MIN(CASE WHEN is_aki_strict  THEN charttime_offset END) AS t0_aki_strict_sec,
    MIN(CASE WHEN is_aki_relaxed THEN charttime_offset END) AS t0_aki_relaxed_sec,
    ROUND(MIN(CASE WHEN is_aki_strict  THEN charttime_offset END) / 3600.0, 2) AS t0_aki_strict_hours,
    ROUND(MIN(CASE WHEN is_aki_relaxed THEN charttime_offset END) / 3600.0, 2) AS t0_aki_relaxed_hours,
    BOOL_OR(is_aki_strict)                               AS aki_ever_strict,
    BOOL_OR(is_aki_relaxed)                              AS aki_ever_relaxed,
    COUNT(*) FILTER (WHERE crit_48h_delta)               AS n_crit_48h,
    COUNT(*) FILTER (WHERE crit_7d_15x_strict)           AS n_crit_7d_strict,
    COUNT(*) FILTER (WHERE crit_7d_15x_relaxed)          AS n_crit_7d_relaxed
FROM sicdb.kdigo2012_creatinine
GROUP BY stay_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_kdigo2012_onset_stay
    ON sicdb.kdigo2012_aki_onset (stay_id);
ANALYZE sicdb.kdigo2012_aki_onset;

\echo '=== kdigo2012_aki_onset (每 stay 的 t0, strict/relaxed 双口径) 已创建 ==='