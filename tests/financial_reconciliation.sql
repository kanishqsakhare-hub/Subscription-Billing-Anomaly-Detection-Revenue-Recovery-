\set ON_ERROR_STOP on

-- Diagnostic reconciliation only. Findings are review candidates, not proof
-- of fraud, realized loss, or externally verified recovery.

\pset null '[NULL]'
SET search_path = public;

-- Invoice/payment cardinality, amount, status, and parent consistency.
SELECT check_name, candidate_rows
FROM (
    SELECT 'invoices without payments' AS check_name, count(*) AS candidate_rows
    FROM invoices i LEFT JOIN payments p USING (invoice_id) WHERE p.payment_id IS NULL
    UNION ALL SELECT 'invoices with multiple payments', count(*) FROM (SELECT invoice_id FROM payments GROUP BY invoice_id HAVING count(*) > 1) x
    UNION ALL SELECT 'payment/invoice amount mismatch', count(*) FROM payments p JOIN invoices i USING (invoice_id) WHERE p.amount <> i.amount
    UNION ALL SELECT 'paid invoice without successful payment', count(*) FROM invoices i WHERE i.status='paid' AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id=i.invoice_id AND p.status='successful')
    UNION ALL SELECT 'non-paid invoice with successful payment', count(*) FROM invoices i WHERE i.status<>'paid' AND EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id=i.invoice_id AND p.status='successful')
    UNION ALL SELECT 'payment/invoice subscription mismatch', count(*) FROM payments p JOIN invoices i USING (invoice_id) WHERE p.subscription_id<>i.subscription_id
) AS invoice_payment_checks
ORDER BY check_name;

-- Preserve and segment failed payments, including the known original anomaly.
SELECT p.record_source,
       i.status AS invoice_status,
       count(*) AS failed_payments,
       sum(p.amount) AS payment_amount_for_review
FROM payments p
JOIN invoices i USING (invoice_id)
WHERE p.status = 'failed'
GROUP BY p.record_source, i.status
ORDER BY p.record_source, i.status;

SELECT count(*) AS original_failed_payment_paid_invoice_candidates,
       sum(p.amount) AS amount_for_review
FROM payments p
JOIN invoices i USING (invoice_id)
WHERE p.record_source = 'original'
  AND p.status = 'failed'
  AND i.status = 'paid';

-- Attempt-level reconciliation. Attempts and payments remain separate grains.
-- Resolve the final attempt once so this remains practical before Phase 4 indexes.
WITH final_attempts AS (
    SELECT DISTINCT ON (invoice_id)
           invoice_id, payment_id, outcome
    FROM payment_attempts
    ORDER BY invoice_id, attempt_number DESC, attempt_id DESC
)
SELECT check_name, candidate_rows
FROM (
    SELECT 'attempts without payment_id' AS check_name, count(*) AS candidate_rows FROM payment_attempts WHERE payment_id IS NULL
    UNION ALL SELECT 'attempt/payment invoice or subscription mismatch', count(*) FROM payment_attempts a JOIN payments p USING (payment_id) WHERE a.invoice_id<>p.invoice_id OR a.subscription_id<>p.subscription_id
    UNION ALL SELECT 'linked final attempt/payment outcome mismatch', count(*)
      FROM final_attempts a JOIN payments p USING (payment_id)
      WHERE (a.outcome='successful') <> (p.status='successful')
    UNION ALL SELECT 'duplicate invoice attempt numbers', count(*) FROM (SELECT invoice_id,attempt_number FROM payment_attempts GROUP BY invoice_id,attempt_number HAVING count(*)>1) x
) AS attempt_checks
ORDER BY check_name;

-- Refund linkage and amount checks. Refunds are synthetic scenario records.
SELECT check_name, candidate_rows, amount_for_review
FROM (
    SELECT 'refund parent mismatch' AS check_name, count(*) AS candidate_rows, coalesce(sum(r.refund_amount),0) AS amount_for_review
    FROM refunds r JOIN invoices i USING (invoice_id) JOIN payments p USING (payment_id)
    WHERE r.subscription_id<>i.subscription_id OR r.invoice_id<>p.invoice_id OR r.subscription_id<>p.subscription_id
    UNION ALL SELECT 'refund exceeds linked payment', count(*), coalesce(sum(r.refund_amount),0)
    FROM refunds r JOIN payments p USING (payment_id) WHERE r.refund_amount>p.amount
    UNION ALL SELECT 'refund linked to failed payment', count(*), coalesce(sum(r.refund_amount),0)
    FROM refunds r JOIN payments p USING (payment_id) WHERE p.status='failed'
    UNION ALL SELECT 'refund dated before linked payment', count(*), coalesce(sum(r.refund_amount),0)
    FROM refunds r JOIN payments p USING (payment_id) WHERE r.refund_date<p.payment_date
) AS refund_checks
ORDER BY check_name;

SELECT reason, status, count(*) AS refunds, sum(refund_amount) AS refund_amount
FROM refunds
GROUP BY reason, status
ORDER BY reason, status;

-- Recovery linkage/status checks. Recovered amounts are simulated or inferred,
-- and must not be described as externally verified cash collections.
SELECT check_name, candidate_rows, amount_for_review
FROM (
    SELECT 'recovery invoice/subscription mismatch' AS check_name, count(*) AS candidate_rows, coalesce(sum(r.at_risk_amount),0) AS amount_for_review
    FROM revenue_recovery r JOIN invoices i USING (invoice_id) WHERE r.subscription_id<>i.subscription_id
    UNION ALL SELECT 'recovered amount exceeds at-risk amount', count(*), coalesce(sum(recovered_amount),0)
    FROM revenue_recovery WHERE recovered_amount>at_risk_amount
    UNION ALL SELECT 'recovery status/date mismatch', count(*), coalesce(sum(at_risk_amount),0)
    FROM revenue_recovery WHERE (status='recovered')<>(recovery_date IS NOT NULL)
    UNION ALL SELECT 'recovery without failed payment', count(*), coalesce(sum(r.at_risk_amount),0)
    FROM revenue_recovery r WHERE NOT EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id=r.invoice_id AND p.status='failed')
) AS recovery_checks
ORDER BY check_name;

SELECT record_source, recovery_type, status,
       count(*) AS cases,
       sum(at_risk_amount) AS at_risk_amount,
       sum(recovered_amount) AS simulated_or_inferred_recovered_amount
FROM revenue_recovery
GROUP BY record_source, recovery_type, status
ORDER BY record_source, recovery_type, status;
