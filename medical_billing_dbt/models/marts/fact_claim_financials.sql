{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='claim_line_id',
        schema='dw',
        on_schema_change='fail'
    )
}}
-- Grain: one claim line, CURRENT balance as of latest dbt build; not historical A/R snapshot.
select
    f.claim_line_id,
    f.claim_id,
    f.billing_entry_id,
    f.client_id as client_key,
    f.provider_id as provider_key,
    f.payer_id as payer_key,
    f.service_code_id as service_key,
    cast(convert(char(8), f.service_date, 112) as int) as service_date_key,
    f.service_date,
    f.line_status,
    f.claim_status,
    f.billed_amount,
    f.allowed_amount,
    f.patient_responsibility_amount,
    f.total_paid,
    f.insurance_paid,
    f.patient_paid,
    f.total_adjusted,
    f.contractual_adjusted,
    f.write_off_adjusted,
    f.outstanding_balance,
    f.payment_transaction_count,
    f.adjustment_transaction_count,
    f.first_payment_date,
    f.last_payment_date,
    f.first_adjustment_date,
    f.last_adjustment_date,
    changes._source_change_at
from {{ ref('int_claim_line_financials') }} as f
left join {{ ref('stg_claim_lines') }} as cl on f.claim_line_id = cl.claim_line_id
left join {{ ref('stg_claims') }} as c on cl.claim_id = c.claim_id
left join {{ ref('stg_billing_entries') }} as be on cl.billing_entry_id = be.billing_entry_id

outer apply
    (
        select max(p.updated_at) as payment_change_at
        from {{ ref('stg_payments') }} as p
        where p.claim_line_id = cl.claim_line_id
    ) as pay_change
outer apply
    (
        select max(a.updated_at) as adjustment_change_at
        from {{ ref('stg_adjustments') }} as a
        where a.claim_line_id = cl.claim_line_id
    ) as adj_change
cross apply
    (
        select max(x.val) as _source_change_at
        from
            (
                values (cl.updated_at),
                (c.updated_at),
                (be.updated_at),
                (pay_change.payment_change_at),
                (adj_change.adjustment_change_at)
            ) as x(val)
    ) as changes
{% if is_incremental() %}
    left join {{ this }} as prior_line on f.claim_line_id = prior_line.claim_line_id
    cross join
        (
            select
                (
                    select dateadd(day, -2, coalesce(max(_source_change_at), cast('1900-01-01' as datetime2)))
                    from {{ this }}
                ) as cutoff_at
        ) as watermark
    where (
        cl.updated_at >= watermark.cutoff_at
        or c.updated_at >= watermark.cutoff_at
        or be.updated_at >= watermark.cutoff_at
        or exists (
            select 1 from {{ ref('stg_payments') }} as p
            where p.claim_line_id = cl.claim_line_id and p.updated_at >= watermark.cutoff_at
        )
        or exists (
            select 1 from {{ ref('stg_adjustments') }} as a
            where a.claim_line_id = cl.claim_line_id and a.updated_at >= watermark.cutoff_at
        )
        -- Compare active payment results directly, including dates that clear on the last deletion.
        or (
            prior_line.claim_line_id is not null
            and exists (
                select
                    f.total_paid,
                    f.insurance_paid,
                    f.patient_paid,
                    f.payment_transaction_count,
                    f.first_payment_date,
                    f.last_payment_date
                except
                select
                    prior_line.total_paid,
                    prior_line.insurance_paid,
                    prior_line.patient_paid,
                    prior_line.payment_transaction_count,
                    prior_line.first_payment_date,
                    prior_line.last_payment_date
            )
        )
    )
{% endif %}
