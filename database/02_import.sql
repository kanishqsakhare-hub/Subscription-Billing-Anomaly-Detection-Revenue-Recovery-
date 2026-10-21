\set ON_ERROR_STOP on

\if :{?project_database}
\else
\set project_database saas_revenue_assurance
\endif
SELECT set_config('saas.project_database', :'project_database', false);

-- Run this file from the repository root so the client-side paths below resolve:
-- psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/02_import.sql
--
-- \copy reads files on the psql client machine. CSV headers are required and
-- unquoted empty fields are loaded as SQL NULL. The source CSVs are not changed.
-- This script expects empty Phase 2 tables and fails before importing otherwise.

BEGIN;

DO $database_guard$
BEGIN
    IF current_database() <> current_setting('saas.project_database') THEN
        RAISE EXCEPTION 'Refusing to import project data into database %. Expected %',
            current_database(), current_setting('saas.project_database');
    END IF;
END
$database_guard$;

SET LOCAL search_path = public;

DO $import_guard$
DECLARE
    populated_tables TEXT;
BEGIN
    SELECT string_agg(table_name, ', ' ORDER BY table_name)
    INTO populated_tables
    FROM (
        SELECT 'customers' AS table_name WHERE EXISTS (SELECT 1 FROM customers)
        UNION ALL SELECT 'subscription_plans' WHERE EXISTS (SELECT 1 FROM subscription_plans)
        UNION ALL SELECT 'subscriptions' WHERE EXISTS (SELECT 1 FROM subscriptions)
        UNION ALL SELECT 'plan_changes' WHERE EXISTS (SELECT 1 FROM plan_changes)
        UNION ALL SELECT 'churn_events' WHERE EXISTS (SELECT 1 FROM churn_events)
        UNION ALL SELECT 'invoices' WHERE EXISTS (SELECT 1 FROM invoices)
        UNION ALL SELECT 'payments' WHERE EXISTS (SELECT 1 FROM payments)
        UNION ALL SELECT 'payment_attempts' WHERE EXISTS (SELECT 1 FROM payment_attempts)
        UNION ALL SELECT 'refunds' WHERE EXISTS (SELECT 1 FROM refunds)
        UNION ALL SELECT 'revenue_recovery' WHERE EXISTS (SELECT 1 FROM revenue_recovery)
    ) AS populated;

    IF populated_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Import requires empty tables; data found in: %', populated_tables;
    END IF;
END
$import_guard$;

\copy customers (customer_id, signup_date, company_size, industry, acquisition_channel, country, record_source) FROM 'data/customers.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy subscription_plans (plan_id, plan_name, billing_interval, price, record_source) FROM 'data/subscription_plans.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy subscriptions (subscription_id, customer_id, start_date, end_date, status, plan_id, record_source) FROM 'data/subscriptions.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy plan_changes (change_id, subscription_id, old_plan_id, new_plan_id, change_date, record_source) FROM 'data/plan_changes.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy churn_events (churn_event_id, subscription_id, churn_date, churn_reason, record_source) FROM 'data/churn_events.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy invoices (invoice_id, subscription_id, invoice_date, due_date, amount, status, record_source) FROM 'data/invoices.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy payments (payment_id, subscription_id, payment_date, amount, status, failure_reason, invoice_id, record_source) FROM 'data/payments.csv' WITH (FORMAT csv, HEADER true, NULL '');

-- payment_attempts.csv stores populated payment_id values as decimal-form text
-- such as 1.0. Stage all fields as text, validate that payment_id is integral,
-- then convert it losslessly to BIGINT while preserving NULLs and every row.
CREATE TEMP TABLE payment_attempts_import (
    attempt_id TEXT,
    invoice_id TEXT,
    payment_id TEXT,
    subscription_id TEXT,
    attempt_date TEXT,
    attempt_number TEXT,
    attempted_amount TEXT,
    outcome TEXT,
    failure_reason TEXT,
    record_source TEXT
) ON COMMIT DROP;

\copy payment_attempts_import (attempt_id, invoice_id, payment_id, subscription_id, attempt_date, attempt_number, attempted_amount, outcome, failure_reason, record_source) FROM 'data/payment_attempts.csv' WITH (FORMAT csv, HEADER true, NULL '');

DO $payment_id_validation$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM payment_attempts_import
        WHERE payment_id IS NOT NULL
          AND (
              payment_id !~ '^[0-9]+(?:\.0+)?$'
              OR payment_id::NUMERIC <> trunc(payment_id::NUMERIC)
          )
    ) THEN
        RAISE EXCEPTION 'payment_attempts.csv contains a non-integral payment_id';
    END IF;
END
$payment_id_validation$;

INSERT INTO payment_attempts (
    attempt_id, invoice_id, payment_id, subscription_id, attempt_date,
    attempt_number, attempted_amount, outcome, failure_reason, record_source
)
SELECT
    attempt_id::BIGINT,
    invoice_id::BIGINT,
    payment_id::NUMERIC::BIGINT,
    subscription_id::BIGINT,
    attempt_date::DATE,
    attempt_number::INTEGER,
    attempted_amount::NUMERIC(12,2),
    outcome,
    failure_reason,
    record_source
FROM payment_attempts_import;

\copy refunds (refund_id, invoice_id, payment_id, subscription_id, refund_date, refund_amount, reason, status, record_source) FROM 'data/refunds.csv' WITH (FORMAT csv, HEADER true, NULL '');

\copy revenue_recovery (recovery_id, invoice_id, subscription_id, recovery_type, at_risk_amount, recovered_amount, recovery_date, status, record_source) FROM 'data/revenue_recovery.csv' WITH (FORMAT csv, HEADER true, NULL '');

COMMIT;

-- Compact import evidence. Detailed validations are in tests/data_integrity.sql.
SELECT *
FROM (
    VALUES
        (1, 'customers',             (SELECT count(*) FROM customers)),
        (2, 'subscription_plans',    (SELECT count(*) FROM subscription_plans)),
        (3, 'subscriptions',         (SELECT count(*) FROM subscriptions)),
        (4, 'plan_changes',          (SELECT count(*) FROM plan_changes)),
        (5, 'churn_events',          (SELECT count(*) FROM churn_events)),
        (6, 'invoices',              (SELECT count(*) FROM invoices)),
        (7, 'payments',              (SELECT count(*) FROM payments)),
        (8, 'payment_attempts',       (SELECT count(*) FROM payment_attempts)),
        (9, 'refunds',               (SELECT count(*) FROM refunds)),
        (10, 'revenue_recovery',     (SELECT count(*) FROM revenue_recovery))
) AS imported(load_order, table_name, row_count)
ORDER BY load_order;
