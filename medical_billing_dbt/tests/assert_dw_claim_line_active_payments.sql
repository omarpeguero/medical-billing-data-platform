-- Independently roll up eligible payments and compare each active claim line.
with active_payments as (
    select
        claim_line_id,
        sum(amount) as total_paid,
        sum(case when payment_source = 'insurance' then amount else 0 end) as insurance_paid,
        sum(case when payment_source = 'patient' then amount else 0 end) as patient_paid,
        count(*) as payment_transaction_count,
        min(payment_date) as first_payment_date,
        max(payment_date) as last_payment_date
    from {{ ref('stg_payments') }}
    where is_deleted = 0
    group by claim_line_id
)

select cl.claim_line_id
from {{ ref('stg_claim_lines') }} as cl
left join active_payments as p on cl.claim_line_id = p.claim_line_id
left join {{ ref('fact_claim_financials') }} as f on cl.claim_line_id = f.claim_line_id
where f.claim_line_id is null
    or exists (
        select coalesce(p.total_paid, 0), coalesce(p.insurance_paid, 0), coalesce(p.patient_paid, 0),
               coalesce(p.payment_transaction_count, 0), p.first_payment_date, p.last_payment_date,
               cast(cl.billed_amount - coalesce(p.total_paid, 0) - f.total_adjusted as decimal(18, 2))
        except
        select f.total_paid, f.insurance_paid, f.patient_paid, f.payment_transaction_count,
               f.first_payment_date, f.last_payment_date, f.outstanding_balance
    )
