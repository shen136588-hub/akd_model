-- 22_kdigo2012_aki_onset.sql  (2026-07-22)
-- =============================================================================
-- 每 stay 的 AKI 首发时间 (t0) —— strict / relaxed 两个口径
-- 依赖: kdigo2012_aki_diagnosis
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_aki_onset CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_aki_onset AS
SELECT
    subject_id,
    hadm_id,
    stay_id,
    MIN(CASE WHEN is_aki_strict  THEN charttime END) AS t0_aki_strict,
    MIN(CASE WHEN is_aki_relaxed THEN charttime END) AS t0_aki_relaxed,
    BOOL_OR(is_aki_strict)                             AS aki_ever_strict,
    BOOL_OR(is_aki_relaxed)                            AS aki_ever_relaxed,
    -- 各标准命中时点数量, 用于审计
    COUNT(*) FILTER (WHERE crit_48h_delta)             AS n_crit_48h,
    COUNT(*) FILTER (WHERE crit_7d_15x_strict)         AS n_crit_7d_strict,
    COUNT(*) FILTER (WHERE crit_7d_15x_relaxed)        AS n_crit_7d_relaxed
FROM mimiciv_derived.kdigo2012_aki_diagnosis
WHERE stay_id IS NOT NULL
GROUP BY subject_id, hadm_id, stay_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_kdigo2012_onset_stay
  ON mimiciv_derived.kdigo2012_aki_onset (hadm_id, stay_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_onset_stay_only
  ON mimiciv_derived.kdigo2012_aki_onset (stay_id);
ANALYZE mimiciv_derived.kdigo2012_aki_onset;

\echo '=== kdigo2012_aki_onset (每 stay 的 t0) 已创建 ==='
