-- 005_phase4_features.sql  (MERGED Phase 4: Michel's SQL + Jolenn's pandas features)
--
-- Builds the final quarterly modeling table per Phase 0's fixed feature set:
--   - Lagged ZHVI momentum (1, 3 and 6 month)
--   - MORTGAGE30US level
--   - MORTGAGE30US rate-of-change, 12-month lag (the lag Phase 3 confirmed)
--   - The rate-of-change x momentum interaction term
--
-- Decisions carried into this merged version (see the Team Merge Handbook):
--   1. The rate-of-change is a PERCENTAGE-POINT difference, rate(t) - rate(t - 12),
--      as in Phase 3 and in Jolenn's pandas features. (The earlier SQL used the
--      relative change rate / rate_lag - 1.)
--   2. The interaction term is mortgage_rate_roc x momentum_3m, as in Jolenn's
--      pandas features: 3 months is one quarter, the horizon the model predicts.
--      (The earlier SQL used 1-month momentum.) Phase 5 can test 1 and 6 months.
--   3. Column names follow Jolenn's feature columns, which her model outputs use:
--      momentum_1m, momentum_3m, momentum_6m, mortgage_rate_level,
--      mortgage_rate_roc, rate_roc_x_momentum.
--   4. Every row with a missing value in ANY of the six features is dropped, not
--      only rows missing momentum_6m or the rate change, so the table never holds
--      NULL features (the pandas matrix asserts zero nulls as well).
--   5. feature_quarter_end is added: the quarter-end date the features were measured
--      at. It equals Jolenn's `month` column, so the two tables can be joined
--      row by row.
--
-- Unlike Phase 3 (Train only, for EDA decisions), this runs across the FULL
-- dataset -- Train, Embargo, and Test all need real feature values for
-- Phase 5 modeling. Building features for Test rows is normal; the leakage
-- rule Phase 0 sets is about not letting Test data inform *decisions* (like
-- the lag choice), not about withholding features from Test rows entirely.
--
-- Leakage discipline carried over from Phase 3: every feature attached to a
-- quarter's label is measured as of the PRECEDING quarter, never the same
-- quarter whose decline is being predicted -- this is what "predict one
-- quarter ahead" actually means at the row level. Rows are dated by their
-- LABEL quarter (quarter), which is the convention behind the Phase 0 row counts;
-- Jolenn's pandas matrix is dated by feature quarter (see Section 4 of the handbook).

-- 1. Monthly ZHVI momentum per county: 1, 3, and 6-month pct change, computed
-- on the full monthly_split table (all three splits), not just Train.
DROP TABLE IF EXISTS county_monthly_momentum;
CREATE TABLE county_monthly_momentum AS
SELECT
    county_fips,
    month,
    date_trunc('quarter', month)::date AS quarter,
    zhvi,
    (zhvi / NULLIF(LAG(zhvi, 1) OVER (PARTITION BY county_fips ORDER BY month), 0)) - 1 AS momentum_1m,
    (zhvi / NULLIF(LAG(zhvi, 3) OVER (PARTITION BY county_fips ORDER BY month), 0)) - 1 AS momentum_3m,
    (zhvi / NULLIF(LAG(zhvi, 6) OVER (PARTITION BY county_fips ORDER BY month), 0)) - 1 AS momentum_6m
FROM monthly_split;

-- 2. Quarter-end snapshot of momentum per county (last observed month in each
-- quarter) -- same DISTINCT ON pattern Phase 3 used for the label itself.
DROP TABLE IF EXISTS county_quarterly_momentum;
CREATE TABLE county_quarterly_momentum AS
SELECT DISTINCT ON (county_fips, quarter)
    county_fips, quarter, momentum_1m, momentum_3m, momentum_6m
FROM county_monthly_momentum
WHERE zhvi IS NOT NULL   -- last month WITH a value, like pandas groupby().last() (skips NaN)
ORDER BY county_fips, quarter, month DESC;

