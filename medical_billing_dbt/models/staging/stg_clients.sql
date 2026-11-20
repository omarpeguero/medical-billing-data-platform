select
    client_id,
    client_number,
    first_name,
    last_name,
    cast(date_of_birth as date) as date_of_birth,
    state_code,
    postal_code,
    client_status,
    created_at,
    updated_at
from {{ source('emr', 'clients') }}
where is_deleted = 0
