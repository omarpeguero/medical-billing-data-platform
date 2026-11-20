-- No dropped or duplicated payment records during fact enrichment.
with a as (select count(*) as cnt, sum(amount) as amt from {{ ref('fact_payments') }}),
     b as (select count(*) as cnt, sum(amount) as amt from {{ ref('stg_payments') }})
select 1 as failed_check from a cross join b
where a.cnt <> b.cnt or abs(coalesce(a.amt,0)-coalesce(b.amt,0)) > 0.01
