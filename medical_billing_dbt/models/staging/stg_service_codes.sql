select
    service_code_id,
    code_system,
    procedure_code,
    description,
    unit_type,
    cast(default_charge_per_unit as decimal(18, 2)) as default_charge_per_unit,
    cast(effective_from as date) as effective_from,
    cast(effective_to as date) as effective_to,
    created_at,
    updated_at
from {{ source('emr', 'service_codes') }}
where is_deleted = 0
