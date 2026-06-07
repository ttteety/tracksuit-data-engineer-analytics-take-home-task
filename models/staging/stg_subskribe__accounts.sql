with source as (

    select * from {{ source('subskribe', 'subskribe_accounts') }}

),

renamed as (

    select
        account_id,
        company_name as account_name,
        crmid as crm_company_id,
        currency as billing_currency,
        cast(created_at as date) as created_at

    from source

)

select * from renamed
