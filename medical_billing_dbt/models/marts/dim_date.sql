{{ config(materialized='table', schema='dw') }}
-- Covers the simulator's historical and near-future dates. Extend as needed.
with digits as (
    select 0 as n union all select 1 union all select 2 union all select 3 union all select 4
    union all select 5 union all select 6 union all select 7 union all select 8 union all select 9
), numbers as (
    select ones.n + 10*tens.n + 100*hundreds.n + 1000*thousands.n as n
    from digits ones cross join digits tens cross join digits hundreds cross join digits thousands
), dates as (
    select dateadd(day, n, cast('2020-01-01' as date)) as calendar_date
    from numbers
    where n <= datediff(day, cast('2020-01-01' as date), cast('2035-12-31' as date))
)
select cast(convert(char(8), calendar_date,112) as int) as date_key,
    calendar_date, datepart(year, calendar_date) as calendar_year,
    datepart(month, calendar_date) as calendar_month,
    datename(month, calendar_date) as month_name,
    datepart(quarter, calendar_date) as calendar_quarter,
    datepart(day, calendar_date) as day_of_month,
    datename(weekday, calendar_date) as day_name,
    cast(datefromparts(year(calendar_date), month(calendar_date), 1) as date) as month_start_date
from dates
