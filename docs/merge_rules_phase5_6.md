# Merge rules for Phases 5 and 6

Written before comparing the notebooks.

## A. Design and honesty about Test

1. **The design stays locked.** Three families: logistic regression, random forest and histogram gradient boosting. Settings are fixed, seed 42, no tuning. Three feature steps in the Phase 0 order: momentum only, plus rate level, plus rate change with the interaction (12-month lag, fixed in advance). The recommended model is chosen on the validation folds only: random forest on momentum. XGBoost is left out completely, not even as an extra line. The pandas pipeline's second-algorithm notebook is compared for method only and is not ported.
2. **Test was already known.** The Test period was scored in both independent pipelines and in earlier versions before this merge. The results are protected from new choices, but they are not untouched. Wording to use: choices were made on the validation folds, and Test was scored once with frozen models.
3. **Comparison of methods and code only.** No choice is made because of Test results. Reading order: the modeling notebook, the robustness notebook and the validation files first. The final-evaluation notebook and its results come last, after this note is committed.
4. **Bootstrap.** The locked version (mean of per-fold scores, bootstrap over quarters) is the main one. The pooled out-of-fold version is reported as a check. If the verdicts differ, the main one stands, the difference is reported, and Test results never settle it.
5. **Allowed additions, labelled as such:** a quarter-bootstrap interval for the logistic interaction coefficient (read as exploratory, because the rate has only about 82 independent quarters of information), validation-year and PR-AUC / base-rate columns in the per-fold table, and a note that the folds use label-quarter dating, so scores are not comparable one-to-one with the pandas pipeline's baseline lock. Anything else new is marked "exploratory, added after Test was seen".

## B. Locks and gates

6. **Locks and gates stay.** The baseline lock is committed before the rate steps are fitted. The thresholds lock is committed before Test is scored. Notebook 06 refuses to run unless the locks are committed. Gates stay: at least 20 positives in every validation fold, and a Test data-quality check (51,980 rows, 4,214 declines, 17 label quarters). Test is scored once per run with frozen models. All three locks go to `docs/` and are committed as soon as they are written.

## C. What the notebooks report

7. **Phase 5:** per-fold table, bootstrap over the 44 validation quarters, and the success rule (a step helps only if its 95% interval excludes zero and the gain is at least +0.01 ROC-AUC). The recommended model is chosen on validation only.
8. **Phase 6:**
   - Test results per step and family, with a bootstrap over the 17 Test quarters and the same success rule. The intervals are wide, and the notebook says so.
   - Rank-based rules (riskiest 5%, 10% and 20%) and the validation-locked F1 threshold, judged by lift.
   - Calibration, and a per-quarter table.
   - A check of rates outside the training range.
   - The order-dependency statement: the lifts measure what the rate adds given momentum.
   - The robustness check: do the families rank the contributions the same way?

## D. Port checks

9. **Checks:**
   - training label quarters end before each validation period starts
   - the FRED rate uses only weeks up to the feature quarter-end
   - there is no duplicate month and no fold row outside Train
   - the team results reproduce the locked numbers (for example logistic regression baseline 0.8364, random forest 0.8680, Test random forest 0.8857) up to floating-point noise. If they do not, stop and investigate.

## E. Data, dashboard and scope

10. **Data version.** The raw Zillow and FRED files are frozen, with hashes recorded in the README, and backed up outside the repo. The write-up states that Zillow revises past values each month, so the backtest uses later, revised values. The smoothing is trailing, so the effect comes from revisions only.
11. **Dashboard.** Aggregated results only, no county-level columns. The snapshot lives in `docs/dashboard_data/` and is re-exported and committed after every re-run of notebooks 05 and 06.
12. **Out of scope before the 16th:** county features, the 2008 sensitivity folds and the measurement of Zillow's revisions (future work). Not adopted, because each would reopen a settled choice after Test was seen: class weights, extra rate lags, XGBoost, neighbour averages and the "declined last quarter" flag.

## Decisions added after the rules were committed

- 2026-10-06 (agreed by both team members): the reproduction check in notebook 05 uses a tolerance per family. Logistic regression and histogram gradient boosting must match to within 1e-6, and the random forest within 1e-3. On a second machine of a different type (Apple arm64), logistic regression and histogram gradient boosting matched exactly and the random forest differed by up to 4e-4. The most likely reason is that its trees split differently at near-ties on different hardware. Any difference in the data or the code still stops the notebook. The same per-family rule applies to the Test lock in Phase 6.
- 2026-10-07 (cut-offs on a re-run: structure proposed by Jolenn, the 1e-2 value chosen by Michel; agreed by both team members): the check of the F1 cut-offs in notebook 06 follows the same per-family idea. Logistic regression and histogram gradient boosting must reproduce all four cut-off numbers (cut-off, precision, recall, F1) to within 1e-6. For the random forest two things must hold, each to within 1e-2: the best validation F1 matches the locked F1, and the locked cut-off, applied to the validation predictions of the machine that runs the notebook, gives an F1 within 1e-2 of that machine's best F1. The gap between the cut-off values themselves is printed for information and never stops the notebook, because the F1 curve of a random forest is flat near its top. On the second machine (a Mac with Apple arm64 and Python 3.14.7) the random forest cut-offs moved by up to 3.4e-3, the best F1 differed by at most 3.6e-4, and the F1 at the locked cut-off was up to 1.12e-3 below that machine's best, so a tolerance of 1e-3 would have stopped the run for a harmless reason. Test is always scored with the cut-offs of the committed docs/phase6_thresholds_lock.json, never with recomputed ones, so every machine applies the same decision rule.
- 2026-10-07 (after the first re-run on the second machine; agreed by both team members): the random forest Test scores in notebook 06 are checked with a tolerance of 1e-2 on another machine, not the 1e-3 first agreed for the Test lock. On the Mac, logistic regression differed from the reference by 7e-17 and histogram gradient boosting by 0, but the random forest PR-AUC (step with the rate change) differed by 1.43e-3, and the notebook stopped, as designed. PR-AUC reacts more strongly than ROC-AUC to near-ties in the trees, and 1e-2 leaves a margin of about seven times over the gap seen. Everything else stays strict: logistic regression and histogram gradient boosting at 1e-6 (also for their Test scores), the row counts and data checks, and the Phase 5 reproduction at 1e-3. No model, setting or verdict changes. With the new tolerance the second re-run on the Mac ran to the end: the verdicts of the bootstrap and every interval_excludes_zero value in the family comparison are the same as on the first machine, and the random forest intervals differ only in the third or fourth decimal. The numbers quoted in the README are those of the committed lock files.
- 2026-10-07 (proposed by Jolenn, agreed by both team members): the thresholds lock also lists the columns of all three feature steps, and notebook 06 stops unless they match the fixed lists and the momentum columns of the committed Phase 5 baseline lock. This only records the features before Test is scored and changes no model. The Phase 5 baseline lock is not touched, because committing it again would weaken its proof of order.
- 2026-10-07 (agreed by both team members): two points about notebook 06, in line with rule 5. The plain read-out against the success criteria (section 13) was added after Test was seen, is labelled as such in the notebook, and computes nothing new. The reverse-causation check itself was already merged in Phase 3 (notebook 03), with the agreed wording "No reliable evidence that home prices lead mortgage rates". The feedback-loop explanation that the pandas pipeline's final evaluation notebook (notebook 10) presented as a tested finding is not carried into notebook 06.
