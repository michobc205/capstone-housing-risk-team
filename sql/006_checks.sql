-- 006_checks.sql  (team repo)
--
-- A test suite written in SQL. Run it once the pipeline up to Phase 4 has been built
-- (it needs the tables of 001 to 005 and the view of 003b), or at any time to see whether
-- the database is still in a healthy state. HARD checks stop the script with an error:
-- they are invariants that must hold whatever Zillow or FRED publish next. SOFT checks only
-- print figures to compare with the README, because those drift slightly as data arrives.
-- The script only reads: it creates and changes nothing.
--
--   psql -U postgres housing_risk_team -f sql/006_checks.sql
-- or paste it into DBeaver's SQL editor (run it as a script).
--
-- Merge rule 9 (docs/merge_rules_phase5_6.md) is covered like this:
--   - training label quarters end before each validation period starts: section 3
--   - the FRED rate uses only months up to the feature quarter-end: section 6
--   - no duplicate month and no fold row outside Train: sections 1 and 3
--   - the results reproduce the locked numbers: not here, notebooks 05 and 06 check it

-- 1. Source tables ------------------------------------------------------------------------
DO $$
DECLARE
    n_dup INTEGER;
    n_bad_z INTEGER;
    n_bad_m INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_dup FROM (
        SELECT county_fips, month FROM zhvi_monthly GROUP BY county_fips, month HAVING COUNT(*) > 1
    ) d;
    IF n_dup > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % duplicate (county_fips, month) pairs in zhvi_monthly', n_dup;
    END IF;

    -- Every stored date must be a month-END date: the day after it is the 1st of a month.
    SELECT COUNT(*) INTO n_bad_z FROM zhvi_monthly WHERE EXTRACT(DAY FROM (month + INTERVAL '1 day')) <> 1;
    SELECT COUNT(*) INTO n_bad_m FROM mortgage_monthly WHERE EXTRACT(DAY FROM (month + INTERVAL '1 day')) <> 1;
    IF n_bad_z > 0 OR n_bad_m > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: month-end convention broken (% zhvi rows, % mortgage rows)', n_bad_z, n_bad_m;
    END IF;
    RAISE NOTICE 'PASS: no duplicate months, and every month is a month-end date';
END $$;

-- 2. Join integrity -----------------------------------------------------------------------
DO $$
DECLARE
    n_z INTEGER; n_j INTEGER; n_lost_counties INTEGER; n_null_rate INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_z FROM zhvi_monthly;
    SELECT COUNT(*) INTO n_j FROM county_month_joined;
    SELECT COUNT(*) INTO n_lost_counties FROM (
        SELECT county_fips FROM zhvi_monthly EXCEPT SELECT county_fips FROM county_month_joined
    ) d;
    SELECT COUNT(*) INTO n_null_rate FROM county_month_joined WHERE mortgage_rate IS NULL;
    IF n_z <> n_j THEN
        RAISE EXCEPTION 'CHECK FAILED: the join changed the row count (% before, % after)', n_z, n_j;
    END IF;
    IF n_lost_counties > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % counties lost in the join', n_lost_counties;
    END IF;
    IF n_null_rate > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % joined rows have no mortgage rate', n_null_rate;
    END IF;
    RAISE NOTICE 'PASS: join kept all % rows and all counties, with no missing rate', n_j;
END $$;

