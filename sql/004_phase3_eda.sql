-- 004_phase3_eda.sql
--
-- SQL version of Phase 3's quarterly decline-label build and lag-correlation
-- analysis. Runs entirely on train_monthly (from 003_phase2_split.sql) --
-- never touches embargo_monthly or test_monthly, per Phase 0's rule against
-- Test-set leakage into EDA decisions.
--
-- Two genuine methodology differences from the pandas version:
--   1. The quarterly label uses DISTINCT ON + LAG() window functions instead
--      of groupby().last() + pct_change().
--   2. The lag-correlation search uses Postgres's corr() aggregate directly,
--      computed once per candidate lag in a single query, instead of pandas
--      .corr() calls on merged DataFrames.

-- 1. Quarterly ZHVI per county: last observed month's value in each quarter.
DROP TABLE IF EXISTS train_quarterly;
CREATE TABLE train_quarterly AS
SELECT DISTINCT ON (county_fips, quarter)
    county_fips,
    date_trunc('quarter', month)::date AS quarter,
    zhvi,
    mortgage_rate
FROM train_monthly
WHERE zhvi IS NOT NULL   -- last month WITH a value, like pandas groupby().last() (skips NaN)
ORDER BY county_fips, quarter, month DESC;

-- 2. Quarter-over-quarter percent change and decline label, via LAG().
DROP TABLE IF EXISTS train_quarterly_labeled;
CREATE TABLE train_quarterly_labeled AS
SELECT
    county_fips,
    quarter,
    zhvi,
    mortgage_rate,
    LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_zhvi,
    LAG(quarter) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_quarter,
    (zhvi / NULLIF(LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter), 0)) - 1 AS pct_change,
    CASE
        WHEN (zhvi / NULLIF(LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter), 0)) - 1 < -0.02
        THEN 1 ELSE 0
    END AS decline_label
FROM train_quarterly;

-- Drop the first quarter per county (no prev_zhvi to compare against) --
-- mirrors the pandas pipeline's .dropna(subset=["pct_change"]). Also drop rows whose
-- previous available quarter is not the immediately preceding calendar quarter
-- (a gap in a county's series would otherwise make pct_change span two quarters).
DELETE FROM train_quarterly_labeled
WHERE prev_zhvi IS NULL
   OR prev_quarter <> (quarter - INTERVAL '3 months')::date;

-- 3. National monthly mortgage rate series (one row per month -- the rate is
-- identical across all counties in a given month, so DISTINCT collapses it).
DROP TABLE IF EXISTS national_monthly_rate;
CREATE TABLE national_monthly_rate AS
SELECT DISTINCT month, mortgage_rate
FROM train_monthly
ORDER BY month;

-- 4. Rate-of-change at each candidate lag, via LAG() over the monthly series.
DROP TABLE IF EXISTS national_rate_roc;
CREATE TABLE national_rate_roc AS
SELECT
    month,
    date_trunc('quarter', month)::date AS quarter,
    mortgage_rate,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 1) OVER (ORDER BY month), 0)) - 1 AS roc_1m,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 2) OVER (ORDER BY month), 0)) - 1 AS roc_2m,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 3) OVER (ORDER BY month), 0)) - 1 AS roc_3m,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 6) OVER (ORDER BY month), 0)) - 1 AS roc_6m,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 9) OVER (ORDER BY month), 0)) - 1 AS roc_9m,
    (mortgage_rate / NULLIF(LAG(mortgage_rate, 12) OVER (ORDER BY month), 0)) - 1 AS roc_12m
FROM national_monthly_rate;

-- 5. Last month's rate-of-change values per quarter (quarter-end snapshot).
DROP TABLE IF EXISTS quarter_end_rates;
CREATE TABLE quarter_end_rates AS
SELECT DISTINCT ON (quarter)
    quarter, roc_1m, roc_2m, roc_3m, roc_6m, roc_9m, roc_12m
FROM national_rate_roc
ORDER BY quarter, month DESC;

-- 6. Match each label's quarter to the PRECEDING quarter's rate-of-change --
-- the information actually available at prediction time (mirrors the pandas
-- version's next_quarter = quarter + 3 months, then merged on that).
DROP TABLE IF EXISTS lag_correlation_input;
CREATE TABLE lag_correlation_input AS
SELECT
    t.county_fips,
    t.quarter,
    t.decline_label,
    q.roc_1m, q.roc_2m, q.roc_3m, q.roc_6m, q.roc_9m, q.roc_12m
FROM train_quarterly_labeled t
JOIN quarter_end_rates q
    ON q.quarter + INTERVAL '3 months' = t.quarter;

-- 7. Correlation of decline_label with each lag's rate-of-change, computed
-- server-side via corr() -- one row, one column per lag. Read back separately
-- by the notebook (not part of the exec loop, since it's a SELECT, not DDL/DML).
SELECT
    corr(decline_label, roc_1m)  AS corr_1m,
    corr(decline_label, roc_2m)  AS corr_2m,
    corr(decline_label, roc_3m)  AS corr_3m,
    corr(decline_label, roc_6m)  AS corr_6m,
    corr(decline_label, roc_9m)  AS corr_9m,
    corr(decline_label, roc_12m) AS corr_12m
FROM lag_correlation_input;
