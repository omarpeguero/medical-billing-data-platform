# Airbyte ingestion setup

Airbyte replicates synthetic billing data from PostgreSQL into SQL Server. This guide documents a reproducible manual setup. The CLI installs Airbyte, and you create the source, destination, and sync connection in the Airbyte UI. Use a fresh host or isolated Docker environment to preserve an existing Airbyte instance.

## Verified configuration and local prerequisites

The live Airbyte UI configuration supplied for this guide uses Airbyte OSS **2.4.0**, installed with `abctl` on Docker Desktop, and PostgreSQL source connector **3.8.5**. The running server deployment also reports Helm chart `airbyte-2.4.0`. The repository confirms the source and destination table contract and the Airflow handoff.

Before recreating the setup, confirm the PostgreSQL endpoint, database logins, network and TLS settings, and installed SQL Server connector version for your environment. The exact `abctl` CLI version and SQL Server connector version have not been captured. Supply credentials locally through the Airbyte or Airflow UI and keep them out of version control.

## 1. Install Airbyte locally

1. Start Docker Desktop with Linux containers and install the [`abctl` CLI](https://docs.airbyte.com/platform/deploying-airbyte/abctl) for your operating system.
2. On a fresh Docker environment, install the recorded chart and check the reported application version.

   ```powershell
   abctl local install --chart-version 2.4.0 --port 8000
   abctl local status
   ```

   Confirm that the application version is `2.4.0`. The install flag selects the Helm chart version. The matching numbers here come from the live deployment.
3. Open `http://localhost:8000`. Use `abctl local credentials` privately if you need the installation’s login details. Keep its output out of shared logs and screenshots.

## 2. Configure the PostgreSQL source

1. Create or select the dedicated `EMR_source` database. Apply the [source DDL](../medical_billing_postgres_schema.sql) to an empty project database and seed synthetic data using the [simulator guide](../README_medical_billing_simulator.md).
2. In Airbyte, create a PostgreSQL source using connector version **3.8.5**. Check the installed connector version before saving. Enter the host and port reachable from Airbyte, the `EMR_source` database, and the `billing` schema. Supply a PostgreSQL account with database access, schema usage, and read access to all 10 tables. Use the TLS setting appropriate to the PostgreSQL server.
3. Select **Xmin System Column** for update detection. Save the source and confirm that Airbyte can connect and discover the `billing` streams.

## 3. Configure the SQL Server destination

1. Create `MedicalBilling_DW` and ensure that the Airbyte login can create and write tables in `raw`. If the schema is precreated, grant the login the permissions required by the [SQL Server destination connector](https://docs.airbyte.com/integrations/destinations/mssql).
2. In Airbyte, create a **Microsoft SQL Server** destination. Enter the following settings and supply the local login and password.

   | Setting | Verified local value |
   | --- | --- |
   | Host | `host.docker.internal` |
   | Port | `1433` |
   | Database | `MedicalBilling_DW` |
   | Default schema | `raw` |
   | Load type | `INSERT` |
   | Transport | Unencrypted, for local development only |

3. Test and save the destination. On a different host, verify routing from the Airbyte connector runtime and select the transport settings required by that environment.

## 4. Configure the sync connection

1. Create a connection named **EMR_source → MedicalBilling_DW** using the source and destination above.
2. Set the schedule to **Manual**, destination namespace to **Destination-defined**, and leave the stream prefix empty. The destination default schema then places the final tables under `MedicalBilling_DW.raw`.
3. Set schema changes to **Manual approval**, enable schema-change notifications, and disable automatic backfill for new or renamed columns. Check notification delivery separately if needed.
4. Select the following 10 streams from `billing`. Use **Incremental | Append + Deduped** for each, confirm its key, and include `is_deleted` and the other columns referenced by the [dbt staging models](../medical_billing_dbt/models/staging).

   | Stream and final table name | Primary key |
   | --- | --- |
   | `adjustments` | `adjustment_id` |
   | `billing_entries` | `billing_entry_id` |
   | `claim_events` | `claim_event_id` |
   | `claim_lines` | `claim_line_id` |
   | `claims` | `claim_id` |
   | `clients` | `client_id` |
   | `payers` | `payer_id` |
   | `payments` | `payment_id` |
   | `providers` | `provider_id` |
   | `service_codes` | `service_code_id` |

5. Save the new connection, run an initial sync in Airbyte, and wait for success. Run the SQL checks below before building dbt.

## 5. Hand off orchestration to Airflow

Create the **Airbyte** connection `airbyte_default` in Airflow. It stores the API base URL and the Airbyte application authentication settings. The verified endpoint from the local Airflow container is `http://host.docker.internal:8000/api/public/v1/`. For the documented self-managed OAuth setup, use `/api/public/v1/applications/token` as the token URL and supply your own application client ID and secret. Confirm the endpoint and authentication behavior on the recreated instance. [Airflow Airbyte connection settings](https://airflow.apache.org/docs/apache-airflow-providers-airbyte/stable/connections.html)

Copy the new sync connection UUID from Airbyte and set `AIRBYTE_CONNECTION_ID` in `medical_billing_airflow/.env`. Set `DBT_IMAGE` to the dbt runner image in the same file. The [environment template](../medical_billing_airflow/.env.example) lists both settings. The API connection tells Airflow how to authenticate and where to send the request. The UUID selects the particular sync to trigger.

Follow the Airflow setup to prepare the dbt runner and SQL Server credentials. From `medical_billing_airflow`, run `docker compose config --quiet` and `docker compose up -d` when configuring a new Airflow environment. Trigger `medical_billing_ingestion` and check that `sync_postgres_to_sqlserver` succeeds before `dbt_build_and_test` runs. Airflow schedules the DAG at the top of each hour in UTC when it is unpaused. [Airflow setup](../medical_billing_airflow/README.md) · [dbt runner configuration](../medical_billing_dbt/README.md#airflow-runner)

## How Xmin replication works

PostgreSQL’s `xmin` identifies the transaction that created a row version. An insert creates a version, and an update creates a new version with the updating transaction’s ID. Airbyte uses this information and its saved sync state to pick up visible inserts and updates. Append + Deduped consolidates the landed rows by their configured keys. A hard delete leaves no visible row version for a later Xmin query to read, so the destination can retain the previously synced row. Multiple changes between syncs may appear as a single current row. [Airbyte PostgreSQL connector](https://docs.airbyte.com/integrations/sources/postgres) · [PostgreSQL system columns](https://www.postgresql.org/docs/current/ddl-system-columns.html)

Transaction IDs are 32-bit and wrap around. They are neither timestamps nor globally increasing identifiers across the life of a cluster. A long sync gap on a busy database can make saved XID state unsafe to use without checking the connector’s behavior. PostgreSQL vacuum freezing protects visibility across wraparound. On supported PostgreSQL versions, freezing marks the row version as frozen while normally preserving its visible `xmin`. Freezing does not create a new row version or emit a change for Airbyte to replay. Keep autovacuum enabled and validate or rebaseline the sync after a restore or a prolonged gap if the saved state is no longer reliable. [PostgreSQL vacuum and XID wraparound](https://www.postgresql.org/docs/current/routine-vacuuming.html)

WAL-based CDC reads changes from PostgreSQL logical replication rather than querying visible rows by transaction ID. With a publication, replication slot, appropriate permissions, and suitable replica identity, CDC can capture deletes as well as inserts and updates. This deployment uses Xmin. [Airbyte PostgreSQL connector](https://docs.airbyte.com/integrations/sources/postgres)

### Logical deletion in dbt

The source DDL defines `is_deleted` on all 10 tables. Updating a row to `is_deleted = TRUE` creates a new PostgreSQL row version that Xmin can replicate. The destination row remains available under `raw` with its flag set. Each dbt staging view filters on `is_deleted = 0`, so the row disappears from staging. Existing incremental fact rows can survive that change because their merges operate on rows still available in the model input. Use the [dbt incremental processing notes](../medical_billing_dbt/README.md#incremental-behavior) when deciding how to reconcile affected marts.

## Verify the SQL Server landing tables

Run the following with read access to all 10 tables and visibility into their metadata. For an isolated test database with a different name, replace `MedicalBilling_DW` in the `USE` statement before running the script. The first result should show 10 rows with all three flags set to `1`. The second result should be empty. Resolve missing tables or columns before trusting the duplicate check. It skips tables whose key metadata is unavailable.

```sql
USE [MedicalBilling_DW];

DECLARE @expected TABLE (table_name sysname, key_column sysname);
INSERT INTO @expected (table_name, key_column)
VALUES ('adjustments', 'adjustment_id'),
       ('billing_entries', 'billing_entry_id'),
       ('claim_events', 'claim_event_id'),
       ('claim_lines', 'claim_line_id'),
       ('claims', 'claim_id'),
       ('clients', 'client_id'),
       ('payers', 'payer_id'),
       ('payments', 'payment_id'),
       ('providers', 'provider_id'),
       ('service_codes', 'service_code_id');

SELECT e.table_name,
       CASE WHEN t.object_id IS NULL THEN 0 ELSE 1 END AS table_exists,
       CASE WHEN d.column_id IS NULL THEN 0 ELSE 1 END AS has_is_deleted,
       CASE WHEN k.column_id IS NULL THEN 0 ELSE 1 END AS has_key_column
FROM @expected AS e
LEFT JOIN sys.tables AS t
  ON t.name = e.table_name AND t.schema_id = SCHEMA_ID(N'raw')
LEFT JOIN sys.columns AS d ON d.object_id = t.object_id AND d.name = N'is_deleted'
LEFT JOIN sys.columns AS k ON k.object_id = t.object_id AND k.name = e.key_column
ORDER BY e.table_name;

CREATE TABLE #duplicate_keys (
    table_name sysname,
    key_value nvarchar(128),
    row_count bigint
);

DECLARE @table sysname, @key sysname, @sql nvarchar(max);
DECLARE stream_keys CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, key_column
    FROM @expected
    WHERE COL_LENGTH(N'raw.' + QUOTENAME(table_name), key_column) IS NOT NULL;

OPEN stream_keys;
FETCH NEXT FROM stream_keys INTO @table, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'INSERT INTO #duplicate_keys
        SELECT @stream, CONVERT(nvarchar(128), ' + QUOTENAME(@key) + N'), COUNT_BIG(*)
        FROM [raw].' + QUOTENAME(@table) + N'
        GROUP BY ' + QUOTENAME(@key) + N'
        HAVING COUNT_BIG(*) > 1 OR ' + QUOTENAME(@key) + N' IS NULL;';
    EXEC sys.sp_executesql @sql, N'@stream sysname', @stream = @table;
    FETCH NEXT FROM stream_keys INTO @table, @key;
END;
CLOSE stream_keys;
DEALLOCATE stream_keys;

-- Rows identify duplicate keys or a null key.
SELECT table_name, key_value, row_count
FROM #duplicate_keys
ORDER BY table_name, key_value;
DROP TABLE #duplicate_keys;
```

## Safely test incremental updates

1. Use a separate Airbyte connection with dedicated disposable PostgreSQL and SQL Server databases, such as `EMR_source_airbyte_test` and `MedicalBilling_DW_airbyte_test`. Use synthetic data only. Verify both endpoints and database names in the test connection before syncing. Leave the working Airbyte connection, its sync state, and the existing Airflow UUID unchanged.
2. Apply the source DDL to the test PostgreSQL database. Seed synthetic rows in all streams if you are validating all 10 destination tables, since an empty stream may not produce a table on the initial sync. Insert a test client and commit before starting that sync. Run the sync in the Airbyte UI. In the test SQL Server database, confirm that the key arrived exactly once.

   ```sql
   -- PostgreSQL. Run only in the disposable test source.
   INSERT INTO billing.clients (client_number, first_name, last_name, date_of_birth)
   VALUES ('AIRBYTE-TEST-001', 'Synthetic', 'Before', DATE '1990-01-01')
   RETURNING client_id;
   ```

   ```sql
   -- SQL Server. Run in the disposable test destination.
   SELECT client_id, client_number, last_name, is_deleted
   FROM raw.clients
   WHERE client_number = 'AIRBYTE-TEST-001';
   ```

3. Update the same synthetic client in a committed transaction, then run a second sync on the test connection. Run the same destination query and confirm it still returns one row with the original `client_id` and `last_name = 'After'`. Run the duplicate-key checks against the test destination.

   ```sql
   -- PostgreSQL. Run only in the disposable test source.
   UPDATE billing.clients
   SET last_name = 'After'
   WHERE client_number = 'AIRBYTE-TEST-001';
   ```

4. To verify the logical-delete path, set `is_deleted = TRUE` on that test client, commit, and sync the test connection again. Confirm the destination still has one row with the flag set and that adding `AND is_deleted = 0` to the destination query returns zero rows. This reproduces the staging predicate. For a full dbt run, use an isolated SQL Server instance with a database named `MedicalBilling_DW`, since the [source declaration](../medical_billing_dbt/models/staging/_sources.yml) pins the database name.
