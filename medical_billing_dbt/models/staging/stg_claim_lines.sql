select
    claim_line_id,
    claim_id,
    billing_entry_id,
    line_number,
    cast(billed_amount as decimal(18,2)) as billed_amount,
    cast(allowed_amount as decimal(18,2)) as allowed_amount,
    cast(patient_responsibility_amount as decimal(18,2)) as patient_responsibility_amount,
    line_status,
    created_at,
    updated_at
from {{ source('emr', 'claim_lines') }}
where is_deleted = 0
