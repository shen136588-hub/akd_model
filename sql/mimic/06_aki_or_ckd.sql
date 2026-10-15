-- 06_aki_or_ckd.sql
-- CKD/AKI diagnosis identification via ICD code parsing
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.aki_or_ckd CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.aki_or_ckd AS
WITH ckd_dia AS
(
  SELECT
    dia.subject_id, dia.hadm_id,
    icd.icd_code, icd.long_title
  FROM mimiciv_hosp.d_icd_diagnoses icd
  LEFT JOIN mimiciv_hosp.diagnoses_icd dia
    ON dia.icd_code = icd.icd_code
  WHERE LOWER(icd.long_title) LIKE ANY (
    ARRAY['%chronic kidney disease%',
          '%kidney failure%',
          '%kidney dialysis%',
          '%end stage renal disease%',
          '%renal failure%',
          '%renal dialysis%']
  )
  AND dia.hadm_id IS NOT NULL
),
aki_ckd AS
(
  SELECT *,
    CASE
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%unspecified%' THEN 'ckd unspecified'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage v%' THEN 'ckd5'
      WHEN LOWER(long_title) LIKE '%end stage renal disease%' THEN 'ckd5'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage 5%' THEN 'ckd5'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage iv%' THEN 'ckd4'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage 4%' THEN 'ckd4'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage iii%' THEN 'ckd3'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage 3%' THEN 'ckd3'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage ii%' THEN 'ckd2'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage 2%' THEN 'ckd2'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage i%' THEN 'ckd1'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%stage 1%' THEN 'ckd1'
      WHEN LOWER(long_title) LIKE '%chronic kidney disease%' THEN 'ckd unspecified'
      WHEN LOWER(long_title) LIKE '%acute kidney failure%' THEN 'aki'
      WHEN LOWER(long_title) LIKE '%kidney dialysis%' THEN 'rrt'
      WHEN LOWER(long_title) LIKE '%renal failure%' THEN 'rf unspecified'
      WHEN LOWER(long_title) LIKE '%renal dialysis%' THEN 'rrt'
      ELSE NULL
    END AS diagnosis
  FROM ckd_dia
)
SELECT
  subject_id, hadm_id,
  STRING_AGG(long_title, ',') AS icd_kd_diagnosis,
  STRING_AGG(diagnosis, ',') AS kd_diagnosis
FROM aki_ckd
GROUP BY (subject_id, hadm_id);
