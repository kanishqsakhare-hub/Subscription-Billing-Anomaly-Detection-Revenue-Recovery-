\set ON_ERROR_STOP on

-- Run after database/02_import.sql. A result of PASS is expected for every
-- critical check. Informational date checks preserve known post-churn events.

\pset null '[NULL]'
SET search_path = public;

-- Expected and actual table totals.
WITH expected(load_order, table_name, expected_rows) AS (
    VALUES
        (1, 'customers', 100000::BIGINT),
        (2, 'subscription_plans', 7::BIGINT),
        (3, 'subscriptions', 100000::BIGINT),
        (4, 'plan_changes', 2166::BIGINT),
        (5, 'churn_events', 38034::BIGINT),
        (6, 'invoices', 626323::BIGINT),
        (7, 'payments', 626323::BIGINT),
        (8, 'payment_attempts', 657162::BIGINT),
        (9, 'refunds', 8121::BIGINT),
        (10, 'revenue_recovery', 49837::BIGINT)
), actual(load_order, table_name, actual_rows) AS (
    VALUES
        (1, 'customers', (SELECT count(*) FROM customers)),
        (2, 'subscription_plans', (SELECT count(*) FROM subscription_plans)),
        (3, 'subscriptions', (SELECT count(*) FROM subscriptions)),
        (4, 'plan_changes', (SELECT count(*) FROM plan_changes)),
        (5, 'churn_events', (SELECT count(*) FROM churn_events)),
        (6, 'invoices', (SELECT count(*) FROM invoices)),
        (7, 'payments', (SELECT count(*) FROM payments)),
        (8, 'payment_attempts', (SELECT count(*) FROM payment_attempts)),
        (9, 'refunds', (SELECT count(*) FROM refunds)),
        (10, 'revenue_recovery', (SELECT count(*) FROM revenue_recovery))
)
SELECT e.table_name, e.expected_rows, a.actual_rows,
       CASE WHEN e.expected_rows = a.actual_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM expected e
JOIN actual a USING (load_order, table_name)
ORDER BY e.load_order;

-- PK uniqueness is independently reported even though PK constraints enforce it.
SELECT *
FROM (
    SELECT 'customers.customer_id uniqueness' AS check_name,
           count(*) - count(DISTINCT customer_id) AS violations FROM customers
    UNION ALL SELECT 'subscription_plans.plan_id uniqueness', count(*) - count(DISTINCT plan_id) FROM subscription_plans
    UNION ALL SELECT 'subscriptions.subscription_id uniqueness', count(*) - count(DISTINCT subscription_id) FROM subscriptions
    UNION ALL SELECT 'plan_changes.change_id uniqueness', count(*) - count(DISTINCT change_id) FROM plan_changes
    UNION ALL SELECT 'churn_events.churn_event_id uniqueness', count(*) - count(DISTINCT churn_event_id) FROM churn_events
    UNION ALL SELECT 'invoices.invoice_id uniqueness', count(*) - count(DISTINCT invoice_id) FROM invoices
    UNION ALL SELECT 'payments.payment_id uniqueness', count(*) - count(DISTINCT payment_id) FROM payments
    UNION ALL SELECT 'payment_attempts.attempt_id uniqueness', count(*) - count(DISTINCT attempt_id) FROM payment_attempts
    UNION ALL SELECT 'refunds.refund_id uniqueness', count(*) - count(DISTINCT refund_id) FROM refunds
    UNION ALL SELECT 'revenue_recovery.recovery_id uniqueness', count(*) - count(DISTINCT recovery_id) FROM revenue_recovery
) AS checks
CROSS JOIN LATERAL (SELECT CASE WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result) AS status
ORDER BY check_name;

