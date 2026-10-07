"""
Export the summary tables the dashboard needs.

Run from the repo root (or from notebooks/) after notebooks 05 and 06:

    python notebooks/07b_export_dashboard_data.py

What it does
  1. Builds five small overview tables from quarterly_modeling_table and cv_fold_rows
     (dash_*) and saves them in Postgres.
  2. Writes every table the dashboard reads to docs/dashboard_data/*.csv, plus
     snapshot_info.json, so the dashboard also runs without a database.

Only aggregated results are exported. A check stops the script if any exported table
holds county-level rows, so no Zillow data can leak into the public repository.
"""
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from dotenv import find_dotenv, load_dotenv
from sqlalchemy import create_engine, text

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent if HERE.name == "notebooks" else HERE
OUT_DIR = ROOT / "docs" / "dashboard_data"

FEATURES_RATE = ["mortgage_rate_level", "mortgage_rate_roc"]

PHASE_TABLES = [
    "phase5_fold_scores", "phase5_step_summary", "phase5_bootstrap_deltas",
    "phase6_test_scores", "phase6_test_deltas", "phase6_family_deltas", "phase6_thresholds",
    "phase6_decision_rules", "phase6_calibration", "phase6_calibration_all",
    "phase6_per_quarter", "phase6_range_check", "phase6_eval_summary",
]
FORBIDDEN_COLUMNS = {"county_fips", "region_name", "zhvi"}


def build_dash_tables(engine):
    """The five overview tables, computed from the modeling table and the fold view."""
    split_summary = pd.read_sql(
        "SELECT split, COUNT(*) AS n_rows, COUNT(DISTINCT county_fips) AS n_counties, "
        "SUM(decline_label) AS n_declines, AVG(decline_label) AS decline_rate "
        "FROM quarterly_modeling_table GROUP BY split ORDER BY split", engine)

    quarterly = pd.read_sql(
        "SELECT quarter, split, COUNT(*) AS n_rows, SUM(decline_label) AS n_declines, "
        "AVG(decline_label) AS decline_rate, AVG(mortgage_rate_level) AS mortgage_rate_level, "
        "AVG(mortgage_rate_roc) AS mortgage_rate_roc "
        "FROM quarterly_modeling_table GROUP BY quarter, split ORDER BY quarter", engine)

    fr = pd.read_sql("SELECT fold_id, fold_role, county_fips, decline_label, mortgage_rate_level, mortgage_rate_roc "
                     "FROM cv_fold_rows", engine)
    tr, va = fr[fr["fold_role"] == "train"], fr[fr["fold_role"] == "val"]
    fold_overview = pd.DataFrame({
        "train_rows": tr.groupby("fold_id").size(),
        "train_declines": tr.groupby("fold_id")["decline_label"].sum(),
        "val_rows": va.groupby("fold_id").size(),
        "val_declines": va.groupby("fold_id")["decline_label"].sum()}).reset_index()
    fold_overview["val_rate_pct"] = 100 * fold_overview["val_declines"] / fold_overview["val_rows"]

    rows = []
    for f in sorted(fr["fold_id"].unique()):
        t, v = tr[tr["fold_id"] == f], va[va["fold_id"] == f]
        row = {"fold_id": int(f)}
        for feat in FEATURES_RATE:
            lo, hi = t[feat].min(), t[feat].max()
            row[f"{feat}_pct_outside"] = float(100 * ((v[feat] < lo) | (v[feat] > hi)).mean())
        rows.append(row)
    fold_range = pd.DataFrame(rows)

    mt = pd.read_sql("SELECT quarter, split, mortgage_rate_level, mortgage_rate_roc FROM quarterly_modeling_table "
                     "WHERE split IN ('train', 'test')", engine)
    train = mt[mt["split"] == "train"]
    test = mt[mt["split"] == "test"].copy()
    for feat in FEATURES_RATE:
        lo, hi = train[feat].min(), train[feat].max()
        test[feat + "_out"] = ((test[feat] < lo) | (test[feat] > hi)).astype(float)
    test_range = (test.groupby("quarter")[[f + "_out" for f in FEATURES_RATE]].mean().mul(100).reset_index()
                  .rename(columns={"mortgage_rate_level_out": "mortgage_rate_level_pct_outside",
                                   "mortgage_rate_roc_out": "mortgage_rate_roc_pct_outside"}))

    return {"dash_split_summary": split_summary, "dash_quarterly_rate": quarterly,
            "dash_fold_overview": fold_overview, "dash_fold_range_check": fold_range,
            "dash_test_range_by_quarter": test_range}


def export(engine, out_dir=OUT_DIR, write_db=True):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    dash = build_dash_tables(engine)
    if write_db:
        for name, df in dash.items():
            df.to_sql(name, engine, if_exists="replace", index=False)

    tables = {name: pd.read_sql(f"SELECT * FROM {name}", engine) for name in PHASE_TABLES}
    tables.update(dash)

    for name, df in tables.items():
        bad = FORBIDDEN_COLUMNS & set(df.columns)
        assert not bad, f"STOP: {name} has county-level columns {bad}. Aggregated tables only."
        assert len(df) < 5000, f"STOP: {name} has {len(df):,} rows, which is not a summary table."
        df.to_csv(out_dir / f"{name}.csv", index=False)

    info = {"created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
            "tables": {name: int(len(df)) for name, df in tables.items()},
            "note": "Aggregated results only. No county-level rows."}
    (out_dir / "snapshot_info.json").write_text(json.dumps(info, indent=2), encoding="utf-8")
    total = sum(p.stat().st_size for p in out_dir.glob("*"))
    return info, total


def main():
    load_dotenv(find_dotenv(usecwd=True), override=True)
    user = os.environ.get("PGUSER", "postgres")
    pwd = os.environ.get("PGPASSWORD", "")
    host = os.environ.get("PGHOST", "localhost")
    port = os.environ.get("PGPORT", "5432")
    name = os.environ.get("PGDATABASE", "housing_risk_team")
    engine = create_engine(f"postgresql+psycopg2://{user}:{pwd}@{host}:{port}/{name}")
    with engine.connect() as conn:
        print("Database:", conn.execute(text("SELECT current_database();")).scalar())
    info, total = export(engine)
    print(f"Exported {len(info['tables'])} tables to {OUT_DIR} ({total / 1024:.0f} KB in total)")
    for t, n in info["tables"].items():
        print(f"  {t:30s} {n:>6,} rows")
    print("No exported table holds county-level rows.")


if __name__ == "__main__":
    main()
