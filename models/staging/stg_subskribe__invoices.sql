with source as (

    select * from {{ source('subskribe', 'subskribe_invoices') }}

),

renamed as (

    select
        invoice_id,
        account_id,
        subscription_id,
        cast(invoice_date as date) as invoice_date,
        cast(total as decimal(18, 2)) as total_amount,
        cast(total_nzd as decimal(18, 2)) as total_nzd,
        currency as invoice_currency,
        status

    from source

)

select * from renamed
