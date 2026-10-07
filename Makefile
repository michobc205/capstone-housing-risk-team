# Makefile for capstone-housing-risk-team
#
# Runs the pipeline in the correct order. Usage:  make help
#
# Why this exists: notebooks 01-04 run most of the SQL, but two steps are not
# in any notebook (the one-time schema, and sql/005_phase4_features.sql, which
# notebook 02 needs before its section 6). This file runs everything in order,
# up to the Test evaluation (notebooks 05 and 06).
#
# Notes
#   * Connection settings come from .env (PGHOST, PGPORT, PGDATABASE, PGUSER,
#     PGPASSWORD). The file is sourced by the shell, so a password containing
#     characters like $ & or spaces must be wrapped in single quotes in .env.
#   * Notebooks are executed into build/executed/, so the committed .ipynb files
#     are never modified. Add "build/" to .gitignore.
#   * Recipe lines must start with a TAB, not spaces.
#   * Notebooks 05 and 06 have gates: they stop unless the lock files in docs/
#     (phase5_baseline_lock.json, phase6_thresholds_lock.json and
#     phase6_test_lock.json) are committed in git, so run them inside a git clone.
#     They compare their results with those locks, so a changed result stops
#     them. They are slow (notebook 05 about 12 to 35 minutes on a Windows
#     laptop, notebook 06 about 15 minutes), so close memory-heavy programs.
#   * Works on Mac/Linux (.venv/bin/python) and on Windows Git Bash
#     (.venv/Scripts/python.exe). On Windows, GNU make is not installed with
#     Git Bash: install it first (for example with Chocolatey, Scoop or winget)
#     and check with: make --version

SHELL := bash
VENV  ?= .venv
# Windows virtualenvs put Python in Scripts/, Mac/Linux in bin/. The last entry is
# only a fallback so the error message below names a sensible path.
PY    := $(firstword $(wildcard $(VENV)/Scripts/python.exe $(VENV)/bin/python) $(VENV)/bin/python)

# Load .env, then run psql. Stop at the first SQL error.
PSQL  := set -a; . ./.env; set +a; psql -v ON_ERROR_STOP=1 -P pager=off

# Execute a notebook top to bottom with no per-cell timeout (the loads are slow).
NBRUN := $(PY) -m jupyter nbconvert --to notebook --execute \
         --output-dir build/executed \
         --ExecutePreprocessor.timeout=-1 \
         --ExecutePreprocessor.kernel_name=python3

.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help check check-nb schema phase1 validate-phase1 split features phase2 phase3 phase4 phase5 phase6 all clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

check: ## Check .env, the virtualenv, psql, and show which database will be used
	@test -f .env || { echo "Missing .env (see README Setup)"; exit 1; }
	@test -x $(PY) || { echo "Missing $(VENV)/bin/python or $(VENV)/Scripts/python.exe. Create the venv and run: pip install -r requirements.txt"; exit 1; }
	@command -v psql >/dev/null || { echo "psql not found on PATH"; exit 1; }
	@$(PSQL) -tA -c "SELECT 'Target database: ' || current_database() || ' (port ' || inet_server_port() || ')'"

check-nb: check ## Check that notebooks can be executed (nbconvert and ipykernel installed)
	@$(PY) -c "import nbconvert, ipykernel" 2>/dev/null || { echo "Missing nbconvert or ipykernel. Run: $(PY) -m pip install nbconvert ipykernel"; exit 1; }

schema: check ## Create the two empty tables (sql/001_schema.sql, safe to re-run)
	@$(PSQL) -f sql/001_schema.sql

phase1: check-nb ## Notebook 01: download, clean, load, and join (runs 002)
	@$(NBRUN) notebooks/01_phase1_ingest_merged.ipynb

validate-phase1: check ## Optional: run the pure-SQL Phase 1 audit (phase1_validation.sql)
	@$(PSQL) -f sql/phase1_validation.sql

split: check ## Run sql/003_phase2_split.sql (split and CV folds; 005 needs it)
	@$(PSQL) -f sql/003_phase2_split.sql

features: check ## Run sql/005_phase4_features.sql (builds quarterly_modeling_table; notebook 02 needs it)
	@$(PSQL) -f sql/005_phase4_features.sql

phase2: check-nb split features ## Run 003 and 005, then notebook 02 (which reruns 003 and runs 003b)
	@$(NBRUN) notebooks/02_phase2_split_cv.ipynb

phase3: check-nb ## Notebook 03: EDA, lag sweep, reverse-causation (runs 004, writes outputs/)
	@$(NBRUN) notebooks/03_phase3_eda_merged.ipynb

phase4: check-nb ## Notebook 04: features (runs 005 and 003b, writes outputs/)
	@$(NBRUN) notebooks/04_phase4_features_merged.ipynb

phase5: check-nb ## Notebook 05: models on the validation folds (needs notebook 04 and the committed baseline lock; writes 4 phase5_* tables)
	@$(NBRUN) notebooks/05_phase5_modeling_merged.ipynb

phase6: check-nb ## Notebook 06: evaluation on the Test period (needs notebook 05 and the 3 committed locks; writes 11 phase6_* tables)
	@$(NBRUN) notebooks/06_phase6_evaluation_merged.ipynb

all: check schema phase1 phase2 phase3 phase4 phase5 phase6 ## Run everything in order, from schema to Phase 6

clean: ## Delete the executed notebook copies in build/
	rm -rf build
