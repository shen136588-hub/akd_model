-- NOTE (2026-08-11): the \set lines below deliberately read DIFFERENTLY-NAMED
-- command-line vars (ext_win_*). Using the same name on both sides makes psql
-- refuse the substitution with 'skipping recursive expansion of variable',
-- leaving the literal ':win_lo' in the SQL. Pass e.g.:
--   -v ext_win_lo="-12 hours" -v ext_win_hi="24 hours"        (mimic)
--   -v ext_win_lo_min=-720   -v ext_win_hi_min=1440           (eicu)
--   -v ext_win_lo_sec=-43200 -v ext_win_hi_sec=86400          (sicdb)
-- ############################################################################
-- EXTENDED COHORT (layer 2 of the 3-tier design, decided 2026-08-11)
--
-- Difference from 01_cohort_features*.sql -- EXACTLY TWO things:
--   1) cohort anchor: kdigo2012_akd_cohort -> kdigo2012_with_rrt_akd_cohort
--   2) object namespace: akd_v2_* -> akd_v3_*  (so main-analysis MVs are SAFE)
-- Everything else (windows, feature definitions, units, joins) is IDENTICAL,
-- which is what makes tier-1 vs tier-2 directly comparable.
--
-- WHERE akd_flag IS NOT NULL is KEPT: chronic dialysis / ESRD patients are
-- excluded BY DEFINITION (AKD is not applicable to them) -- business red line.
-- That is why tier 2 only adds ~8% of stays, not ~100%.
--
-- 3-tier design:
--   tier 1 (main)        akd_v2_*  from kdigo2012_akd_cohort          (no RRT)
--   tier 2 (sensitivity) akd_v3_*  from kdigo2012_with_rrt_akd_cohort (this file)
--   tier 3 (subgroup)    rrt_started_after_t0 = true, carved out of tier 2
--
-- Same plan args as the tier-1 script -- MUST be passed explicitly.
-- ############################################################################
-- =============================================================================
-- 01_cohort_features.sql  (v3, KDIGO 2012 AKD 预测特征工程)
-- Author: 米好 for 朝阳    Date: 2026-07-27  (v3: H.6/H.7 变量口径定稿)
--
-- v3 相对 v2 变更 (见 严谨课题重设计.md H.2/H.7):
--   * 删泄漏/冗余时序: albumin(弃用)、hematocrit(≈hgb)、inr(≈pt)、fio2_bg(被 fio2_value_max 替代)
--   * SOFA 精简: 仅保留 sofa_24hours(时序) + sofa_baseline(静态), 删 6 个器官子分
--   * vaso 删 milrinone(极罕见), 回退 6 种血管活性药
--   * 新增 akd_v3_o2 视图: 移植旧 predictor o2_delivery 清洗(o2_device_cat/o2_flow/fio2)
--     → Python 端算 fio2_value_max(找回被血气丢失的 FiO2 信号)
--   * static 删合并症/Charlson: CHF/DM/renal/malignant/liver + charlson_index + hp/dm/hf
--     (三库不可靠对齐, 全弃用; 保留 ckd_stage + dialysis_dep 直接肾病史)
--   * diag 改主+次诊断(seq_num<=2), 向 SICDB 看齐(三库统一只用主+次诊断)
--
-- 设计要点 (对齐 3.5/3.6):
--   * 队列锚点: kdigo2012_akd_cohort, 仅 akd_flag IS NOT NULL
--   * 时间锚点: t0_time (AKI 首发)
--   * 窗口参数化: 方案 A [t0-24h,t0] / 方案 B [t0-12h,t0+24h]
--   * 窗口下限 GREATEST(..., icu_intime): 绝不取入 ICU 前数据
--   * 删除泄漏特征: aki_stage_creat / _at_develop / creat_low_past_48hr
--
-- 用法 (方案 A):
--   psql -v win_lo="-24 hours" -v win_hi="0 hours"  -f 01_cohort_features.sql
-- 用法 (方案 B):
--   psql -v win_lo="-12 hours" -v win_hi="24 hours" -f 01_cohort_features.sql
-- =============================================================================

\set win_lo :ext_win_lo
\set win_hi :ext_win_hi

-- ==========================================================================
-- 队列 + 窗口边界
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_cohort CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_cohort AS
SELECT
    c.subject_id,
    c.hadm_id,
    c.stay_id,
    c.icu_intime,
    c.icu_outtime,
    c.t0_time,
    c.akd_flag,
    GREATEST(c.t0_time + (:'win_lo')::INTERVAL, c.icu_intime) AS win_start,
    c.t0_time + (:'win_hi')::INTERVAL                         AS win_end
FROM mimiciv_derived.kdigo2012_with_rrt_akd_cohort c
WHERE c.akd_flag IS NOT NULL;

