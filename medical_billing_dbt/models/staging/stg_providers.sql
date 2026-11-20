select
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
from {{ source('emr', 'providers') }}
where is_deleted = 0
