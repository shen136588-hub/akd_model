-- 08_id_rrt_without_record.sql
-- Identify patients on RRT without records
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.id_rrt_without_record CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.id_rrt_without_record AS
WITH id1 AS (
    SELECT hadm_id FROM mimiciv_derived.aki_or_ckd WHERE kd_diagnosis LIKE '%rrt%'
),
id2 AS (
    SELECT DISTINCT hadm_id FROM mimiciv_derived.rrt_all WHERE dialysis_active = 1
),
id3 AS (
    SELECT subject_id, hadm_id, stay_id,
           MAX(dialysis_present) AS dialysis_present,
           MAX(dialysis_active) AS dialysis_active
    FROM mimiciv_derived.rrt_all
    GROUP BY subject_id, hadm_id, stay_id
),
adm AS (
    (SELECT hadm_id FROM id1
     UNION
     SELECT hadm_id FROM id3 WHERE dialysis_present = 1 AND dialysis_active = 0)
    EXCEPT
    SELECT hadm_id FROM id2
)
SELECT adm.hadm_id, icu.stay_id
FROM adm
LEFT JOIN mimiciv_icu.icustays icu ON adm.hadm_id = icu.hadm_id;
