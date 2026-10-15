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
-- 01_cohort_features_sicdb.sql   (SICdb external-validation feature extraction)
-- Author: mihao for zhaoyang    Date: 2026-07-28
--
-- GOAL: emit 7 views with SAME column names & schema as MIMIC
--   mimiciv_derived.akd_v3_*  so identical 02_assemble.py consumes exports and
--   the LOCKED MIMIC scaler/imputer/PCA + checkpoint transform (never refit).
--
-- KEY ALIGNMENT (see design doc J.5/J.6):
--   * ids: stay_id/subject_id/hadm_id already present in cohort/icustay_detail.
--   * time axis: SICdb offsets are SECONDS since HOSPITAL ADMIT. ICU intime is
--     icu_offset_sec. We rebase everything to ICU intime then synthesize
--     timestamp = BASE '2000-01-01' + (offset_sec - icu_offset_sec) seconds,
--     so assembler hour-grid (relative to win_start) works unchanged.
--   * window plan A [t0-24h,t0]: win_lo_sec=-86400, win_hi_sec=0. win_start
--     clipped to ICU intime: GREATEST(t0_sec-86400, icu_offset_sec). All source
--     charttime_offset are hospital-relative sec; keep only >= icu_offset_sec.
--   * severity: SICdb has SAPS 3 -> output as column "sapsii" for 03. (proxy)
--   * sepsis3: native sicdb.sepsis3.sepsis3_flag (integer 0/1).
--   * PT native (coagulation.pt); lactate from bg; P/F from oxygen_delivery
--     (native ratio + pao2/fio2 nearest-time pairing to fix sparsity, ~81->8.7k).
--   * SOFA: sicdb.sofa_official is DAILY (day_num, 86400s steps). We emit one
--     point per day at its offset; assembler ffill carries it across hours.
--   * fio2 output as PERCENT (oxygen_delivery.fio2 fraction? verified below).
--   * diag: icd10maintext (German) as diag_text placeholder (J.4 finalizes).
--
-- USAGE (plan A):
--   psql -v win_lo_sec=-86400 -v win_hi_sec=0 -f 01_cohort_features_sicdb.sql
-- =============================================================================

\set win_lo_sec :ext_win_lo_sec
\set win_hi_sec :ext_win_hi_sec

SET work_mem = '1GB';
SET max_parallel_workers_per_gather = 8;

-- ==========================================================================
-- cohort + window boundaries (akd_v3_cohort). offsets rebased to ICU intime.
--   win_start_sec / win_end_sec are HOSPITAL-relative sec (for source filter).
--   timestamps are ICU-relative (subtract icu_offset_sec) for assembler.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_cohort CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_cohort AS
SELECT
    c.subject_id, c.hadm_id, c.stay_id,
    d.icu_offset_sec,
    (TIMESTAMP '2000-01-01 00:00:00')                                                          AS icu_intime,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (c.disch_sec - d.icu_offset_sec))) AS icu_outtime,
    (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (c.t0_sec - d.icu_offset_sec)))     AS t0_time,
    c.akd_flag,
    (TIMESTAMP '2000-01-01 00:00:00'
       + make_interval(secs => (GREATEST(c.t0_sec + (:win_lo_sec), d.icu_offset_sec) - d.icu_offset_sec))) AS win_start,
    (TIMESTAMP '2000-01-01 00:00:00'
       + make_interval(secs => ((c.t0_sec + (:win_hi_sec)) - d.icu_offset_sec)))                           AS win_end,
    c.t0_sec,
    GREATEST(c.t0_sec + (:win_lo_sec), d.icu_offset_sec)::bigint AS win_start_sec,
    (c.t0_sec + (:win_hi_sec))::bigint                          AS win_end_sec
FROM sicdb.kdigo2012_with_rrt_akd_cohort c
JOIN sicdb.icustay_detail d ON d.stay_id = c.stay_id
WHERE c.akd_flag IS NOT NULL;

CREATE UNIQUE INDEX idx_sicdb_akd_v3_cohort_stay ON sicdb.akd_v3_cohort (stay_id);
ANALYZE sicdb.akd_v3_cohort;

