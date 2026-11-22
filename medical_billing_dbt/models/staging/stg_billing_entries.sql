select
    billing_entry_id,
    client_id,
    provider_id,
    service_code_id,
    cast(service_date as date) as service_date,
    cast(units as decimal(18, 2)) as units,
    cast(charge_per_unit as decimal(18, 2)) as charge_per_unit,
    cast(charge_amount as decimal(18, 2)) as charge_amount,
    entry_status,
    created_at,
    updated_at
from {{ source('emr', 'billing_entries') }}
where is_deleted = 0
