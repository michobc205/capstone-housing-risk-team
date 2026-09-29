-- 002_join_check.sql (merged)
--
-- Zillow is the spine (LEFT JOIN): a month missing from mortgage_monthly
-- should surface as a NULL mortgage_rate, never as a silently dropped
-- county-month row.
--
-- Plain equality join (m.month = z.month), not date_trunc('month', ...).
-- The earlier SQL-variant version of this file needed date_trunc because
-- that repo normalized zhvi_monthly.month to month-*start* while
-- mortgage_monthly.month stayed at month-*end*. The merged Phase 1 notebook
-- keeps zhvi_monthly at month-end (Zillow's own native format, and already
-- mortgage_monthly's convention after resampling), so both sides already
-- agree and no truncation is needed.
--
-- Dropped first so this is safe to re-run: CREATE TABLE ... AS has no "OR
-- REPLACE" form in Postgres, so "IF NOT EXISTS" alone would silently keep
-- whatever rows this table already had from an earlier run, even after
-- zhvi_monthly or mortgage_monthly changed underneath it.
--
-- NOTE on the two source repos' original row-count mismatch (708,953 vs.
-- 709,996): an earlier version of this comment attributed that gap to
-- "stale rows from an earlier run silently accumulating." That explanation
-- does not hold up -- both source pipelines clear their tables before
-- every load and zhvi_monthly has a (county_fips, month) primary key, which
-- would reject true duplicates outright. The real cause was a NaN-handling
-- difference in the two repos' Zillow cleaning steps (one dropped genuine
-- internal reporting gaps, the other correctly kept them as NULL rows) --
-- see the merged Phase 1 notebook's Section 3 for the full explanation.
-- This file no longer needs to guard against that scenario specifically,
-- but TRUNCATE-before-load discipline is kept in the notebook regardless,
-- since it's good practice independent of this particular historical bug.
DROP TABLE IF EXISTS county_month_joined;

CREATE TABLE county_month_joined AS
SELECT
    z.county_fips,
    z.month,
    z.zhvi,
    z.region_name,
    z.state,
    m.mortgage_rate
FROM zhvi_monthly AS z
LEFT JOIN mortgage_monthly AS m
    ON m.month = z.month;
