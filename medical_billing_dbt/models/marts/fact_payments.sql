{{ config(materialized='incremental', incremental_strategy='merge', unique_key='payment_id', schema='dw', on_schema_change='fail') }}
-- Grain: one posted payment/reversal transaction. Signed amount is preserved.
select p.payment_id, p.claim_line_id, f.claim_id, f.billing_entry_id,
    f.client_id as client_key, f.provider_id as provider_key,
    f.service_code_id as service_key, f.payer_id as claim_payer_key,
    p.payer_id as payment_payer_key,
    cast(convert(char(8), p.payment_date,112) as int) as payment_date_key,
    p.payment_date, p.posted_at, p.payment_source, p.transaction_type,
    p.amount, p.reference_number, p.original_payment_id, p.created_at, p.updated_at,
    changes._source_change_at as _source_change_at
from {{ ref('stg_payments') }} p
left join {{ ref('int_claim_line_financials') }} f on p.claim_line_id = f.claim_line_id
left join {{ ref('stg_claim_lines') }} cl on p.claim_line_id=cl.claim_line_id
left join {{ ref('stg_claims') }} c on cl.claim_id=c.claim_id
left join {{ ref('stg_billing_entries') }} be on cl.billing_entry_id=be.billing_entry_id

cross apply (select max(x.val) as _source_change_at from (values (p.updated_at),(cl.updated_at),(c.updated_at),(be.updated_at)) as x(val)) changes
{% if is_incremental() %}
cross join (select (select dateadd(day,-2,coalesce(max(_source_change_at), cast('1900-01-01' as datetime2))) from {{ this }}) as cutoff_at) watermark
where (p.updated_at >= watermark.cutoff_at
    or cl.updated_at >= watermark.cutoff_at
    or c.updated_at >= watermark.cutoff_at
    or be.updated_at >= watermark.cutoff_at)
{% endif %}