-- Required-column null checks plus expected optional-null totals.
SELECT check_name, null_count, expected_nulls,
       CASE WHEN null_count = expected_nulls THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 'customers required columns' AS check_name,
           count(*) FILTER (WHERE customer_id IS NULL OR signup_date IS NULL OR company_size IS NULL OR industry IS NULL OR acquisition_channel IS NULL OR country IS NULL OR record_source IS NULL) AS null_count,
           0::BIGINT AS expected_nulls FROM customers
    UNION ALL SELECT 'subscription_plans required columns', count(*) FILTER (WHERE plan_id IS NULL OR plan_name IS NULL OR billing_interval IS NULL OR price IS NULL OR record_source IS NULL), 0 FROM subscription_plans
    UNION ALL SELECT 'subscriptions required columns', count(*) FILTER (WHERE subscription_id IS NULL OR customer_id IS NULL OR start_date IS NULL OR status IS NULL OR plan_id IS NULL OR record_source IS NULL), 0 FROM subscriptions
    UNION ALL SELECT 'plan_changes required columns', count(*) FILTER (WHERE change_id IS NULL OR subscription_id IS NULL OR old_plan_id IS NULL OR new_plan_id IS NULL OR change_date IS NULL OR record_source IS NULL), 0 FROM plan_changes
    UNION ALL SELECT 'churn_events required columns', count(*) FILTER (WHERE churn_event_id IS NULL OR subscription_id IS NULL OR churn_date IS NULL OR churn_reason IS NULL OR record_source IS NULL), 0 FROM churn_events
    UNION ALL SELECT 'invoices required columns', count(*) FILTER (WHERE invoice_id IS NULL OR subscription_id IS NULL OR invoice_date IS NULL OR due_date IS NULL OR amount IS NULL OR status IS NULL OR record_source IS NULL), 0 FROM invoices
    UNION ALL SELECT 'payments required columns', count(*) FILTER (WHERE payment_id IS NULL OR subscription_id IS NULL OR payment_date IS NULL OR amount IS NULL OR status IS NULL OR invoice_id IS NULL OR record_source IS NULL), 0 FROM payments
    UNION ALL SELECT 'payment_attempts required columns', count(*) FILTER (WHERE attempt_id IS NULL OR invoice_id IS NULL OR subscription_id IS NULL OR attempt_date IS NULL OR attempt_number IS NULL OR attempted_amount IS NULL OR outcome IS NULL OR record_source IS NULL), 0 FROM payment_attempts
    UNION ALL SELECT 'refunds required columns', count(*) FILTER (WHERE refund_id IS NULL OR invoice_id IS NULL OR payment_id IS NULL OR subscription_id IS NULL OR refund_date IS NULL OR refund_amount IS NULL OR reason IS NULL OR status IS NULL OR record_source IS NULL), 0 FROM refunds
    UNION ALL SELECT 'revenue_recovery required columns', count(*) FILTER (WHERE recovery_id IS NULL OR invoice_id IS NULL OR subscription_id IS NULL OR recovery_type IS NULL OR at_risk_amount IS NULL OR recovered_amount IS NULL OR status IS NULL OR record_source IS NULL), 0 FROM revenue_recovery
    UNION ALL SELECT 'subscriptions.end_date', count(*) FILTER (WHERE end_date IS NULL), 61966 FROM subscriptions
    UNION ALL SELECT 'payments.failure_reason', count(*) FILTER (WHERE failure_reason IS NULL), 568042 FROM payments
    UNION ALL SELECT 'payment_attempts.payment_id', count(*) FILTER (WHERE payment_id IS NULL), 30839 FROM payment_attempts
    UNION ALL SELECT 'payment_attempts.failure_reason', count(*) FILTER (WHERE failure_reason IS NULL), 594084 FROM payment_attempts
    UNION ALL SELECT 'revenue_recovery.recovery_date', count(*) FILTER (WHERE recovery_date IS NULL), 18998 FROM revenue_recovery
) AS null_checks
ORDER BY check_name;