-- 3. Split and folds ----------------------------------------------------------------------
DO $$
DECLARE
    n_null_split INTEGER; n_fold_leak INTEGER; n_order INTEGER; min_val_pos INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_null_split FROM monthly_split WHERE split IS NULL;
    IF n_null_split > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % rows without a split label', n_null_split;
    END IF;

    -- The view cv_fold_rows has no split column, so every fold row is looked up in the
    -- modeling table: it must be found there and must belong to Train.
    SELECT COUNT(*) INTO n_fold_leak
    FROM cv_fold_rows f
    LEFT JOIN quarterly_modeling_table m ON m.county_fips = f.county_fips AND m.quarter = f.quarter
    WHERE m.split IS DISTINCT FROM 'train';
    IF n_fold_leak > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % fold rows are missing from the modeling table or come from Embargo or Test', n_fold_leak;
    END IF;

    -- In every fold, the last training label quarter must end before the validation period
    -- starts. A label quarter ends on its last day: quarter start + 3 months - 1 day.
    SELECT COUNT(*) INTO n_order FROM (
        SELECT f.fold_id
        FROM cv_folds f
        JOIN cv_fold_rows r ON r.fold_id = f.fold_id AND r.fold_role = 'train'
        GROUP BY f.fold_id, f.val_start
        HAVING MAX((r.quarter + INTERVAL '3 months' - INTERVAL '1 day')::date) >= f.val_start
    ) s;
    IF n_order > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: % folds have training label quarters that end on or after the validation start', n_order;
    END IF;

    -- Every validation fold needs enough positives for its AUC to be trusted.
    SELECT MIN(pos) INTO min_val_pos FROM (
        SELECT fold_id, SUM(decline_label) AS pos FROM cv_fold_rows WHERE fold_role = 'val' GROUP BY fold_id
    ) s;
    IF min_val_pos IS NULL OR min_val_pos < 20 THEN
        RAISE EXCEPTION 'CHECK FAILED: no validation folds found, or a fold has only % positives (minimum 20)', min_val_pos;
    END IF;
    RAISE NOTICE 'PASS: every row has a split, every fold row is a Train row, training ends before validation starts, lowest validation fold has % positives', min_val_pos;
END $$;

-- 4. Labels -------------------------------------------------------------------------------
DO $$
DECLARE
    n_gap INTEGER; n_null INTEGER; n_bad_label INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_gap FROM train_quarterly_labeled
    WHERE prev_quarter <> (quarter - INTERVAL '3 months')::date;
    SELECT COUNT(*) INTO n_null FROM train_quarterly_labeled WHERE pct_change IS NULL;
    SELECT COUNT(*) INTO n_bad_label FROM train_quarterly_labeled WHERE decline_label NOT IN (0, 1);
    IF n_gap > 0 OR n_null > 0 OR n_bad_label > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: labels (% spanning more than a quarter, % empty changes, % invalid labels)',
            n_gap, n_null, n_bad_label;
    END IF;
    RAISE NOTICE 'PASS: every label is a true quarter-to-quarter change';
END $$;

-- 5. Modeling table -----------------------------------------------------------------------
DO $$
DECLARE
    n_null INTEGER; n_dup INTEGER; n_align INTEGER; n_inter INTEGER; n_month INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_null FROM quarterly_modeling_table
    WHERE momentum_1m IS NULL OR momentum_3m IS NULL OR momentum_6m IS NULL
       OR mortgage_rate_level IS NULL OR mortgage_rate_roc IS NULL OR rate_roc_x_momentum IS NULL;
    SELECT COUNT(*) INTO n_dup FROM (
        SELECT county_fips, quarter FROM quarterly_modeling_table GROUP BY county_fips, quarter HAVING COUNT(*) > 1
    ) d;
    -- Features are measured on the last day before the label quarter starts.
    SELECT COUNT(*) INTO n_align FROM quarterly_modeling_table
    WHERE feature_quarter_end <> (quarter - INTERVAL '1 day')::date;
    SELECT COUNT(*) INTO n_month FROM quarterly_modeling_table
    WHERE EXTRACT(MONTH FROM feature_quarter_end) NOT IN (3, 6, 9, 12);
    SELECT COUNT(*) INTO n_inter FROM quarterly_modeling_table
    WHERE ABS(rate_roc_x_momentum - mortgage_rate_roc * momentum_3m) > 1e-9;
    IF n_null > 0 OR n_dup > 0 OR n_align > 0 OR n_month > 0 OR n_inter > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: modeling table (% missing, % duplicates, % misaligned, % not at a quarter end, % wrong interaction)',
            n_null, n_dup, n_align, n_month, n_inter;
    END IF;
    RAISE NOTICE 'PASS: no missing features, one row per county and quarter, features from the preceding quarter end';
END $$;