-- ==========================================================================
-- time-series long table (akd_v3_ts_long). column names match MIMIC.
-- charttime = BASE + (charttime_offset - icu_offset_sec) seconds.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_ts_long CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_ts_long AS
WITH
vs AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (v.charttime_offset - b.icu_offset_sec))) AS charttime,
           v.heart_rate::double precision,
           COALESCE(v.sbp, v.sbp_ni)::double precision AS sbp,
           COALESCE(v.dbp, v.dbp_ni)::double precision AS dbp,
           COALESCE(v.mbp, v.mbp_ni)::double precision AS mbp,
           v.resp_rate::double precision, v.temperature::double precision, v.spo2::double precision
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.vitalsign v
      ON v.stay_id = b.stay_id
     AND v.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
),
chem AS (
    -- ★ UNIT FIX 2026-08-02 (#1 calcium): SICdb chemistry.calcium 单位为 mmol/L
    -- (d_references 457/458 = mmol/L, median 2.11), MIMIC/eICU chemistry.calcium
    -- 为 mg/dL (median 8.3). 1 mmol/L = 4.008 mg/dL. 不换算会让 MIMIC scaler
    -- 把 SICdb 钙压到 -7 个标准差 (实测 mean=-7.03), 直接污染外验。
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (ch.charttime_offset - b.icu_offset_sec))) AS charttime,
           ch.bun::double precision, ch.creatinine::double precision AS creat_lab,
           ch.chloride::double precision, ch.sodium::double precision,
           ch.potassium::double precision,
           (ch.calcium * 4.008)::double precision AS calcium
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.chemistry ch
      ON ch.stay_id = b.stay_id
     AND ch.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
),
-- ★ UNIT FIX 2026-08-02 (#2 glucose/bicarbonate): SICdb 无 chemistry.glucose /
-- chemistry.bicarbonate 字段, 原脚本整列 NULL → 两个特征 100% 缺失, 只能被
-- MIMIC train median 顶替 (常数列, 实测 std=0). SICdb 的血气表 sicdb.bg 有
-- glucose_bg (mg/dL, median 126, 与 MIMIC 130 同量纲) 与 bicarbonate
-- (mmol/L, median 25, 与 MIMIC bicarbonate_chem 23 同量纲) → 用血气值代理。
chem_bg AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (g.charttime_offset - b.icu_offset_sec))) AS charttime,
           g.glucose_bg::double precision AS glucose_chem,
           g.bicarbonate::double precision AS bicarbonate_chem
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.bg g
      ON g.stay_id = b.stay_id
     AND g.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
    WHERE g.glucose_bg IS NOT NULL OR g.bicarbonate IS NOT NULL
),
cbc AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (cb.charttime_offset - b.icu_offset_sec))) AS charttime,
           cb.wbc::double precision, cb.hemoglobin::double precision, cb.platelet::double precision
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.complete_blood_count cb
      ON cb.stay_id = b.stay_id
     AND cb.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
),
coag AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (cg.charttime_offset - b.icu_offset_sec))) AS charttime,
           cg.pt::double precision, cg.aptt::double precision AS ptt
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.coagulation cg
      ON cg.stay_id = b.stay_id
     AND cg.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
),
bloodgas AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (g.charttime_offset - b.icu_offset_sec))) AS charttime,
           g.po2::double precision, g.pco2::double precision, g.ph::double precision,
           g.lactate::double precision, g.baseexcess::double precision, g.aniongap::double precision
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.bg g
      ON g.stay_id = b.stay_id
     AND g.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
),
pf AS (
    -- P/F ratio. Native oxygen_delivery.pao2fio2_ratio is very sparse (only ~81
    -- rows in-cohort) because pao2 and fio2 rarely co-occur on the SAME row.
    -- Supplement: within each stay, pair every pao2 measurement with the nearest
    -- fio2 (ffill preferred = current ventilator setting at the blood-gas moment,
    -- bfill fallback), then P/F = pao2 / (fio2/100). fio2 cleaned to [21,100],
    -- pao2>0. This lifts coverage ~81 -> ~8.7k rows / 897 stays, median ~211
    -- (matches native ratio median ~228). See design doc problem #2.
    WITH o_pao2 AS (
        SELECT o.stay_id, o.charttime_offset AS t, o.pao2, o.pao2fio2_ratio
        FROM sicdb.akd_v3_cohort b
        JOIN sicdb.oxygen_delivery o
          ON o.stay_id = b.stay_id
         AND o.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
         AND o.pao2 IS NOT NULL AND o.pao2 > 0
    ),
    o_fio2 AS (
        SELECT o.stay_id, o.charttime_offset AS t, o.fio2
        FROM sicdb.akd_v3_cohort b
        JOIN sicdb.oxygen_delivery o
          ON o.stay_id = b.stay_id
         AND o.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
         AND o.fio2 BETWEEN 21 AND 100
    ),
    paired AS (
        SELECT p.stay_id, p.t, p.pao2, p.pao2fio2_ratio,
               COALESCE(
                 (SELECT f.fio2 FROM o_fio2 f
                   WHERE f.stay_id = p.stay_id AND f.t <= p.t
                   ORDER BY f.t DESC LIMIT 1),
                 (SELECT f.fio2 FROM o_fio2 f
                   WHERE f.stay_id = p.stay_id AND f.t > p.t
                   ORDER BY f.t ASC LIMIT 1)
               ) AS fio2_matched
        FROM o_pao2 p
    )
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (pr.t - b.icu_offset_sec))) AS charttime,
           COALESCE(
             pr.pao2fio2_ratio,
             CASE WHEN pr.fio2_matched IS NOT NULL
                  THEN ROUND((pr.pao2 / (pr.fio2_matched / 100.0))::numeric, 1)
                  ELSE NULL END
           )::double precision AS pao2fio2ratio
    FROM paired pr
    JOIN sicdb.akd_v3_cohort b ON b.stay_id = pr.stay_id
    WHERE COALESCE(pr.pao2fio2_ratio,
                   CASE WHEN pr.fio2_matched IS NOT NULL
                        THEN pr.pao2 / (pr.fio2_matched / 100.0) ELSE NULL END) IS NOT NULL
),
cr_uo AS (
    -- ★★ UNIT FIX 2026-08-02 (#3 尿量, 最严重): sicdb.urine_output_rate 的
    -- uo_6hr/12hr/24hr 是**滚动窗口内尿量总和 (mL)**, 不是 mL/kg/h!
    -- (实测 uo_6hr median = 840 mL; MIMIC uo_mlkghr_6hr median = 0.86 mL/kg/h)
    -- 原脚本直接当 uo_rt_* 用 → SICdb 尿量特征放大 ~800-2400 倍, 而 uo_rt_12hr_std
    -- 恰是 XGBoost 第 1 重要特征 → 这是 SICdb 外验 AUROC 掉到 0.399 的主因。
    -- 修正: 转成 MIMIC 同口径 mL/kg/h = 窗口总量 / 体重 / 窗口小时数。
    -- 窗口小时数用实际可观测跨度封顶 (charttime_hours), 避免入 ICU 早期
    -- (不足 6/12/24h) 时被系统性低估。
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (u.charttime_offset - b.icu_offset_sec))) AS charttime,
           (u.uo_6hr  / NULLIF(w.weight_kg, 0)
                      / GREATEST(LEAST(u.charttime_hours, 6), 1))::numeric  AS uo_rt_6hr,
           (u.uo_12hr / NULLIF(w.weight_kg, 0)
                      / GREATEST(LEAST(u.charttime_hours, 12), 1))::numeric AS uo_rt_12hr,
           (u.uo_24hr / NULLIF(w.weight_kg, 0)
                      / GREATEST(LEAST(u.charttime_hours, 24), 1))::numeric AS uo_rt_24hr
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.urine_output_rate u
      ON u.stay_id = b.stay_id
     AND u.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
    -- B2 FIX (2026-08-03): was an INNER JOIN with `w.weight_kg > 0`, which
    -- silently discarded ALL urine-output rows for any stay lacking a usable
    -- weight. Urine output is the #1 XGBoost feature block, and neither MIMIC
    -- nor eICU gate uo on a weight join, so this was a cross-cohort asymmetry.
    -- Now LEFT JOIN: no weight -> NULLIF yields NULL -> the Python layer's
    -- ffill/bfill + MIMIC-train-median imputation handles it, same as any other
    -- missing value. Measured impact at the time of the fix: 1 / 1198 stays.
    LEFT JOIN sicdb.icustays w
           ON w.stay_id = b.stay_id
          AND w.weight_kg > 0
),
sofa_ts AS (
    SELECT b.stay_id,
           (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (s.charttime_offset - b.icu_offset_sec))) AS charttime,
           s.sofa::integer AS sofa_24hours
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.sofa_official s
      ON s.stay_id = b.stay_id
     AND s.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec
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
       bun, creat_lab, chloride, sodium, potassium, calcium, NULL, NULL,
       NULL,
       NULL,NULL,NULL,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM chem
