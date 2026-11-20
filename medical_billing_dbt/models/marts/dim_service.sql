{{ config(materialized='table', schema='dw') }}
select service_code_id as service_key, service_code_id, code_system, procedure_code,
    description as service_description, unit_type, default_charge_per_unit,
    effective_from, effective_to, created_at, updated_at
from {{ ref('stg_service_codes') }}
