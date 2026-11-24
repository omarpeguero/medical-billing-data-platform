# Medical Billing dbt project

dbt Core transforms 10 Airbyte-landed SQL Server relations into 23 models for revenue-cycle analysis. Claim-line balances, signed transactions, and claim events retain separate grains so the report can answer financial and operational questions without multiplying amounts.

## Project layout

| Path | Purpose |
| --- | --- |
| [dbt_project.yml](dbt_project.yml) | Project configuration and layer defaults |
| [config/profiles.yml](config/profiles.yml) | SQL Server connection and targets |
| [models/staging](models/staging) | Airbyte source declarations, active-row views, and column tests |
| [models/intermediate](models/intermediate) | Claim-line finances, claim lifecycle, and billing performance |
| [models/marts](models/marts) | Dimensions, incremental facts, and warehouse tests |
| [macros](macros) | Target-specific schema naming |
| [tests](tests) | Standalone SQL assertions |
| [Dockerfile](Dockerfile), [docker-compose.yml](docker-compose.yml) | Local dbt image with a bind-mounted project |
| [Dockerfile.airflow-runner](Dockerfile.airflow-runner) | Packaged project for orchestrated execution |

## Sources and models

The `emr` source reads `MedicalBilling_DW.raw`. The database and schema are explicit in [`_sources.yml`](models/staging/_sources.yml). Both targets read the same declared source. Staging views cast and project source fields and filter on `is_deleted = 0`.

| Staging view | Contents |
| --- | --- |
| `stg_clients` | Synthetic client reference data |
| `stg_providers` | Provider reference data |
| `stg_payers` | Payer reference data |
| `stg_service_codes` | Billable service catalog |
| `stg_billing_entries` | Charges for rendered services |
| `stg_claims` | Claim headers and current status |
| `stg_claim_lines` | Billable lines and adjudication amounts |
| `stg_claim_events` | Claim lifecycle events and reasons |
| `stg_payments` | Signed payment transactions |
| `stg_adjustments` | Signed financial adjustment transactions |

| Intermediate view | Grain and logic |
| --- | --- |
| `int_claim_line_financials` | One active claim line. Aggregates payments and adjustments separately, then calculates paid, adjusted, and outstanding amounts. |
| `int_claim_lifecycle` | One logical claim. Rolls up event occurrences and lifecycle dates. |
| `int_billing_performance` | One active billing entry. Adds claim lifecycle context and time to first submission. |

| Warehouse model | Materialization | Grain | Key |
| --- | --- | --- | --- |
| `dim_client` | Table | One client | `client_key` |
| `dim_provider` | Table | One provider | `provider_key` |
| `dim_payer` | Table | One payer | `payer_key` |
| `dim_service` | Table | One service code | `service_key` |
| `dim_date` | Table | One calendar date, 2020–2035 inclusive | `date_key` (integer YYYYMMDD) |
| `fact_billing` | Incremental merge | One active billing entry with current claim context | `billing_entry_id` |
| `fact_claim_financials` | Incremental merge | One claim line with current balances | `claim_line_id` |
| `fact_payments` | Incremental merge | One posted payment or reversal | `payment_id` |
| `fact_adjustments` | Incremental merge | One posted adjustment or reversal | `adjustment_id` |
| `fact_claim_events` | Incremental merge | One claim event | `claim_event_id` |

### Incremental behavior

All five facts use a SQL Server merge keyed on their source identifiers. For incremental runs, each derives a cutoff two days before the maximum stored `_source_change_at` and selects rows with relevant upstream timestamps at or after the cutoff. The financial fact also considers related payment and adjustment change timestamps. Successive runs can reprocess recently changed records within the two-day lookback and update existing rows by key. This assumes unique input keys and change timestamps within the replay window. Run builds against the same destination schema sequentially.

Source rows that disappear from staging are outside the merge input. Existing fact rows can therefore survive a source deletion, and related totals can require rebuilding. Changes arriving outside the lookback can also require a rebuild. After confirming that raw is complete, use a deliberate full refresh to realign derived tables. The financial fact stores current A/R, with no historical balance snapshot.