-- Explicit FK orphan checks. FK constraints also prevent these after import.
SELECT check_name, violations,
       CASE WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 'subscriptions -> customers' AS check_name, count(*) AS violations
    FROM subscriptions s LEFT JOIN customers c USING (customer_id) WHERE c.customer_id IS NULL
    UNION ALL SELECT 'subscriptions -> plans', count(*) FROM subscriptions s LEFT JOIN subscription_plans p USING (plan_id) WHERE p.plan_id IS NULL
    UNION ALL SELECT 'plan_changes -> subscriptions', count(*) FROM plan_changes x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'plan_changes.old_plan -> plans', count(*) FROM plan_changes x LEFT JOIN subscription_plans p ON p.plan_id=x.old_plan_id WHERE p.plan_id IS NULL
    UNION ALL SELECT 'plan_changes.new_plan -> plans', count(*) FROM plan_changes x LEFT JOIN subscription_plans p ON p.plan_id=x.new_plan_id WHERE p.plan_id IS NULL
    UNION ALL SELECT 'churn_events -> subscriptions', count(*) FROM churn_events x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'invoices -> subscriptions', count(*) FROM invoices x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'payments -> invoices', count(*) FROM payments x LEFT JOIN invoices i USING (invoice_id) WHERE i.invoice_id IS NULL
    UNION ALL SELECT 'payments -> subscriptions', count(*) FROM payments x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'attempts -> invoices', count(*) FROM payment_attempts x LEFT JOIN invoices i USING (invoice_id) WHERE i.invoice_id IS NULL
    UNION ALL SELECT 'attempts -> payments', count(*) FROM payment_attempts x LEFT JOIN payments p USING (payment_id) WHERE x.payment_id IS NOT NULL AND p.payment_id IS NULL
    UNION ALL SELECT 'attempts -> subscriptions', count(*) FROM payment_attempts x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'refunds -> invoices', count(*) FROM refunds x LEFT JOIN invoices i USING (invoice_id) WHERE i.invoice_id IS NULL
    UNION ALL SELECT 'refunds -> payments', count(*) FROM refunds x LEFT JOIN payments p USING (payment_id) WHERE p.payment_id IS NULL
    UNION ALL SELECT 'refunds -> subscriptions', count(*) FROM refunds x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
    UNION ALL SELECT 'recovery -> invoices', count(*) FROM revenue_recovery x LEFT JOIN invoices i USING (invoice_id) WHERE i.invoice_id IS NULL
    UNION ALL SELECT 'recovery -> subscriptions', count(*) FROM revenue_recovery x LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL
) AS orphan_checks
ORDER BY check_name;

-- Cross-table consistency and date rules. Post-end events are reported rather
-- than failed because collections and retries can legitimately follow churn.
SELECT check_name, violations, severity,
       CASE WHEN severity = 'INFO' THEN 'REVIEW'
            WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 'subscription end before start' AS check_name, count(*) AS violations, 'ERROR' AS severity
    FROM subscriptions WHERE end_date < start_date
    UNION ALL SELECT 'active/churned end-date mismatch', count(*), 'ERROR' FROM subscriptions WHERE (status='active') <> (end_date IS NULL)
    UNION ALL SELECT 'plan change before subscription start', count(*), 'ERROR' FROM plan_changes p JOIN subscriptions s USING (subscription_id) WHERE p.change_date < s.start_date
    UNION ALL SELECT 'churn before subscription start', count(*), 'ERROR' FROM churn_events c JOIN subscriptions s USING (subscription_id) WHERE c.churn_date < s.start_date
    UNION ALL SELECT 'invoice before subscription start', count(*), 'ERROR' FROM invoices i JOIN subscriptions s USING (subscription_id) WHERE i.invoice_date < s.start_date
    UNION ALL SELECT 'invoice due before invoice date', count(*), 'ERROR' FROM invoices WHERE due_date < invoice_date
    UNION ALL SELECT 'payment before invoice date', count(*), 'ERROR' FROM payments p JOIN invoices i USING (invoice_id) WHERE p.payment_date < i.invoice_date
    UNION ALL SELECT 'attempt before invoice date', count(*), 'ERROR' FROM payment_attempts a JOIN invoices i USING (invoice_id) WHERE a.attempt_date < i.invoice_date
    UNION ALL SELECT 'refund before payment date', count(*), 'ERROR' FROM refunds r JOIN payments p USING (payment_id) WHERE r.refund_date < p.payment_date
    UNION ALL SELECT 'recovery before invoice date', count(*), 'ERROR' FROM revenue_recovery r JOIN invoices i USING (invoice_id) WHERE r.recovery_date < i.invoice_date
    UNION ALL SELECT 'churn event differs from subscription end/status', count(*), 'ERROR' FROM churn_events c JOIN subscriptions s USING (subscription_id) WHERE s.status <> 'churned' OR c.churn_date <> s.end_date
    UNION ALL SELECT 'payment invoice/subscription mismatch', count(*), 'ERROR' FROM payments p JOIN invoices i USING (invoice_id) WHERE p.subscription_id <> i.subscription_id
    UNION ALL SELECT 'attempt invoice/subscription mismatch', count(*), 'ERROR' FROM payment_attempts a JOIN invoices i USING (invoice_id) WHERE a.subscription_id <> i.subscription_id
    UNION ALL SELECT 'attempt payment parent mismatch', count(*), 'ERROR' FROM payment_attempts a JOIN payments p USING (payment_id) WHERE a.invoice_id <> p.invoice_id OR a.subscription_id <> p.subscription_id
    UNION ALL SELECT 'refund parent mismatch', count(*), 'ERROR' FROM refunds r JOIN invoices i USING (invoice_id) JOIN payments p USING (payment_id) WHERE r.subscription_id <> i.subscription_id OR r.invoice_id <> p.invoice_id OR r.subscription_id <> p.subscription_id
    UNION ALL SELECT 'recovery invoice/subscription mismatch', count(*), 'ERROR' FROM revenue_recovery r JOIN invoices i USING (invoice_id) WHERE r.subscription_id <> i.subscription_id
    UNION ALL SELECT 'payments after subscription end', count(*), 'INFO' FROM payments p JOIN subscriptions s USING (subscription_id) WHERE s.end_date IS NOT NULL AND p.payment_date > s.end_date
    UNION ALL SELECT 'attempts after subscription end', count(*), 'INFO' FROM payment_attempts a JOIN subscriptions s USING (subscription_id) WHERE s.end_date IS NOT NULL AND a.attempt_date > s.end_date
    UNION ALL SELECT 'recoveries after subscription end', count(*), 'INFO' FROM revenue_recovery r JOIN subscriptions s USING (subscription_id) WHERE s.end_date IS NOT NULL AND r.recovery_date > s.end_date
) AS date_checks
ORDER BY severity DESC, check_name;

