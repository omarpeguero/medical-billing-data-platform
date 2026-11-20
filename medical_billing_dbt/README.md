# Medical Billing dbt starter

Runs dbt Core in a separate Docker container against the local Microsoft SQL Server on port 1433. Does not modify your existing Airflow compose.

1. Copy `.env.example` to `.env`, then replace SQLSERVER_PASSWORD with your own credentials. Do not commit `.env`.
2. Run `docker compose build`.
3. Run `docker compose run --rm dbt debug`.
4. Run `docker compose run --rm dbt run --select stg_billing_entries`.
5. Run `docker compose run --rm dbt test --select stg_billing_entries`.

The Docker image uses ODBC Driver 18, with local-development-only `trust_cert: true` to accept SQL Server's self-signed certificate. To use certificates in production, use a trusted certificate and `trust_cert: false`.

The first model creates a `staging.stg_billing_entries` view and leaves `raw` untouched. `dbt run` is not yet integrated into the Airflow DAG. The source file defines all 10 Airbyte streams; other models should be added and tested iteratively after the first successful run.

If your SQL Server container maps a different host port or uses a different database/login, adjust `.env`. `host.docker.internal` reaches a published Docker Desktop Windows-host port.

Run `docker compose run --rm dbt --version` to inspect installed versions.
