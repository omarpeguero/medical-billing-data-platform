{{ config(materialized='view', schema='intermediate') }}

-- Grain: one active billing entry. Source design ensures at most one
-- active claim line per billing entry.
select
    be.billing_entry_id,
    be.client_id, be.provider_id, be.service_code_id,
    be.service_date, be.units, be.charge_per_unit, be.charge_amount,
    be.entry_status,
    cl.claim_line_id,
    cl.claim_id,
    c.payer_id,
    c.claim_status,
    c.first_submitted_at,
    c.last_submitted_at,
    cast(case when cl.claim_line_id is null then 0 else 1 end as bit) as has_claim_line,
    cast(case when c.first_submitted_at is not null then 1 else 0 end as bit) as has_been_submitted,
    case when c.first_submitted_at is not null
        then datediff(day, be.service_date, c.first_submitted_at) end as days_service_to_first_submission,
    cast(case when cl.claim_line_id is null and be.entry_status in ('ready','on_hold')
        then 1 else 0 end as bit) as is_unbilled_ready_or_hold,
    cast(case when be.entry_status = 'void' then 1 else 0 end as bit) as is_void,
    be.created_at, be.updated_at
from {{ ref('stg_billing_entries') }} be
left join {{ ref('stg_claim_lines') }} cl on be.billing_entry_id = cl.billing_entry_id
left join {{ ref('stg_claims') }} c on cl.claim_id=c.claim_id
