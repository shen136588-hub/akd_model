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
-- 01_cohort_features_eicu.sql   (eICU external-validation feature extraction)
-- Author: mihao for zhaoyang    Date: 2026-07-28
--
-- GOAL: emit 7 views/tables with the SAME column names & schema as MIMIC
--   mimiciv_derived.akd_v3_*  so that the identical 02_assemble.py can consume
--   the exported CSVs, and the LOCKED MIMIC scaler/imputer/PCA + checkpoint can
--   transform (never refit) this external set for TRIPOD-AI validation.
--
-- KEY ALIGNMENT DECISIONS (see design doc J.5/J.6):
--   * ids: stay_id = patientunitstayid ; subject_id/hadm_id = patienthealthsystemstayid
--   * time axis: eICU offsets are MINUTES since ICU (unit) admit. We synthesize a
--     timestamp = BASE '2000-01-01 00:00:00' + offset minutes, so assembler's
--     floor((charttime - win_start)/1h) hour-grid logic works unchanged.
--   * window plan A: [t0-24h, t0]  -> win_lo_min=-1440, win_hi_min=0
--     win_start clipped to ICU intime (offset 0) via GREATEST(t0_off-1440, 0),
--     mirroring MIMIC GREATEST(..., icu_intime): never take pre-ICU data.
--   * severity score: eICU has no SAPS II -> use APS III (acutephysiologyscore),
--     output under column name "sapsii" so 03 picks it up. (accepted proxy)
--   * sepsis3: eICU has no Sepsis-3 view -> proxy = sepsis_3_ab (Sepsis-3 based on
--     antibiotic course >72h [suspicion_of_infection_ab] + SOFA>=2 within course).
--     Replaces the old over-strict suspicion_of_infection (only 44 in-cohort).
--   * PT from eicu.lab (labname='PT'); lactate from lab_test; P/F = pao2/fio2
--     (pivoted_bg.fio2 is a fraction 0-1). fio2 exported as PERCENT (x100) so the
--     assembler o2 cleaning (which treats value<=10 as LPM misrecord) is correct.
--   * diag: diagnosisstring, priority in (Primary,Major) ~ MIMIC seq_num<=2.
--   * diag placeholder for now (J.4 will fill); ts/static/vaso/vent/o2 are full.
--
-- USAGE (plan A):
--   psql -v win_lo_min=-1440 -v win_hi_min=0 -f 01_cohort_features_eicu.sql
-- =============================================================================

\set win_lo_min :ext_win_lo_min
\set win_hi_min :ext_win_hi_min

SET work_mem = '1GB';
SET max_parallel_workers_per_gather = 8;

-- BASE timestamp helper is inlined as (TIMESTAMP '2000-01-01 00:00:00' + N min)

-- ==========================================================================
-- cohort + window boundaries  (akd_v3_cohort)
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_cohort CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_cohort AS
SELECT
    c.patienthealthsystemstayid            AS subject_id,
    c.patienthealthsystemstayid            AS hadm_id,
    c.patientunitstayid                    AS stay_id,
    (TIMESTAMP '2000-01-01 00:00:00')                                        AS icu_intime,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => c.unitdischargeoffset::int)) AS icu_outtime,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => c.t0_off::int))              AS t0_time,
    c.akd_flag,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => GREATEST(c.t0_off + (:win_lo_min), 0)::int)) AS win_start,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => (c.t0_off + (:win_hi_min))::int))             AS win_end,
    c.t0_off,
    GREATEST(c.t0_off + (:win_lo_min), 0)::int AS win_start_min,
    (c.t0_off + (:win_hi_min))::int            AS win_end_min
FROM eicu.kdigo2012_with_rrt_akd_cohort c
WHERE c.akd_flag IS NOT NULL;

CREATE UNIQUE INDEX idx_eicu_akd_v3_cohort_stay ON eicu.akd_v3_cohort (stay_id);
ANALYZE eicu.akd_v3_cohort;

