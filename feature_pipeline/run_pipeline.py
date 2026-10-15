# -*- coding: utf-8 -*-
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
import argparse
import glob
import json
import os
import re

import pandas as pd
from sqlalchemy import create_engine, text

HERE = os.path.dirname(os.path.abspath(__file__))


def get_conn():
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


EXPORT_VIEWS = [
    "akd_v2_cohort", "akd_v2_ts_long", "akd_v2_o2", "akd_v2_static",
    "akd_v2_vaso", "akd_v2_vent", "akd_v2_diag",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, choices=["A", "B"])
    args = ap.parse_args()
    win = {"A": ("-24 hours", "0 hours"), "B": ("-12 hours", "24 hours")}[args.plan]
    outdir = os.path.join(HERE, f"export_{args.plan}")
    os.makedirs(outdir, exist_ok=True)

    sql = open(os.path.join(HERE, "01_cohort_features.sql"), encoding="utf-8").read()
    # 去掉 psql 专用 meta 命令(\set / \echo)
    lines = [ln for ln in sql.splitlines()
             if not ln.strip().startswith("\\")]
    sql_body = "\n".join(lines)
    # 替换 psql 变量占位符 :'win_lo' / :'win_hi' 为字面量
    sql_body = sql_body.replace(":'win_lo'", f"'{win[0]}'")
    sql_body = sql_body.replace(":'win_hi'", f"'{win[1]}'")
    # 末尾的汇总 SELECT 会返回结果集, 拆出单独执行
    marker = "SELECT\n    (SELECT COUNT(*) FROM mimiciv_derived.akd_v2_cohort)"
    idx = sql_body.find(marker)
    ddl = sql_body[:idx] if idx > 0 else sql_body
    summary = sql_body[idx:] if idx > 0 else None

    eng = create_engine(get_conn())
    print(f">>> [plan {args.plan}] win={win}  执行 01 DDL ...")
    with eng.begin() as cx:
        cx.execute(text(ddl))
    print(">>> DDL 完成. 汇总:")
    if summary:
        with eng.connect() as cx:
            row = cx.execute(text(summary.rstrip().rstrip(";"))).fetchone()
            print("   ", dict(row._mapping))

    print(">>> 导出 CSV ...")
    with eng.connect() as cx:
        for v in EXPORT_VIEWS:
            df = pd.read_sql(text(f"SELECT * FROM mimiciv_derived.{v}"), cx)
            p = os.path.join(outdir, f"{v}.csv")
            df.to_csv(p, index=False)
            print(f"    {v}: {df.shape} -> {p}")
    print(">>> 完成 plan", args.plan)


if __name__ == "__main__":
    main()
