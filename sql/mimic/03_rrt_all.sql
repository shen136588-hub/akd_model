-- 03_rrt_all.sql
-- Complete RRT records from chartevents/datetimeevents/inputevents/procedureevents
-- Adapted for MIMIC-IV 3.1 schema

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.rrt_all CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.rrt_all AS
WITH ce AS
(
  SELECT
    ce.hadm_id, ce.stay_id,
    ce.charttime, ce.itemid, ce.value,
    CASE
        WHEN ce.itemid IN
        (
            226118, -- Dialysis Catheter placed in outside facility
            227357, -- Dialysis Catheter Dressing Occlusive
            225725  -- Dialysis Catheter Tip Cultured
        ) THEN 1
        WHEN ce.itemid IN
        (
            226499, -- Hemodialysis Output
            224154, -- Dialysate Rate
            225810, -- Dwell Time (Peritoneal Dialysis)
            225959, -- Medication Added Amount #1 (Peritoneal Dialysis)
            227639, -- Medication Added Amount #2 (Peritoneal Dialysis)
            225183, -- Current Goal
            227438, -- Volume not removed
            224191, -- Hourly Patient Fluid Removal
            225806, -- Volume In (PD)
            225807, -- Volume Out (PD)
            228004, -- Citrate (ACD-A)
            228005, -- PBP (Prefilter) Replacement Rate
            228006, -- Post Filter Replacement Rate
            224144, -- Blood Flow (ml/min)
            224145, -- Heparin Dose (per hour)
            224149, -- Access Pressure
            224150, -- Filter Pressure
            224151, -- Effluent Pressure
            224152, -- Return Pressure
            224153, -- Replacement Rate
            224404, -- ART Lumen Volume
            224406, -- VEN Lumen Volume
            226457, -- Ultrafiltrate Output
            229247, -- Trans Membrane Pressure
            229348  -- Pressure Drop
        ) THEN 1
        WHEN ce.itemid = 225126 AND ce.valuenum = 1 THEN 1 -- Dialysis patient
        WHEN ce.itemid IN
        (
            224135, -- Dialysis Access Site
            224139, -- Dialysis Site Appearance
            224146, -- System Integrity
            225323, -- Dialysis Catheter Site Appear
            225740, -- Dialysis Catheter Discontinued
            225776, -- Dialysis Catheter Dressing Type
            225951, -- Peritoneal Dialysis Fluid Appearance
            225952, -- Medication Added #1 (Peritoneal Dialysis)
            225953, -- Solution (Peritoneal Dialysis)
            225954, -- Dialysis Access Type
            225956, -- Reason for CRRT Filter Change
            225958, -- Heparin Concentration (units/mL)
            225961, -- Medication Added Units #1 (Peritoneal Dialysis)
            225963, -- Peritoneal Dialysis Catheter Type
            225965, -- Peritoneal Dialysis Catheter Status
            225976, -- Replacement Fluid
            225977, -- Dialysate Fluid
            227124, -- Dialysis Catheter Type
            229536, -- Dialysis Catheter Type
            227290, -- CRRT mode
            227638, -- Medication Added #2 (Peritoneal Dialysis)
            227640, -- Medication Added Units #2 (Peritoneal Dialysis)
            227753  -- Dialysis Catheter Placement Confirmed by X-ray
        ) THEN 1
        ELSE 0
    END AS dialysis_present,
    CASE
        WHEN ce.itemid = 225965 AND value = 'In use' THEN 1
        WHEN ce.itemid IN
        (
            226499, 224154, 225810, 225183, 227438, 224191,
            225806, 225807, 228004, 228005, 228006, 224144,
            224145, 224153, 226457, 225959, 227639,
            224149, 224150, 224151, 224152, 224404, 224406,
            225951, 229247, 229348
        ) THEN 1
        WHEN ce.itemid = 224146 AND value <> 'Discontinued' THEN 1
        WHEN ce.itemid IN (225952, 227638) AND value <> 'None' THEN 1
        WHEN ce.itemid = 225953 AND value <> 'None' THEN 1
        WHEN ce.itemid IN (225976, 225977) AND value <> 'None' THEN 1
        ELSE 0
    END AS dialysis_active,
    CASE
        WHEN ce.itemid = 227290 THEN value
        WHEN ce.itemid IN
        (
            225810, 225806, 225807, 227639, 225959,
            225951, 225952, 225961, 225953, 225963,
            225965, 227638, 227640
        ) THEN 'Peritoneal'
        WHEN ce.itemid = 226499 THEN 'IHD'
        ELSE NULL
    END AS dialysis_type
  FROM mimiciv_icu.chartevents ce
  WHERE ce.itemid IN
  (
    226118, 227357, 225725,
    226499, 224154, 225810, 227639, 225183, 227438,
    224191, 225806, 225807, 228004, 228005, 228006,
    224144, 224145, 224149, 224150, 224151, 224152,
    224153, 224404, 224406, 226457, 225959, 225126,
    229247, 229348,
    224135, 224139, 224146, 225323, 225740, 225776,
    225951, 225952, 225953, 225954, 225956, 225958,
    225961, 225963, 225965, 225976, 225977, 227124,
    227290, 227638, 227640, 227753, 229536
  )
  AND ce.value IS NOT NULL
),
de AS
(
  SELECT
    dte.hadm_id, dte.stay_id,
    dte.value AS charttime, dte.itemid,
    di.label AS value,
    1 AS dialysis_present,
    CASE
      WHEN dte.itemid IN (225128) THEN 1
      ELSE 0
    END AS dialysis_active,
    NULL AS dialysis_type
  FROM mimiciv_icu.datetimeevents dte
  LEFT JOIN mimiciv_icu.d_items di ON dte.itemid = di.itemid
  WHERE dte.itemid IN
  (
    225128, -- Last dialysis
    225318, -- Dialysis Catheter Cap Change
    225319, -- Dialysis Catheter Change over Wire Date
    225321, -- Dialysis Catheter Dressing Change
    225322, -- Dialysis Catheter Insertion Date
    225324  -- Dialysis Catheter Tubing Change
  )
),
mv_ranges AS
(
  SELECT
    hadm_id, stay_id, starttime, endtime, itemid,
    amount::character AS value,
    1 AS dialysis_present,
    1 AS dialysis_active,
    'CRRT' AS dialysis_type
  FROM mimiciv_icu.inputevents
  WHERE itemid IN (227536, 227525)
  AND amount > 0
  UNION DISTINCT
  SELECT
    hadm_id, stay_id, starttime, endtime, itemid,
    value::character,
    1 AS dialysis_present,
    CASE WHEN itemid NOT IN (224270, 225436) THEN 1 ELSE 0 END AS dialysis_active,
    CASE
      WHEN itemid = 225441 THEN 'IHD'
      WHEN itemid = 225802 THEN 'CRRT'
      WHEN itemid = 225803 THEN 'CVVHD'
      WHEN itemid = 225805 THEN 'Peritoneal'
      WHEN itemid = 225809 THEN 'CVVHDF'
      WHEN itemid = 225955 THEN 'SCUF'
      ELSE NULL
    END AS dialysis_type
  FROM mimiciv_icu.procedureevents
  WHERE itemid IN
  (
    225441, 225802, 225803, 225805,
    224270, 225809, 225955, 225436
  )
  AND value IS NOT NULL
),
stg0 AS
(
  SELECT hadm_id, stay_id, charttime, itemid, value,
         dialysis_present, dialysis_active, dialysis_type
  FROM ce WHERE dialysis_present = 1
  UNION DISTINCT
  SELECT hadm_id, stay_id, starttime AS charttime, itemid, value,
         dialysis_present, dialysis_active, dialysis_type
  FROM mv_ranges
  UNION DISTINCT
  SELECT hadm_id, stay_id, charttime, itemid, value,
         dialysis_present, dialysis_active, dialysis_type
  FROM de WHERE dialysis_present = 1
),
rt AS
(
  SELECT
    stg0.hadm_id, stg0.stay_id, stg0.charttime, stg0.itemid, stg0.value,
    mv.starttime AS procedure_starttime,
    mv.endtime AS procedure_endtime,
    mv.itemid AS procedure_itemid,
    mv.value AS procedure_value,
    GREATEST(mv.dialysis_present, stg0.dialysis_present) AS dialysis_present,
    GREATEST(mv.dialysis_active, stg0.dialysis_active) AS dialysis_active,
    mv.dialysis_type || '+' || stg0.dialysis_type AS dialysis_type
  FROM stg0
  LEFT JOIN mv_ranges mv
    ON stg0.stay_id = mv.stay_id
    AND stg0.charttime >= mv.starttime
    AND stg0.charttime <= mv.endtime
),
rrt AS
(
  SELECT icu.subject_id, rt.*
  FROM rt
  LEFT JOIN mimiciv_icu.icustays icu ON icu.stay_id = rt.stay_id
)
SELECT
  rrt.subject_id, rrt.hadm_id, rrt.stay_id, rrt.charttime, rrt.itemid, di.label,
  rrt.value,
  rrt.procedure_starttime,
  rrt.procedure_endtime,
  rrt.procedure_itemid,
  dit.label AS procedure_label,
  rrt.procedure_value,
  rrt.dialysis_present,
  rrt.dialysis_active,
  rrt.dialysis_type
FROM rrt
LEFT JOIN mimiciv_icu.d_items di ON rrt.itemid = di.itemid
LEFT JOIN mimiciv_icu.d_items dit ON rrt.procedure_itemid = dit.itemid;