-- ==========================================================================
-- time-series long table (akd_v3_ts_long): one row per (stay, charttime, src),
-- 32 numeric feature columns side by side (bicarbonate_bg dropped by meta).
-- column names MUST match MIMIC TS_MEAN_COLS.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_ts_long CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_ts_long AS
WITH
-- vitals from pivoted_vital
vs AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => v.chartoffset::int)) AS charttime,
           v.heartrate::double precision                              AS heart_rate,
           COALESCE(v.ibp_systolic, v.nibp_systolic)::double precision AS sbp,
           COALESCE(v.ibp_diastolic, v.nibp_diastolic)::double precision AS dbp,
           COALESCE(v.ibp_mean, v.nibp_mean)::double precision        AS mbp,
           v.respiratoryrate::double precision                       AS resp_rate,
           v.temperature::double precision                           AS temperature,
           v.spo2::double precision                                  AS spo2
    FROM eicu.akd_v3_cohort b
    JOIN eicu.pivoted_vital v
      ON v.patientunitstayid = b.stay_id
     AND v.chartoffset BETWEEN b.win_start_min AND b.win_end_min
),
-- chemistry + cbc + ptt + lactate from lab_test
chem AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => l.chartoffset::int)) AS charttime,
           l.bun::double precision, l.creatinine::double precision AS creat_lab,
           l.chloride::double precision, l.sodium::double precision,
           l.potassium::double precision, l.calcium::double precision,
           l.glucose::double precision AS glucose_chem,
           l.bicarbonate::double precision AS bicarbonate_chem,
           l.wbc::double precision, l.hemoglobin::double precision,
           l.platelets::double precision AS platelet,
           l.ptt::double precision, l.lactate::double precision
    FROM eicu.akd_v3_cohort b
    JOIN eicu.lab_test l
      ON l.patientunitstayid = b.stay_id
     AND l.chartoffset BETWEEN b.win_start_min AND b.win_end_min
),
-- PT from eicu.lab (labname='PT')
pt AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => la.labresultoffset::int)) AS charttime,
           la.labresult::double precision AS pt
    FROM eicu.akd_v3_cohort b
    JOIN eicu.lab la
      ON la.patientunitstayid = b.stay_id
     AND la.labname = 'PT'
     AND la.labresultoffset BETWEEN b.win_start_min AND b.win_end_min
),
-- blood gas from pivoted_bg
bloodgas AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => g.chartoffset::int)) AS charttime,
           g.pao2::double precision AS po2,
           g.paco2::double precision AS pco2,
           g.ph::double precision,
           g.baseexcess::double precision,
           g.aniongap::double precision,
           (g.pao2 / NULLIF(g.fio2::numeric, 0))::double precision AS pao2fio2ratio
    FROM eicu.akd_v3_cohort b
    JOIN eicu.pivoted_bg g
      ON g.patientunitstayid = b.stay_id
     AND g.chartoffset BETWEEN b.win_start_min AND b.win_end_min
),
-- urine output rate from akistage_uo_step3
cr_uo AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => u.chartoffset::int)) AS charttime,
           u.uo_rt_6hr::numeric, u.uo_rt_12hr::numeric, u.uo_rt_24hr::numeric
    FROM eicu.akd_v3_cohort b
    JOIN eicu.akistage_uo_step3 u
      ON u.patientunitstayid = b.stay_id
     AND u.chartoffset BETWEEN b.win_start_min AND b.win_end_min
),
-- rolling 24h SOFA from sofa_score (starttime is integer hour -> min = *60)
sofa_ts AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => (s.starttime*60)::int)) AS charttime,
           s.sofa_24hours::integer
    FROM eicu.akd_v3_cohort b
    JOIN eicu.sofa_score s
      ON s.patientunitstayid = b.stay_id
     AND (s.starttime*60) BETWEEN b.win_start_min AND b.win_end_min
)
SELECT stay_id, charttime, 'vs'::text AS src,
       heart_rate, sbp, dbp, mbp, resp_rate, temperature, spo2,
       NULL::double precision AS bun, NULL::double precision AS creat_lab,
       NULL::double precision AS chloride, NULL::double precision AS sodium,
       NULL::double precision AS potassium, NULL::double precision AS calcium,
       NULL::double precision AS glucose_chem, NULL::double precision AS bicarbonate_chem,
       NULL::double precision AS aniongap,
       NULL::double precision AS wbc, NULL::double precision AS hemoglobin,
       NULL::double precision AS platelet,
       NULL::double precision AS pt, NULL::double precision AS ptt,
       NULL::double precision AS po2, NULL::double precision AS pco2,
       NULL::double precision AS ph, NULL::double precision AS lactate,
       NULL::double precision AS baseexcess, NULL::double precision AS pao2fio2ratio,
       NULL::numeric AS uo_rt_6hr, NULL::numeric AS uo_rt_12hr, NULL::numeric AS uo_rt_24hr,
       NULL::integer AS sofa_24hours
