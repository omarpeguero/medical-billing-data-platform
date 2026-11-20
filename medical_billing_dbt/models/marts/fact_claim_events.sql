{{ config(materialized='incremental', incremental_strategy='merge', unique_key='claim_event_id', schema='dw', on_schema_change='fail') }}
-- Grain: one claim event, never one claim or one claim line.
select e.claim_event_id, e.claim_id, e.claim_line_id,
    c.client_id as client_key, c.provider_id as provider_key,
    c.payer_id as payer_key,
    cast(convert(char(8), cast(e.event_at as date),112) as int) as event_date_key,
    e.event_at, e.event_type, e.reason_code, e.reason_description,
    e.submission_reference, e.notes, e.created_at, e.updated_at,
    changes._source_change_at as _source_change_at
from {{ ref('stg_claim_events') }} e
left join {{ ref('stg_claims') }} c on e.claim_id = c.claim_id

cross apply (select max(x.val) as _source_change_at from (values (e.updated_at),(c.updated_at)) as x(val)) changes
{% if is_incremental() %}
cross join (select (select dateadd(day,-2,coalesce(max(_source_change_at), cast('1900-01-01' as datetime2))) from {{ this }}) as cutoff_at) watermark
where (e.updated_at >= watermark.cutoff_at
    or c.updated_at >= watermark.cutoff_at)
{% endif %}
