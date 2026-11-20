{{ config(materialized='incremental', incremental_strategy='merge', unique_key='adjustment_id', schema='dw', on_schema_change='fail') }}
-- Grain: one posted adjustment/reversal transaction. Signed amount is preserved.
select a.adjustment_id, a.claim_line_id, f.claim_id, f.billing_entry_id,
    f.client_id as client_key, f.provider_id as provider_key,
    f.payer_id as payer_key, f.service_code_id as service_key,
    cast(convert(char(8), a.adjustment_date,112) as int) as adjustment_date_key,
    a.adjustment_date, a.posted_at, a.adjustment_type, a.amount,
    a.adjustment_group_code, a.adjustment_reason_code, a.description,
    a.original_adjustment_id, a.created_at, a.updated_at,
    changes._source_change_at as _source_change_at
from {{ ref('stg_adjustments') }} a
left join {{ ref('int_claim_line_financials') }} f on a.claim_line_id = f.claim_line_id
left join {{ ref('stg_claim_lines') }} cl on a.claim_line_id=cl.claim_line_id
left join {{ ref('stg_claims') }} c on cl.claim_id=c.claim_id
left join {{ ref('stg_billing_entries') }} be on cl.billing_entry_id=be.billing_entry_id

cross apply (select max(x.val) as _source_change_at from (values (a.updated_at),(cl.updated_at),(c.updated_at),(be.updated_at)) as x(val)) changes
{% if is_incremental() %}
cross join (select (select dateadd(day,-2,coalesce(max(_source_change_at), cast('1900-01-01' as datetime2))) from {{ this }}) as cutoff_at) watermark
where (a.updated_at >= watermark.cutoff_at
    or cl.updated_at >= watermark.cutoff_at
    or c.updated_at >= watermark.cutoff_at
    or be.updated_at >= watermark.cutoff_at)
{% endif %}
