with a as (select count(*) as cnt, sum(amount) as amt from {{ ref('fact_adjustments') }}),
     b as (select count(*) as cnt, sum(amount) as amt from {{ ref('stg_adjustments') }})
select 1 as failed_check from a cross join b
where a.cnt <> b.cnt or abs(coalesce(a.amt,0)-coalesce(b.amt,0)) > 0.01
