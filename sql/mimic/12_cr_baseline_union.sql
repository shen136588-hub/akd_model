-- 12_cr_baseline_union.sql  v4 (2026-07-14)
-- 组装最终 cr_baseline_union，对齐 SICdb v3 层级 COALESCE 逻辑
--
-- 三级严格 COALESCE 优先（不用 LEAST！）:
--   Tier 1: cr_baseline_pre_365d_7d       (入院前 -365d~-7d MEAN)  ← 主
--   Tier 2: cr_baseline_min_p10_p20        (合并近端窗口, 时点级 RRT 剔除)
--   Tier 3: cr_baseline_mdrd_union         (MDRD 反推兜底)
--
-- 敏感性备选（供后续 KDIGO 稳健性分析）:
--   cr_baseline_altmin    : Tier 1 MIN    → Tier 2 → Tier 3
--   cr_baseline_altmedian : Tier 1 median → Tier 2 → Tier 3
--   cr_baseline_altlast   : Tier 1 last   → Tier 2 → Tier 3
--   cr_baseline_mdrd75    : 纯 MDRD 反推
--
-- 依据: KDIGO 2012 / ADQI 16 (Chawla 2017) / Bouchard 2021

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_union CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_union AS
WITH mdrd_union AS (
    SELECT DISTINCT ON (hadm_id)
           subject_id, hadm_id, cr_baseline_mdrd, cr_baseline_mdrd_method
    FROM (
        SELECT subject_id, hadm_id, cr_baseline_mdrd, cr_baseline_mdrd_method
        FROM mimiciv_derived.cr_baseline_ckd_no_mdrd
        UNION ALL
        SELECT subject_id, hadm_id, cr_baseline_mdrd, cr_baseline_mdrd_method
        FROM mimiciv_derived.cr_baseline_ckd_yes_mdrd
    ) u
    ORDER BY hadm_id, cr_baseline_mdrd DESC NULLS LAST   -- 取每 hadm_id 更高的 MDRD 估计
),
final AS (
    SELECT
        adm.subject_id,
        adm.hadm_id,
        -- Tier 1 主 + 敏感性备选
        pa.cr_baseline_pre_365d_7d,
        pa.cr_baseline_pre_365d_7d_min,
        pa.cr_baseline_pre_365d_7d_median,
        pa.cr_baseline_pre_365d_7d_last,
        pa.cr_baseline_pre_365d_7d_n,
        -- Tier 2 近端窗口
        h.cr_baseline        AS cr_baseline_min_p10_p20,
        h.method_used        AS cr_baseline_min_p10_p20_method,
        h.n_near             AS cr_baseline_near_n,
        -- Tier 3 MDRD
        m.cr_baseline_mdrd,
        m.cr_baseline_mdrd_method
    FROM mimiciv_hosp.admissions adm
    LEFT JOIN mimiciv_derived.cr_baseline_preadmit      pa ON adm.hadm_id = pa.hadm_id
    LEFT JOIN mimiciv_derived.cr_baseline_min_p10_p20   h  ON adm.hadm_id = h.hadm_id
    LEFT JOIN mdrd_union                                m  ON adm.hadm_id = m.hadm_id
)
SELECT
    subject_id,
    hadm_id,
    cr_baseline_pre_365d_7d,
    cr_baseline_pre_365d_7d_min,
    cr_baseline_pre_365d_7d_median,
    cr_baseline_pre_365d_7d_last,
    cr_baseline_pre_365d_7d_n,
    cr_baseline_min_p10_p20,
    cr_baseline_min_p10_p20_method,
    cr_baseline_near_n,
    cr_baseline_mdrd,
    cr_baseline_mdrd_method,
    -- ★ 主分析基线: Tier 1 MEAN → Tier 2 → Tier 3
    COALESCE(cr_baseline_pre_365d_7d, cr_baseline_min_p10_p20, cr_baseline_mdrd) AS cr_baseline,
    CASE
        WHEN cr_baseline_pre_365d_7d IS NOT NULL THEN 'preadmit_365d_7d_mean'
        WHEN cr_baseline_min_p10_p20 IS NOT NULL THEN cr_baseline_min_p10_p20_method
        WHEN cr_baseline_mdrd        IS NOT NULL THEN cr_baseline_mdrd_method
        ELSE 'none'
    END AS cr_baseline_source,
    -- 敏感性备选
    COALESCE(cr_baseline_pre_365d_7d_min,    cr_baseline_min_p10_p20, cr_baseline_mdrd) AS cr_baseline_altmin,
    COALESCE(cr_baseline_pre_365d_7d_median, cr_baseline_min_p10_p20, cr_baseline_mdrd) AS cr_baseline_altmedian,
    COALESCE(cr_baseline_pre_365d_7d_last,   cr_baseline_min_p10_p20, cr_baseline_mdrd) AS cr_baseline_altlast,
    cr_baseline_mdrd AS cr_baseline_mdrd75
FROM final;

CREATE UNIQUE INDEX IF NOT EXISTS idx_crb_union_hadm
    ON mimiciv_derived.cr_baseline_union (hadm_id);
ANALYZE mimiciv_derived.cr_baseline_union;

\echo '=== cr_baseline_union v4 (Tier1 MEAN → Tier2 near → Tier3 MDRD, COALESCE 层级) 已创建 ==='
