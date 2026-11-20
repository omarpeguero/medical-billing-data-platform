{{ config(severity='warn') }}
-- Claims submitted before the recorded service date require investigation.
select billing_entry_id, days_service_to_first_submission
from {{ ref('int_billing_performance') }}
where days_service_to_first_submission < 0
