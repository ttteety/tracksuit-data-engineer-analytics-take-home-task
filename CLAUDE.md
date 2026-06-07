# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Tracksuit Senior Data Engineer take-home: build a dbt project (DuckDB-backed, no cloud credentials) that produces a dimensional model (dim/fact pair) of customer subscriptions over time, plus one reporting model proving it works. The full brief is in `README.md` — **do not overwrite it**. Setup details are in `SETUP.md`.

**Assessment weighting: ~80% on the dimensional model, ~20% on the reporting model.** Reviewers care about project structure, layering, naming, tests, and docs more than clever SQL.

## Commands

dbt resolves `profiles.yml` from the repo root — no `--profiles-dir` flag needed. On Windows/PowerShell:

```powershell
.\.venv\Scripts\Activate.ps1          # activate venv (python 3.13, dbt-duckdb 1.x)
python load_raw_data.py               # (re)load raw CSVs into tracksuit.duckdb — run once before dbt
dbt build                             # run all models + tests
dbt build --select <model>            # build a single model
dbt build --select +<model>           # model plus upstream dependencies
dbt test --select <model>             # run tests for one model
dbt deps                              # only if packages.yml is added
```

Reproducibility contract: from a fresh clone, `python load_raw_data.py` then `dbt build` must succeed end-to-end — verify this before considering work done.

Inspect the database:

```powershell
python -c "import duckdb; print(duckdb.connect('tracksuit.duckdb').sql('SELECT * FROM raw.subskribe_subscriptions LIMIT 10'))"
```

## Overview

- **Sources:** `load_raw_data.py` loads four CSVs from `data/raw/` into the `raw` schema of `tracksuit.duckdb`, **all columns as VARCHAR** — type casting belongs in staging. Tables: `raw.hubspot_companies` (CRM), `raw.subskribe_accounts`, `raw.subskribe_subscriptions`, `raw.subskribe_invoices` (billing).
- **dbt output:** models build into the `analytics` schema of the same file (`profiles.yml`). Default materialization is `view` (`dbt_project.yml`); layering/materialization choices beyond that are deliberately left to the candidate.
- **Join path:** `hubspot_companies.company_id` ← `subskribe_accounts.crmid`; `subscriptions.account_id` → accounts; `invoices.account_id`/`subscription_id` → accounts/subscriptions. `renewed_from_subscription_id` chains a customer's subscription history.

## Architecture

All models must be strictly separated into the following folders and layers:

- **Staging (`models/staging/`)**: Direct 1:1 mapping of source data. Clean column names (snake_case), basic type casting. No derived columns. Create as views.
- **Intermediate (`models/intermediate/`)**: Business logic joins and aggregations.
- **Marts (`models/marts/`)**: Final business entities (facts and dimensions). Clean, ready-to-query grain. Surrogate keys are generated here, where each model's grain is defined.

## Testing & Documentation

- **Primary Keys**: Every model must have a `not_null` and `unique` test on its primary key.
- **Relationships**: Ensure foreign keys have `relationships` tests.
- **Docs**: All models and columns (in `schema.yml` files) must be thoroughly

### Known data quirks (handling them is part of the task)

- `hubspot_companies.merged_object_ids`: semicolon-separated old company IDs merged into the record — `crmid` may point at a merged-away ID.
- Account names don't always match HubSpot company names; `crmid` is the link, not the name.
- Multi-currency invoices: use `total_nzd` (NZD is Tracksuit's functional currency).
- Subscription states include `ACTIVE`, `CANCELED`, `EXPIRED`, etc.; invoice statuses include `POSTED`, `PAID`, `VOIDED`.
- Make defensible assumptions for ambiguities and record them in `SUBMISSION.md` rather than chasing edge cases.

### GRR definition (Tracksuit's working definition — use exactly this)

> GRR for month M = revenue at month M from the cohort of customers who were paying at month M-12, divided by that cohort's revenue at month M-12, expressed as a percentage. The cohort is fixed at M-12 (customers acquired after M-12 don't count). Expansion is excluded: cap each cohort customer's month-M revenue at their M-12 amount — the cap is what makes it "gross" rather than "net".

The reporting model must return monthly GRR **segmented by `size_grouped`** (Enterprise/Mid-Market/SMB/Startup) for the last 12 months.

## Deliverables checklist

1. Dimensional model (dim/fact) of subscriptions over time — reusable, must answer "subscriptions as of any given month", not just today.
2. Reporting model: monthly GRR by customer size segment, last 12 months.
3. `SUBMISSION.md` (new file): how to run, key assumptions, data quality notes.
4. `PROMPTS.md`: the AI prompts that shaped real decisions (not a full transcript).

All work must be committed to this repo.

## Git

The git will manually commit.
