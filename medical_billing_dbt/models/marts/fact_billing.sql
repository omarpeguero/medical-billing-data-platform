{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='billing_entry_id',
        schema='dw',
        on_schema_change='fail'
    )
}}
-- Grain: one active billing entry, with current claim status.
select
    bp.billing_entry_id,
    bp.client_id as client_key,
    bp.provider_id as provider_key,
    bp.service_code_id as service_key,
    bp.payer_id as payer_key,
    cast(convert(char(8), bp.service_date, 112) as int) as service_date_key,
    bp.service_date,
    bp.claim_id,
    bp.claim_line_id,
    bp.entry_status,
    bp.claim_status,
    bp.units,
    bp.charge_per_unit,
    bp.charge_amount,
    bp.has_claim_line,
    bp.has_been_submitted,
    bp.days_service_to_first_submission,
    bp.is_unbilled_ready_or_hold,
    bp.is_void,
    bp.created_at,
    bp.updated_at,
    changes._source_change_at
from {{ ref('int_billing_performance') }} as bp
left join {{ ref('stg_billing_entries') }} as be on bp.billing_entry_id = be.billing_entry_id
left join {{ ref('stg_claim_lines') }} as cl on bp.claim_line_id = cl.claim_line_id
left join {{ ref('stg_claims') }} as c on bp.claim_id = c.claim_id
cross apply
    (select max(x.val) as _source_change_at from (values (be.updated_at), (cl.updated_at), (c.updated_at)) as x(val))
        as changes
{% if is_incremental() %}
    cross join
        (
            select
                (
                    select dateadd(day, -2, coalesce(max(_source_change_at), cast('1900-01-01' as datetime2)))
                    from {{ this }}
                ) as cutoff_at
        ) as watermark
    where (
        be.updated_at >= watermark.cutoff_at
        or cl.updated_at >= watermark.cutoff_at
        or c.updated_at >= watermark.cutoff_at
    )
{% endif %}