CREATE UNIQUE INDEX idx_akd_v3_cohort_stay ON mimiciv_derived.akd_v3_cohort (stay_id);
CREATE INDEX idx_akd_v3_cohort_hadm ON mimiciv_derived.akd_v3_cohort (hadm_id);
ANALYZE mimiciv_derived.akd_v3_cohort;

-- ==========================================================================
-- 时序长表: 每条 (stay_id, charttime, src) 一行, 33 个数值特征列并排
--   数值列顺序: vitals(7) chem(9) cbc(3) coag(2) bg(7) uo(3) sofa(1)
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_ts_long CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_ts_long AS
WITH
vs AS (
    SELECT b.stay_id, v.charttime,
           v.heart_rate, v.sbp, v.dbp, v.mbp, v.resp_rate,
           v.temperature::double precision AS temperature, v.spo2
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.vitalsign v
      ON v.stay_id = b.stay_id
     AND v.charttime BETWEEN b.win_start AND b.win_end
),
chem AS (
    SELECT b.stay_id, ch.charttime,
           ch.bun, ch.creatinine AS creat_lab, ch.chloride, ch.sodium,
           ch.potassium, ch.calcium, ch.glucose AS glucose_chem,
           ch.bicarbonate AS bicarbonate_chem, ch.aniongap
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.chemistry ch
      ON ch.hadm_id = b.hadm_id
     AND ch.charttime BETWEEN b.win_start AND b.win_end
),
cbc AS (
    SELECT b.stay_id, cb.charttime,
           cb.wbc, cb.hemoglobin, cb.platelet
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.complete_blood_count cb
      ON cb.hadm_id = b.hadm_id
     AND cb.charttime BETWEEN b.win_start AND b.win_end
),
coag AS (
    SELECT b.stay_id, cg.charttime, cg.pt, cg.ptt
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.coagulation cg
      ON cg.hadm_id = b.hadm_id
     AND cg.charttime BETWEEN b.win_start AND b.win_end
),
bloodgas AS (
    SELECT b.stay_id, g.charttime,
           g.po2, g.pco2, g.ph, g.lactate, g.baseexcess,
           g.bicarbonate AS bicarbonate_bg, g.pao2fio2ratio
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.bg g
      ON g.hadm_id = b.hadm_id
     AND g.charttime BETWEEN b.win_start AND b.win_end
),
cr_uo AS (
    SELECT b.stay_id, u.charttime,
           u.uo_mlkghr_6hr  AS uo_rt_6hr,
           u.uo_mlkghr_12hr AS uo_rt_12hr,
           u.uo_mlkghr_24hr AS uo_rt_24hr
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.urine_output_rate u
      ON u.stay_id = b.stay_id
     AND u.charttime BETWEEN b.win_start AND b.win_end
),
sofa_ts AS (
    SELECT b.stay_id, s.starttime AS charttime, s.sofa_24hours
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.sofa s
      ON s.stay_id = b.stay_id
     AND s.starttime BETWEEN b.win_start AND b.win_end
)
SELECT stay_id, charttime, 'vs' AS src,
       heart_rate, sbp, dbp, mbp, resp_rate, temperature, spo2,
       NULL::double precision AS bun, NULL::double precision AS creat_lab,
       NULL::double precision AS chloride, NULL::double precision AS sodium,
       NULL::double precision AS potassium, NULL::double precision AS calcium,
       NULL::double precision AS glucose_chem,
       NULL::double precision AS bicarbonate_chem, NULL::double precision AS aniongap,
       NULL::double precision AS wbc, NULL::double precision AS hemoglobin,
       NULL::double precision AS platelet,
       NULL::double precision AS pt, NULL::double precision AS ptt,
       NULL::double precision AS po2, NULL::double precision AS pco2,
       NULL::double precision AS ph, NULL::double precision AS lactate,
       NULL::double precision AS baseexcess, NULL::double precision AS bicarbonate_bg,
       NULL::double precision AS pao2fio2ratio,
       NULL::numeric AS uo_rt_6hr, NULL::numeric AS uo_rt_12hr,
       NULL::numeric AS uo_rt_24hr,
       NULL::integer AS sofa_24hours
FROM vs
UNION ALL
SELECT stay_id, charttime, 'chem',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       bun, creat_lab, chloride, sodium, potassium, calcium, glucose_chem,
       bicarbonate_chem, aniongap,
       NULL,NULL,NULL, NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM chem
UNION ALL
SELECT stay_id, charttime, 'cbc',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       wbc, hemoglobin, platelet, NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM cbc
UNION ALL
SELECT stay_id, charttime, 'coag',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, pt, ptt,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM coag
UNION ALL
SELECT stay_id, charttime, 'bg',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL,NULL,
       po2, pco2, ph, lactate, baseexcess, bicarbonate_bg, pao2fio2ratio,
       NULL,NULL,NULL, NULL