## Targets and credentials

The [schema macro](macros/generate_schema_name.sql) selects the following SQL Server schemas.

| Target | Staging | Intermediate | Marts |
| --- | --- | --- | --- |
| `dev` (default) | `dev_omar_staging` | `dev_omar_intermediate` | `dev_omar_dw` |
| `prod` (local shared warehouse) | `staging` | `intermediate` | `dw` |

Create a local `.env` from [`.env.example`](.env.example) with `SQLSERVER_HOST`, `SQLSERVER_PORT`, `SQLSERVER_DATABASE`, `SQLSERVER_USER`, and `SQLSERVER_PASSWORD`. Use an account with source read access and permission to create and update relations in the selected target schemas. Changing `SQLSERVER_DATABASE` leaves the source database declaration unchanged. Keep credentials in the ignored runtime environment files.

Both profiles use ODBC Driver 18, encryption, and `trust_cert: true` for the local SQL Server certificate. A production environment should use a trusted certificate and set `trust_cert: false`. The targets provide schema separation. Server and credentials come from the same environment variable names.

## Local development

Run from `medical_billing_dbt` after landing the raw relations. Compose mounts the project into `/workspace` and points dbt to `/workspace/config`.

```powershell
Copy-Item .env.example .env  # First-time setup. Edit values before running dbt.
docker compose build
docker compose run --rm dbt --version
docker compose run --rm dbt debug --target dev
docker compose run --rm dbt build --target dev
docker compose run --rm dbt test --target dev
docker compose run --rm dbt build --target dev --select +fact_claim_financials
```

For a development rebuild from the complete raw dataset, run `docker compose run --rm dbt build --target dev --full-refresh`. The `prod` target writes to the shared schemas used by Power BI.

### Test coverage

There are 123 generic tests across [staging](models/staging/_models.yml), [intermediate](models/intermediate/_intermediate_models.yml), and [marts](models/marts/_dw_models.yml). They check nullability, uniqueness, accepted values, and relationships. Nine [singular SQL tests](tests) check claim-line reconciliation and nonnegative balances, lifecycle rollups, submission lag, transaction totals against staging, and current warehouse financials against intermediate results. `dbt build` executes models and tests in dependency order. GitHub Actions validates project parsing separately.

## Airflow runner

The [DAG](../medical_billing_airflow/dags/medical_billing_ingestion.py) waits for the Airbyte sync before its `DockerOperator` runs the following command in the image identified by `DBT_IMAGE`.

```bash
dbt build --project-dir /workspace --profiles-dir /workspace/config --target prod
```

The runner includes the models, tests, macros, and profile, with dbt-sqlserver pinned to 1.12.1. Airflow Compose mounts this project's `.env` read-only at `/opt/airflow/secrets/dbt.env`. The DAG reads that file and passes the values into the runner through `private_environment`. The runner uses Docker bridge networking and connects to SQL Server from inside the container. Airflow needs a compatible Docker provider and access to the Docker socket. The runner must be available to that daemon, with registry login where required. [Delivery and rollback](../docs/cicd.md)

## Troubleshooting

- **Connection fails in `dbt debug`.** Check SQL Server's published port, login, and container-to-host routing. `localhost` inside the runner refers to the runner itself. Use the Docker Desktop host address or another reachable endpoint.
- **dbt cannot find a raw relation.** Verify the initial Airbyte sync, the fixed `MedicalBilling_DW.raw` location, and the source columns expected by the staging SQL, including `is_deleted`.
- **Power BI refresh cannot find the marts.** The default dbt target writes to `dev_omar_dw`. Build the shared `dw` schema with the `prod` target and confirm the report's SQL Server endpoint.
- **Airflow cannot parse or start the runner task.** Check the Airflow Compose `DBT_IMAGE`, the Docker provider import, daemon access, and image availability. The Airflow Dockerfile explicitly installs the Airbyte provider. Verify that the base image supplies the Docker provider before running the DAG.
- **A reconciliation test fails after an old update or deletion.** Inspect raw and staging first. Check the fact watermark, the upstream timestamps, and whether the row is still in staging before deciding whether to rebuild.
