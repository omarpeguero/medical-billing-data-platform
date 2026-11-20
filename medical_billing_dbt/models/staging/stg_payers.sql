select
    payer_id,
    payer_code,
    payer_name,
    payer_type,
    created_at,
    updated_at
from {{ source('emr', 'payers') }}
where is_deleted = 0
