-- Export hourly feature CSVs (plan B_ext, 37 steps).
-- Run with psql from THIS directory; CSVs land in ./export_B_ext/.
-- mkdir export_B_ext first (psql \copy will not create directories).
\copy (SELECT * FROM mimiciv_derived.akd_v3_cohort) TO 'export_B_ext/cohort.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_ts_long) TO 'export_B_ext/ts_long.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_o2) TO 'export_B_ext/o2.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_vaso) TO 'export_B_ext/vaso.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_vent) TO 'export_B_ext/vent.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_static) TO 'export_B_ext/static.csv' CSV HEADER
\copy (SELECT * FROM mimiciv_derived.akd_v3_diag) TO 'export_B_ext/diag.csv' CSV HEADER