FROM vs
UNION ALL
SELECT stay_id, charttime, 'chem',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       bun, creat_lab, chloride, sodium, potassium, calcium, glucose_chem, bicarbonate_chem,
       NULL,
       wbc, hemoglobin, platelet,
       NULL, ptt,
       NULL,NULL,NULL, lactate, NULL, NULL,
       NULL,NULL,NULL, NULL
FROM chem
UNION ALL
SELECT stay_id, charttime, 'pt',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       NULL,NULL,NULL,
       pt, NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM pt
UNION ALL
SELECT stay_id, charttime, 'bg',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       aniongap,
       NULL,NULL,NULL,
       NULL,NULL,
       po2, pco2, ph, NULL, baseexcess, pao2fio2ratio,
       NULL,NULL,NULL, NULL
FROM bloodgas
UNION ALL
SELECT stay_id, charttime, 'cr_uo',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       NULL,NULL,NULL,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       uo_rt_6hr, uo_rt_12hr, uo_rt_24hr, NULL
FROM cr_uo
UNION ALL
SELECT stay_id, charttime, 'sofa',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       NULL,NULL,NULL,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, sofa_24hours
FROM sofa_ts;

CREATE INDEX idx_eicu_akd_v3_ts_long_stay ON eicu.akd_v3_ts_long (stay_id, charttime);
ANALYZE eicu.akd_v3_ts_long;

-- ==========================================================================
-- oxygen therapy (akd_v3_o2): device_cat + o2_flow + fio2(PERCENT).
-- pivoted_o2 gives device+flow; pivoted_bg gives fio2 fraction -> *100.
-- assembler maps o2_device_cat via {none,cot,hf,niv,iv,ecmo} and computes
-- fio2_value_max + o2_device_cat_numeric.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_o2 CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_o2 AS
-- device + flow rows from pivoted_o2
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => o.chartoffset::int)) AS charttime,
       CASE
           WHEN lower(o.o2_device) IN ('room air','ra','room air ') THEN 'none'
           WHEN lower(o.o2_device) IN ('hfnc','high flow','high flow nasal cannula') THEN 'hf'
           WHEN lower(o.o2_device) LIKE '%bipap%' OR lower(o.o2_device) LIKE '%cpap%' THEN 'niv'
           WHEN lower(o.o2_device) IN ('ventilator','vent') THEN 'iv'
           WHEN lower(o.o2_device) LIKE '%ecmo%' THEN 'ecmo'
           WHEN lower(o.o2_device) LIKE '%nasal cannula%' OR lower(o.o2_device) IN ('nc')
                OR lower(o.o2_device) LIKE '%mask%' OR lower(o.o2_device) LIKE '%non-rebreather%'
                OR lower(o.o2_device) LIKE '%oxymizer%' OR lower(o.o2_device) LIKE '%aerosol%'
                OR lower(o.o2_device) LIKE '%face tent%' OR lower(o.o2_device) LIKE '%trach collar%'
                OR lower(o.o2_device) LIKE '%venturi%' OR lower(o.o2_device) LIKE '%venti%' THEN 'cot'
           ELSE NULL
       END AS o2_device_cat,
       o.o2_flow::double precision AS o2_flow,
       NULL::double precision AS fio2
