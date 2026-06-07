-- Monthly Gross Revenue Retention by customer size segment, last 12 months.
-- Tracksuit's working definition: for month M, the cohort is customers with
-- revenue > 0 at M-12; each cohort customer's month-M revenue is capped at their
-- M-12 amount (the cap excludes expansion, making retention "gross");
-- GRR = sum(capped revenue at M) / sum(revenue at M-12), per segment.
--
-- The window anchors on the data horizon (latest fact month), not current_date,
-- so dbt build produces identical numbers whenever it runs. Output is sparse:
-- a (month, segment) row exists only where the segment had cohort revenue at
-- M-12 — grr_pct is never NULL and never divides by zero.

with subscription_months as (

    select * from {{ ref('fct_subscription_months') }}

),

customers as (

    select * from {{ ref('dim_customers') }}

),

customer_months as (

    select
        customer_key,
        month_start_date,
        sum(revenue_nzd) as revenue_nzd
    from subscription_months
    group by 1, 2

),

data_horizon as (

    select max(month_start_date) as horizon_month
    from subscription_months

),

report_months as (

    select cast(gs.generate_series as date) as month_start_date
    from data_horizon
    cross join generate_series(
        horizon_month - interval 11 month,
        horizon_month,
        interval 1 month
    ) as gs

),

cohort as (

    -- customers paying at M-12, with their baseline (denominator) revenue
    select
        report_months.month_start_date,
        customer_months.customer_key,
        customer_months.revenue_nzd as cohort_revenue_nzd
    from report_months
    inner join customer_months
        on customer_months.month_start_date
            = cast(report_months.month_start_date - interval 12 month as date)
    where customer_months.revenue_nzd > 0

),

retained as (

    -- month-M revenue per cohort customer, capped at the M-12 baseline;
    -- a customer with no month-M revenue contributes 0 (churn)
    select
        cohort.month_start_date,
        cohort.customer_key,
        cohort.cohort_revenue_nzd,
        least(
            coalesce(customer_months.revenue_nzd, 0),
            cohort.cohort_revenue_nzd
        ) as retained_revenue_nzd
    from cohort
    left join customer_months
        on customer_months.customer_key = cohort.customer_key
        and customer_months.month_start_date = cohort.month_start_date

)

select
    retained.month_start_date,
    customers.size_grouped,
    count(distinct retained.customer_key) as cohort_customer_count,
    sum(retained.cohort_revenue_nzd) as cohort_revenue_nzd,
    sum(retained.retained_revenue_nzd) as retained_revenue_nzd,
    round(100.0 * sum(retained.retained_revenue_nzd) / sum(retained.cohort_revenue_nzd), 2) as grr_pct
from retained
inner join customers
    on retained.customer_key = customers.customer_key
group by 1, 2
