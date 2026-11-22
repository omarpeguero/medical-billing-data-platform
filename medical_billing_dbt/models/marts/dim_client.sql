{{ config(materialized='table', schema='dw') }}
select
    client_id as client_key,
    client_id,
    client_number,
    first_name,
    last_name,
    concat(first_name, ' ', last_name) as client_name,
    date_of_birth,
    state_code,
    postal_code,
    client_status,
    created_at,
    updated_at
from {{ ref('stg_clients') }}
