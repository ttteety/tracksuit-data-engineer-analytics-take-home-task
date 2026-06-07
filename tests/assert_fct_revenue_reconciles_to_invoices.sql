-- The fact must reconcile exactly to the billing system: total fact revenue equals
-- the total of all non-voided source invoices. The fact computes revenue via a
-- PAID/POSTED whitelist, so this blacklist-based check also fails loudly if an
-- unknown new invoice status ever appears. Returns rows (= fails) on mismatch.

with fct_total as (

    -- coalesce: an empty fact must FAIL this test, not vacuously pass it
    select coalesce(sum(revenue_nzd), 0) as total_nzd
    from {{ ref('fct_subscription_months') }}

),

invoice_total as (

    select coalesce(sum(cast(total_nzd as decimal(18, 2))), 0) as total_nzd
    from {{ source('subskribe', 'subskribe_invoices') }}
    where status != 'VOIDED'

)

select
    fct_total.total_nzd as fct_total_nzd,
    invoice_total.total_nzd as invoice_total_nzd
from fct_total
cross join invoice_total
where abs(fct_total.total_nzd - invoice_total.total_nzd) > 0.005