-- 3. National mortgage rate: level + 12-month rate-of-change (percentage points), monthly grain,
-- across the full dataset (extends Phase 3's Train-only version).
DROP TABLE IF EXISTS national_monthly_rate_full;
CREATE TABLE national_monthly_rate_full AS
SELECT DISTINCT month, mortgage_rate,
       date_trunc('quarter', month)::date AS quarter
FROM monthly_split
ORDER BY month;

DROP TABLE IF EXISTS national_rate_roc_full;
CREATE TABLE national_rate_roc_full AS
SELECT
    month, quarter, mortgage_rate,
    mortgage_rate - LAG(mortgage_rate, 12) OVER (ORDER BY month) AS rate_roc_12m   -- percentage points
FROM national_monthly_rate_full;

-- 4. Quarter-end snapshot of rate level + rate-of-change.
DROP TABLE IF EXISTS quarter_end_rate_features;
CREATE TABLE quarter_end_rate_features AS
SELECT DISTINCT ON (quarter)
    quarter, mortgage_rate AS rate_level, rate_roc_12m
FROM national_rate_roc_full
ORDER BY quarter, month DESC;

-- 5. Quarterly decline label across the FULL dataset (Phase 3's label logic,
-- generalized from Train-only to all three splits). Quarters align exactly
-- with the Train/Embargo/Test cutoffs (Embargo is a full quarter, Train ends
-- on a quarter boundary), so each quarter's split is unambiguous.
DROP TABLE IF EXISTS quarterly_labeled_full;
CREATE TABLE quarterly_labeled_full AS
WITH q AS (
    SELECT DISTINCT ON (county_fips, quarter)
        county_fips,
        date_trunc('quarter', month)::date AS quarter,
        zhvi,
        split
    FROM monthly_split
    WHERE zhvi IS NOT NULL   -- last month WITH a value, like pandas groupby().last() (skips NaN)
    ORDER BY county_fips, date_trunc('quarter', month)::date, month DESC
)
SELECT
    county_fips,
    quarter,
    split,
    zhvi,
    LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_zhvi,
    LAG(quarter) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_quarter,
    CASE
        WHEN (zhvi / NULLIF(LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter), 0)) - 1 < -0.02
        THEN 1 ELSE 0
    END AS decline_label
FROM q;

-- Also drop rows whose previous available quarter is not the immediately preceding
-- calendar quarter (a gap in a county's series would make the label span two quarters).
DELETE FROM quarterly_labeled_full
WHERE prev_zhvi IS NULL
   OR prev_quarter <> (quarter - INTERVAL '3 months')::date;

-- 6. Final modeling table: label's quarter joined to the PRECEDING quarter's
-- momentum and rate features (quarter + 3 months = label's quarter).
-- CASCADE also drops the cv_fold_rows view (from 003b), which reads this table; re-run 003b afterwards.
DROP TABLE IF EXISTS quarterly_modeling_table CASCADE;
CREATE TABLE quarterly_modeling_table AS
SELECT
    l.county_fips,
    l.quarter,
    (l.quarter - INTERVAL '1 day')::date AS feature_quarter_end,   -- quarter-end the features are measured at
    l.split,
    l.decline_label,
    m.momentum_1m,
    m.momentum_3m,
    m.momentum_6m,
    r.rate_level AS mortgage_rate_level,
    r.rate_roc_12m AS mortgage_rate_roc,
    r.rate_roc_12m * m.momentum_3m AS rate_roc_x_momentum
FROM quarterly_labeled_full l
JOIN county_quarterly_momentum m
    ON m.county_fips = l.county_fips
    AND m.quarter + INTERVAL '3 months' = l.quarter
JOIN quarter_end_rate_features r
    ON r.quarter + INTERVAL '3 months' = l.quarter;

-- 7. Drop rows lacking any feature: the earliest quarters per county/nationally
-- (Phase 0's Data Requirement: at least 2 quarters of prior history for momentum_6m,
-- plus 12 months for the rate change) and any quarter touched by a missing ZHVI month.
DELETE FROM quarterly_modeling_table
WHERE momentum_1m IS NULL OR momentum_3m IS NULL OR momentum_6m IS NULL
   OR mortgage_rate_level IS NULL OR mortgage_rate_roc IS NULL OR rate_roc_x_momentum IS NULL;

-- Row-count check per split -- compare against Phase 0's documented quarterly
-- provenance figures (Train 173,824 / Embargo 3,021 / Test 52,087) and Jolenn's
-- Train feature matrix (164,460 rows, 3,009 counties, 4.85% positive). Expect fewer
-- rows than Phase 0, because this table also drops early-history rows.
SELECT split, COUNT(1) AS n_rows, COUNT(DISTINCT county_fips) AS n_counties,
       ROUND(100.0 * AVG(decline_label), 2) AS positive_rate_pct
FROM quarterly_modeling_table
GROUP BY split
ORDER BY split;
