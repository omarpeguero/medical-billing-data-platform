select
    adjustment_id,
    claim_line_id,
    cast(adjustment_date as date) as adjustment_date,
    posted_at,
    adjustment_type,
    cast(amount as decimal(18,2)) as amount,
    adjustment_group_code,
    adjustment_reason_code,
    description,
    original_adjustment_id,
    created_at,
    updated_at
from {{ source('emr', 'adjustments') }}
where is_deleted = 0
