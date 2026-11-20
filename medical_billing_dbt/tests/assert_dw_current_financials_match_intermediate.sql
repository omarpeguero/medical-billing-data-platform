with a as (select count(*) as cnt, sum(billed_amount) as billed,
 sum(total_paid) as paid, sum(total_adjusted) as adjusted, sum(outstanding_balance) as ar
 from {{ ref('fact_claim_financials') }}),
 b as (select count(*) as cnt, sum(billed_amount) as billed,
 sum(total_paid) as paid, sum(total_adjusted) as adjusted, sum(outstanding_balance) as ar
 from {{ ref('int_claim_line_financials') }})
select 1 as failed_check from a cross join b
where a.cnt <> b.cnt or abs(coalesce(a.billed,0)-coalesce(b.billed,0)) > 0.01
 or abs(coalesce(a.paid,0)-coalesce(b.paid,0)) > 0.01
 or abs(coalesce(a.adjusted,0)-coalesce(b.adjusted,0)) > 0.01
 or abs(coalesce(a.ar,0)-coalesce(b.ar,0)) > 0.01