FROM bloodgas
UNION ALL
SELECT stay_id, charttime, 'cr_uo',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       uo_rt_6hr, uo_rt_12hr, uo_rt_24hr, NULL
FROM cr_uo
UNION ALL
SELECT stay_id, charttime, 'sofa',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, sofa_24hours
FROM sofa_ts;

CREATE INDEX idx_akd_v3_ts_long_stay ON mimiciv_derived.akd_v3_ts_long (stay_id, charttime);
ANALYZE mimiciv_derived.akd_v3_ts_long;

-- ==========================================================================
-- 氧疗 (移植旧 predictor o2_delivery 清洗) → Python 端算 fio2_value_max
--   o2_device_cat: itemid + o2_device 文本分级 (none/cot/hf/niv/iv/ecmo)
--   o2_flow / fio2: 安全转 numeric (text 列, 非数字置 NULL)
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_o2 CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_o2 AS
SELECT b.stay_id, od.charttime,
    CASE
        WHEN od.itemid IN (224833, 224716, 224740, 226873, 226871, 224685,
                           224684, 224686, 224696, 220339, 224700) THEN 'iv'
        WHEN od.itemid IN (224660, 229277, 229270) THEN 'ecmo'
        WHEN od.itemid = 226732 AND od.o2_device LIKE ANY (ARRAY[
            'Medium conc mask%', 'Aerosol-cool%', 'Non-rebreather%',
            'Trach mask%', 'Oxymizer%', 'Vapomist%', 'Ultrasonic neb%',
            'Face tent%', 'Venti mask%', 'Nasal cannula%']) THEN 'cot'
        WHEN od.itemid = 226732 AND od.o2_device LIKE ANY (ARRAY[
            'Bipap mask%', 'CPAP mask%']) THEN 'niv'
        WHEN od.itemid = 226732 AND od.o2_device LIKE 'High flow%' THEN 'hf'
        WHEN od.itemid = 226732 AND od.o2_device LIKE ANY (ARRAY[
            'Endotracheal tube%', 'Tracheostomy tube%']) THEN 'iv'
        WHEN od.itemid = 226732 AND od.o2_device LIKE 'None' THEN 'none'
        WHEN od.itemid = 223849 AND od.o2_device IS NOT NULL
             AND od.o2_device NOT IN ('CPAP', 'CPAP/PSV', 'PSV/SBT', 'SPONT',
                                      'CPAP/PPS') THEN 'iv'
        WHEN od.itemid = 223849 AND od.o2_device IN ('CPAP', 'CPAP/PSV',
                                      'PSV/SBT', 'SPONT', 'CPAP/PPS') THEN 'niv'
        ELSE NULL
    END AS o2_device_cat,
    CASE WHEN od.o2_flow ~ '^[0-9]+(\.[0-9]+)?$'
         THEN od.o2_flow::double precision END AS o2_flow,
    CASE WHEN od.fio2 ~ '^[0-9]+(\.[0-9]+)?$'
         THEN od.fio2::double precision END AS fio2
FROM mimiciv_derived.akd_v3_cohort b
JOIN mimiciv_derived.oxygen_delivery od
  ON od.stay_id = b.stay_id
 AND od.charttime BETWEEN b.win_start AND b.win_end;

CREATE INDEX idx_akd_v3_o2_stay ON mimiciv_derived.akd_v3_o2 (stay_id, charttime);
ANALYZE mimiciv_derived.akd_v3_o2;

-- ==========================================================================
-- 血管活性药 (6 种, 删 milrinone) - 区间型, Python 端 explode 到小时格
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_vaso CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_vaso AS
SELECT b.stay_id, va.starttime, va.endtime,
       va.norepinephrine, va.epinephrine, va.dopamine, va.dobutamine,
       va.phenylephrine, va.vasopressin
FROM mimiciv_derived.akd_v3_cohort b
JOIN mimiciv_derived.vasoactive_agent va
  ON va.stay_id = b.stay_id
 AND va.starttime <= b.win_end
 AND va.endtime   >= b.win_start;

CREATE INDEX idx_akd_v3_vaso_stay ON mimiciv_derived.akd_v3_vaso (stay_id, starttime);
ANALYZE mimiciv_derived.akd_v3_vaso;

-- ==========================================================================
-- 机械通气 (区间型 → Python 端映射到小时格 binary/分级)
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_vent CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_vent AS
SELECT b.stay_id, ve.starttime, ve.endtime, ve.ventilation_status
FROM mimiciv_derived.akd_v3_cohort b
JOIN mimiciv_derived.ventilation ve
  ON ve.stay_id = b.stay_id
 AND ve.starttime <= b.win_end
 AND ve.endtime   >= b.win_start;

