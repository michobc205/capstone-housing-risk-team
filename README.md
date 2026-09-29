# County-Level Housing Price Decline Prediction — Team Repo

Neuefische Data Science Bootcamp — Capstone Project (Team Merge)

Merges two independently-built pipelines — a pandas-based approach and a
SQL/Postgres-based approach — into a single shared codebase, comparing
methodology and combining the best of both along the way.

## Business Question

> "Can we predict, one quarter ahead, which US counties will see a housing
> price decline greater than 2%, and how much predictive power does
> mortgage-rate movement (30-year fixed rate level and rate-of-change) add
> once a county's own price momentum is already known?"

## Data Sources

| Source | Grain | What it provides |
|---|---|---|
| Zillow ZHVI (Middle Tier, 33rd-67th percentile, SFR + Condo/Co-op, Smoothed & Seasonally Adjusted) | County, monthly | Home value index — builds the price-decline label and momentum features |
| FRED `MORTGAGE30US` | National, weekly (resampled to monthly via `.mean()`) | 30-year fixed mortgage rate — builds rate level, rate-of-change, and interaction features |

## Project Structure

```
data/         raw and processed data (not tracked in git)
notebooks/    merged, phase-by-phase notebooks
sql/          SQL schema and query files backing the notebooks
outputs/      exported charts and persisted results (JSON, CSV, PNG)
docs/         business framing and team reference documentation
```

## Merge Workflow

This repo combines two independently-built capstone pipelines:

- **[capstone-housing-risk-postgres-variant](https://github.com/michobc205/capstone-housing-risk-postgres-variant)** — Michel's SQL/Postgres-based approach, doing transformations (splitting, EDA, feature engineering) directly in Postgres via SQL rather than pandas
- **Housing Price Decline** — Jolenn's pandas-based approach, using Python/pandas for transformations with Postgres as storage only

Each phase is merged by comparing both independent implementations, resolving any methodology differences, and combining them into a single version carried forward here. Decisions made along the way are documented directly in the relevant notebook's markdown cells, not hidden in commit messages.

### Phase 1 — Ingest, Join, and Coverage Audit ✅ Complete

**Notebook:** `notebooks/01_phase1_ingest_merged.ipynb`
**SQL:** `sql/001_schema.sql`, `sql/002_join_check.sql`, `sql/phase1_validation.sql`

Merges both repos' Zillow ZHVI + FRED `MORTGAGE30US` ingest pipelines. Key decisions:

- **Zillow NaN handling:** adopts the pandas repo's approach — trims each county to its own reporting window but keeps genuine *internal* gaps as NULL rows, rather than silently dropping them
- **Month storage convention:** adopts month-end dates (Zillow's native format), removing the need for a `date_trunc`-based join
- **The join itself stays in SQL** (the Postgres-variant's differentiator), now simplified to a plain equality join since both tables share one date convention

**Validated two independent ways:** once via the notebook's own pandas-based provenance check, and again via `sql/phase1_validation.sql`'s pure-SQL recomputation — both agree, and both match the project's documented baseline figures (Test window: 52,087 rows, 8.15% positive rate, exact match).

### Phases 2-7 — Not yet started

Split/CV, EDA, feature engineering, modeling, evaluation, and the communication dashboard are still to be merged.

## Setup

This project uses a plain Python virtual environment (no Anaconda required):

```
python -m venv .venv
source .venv/bin/activate        # Mac/Linux
source .venv/Scripts/activate    # Windows (Git Bash)
pip install -r requirements.txt
```

Create a `.env` file in the project root (never committed — see `.gitignore`) with:

```
PGHOST=localhost
PGPORT=5432
PGDATABASE=housing_risk_team
PGUSER=postgres
PGPASSWORD=your_password_here
```

Apply the schema once, before running any notebook:

```
psql -U postgres housing_risk_team -f sql/001_schema.sql
```

Then run the notebooks in order: `01` → `02` → ...

## Collaboration

Built by merging two independently-attempted personal repos into this shared
one, phase by phase — each phase is compared, methodology differences are
resolved and documented, and the combined version is carried forward here.

- **Michel Mghames** — [capstone-housing-risk-postgres-variant](https://github.com/michobc205/capstone-housing-risk-postgres-variant)
- **Jolenn Darensbourg** — Housing Price Decline (pandas-based repo)

## License

MIT — see [LICENSE](LICENSE).