UNION ALL
-- ★ UNIT FIX #2: glucose/bicarbonate 从血气补录 (SICdb chemistry 无此两项)
SELECT stay_id, charttime, 'chem_bg',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL, glucose_chem, bicarbonate_chem,
       NULL,
       NULL,NULL,NULL,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM chem_bg
UNION ALL
SELECT stay_id, charttime, 'cbc',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       wbc, hemoglobin, platelet,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM cbc
UNION ALL
SELECT stay_id, charttime, 'coag',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       NULL,NULL,NULL,
       pt, ptt,
       NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL, NULL
FROM coag
UNION ALL
SELECT stay_id, charttime, 'bg',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       aniongap,
       NULL,NULL,NULL,
       NULL,NULL,
       po2, pco2, ph, lactate, baseexcess, NULL,
       NULL,NULL,NULL, NULL
FROM bloodgas
UNION ALL
SELECT stay_id, charttime, 'pf',
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
       NULL,
       NULL,NULL,NULL,
       NULL,NULL,
       NULL,NULL,NULL,NULL,NULL, pao2fio2ratio,
       NULL,NULL,NULL, NULL
FROM pf
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

CREATE INDEX idx_sicdb_akd_v3_ts_long_stay ON sicdb.akd_v3_ts_long (stay_id, charttime);
ANALYZE sicdb.akd_v3_ts_long;

