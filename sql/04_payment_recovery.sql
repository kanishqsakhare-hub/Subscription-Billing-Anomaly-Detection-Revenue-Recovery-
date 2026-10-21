\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'
SET search_path = public;
BEGIN READ ONLY;

-- Recovery records are synthetic or original-derived scenarios. Amounts in
-- revenue_recovery are modeled outcomes, not independently verified cash.
-- Original-derived attempts are proxies and must not be described as observed
-- historical retry behavior.

-- Q1. How did payment failure rates change monthly and by provenance?
-- Failure rate = failed payment rows / all payment rows in that segment.
-- Expected columns: month, record_source, payments, failed_payments,
-- failed_amount, failure_rate_pct.
-- Verified interpretation: through the snapshot the weighted failure rate is
-- 7.01% for original payments and 10.48% for synthetic payments.
SELECT date_trunc('month',payment_date)::DATE AS month,
       record_source,
       count(*) AS payments,
       count(*) FILTER (WHERE status='failed') AS failed_payments,
       sum(amount) FILTER (WHERE status='failed') AS failed_amount,
       round(100.0*count(*) FILTER (WHERE status='failed')/count(*),2) AS failure_rate_pct
FROM payments
WHERE payment_date<=DATE '2026-09-30'
GROUP BY 1,record_source
ORDER BY 1,record_source;

-- Q2. Which failure reasons contribute most to failed-payment value?
-- Expected columns: record_source, failure_reason, failed_payments,
-- failed_amount, share_of_source_failed_amount_pct.
-- Verified interpretation: all 4,797 original failures are unspecified; the five
-- synthetic reasons are balanced at 19.34%-20.83% of synthetic failed value.
SELECT record_source,
       coalesce(failure_reason,'unspecified') AS failure_reason,
       count(*) AS failed_payments,
       sum(amount) AS failed_amount,
       round(100.0*sum(amount)/sum(sum(amount)) OVER (PARTITION BY record_source),2) AS share_of_source_failed_amount_pct
FROM payments
WHERE status='failed'
GROUP BY record_source,coalesce(failure_reason,'unspecified')
ORDER BY record_source,failed_amount DESC;

-- Q3. How does attempt success vary by attempt number and provenance?
-- Synthetic rows model retry sequences; original_derived rows are one-to-one
-- inferred artifacts rather than observed retries.
-- Expected columns: record_source, attempt_number, attempts,
-- successful_attempts, attempted_amount, success_rate_pct.
-- Verified interpretation: first-attempt success is 92.99% for original-derived
-- proxies and 89.55% for synthetic rows; all 30,839 modeled second attempts succeed.
SELECT record_source,attempt_number,
       count(*) AS attempts,
       count(*) FILTER (WHERE outcome='successful') AS successful_attempts,
       sum(attempted_amount) AS attempted_amount,
       round(100.0*count(*) FILTER (WHERE outcome='successful')/count(*),2) AS success_rate_pct
FROM payment_attempts
GROUP BY record_source,attempt_number
ORDER BY record_source,attempt_number;

-- Q4. What is the invoice-level retry funnel?
-- A recovered-after-failure invoice has a successful attempt number greater
-- than its first failed attempt number. Results describe modeled sequences.
-- Expected columns: record_source, invoices_with_attempts,
-- invoices_with_failure, recovered_after_failure, unresolved_after_failure,
-- retry_recovery_rate_pct.
-- Verified interpretation: synthetic sequences model 30,839 recoveries from
-- 58,281 invoices with failures, a 52.91% retry rate; original-derived retries are not observed.
WITH invoice_attempts AS (
    SELECT record_source,invoice_id,
           min(attempt_number) FILTER (WHERE outcome='failed') AS first_failed_attempt,
           min(attempt_number) FILTER (WHERE outcome='successful') AS first_success_attempt
    FROM payment_attempts
    GROUP BY record_source,invoice_id
)
SELECT record_source,
       count(*) AS invoices_with_attempts,
       count(*) FILTER (WHERE first_failed_attempt IS NOT NULL) AS invoices_with_failure,
       count(*) FILTER (WHERE first_success_attempt>first_failed_attempt) AS recovered_after_failure,
       count(*) FILTER (WHERE first_failed_attempt IS NOT NULL AND first_success_attempt IS NULL) AS unresolved_after_failure,
       round(100.0*count(*) FILTER (WHERE first_success_attempt>first_failed_attempt)
             /nullif(count(*) FILTER (WHERE first_failed_attempt IS NOT NULL),0),2) AS retry_recovery_rate_pct
