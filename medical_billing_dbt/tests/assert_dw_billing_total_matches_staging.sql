with a as (select count(*) as cnt, sum(charge_amount) as amt from {{ ref('fact_billing') }}),
     b as (select count(*) as cnt, sum(charge_amount) as amt from {{ ref('stg_billing_entries') }})
select 1 as failed_check from a cross join b
where a.cnt <> b.cnt or abs(coalesce(a.amt,0)-coalesce(b.amt,0)) > 0.01
