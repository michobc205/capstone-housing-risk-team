-- phase1_validation.sql
--
-- Run this after executing 01_phase1_ingest_merged.ipynb top to bottom,
-- against the same housing_risk_team database. Hard checks (RAISE
-- EXCEPTION) are invariants that must never fail regardless of when Zillow
-- or FRED last updated their files; soft checks (RAISE NOTICE) report
-- figures that will drift slightly over time as new months are published,
-- so they're printed for review rather than asserted exactly.
--
-- Usage:
--   psql "$DATABASE_URL" -f phase1_validation.sql
-- or paste directly into DBeaver's SQL editor against housing_risk_team.

-- =====================================================================
-- 1. Row counts and county counts (SOFT -- drift expected month to month)
-- =====================================================================
DO $$
DECLARE
    zhvi_rows       INT;
    zhvi_counties   INT;
    mortgage_rows   INT;
    internal_gaps   INT;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT county_fips) INTO zhvi_rows, zhvi_counties FROM zhvi_monthly;
    SELECT COUNT(*) INTO mortgage_rows FROM mortgage_monthly;
    SELECT COUNT(*) INTO internal_gaps FROM zhvi_monthly WHERE zhvi IS NULL;

    RAISE NOTICE '--- Row counts (expect ~709,996 / 3,071 / ~666; both drift forward over time) ---';
    RAISE NOTICE 'zhvi_monthly rows:      %', zhvi_rows;
    RAISE NOTICE 'zhvi_monthly counties:  %', zhvi_counties;
    RAISE NOTICE 'mortgage_monthly rows:  %', mortgage_rows;
    RAISE NOTICE 'Internal NULL zhvi rows kept (genuine gaps): %', internal_gaps;

    IF zhvi_counties <> 3071 THEN
        RAISE NOTICE 'WARNING: county count differs from the expected 3,071 -- check Zillow''s file for a coverage change.';
    END IF;
END $$;

-- =====================================================================
-- 2. Primary key / duplicate check (HARD -- must always pass)
-- =====================================================================
DO $$
DECLARE
    dup_count INT;
BEGIN
    SELECT COUNT(*) INTO dup_count FROM (
        SELECT county_fips, month FROM zhvi_monthly
        GROUP BY county_fips, month HAVING COUNT(*) > 1
    ) d;
    IF dup_count > 0 THEN
        RAISE EXCEPTION 'STOP: % duplicate (county_fips, month) pairs found in zhvi_monthly -- the primary key should make this impossible.', dup_count;
    END IF;
    RAISE NOTICE 'PASS: no duplicate (county_fips, month) pairs in zhvi_monthly.';
END $$;

-- =====================================================================
-- 3. Date convention check (HARD -- catches a regression to month-start)
-- =====================================================================
-- Every month value in both tables must be an actual month-END date, i.e.
-- the day after it must roll into the following month. Confirms Section 3's
-- decision (parse Zillow headers directly, no to_period("M") normalization)
-- actually took effect, rather than silently reverting to month-start.
DO $$
DECLARE
    bad_zhvi INT;
    bad_mortgage INT;
BEGIN
    SELECT COUNT(*) INTO bad_zhvi
    FROM zhvi_monthly
    WHERE EXTRACT(DAY FROM (month + INTERVAL '1 day')) <> 1;

    SELECT COUNT(*) INTO bad_mortgage
    FROM mortgage_monthly
    WHERE EXTRACT(DAY FROM (month + INTERVAL '1 day')) <> 1;

    IF bad_zhvi > 0 THEN
        RAISE EXCEPTION 'STOP: % rows in zhvi_monthly are not month-end dates -- check for a regression to month-start normalization.', bad_zhvi;
    END IF;
    IF bad_mortgage > 0 THEN
        RAISE EXCEPTION 'STOP: % rows in mortgage_monthly are not month-end dates.', bad_mortgage;
    END IF;
    RAISE NOTICE 'PASS: every row in both tables uses month-end dates.';
END $$;

-- =====================================================================
-- 4. Join integrity (HARD -- no counties or rows may be dropped)
-- =====================================================================
DO $$
DECLARE
    zhvi_rows    INT;
    joined_rows  INT;
    dropped_cty  INT;
    null_rate    INT;