-- 6. FRED mortgage rate timing (merge rule 9) -----------------------------------------------
-- The database holds the MONTHLY rate only. Cutting the weekly FRED file down to weeks up
-- to each month-end happens before the database, when the file is loaded (notebook 01), so
-- this section cannot test it. What it does test, on every modeling row: the rate level is
-- the monthly rate at the feature quarter-end, never a later month, and the 12-month change
-- is that rate minus the rate of exactly 12 calendar months earlier. It also tests that the
-- monthly series has no gap, because a gap would make "12 rows earlier" mean more than 12 months.
DO $$
DECLARE
    n_gap INTEGER; n_level INTEGER; n_roc INTEGER;
BEGIN
    SELECT COUNT(*) INTO n_gap FROM (
        SELECT month, LAG(month) OVER (ORDER BY month) AS prev_month FROM mortgage_monthly
    ) s
    WHERE prev_month IS NOT NULL AND prev_month <> (date_trunc('month', month) - INTERVAL '1 day')::date;

    SELECT COUNT(*) INTO n_level
    FROM quarterly_modeling_table t
    LEFT JOIN mortgage_monthly m ON m.month = t.feature_quarter_end
    WHERE m.month IS NULL OR ABS(t.mortgage_rate_level - m.mortgage_rate) > 1e-9;

    -- Month-end of the month 12 months before the feature quarter-end.
    SELECT COUNT(*) INTO n_roc
    FROM quarterly_modeling_table t
    LEFT JOIN mortgage_monthly m ON m.month = t.feature_quarter_end
    LEFT JOIN mortgage_monthly m12
           ON m12.month = (date_trunc('month', t.feature_quarter_end) - INTERVAL '11 months' - INTERVAL '1 day')::date
    WHERE m.month IS NULL OR m12.month IS NULL
       OR ABS(t.mortgage_rate_roc - (m.mortgage_rate - m12.mortgage_rate)) > 1e-9;

    IF n_gap > 0 OR n_level > 0 OR n_roc > 0 THEN
        RAISE EXCEPTION 'CHECK FAILED: mortgage rate timing (% gaps in the monthly series, % rows with a level that is not the rate at the feature quarter-end, % rows with a wrong 12-month change)',
            n_gap, n_level, n_roc;
    END IF;
    RAISE NOTICE 'PASS: every rate level is the rate at the feature quarter-end, every 12-month change spans exactly 12 months, no gap in the monthly series';
END $$;

-- 7. Soft checks: figures to compare with the README ----------------------------------------
-- 7a. Decline labels per window, computed in SQL. They must equal the figures in the README
-- (Phase 1 section) for the frozen data version: Full history 231,453 rows / 5.55 percent,
-- Train 173,277 / 4.88, Embargo 3,020 / 0.96, Test 52,085 / 8.15. Full history also holds
-- the 3,071 rows of 2026-Q2, which belong to no split.
SELECT 'Full history' AS window, COUNT(*) AS n_rows,
       ROUND(100.0 * AVG(decline_label), 2) AS positive_rate_pct
FROM quarterly_labeled_full
UNION ALL
SELECT 'Train', COUNT(*), ROUND(100.0 * AVG(decline_label), 2)
FROM quarterly_labeled_full WHERE split = 'train'
UNION ALL
SELECT 'Embargo', COUNT(*), ROUND(100.0 * AVG(decline_label), 2)
FROM quarterly_labeled_full WHERE split = 'embargo'
UNION ALL
SELECT 'Test', COUNT(*), ROUND(100.0 * AVG(decline_label), 2)
FROM quarterly_labeled_full WHERE split = 'test';

-- 7b. The modeling table, which drops each county's earliest quarters (no 6-month momentum
-- or 12-month rate history yet) and any row with a missing feature.
-- Expected for the frozen data version (README, Phase 4 section):
--   Train 164,460 rows / 4.85 percent, Embargo 3,020 / 0.96, Test 51,980 / 8.11, Unassigned 3,070 / 4.27
SELECT split, COUNT(*) AS n_rows, COUNT(DISTINCT county_fips) AS n_counties,
       ROUND(100.0 * AVG(decline_label), 2) AS positive_rate_pct
FROM quarterly_modeling_table
GROUP BY split
ORDER BY split;