FROM eicu.akd_v3_cohort b
JOIN eicu.pivoted_o2 o
  ON o.patientunitstayid = b.stay_id
 AND o.chartoffset BETWEEN b.win_start_min AND b.win_end_min
UNION ALL
-- fio2 rows from pivoted_bg (fraction -> percent)
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => g.chartoffset::int)) AS charttime,
       NULL::text AS o2_device_cat,
       NULL::double precision AS o2_flow,
       (g.fio2::double precision * 100.0) AS fio2
FROM eicu.akd_v3_cohort b
JOIN eicu.pivoted_bg g
  ON g.patientunitstayid = b.stay_id
 AND g.fio2 IS NOT NULL
 AND g.chartoffset BETWEEN b.win_start_min AND b.win_end_min;

CREATE INDEX idx_eicu_akd_v3_o2_stay ON eicu.akd_v3_o2 (stay_id, charttime);
ANALYZE eicu.akd_v3_o2;

-- ==========================================================================
-- vasoactive agents (akd_v3_vaso): 6 drugs. eICU vaso_*_std are POINT events
-- (infusionoffset, drug_rate_std in mcg/kg/min). We emit interval rows
-- [t, t+60min] so the assembler explode fills the hour grid. one drug per row,
-- others NULL; assembler groupby-max then fill 0.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_vaso CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_vaso AS
WITH allv AS (
    SELECT patientunitstayid, infusionoffset, drug_rate_std, 'nor' AS d FROM eicu.vaso_norepinephrine_std WHERE drug_rate_std IS NOT NULL
    UNION ALL SELECT patientunitstayid, infusionoffset, drug_rate_std, 'epi' FROM eicu.vaso_epinephrine_std  WHERE drug_rate_std IS NOT NULL
    UNION ALL SELECT patientunitstayid, infusionoffset, drug_rate_std, 'dop' FROM eicu.vaso_dopamine_std     WHERE drug_rate_std IS NOT NULL
    UNION ALL SELECT patientunitstayid, infusionoffset, drug_rate_std, 'dob' FROM eicu.vaso_dobutamine_std   WHERE drug_rate_std IS NOT NULL
    UNION ALL SELECT patientunitstayid, infusionoffset, drug_rate_std, 'phe' FROM eicu.vaso_phenylephrine_std WHERE drug_rate_std IS NOT NULL
    -- ★ UNIT FIX 2026-08-02 (Q1 vasopressin): 三库 vasopressin 单位不统一。
    --   MIMIC  mimiciv_derived.vasopressin  -> units/HOUR (rateuom='units/min' 已 x60)
    --   SICdb  sicdb.vasopressin            -> units/HOUR (amountperminute x60)
    --   eICU   vaso_vasopressin_std         -> units/MIN  (rateuom_std='units/min')
    -- 实测中位数: MIMIC 2.40 / SICdb 2.00 / eICU 0.04 —— eICU 恰好差 ~60 倍。
    -- MIMIC RobustScaler 对 vasopressin 是 center=0 / scale=1 (因 >75% 行为 0,
    -- IQR=0 被 sklearn 兜底成 1) → **完全不做缩放**, 单位差异 100% 原样传入模型:
    -- eICU 用药患者被当成"几乎没用药"。故必须在 SQL 层 x60 对齐到 units/hour。
    UNION ALL SELECT patientunitstayid, infusionoffset, drug_rate_std * 60.0, 'vas' FROM eicu.vaso_vasopressin_std  WHERE drug_rate_std IS NOT NULL
)
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => a.infusionoffset::int))       AS starttime,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => (a.infusionoffset+60)::int))   AS endtime,
       CASE WHEN a.d='nor' THEN a.drug_rate_std END::double precision AS norepinephrine,
       CASE WHEN a.d='epi' THEN a.drug_rate_std END::double precision AS epinephrine,
       CASE WHEN a.d='dop' THEN a.drug_rate_std END::double precision AS dopamine,
       CASE WHEN a.d='dob' THEN a.drug_rate_std END::double precision AS dobutamine,
       CASE WHEN a.d='phe' THEN a.drug_rate_std END::double precision AS phenylephrine,
       CASE WHEN a.d='vas' THEN a.drug_rate_std END::double precision AS vasopressin
