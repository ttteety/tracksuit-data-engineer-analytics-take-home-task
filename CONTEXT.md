# Tracksuit Subscriptions Analytics

Dimensional model of customer subscriptions over time (dbt + DuckDB), built to be the
source of truth for revenue retention reporting — starting with GRR by size segment.

## Language

**Customer**:
The paying entity — a Subskribe billing account enriched with HubSpot company attributes.
_Avoid_: account (source-system term), company (the HubSpot record, not the payer)

**Subscription**:
A single billed term for a Customer; renewals create a new Subscription linked to its predecessor via `renewed_from_subscription_id`.
_Avoid_: contract, deal

**Renewal chain**:
The lineage of Subscriptions connected by `renewed_from_subscription_id`; chains never overlap in dates.

**Active month**:
A calendar month within a Subscription's window: start month → earliest of end month, cancelled month, Data horizon.

**Monthly revenue**:
Non-voided (PAID + POSTED) invoiced NZD, bucketed by invoice calendar month. Never imputed.
_Avoid_: MRR (implies normalization we don't do), collected revenue (cash basis)

**Voided month**:
An Active month whose only invoice was VOIDED — revenue 0, flagged, never re-billed. 113 exist.

**Data horizon**:
The latest complete invoice month in the data (`MAX(invoice month)`); complete because all billing happens on days 1–6.

**Size segment**:
`size_grouped` from HubSpot: Enterprise / Mid-Market / SMB / Startup / **Unknown** (Customers whose CRM link is unresolvable). Unknown appears in reporting output.

**Cohort (GRR)**:
For month M: the Customers with Monthly revenue > 0 at M-12. Fixed at M-12; later acquisitions never join.

**Retained revenue**:
A cohort Customer's month-M revenue capped at their M-12 amount: `LEAST(rev_M, rev_M-12)`. The cap is what makes retention "gross".

**GRR**:
`SUM(Retained revenue) / SUM(cohort revenue at M-12)` per Size segment, as a percentage.

## Relationships

- A **Customer** has one or more **Subscriptions**; a **Subscription** belongs to exactly one **Customer**
- A **Subscription** has at most one invoice per calendar month (verified)
- A **Renewal chain** preserves the **Customer** — subscription IDs change, the payer does not
- **GRR cohort** identity is the **Customer**, so retention survives renewals by construction

## Example dialogue

> **Dev:** "This Customer's subscription ID changed in January — did we lose them from the cohort?"
> **Domain expert:** "No — that's a **Renewal chain**. The **Customer** kept paying, so they're retained. Cohorts track Customers, not Subscriptions."
> **Dev:** "And their February invoice was VOIDED?"
> **Domain expert:** "Then February is a **Voided month** — revenue 0, flagged, not imputed. If February was their M-12, they drop out of that **Cohort**."

## Flagged ambiguities

- "customer" vs "account" vs "company" — resolved: **Customer** = the billing account (the payer); HubSpot company is an attribute source only. Two Customers have no company link at all.
- "revenue in a month" — resolved: invoiced (billed) basis, not cash collected, not normalized MRR.
- Surrogate keys — resolved: generated in marts where each model's grain is defined, not in staging (CLAUDE.md updated to match).
