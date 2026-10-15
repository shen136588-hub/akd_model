-- 16_kdigo_uo_step2.sql
-- KDIGO UO step 2: compute 6/12/24h cumulative urine output totals
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo_uo_step2 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo_uo_step2 AS
SELECT
    uo.hadm_id,
    MAX(uo.stay_id) AS stay_id,
    MAX(uo.charttime) AS charttime,
    MAX(uo."order") AS uo_order,
    MAX(uo.urineoutput) AS urineoutput,
    MAX(uo.uosum_6hr_order) AS uosum_6hr_order,
    MAX(uo.uosum_12hr_order) AS uosum_12hr_order,
    MAX(uo.uosum_24hr_order) AS uosum_24hr_order,
    MAX(uo.uo_tm_6hr) AS uo_tm_6hr,
    MAX(uo.uo_tm_12hr) AS uo_tm_12hr,
    MAX(uo.uo_tm_24hr) AS uo_tm_24hr,
    SUM(CASE
        WHEN uosum.uo_order >= uo.uosum_6hr_order
        AND uosum.uo_order <= uo."order"
        THEN uosum.urineoutput
        ELSE NULL
    END) AS uosum_6hr,
    SUM(CASE
        WHEN uosum.uo_order >= uo.uosum_12hr_order
        AND uosum.uo_order <= uo."order"
        THEN uosum.urineoutput
        ELSE NULL
    END) AS uosum_12hr,
    SUM(CASE
        WHEN uosum.uo_order >= uo.uosum_24hr_order
        AND uosum.uo_order <= uo."order"
        THEN uosum.urineoutput
        ELSE NULL
    END) AS uosum_24hr
FROM mimiciv_derived.kdigo_uo_step1 uo
LEFT JOIN mimiciv_derived.urine_output_kdigo_akistage uosum
    ON uo.stay_id = uosum.stay_id
    AND uosum.uo_order <= uo."order" + 1
    AND uosum.charttime >= uo.charttime - INTERVAL '24 hour'
GROUP BY uo.hadm_id, uo.stay_id, uo."order";
