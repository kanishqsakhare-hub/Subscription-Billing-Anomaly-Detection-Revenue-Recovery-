\set ON_ERROR_STOP on

\if :{?project_database}
\else
\set project_database saas_revenue_assurance
\endif
SELECT set_config('saas.project_database', :'project_database', false);

-- Phase 5: analytical indexes
-- Safe to rerun: every index uses IF NOT EXISTS and no source rows are changed.
-- Run with:
--   psql -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/03_indexes.sql

SELECT current_database() AS connected_database,
       current_user AS connected_user,
       version() AS server_version;

DO $guard$
BEGIN
    IF current_database() <> current_setting('saas.project_database') THEN
        RAISE EXCEPTION
            'Refusing to create indexes in database %. Expected %.',
            current_database(), current_setting('saas.project_database');
    END IF;
END
$guard$;

SET search_path = public;

-- Supports effective-dated plan lookup by subscription. The descending keys match
-- ORDER BY change_date DESC, change_id DESC; included plan IDs avoid heap access.
CREATE INDEX IF NOT EXISTS idx_plan_changes_subscription_effective
    ON plan_changes (subscription_id, change_date DESC, change_id DESC)
    INCLUDE (old_plan_id, new_plan_id);

-- Supports subscription invoice histories and ordered billing-cadence windows.
-- invoice_id makes ordering deterministic; amount and status cover common analyses.
CREATE INDEX IF NOT EXISTS idx_invoices_subscription_date
    ON invoices (subscription_id, invoice_date, invoice_id)
    INCLUDE (amount, status);

-- Supports selection of the final attempt for each invoice without sorting the
-- complete payment-attempt table.
CREATE INDEX IF NOT EXISTS idx_payment_attempts_invoice_sequence
    ON payment_attempts (invoice_id, attempt_number DESC, attempt_id DESC)
    INCLUDE (payment_id, outcome);

-- Failed payments are a selective minority. A partial covering index reduces work
-- for failure and recovery analyses while avoiding an index entry for successes.
CREATE INDEX IF NOT EXISTS idx_payments_failed_invoice
    ON payments (invoice_id)
    INCLUDE (record_source, subscription_id, amount, payment_date)
    WHERE status = 'failed';

-- No index is added for payments(payment_date) because successful collections cover
-- most payment rows in this dataset; the planner correctly favors a sequential scan.
-- No unresolved-recovery partial index is added because revenue_recovery is small and
-- its unresolved predicate retains a large share of the table.

ANALYZE subscriptions;
ANALYZE plan_changes;
ANALYZE invoices;
ANALYZE payments;
ANALYZE payment_attempts;
ANALYZE revenue_recovery;

SELECT schemaname,
       tablename,
       indexname,
       pg_size_pretty(pg_relation_size(format('%I.%I', schemaname, indexname)::regclass)) AS index_size
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
      'idx_plan_changes_subscription_effective',
      'idx_invoices_subscription_date',
      'idx_payment_attempts_invoice_sequence',
      'idx_payments_failed_invoice'
  )
ORDER BY tablename, indexname;
