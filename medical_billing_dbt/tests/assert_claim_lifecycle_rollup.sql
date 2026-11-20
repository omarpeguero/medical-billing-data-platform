select claim_id
from {{ ref('int_claim_lifecycle') }}
where abs(cast(total_billed - total_paid - total_adjusted - outstanding_balance as decimal(18,2))) > 0.01
