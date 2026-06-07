-- Customer = the paying entity: a Subskribe billing account enriched with HubSpot
-- attributes. Grain: account (122 rows). The 2 accounts whose crm id is genuinely
-- unmatchable stay in the dim with size_grouped = 'Unknown' — revenue is never
-- silently dropped, and crm_match_status makes the data quality story queryable.

with accounts as (

    select * from {{ ref('stg_subskribe__accounts') }}

),

companies as (

    select * from {{ ref('stg_hubspot__companies') }}

),

id_map as (

    select * from {{ ref('int_company_id_map') }}

),

resolved as (

    select
        accounts.account_id,
        accounts.account_name,
        accounts.billing_currency,
        accounts.created_at as account_created_at,
        accounts.crm_company_id,
        id_map.company_id
    from accounts
    left join id_map
        on accounts.crm_company_id = id_map.crm_company_id

)

select
    {{ dbt_utils.generate_surrogate_key(['resolved.account_id']) }} as customer_key,
    resolved.account_id,
    resolved.company_id,
    coalesce(companies.company_name, resolved.account_name) as customer_name,
    resolved.account_name,
    coalesce(companies.size_grouped, 'Unknown') as size_grouped,
    companies.industry,
    companies.country,
    resolved.billing_currency,
    case
        when resolved.company_id is null then 'unmatched'
        when resolved.company_id = resolved.crm_company_id then 'matched'
        else 'merged_resolved'
    end as crm_match_status,
    resolved.account_created_at,
    companies.created_at as company_created_at
from resolved
left join companies
    on resolved.company_id = companies.company_id
