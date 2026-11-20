{{ config(materialized='table', schema='dw') }}
select payer_id as payer_key, payer_id, payer_code, payer_name, payer_type, created_at, updated_at
from {{ ref('stg_payers') }}
