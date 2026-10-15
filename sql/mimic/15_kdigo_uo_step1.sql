-- 15_kdigo_uo_step1.sql
-- KDIGO UO step 1: calculate 6/12/24h cumulative urine output and time span
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo_uo_step1 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.kdigo_uo_step1 AS
SELECT
    MAX(io.hadm_id) AS hadm_id,
    io.stay_id,
    io.charttime,
    MAX(io.uo_order) AS "order",
    MAX(io.urineoutput) AS urineoutput,
    -- 6 hours
    MIN(CASE
            WHEN iosum.charttime >= io.charttime - INTERVAL '6 hours'
            THEN iosum.uo_order
            ELSE NULL
        END) + 1 AS uosum_6hr_order,
    -- 12 hours
    MIN(CASE
            WHEN iosum.charttime >= io.charttime - INTERVAL '12 hours'
            THEN iosum.uo_order
            ELSE NULL
        END) + 1 AS uosum_12hr_order,
    -- 24 hours
    MIN(iosum.uo_order) + 1 AS uosum_24hr_order,
    -- Calculate time span (hours)
    ROUND(CAST(
        EXTRACT(EPOCH FROM (io.charttime -
            MIN(CASE
                    WHEN iosum.charttime >= io.charttime - INTERVAL '6 hours'
                    THEN iosum.charttime
                    ELSE NULL
                END)
        )) / 3600.0 AS NUMERIC), 4) AS uo_tm_6hr,
    ROUND(CAST(
        EXTRACT(EPOCH FROM (io.charttime -
            MIN(CASE
                    WHEN iosum.charttime >= io.charttime - INTERVAL '12 hours'
                    THEN iosum.charttime
                    ELSE NULL
                END)
        )) / 3600.0 AS NUMERIC), 4) AS uo_tm_12hr,
    ROUND(CAST(
        EXTRACT(EPOCH FROM (io.charttime - MIN(iosum.charttime))) / 3600.0 AS NUMERIC), 4) AS uo_tm_24hr
FROM mimiciv_derived.urine_output_kdigo_akistage io
LEFT JOIN mimiciv_derived.urine_output_kdigo_akistage iosum
    ON io.stay_id = iosum.stay_id
    AND iosum.charttime <= io.charttime
    AND iosum.charttime >= io.charttime - INTERVAL '24 hours'
GROUP BY io.stay_id, io.charttime;