-- Provenance reconciliation.
SELECT entity, record_source, expected_rows, actual_rows,
       CASE WHEN expected_rows = actual_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT 'customers' AS entity, src.record_source, src.expected_rows, count(c.*) AS actual_rows
    FROM (VALUES ('original',25000::BIGINT),('synthetic',75000::BIGINT)) src(record_source,expected_rows)
    LEFT JOIN customers c ON c.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'subscriptions', src.record_source, src.expected_rows, count(s.*) FROM (VALUES ('original',25000::BIGINT),('synthetic',75000::BIGINT)) src(record_source,expected_rows) LEFT JOIN subscriptions s ON s.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'subscription_plans', 'original', 7, count(*) FROM subscription_plans WHERE record_source='original'
    UNION ALL SELECT 'invoices', src.record_source, src.expected_rows, count(i.*) FROM (VALUES ('original',68411::BIGINT),('synthetic',557912::BIGINT)) src(record_source,expected_rows) LEFT JOIN invoices i ON i.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'payments', src.record_source, src.expected_rows, count(p.*) FROM (VALUES ('original',68411::BIGINT),('synthetic',557912::BIGINT)) src(record_source,expected_rows) LEFT JOIN payments p ON p.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'plan_changes', src.record_source, src.expected_rows, count(p.*) FROM (VALUES ('original',787::BIGINT),('synthetic',1379::BIGINT)) src(record_source,expected_rows) LEFT JOIN plan_changes p ON p.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'churn_events', src.record_source, src.expected_rows, count(c.*) FROM (VALUES ('original',9757::BIGINT),('synthetic',28277::BIGINT)) src(record_source,expected_rows) LEFT JOIN churn_events c ON c.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'payment_attempts', src.record_source, src.expected_rows, count(a.*) FROM (VALUES ('synthetic',588751::BIGINT),('original_derived',68411::BIGINT)) src(record_source,expected_rows) LEFT JOIN payment_attempts a ON a.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
    UNION ALL SELECT 'refunds', 'synthetic', 8121, count(*) FROM refunds WHERE record_source='synthetic'
    UNION ALL SELECT 'revenue_recovery', src.record_source, src.expected_rows, count(r.*) FROM (VALUES ('synthetic',45040::BIGINT),('original_derived',4797::BIGINT)) src(record_source,expected_rows) LEFT JOIN revenue_recovery r ON r.record_source=src.record_source GROUP BY src.record_source,src.expected_rows
) AS provenance
ORDER BY entity, record_source;
