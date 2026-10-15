# -*- coding: utf-8 -*-
"""Sanitize run_pipeline.py for publication:
- remove the hard-coded local root path + notebook-scraping connection hack
- require an explicit PGURL env var instead (no credentials in code)
"""
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

P = r"D:\research\akd prediction\akd_prediction_code\feature_pipeline\run_pipeline.py"
src = open(P, encoding="utf-8").read()

old_fn = src[src.index("def get_conn():"):src.index("EXPORT_VIEWS")]
new_fn = '''def get_conn():
    """Read the SQLAlchemy connection URL from the PGURL environment variable.

    Example (never hard-code credentials in this file):
        set PGURL=postgresql://user:password@localhost:5432/postgres   # Windows
        export PGURL=postgresql://user:password@localhost:5432/postgres # Linux
    """
    url = os.environ.get("PGURL", "").strip()
    if not url:
        raise RuntimeError(
            "Set the PGURL environment variable to your SQLAlchemy connection URL, "
            "e.g. postgresql://user:password@host:5432/dbname"
        )
    return url


'''
assert old_fn.startswith("def get_conn():") and "RuntimeError" in old_fn
src2 = src.replace(old_fn, new_fn)
assert 'D:\\documents\\anacondafiles' not in src2, "local path still present"
assert src2 != src

# docstring: the notebook-scraping description is no longer true; rewrite header
head_old = src2[:src2.index("import argparse")]
head_new = '''# -*- coding: utf-8 -*-
"""
run_pipeline.py -- export the hourly feature CSVs for one time-window plan.

Runs the 01_cohort_features SQL (parameterized window) against PostgreSQL and
writes one CSV per view into export_<plan>/. Nothing is printed or persisted
beyond the CSV exports.

Usage:
  set PGURL=postgresql://user:password@localhost:5432/postgres
  python run_pipeline.py --plan A   # win_lo=-24h win_hi=0h   -> export_A
  python run_pipeline.py --plan B   # win_lo=-12h win_hi=24h  -> export_B
"""
'''
src3 = head_new + src2[src2.index("import argparse"):]
open(P, "w", encoding="utf-8", newline="\n").write(src3)

import ast
ast.parse(src3)
print("sanitized; local path gone:", 'D:\\documents' not in src3, "| parses ok")