BEGIN
    SELECT COUNT(*) INTO zhvi_rows FROM zhvi_monthly;
    SELECT COUNT(*) INTO joined_rows FROM county_month_joined;

    SELECT COUNT(*) INTO dropped_cty FROM (
        SELECT county_fips FROM zhvi_monthly
        EXCEPT
        SELECT county_fips FROM county_month_joined
    ) d;

    SELECT COUNT(*) INTO null_rate FROM county_month_joined WHERE mortgage_rate IS NULL;

    IF joined_rows <> zhvi_rows THEN
        RAISE EXCEPTION 'STOP: county_month_joined has % rows, zhvi_monthly has % -- row count changed across the join.', joined_rows, zhvi_rows;
    END IF;
    IF dropped_cty > 0 THEN
        RAISE EXCEPTION 'STOP: % counties present in zhvi_monthly are missing from county_month_joined.', dropped_cty;
    END IF;

    RAISE NOTICE 'PASS: join preserved all % rows and all counties.', joined_rows;
    RAISE NOTICE 'NULL mortgage_rate rows in joined table: % (expect 0 given both tables'' overlapping date ranges)', null_rate;
END $$;

-- =====================================================================
-- 5. Quarterly provenance check (SOFT -- compare against phase0_framing.md)
-- =====================================================================
-- Mirrors the notebook's Section 9 in pure SQL: the QUARTER-END month's value
-- per quarter, per county, quarter-over-quarter decline label at the -2% cutoff.
-- A county-quarter is used only if its quarter-end month (Mar/Jun/Sep/Dec) has a
-- ZHVI value, and a label is kept only if the previous row is the calendar quarter
-- right before it. So both quarter-end months must have a value, which is the same
-- rule as the pandas build (labels.py) and as 004/005 in this repo.
WITH quarterly AS (
    SELECT
        county_fips,
        date_trunc('quarter', month)::date AS quarter,
        zhvi
    FROM county_month_joined
    WHERE zhvi IS NOT NULL
      AND month = (date_trunc('quarter', month) + INTERVAL '3 months' - INTERVAL '1 day')::date
),
labeled AS (
    SELECT
        county_fips,
        quarter,
        zhvi,
        LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_zhvi,
        LAG(quarter) OVER (PARTITION BY county_fips ORDER BY quarter) AS prev_quarter,
        CASE
            WHEN (zhvi / NULLIF(LAG(zhvi) OVER (PARTITION BY county_fips ORDER BY quarter), 0)) - 1 < -0.02
            THEN 1 ELSE 0
        END AS decline_label
    FROM quarterly
)
SELECT
    'Full history' AS window,
    COUNT(*) AS rows,
    ROUND(100.0 * AVG(decline_label), 2) AS positive_rate_pct
FROM labeled WHERE prev_quarter = (quarter - INTERVAL '3 months')::date
UNION ALL
SELECT
    'Train (through 2021-09-30)',
    COUNT(*),
    ROUND(100.0 * AVG(decline_label), 2)
FROM labeled WHERE prev_quarter = (quarter - INTERVAL '3 months')::date AND quarter <= DATE '2021-09-30'
UNION ALL
SELECT
    'Embargo (2021-10-01 to 2021-12-31)',
    COUNT(*),
    ROUND(100.0 * AVG(decline_label), 2)
FROM labeled WHERE prev_quarter = (quarter - INTERVAL '3 months')::date AND quarter BETWEEN DATE '2021-10-01' AND DATE '2021-12-31'
UNION ALL
SELECT
    'Test (2022-01-01 to 2026-03-31)',
    COUNT(*),
    ROUND(100.0 * AVG(decline_label), 2)
FROM labeled WHERE prev_quarter = (quarter - INTERVAL '3 months')::date AND quarter BETWEEN DATE '2022-01-01' AND DATE '2026-03-31';

-- Expected after the label-rule change (both quarter-end months required):
--   Train about 173,277 rows (~4.88%), the same as the pandas build's eda_summary.json.
--   Embargo and Test move by a few rows at most. Full history also includes 2026-Q2 and Q3.
-- docs/phase0_framing.md's figures (Full history 5.59%, Train 4.96% / 173,824, Embargo 0.99% /
-- 3,021, Test 8.15% / 52,087) came from an earlier method that kept the quarter after an empty
-- one, whose change then spans six months. Their "Full history" row count (228,932) is Train +
-- Embargo + Test only, so it is lower than the "Full history" row here by design.
-- Stop and investigate if Train is not close to 173,277.