FROM eicu.akd_v3_cohort b
JOIN allv a
  ON a.patientunitstayid = b.stay_id
 AND a.infusionoffset <= b.win_end_min
 AND (a.infusionoffset+60) >= b.win_start_min;

CREATE INDEX idx_eicu_akd_v3_vaso_stay ON eicu.akd_v3_vaso (stay_id, starttime);
ANALYZE eicu.akd_v3_vaso;

-- ==========================================================================
-- mechanical ventilation (akd_v3_vent): eICU has no vent view -> derive from
-- pivoted_o2 device. ventilation_status strings chosen so assembler vent_level()
-- maps InvasiveVent=2, NonInvasiveVent/HFNC=1. interval [t, t+60min].
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_vent CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_vent AS
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => o.chartoffset::int))     AS starttime,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(mins => (o.chartoffset+60)::int)) AS endtime,
       CASE
           WHEN lower(o.o2_device) IN ('ventilator','vent') THEN 'InvasiveVent'
           WHEN lower(o.o2_device) LIKE '%bipap%' OR lower(o.o2_device) LIKE '%cpap%'
                OR lower(o.o2_device) IN ('hfnc','high flow') THEN 'NonInvasiveVent'
           ELSE NULL
       END AS ventilation_status
FROM eicu.akd_v3_cohort b
JOIN eicu.pivoted_o2 o
  ON o.patientunitstayid = b.stay_id
 AND o.chartoffset BETWEEN b.win_start_min AND b.win_end_min
WHERE (lower(o.o2_device) IN ('ventilator','vent')
       OR lower(o.o2_device) LIKE '%bipap%' OR lower(o.o2_device) LIKE '%cpap%'
       OR lower(o.o2_device) IN ('hfnc','high flow'));

CREATE INDEX idx_eicu_akd_v3_vent_stay ON eicu.akd_v3_vent (stay_id, starttime);
ANALYZE eicu.akd_v3_vent;

-- ==========================================================================
-- static features (akd_v3_static): one row per stay.
-- column names MUST match what 03_split_impute_scale.py expects:
--   subject_id, stay_id, akd_flag, gender, race, sepsis3, kd_diagnosis,
--   icd_kd_diagnosis, age, obs_hours, admit_weight, any_weight, cr_baseline,
--   sapsii(=APS III proxy), sofa_baseline
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_static CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_static AS
WITH sofa_static AS (
    SELECT DISTINCT ON (b.stay_id) b.stay_id, s.sofa_24hours AS sofa_baseline
    FROM eicu.akd_v3_cohort b
    JOIN eicu.sofa_score s
      ON s.patientunitstayid = b.stay_id AND (s.starttime*60) <= b.t0_off
    ORDER BY b.stay_id, s.starttime DESC
),
aps AS (
    SELECT DISTINCT ON (patientunitstayid) patientunitstayid,
           acutephysiologyscore AS aps_iii
    FROM eicu.apachepatientresult
    WHERE acutephysiologyscore IS NOT NULL AND acutephysiologyscore >= 0
    ORDER BY patientunitstayid, apacheversion DESC
),
ckd AS (
    SELECT patientunitstayid,
           STRING_AGG(DISTINCT lower(pasthistoryvalue), ', ') AS kd_text
    FROM eicu.ckd_pasthistory
    GROUP BY patientunitstayid
),
sep AS (
    SELECT DISTINCT patientunitstayid, TRUE AS sepsis3
    FROM eicu.sepsis_3_ab
)
SELECT
    b.stay_id, b.subject_id, b.hadm_id, b.akd_flag,
    b.t0_time, b.icu_intime, b.win_start, b.win_end,
    ROUND((b.win_end_min - b.win_start_min) / 60.0, 2) AS obs_hours,
    CASE WHEN d.age = '> 89' THEN 90
         WHEN d.age ~ '^[0-9]+$' THEN d.age::int
         ELSE NULL END AS age,
    d.gender,
    d.ethnicity AS race,
    d.admissionweight AS admit_weight,
    COALESCE(d.admissionweight, d.dischargeweight) AS any_weight,
    crb.cr_baseline,
    ck.kd_text AS kd_diagnosis,
    ck.kd_text AS icd_kd_diagnosis,
    aps.aps_iii AS sapsii,
    ss.sofa_baseline,
    COALESCE(sp.sepsis3, FALSE) AS sepsis3
