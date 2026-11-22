{{ config(materialized='table', schema='dw') }}
select
    provider_id as provider_key,
    provider_id,
    provider_number,
    provider_name,
    npi,
    specialty,
    practice_name,
    state_code,
    provider_status,
    created_at,
    updated_at
from {{ ref('stg_providers') }}
