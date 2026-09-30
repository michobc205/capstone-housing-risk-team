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
outputs/      exported charts and persisted results (JSON, CSV, PNG); only files named phase* are tracked in git
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

**Result:** the joined table `county_month_joined` (Zillow as the spine, LEFT JOIN to `mortgage_monthly`) holds 709,996 county-months across 3,071 counties, with no rows or counties dropped by the join.

**Aggregation sensitivity:** the weekly-to-monthly FRED resample uses `.mean()` at month-end. A separate check comparing `.mean()` against `.last()` found the two nearly identical in level (correlation 0.9992) but disagreeing on the direction of the month-over-month change in 111 of 665 months, so the choice matters for the rate-of-change feature and is documented here rather than left implicit.

**Validated two independent ways:** once via the notebook's own pandas-based provenance check, and again via `sql/phase1_validation.sql`'s pure-SQL recomputation — both agree, and both match the project's documented baseline figures (Test window: 52,087 rows, 8.15% positive rate, exact match).

### Phase 2 — Chronological Split + CV Folds ✅ Complete

**Notebook:** `notebooks/02_phase2_split_cv.ipynb`
**SQL:** `sql/003_phase2_split.sql`, `sql/003b_cv_fold_membership.sql` (plus `sql/005_phase4_features.sql`, which builds the modeling table the fold view reads)

Merges the SQL variant's single chronological split with the pandas repo's cross-validation folds. Key decisions:

- **Split:** Train through 2021-09-30, one-quarter Embargo (2021-Q4, excluded from both sides), Test 2022-01-01 to 2026-03-31, and anything later is labelled `unassigned` rather than silently dropped
- **CV folds:** the pandas repo's 11 expanding-window folds (validation years 2010-2020, four quarters each) are stored in a `cv_folds` table, all inside the Train window; folds never touch Embargo or Test
- **Fold membership:** the `cv_fold_rows` view assigns each Train county-quarter to each fold as `train` or `val`, converting quarter-start dates to quarter-end to match the fold boundaries
- **NULL ZHVI months:** some counties have missing ZHVI months mid-series, so quarterly snapshots take each county's last month *with a value* (mirroring pandas `groupby().last()`), and labels are dropped where the previous quarter is not the calendar quarter before

**Validated:**

- The split covers all 709,996 rows; the 1,043 rows above the earlier documented monthly counts are exactly the NULL-ZHVI months (1,040 Train, 3 Test)
- Modeling table: Train 165,269 rows (4.92% positive), Embargo 3,020, Test 51,986 (8.11% positive), close to the documented Phase 0 figures
- Every validation fold has at least 71 positives (the minimum required is 20); pooled validation prevalence is about 3.8%
- No Embargo or Test rows appear in any fold
- Reproduced on a second machine (PostgreSQL 15, Jolenn's laptop) with identical modeling-table counts and all 22 fold rows matching

**Open items:** the pandas repo's test set has 48,960 rows against 51,986 here. This is a dating convention, not a county filter: its rows are dated by feature quarter, so it covers 16 label quarters (2022-Q2 to 2026-Q1) against our 17 (2022-Q1 to 2026-Q1). The team still has to choose which convention to carry forward, and to confirm the folds may have no embargo gap.

### Phase 3 — EDA: Lag Sweep and Reverse-Causation Check ✅ Done (reproduction on the second machine pending)

**Notebook:** `notebooks/03_phase3_eda_merged.ipynb`
**SQL:** `sql/004_phase3_eda.sql`
**Results:** `outputs/phase3_lag_correlation.csv`, `outputs/phase3_reverse_causation.csv`

Merges the SQL variant's quarterly label and lag correlation with the pandas repo's EDA (p-values, confidence intervals, reverse-causation check). Key decisions:

- **Rate-of-change in percentage points:** `rate(t) - rate(t - lag)`, as in the pandas repo. The earlier SQL used relative change, which gave a weaker 12-month correlation (-0.034 against -0.050)
- **Preceding-quarter alignment:** each label is paired with the rate change at the end of the quarter before it, which is what predicting one quarter ahead requires. The pandas EDA paired it with the same quarter; that version is kept only to reproduce its numbers
- **Label:** a decline strictly greater than 2%, using each county's last month with a value in a quarter (same missing-month handling as Phase 2)
- **Lag:** 12 months
- **Reverse-causation check in SQL:** two variants, one with the full mortgage-rate history (as in the pandas notebook) and one using only rates up to the end of Train

**Validated:**

- The quarterly label has 173,734 rows (4.93% positive), matching the Phase 1 check exactly
- The SQL reproduces the pandas lag sweep: with the same-quarter setup, every lag is within 0.0004 (12 months: -0.0523 against -0.0521)
- The 12-month lag wins on both alignments; in the one-quarter-ahead version r = -0.0502 (95% CI -0.0550 to -0.0455, n = 169,548). The sign is negative, opposite to the hypothesis, and the effect is small
- Reverse causation: the SQL reproduces the pandas result exactly (14 months, r = 0.2637), but using only rates up to the end of Train roughly halves it (r = 0.12), so it is at most weakly consistent with prices leading rates
- The SQL was tested on synthetic data in a scratch PostgreSQL 16 database against independent pandas versions (agreement to about 1e-16)

**Open items:** reproduce on the second machine, confirm the decisions above with the pandas repo's author, and agree the wording of the reverse-causation result.

### Phases 4-7 — Not yet merged

Feature engineering, modeling, evaluation, and the communication dashboard are still to be merged. `sql/005_phase4_features.sql` is already in the repo as a building block for Phase 2's fold membership, but the side-by-side comparison with the pandas features has not been done. Known differences to settle first: `005` uses relative change for the rate and 1-month momentum in the interaction term, while the pandas features use percentage points and 3-month momentum.

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

For Phase 2, the SQL files must run in this order: `003_phase2_split.sql` → `005_phase4_features.sql` → `003b_cv_fold_membership.sql` (`003b` reads the modeling table `005` builds). `005` drops the `cv_fold_rows` view when it rebuilds the modeling table, so re-run `003b` after every run of `005`. Notebook `02` runs `003` and `003b` and checks their results, but does not run `005`.

For Phase 3, notebook `03_phase3_eda_merged.ipynb` runs `004_phase3_eda.sql` itself. It needs `train_monthly` (built by `003`) and `mortgage_monthly` to exist.

## Collaboration

Built by merging two independently-attempted personal repos into this shared
one, phase by phase — each phase is compared, methodology differences are
resolved and documented, and the combined version is carried forward here.

- **Michel Mghames** — [capstone-housing-risk-postgres-variant](https://github.com/michobc205/capstone-housing-risk-postgres-variant)
- **Jolenn Darensbourg** — Housing Price Decline (pandas-based repo)

## License

MIT — see [LICENSE](LICENSE).
