{{ config(severity='warn') }}
-- A negative balance can be a legitimate credit. Surface for investigation.
select claim_line_id, outstanding_balance
from {{ ref('int_claim_line_financials') }}
where outstanding_balance < -0.01
