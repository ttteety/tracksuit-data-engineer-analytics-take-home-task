# Design: Tracksuit Subscriptions Dimensional Model

**Date:** 2026-06-04
**Status:** Approved
**Context:** Tracksuit Senior Data Engineer take-home. Build a dbt project (DuckDB) producing a dimensional model of customer subscriptions over time, plus a reporting model calculating monthly GRR by customer size segment for the last 12 months. Assessment weight: ~80% dimensional model, ~20% reporting model.

## Data profile (verified 2026-06-04)

| Table | Rows | Notes |
|---|---|---|
| `raw.hubspot_companies` | 120 | unique PKs; 14 rows have `merged_object_ids` |
| `raw.subskribe_accounts` | 122 | no NULL `crmid`; 13 don't match a live company directly |
| `raw.subskribe_subscriptions` | 330 | EXPIRED 208 / ACTIVE 111 / CANCELED 11 |
| `raw.subskribe_invoices` | 3,594 | PAID 3,321 / POSTED 160 / VOIDED 113; 2023-06 → 2026-05 |

Verified facts the design depends on:

- **CRM links:** 11 of 13 unmatched `crmid`s are `hsold_*` values, all resolvable by splitting `merged_object_ids`. 2 are `hsmissing_*` (Wrenfield Brewing, Riverbend Co) — genuinely unmatchable, no `size_grouped` available.
- **Invoice cadence is cleanly monthly:** never >1 invoice per subscription per calendar month. No negative/zero/non-numeric totals. No duplicate PKs anywhere; no orphan FKs within Subskribe.
- **Bounded month spine closes perfectly:** generating months from `start_date` to `LEAST(end_date, cancelled_date, data horizon)` per subscription leaves exactly 113 zero-invoice months, 100% explained by VOIDED invoices, and loses zero non-voided invoices. No invoices exist after `cancelled_date`.
- **Voided invoices were never re-issued:** all 113 sit alone in their month → each is a one-month revenue hole in an otherwise continuously billed subscription.
- **Renewal chains never overlap in dates**, but billing months do: 194 account-months contain invoices from 2 subscriptions (old term's last bill + new term's first bill in the same calendar month).
- **Advance billing:** 307 invoices are dated up to 29 days before `start_date`, but never in an earlier *calendar month* — so invoice-month bucketing is safe.
- **Amounts are ~constant per subscription** (no sub varies >5% between min and max invoice).

## Decisions (made interactively, in order)

1. **Fact grain = monthly snapshot.** `fct_subscription_months`: one row per subscription per active month. Directly answers "subscriptions as of any given month"; GRR becomes a self-join. Rejected: invoice-grain fact (pushes as-of logic onto analysts), SCD2 ranges (error-prone range joins, revenue still separate).
2. **Customer = Subskribe billing account**, enriched with HubSpot attributes via `crmid`, resolving `hsold_*` IDs through `merged_object_ids`. The 2 `hsmissing_*` accounts stay in the dim with `size_grouped = 'Unknown'` — revenue stays complete, the gap stays visible. Account grain is load-bearing for GRR: subscription IDs change on renewal (`renewed_from` chains), but the paying entity persists, so the cohort survives renewals. Rejected: company grain (1:1 here, adds a hop, and 2 accounts have no company row), excluding unmatched accounts (silent revenue loss).
3. **Separate `dim_subscriptions`** holds static subscription attributes and renewal lineage; the fact stays narrow (keys + month + measures). "A dim/fact pair" is a minimum, not a maximum.
4. **Voided months = invoiced truth + flag.** `revenue_nzd` sums non-voided (PAID + POSTED) invoices only; a voided month keeps its fact row with revenue 0 and `voided_invoice_count = 1`. The fact reconciles exactly to the billing system; no imputed numbers. Rejected: carry-forward fill (manufactures revenue never invoiced), dual measures (invites inconsistent consumption — the problem this project exists to kill).
5. **PAID + POSTED both count as revenue.** GRR measures retention of billing relationships, not cash collection; POSTED clusters in recent months and excluding it would fake churn cliffs. The billed-vs-collected distinction belongs in a future invoice-grain fact, not extra columns here. Invoice `status` is kept and tested in staging; it surfaces in the fact only via the measures.
6. **"Last 12 months" anchored on the data horizon** (`MAX(invoice month)` = 2026-05), not `current_date` — `dbt build` produces identical numbers whenever it runs.

## Architecture

```
sources (raw.*)
   │
staging — views, 1:1 with sources, rename/cast/typed
   ├─ stg_hubspot__companies
   ├─ stg_subskribe__accounts
   ├─ stg_subskribe__subscriptions
   └─ stg_subskribe__invoices
   │
intermediate — tables, business logic
   ├─ int_company_id_map          (live IDs ∪ exploded merged_object_ids → surviving company)
   └─ int_subscription_months     (bounded month spine per subscription + monthly invoice aggregates)
   │
marts — tables
   ├─ core/
   │   ├─ dim_customers
   │   ├─ dim_subscriptions
   │   └─ fct_subscription_months
   └─ reporting/
       └─ rpt_grr_by_size_segment
```

- Materialization: staging inherits project default (`view`); intermediate and marts configured as `table` (user decision during execution — intermediate holds the month spine the fact builds on).
- Packages: `dbt_utils` only (`generate_surrogate_key`, test helpers). Requires `dbt deps`.
- Naming: dbt standard `stg_<source>__<entity>`, `int_`, `dim_`/`fct_`/`rpt_` prefixes.

