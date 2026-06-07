# Monthly revenue is invoiced truth, never imputed

`fct_subscription_months.revenue_nzd` is the sum of non-voided (PAID + POSTED) invoices
bucketed by invoice calendar month — nothing more. 113 active subscription-months contain
only a VOIDED invoice that was never re-issued; those months get a fact row with revenue 0
and `voided_invoice_count = 1`, so a paying customer's revenue can legitimately drop to
zero for exactly one month. This is deliberate: the fact reconciles exactly to the billing
system (enforced by a singular test), which is what makes it trustworthy as a
source-of-truth foundation.

## Considered Options

- **Carry-forward fill** — copy the prior month's amount into voided months. Smoother GRR,
  but manufactures revenue that was never invoiced and breaks reconciliation to Subskribe.
- **Dual measures** (`invoiced_revenue_nzd` + `revenue_nzd_filled`) — consumers would pick
  inconsistently, recreating the "different teams get different answers" problem this
  project exists to eliminate.

## Consequences

- GRR shows small genuine dips where cohort customers hit a voided month (~3 per calendar
  month across 122 customers). These are honest artifacts of the billing data, not bugs.
- A customer whose M-12 month was voided drops out of that month's GRR cohort (revenue 0
  at M-12 → contributes nothing to numerator or denominator).
- If finance ever decides voids are billing errors to be smoothed, that belongs in a new,
  clearly-named downstream measure — not a redefinition of `revenue_nzd`.
