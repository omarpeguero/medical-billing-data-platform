# Medical billing source data simulator

This simulator populates **your existing PostgreSQL `EMR_source`** database under the `billing` schema. It is written against the 10-table SQL DDL supplied with this project. All records are synthetic.

## Setup

1. Execute `medical_billing_postgres_schema.sql` in **pgAdmin Query Tool** connected to `EMR_source` (skip if your 10 tables are already created).
2. Install Python 3.11+ and create a virtual environment:

   ```bash
   python -m venv .venv
   # Windows PowerShell
   .venv\Scripts\Activate.ps1
   pip install -r requirements_medical_billing_simulator.txt
   ```

3. Copy `.env.medical_billing.example` to `.env` **in the same folder as** `medical_billing_simulator.py`. Edit `PGUSER`, `PGPASSWORD`, etc. Example:

   ```ini
   PGHOST=localhost
   PGPORT=5432
   PGDATABASE=EMR_source
   PGUSER=postgres
   PGPASSWORD=your_postgres_password_here
   ```

4. Run:

   ```bash
   python medical_billing_simulator.py --init-days 365 --interval-seconds 60
   ```

The first run seeds the master data and up to one year's historical activity. Then it continuously simulates **one business hour per real minute**, indefinitely while the process stays running. Use `Ctrl+C` to stop.

## Commands

| Command | Behavior |
|---|---|
| `python medical_billing_simulator.py --once` | One incremental tick then exit (suitable for testing) |
| `python medical_billing_simulator.py --verify` | Read-only row counts and financial-balance check |
| `python medical_billing_simulator.py --init-days 90 --interval-seconds 30` | 90-day initial seed, then 1 simulated hour every 30s |
| `python medical_billing_simulator.py --hours-per-tick 24 --interval-seconds 60` | 1 synthetic day each minute (fast demo) |
| `python medical_billing_simulator.py --base-daily-entries 50 --annual-growth 0.15` | Higher case volume with 15% modeled annual growth |

Only one simulator process should run against a given database. Initial historical seeding is skipped when synthetic billing entries already exist. **Do not delete all synthetic entries or reset sequences casually**; the simulator depends on consistent FK relationships. The script does not create tables or drop/truncate anything.

### Growth and business realism

- Demand grows annually (`--annual-growth`, default 12%); weekends produce few visits.
- Monthly seasonal multipliers affect service volume; holidays are not specially modeled.
- Patient registrations and provider capacity increase periodically.
- Different payers have different denial rates, adjudication delays and reimbursement ratios.
- Services are associated with valid clients, providers, service codes; financial lines reference their original billable charges.
- Claims move through submitted → accepted / rejected → denied / paid / partially paid / closed, including resubmissions and appeals.
- Partial insurance/patient payments, contractual reductions and write-offs are appended as financial transactions.
- Unbilled `draft` and `on_hold` services create operational backlog.

**Limitations:** This is a portfolio simulator, not an actual EMR or adjudication engine. Rates, payer names, case volumes and probabilities are fictional. Code descriptions are simplified. The generator doesn't simulate every real-world medical billing rule or X12 EDI file.

### Airbyte replication

- PostgreSQL source: host where PG runs, `billing` schema, all 10 tables.
- Azure SQL destination: configure with the supported connector version. Verify destination features before relying on CDC.
- Prefer **CDC** using PostgreSQL's WAL when feasible, since this captures inserts and updates; otherwise configure supported incremental cursors using `updated_at`, noting that this cannot represent deletes and may have timestamp tie/late-event limitations depending on connector behavior.
- Airbyte's PostgreSQL source may require WAL configuration, replication privileges, and network access. This isn't configured by the Python script.
- For Airflow, run this generator as a separate persistent process or service. Airflow should orchestrate ingestion, dbt transformations and tests; it does not need to own the continuously running source application.

### Validation SQL (run in pgAdmin)

```sql
SELECT 'billing_entries' AS table_name, COUNT(*) AS n FROM billing.billing_entries
UNION ALL SELECT 'claims', COUNT(*) FROM billing.claims
UNION ALL SELECT 'claim_events', COUNT(*) FROM billing.claim_events
UNION ALL SELECT 'payments', COUNT(*) FROM billing.payments
UNION ALL SELECT 'adjustments', COUNT(*) FROM billing.adjustments;

SELECT claim_status, COUNT(*) AS claims FROM billing.claims
GROUP BY claim_status ORDER BY claims DESC;

SELECT DATE_TRUNC('month', service_date)::date AS month,
       COUNT(*) AS services, SUM(charge_amount) AS charges
FROM billing.billing_entries GROUP BY 1 ORDER BY 1;

SELECT COALESCE(SUM(billed_amount),0) AS billed
FROM billing.claim_lines;
```

**Financial definition:** Claimed A/R = billed claim-line amounts − signed payments − signed financial reductions (as of their posted timestamps). Billing entries not yet claimed are **unbilled charges**, not claim A/R. Patient responsibility is part of the allowed balance and does not independently reduce total A/R.

### Operational notes

- Real-time simulation continues only while the script is running. For a persistent demonstration, supervise it with Windows Task Scheduler, a service manager, or Docker restart policies.
- This simulator is **accelerated** by default. One minute of wall time advances one hour of simulated business time. For literal real-time pacing set `--interval-seconds 3600 --hours-per-tick 1`.
- Logs use local wall-clock time; claim and payment business timestamps use simulated time. Historical seed `created_at`/`updated_at` are stamped when inserted, while event, service and posting dates reflect historical business dates. This supports a realistic initial load plus ongoing source changes.
- If the process stops, synthetic time resumes at the newest generated `billing_entries.entry_number` marker, approximately. Empty after-hours ticks cannot be recovered exactly. Run one simulator at a time and avoid clock-sensitive production assumptions.
- Backfill checkpoints are based on existing synthetic billing entries, not a separate control table. If a backfill fails partway through, subsequent runs skip remaining historical periods. For a full rebuild, start from a fresh dedicated project database.
