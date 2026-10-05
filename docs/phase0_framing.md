# Phase 0 — Framing

## Business Question

> "Can we predict, one quarter ahead, which US counties will see a housing price decline greater than 2%, and how much predictive power does mortgage-rate movement (30-year fixed rate level and rate-of-change) add once a county's own price momentum is already known?"

The phrase "once a county's own price momentum is already known" is deliberate. Mortgage-rate movement and price momentum are not independent — rate changes influence price trends partly by moving through momentum itself. Asking "how much is explained by rate versus momentum" would understate rate's actual role, since some of rate's effect would already be hiding inside momentum. Asking what rate adds *on top of* momentum instead measures a well-defined, honestly reportable quantity: momentum's contribution is established first, then rate's marginal contribution is measured against that established baseline.

## Field Scope

The features in use are limited to:

- Lagged ZHVI momentum (1, 3, and 6-month)
- `MORTGAGE30US` level
- `MORTGAGE30US` rate-of-change
- The rate-of-change × prior-momentum interaction term

No other Zillow or FRED series, and no additional data sources, are part of this question's scope. This is written down explicitly so the feature set stays fixed rather than drifting during implementation.

## Data Provenance

The positive-rate figures used throughout this project come from a direct computation against the downloaded Zillow ZHVI file, not an estimate or an assumption. Method: county-level ZHVI, resampled to quarter-end (last observed value per quarter), full available history (January 2000 through August 2026), positive label defined as a quarter-over-quarter decline greater than 2%. Rows, not monthly values, quarterly grain throughout. No model scores are involved in these figures — they're computed from labels only.

| Window | Positive rate | Rows |
|---|---|---|
| Full history | 5.59% | 228,932 |
| Train (through 2021-09-30) | 4.96% | 173,824 |
| Embargoed (2021-10-01 to 2021-12-31, excluded from both train and test) | 0.99% | 3,021 |
| Test (2022-01-01 to 2026-03-31) | 8.15% | 52,087 |

The test window's positive rate (8.15%) is meaningfully higher than the training window's (4.96%) — the elevated test rate is driven by 2022, 2023, and 2025 specifically. This prevalence shift matters for evaluation: PR-AUC's own baseline shifts with class prevalence, so any PR-AUC result should be interpreted against the test window's own 8.15% baseline, not the full-history 5.59% figure.

**Note on "Full history" scope.** The Full history row count above (228,932) is the sum of the Train, Embargoed, and Test windows — it is not every row in the downloaded ZHVI file. The raw file extends through August 2026, which adds two more quarters (2026 Q2 and the partial 2026 Q3) beyond the Test window's 2026-03-31 cutoff — 6,142 additional county-quarter rows. Those quarters are excluded for the same reason Test stops where it does: predicting a quarter's decline requires a fully realized next quarter to label against, and 2026 Q3 isn't complete yet (through August only, no September). As more months land, these quarters become eligible for a future test-window extension, not a correction to the current figures.

**Merged pipeline: label rule and updated figures.** The table above is the original Phase 0 record and is kept as it was. It comes from the earlier method, which took the last observed value per quarter. The merged pipeline requires **both quarter-end months** (March, June, September, December) to have a ZHVI value, the same rule as the pandas labels, so every label is a true quarter-to-quarter change. It gives:

| Window | Positive rate | Rows | Phase 0 rows |
|---|---|---|---|
| Train (through 2021-09-30) | 4.88% | 173,277 | 173,824 |
| Embargoed (2021-10-01 to 2021-12-31) | 0.96% | 3,020 | 3,021 |
| Test (2022-01-01 to 2026-03-31) | 8.15% | 52,085 | 52,087 |

The Train count is 547 lower (positive rate 4.88% instead of 4.96%) for two reasons. First, 91 counties each have one quarter with all three months empty. The earlier method kept the quarter after it, whose change spans six months, and the merged pipeline drops it (90 rows in Train, 1 in the Embargo window). Second, 457 Train rows had an empty quarter-end month but a value in an earlier month of the same quarter. The earlier method used that earlier month, so the label could span four to five months, and the merged pipeline drops those rows. Test is 2 rows lower for the second reason. The 173,277 Train rows are exactly Jolenn's pandas label count.