-- ==========================================================================
-- oxygen therapy (akd_v3_o2). oxygen_delivery has fio2 + o2_flow + o2_mode.
-- fio2 output as PERCENT. device_cat from o2_mode / intubated_flag / airway_type.
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_o2 CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_o2 AS
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (o.charttime_offset - b.icu_offset_sec))) AS charttime,
       CASE
           WHEN o.intubated_flag = 1 THEN 'iv'
           WHEN lower(coalesce(o.o2_mode,'')) LIKE '%ecmo%' THEN 'ecmo'
           -- ★ DEVICE FIX 2026-08-02 (#4): SICdb intubated_flag 恒为 0 (实测
           -- 2,802,632 行全部 =0), 且无 bipap/cpap/niv 字样 → 原映射把
           -- 'ventilator_setting_only' (595,045 行, 即读数来自呼吸机设定 =
           -- 患者正在接有创通气) 退化成 'cot'(=1), 导致 SICdb
           -- o2_device_cat_numeric median=1 vs MIMIC=4, 器械分级系统性低估 3 级。
           -- 修正: ventilator_setting_only → 'iv'; 并以 sicdb.ventilation
           -- (ventilation_status 全为 InvasiveVent) 区间覆盖作为二重确认。
           WHEN lower(coalesce(o.o2_mode,'')) LIKE '%ventilator_setting%' THEN 'iv'
           WHEN EXISTS (
               SELECT 1 FROM sicdb.ventilation ve
               WHERE ve.stay_id = b.stay_id
                 AND ve.ventilation_status = 'InvasiveVent'
                 AND o.charttime_offset BETWEEN ve.starttime AND ve.endtime
           ) THEN 'iv'
           WHEN lower(coalesce(o.o2_mode,'')) LIKE '%bipap%' OR lower(coalesce(o.o2_mode,'')) LIKE '%cpap%'
                OR lower(coalesce(o.o2_mode,'')) LIKE '%niv%' THEN 'niv'
           WHEN lower(coalesce(o.o2_mode,'')) LIKE '%hfnc%' OR lower(coalesce(o.o2_mode,'')) LIKE '%high flow%' THEN 'hf'
           WHEN o.o2_flow IS NOT NULL AND o.o2_flow > 0 THEN 'cot'
           WHEN o.fio2 IS NOT NULL THEN 'cot'
           ELSE NULL
       END AS o2_device_cat,
       o.o2_flow::double precision AS o2_flow,
       CASE WHEN o.fio2 IS NULL THEN NULL
            WHEN o.fio2 <= 1.0 THEN o.fio2 * 100.0
            ELSE o.fio2 END::double precision AS fio2
