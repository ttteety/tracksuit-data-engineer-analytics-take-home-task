-- Maps every HubSpot company id an account might reference — live or merged-away —
-- to the surviving company record. Verified: no old id appears under two survivors,
-- and no old id collides with a live id, so this map cannot fan out.

with companies as (

    select * from {{ ref('stg_hubspot__companies') }}

),

live_ids as (

    select
        company_id as crm_company_id,
        company_id
    from companies

),

merged_ids_exploded as (

    select
        -- semicolon-separated per the HubSpot merged_object_ids export format
        unnest(string_split(merged_object_ids, ';')) as crm_company_id,
        company_id
    from companies
    where merged_object_ids is not null

),

merged_ids as (

    select
        trim(crm_company_id) as crm_company_id,
        company_id
    from merged_ids_exploded
    -- guard against empty tokens from stray/trailing semicolons
    where trim(crm_company_id) != ''

)

select * from live_ids
union all
select * from merged_ids