Full history in the merged pipeline is 231,453 rows (5.55%): Train, Embargoed and Test (228,382) plus 3,071 rows for 2026-Q2. The partial 2026-Q3 gives no rows any more, because its quarter-end month (September) is not published yet.

## Evaluation Metric

**ROC-AUC** is the primary metric at every modeling step, chosen because the three-step comparison method depends on a threshold-free metric to produce clean, comparable increments.

**PR-AUC** is reported alongside as a required secondary metric, not an optional addition, since the test window's positive rate (8.15%, see Data Provenance above) means ROC-AUC alone can look stronger than it deserves to — and PR-AUC results must be read against that same 8.15% baseline, not the full-history rate, given the prevalence shift between train and test.

Both metrics are decided here, in Phase 0, rather than left until evaluation time.

## Model Validation Requirements

**Cluster bootstrap (primary uncertainty method).** Confidence intervals on every AUC delta use a cluster bootstrap, resampling whole quarters with replacement rather than individual county-quarter rows. Counties within a single quarter share the same national rate environment and regional market conditions — they are not independent observations of each other. A row-level bootstrap would overcount the amount of independent evidence available and produce artificially narrow confidence intervals.

**Minimum positives per cross-validation fold.** Any time series CV fold used during hyperparameter tuning must contain a minimum number of positive-class examples before its AUC score is used — a fold with too few positives produces an unstable or undefined AUC and can distort model selection. This check must run automatically, since the early years of the training window have naturally lower decline rates.

**Per-window data-quality gates.** Any automated check on the observed positive rate must compare each window (train, test, or a specific year) against that window's own verified rate from the Data Provenance table above, not a single blanket tolerance applied everywhere.

## Success Criteria

| Step | Target | Rationale |
|---|---|---|
| Baseline (momentum only) | To be set from the baseline model's own training/validation result | No target is fixed in advance. The baseline is trained first, scored on training/validation data, and that result becomes the stated target, locked in before the test set is touched. This avoids setting a number that isn't actually grounded in this model's performance |
| + rate level | ROC-AUC ≥ baseline + 0.01 | A small but real, non-trivial lift; smaller is within noise range |
| + rate-of-change/interaction | ROC-AUC ≥ Model 1 + 0.01, or a stated null result | The headline number; a null result is a valid, reportable answer |
| Robustness check | Same ranking of contributions across ≥2 algorithm families | Confirms the finding isn't specific to one algorithm |

Every marginal AUC change is reported with a bootstrap confidence interval; a change whose interval includes zero is described as "no significant marginal contribution," not rounded to a small positive result.

The marginal-lift numbers depend on the order features are added in (momentum first) — they represent what rate contributes *given momentum is already known*, not a claim about rate's overall importance in isolation. This order-dependency is stated explicitly, not left implicit.

## Data Requirement

Each county-quarter row included in modeling needs at least **2 quarters of prior history** for that specific county — the minimum needed to compute the 6-month momentum lag feature.

This is a **per-row** requirement, not a requirement that a county's full history span both the training and test windows: the model pools information across all counties rather than fitting one model per county, so a county doesn't need to appear in both windows to be usable. A county with no rows in the training period is still evaluated at test time, but purely on what the model learned from other counties — a real limitation worth stating in the final write-up, not a reason to exclude such counties outright.

Zero counties should be dropped during the join step, since this pipeline requires no geographic crosswalk — any dropped county indicates an implementation error, not a genuine geography mismatch.

## Train/Test Split (Phase 2, decided here for reference)

- **Train:** through 2021-09-30
- **Embargo:** 2021-10-01 to 2021-12-31 (excluded from both train and test — guards against serial correlation in the rolling-window momentum features near the boundary)
- **Test:** 2022-01-01 through 2026-03-31

This places the entire 2022–23 rate-hiking cycle and its multi-year aftermath inside the test period, while the two earlier hiking cycles (2004–06, 2015–18) remain inside training — so the model is evaluated on a hiking episode it never trained on directly.