## Model contracts

### `dim_customers` — grain: billing account (122 rows)

| Column | Notes |
|---|---|
| `customer_key` | surrogate key from `account_id` (PK) |
| `account_id` | natural key |
| `company_id` | resolved HubSpot id via merge map; NULL for the 2 unmatched |
| `customer_name` | HubSpot company name, fallback to account name |
| `account_name` | Subskribe billing name |
| `size_grouped` | Enterprise / Mid-Market / SMB / Startup / **Unknown** |
| `industry`, `country` | from HubSpot, NULL when unmatched |
| `billing_currency` | from account |
| `crm_match_status` | `matched` / `merged_resolved` / `unmatched` — data quality made queryable |
| `account_created_at`, `company_created_at` | |

### `dim_subscriptions` — grain: subscription (330 rows)

| Column | Notes |
|---|---|
| `subscription_key` | surrogate key from `subscription_id` (PK) |
| `subscription_id` | natural key |
| `customer_key` | FK → `dim_customers` |
| `subscription_state` | current state: ACTIVE / CANCELED / EXPIRED |
| `start_date`, `end_date`, `cancelled_date` | |
| `renewed_from_subscription_id` | renewal lineage |
| `is_renewal` | `renewed_from_subscription_id IS NOT NULL` |

### `fct_subscription_months` — grain: subscription × active month (~3.4k rows)

| Column | Notes |
|---|---|
| `subscription_month_key` | surrogate key from (`subscription_id`, `month_start_date`) (PK) |
| `month_start_date` | first day of month |
| `subscription_key` | FK → `dim_subscriptions` |
| `customer_key` | FK → `dim_customers` (denormalized for one-join analysis) |
| `revenue_nzd` | non-voided (PAID + POSTED) invoiced NZD in that calendar month |
| `invoice_count` | non-voided invoices that month |
| `voided_invoice_count` | voided invoices that month |

Spine per subscription: `date_trunc(month, start_date)` → `LEAST(date_trunc(month, end_date), date_trunc(month, cancelled_date), horizon)` where horizon = `MAX(invoice month)` across all invoices.

### `rpt_grr_by_size_segment` — grain: month × size segment (last 12 months)

Logic, per Tracksuit's working definition:

1. Aggregate fact to customer-month (`SUM(revenue_nzd)` — renewal boundary months legitimately sum two subscriptions).
2. For each month M in the last 12 (anchored at horizon): cohort = customers with revenue > 0 at M-12.
3. Retained revenue per cohort customer = `LEAST(rev_M, rev_M-12)` — the cap; missing at M counts as 0.
4. `grr_pct = SUM(retained) / SUM(rev_M-12) * 100`, grouped by `size_grouped`.

Cohort membership and cap read the same measure (`revenue_nzd`). The `Unknown` segment **is included** in the output where its customers have cohort revenue — revenue is never silently dropped from a retention report, and the row is an actionable flag (fix the CRM links and it disappears).

| Column | Notes |
|---|---|
| `month_start_date` + `size_grouped` | composite grain (PK tested as combination). **Sparse:** a row exists only where the segment had cohort revenue at M-12 — `grr_pct` is never NULL/divide-by-zero; an absent row means "GRR undefined here", documented in `schema.yml` |
| `cohort_customer_count` | customers paying at M-12 |
| `cohort_revenue_nzd` | denominator |
| `retained_revenue_nzd` | capped numerator |
| `grr_pct` | |

## Testing

- **Every model:** `unique` + `not_null` on its PK (composite via `dbt_utils.unique_combination_of_columns` for the reporting model).
- **Relationships:** fact → both dims; `dim_subscriptions` → `dim_customers`; staging invoices/subscriptions → parent accounts.
- **`accepted_values`:** `subscription_state`, invoice `status`, `size_grouped` (incl. `Unknown`) — early warning if the source vocabulary grows.
- **Singular reconciliation test:** `SUM(fct_subscription_months.revenue_nzd)` equals `SUM(raw non-voided invoice total_nzd)` — proves the fact loses nothing.
- **GRR sanity:** `grr_pct <= 100` via `dbt_utils.expression_is_true` (the cap guarantees it; the test proves it).

## Documentation deliverables

- `schema.yml` per layer: every model and column described.
- **`SUBMISSION.md`:** how to run; key assumptions (decisions 1–6 above); data quality notes (merged/missing CRM ids, voided one-month holes, renewal double-billing months — capped on the numerator side, noted as a small denominator effect; advance billing).
- **`PROMPTS.md`:** the prompts from this session that shaped real decisions (grain choice, gap investigation that redefined the spine, voided handling, status-column discussion, grilling session). AI drafts it at the end of implementation as prompt → decision shaped → how the output was verified; the candidate reviews and edits before committing.

## Out of scope

- Carry-forward / MRR normalization engines.
- Invoice-grain AR/collections fact (noted as the future home of PAID vs POSTED splits).
- Snapshots/SCD2 of `size_grouped` (source has no history; current value applied to all months — documented assumption).
- Overall/total GRR row (brief asks by segment only).

## Reproducibility contract

From a fresh clone: `python load_raw_data.py` → `dbt deps` → `dbt build` must succeed end-to-end with all tests passing, producing identical reporting numbers regardless of run date.