CREATE INDEX idx_akd_v3_vent_stay ON mimiciv_derived.akd_v3_vent (stay_id, starttime);
ANALYZE mimiciv_derived.akd_v3_vent;

-- ==========================================================================
-- 静态特征 (每 stay 一行) - v3 删合并症/Charlson
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_static CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_static AS
WITH wt AS (
    SELECT b.stay_id,
           AVG(w.weight) FILTER (WHERE w.weight_type = 'admit') AS admit_weight,
           AVG(w.weight)                                        AS any_weight
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.weight_durations w ON w.stay_id = b.stay_id
    GROUP BY b.stay_id
),
sofa_static AS (
    SELECT DISTINCT ON (b.stay_id) b.stay_id, s.sofa_24hours AS sofa_baseline
    FROM mimiciv_derived.akd_v3_cohort b
    JOIN mimiciv_derived.sofa s
      ON s.stay_id = b.stay_id AND s.starttime <= b.t0_time
    ORDER BY b.stay_id, s.starttime DESC
),
sep AS (
    SELECT stay_id, BOOL_OR(sepsis3) AS sepsis3
    FROM mimiciv_derived.sepsis3 GROUP BY stay_id
)
SELECT
    b.stay_id, b.subject_id, b.hadm_id, b.akd_flag,
    b.t0_time, b.icu_intime, b.win_start, b.win_end,
    ROUND(EXTRACT(EPOCH FROM (b.win_end - b.win_start)) / 3600.0, 2) AS obs_hours,
    a.age, a.gender, a.race,
    wt.admit_weight, wt.any_weight,
    ks.cr_baseline,
    -- CKD 分级 / 透析依赖 (保留: 直接肾病史, 非 Charlson)
    ks.kd_diagnosis, ks.icd_kd_diagnosis,
    sps.sapsii,
    ss.sofa_baseline,
    COALESCE(sp.sepsis3, FALSE) AS sepsis3
FROM mimiciv_derived.akd_v3_cohort b
LEFT JOIN mimiciv_derived.agr a ON a.hadm_id = b.hadm_id
LEFT JOIN wt ON wt.stay_id = b.stay_id
LEFT JOIN LATERAL (
    SELECT k.cr_baseline, k.kd_diagnosis, k.icd_kd_diagnosis
    FROM mimiciv_derived.kdigo2012_stages k
    WHERE k.stay_id = b.stay_id
    ORDER BY k.charttime
    LIMIT 1
) ks ON TRUE
LEFT JOIN mimiciv_derived.sapsii sps ON sps.stay_id = b.stay_id
LEFT JOIN sofa_static ss ON ss.stay_id = b.stay_id
LEFT JOIN sep sp ON sp.stay_id = b.stay_id;

CREATE UNIQUE INDEX idx_akd_v3_static_stay ON mimiciv_derived.akd_v3_static (stay_id);
ANALYZE mimiciv_derived.akd_v3_static;

-- ==========================================================================
-- 诊断文本 (主+次诊断 seq_num<=2, 向 SICDB 看齐) - 供 BERT 离线抽 embedding
-- ==========================================================================
-- diag: PRIMARY diagnosis ONLY (seq_num = 1). Unified 2026-08-12:
-- SICdb stores exactly ONE coded diagnosis per case, so primary-only
-- is the only policy the three cohorts can share. Previously seq_num<=2.
DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akd_v3_diag CASCADE;
CREATE MATERIALIZED VIEW mimiciv_derived.akd_v3_diag AS
SELECT b.stay_id, b.hadm_id,
       REGEXP_REPLACE(LOWER(icd.long_title), '[,()]+', ' ', 'g') AS diag_text
FROM mimiciv_derived.akd_v3_cohort b
JOIN mimiciv_hosp.diagnoses_icd d ON d.hadm_id = b.hadm_id AND d.seq_num = 1
LEFT JOIN mimiciv_hosp.d_icd_diagnoses icd
  ON icd.icd_code = d.icd_code AND icd.icd_version = d.icd_version;

CREATE UNIQUE INDEX idx_akd_v3_diag_stay ON mimiciv_derived.akd_v3_diag (stay_id);
ANALYZE mimiciv_derived.akd_v3_diag;

\echo '=== 01_cohort_features v3: akd_v3_* 视图已创建 ==='
SELECT
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_cohort)  AS n_cohort,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_ts_long) AS n_ts_rows,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_o2)      AS n_o2_rows,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_static)  AS n_static,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_vaso)    AS n_vaso,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_vent)    AS n_vent,
    (SELECT COUNT(*) FROM mimiciv_derived.akd_v3_diag)    AS n_diag;
