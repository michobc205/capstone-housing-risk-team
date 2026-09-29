-- 003_phase2_split.sql  (MERGED: Michel's chronological split + Jolenn's CV folds)
--
-- Part A: chronological Train / Embargo / Test split on county_month_joined
--         (unchanged from Michel's version).
--   Train:   through 2021-09-30
--   Embargo: 2021-10-01 to 2021-12-31 (excluded from both Train and Test)
--   Test:    2022-01-01 to 2026-03-31
--   Rows after 2026-03-31 get 'unassigned' instead of being silently dropped.
--
-- Part B: Jolenn's 11 expanding-window CV folds (from her cv_folds.json),
--         stored as a table. Folds live entirely inside the Train window; they
--         never touch Embargo or Test. Fold dates are QUARTER-END dates, while
--         quarterly tables here store the quarter START (date_trunc('quarter')),
--         so the membership view (003b) converts before comparing.
--
-- Part C: sanity checks that raise an error if the fold table is inconsistent.

-- ---------------------------------------------------------------- Part A
DROP TABLE IF EXISTS monthly_split CASCADE;

CREATE TABLE monthly_split AS
SELECT
    *,
    CASE
        WHEN month <= DATE '2021-09-30' THEN 'train'
        WHEN month >= DATE '2021-10-01' AND month <= DATE '2021-12-31' THEN 'embargo'
        WHEN month >= DATE '2022-01-01' AND month <= DATE '2026-03-31' THEN 'test'
        ELSE 'unassigned'
    END AS split
FROM county_month_joined;

CREATE VIEW train_monthly   AS SELECT * FROM monthly_split WHERE split = 'train';
CREATE VIEW embargo_monthly AS SELECT * FROM monthly_split WHERE split = 'embargo';
CREATE VIEW test_monthly    AS SELECT * FROM monthly_split WHERE split = 'test';

-- ---------------------------------------------------------------- Part B
DROP TABLE IF EXISTS cv_folds CASCADE;

CREATE TABLE cv_folds (
    fold_id          INTEGER PRIMARY KEY,
    train_start      DATE NOT NULL,
    train_end        DATE NOT NULL,
    val_start        DATE NOT NULL,
    val_end          DATE NOT NULL,
    n_train_quarters INTEGER NOT NULL,
    n_val_quarters   INTEGER NOT NULL
);

INSERT INTO cv_folds VALUES
    (0, DATE '2000-03-31', DATE '2009-12-31', DATE '2010-03-31', DATE '2010-12-31', 40, 4),
    (1, DATE '2000-03-31', DATE '2010-12-31', DATE '2011-03-31', DATE '2011-12-31', 44, 4),
    (2, DATE '2000-03-31', DATE '2011-12-31', DATE '2012-03-31', DATE '2012-12-31', 48, 4),
    (3, DATE '2000-03-31', DATE '2012-12-31', DATE '2013-03-31', DATE '2013-12-31', 52, 4),
    (4, DATE '2000-03-31', DATE '2013-12-31', DATE '2014-03-31', DATE '2014-12-31', 56, 4),
    (5, DATE '2000-03-31', DATE '2014-12-31', DATE '2015-03-31', DATE '2015-12-31', 60, 4),
    (6, DATE '2000-03-31', DATE '2015-12-31', DATE '2016-03-31', DATE '2016-12-31', 64, 4),
    (7, DATE '2000-03-31', DATE '2016-12-31', DATE '2017-03-31', DATE '2017-12-31', 68, 4),
    (8, DATE '2000-03-31', DATE '2017-12-31', DATE '2018-03-31', DATE '2018-12-31', 72, 4),
    (9, DATE '2000-03-31', DATE '2018-12-31', DATE '2019-03-31', DATE '2019-12-31', 76, 4),
    (10, DATE '2000-03-31', DATE '2019-12-31', DATE '2020-03-31', DATE '2020-12-31', 80, 4);

-- ---------------------------------------------------------------- Part C
DO $$
DECLARE
    bad INTEGER;
    last_train DATE;
BEGIN
    SELECT MAX(month) INTO last_train FROM monthly_split WHERE split = 'train';

    -- 1. Every fold's validation window ends inside Train (never reaches Embargo/Test).
    SELECT COUNT(*) INTO bad FROM cv_folds WHERE val_end > last_train;
    IF bad > 0 THEN RAISE EXCEPTION 'CV check failed: % fold(s) validate beyond the Train window', bad; END IF;

    -- 2. Within each fold, training ends before validation starts.
    SELECT COUNT(*) INTO bad FROM cv_folds WHERE train_end >= val_start;
    IF bad > 0 THEN RAISE EXCEPTION 'CV check failed: % fold(s) have train overlapping validation', bad; END IF;

    -- 3. Expanding window: same start, train_end strictly increasing with fold_id.
    SELECT COUNT(*) INTO bad FROM (
        SELECT train_start, train_end,
               LAG(train_end) OVER (ORDER BY fold_id) AS prev_end,
               FIRST_VALUE(train_start) OVER (ORDER BY fold_id) AS first_start
        FROM cv_folds
    ) t
    WHERE train_start <> first_start OR (prev_end IS NOT NULL AND train_end <= prev_end);
    IF bad > 0 THEN RAISE EXCEPTION 'CV check failed: folds are not a clean expanding window'; END IF;

    -- 4. Stored quarter counts match the dates.
    SELECT COUNT(*) INTO bad FROM cv_folds
    WHERE n_train_quarters <> (EXTRACT(YEAR FROM train_end) - EXTRACT(YEAR FROM train_start)) * 4
                              + (EXTRACT(MONTH FROM train_end) - EXTRACT(MONTH FROM train_start)) / 3 + 1
       OR n_val_quarters   <> (EXTRACT(YEAR FROM val_end) - EXTRACT(YEAR FROM val_start)) * 4
                              + (EXTRACT(MONTH FROM val_end) - EXTRACT(MONTH FROM val_start)) / 3 + 1;
    IF bad > 0 THEN RAISE EXCEPTION 'CV check failed: quarter counts do not match fold dates'; END IF;

    RAISE NOTICE 'Phase 2 checks passed: % folds, all inside Train (last train month %)',
        (SELECT COUNT(*) FROM cv_folds), last_train;
END $$;

-- Row counts per split, to compare against each side's known figures.
SELECT split, COUNT(*) AS n_rows
FROM monthly_split
GROUP BY split
ORDER BY split;
