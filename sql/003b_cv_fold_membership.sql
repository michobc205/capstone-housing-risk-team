-- 003b_cv_fold_membership.sql
-- Run AFTER 005_phase4_features.sql (needs quarterly_modeling_table).
--
-- One row per (fold, county-quarter): fold_role is 'train' or 'val' for that fold.
-- Only Train-split rows are eligible, so Embargo and Test can never enter a fold.
-- Fold dates are quarter-END; quarterly_modeling_table.quarter is quarter START,
-- so it is converted to quarter-end before comparing.

DROP VIEW IF EXISTS cv_fold_rows;

CREATE VIEW cv_fold_rows AS
SELECT *
FROM (
    SELECT
        f.fold_id,
        m.county_fips,
        m.quarter,
        m.decline_label,
        m.momentum_1m, m.momentum_3m, m.momentum_6m,
        m.mortgage_rate_level, m.mortgage_rate_roc, m.rate_roc_x_momentum,
        CASE
            WHEN qe BETWEEN f.train_start AND f.train_end THEN 'train'
            WHEN qe BETWEEN f.val_start   AND f.val_end   THEN 'val'
        END AS fold_role
    FROM cv_folds f
    CROSS JOIN LATERAL (SELECT 1) x
    JOIN (
        SELECT *, (quarter + INTERVAL '3 months' - INTERVAL '1 day')::date AS qe
        FROM quarterly_modeling_table
        WHERE split = 'train'
    ) m ON TRUE
) s
WHERE fold_role IS NOT NULL;

-- Per-fold summary: rows and positives per role (Jolenn's min_fold_positives = 20).
SELECT fold_id, fold_role,
       COUNT(*) AS n_rows,
       SUM(decline_label) AS n_positives,
       ROUND(100.0 * AVG(decline_label), 2) AS positive_rate_pct
FROM cv_fold_rows
GROUP BY fold_id, fold_role
ORDER BY fold_id, fold_role;
