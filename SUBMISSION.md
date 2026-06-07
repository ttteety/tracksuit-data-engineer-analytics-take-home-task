# Submission Notes

## How to run

```bash
python3 -m venv .venv && source .venv/bin/activate   # Windows PowerShell: .\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python3 load_raw_data.py    # load raw CSVs into tracksuit.duckdb
dbt deps                    # installs dbt_utils
dbt build                   # builds all models and runs all tests
```

`dbt build` creates 10 models across the `staging`, `intermediate`, and `marts` schemas and runs 73 tests. The
reporting model is `marts.rpt_grr_by_size_segment` — monthly GRR by customer
size segment for the 12 months ending at the data horizon (May 2026). Numbers are
identical regardless of when you run it (see assumption 6).

## Project structure

- **staging** (views) — 1:1 typed views over the four raw tables. No business logic,
  no derived columns.
- **intermediate** (tables) — `int_company_id_map` (CRM merge resolution) and
  `int_subscription_months` (bounded month spine + monthly invoice aggregates).
- **marts/core** (tables) — the dimensional model: `dim_customers` (grain: billing
  account), `dim_subscriptions` (grain: subscription), `fct_subscription_months`
  (grain: subscription × active month). Surrogate keys are generated here.
- **marts/reporting** (tables) — `rpt_grr_by_size_segment`, built only on the
  dim/fact.

## Key assumptions

1. **Customer = Subskribe billing account.** It's the paying entity, and it persists
   across renewals (subscription IDs change via `renewed_from_subscription_id`; the
   account doesn't). GRR cohorts therefore survive renewals by construction.
2. **Monthly revenue = non-voided (PAID + POSTED) invoiced NZD, bucketed by invoice
   calendar month.** POSTED counts: GRR measures retention of billing relationships,
   not cash collection, and POSTED clusters in recent months — excluding it would
   fake churn cliffs. See `docs/adr/0001-monthly-revenue-is-invoiced-truth.md`.
3. **A subscription's active window** runs from its start month to the earliest of
   end month, cancelled month, and the data horizon. Verified: bounded this way, the
   spine loses zero non-voided invoices and its only zero-revenue months are the 113
   voided-invoice months.
4. **Unmatchable CRM links become an 'Unknown' segment.** 11 of 13 non-matching
   `crmid`s resolve through `merged_object_ids`; the remaining 2 (`hsmissing_*`) stay
   in the model with `size_grouped = 'Unknown'` rather than being dropped — their
   revenue is real, and the Unknown row in the report is an actionable flag.
5. **`size_grouped` is treated as static** (HubSpot provides no history), so the
   current segment applies to all months. The report answers "GRR by current
   segment", not "segment at the time".
6. **"Last 12 months" anchors on the data horizon** (`MAX(invoice month)` = May
   2026), not `current_date`, so the build is reproducible. May 2026 is a complete
   billing month — every invoice in the data is issued on days 1–6 of its month.
7. **The GRR report is sparse by contract:** a (month, segment) row exists only where
   the segment had cohort revenue at M-12, so `grr_pct` is never NULL and never
   divides by zero. (In the current data every segment has a cohort every month, so
   all 60 rows happen to exist.)
8. **All revenue measures are NZD** (Tracksuit's functional currency, per the brief).
   Multi-currency reporting is deliberately out of scope: the data contains no
   exchange-rate source (only per-invoice implicit rates), and deriving rates from
   them would manufacture numbers. The extension point is preserved — staging keeps
   `total_amount` + `invoice_currency`, and the account's `billing_currency` is on
   `dim_customers` — so adding an fx-rate dimension later is an intermediate-layer
   change, not a remodel.
9. **Reusability:** I deliberately modeled a monthly subscription fact table because GRR is only one retention metric.
   The same model can be reused to calculate churn, NRR (Net Revenue Retention), cohort retention, customer lifecycle
   metrics, and revenue trend analysis.
10. **FX fluctuations** Revenue retention is calculated using `revenue_nzd` as it is Tracksuit's functional currency.
    This approach reflects retained reported revenue but may be affected by FX flucations. If the business wises to
    isolate customer retention from currency movements, GRR could alternatively be calculated in local currency
    and then aggregated at the currency level (assuming that each company only invoice with one local currency).
11. If `size_grouped` is used for historical performance analysis, it could be treated as a slowly changing dimension in `dim_customers`
    and implemented as Type 2 to preserve point-in-time correctness. If it is purely descriptive for current-state reporting,
    Type 1 overwrite is sufficient.

## Data quality notes

- **Merged CRM ids:** 11 accounts pointed at merged-away HubSpot ids — resolved by
  exploding `merged_object_ids` (no ambiguity: no old id maps to two survivors).
  2 accounts point at ids that don't exist anywhere; they're kept with
  `crm_match_status = 'unmatched'`.
- **Voided invoices (113):** each sits alone in its month and was never re-issued, so
  each is a one-month revenue hole for an otherwise continuously billed subscription.
  Kept as honest zeros (flagged via `voided_invoice_count`), never imputed.
- **Renewal boundary double-billing:** 194 customer-months contain invoices from two
  subscriptions (old term's last bill + new term's first). Kept as invoiced truth;
  the GRR cap absorbs the numerator side, and the small denominator-side inflation is
  accepted and documented rather than smoothed.
- **Advance billing:** 307 invoices are dated up to 29 days before their
  subscription's `start_date` but never in an earlier calendar month, so
  invoice-month bucketing is safe.
- The fact reconciles exactly to the billing system — enforced by
  `tests/assert_fct_revenue_reconciles_to_invoices.sql` (total fact revenue = total
  non-voided invoice NZD = $7,904,203.40). This is a deliberate fail-fast contract:
  on a live Fivetran feed, a PAID/POSTED invoice landing outside its subscription's
  active window (after `end_date`/`cancelled_date`) would fail the build rather than
  silently dropping revenue — the right behaviour for a source-of-truth fact.
