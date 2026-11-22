{{ config(materialized='view', schema='intermediate') }}

-- Grain: one record per active claim line. Never join payment and adjustment
-- transactions directly: pre-aggregate each to avoid a fan-out.
with payment_totals as (
    select
        claim_line_id,
        cast(sum(amount) as decimal(18, 2)) as total_paid,
        cast(sum(case when payment_source = 'insurance' then amount else 0 end) as decimal(18, 2)) as insurance_paid,
        cast(sum(case when payment_source = 'patient' then amount else 0 end) as decimal(18, 2)) as patient_paid,
        count(*) as payment_transaction_count,
        min(payment_date) as first_payment_date,
        max(payment_date) as last_payment_date
    from {{ ref('stg_payments') }}
    group by claim_line_id
),

adjustment_totals as (
    select
        claim_line_id,
        cast(sum(amount) as decimal(18, 2)) as total_adjusted,
        cast(sum(case when adjustment_type = 'contractual' then amount else 0 end) as decimal(18, 2))
            as contractual_adjusted,
        cast(sum(case when adjustment_type = 'write_off' then amount else 0 end) as decimal(18, 2))
            as write_off_adjusted,
        count(*) as adjustment_transaction_count,
        min(adjustment_date) as first_adjustment_date,
        max(adjustment_date) as last_adjustment_date
    from {{ ref('stg_adjustments') }}
    group by claim_line_id
)

select
    cl.claim_line_id,
    cl.claim_id,
    cl.billing_entry_id,
    c.client_id,
    c.provider_id,
    c.payer_id,
    be.service_code_id,
    be.service_date,
    cl.line_status,
    c.claim_status,
    cast(cl.billed_amount as decimal(18, 2)) as billed_amount,
    cast(cl.allowed_amount as decimal(18, 2)) as allowed_amount,
    cast(cl.patient_responsibility_amount as decimal(18, 2)) as patient_responsibility_amount,
    coalesce(p.total_paid, cast(0 as decimal(18, 2))) as total_paid,
    coalesce(p.insurance_paid, cast(0 as decimal(18, 2))) as insurance_paid,
    coalesce(p.patient_paid, cast(0 as decimal(18, 2))) as patient_paid,
    coalesce(a.total_adjusted, cast(0 as decimal(18, 2))) as total_adjusted,
    coalesce(a.contractual_adjusted, cast(0 as decimal(18, 2))) as contractual_adjusted,
    coalesce(a.write_off_adjusted, cast(0 as decimal(18, 2))) as write_off_adjusted,
    cast(cl.billed_amount - coalesce(p.total_paid, 0) - coalesce(a.total_adjusted, 0) as decimal(18, 2))
        as outstanding_balance,
    coalesce(p.payment_transaction_count, 0) as payment_transaction_count,
    coalesce(a.adjustment_transaction_count, 0) as adjustment_transaction_count,
    p.first_payment_date,
    p.last_payment_date,
    a.first_adjustment_date,
    a.last_adjustment_date
from {{ ref('stg_claim_lines') }} as cl
left join {{ ref('stg_claims') }} as c on cl.claim_id = c.claim_id
left join {{ ref('stg_billing_entries') }} as be on cl.billing_entry_id = be.billing_entry_id
left join payment_totals as p on cl.claim_line_id = p.claim_line_id
left join adjustment_totals as a on cl.claim_line_id = a.claim_line_id