FROM eicu.akd_v3_cohort b
LEFT JOIN eicu.icustay_detail d ON d.patientunitstayid = b.stay_id
LEFT JOIN eicu.cr_baseline_union crb ON crb.patientunitstayid = b.stay_id
LEFT JOIN ckd ck ON ck.patientunitstayid = b.stay_id
LEFT JOIN aps ON aps.patientunitstayid = b.stay_id
LEFT JOIN sofa_static ss ON ss.stay_id = b.stay_id
LEFT JOIN sep sp ON sp.patientunitstayid = b.stay_id;

CREATE UNIQUE INDEX idx_eicu_akd_v3_static_stay ON eicu.akd_v3_static (stay_id);
ANALYZE eicu.akd_v3_static;

-- ==========================================================================
-- diagnosis text (akd_v3_diag): Primary+Major ~ MIMIC seq_num<=2.
-- clean text: lower + strip ,() like MIMIC. (J.4 will finalize; usable now.)
-- ==========================================================================
-- diag: PRIMARY diagnosis ONLY, earliest record per stay.
-- Unified 2026-08-12. NOTE eICU repeats the same Primary diagnosis at
-- many offsets (mean 6.3, max 278 rows per stay), so a plain filter is
-- NOT enough; ROW_NUMBER keeps one row and makes the text comparable
-- to MIMIC/SICdb. Previously Primary+Major, STRING_AGG of all rows.
DROP MATERIALIZED VIEW IF EXISTS eicu.akd_v3_diag CASCADE;
CREATE MATERIALIZED VIEW eicu.akd_v3_diag AS
WITH pri AS (
    SELECT b.stay_id, b.hadm_id, dg.diagnosisstring,
           ROW_NUMBER() OVER (PARTITION BY b.stay_id
                              ORDER BY dg.diagnosisoffset, dg.diagnosisid) AS rn
    FROM eicu.akd_v3_cohort b
    JOIN eicu.diagnosis dg ON dg.patientunitstayid = b.stay_id
     AND dg.diagnosispriority = 'Primary'
)
SELECT stay_id, hadm_id,
       REGEXP_REPLACE(LOWER(diagnosisstring), '[,()]+', ' ', 'g') AS diag_text
FROM pri WHERE rn = 1;

CREATE UNIQUE INDEX idx_eicu_akd_v3_diag_stay ON eicu.akd_v3_diag (stay_id);
ANALYZE eicu.akd_v3_diag;

\echo '=== 01_cohort_features_eicu: eicu.akd_v3_* views created ==='
SELECT
    (SELECT COUNT(*) FROM eicu.akd_v3_cohort)  AS n_cohort,
    (SELECT COUNT(*) FROM eicu.akd_v3_ts_long) AS n_ts_rows,
    (SELECT COUNT(*) FROM eicu.akd_v3_o2)      AS n_o2_rows,
    (SELECT COUNT(*) FROM eicu.akd_v3_static)  AS n_static,
    (SELECT COUNT(*) FROM eicu.akd_v3_vaso)    AS n_vaso,
    (SELECT COUNT(*) FROM eicu.akd_v3_vent)    AS n_vent,
    (SELECT COUNT(*) FROM eicu.akd_v3_diag)    AS n_diag;