FROM sicdb.akd_v3_cohort b
JOIN sicdb.oxygen_delivery o
  ON o.stay_id = b.stay_id
 AND o.charttime_offset BETWEEN b.win_start_sec AND b.win_end_sec;

CREATE INDEX idx_sicdb_akd_v3_o2_stay ON sicdb.akd_v3_o2 (stay_id, charttime);
ANALYZE sicdb.akd_v3_o2;

-- ==========================================================================
-- vasoactive agents (akd_v3_vaso). native vasoactive_agent is interval-typed
-- (starttime/endtime sec). rebase to ICU intime. 6 drugs (drop milrinone).
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_vaso CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_vaso AS
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (va.starttime - b.icu_offset_sec))) AS starttime,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (va.endtime   - b.icu_offset_sec))) AS endtime,
       va.norepinephrine::double precision, va.epinephrine::double precision,
       va.dopamine::double precision, va.dobutamine::double precision,
       va.phenylephrine::double precision, va.vasopressin::double precision
FROM sicdb.akd_v3_cohort b
JOIN sicdb.vasoactive_agent va
  ON va.stay_id = b.stay_id
 AND va.starttime <= b.win_end_sec
 AND va.endtime   >= b.win_start_sec;

CREATE INDEX idx_sicdb_akd_v3_vaso_stay ON sicdb.akd_v3_vaso (stay_id, starttime);
ANALYZE sicdb.akd_v3_vaso;

-- ==========================================================================
-- mechanical ventilation (akd_v3_vent). native ventilation interval view.
-- ventilation_status kept as-is (assembler vent_level maps InvasiveVent=2 etc).
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_vent CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_vent AS
SELECT b.stay_id,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (ve.starttime - b.icu_offset_sec))) AS starttime,
       (TIMESTAMP '2000-01-01 00:00:00' + make_interval(secs => (ve.endtime   - b.icu_offset_sec))) AS endtime,
       ve.ventilation_status
FROM sicdb.akd_v3_cohort b
JOIN sicdb.ventilation ve
  ON ve.stay_id = b.stay_id
 AND ve.starttime <= b.win_end_sec
 AND ve.endtime   >= b.win_start_sec;

CREATE INDEX idx_sicdb_akd_v3_vent_stay ON sicdb.akd_v3_vent (stay_id, starttime);
ANALYZE sicdb.akd_v3_vent;

-- ==========================================================================
-- static features (akd_v3_static). column names match 03 expectations.
--   sapsii = SAPS 3 proxy; sofa_baseline from sepsis3 view; sepsis3 native.
--   kd_diagnosis/icd_kd_diagnosis: placeholder from icd10maintext (German),
--   parse_ckd_stage in 03 will return 0 (no 'ckd N' english) -> acceptable,
--   dialysis_dep -> 0. (documented limitation; refine in J.4 if needed.)
-- ==========================================================================
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_static CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_static AS
WITH sofa_static AS (
    SELECT DISTINCT ON (b.stay_id) b.stay_id, s.sofa AS sofa_baseline
    FROM sicdb.akd_v3_cohort b
    JOIN sicdb.sofa_official s
      ON s.stay_id = b.stay_id AND s.charttime_offset <= b.t0_sec
    ORDER BY b.stay_id, s.charttime_offset DESC
)
SELECT
    b.stay_id, b.subject_id, b.hadm_id, b.akd_flag,
    b.t0_time, b.icu_intime, b.win_start, b.win_end,
    ROUND((b.win_end_sec - b.win_start_sec) / 3600.0, 2) AS obs_hours,
    d.age::int AS age,
    d.gender,
    NULL::text AS race,
    d.weight_kg AS admit_weight,
    d.weight_kg AS any_weight,
    crb.cr_baseline,
    d.icd10maintext AS kd_diagnosis,
    d.icd10main      AS icd_kd_diagnosis,
    d.saps3          AS sapsii,
    ss.sofa_baseline,
    COALESCE(sep.sepsis3_flag = 1, FALSE) AS sepsis3
