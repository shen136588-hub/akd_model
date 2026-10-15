# -*- coding: utf-8 -*-
"""Rewrite _export_*_B_ext.sql with relative export paths (run from repo root)."""
import os, io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

ROOT = r"D:\research\akd prediction\akd_prediction_code"
files = {
    "sql/mimic/_export_mimic_B_ext.sql": ("mimiciv_derived", "mimic"),
    "sql/eicu/_export_eicu_B_ext.sql": ("eicu", "eicu"),
    "sql/sicdb/_export_sicdb_B_ext.sql": ("sicdb", "sicdb"),
}
VIEWS = ["cohort", "ts_long", "o2", "vaso", "vent", "static", "diag"]

for rel, (schema, db) in files.items():
    p = os.path.join(ROOT, rel)
    lines = [
        "-- Export hourly feature CSVs (plan B_ext, 37 steps).",
        "-- Run with psql from THIS directory; CSVs land in ./export_B_ext/.",
        "-- mkdir export_B_ext first (psql \\copy will not create directories).",
    ]
    for v in VIEWS:
        lines.append(
            "\\copy (SELECT * FROM %s.akd_v3_%s) TO 'export_B_ext/%s.csv' CSV HEADER"
            % (schema, v, v)
        )
    body = "\n".join(lines) + "\n"
    open(p, "w", encoding="utf-8", newline="\n").write(body)
    print("rewrote", rel, len(lines) - 3, "exports")
