select
    payment_id,
    claim_line_id,
    payer_id,
    payment_source,
    cast(payment_date as date) as payment_date,
    posted_at,
    cast(amount as decimal(18,2)) as amount,
    transaction_type,
    reference_number,
    original_payment_id,
    created_at,
    updated_at
from {{ source('emr', 'payments') }}
where is_deleted = 0
