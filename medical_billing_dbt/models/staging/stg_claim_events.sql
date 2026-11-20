select
    claim_event_id,
    claim_id,
    claim_line_id,
    event_type,
    event_at,
    reason_code,
    reason_description,
    submission_reference,
    notes,
    created_at,
    updated_at
from {{ source('emr', 'claim_events') }}
where is_deleted = 0
