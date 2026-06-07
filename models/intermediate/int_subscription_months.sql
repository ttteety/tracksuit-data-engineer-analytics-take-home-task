-- One row per subscription per active calendar month. The spine runs from the start
-- month to the earliest of: end month, cancelled month, data horizon (latest invoice
-- month — complete, since all billing happens on days 1-6). Verified: this spine has
-- exactly 113 zero-revenue months, all explained by VOIDED invoices, and drops no
-- non-voided invoice (enforced downstream by a reconciliation test on the fact).
-- Revenue is invoiced truth, never imputed — see docs/adr/0001.

with subscriptions as (

    select * from {{ ref('stg_subskribe__subscriptions') }}

),

invoices as (

    select * from {{ ref('stg_subskribe__invoices') }}

),

data_horizon as (

    select date_trunc('month', max(invoice_date)) as horizon_month
    from invoices

),

month_spine as (

    select
        s.subscription_id,
        s.account_id,
        cast(gs.generate_series as date) as month_start_date
    from subscriptions as s
    cross join data_horizon as h
    cross join generate_series(
        date_trunc('month', s.start_date),
        -- cap at scheduled end, actual cancellation (coalesce handles the NULL
        -- cancelled_date of non-cancelled subscriptions), and the data horizon
        least(
            date_trunc('month', s.end_date),
            date_trunc('month', coalesce(s.cancelled_date, s.end_date)),
            h.horizon_month
        ),
        interval 1 month
    ) as gs

),

invoice_months as (

    select
        subscription_id,
        cast(date_trunc('month', invoice_date) as date) as month_start_date,
        -- whitelist, not "!= 'VOIDED'": revenue means exactly PAID + POSTED, so a
        -- future unknown status can never silently count as revenue
        sum(total_nzd) filter (where status in ('PAID', 'POSTED')) as revenue_nzd,
        count(*) filter (where status in ('PAID', 'POSTED')) as invoice_count,
        count(*) filter (where status = 'VOIDED') as voided_invoice_count
    from invoices
    group by 1, 2

)

select
    month_spine.subscription_id,
    month_spine.account_id,
    month_spine.month_start_date,
    coalesce(invoice_months.revenue_nzd, 0) as revenue_nzd,
    coalesce(invoice_months.invoice_count, 0) as invoice_count,
    coalesce(invoice_months.voided_invoice_count, 0) as voided_invoice_count
from month_spine
left join invoice_months
    on month_spine.subscription_id = invoice_months.subscription_id
    and month_spine.month_start_date = invoice_months.month_start_date
