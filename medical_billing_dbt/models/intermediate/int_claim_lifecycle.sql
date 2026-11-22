{{ config(materialized='view', schema='intermediate') }}

-- Grain: one logical claim. Event counts are counts of occurrences, not
-- necessarily unique submissions or claims denied at first pass.
with event_summary as (
    select
        claim_id,
        count(*) as event_count,
        sum(case when event_type = 'submitted' then 1 else 0 end) as submitted_event_count,
        sum(case when event_type = 'resubmitted' then 1 else 0 end) as resubmission_event_count,
        sum(case when event_type = 'denied' then 1 else 0 end) as denial_event_count,
        sum(case when event_type = 'appealed' then 1 else 0 end) as appeal_event_count,
        sum(case when event_type = 'clearinghouse_rejected' then 1 else 0 end) as clearinghouse_rejection_count,
        min(case when event_type in ('submitted', 'resubmitted') then event_at end) as first_submission_event_at,
        max(case when event_type in ('submitted', 'resubmitted') then event_at end) as last_submission_event_at,
        min(case when event_type = 'denied' then event_at end) as first_denial_at,
        max(case when event_type = 'denied' then event_at end) as last_denial_at,
        min(case when event_type = 'paid' then event_at end) as first_paid_event_at,
        max(event_at) as latest_event_at
    from {{ ref('stg_claim_events') }}
    group by claim_id
),

line_summary as (
    select
        claim_id,
        count(*) as claim_line_count,
        cast(sum(billed_amount) as decimal(18, 2)) as total_billed,
        cast(sum(total_paid) as decimal(18, 2)) as total_paid,
        cast(sum(total_adjusted) as decimal(18, 2)) as total_adjusted,
        cast(sum(outstanding_balance) as decimal(18, 2)) as outstanding_balance
    from {{ ref('int_claim_line_financials') }}
    group by claim_id
)

select
    c.claim_id,
    c.claim_number,
    c.client_id,
    c.provider_id,
    c.payer_id,
    c.claim_type,
    c.claim_status,
    c.first_submitted_at,
    c.last_submitted_at,
    coalesce(e.event_count, 0) as event_count,
    coalesce(e.submitted_event_count, 0) as submitted_event_count,
    coalesce(e.resubmission_event_count, 0) as resubmission_event_count,
    coalesce(e.denial_event_count, 0) as denial_event_count,
    coalesce(e.appeal_event_count, 0) as appeal_event_count,
    coalesce(e.clearinghouse_rejection_count, 0) as clearinghouse_rejection_count,
    cast(case when coalesce(e.denial_event_count, 0) > 0 then 1 else 0 end as bit) as ever_denied,
    e.first_submission_event_at,
    e.last_submission_event_at,
    e.first_denial_at,
    e.last_denial_at,
    e.first_paid_event_at,
    e.latest_event_at,
    coalesce(l.claim_line_count, 0) as claim_line_count,
    coalesce(l.total_billed, cast(0 as decimal(18, 2))) as total_billed,
    coalesce(l.total_paid, cast(0 as decimal(18, 2))) as total_paid,
    coalesce(l.total_adjusted, cast(0 as decimal(18, 2))) as total_adjusted,
    coalesce(l.outstanding_balance, cast(0 as decimal(18, 2))) as outstanding_balance,
    case
        when c.first_submitted_at is not null and e.first_denial_at is not null
            then datediff(day, c.first_submitted_at, e.first_denial_at)
    end as days_to_first_denial
from {{ ref('stg_claims') }} as c
left join event_summary as e on c.claim_id = e.claim_id
left join line_summary as l on c.claim_id = l.claim_id
