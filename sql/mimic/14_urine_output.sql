-- 14_urine_output.sql
-- Urine output data preparation for KDIGO UO staging
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.urine_output_kdigo_akistage CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.urine_output_kdigo_akistage AS
WITH urineout AS
(
  SELECT
    stay_id, charttime,
    SUM(urineoutput) AS urineoutput
  FROM
  (
    SELECT
      oe.stay_id, oe.charttime,
      CASE
        WHEN oe.itemid = 227488 AND oe.value > 0 THEN -1 * oe.value
        ELSE oe.value
      END AS urineoutput
    FROM mimiciv_icu.outputevents oe
    WHERE itemid IN
    (
      226559, 226560, 226561, 226584, 226563, 226564, 226565,
      226567, 226557, 226558, 227488, 227489
    )
  ) uo
  GROUP BY stay_id, charttime
)
SELECT
    icu.hadm_id, uo.*,
    ROW_NUMBER() OVER(PARTITION BY uo.stay_id ORDER BY uo.charttime) AS uo_order
FROM urineout uo
LEFT JOIN mimiciv_icu.icustays icu ON uo.stay_id = icu.stay_id;
