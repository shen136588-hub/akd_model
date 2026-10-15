-- 07_agr.sql
-- Age, gender, race info for MDRD formula baseline creatinine calculation
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.agr CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.agr AS
WITH race AS
(
  SELECT subject_id, hadm_id,
    CASE WHEN LOWER(race) LIKE '%black%' THEN 'black' ELSE 'white' END AS race
  FROM mimiciv_hosp.admissions
),
gender AS
(
  SELECT pt.subject_id, ad.hadm_id, pt.gender
  FROM mimiciv_hosp.patients pt
  LEFT JOIN mimiciv_hosp.admissions ad ON pt.subject_id = ad.subject_id
),
age AS
(
  SELECT subject_id, hadm_id, ROUND(age) AS age
  FROM mimiciv_derived.age
)
SELECT * FROM race
FULL JOIN gender USING(subject_id, hadm_id)
FULL JOIN age USING(subject_id, hadm_id);
