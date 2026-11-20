-- Preserve amount signs and ensure each claim line balances arithmetically.
select claim_line_id from {{ ref('fact_claim_financials') }}
where abs(cast(billed_amount as decimal(18,2)) - coalesce(total_paid,0)
           - coalesce(total_adjusted,0) - coalesce(outstanding_balance,0)) > 0.01
