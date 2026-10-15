-- 04_rrt_active.sql
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.rrt_active CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.rrt_active AS
WITH rt AS
(
  SELECT
    subject_id, hadm_id, stay_id, charttime,
    ROW_NUMBER() OVER(PARTITION BY stay_id, charttime ORDER BY charttime) AS num,
    1 AS rt_active
  FROM mimiciv_derived.rrt_all
  WHERE dialysis_active = 1
)
SELECT * FROM rt WHERE num = 1;
