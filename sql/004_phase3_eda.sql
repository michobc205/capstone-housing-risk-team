-- 004_phase3_eda.sql  (MERGED Phase 3: Michel's SQL + Jolenn's pandas EDA)
--
-- Quarterly decline label, lag-correlation sweep and reverse-causation check,
-- computed in SQL. The label and lag sweep run entirely on train_monthly (from
-- 003_phase2_split.sql) -- never on embargo_monthly or test_monthly, per
-- Phase 0's rule against Test-set leakage into EDA decisions.
--
-- Decisions carried into this merged version (see the Team Merge Handbook):
--   1. Rate-of-change is a PERCENTAGE-POINT difference, rate(t) - rate(t - lag),
--      as in Jolenn's pandas EDA. (The earlier SQL version used the relative
--      change rate / rate_lag - 1.)
--   2. Main alignment is the PRECEDING quarter: each label is paired with the
--      rate-of-change measured at the end of the quarter BEFORE it, which is
--      what "predict one quarter ahead" means. Jolenn's EDA paired the label
--      with the rate-of-change ending in the SAME quarter; that version is kept
--      here as a second alignment purely for comparison.
--   3. The label is a decline strictly greater than 2% (pct_change < -0.02).
--   4. Each county-quarter uses the county's last month WITH a ZHVI value, and a
--      label is dropped when the previous available quarter is not the calendar
--      quarter right before it.

-- 1. Quarterly ZHVI per county: last month that has a value in each quarter.
DROP TABLE IF EXISTS train_quarterly CASCADE;
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
DROP TABLE IF EXISTS train_quarterly_labeled CASCADE;
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

-- Drop the first quarter per county (no previous quarter to compare against), and
-- any row whose previous available quarter is not the calendar quarter before it.
DELETE FROM train_quarterly_labeled
WHERE prev_zhvi IS NULL
   OR prev_quarter <> (quarter - INTERVAL '3 months')::date;

-- 3. National monthly mortgage rate series (one row per month -- the rate is
-- identical across all counties in a given month, so DISTINCT collapses it).
DROP TABLE IF EXISTS national_monthly_rate CASCADE;
CREATE TABLE national_monthly_rate AS
SELECT DISTINCT month, mortgage_rate
FROM train_monthly
ORDER BY month;

-- 4. Rate-of-change at each candidate lag: PERCENTAGE-POINT difference.
-- (Column names keep the roc_<n>m form; the values are now rate - rate_lag.)
DROP TABLE IF EXISTS national_rate_roc CASCADE;
CREATE TABLE national_rate_roc AS
SELECT
    month,
    date_trunc('quarter', month)::date AS quarter,
    mortgage_rate,
    mortgage_rate - LAG(mortgage_rate, 1)  OVER (ORDER BY month) AS roc_1m,
    mortgage_rate - LAG(mortgage_rate, 2)  OVER (ORDER BY month) AS roc_2m,
    mortgage_rate - LAG(mortgage_rate, 3)  OVER (ORDER BY month) AS roc_3m,
    mortgage_rate - LAG(mortgage_rate, 6)  OVER (ORDER BY month) AS roc_6m,
    mortgage_rate - LAG(mortgage_rate, 9)  OVER (ORDER BY month) AS roc_9m,
    mortgage_rate - LAG(mortgage_rate, 12) OVER (ORDER BY month) AS roc_12m
FROM national_monthly_rate;

-- 5. Last month's rate-of-change values per quarter (quarter-end snapshot).
DROP TABLE IF EXISTS quarter_end_rates CASCADE;
CREATE TABLE quarter_end_rates AS
SELECT DISTINCT ON (quarter)
    quarter, roc_1m, roc_2m, roc_3m, roc_6m, roc_9m, roc_12m
FROM national_rate_roc
ORDER BY quarter, month DESC;

-- 6. Label + rate-of-change pairs, under two alignments.
--    'preceding quarter (used)': label quarter t is paired with the snapshot at the
--        end of quarter t-1 (information available one quarter ahead).
--    'same quarter (Jolenn EDA)': label quarter t is paired with the snapshot at the
--        end of quarter t itself (for comparison with the pandas EDA only).
DROP TABLE IF EXISTS lag_correlation_input CASCADE;
CREATE TABLE lag_correlation_input AS
SELECT
    'preceding quarter (used)'::text AS alignment,
    t.county_fips, t.quarter, t.decline_label,
    q.roc_1m, q.roc_2m, q.roc_3m, q.roc_6m, q.roc_9m, q.roc_12m
