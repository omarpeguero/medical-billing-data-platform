{{ config(materialized='view', schema='intermediate') }}

-- Grain: one active billing entry. Source design ensures at most one
-- active claim line per billing entry.
SELECT
    be.billing_entry_id,
    be.client_id,
    be.provider_id,
    be.service_code_id,
    be.service_date,
    be.units,
    be.charge_per_unit,
    be.charge_amount,
    be.entry_status,
    cl.claim_line_id,
    cl.claim_id,
    c.payer_id,
    c.claim_status,
    c.first_submitted_at,
    c.last_submitted_at,
    be.created_at,
    be.updated_at,
    CAST(
        CASE
            WHEN cl.claim_line_id IS NULL THEN 0
            ELSE 1
        END AS BIT
    ) AS has_claim_line,
    CAST(
        CASE
            WHEN c.first_submitted_at IS NOT NULL THEN 1
            ELSE 0
        END AS BIT
    ) AS has_been_submitted,
    CASE
        WHEN c.first_submitted_at IS NOT NULL
            THEN DATEDIFF(DAY, be.service_date, c.first_submitted_at)
    END AS days_service_to_first_submission,
    CAST(
        CASE
            WHEN
                cl.claim_line_id IS NULL
                AND be.entry_status IN ('ready', 'on_hold')
                THEN 1
            ELSE 0
        END AS BIT
    ) AS is_unbilled_ready_or_hold,
    CAST(
        CASE
            WHEN be.entry_status = 'void' THEN 1
            ELSE 0
        END AS BIT
    ) AS is_void
FROM {{ ref('stg_billing_entries') }} AS be
LEFT JOIN {{ ref('stg_claim_lines') }} AS cl
    ON be.billing_entry_id = cl.billing_entry_id
LEFT JOIN {{ ref('stg_claims') }} AS c
    ON cl.claim_id = c.claim_id
