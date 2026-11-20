"""Hourly medical-billing ELT: Airbyte -> dbt.

Requires Airflow's Airbyte and Docker providers, plus a dedicated dbt runner image.
"""
from datetime import datetime, timedelta, timezone
from dotenv import dotenv_values

from airflow import DAG
from airflow.sdk import literal
from airflow.providers.airbyte.operators.airbyte import AirbyteTriggerSyncOperator
from airflow.providers.docker.operators.docker import DockerOperator

AIRBYTE_CONNECTION_ID = "e8203ef0-0836-41ca-873e-fcee616c22e8"

with DAG(
    dag_id="medical_billing_ingestion",
    description="Incremental EMR ingestion and tested SQL Server dbt warehouse refresh",
    start_date=datetime(2026, 10, 1, tzinfo=timezone.utc),
    schedule="0 * * * *",
    catchup=False,
    max_active_runs=1,
    default_args={
        "retries": 1,
        "retry_delay": timedelta(minutes=2),
    },
    tags=["medical-billing", "airbyte", "dbt"],
) as dag:
    sync_postgres_to_sqlserver = AirbyteTriggerSyncOperator(
        task_id="sync_postgres_to_sqlserver",
        airbyte_conn_id="airbyte_default",
        connection_id=AIRBYTE_CONNECTION_ID,
        asynchronous=False,
        timeout=3600,
        wait_seconds=10,
    )

    build_and_test_warehouse = DockerOperator(
        task_id="dbt_build_and_test",
        image="medical-billing-dbt:runner",
        command=[
            "build",
            "--project-dir", "/workspace",
            "--profiles-dir", "/workspace/config"],
        docker_url="unix:///var/run/docker.sock",
        network_mode="bridge",
        mount_tmp_dir=False,
        private_environment=dict(
            dotenv_values("/opt/airflow/secrets/dbt.env")
        ),
        auto_remove="success",
        force_pull=False,
        do_xcom_push=False,
    )

    sync_postgres_to_sqlserver >> build_and_test_warehouse
