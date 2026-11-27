-- A retained payment must match its landed key, signed amount, and deletion flag.
select coalesce(s.payment_id, p.payment_id) as payment_id
from {{ ref('stg_payments') }} as s
full outer join {{ ref('fact_payments') }} as p on s.payment_id = p.payment_id
where s.payment_id is null
    or p.payment_id is null
    or s.is_deleted is null
    or p.is_deleted is null
    or s.is_deleted <> p.is_deleted
    or s.amount is null
    or s.amount <> p.amount
    or p.amount is null
