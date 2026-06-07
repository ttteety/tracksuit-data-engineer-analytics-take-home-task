-- Monthly snapshot fact. Grain: subscription x active calendar month (3,594 rows).
-- Row existence answers "was this subscription active in month M" — no date-range
-- logic needed by consumers. revenue_nzd reconciles exactly to non-voided source
-- invoices (enforced by tests/assert_fct_revenue_reconciles_to_invoices.sql).

with subscription_months as (

    select * from {{ ref('int_subscription_months') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['subscription_id', 'month_start_date']) }} as subscription_month_key,
    month_start_date,
    {{ dbt_utils.generate_surrogate_key(['subscription_id']) }} as subscription_key,
    subscription_id,
    {{ dbt_utils.generate_surrogate_key(['account_id']) }} as customer_key,
    account_id,
    revenue_nzd,
    invoice_count,
    voided_invoice_count
from subscription_months
