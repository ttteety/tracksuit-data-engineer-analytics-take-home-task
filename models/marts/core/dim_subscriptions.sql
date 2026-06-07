-- Subscription dimension: static attributes and renewal lineage. Grain: subscription
-- (330 rows). Renewals are new subscription rows chained via
-- renewed_from_subscription_id; the chain never overlaps in dates. The customer_key
-- hash matches dim_customers by construction (same surrogate-key input).

with subscriptions as (

    select * from {{ ref('stg_subskribe__subscriptions') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['subscription_id']) }} as subscription_key,
    subscription_id,
    {{ dbt_utils.generate_surrogate_key(['account_id']) }} as customer_key,
    account_id,
    subscription_state,
    start_date,
    end_date,
    cancelled_date,
    renewed_from_subscription_id,
    renewed_from_subscription_id is not null as is_renewal
from subscriptions