FROM sicdb.akd_v3_cohort b
LEFT JOIN sicdb.icustay_detail d ON d.stay_id = b.stay_id
LEFT JOIN sicdb.cr_baseline crb ON crb.stay_id = b.stay_id
LEFT JOIN sicdb.sepsis3 sep ON sep.stay_id = b.stay_id
LEFT JOIN sofa_static ss ON ss.stay_id = b.stay_id;

CREATE UNIQUE INDEX idx_sicdb_akd_v3_static_stay ON sicdb.akd_v3_static (stay_id);
ANALYZE sicdb.akd_v3_static;

-- ==========================================================================
-- diagnosis (akd_v3_diag). SICdb icd10maintext is GERMAN. Per H.7/J.4 decision:
-- emit standard ICD-10 CODES (main + secondary) from sicdb.cases; the Python
-- side (04b) maps codes -> English WHO titles (simple_icd_10) -> BioClinicalBERT
-- -> MIMIC diag_pca transform. This makes diag cross-cohort comparable.
-- diag_text here = space-joined ICD codes (e.g. 'I71.0 K85.2'); diag_icd kept raw.
-- ==========================================================================
-- diag: PRIMARY ICD-10 CODE ONLY (cases.icd10main).
-- FIXED 2026-08-12 (audit item B9): the previous expression was
--   CONCAT_WS(' ', icd10main, diagnosist2)
-- which emitted 'CODE + GERMAN TEXT' although the comment claimed it
-- emitted codes. 03b_external_transform.py --icd_map only maps the
-- FIRST token, so the German words were passed to BioClinicalBERT as
-- unknown tokens. diagnosist2 is NOT a second diagnosis: 0/27350 match
-- an ICD pattern, 65.6% duplicate icd10maintext, 13.2% are empty.
-- Python side maps the pure code -> English WHO title (99.8% of the
-- 617 distinct primary codes in this cohort are mappable).
DROP MATERIALIZED VIEW IF EXISTS sicdb.akd_v3_diag CASCADE;
CREATE MATERIALIZED VIEW sicdb.akd_v3_diag AS
SELECT b.stay_id, b.hadm_id,
       NULLIF(TRIM(c.icd10main), '') AS diag_text
FROM sicdb.akd_v3_cohort b
LEFT JOIN sicdb.cases c ON c.caseid = b.stay_id;

CREATE UNIQUE INDEX idx_sicdb_akd_v3_diag_stay ON sicdb.akd_v3_diag (stay_id);
ANALYZE sicdb.akd_v3_diag;

\echo '=== 01_cohort_features_sicdb: sicdb.akd_v3_* views created ==='
SELECT
    (SELECT COUNT(*) FROM sicdb.akd_v3_cohort)  AS n_cohort,
    (SELECT COUNT(*) FROM sicdb.akd_v3_ts_long) AS n_ts_rows,
    (SELECT COUNT(*) FROM sicdb.akd_v3_o2)      AS n_o2_rows,
    (SELECT COUNT(*) FROM sicdb.akd_v3_static)  AS n_static,
    (SELECT COUNT(*) FROM sicdb.akd_v3_vaso)    AS n_vaso,
    (SELECT COUNT(*) FROM sicdb.akd_v3_vent)    AS n_vent,
    (SELECT COUNT(*) FROM sicdb.akd_v3_diag)    AS n_diag;
