-- e22_kdigo2012_aki_onset.sql  (2026-07-22)
-- =============================================================================
-- eICU 每 stay 的 AKI 首发时间 (t0)
-- 依赖: kdigo2012_aki_diagnosis
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_aki_onset CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_aki_onset AS
SELECT
    patientunitstayid,
    MIN(CASE WHEN is_aki_strict  THEN chartoffset END) AS t0_aki_strict,
    MIN(CASE WHEN is_aki_relaxed THEN chartoffset END) AS t0_aki_relaxed,
    BOOL_OR(is_aki_strict)                               AS aki_ever_strict,
    BOOL_OR(is_aki_relaxed)                              AS aki_ever_relaxed,
    COUNT(*) FILTER (WHERE crit_48h_delta)               AS n_crit_48h,
    COUNT(*) FILTER (WHERE crit_7d_15x_strict)           AS n_crit_7d_strict,
    COUNT(*) FILTER (WHERE crit_7d_15x_relaxed)          AS n_crit_7d_relaxed
FROM eicu.kdigo2012_aki_diagnosis
GROUP BY patientunitstayid;

CREATE UNIQUE INDEX IF NOT EXISTS idx_eicu_kdigo2012_onset_stay
  ON eicu.kdigo2012_aki_onset (patientunitstayid);
ANALYZE eicu.kdigo2012_aki_onset;

\echo '=== eicu.kdigo2012_aki_onset (每 stay 的 t0) 已创建 ==='