-- Medical Billing Data Platform - synthetic OLTP source (PostgreSQL 14+)
-- Proposed identifiers for this portfolio project; not an export of a commercial EMR.
-- Run in a dedicated database. No real PHI.
BEGIN;

CREATE SCHEMA IF NOT EXISTS billing;

-- Automatically maintain updated_at for reliable cursor-based incremental syncs.
CREATE OR REPLACE FUNCTION billing.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- 1. Clients
CREATE TABLE billing.clients (
    client_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_number VARCHAR(30) NOT NULL UNIQUE,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    date_of_birth DATE NOT NULL,
    state_code CHAR(2),
    postal_code VARCHAR(10),
    client_status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (client_status IN ('active','inactive','deceased')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- 2. Providers (a simple practice label instead of a separate practice table)
CREATE TABLE billing.providers (
    provider_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider_number VARCHAR(30) NOT NULL UNIQUE,
    provider_name VARCHAR(200) NOT NULL,
    npi CHAR(10) UNIQUE CHECK (npi IS NULL OR npi ~ '^[0-9]{10}$'),
    specialty VARCHAR(100),
    practice_name VARCHAR(200) NOT NULL,
    state_code CHAR(2),
    provider_status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (provider_status IN ('active','inactive')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- 3. Payers
CREATE TABLE billing.payers (
    payer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payer_code VARCHAR(30) NOT NULL UNIQUE,
    payer_name VARCHAR(200) NOT NULL,
    payer_type VARCHAR(30) NOT NULL
        CHECK (payer_type IN ('commercial','medicare','medicaid','self_pay','other')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- 4. Service codes
CREATE TABLE billing.service_codes (
    service_code_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code_system VARCHAR(20) NOT NULL CHECK (code_system IN ('CPT','HCPCS','OTHER')),
    procedure_code VARCHAR(20) NOT NULL,
    description VARCHAR(255) NOT NULL,
    unit_type VARCHAR(20) NOT NULL DEFAULT 'unit'
        CHECK (unit_type IN ('unit','15_min','hour','visit')),
    default_charge_per_unit NUMERIC(12,2) NOT NULL CHECK (default_charge_per_unit >= 0),
    effective_from DATE,
    effective_to DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (code_system, procedure_code),
    CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from)
);

-- 5. Billing entries = delivered services/charges, before claim creation
CREATE TABLE billing.billing_entries (
    billing_entry_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_number VARCHAR(40) NOT NULL UNIQUE,
    client_id BIGINT NOT NULL REFERENCES billing.clients(client_id),
    provider_id BIGINT NOT NULL REFERENCES billing.providers(provider_id),
    service_code_id BIGINT NOT NULL REFERENCES billing.service_codes(service_code_id),
    service_date DATE NOT NULL,
    units NUMERIC(10,2) NOT NULL CHECK (units > 0),
    charge_per_unit NUMERIC(12,2) NOT NULL CHECK (charge_per_unit >= 0),
    charge_amount NUMERIC(14,2) GENERATED ALWAYS AS (ROUND(units * charge_per_unit,2)) STORED,
    entry_status VARCHAR(25) NOT NULL DEFAULT 'ready'
        CHECK (entry_status IN ('draft','ready','on_hold','billed','void')),
    billing_note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- 6. Claims: one logical claim can have multiple attempts in claim_events
CREATE TABLE billing.claims (
    claim_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_number VARCHAR(40) NOT NULL UNIQUE,
    client_id BIGINT NOT NULL REFERENCES billing.clients(client_id),
    provider_id BIGINT NOT NULL REFERENCES billing.providers(provider_id),
    payer_id BIGINT NOT NULL REFERENCES billing.payers(payer_id),
    claim_type VARCHAR(20) NOT NULL DEFAULT 'original'
        CHECK (claim_type IN ('original','replacement','void')),
    claim_status VARCHAR(25) NOT NULL DEFAULT 'draft'
        CHECK (claim_status IN ('draft','submitted','accepted','rejected','pending','partially_paid','paid','denied','closed','void')),
    first_submitted_at TIMESTAMPTZ,
    last_submitted_at TIMESTAMPTZ,
    payer_claim_number VARCHAR(60),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (last_submitted_at IS NULL OR first_submitted_at IS NULL OR last_submitted_at >= first_submitted_at)
);

-- 7. Claim lines connect individual charges to the claim.
-- A billing entry belongs to only one logical claim in this simplified model;
-- resubmission is tracked in claim_events rather than re-creating financial lines.
CREATE TABLE billing.claim_lines (
    claim_line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id BIGINT NOT NULL REFERENCES billing.claims(claim_id),
    billing_entry_id BIGINT NOT NULL UNIQUE REFERENCES billing.billing_entries(billing_entry_id),
    line_number INTEGER NOT NULL CHECK (line_number > 0),
    billed_amount NUMERIC(14,2) NOT NULL CHECK (billed_amount >= 0),
    allowed_amount NUMERIC(14,2) CHECK (allowed_amount IS NULL OR allowed_amount >= 0),
    patient_responsibility_amount NUMERIC(14,2)
        CHECK (patient_responsibility_amount IS NULL OR patient_responsibility_amount >= 0),
    line_status VARCHAR(25) NOT NULL DEFAULT 'unsubmitted'
        CHECK (line_status IN ('unsubmitted','submitted','pending','partially_paid','paid','denied','closed','void')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (claim_id, line_number)
);

-- 8. Claim events: submission, clearinghouse rejection, payer denial, appeal, etc.
CREATE TABLE billing.claim_events (
    claim_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_id BIGINT NOT NULL REFERENCES billing.claims(claim_id),
    claim_line_id BIGINT REFERENCES billing.claim_lines(claim_line_id),
    event_type VARCHAR(30) NOT NULL
        CHECK (event_type IN ('submitted','clearinghouse_accepted','clearinghouse_rejected',
          'payer_accepted','pending','denied','appealed','resubmitted',
          'partially_paid','paid','closed','voided')),
    event_at TIMESTAMPTZ NOT NULL,
    reason_code VARCHAR(30),
    reason_description VARCHAR(255),
    submission_reference VARCHAR(60),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- 9. Payment allocations, including negative reversals; payer vs patient receipts.
CREATE TABLE billing.payments (
    payment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_line_id BIGINT NOT NULL REFERENCES billing.claim_lines(claim_line_id),
    payer_id BIGINT REFERENCES billing.payers(payer_id),
    payment_source VARCHAR(20) NOT NULL CHECK (payment_source IN ('insurance','patient')),
    payment_date DATE NOT NULL,
    posted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    amount NUMERIC(14,2) NOT NULL CHECK (amount <> 0),
    transaction_type VARCHAR(20) NOT NULL DEFAULT 'payment'
        CHECK (transaction_type IN ('payment','reversal','refund')),
    reference_number VARCHAR(80),
    original_payment_id BIGINT REFERENCES billing.payments(payment_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK ((transaction_type = 'payment' AND amount > 0)
        OR (transaction_type IN ('reversal','refund') AND amount < 0)),
    CHECK ((payment_source = 'insurance' AND payer_id IS NOT NULL)
        OR payment_source = 'patient')
);

-- 10. Signed financial adjustments. Responsibility transfers are NOT write-offs:
-- the transfer must eventually be represented by offsetting entries if a
-- responsibility-level ledger is introduced. For this compact model, record
-- contractual adjustments/write-offs/reversals only; patient responsibility
-- is captured on claim_lines and does not reduce total A/R by itself.
CREATE TABLE billing.adjustments (
    adjustment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_line_id BIGINT NOT NULL REFERENCES billing.claim_lines(claim_line_id),
    adjustment_date DATE NOT NULL,
    posted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    adjustment_type VARCHAR(25) NOT NULL
        CHECK (adjustment_type IN ('contractual','write_off','other_reduction','reversal')),
    amount NUMERIC(14,2) NOT NULL CHECK (amount <> 0),
    adjustment_group_code VARCHAR(10),
    adjustment_reason_code VARCHAR(30),
    description VARCHAR(255),
    original_adjustment_id BIGINT REFERENCES billing.adjustments(adjustment_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK ((adjustment_type <> 'reversal' AND amount > 0)
        OR (adjustment_type = 'reversal' AND amount < 0))
);

-- Relationship & common report lookup indexes
CREATE INDEX idx_billing_entries_client_date ON billing.billing_entries(client_id, service_date);
CREATE INDEX idx_billing_entries_provider_date ON billing.billing_entries(provider_id, service_date);
CREATE INDEX idx_billing_entries_status ON billing.billing_entries(entry_status);
CREATE INDEX idx_claims_client ON billing.claims(client_id);
CREATE INDEX idx_claims_provider ON billing.claims(provider_id);
CREATE INDEX idx_claims_payer_status ON billing.claims(payer_id, claim_status);
CREATE INDEX idx_claim_lines_claim ON billing.claim_lines(claim_id);
CREATE INDEX idx_claim_events_claim_time ON billing.claim_events(claim_id, event_at);
CREATE INDEX idx_claim_events_line ON billing.claim_events(claim_line_id);
CREATE INDEX idx_payments_line_date ON billing.payments(claim_line_id, payment_date);
CREATE INDEX idx_adjustments_line_date ON billing.adjustments(claim_line_id, adjustment_date);

-- Update timestamps in the source for all ten tables.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
      'clients','providers','payers','service_codes','billing_entries',
      'claims','claim_lines','claim_events','payments','adjustments'
    ] LOOP
        EXECUTE format(
          'CREATE TRIGGER trg_%I_updated_at BEFORE UPDATE ON billing.%I '
          || 'FOR EACH ROW EXECUTE FUNCTION billing.set_updated_at()', t, t);
        EXECUTE format('CREATE INDEX idx_%I_updated_at ON billing.%I(updated_at)', t, t);
    END LOOP;
END $$;

COMMIT;

-- Reporting rule (not a materialized source field):
-- A/R as of a cutoff = SUM(billed claim line amounts)
--                      - SUM(payments posted by cutoff; signed)
--                      - SUM(adjustments posted by cutoff; signed).
-- Exclude voided / canceled charges according to documented financial policy.
-- Use posted_at (not merely payment_date or adjustment_date) for as-of reporting.
-- Validate claim/client/provider consistency in generation and dbt tests:
-- SQL foreign keys alone do not enforce these multi-table business rules.
