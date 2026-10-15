-- 21_kdigo2012_aki_diagnosis.sql  (2026-07-22)
-- =============================================================================
-- KDIGO 2012 严格 AKI 诊断 (per-timepoint 标志)
--
-- 定义 (KDIGO 2012 §2.1.1):
--   A) ΔSCr ≥ 0.3 mg/dL within 48h
--       creat ≥ creat_low_past_48hr + 0.3
--   B) SCr ≥ 1.5 × baseline in prior 7d
--       creat ≥ 1.5 × cr_baseline
--       AND creat_low_past_7day ≤ cr_baseline           (strict, Cr 在7d内曾处基线)
--       AND creat_low_past_7day ≤ cr_baseline + 0.1     (relaxed, 允许 CKD 波动)
--
-- 说明: is_aki_strict/relaxed = A OR B(strict/relaxed)
--       两个诊断口径并列输出, 下游可自行选择 (默认 relaxed).
-- v2 (2026-07-24): 标准 B 的 1.5× 参考值从 creat_low_past_7day 改为 cr_baseline,
--   与 KDIGO 2012 原文 "≥1.5 times baseline" 一致, 同时与分期参考值统一.
-- 依赖: cr_baseline_step1, cr_baseline_union
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_aki_diagnosis CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo2012_aki_diagnosis AS
SELECT
    cr.subject_id,
    cr.hadm_id,
    cr.stay_id,
    cr.charttime,
    cr.creat,
    cr.creat_low_past_48hr,
    cr.creat_low_past_7day,
    cr_b.cr_baseline,
    -- Criterion A: 48h 绝对升高 ≥0.3
    (cr.creat_low_past_48hr IS NOT NULL
     AND cr.creat >= cr.creat_low_past_48hr + 0.3)                       AS crit_48h_delta,
    -- Criterion B strict
    (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
     AND cr.creat >= 1.5 * cr_b.cr_baseline
     AND cr.creat_low_past_7day <= cr_b.cr_baseline)                     AS crit_7d_15x_strict,
    -- Criterion B relaxed (+0.1 mg/dL 波动容忍)
    (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
     AND cr.creat >= 1.5 * cr_b.cr_baseline
     AND cr.creat_low_past_7day <= cr_b.cr_baseline + 0.1)               AS crit_7d_15x_relaxed,
    -- 综合诊断 (A OR B)
    ((cr.creat_low_past_48hr IS NOT NULL AND cr.creat >= cr.creat_low_past_48hr + 0.3)
     OR (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
         AND cr.creat >= 1.5 * cr_b.cr_baseline
         AND cr.creat_low_past_7day <= cr_b.cr_baseline))                AS is_aki_strict,
    ((cr.creat_low_past_48hr IS NOT NULL AND cr.creat >= cr.creat_low_past_48hr + 0.3)
     OR (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
         AND cr.creat >= 1.5 * cr_b.cr_baseline
         AND cr.creat_low_past_7day <= cr_b.cr_baseline + 0.1))          AS is_aki_relaxed
FROM mimiciv_derived.cr_baseline_step1 cr
LEFT JOIN mimiciv_derived.cr_baseline_union cr_b ON cr.hadm_id = cr_b.hadm_id;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_diag_key
  ON mimiciv_derived.kdigo2012_aki_diagnosis (hadm_id, stay_id, charttime);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_diag_stay
  ON mimiciv_derived.kdigo2012_aki_diagnosis (stay_id, charttime);
ANALYZE mimiciv_derived.kdigo2012_aki_diagnosis;

\echo '=== kdigo2012_aki_diagnosis (KDIGO 2012 per-timepoint) 已创建 ==='
