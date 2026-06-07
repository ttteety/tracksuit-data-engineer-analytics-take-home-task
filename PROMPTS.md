# AI Prompts That Shaped This Submission

Built with Claude Code. This is not a transcript — it's the prompts that shaped real
decisions, with how each output was verified before I trusted it.

## 1. Structured brainstorm before any code

> *"I am working on the assignment task as part of the Tracksuit recruitment process.
> Please read the README and start planning on this together."*

**What it shaped:** Instead of generating a project immediately, the AI profiled the
raw data first (row counts, PK uniqueness, orphan FKs, status distributions,
merged-id resolution) and then forced the big design decisions as explicit
multiple-choice trade-offs: fact grain (monthly snapshot vs invoice-grain vs SCD2),
customer entity (billing account vs HubSpot company), dimension scope (separate
dim_subscriptions vs inline attributes), and voided-invoice handling. The rejected
alternatives and reasons are recorded in the design spec and ADR.

**How I verified:** every profiling claim (e.g. "11 of 13 unmatched crmids resolve
via merged_object_ids") was a re-runnable query, and the numbers became hard
expectations in the implementation plan — a wrong claim would have failed a later
verification step loudly.

## 2. The challenge that redefined the fact's spine

> *(AI advisor review of the draft design)* "You verified ≤1 invoice per
> subscription-month. You did **not** verify ≥1 — if active months have invoice
> gaps, GRR's cohort and cap silently distort."

**What it shaped:** The most important correction of the project. A naive spine
(start_date → end_date) showed 614 "gap" months. Investigation revealed the
monotonic gap pattern was future months of ACTIVE subscriptions beyond the May-2026
data horizon, plus post-cancellation months. Bounding the spine to
LEAST(end month, cancelled month, data horizon) left exactly 113 gaps — 100%
explained by voided invoices. That bounded spine became `int_subscription_months`.

**How I verified:** the bounded spine was re-checked to lose zero non-voided
invoices, and that property is now permanently enforced by
`tests/assert_fct_revenue_reconciles_to_invoices.sql`.

## 3. Voided months: truth vs smoothing

> *"How should the 113 voided-invoice months be treated in the fact's revenue
> measure?"* (presented options: invoiced truth + flag / carry-forward fill /
> dual measures)

**What it shaped:** Chose invoiced truth — revenue 0 plus a `voided_invoice_count`
flag. Rejected carry-forward (manufactures revenue never invoiced) and dual measures
(two revenue columns on a foundational fact recreates the inconsistent-answers
problem the project exists to kill). Recorded as
`docs/adr/0001-monthly-revenue-is-invoiced-truth.md` because a future reader will
see a paying customer drop to zero for exactly one month and assume a bug.

**How I verified:** all 113 voided invoices sit alone in their months (never
re-issued), confirmed by query; the fact's total reconciles to the cent against
non-voided invoices ($7,904,203.40).

## 4. My challenge to the AI: "should we keep the invoice status column?"

**What it shaped:** Clarified layer responsibilities — `status` is kept and tested
(`not_null` + `accepted_values`) in staging as an early-warning system for new
statuses, drives the revenue filter in intermediate, and surfaces in the fact only
as measures. It also surfaced the PAID vs POSTED decision (both count: GRR measures
retention of billing relationships, not cash collection) and the explicit decision
NOT to split them into separate measures.

**How I verified:** POSTED's clustering in recent months was confirmed by a
month-distribution query before deciding it counts as revenue — excluding it would
have faked churn cliffs in the latest GRR months.

## 5. Grilling session against the written spec

> *"Interview me relentlessly about every aspect of this plan until we reach a
> shared understanding."*

**What it shaped:** Six resolutions before any code: surrogate keys generated in
marts (the project instructions contradicted the spec — the instructions were
amended); the Unknown segment included in report output; the fact kept narrow (row
existence = active, no derivable lifecycle flags); the revenue ADR; the sparse
report contract (no NULL grr_pct, no divide-by-zero); and this file's
draft-then-edit workflow.

**How I verified:** the grill produced three new data checks — May 2026 is a
complete billing month, the merge map cannot fan out (19 old ids, no duplicates, no
live-id collisions), and no subscription starts beyond the horizon.

## 6. Independent review agents on every implementation task

Each model was built by one AI agent and then reviewed by two separate ones (spec
compliance, then code quality) with fresh context. Real catches that changed the
code:

- **Revenue filter flipped from blacklist to whitelist** (`status != 'VOIDED'` →
  `status IN ('PAID', 'POSTED')`): an unknown future status can now never silently
  count as revenue. Combined with the blacklist-based reconciliation test, a new
  status trips two alarms.
- **NULL-safety hole in the reconciliation test:** with an empty fact,
  `SUM(...)` returns NULL and `abs(NULL - x) > 0.005` is never true — the test would
  have vacuously passed on the exact failure it exists to catch. Fixed with
  `coalesce(..., 0)`.
- **A factual error in my own docs:** the fact-checking pass on SUBMISSION.md
  re-derived every number and caught that invoices bill on days 1–6, not 1–7 as I'd
  written from an earlier bucketed profile.
- Renewal-chain referential integrity test, empty-token guard in the merge-id
  explosion, and `count(distinct ...)` for self-documenting cohort counts.

**How I verified:** every reviewer claim was re-run against the database before
accepting the fix; review suggestions that conflicted with deliberate decisions
(e.g. migrating to dbt 1.11-only test syntax) were rejected, with the reasoning kept.

## What was delegated vs owned

Delegated to AI: data profiling queries, SQL drafting, schema.yml drafting,
review passes, this file's draft. Owned by me: every design decision above (made as
explicit choices among presented trade-offs), the final review of all committed
code, and all commits.
