-- Returns only rows that violate the signed transaction reconciliation.
select claim_line_id
from {{ ref('int_claim_line_financials') }}
where abs(cast(billed_amount - total_paid - total_adjusted - outstanding_balance as decimal(18,2))) > 0.01
