\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'
SET search_path = public;
BEGIN READ ONLY;

-- Phase 3 uses 2026-09-30 as the synthetic scenario snapshot. Original rows
-- retain their source dates, including dates outside the synthetic horizon.

-- Q1. How large is each entity and how is it split by provenance?
-- Expected columns: entity, record_source, row_count.
-- Verified interpretation: all documented provenance totals reconcile; the
-- largest fact sets are 657,162 attempts and 626,323 invoices/payments each.
SELECT entity, record_source, row_count
FROM (
    SELECT 'customers' AS entity, record_source, count(*) AS row_count FROM customers GROUP BY record_source
    UNION ALL SELECT 'subscriptions', record_source, count(*) FROM subscriptions GROUP BY record_source
    UNION ALL SELECT 'subscription_plans', record_source, count(*) FROM subscription_plans GROUP BY record_source
    UNION ALL SELECT 'invoices', record_source, count(*) FROM invoices GROUP BY record_source
    UNION ALL SELECT 'payments', record_source, count(*) FROM payments GROUP BY record_source
    UNION ALL SELECT 'payment_attempts', record_source, count(*) FROM payment_attempts GROUP BY record_source
    UNION ALL SELECT 'refunds', record_source, count(*) FROM refunds GROUP BY record_source
    UNION ALL SELECT 'revenue_recovery', record_source, count(*) FROM revenue_recovery GROUP BY record_source
    UNION ALL SELECT 'plan_changes', record_source, count(*) FROM plan_changes GROUP BY record_source
    UNION ALL SELECT 'churn_events', record_source, count(*) FROM churn_events GROUP BY record_source
) x
ORDER BY entity, record_source;

-- Q2. Which customer segments make up the subscriber base?
-- Expected columns: company_size, industry, customers, active_at_snapshot,
-- churned_by_snapshot, active_share_pct.
-- Verified interpretation: active share is tightly grouped from 61.73% to
-- 62.57% across the 12 size/industry segments; no segment is a clear outlier.
SELECT c.company_size,
       c.industry,
       count(*) AS customers,
       count(*) FILTER (
           WHERE s.start_date <= DATE '2026-09-30'
             AND (s.end_date IS NULL OR s.end_date > DATE '2026-09-30')
       ) AS active_at_snapshot,
       count(*) FILTER (WHERE s.end_date <= DATE '2026-09-30') AS churned_by_snapshot,
       round(100.0 * count(*) FILTER (
           WHERE s.start_date <= DATE '2026-09-30'
             AND (s.end_date IS NULL OR s.end_date > DATE '2026-09-30')
       ) / count(*), 2) AS active_share_pct
FROM customers c
JOIN subscriptions s USING (customer_id)
GROUP BY c.company_size, c.industry
ORDER BY customers DESC, c.company_size, c.industry;

-- Q3. What is the subscription status and observed lifetime by provenance?
-- Active lifetimes are right-censored at the snapshot; churned lifetimes end
-- on end_date. These are observed durations, not predicted customer lifetime.
-- Expected columns: record_source, status, subscriptions,
-- median_observed_days, average_observed_days.
-- Verified interpretation: median completed lifetime is 184 days for original
-- churn and 251 for synthetic churn; active medians are censored at 545/382 days.
SELECT record_source,
       status,
       count(*) AS subscriptions,
       percentile_cont(0.5) WITHIN GROUP (
           ORDER BY (coalesce(end_date, DATE '2026-09-30') - start_date)
       )::NUMERIC(12,1) AS median_observed_days,
       round(avg(coalesce(end_date, DATE '2026-09-30') - start_date), 1) AS average_observed_days
FROM subscriptions
WHERE start_date <= DATE '2026-09-30'
GROUP BY record_source, status
ORDER BY record_source, status;

-- Q4. How do invoice and payment outcomes align at the invoice grain?
-- Expected columns: invoice_source, invoice_status, payment_status, invoices,
-- invoice_amount, payment_amount.
-- Verified interpretation: 563,245 invoice/payment pairs are successful;
-- 35,636 paid invoices have failed payments and require contextual review.
SELECT i.record_source AS invoice_source,
       i.status AS invoice_status,
       p.status AS payment_status,
       count(*) AS invoices,
       sum(i.amount) AS invoice_amount,
       sum(p.amount) AS payment_amount
FROM invoices i
JOIN payments p USING (invoice_id)
GROUP BY i.record_source, i.status, p.status
ORDER BY i.record_source, i.status, p.status;

-- Q5. What temporal range does each event table cover?
-- Expected columns: entity, minimum_date, maximum_date, rows_after_snapshot.
-- Verified interpretation: invoices stop at the snapshot, while 1,791 payments,
-- 1,976 attempts, and 185 dated recoveries extend up to five days beyond it.
SELECT *
FROM (
    SELECT 'customers.signup' AS entity, min(signup_date) AS minimum_date,
           max(signup_date) AS maximum_date,
           count(*) FILTER (WHERE signup_date > DATE '2026-09-30') AS rows_after_snapshot
    FROM customers
    UNION ALL SELECT 'subscriptions.start', min(start_date), max(start_date), count(*) FILTER (WHERE start_date > DATE '2026-09-30') FROM subscriptions
    UNION ALL SELECT 'invoices.invoice', min(invoice_date), max(invoice_date), count(*) FILTER (WHERE invoice_date > DATE '2026-09-30') FROM invoices
    UNION ALL SELECT 'payments.payment', min(payment_date), max(payment_date), count(*) FILTER (WHERE payment_date > DATE '2026-09-30') FROM payments
    UNION ALL SELECT 'attempts.attempt', min(attempt_date), max(attempt_date), count(*) FILTER (WHERE attempt_date > DATE '2026-09-30') FROM payment_attempts
    UNION ALL SELECT 'refunds.refund', min(refund_date), max(refund_date), count(*) FILTER (WHERE refund_date > DATE '2026-09-30') FROM refunds
    UNION ALL SELECT 'recovery.recovery', min(recovery_date), max(recovery_date), count(*) FILTER (WHERE recovery_date > DATE '2026-09-30') FROM revenue_recovery
    UNION ALL SELECT 'plan_changes.change', min(change_date), max(change_date), count(*) FILTER (WHERE change_date > DATE '2026-09-30') FROM plan_changes
    UNION ALL SELECT 'churn.churn', min(churn_date), max(churn_date), count(*) FILTER (WHERE churn_date > DATE '2026-09-30') FROM churn_events
) ranges
ORDER BY entity;

COMMIT;