FROM invoice_attempts
GROUP BY record_source
ORDER BY record_source;

-- Q5. What is the modeled recovery funnel by provenance and status?
-- Recovery rate uses recovered_amount / at_risk_amount and remains a scenario
-- metric. Original-derived rows are review classifications, not recoveries.
-- Expected columns: record_source, status, cases, at_risk_amount,
-- modeled_recovered_amount, modeled_amount_recovery_pct.
-- Verified interpretation: synthetic modeled recovery is 1,644,008.00 across
-- 30,839 cases; 14,201 synthetic cases retain 761,892.00 modeled at risk.
SELECT record_source,status,
       count(*) AS cases,
       sum(at_risk_amount) AS at_risk_amount,
       sum(recovered_amount) AS modeled_recovered_amount,
       round(100.0*sum(recovered_amount)/nullif(sum(at_risk_amount),0),2) AS modeled_amount_recovery_pct
FROM revenue_recovery
GROUP BY record_source,status
ORDER BY record_source,status;

-- Q6. How old are unresolved modeled recovery cases at the snapshot?
-- Age begins at invoice due_date; future-due invoices are placed in not_due.
-- Expected columns: aging_bucket, cases, at_risk_amount.
-- Verified interpretation: 16,797 of 18,998 unresolved/review cases are over
-- 90 days past due at the snapshot, representing 894,411.00 modeled at risk.
SELECT CASE
           WHEN i.due_date>DATE '2026-09-30' THEN 'not_due'
           WHEN DATE '2026-09-30'-i.due_date<=30 THEN '0-30_days'
           WHEN DATE '2026-09-30'-i.due_date<=60 THEN '31-60_days'
           WHEN DATE '2026-09-30'-i.due_date<=90 THEN '61-90_days'
           ELSE 'over_90_days'
       END AS aging_bucket,
       count(*) AS cases,
       sum(r.at_risk_amount) AS at_risk_amount
FROM revenue_recovery r
JOIN invoices i USING(invoice_id)
WHERE r.status IN ('unrecovered','requires_review')
GROUP BY aging_bucket
ORDER BY min(CASE
    WHEN i.due_date>DATE '2026-09-30' THEN 0
    WHEN DATE '2026-09-30'-i.due_date<=30 THEN 1
    WHEN DATE '2026-09-30'-i.due_date<=60 THEN 2
    WHEN DATE '2026-09-30'-i.due_date<=90 THEN 3 ELSE 4 END);

-- Q7. What refund value offsets successful collections, by reason?
-- Refunds are synthetic. The percentage denominator is successful payment
-- value linked to refunded payments, not company-wide collections.
-- Expected columns: reason, refunds, refunded_amount,
-- linked_successful_payment_amount, refund_to_linked_payment_pct.
-- Verified interpretation: synthetic refunds total 251,650.00; reason-level
-- refund/payment ratios range from 57.65% to 61.77% for the linked payments.
SELECT r.reason,count(*) AS refunds,
       sum(r.refund_amount) AS refunded_amount,
       sum(p.amount) AS linked_successful_payment_amount,
       round(100.0*sum(r.refund_amount)/nullif(sum(p.amount),0),2) AS refund_to_linked_payment_pct
FROM refunds r
JOIN payments p USING(payment_id)
WHERE r.status='completed' AND p.status='successful'
GROUP BY r.reason
ORDER BY refunded_amount DESC;

-- Export 3 of 4: modeled recovery funnel, kept separate from cash collections.
\copy (SELECT record_source,status,count(*) cases,sum(at_risk_amount) at_risk_amount,sum(recovered_amount) modeled_recovered_amount,round(100.0*sum(recovered_amount)/nullif(sum(at_risk_amount),0),2) modeled_amount_recovery_pct FROM revenue_recovery GROUP BY record_source,status ORDER BY record_source,status) TO 'results/payment_recovery_funnel.csv' WITH (FORMAT csv, HEADER true);

COMMIT;
