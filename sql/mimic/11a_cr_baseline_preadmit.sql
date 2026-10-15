-- 11a_cr_baseline_preadmit.sql  v4 (2026-07-14)
-- Pre-admission serum creatinine baseline (Tier 1 主 & 敏感性备选)
--
-- 变更（对齐 SICdb 02_cr_baseline.sql v3）:
--   * Tier 1 主分析：入院前 -365d ~ -7d **MEAN**（ADQI 16 / Bouchard 2021）
--   * 保留 min / median / last 作为敏感性备选（对应 altmin / altmedian / altlast）
--   * 移除 Tier 2 (-7d~-48h) 独立窗口：入院前 -7d 起统一交给 near window（09 版）处理
--   * itemid=50912 (Serum Creatinine, mg/dL); 数值合法区间 (0, 150]
--   * 关联 subject_id 拿门诊/既往住院的肌酐（不依赖 hadm_id）
--
-- 输出字段命名保持向下兼容 12_cr_baseline_union.sql v4

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_preadmit CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_preadmit AS
WITH cr_preadmit AS (
    SELECT
        adm.subject_id,
        adm.hadm_id,
        adm.admittime,
        le.charttime,
        le.valuenum AS creat
    FROM mimiciv_hosp.admissions adm
    JOIN mimiciv_hosp.labevents le
      ON adm.subject_id = le.subject_id
    WHERE le.itemid = 50912
      AND le.valuenum IS NOT NULL
      AND le.valuenum > 0
      AND le.valuenum <= 150
      AND le.charttime >= adm.admittime - INTERVAL '365 day'
      AND le.charttime <= adm.admittime - INTERVAL '7 day'
),
tier1 AS (
    SELECT
        subject_id,
        hadm_id,
        AVG(creat)                                             AS cr_pri1_mean,
        MIN(creat)                                             AS cr_pri1_min,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY creat)     AS cr_pri1_median,
        (ARRAY_AGG(creat ORDER BY charttime DESC))[1]          AS cr_pri1_last,
        COUNT(*)                                               AS n_pri1
    FROM cr_preadmit
    GROUP BY subject_id, hadm_id
)
SELECT
    adm.subject_id,
    adm.hadm_id,
    adm.admittime,
    t1.cr_pri1_mean     AS cr_baseline_pre_365d_7d,          -- ★ 主分析
    t1.cr_pri1_min      AS cr_baseline_pre_365d_7d_min,
    t1.cr_pri1_median   AS cr_baseline_pre_365d_7d_median,
    t1.cr_pri1_last     AS cr_baseline_pre_365d_7d_last,
    t1.n_pri1           AS cr_baseline_pre_365d_7d_n
FROM mimiciv_hosp.admissions adm
LEFT JOIN tier1 t1 ON adm.subject_id = t1.subject_id AND adm.hadm_id = t1.hadm_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_crb_preadmit_hadm
    ON mimiciv_derived.cr_baseline_preadmit (hadm_id);
CREATE INDEX IF NOT EXISTS idx_crb_preadmit_subj
    ON mimiciv_derived.cr_baseline_preadmit (subject_id);

\echo '=== cr_baseline_preadmit v4 (Tier 1 MEAN 主 + min/median/last 敏感性) 已创建 ==='
