-- 17_kdigo_uo_step3.sql
-- KDIGO UO step 3: calculate weight-adjusted urine output rate
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo_uo_step3 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo_uo_step3 AS
WITH aki AS (
  SELECT
    hadm_id, stay_id, charttime, uo_order, urineoutput,
    uosum_6hr_order, uosum_12hr_order, uosum_24hr_order,
    CASE WHEN uo_tm_6hr > 0 THEN uo_tm_6hr ELSE NULL END AS uo_tm_6hr,
    CASE WHEN uo_tm_12hr > 0 THEN uo_tm_12hr ELSE NULL END AS uo_tm_12hr,
    CASE WHEN uo_tm_24hr > 0 THEN uo_tm_24hr ELSE NULL END AS uo_tm_24hr,
    uosum_6hr, uosum_12hr, uosum_24hr
  FROM mimiciv_derived.kdigo_uo_step2
)
SELECT
  ur.*,
  wd.weight AS weight,
  ROUND((ur.uosum_6hr / wd.weight / NULLIF(ur.uo_tm_6hr, 0))::numeric, 4) AS uo_rt_6hr,
  ROUND((ur.uosum_12hr / wd.weight / NULLIF(ur.uo_tm_12hr, 0))::numeric, 4) AS uo_rt_12hr,
  ROUND((ur.uosum_24hr / wd.weight / NULLIF(ur.uo_tm_24hr, 0))::numeric, 4) AS uo_rt_24hr
FROM aki ur
LEFT JOIN mimiciv_derived.weight_durations wd
  ON ur.stay_id = wd.stay_id
  AND ur.charttime >= wd.starttime
  AND ur.charttime < wd.endtime;
