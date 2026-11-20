select
    claim_id,
    claim_number,
    client_id,
    provider_id,
    payer_id,
    claim_type,
    claim_status,
    first_submitted_at,
    last_submitted_at,
    payer_claim_number,
    created_at,
    updated_at
from {{ source('emr', 'claims') }}
where is_deleted = 0