FROM train_quarterly_labeled t
JOIN quarter_end_rates q
    ON q.quarter + INTERVAL '3 months' = t.quarter
UNION ALL
SELECT
    'same quarter (Jolenn EDA)'::text AS alignment,
    t.county_fips, t.quarter, t.decline_label,
    q.roc_1m, q.roc_2m, q.roc_3m, q.roc_6m, q.roc_9m, q.roc_12m
FROM train_quarterly_labeled t
JOIN quarter_end_rates q
    ON q.quarter = t.quarter;

-- 7. Correlation of decline_label with each lag's rate-of-change, per alignment,
-- in long format (one row per alignment and lag) so the notebook can add p-values
-- and confidence intervals. corr() skips rows where either side is NULL, and
-- n_rows counts the rows that were actually usable.
DROP TABLE IF EXISTS lag_correlation_results CASCADE;
CREATE TABLE lag_correlation_results AS
SELECT
    a.alignment,
    v.lag_months,
    corr(a.decline_label, v.roc) AS correlation,
    COUNT(v.roc) AS n_rows
FROM lag_correlation_input a
CROSS JOIN LATERAL (VALUES
    (1, a.roc_1m), (2, a.roc_2m), (3, a.roc_3m),
    (6, a.roc_6m), (9, a.roc_9m), (12, a.roc_12m)
) AS v(lag_months, roc)
GROUP BY a.alignment, v.lag_months;

-- 8. Reverse-causation check: does national price momentum lead future
-- mortgage-rate changes? Mirrors Jolenn's notebook 11.
--   national momentum(t) = 3-month change of the MEDIAN county ZHVI (Train months only)
--   rate change(t+k)     = 1-month percentage-point change of the mortgage rate at t+k
--   correlation over t, for forward lags k = 1 .. 18.
-- Variant A uses the full mortgage_monthly history (as Jolenn's notebook does), which
-- reaches rate months after the Train window for the latest t. Variant B only uses rate
-- months up to the end of Train, so no Embargo/Test-period rate enters the check.
DROP TABLE IF EXISTS reverse_causation_sweep CASCADE;
CREATE TABLE reverse_causation_sweep AS
WITH zm AS (
    SELECT month, percentile_cont(0.5) WITHIN GROUP (ORDER BY zhvi) AS national_zhvi
    FROM train_monthly
    GROUP BY month
),
mom AS (
    SELECT month,
           national_zhvi / NULLIF(LAG(national_zhvi, 3) OVER (ORDER BY month), 0) - 1 AS mom3
    FROM zm
),
rr AS (
    SELECT month,
           mortgage_rate - LAG(mortgage_rate, 1) OVER (ORDER BY month) AS roc1
    FROM mortgage_monthly
),
v(variant, cutoff) AS (
    VALUES ('A full rate history (as Jolenn)', DATE '9999-12-31'),
           ('B rates through train end only', (SELECT MAX(month) FROM train_monthly))
)
SELECT
    v.variant,
    k.lag_months,
    corr(m.mom3, f.roc1) AS correlation,
    COUNT(1) FILTER (WHERE m.mom3 IS NOT NULL AND f.roc1 IS NOT NULL) AS n_rows
FROM v
CROSS JOIN generate_series(1, 18) AS k(lag_months)
CROSS JOIN mom m
JOIN rr f
    ON f.month = (date_trunc('month', m.month)
                  + make_interval(months => k.lag_months + 1) - INTERVAL '1 day')::date
   AND f.month <= v.cutoff
GROUP BY v.variant, k.lag_months;

-- Results for DBeaver (the notebook reads the same tables back).
SELECT alignment, lag_months, correlation, n_rows
FROM lag_correlation_results
ORDER BY alignment, lag_months;

SELECT variant, lag_months, correlation, n_rows
FROM reverse_causation_sweep
ORDER BY variant, lag_months;
