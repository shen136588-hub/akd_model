-- e21_kdigo2012_aki_diagnosis.sql  (2026-07-22; v2 2026-07-28)
-- =============================================================================
-- eICU KDIGO 2012 严格 AKI 诊断 (per-timepoint)
-- 逻辑与 MIMIC 21 号完全一致, 适配 eICU 字段
-- 依赖: akistage_cr_baseline_step1, cr_baseline_union, aki_or_ckd
--
-- v2 (2026-07-28, C-1 同步): 标准 B 的 1.5× 参考值从 creat_low_past_7day 改为
--   cr_baseline, 与 KDIGO 2012 原文 "≥1.5 times baseline" 一致, 与分期参考值统一,
--   消除"诊断 AKI 但 stage<1"的 artifact。与 MIMIC 21 v2 口径完全对齐。
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS eicu.kdigo2012_aki_diagnosis CASCADE;

CREATE MATERIALIZED VIEW eicu.kdigo2012_aki_diagnosis AS
SELECT
    cr.patientunitstayid,
    cr.chartoffset,
    cr.creatinine,
    cr.creat_low_past_48hr,
    cr.creat_low_past_7day,
    cr_b.cr_baseline,
    ki.kd_diagnosis,
    ki.kd_diagnosis_string,
    -- Criterion A: 48h 绝对升高 ≥0.3
    (cr.creat_low_past_48hr IS NOT NULL
     AND cr.creatinine >= cr.creat_low_past_48hr + 0.3)                        AS crit_48h_delta,
    -- Criterion B strict
    (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
     AND cr.creatinine >= 1.5 * cr_b.cr_baseline
     AND cr.creat_low_past_7day <= cr_b.cr_baseline)                            AS crit_7d_15x_strict,
    -- Criterion B relaxed (+0.1 mg/dL)
    (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
     AND cr.creatinine >= 1.5 * cr_b.cr_baseline
     AND cr.creat_low_past_7day <= cr_b.cr_baseline + 0.1)                       AS crit_7d_15x_relaxed,
    -- 综合诊断
    ((cr.creat_low_past_48hr IS NOT NULL AND cr.creatinine >= cr.creat_low_past_48hr + 0.3)
     OR (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
         AND cr.creatinine >= 1.5 * cr_b.cr_baseline
         AND cr.creat_low_past_7day <= cr_b.cr_baseline))                       AS is_aki_strict,
    ((cr.creat_low_past_48hr IS NOT NULL AND cr.creatinine >= cr.creat_low_past_48hr + 0.3)
     OR (cr.creat_low_past_7day IS NOT NULL AND cr_b.cr_baseline IS NOT NULL
         AND cr.creatinine >= 1.5 * cr_b.cr_baseline
         AND cr.creat_low_past_7day <= cr_b.cr_baseline + 0.1))                 AS is_aki_relaxed
FROM eicu.akistage_cr_baseline_step1 cr
LEFT JOIN eicu.cr_baseline_union cr_b ON cr.patientunitstayid = cr_b.patientunitstayid
LEFT JOIN eicu.aki_or_ckd        ki   ON cr.patientunitstayid = ki.patientunitstayid;

CREATE INDEX IF NOT EXISTS idx_eicu_kdigo2012_diag_stay
  ON eicu.kdigo2012_aki_diagnosis (patientunitstayid, chartoffset);
ANALYZE eicu.kdigo2012_aki_diagnosis;

\echo '=== eicu.kdigo2012_aki_diagnosis (KDIGO 2012 per-timepoint) 已创建 ==='