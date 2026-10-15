-- 02_rrt_crrt.sql
-- CRRT is a subset of RRT view
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.rrt_crrt CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.rrt_crrt AS
WITH crrt_settings AS
(
  SELECT
    ce.subject_id, ce.hadm_id, ce.stay_id, ce.charttime, ce.itemid,
    CASE WHEN ce.itemid = 227290 THEN ce.value ELSE NULL END AS crrt_mode,
    CASE WHEN ce.itemid = 224149 THEN ce.valuenum ELSE NULL END AS access_pressure,
    CASE WHEN ce.itemid = 224144 THEN ce.valuenum ELSE NULL END AS blood_flow,
    CASE WHEN ce.itemid = 228004 THEN ce.valuenum ELSE NULL END AS citrate,
    CASE WHEN ce.itemid = 225183 THEN ce.valuenum ELSE NULL END AS current_goal,
    CASE WHEN ce.itemid = 225977 THEN ce.value ELSE NULL END AS dialysate_fluid,
    CASE WHEN ce.itemid = 224154 THEN ce.valuenum ELSE NULL END AS dialysate_rate,
    CASE WHEN ce.itemid = 224151 THEN ce.valuenum ELSE NULL END AS effluent_pressure,
    CASE WHEN ce.itemid = 224150 THEN ce.valuenum ELSE NULL END AS filter_pressure,
    CASE WHEN ce.itemid = 225958 THEN ce.value ELSE NULL END AS heparin_concentration,
    CASE WHEN ce.itemid = 224145 THEN ce.valuenum ELSE NULL END AS heparin_dose,
    CASE WHEN ce.itemid = 224191 THEN ce.valuenum ELSE NULL END AS hourly_patient_fluid_removal,
    CASE WHEN ce.itemid = 228005 THEN ce.valuenum ELSE NULL END AS prefilter_replacement_rate,
    CASE WHEN ce.itemid = 228006 THEN ce.valuenum ELSE NULL END AS postfilter_replacement_rate,
    CASE WHEN ce.itemid = 225976 THEN ce.value ELSE NULL END AS replacement_fluid,
    CASE WHEN ce.itemid = 224153 THEN ce.valuenum ELSE NULL END AS replacement_rate,
    CASE WHEN ce.itemid = 224152 THEN ce.valuenum ELSE NULL END AS return_pressure,
    CASE WHEN ce.itemid = 226457 THEN ce.valuenum ELSE NULL END AS ultrafiltrate_output,
    CASE WHEN ce.itemid = 225956 THEN ce.value ELSE NULL END AS filter_change,
    CASE WHEN ce.itemid = 224146 THEN ce.value ELSE NULL END AS system_integrity
  FROM mimiciv_icu.chartevents ce
  WHERE ce.itemid IN
  (
    227290, -- CRRT Mode
    224146, -- System Integrity
    225956, -- Reason for CRRT Filter Change
    224149, -- Access Pressure
    224144, -- Blood Flow (ml/min)
    228004, -- Citrate (ACD-A)
    225183, -- Current Goal
    225977, -- Dialysate Fluid
    224154, -- Dialysate Rate
    224151, -- Effluent Pressure
    224150, -- Filter Pressure
    225958, -- Heparin Concentration (units/mL)
    224145, -- Heparin Dose (per hour)
    224191, -- Hourly Patient Fluid Removal
    228005, -- PBP (Prefilter) Replacement Rate
    228006, -- Post Filter Replacement Rate
    225976, -- Replacement Fluid
    224153, -- Replacement Rate
    224152, -- Return Pressure
    226457  -- Ultrafiltrate Output
  )
  AND ce.value IS NOT NULL
)
SELECT *,
  CASE
    WHEN crrt_mode IS NULL
    AND access_pressure IS NULL
    AND blood_flow IS NULL
    AND citrate IS NULL
    AND current_goal IS NULL
    AND (dialysate_fluid IS NULL OR dialysate_fluid LIKE 'None')
    AND dialysate_rate IS NULL
    AND effluent_pressure IS NULL
    AND filter_pressure IS NULL
    AND heparin_concentration IS NULL
    AND heparin_dose IS NULL
    AND hourly_patient_fluid_removal IS NULL
    AND prefilter_replacement_rate IS NULL
    AND postfilter_replacement_rate IS NULL
    AND (replacement_fluid IS NULL OR replacement_fluid LIKE 'None')
    AND replacement_rate IS NULL
    AND return_pressure IS NULL
    AND ultrafiltrate_output IS NULL
    AND filter_change IS NULL
    AND (system_integrity IS NULL OR system_integrity LIKE 'Discontinued')
    THEN 0 ELSE 1
  END AS crrt_active
FROM crrt_settings;
