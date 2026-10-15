-- 01_akistage_creatinine_step1.sql
-- Extract creatinine values per hadm_id, 7 days pre-admission to 12h post-discharge
-- Adapted for MIMIC-IV 3.1 schema
--
-- v2 (2026-07-22) 去重修复:
--   1) labevents 同一 (hadm_id, charttime) 可能有多条肌酐记录 → 用 AVG 聚合到唯一时点
--   2) hadm_id → N 个 stay_id 的 fan-out 会把每条 lab 复制 N 份
--      → 用 DISTINCT ON 让每条 lab 只归属最合理的一次 ICU stay（距 intime 最近）
--   3) cr48 / cr7 改用 hadm_id 做 self-join key（此时 (hadm, charttime) 已唯一）

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.akistage_creatinine_step1 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.akistage_creatinine_step1 AS
WITH cr_raw AS
(
  -- 原始肌酐: 未做时点去重, 只按 hadm 层筛入院窗口
  SELECT
    adm.subject_id,
    adm.hadm_id,
    adm.admittime,
    adm.dischtime,
    le.charttime,
    le.valuenum AS creat
  FROM mimiciv_hosp.admissions adm
  JOIN mimiciv_hosp.labevents le
    ON adm.hadm_id = le.hadm_id
  WHERE le.itemid = 50912
    AND le.valuenum IS NOT NULL
    AND le.valuenum <= 150
    AND le.valuenum > 0
    AND le.charttime BETWEEN (adm.admittime - INTERVAL '7 day')
                         AND (adm.dischtime + INTERVAL '12 hour')
),
cr_hadm AS
(
  -- 同一 (hadm_id, charttime) 若有多条 → 取均值合并成 1 条
  SELECT
    subject_id,
    hadm_id,
    admittime,
    dischtime,
    charttime,
    AVG(creat) AS creat
  FROM cr_raw
  GROUP BY subject_id, hadm_id, admittime, dischtime, charttime
),
cr AS
(
  -- 把每条 lab 唯一分配到一个 stay_id: 距 intime 最近的 ICU 入住
  -- 无 ICU 入住的 hadm → stay_id 保持 NULL (LEFT JOIN)
  SELECT DISTINCT ON (h.hadm_id, h.charttime)
    h.subject_id,
    h.hadm_id,
    ie.stay_id,
    ie.intime,
    ie.outtime,
    ROUND(ie.los::numeric, 1) AS iculos,
    ROUND((EXTRACT(EPOCH FROM (h.dischtime - h.admittime)) / 86400)::numeric, 1) AS hoslos,
    h.admittime,
    h.dischtime,
    h.charttime,
    h.creat
  FROM cr_hadm h
  LEFT JOIN mimiciv_icu.icustays ie
    ON ie.hadm_id = h.hadm_id
  ORDER BY
    h.hadm_id,
    h.charttime,
    ABS(EXTRACT(EPOCH FROM (h.charttime - ie.intime))) NULLS LAST,
    ie.stay_id
),
cr48 AS
(
  -- 过去 48h 最低肌酐: (hadm, charttime) 已唯一, 直接按 hadm 自连接
  SELECT
    cr.hadm_id,
    cr.charttime,
    MIN(cr48.creat) AS creat_low_past_48hr
  FROM cr
  LEFT JOIN cr cr48
    ON cr48.hadm_id  = cr.hadm_id
   AND cr48.charttime <  cr.charttime
   AND cr48.charttime >= cr.charttime - INTERVAL '48 hour'
  GROUP BY cr.hadm_id, cr.charttime
),
cr7 AS
(
  -- 过去 7d 最低肌酐
  SELECT
    cr.hadm_id,
    cr.charttime,
    MIN(cr7.creat) AS creat_low_past_7day
  FROM cr
  LEFT JOIN cr cr7
    ON cr7.hadm_id  = cr.hadm_id
   AND cr7.charttime <  cr.charttime
   AND cr7.charttime >= cr.charttime - INTERVAL '7 day'
  GROUP BY cr.hadm_id, cr.charttime
)
SELECT
  cr.subject_id,
  cr.hadm_id,
  cr.stay_id,
  cr.intime,
  cr.outtime,
  cr.iculos,
  cr.hoslos,
  cr.admittime,
  cr.dischtime,
  cr.charttime,
  cr.creat,
  cr48.creat_low_past_48hr,
  cr7.creat_low_past_7day
FROM cr
LEFT JOIN cr48
  ON cr48.hadm_id  = cr.hadm_id
 AND cr48.charttime = cr.charttime
LEFT JOIN cr7
  ON cr7.hadm_id   = cr.hadm_id
 AND cr7.charttime = cr.charttime;

CREATE INDEX IF NOT EXISTS idx_akistage_cr_step1_hadm_time
  ON mimiciv_derived.akistage_creatinine_step1 (hadm_id, charttime);
ANALYZE mimiciv_derived.akistage_creatinine_step1;

\echo '=== akistage_creatinine_step1 v2 (dedup: hadm+time unique, stay_id unique-assigned) ==='
