\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'
SET search_path = public;
BEGIN READ ONLY;

-- Candidate counts in this file identify records for review. They do not prove
-- fraud, revenue loss, or erroneous customer charges. Free plans, changes in
-- plan, modeled retries, and full-cycle synthetic billing can create legitimate
-- differences from simplified expectations.

-- Q1. Which paid invoices lack a successful payment, and are they explained by
-- documented modeled recovery cases?
-- Expected columns: invoice_source, payment_source, recovery_status,
-- candidate_invoices, amount_for_review.
-- Verified interpretation: 4,797 original cases totaling 240,760.00 are marked
-- requires_review; 30,839 synthetic cases totaling 1,644,008.00 are modeled recovered.
SELECT i.record_source AS invoice_source,
       p.record_source AS payment_source,
       coalesce(r.status,'no_recovery_record') AS recovery_status,
       count(*) AS candidate_invoices,
       sum(i.amount) AS amount_for_review
FROM invoices i
JOIN payments p USING (invoice_id)
LEFT JOIN revenue_recovery r USING (invoice_id)
WHERE i.status='paid' AND p.status<>'successful'
GROUP BY i.record_source, p.record_source, coalesce(r.status,'no_recovery_record')
ORDER BY i.record_source, recovery_status;

-- Q2. What is the complete invoice/payment status mismatch matrix?
-- Expected columns: invoice_status, payment_status, invoices, invoice_amount,
-- status_alignment.
-- Verified interpretation: 563,245 pairs align as paid/successful; 17,749 open
-- and 9,693 uncollectible invoices align to failures; 35,636 paid/failed need review.
SELECT i.status AS invoice_status,
       p.status AS payment_status,
       count(*) AS invoices,
       sum(i.amount) AS invoice_amount,
       CASE
           WHEN i.status='paid' AND p.status='successful' THEN 'aligned'
           WHEN i.status IN ('open','uncollectible') AND p.status='failed' THEN 'aligned_uncollected'
           ELSE 'review'
       END AS status_alignment
FROM invoices i
JOIN payments p USING (invoice_id)
GROUP BY i.status,p.status,status_alignment
ORDER BY i.status,p.status;

-- Q3. Are there duplicate billing candidates at invoice or payment grain?
-- Candidate rule: same subscription, event date, and amount occurring more
-- than once. Legitimate same-day adjustments would still require review.
-- Expected columns: candidate_type, duplicate_groups, affected_rows,
-- amount_across_affected_rows.
-- Verified interpretation: no duplicate invoice or payment groups meet the
-- same-subscription, same-date, same-amount candidate rule.
WITH duplicate_invoices AS (
    SELECT subscription_id,invoice_date,amount,count(*) AS rows
    FROM invoices GROUP BY subscription_id,invoice_date,amount HAVING count(*)>1
), duplicate_payments AS (
    SELECT subscription_id,payment_date,amount,count(*) AS rows
    FROM payments GROUP BY subscription_id,payment_date,amount HAVING count(*)>1
)
SELECT 'invoice' AS candidate_type, count(*) AS duplicate_groups,
       coalesce(sum(rows),0) AS affected_rows,
       coalesce(sum(amount*rows),0) AS amount_across_affected_rows
FROM duplicate_invoices
UNION ALL
SELECT 'payment',count(*),coalesce(sum(rows),0),coalesce(sum(amount*rows),0)
FROM duplicate_payments
ORDER BY candidate_type;

-- Q4. Which subscriptions have gaps between recurring invoices larger than the
-- plan cadence inferred from invoice price?
-- Monthly gaps >35 days and annual gaps >370 days are review candidates. This
-- is a gap screen, not proof of a missing bill; changes and churn need context.
-- Expected columns: inferred_interval, gap_candidates, affected_subscriptions,
-- maximum_gap_days.
-- Verified interpretation: no recurring invoice gaps exceed the 35-day monthly
-- or 370-day annual thresholds.
WITH sequenced AS (
    SELECT i.subscription_id,i.invoice_date,i.amount,
           lag(i.invoice_date) OVER (PARTITION BY i.subscription_id ORDER BY i.invoice_date,i.invoice_id) AS prior_invoice_date
    FROM invoices i
), classified AS (
    SELECT s.*,
           CASE WHEN EXISTS (SELECT 1 FROM subscription_plans p WHERE p.price=s.amount AND p.billing_interval='monthly') THEN 'monthly'
                WHEN EXISTS (SELECT 1 FROM subscription_plans p WHERE p.price=s.amount AND p.billing_interval='annual') THEN 'annual'
                ELSE 'unknown' END AS inferred_interval
    FROM sequenced s
), candidates AS (
    SELECT *,invoice_date-prior_invoice_date AS gap_days
    FROM classified
    WHERE prior_invoice_date IS NOT NULL
      AND ((inferred_interval='monthly' AND invoice_date-prior_invoice_date>35)
        OR (inferred_interval='annual' AND invoice_date-prior_invoice_date>370))
)
SELECT inferred_interval,count(*) AS gap_candidates,
       count(DISTINCT subscription_id) AS affected_subscriptions,
       max(gap_days) AS maximum_gap_days
FROM candidates
GROUP BY inferred_interval
ORDER BY inferred_interval;

-- Q5. Which invoices differ from the historically effective plan price?
-- Effective plan segments use the first old plan and subsequent plan changes.
-- Expected columns: variance_direction, candidate_invoices, variance_amount.
-- Verified interpretation: all 626,323 invoices match the effective plan price;
-- no under- or over-plan-price variance is present.
WITH first_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id,old_plan_id
    FROM plan_changes ORDER BY subscription_id,change_date,change_id
), events AS (
    SELECT s.subscription_id,s.start_date AS effective_date,coalesce(fc.old_plan_id,s.plan_id) AS plan_id
    FROM subscriptions s LEFT JOIN first_change fc USING(subscription_id)
    UNION ALL SELECT subscription_id,change_date,new_plan_id FROM plan_changes
), segments AS (
    SELECT subscription_id,plan_id,effective_date,
           lead(effective_date) OVER (PARTITION BY subscription_id ORDER BY effective_date,plan_id) AS next_date
    FROM events
), compared AS (
    SELECT i.invoice_id,i.amount,sp.price,
           CASE WHEN i.amount>sp.price THEN 'over_plan_price'
                WHEN i.amount<sp.price THEN 'under_plan_price'
                ELSE 'matches_plan_price' END AS variance_direction
    FROM invoices i
    JOIN segments seg ON seg.subscription_id=i.subscription_id
                     AND i.invoice_date>=seg.effective_date
                     AND (seg.next_date IS NULL OR i.invoice_date<seg.next_date)
    JOIN subscription_plans sp USING(plan_id)
)
SELECT variance_direction,count(*) AS candidate_invoices,
       sum(amount-price) AS variance_amount
FROM compared
GROUP BY variance_direction
ORDER BY variance_direction;

-- Q6. Which financial events occur after recorded churn?
-- Later payments/retries may be legitimate collection activity. Invoices after
-- churn are stronger missing-boundary candidates but still require review.
-- Expected columns: event_type, candidate_rows, amount_for_review,
-- affected_subscriptions.
-- Verified interpretation: no invoices occur after churn; 1,106 payments worth
-- 52,880.00 and 1,178 attempts worth 56,089.00 occur after churn for review.
SELECT event_type,candidate_rows,amount_for_review,affected_subscriptions
FROM (
    SELECT 'invoice_after_churn' AS event_type,count(*) AS candidate_rows,
           coalesce(sum(i.amount),0) AS amount_for_review,
           count(DISTINCT i.subscription_id) AS affected_subscriptions
    FROM invoices i JOIN subscriptions s USING(subscription_id)
    WHERE s.end_date IS NOT NULL AND i.invoice_date>s.end_date
    UNION ALL SELECT 'payment_after_churn',count(*),coalesce(sum(p.amount),0),count(DISTINCT p.subscription_id)
    FROM payments p JOIN subscriptions s USING(subscription_id)
    WHERE s.end_date IS NOT NULL AND p.payment_date>s.end_date
    UNION ALL SELECT 'attempt_after_churn',count(*),coalesce(sum(a.attempted_amount),0),count(DISTINCT a.subscription_id)
    FROM payment_attempts a JOIN subscriptions s USING(subscription_id)
    WHERE s.end_date IS NOT NULL AND a.attempt_date>s.end_date
) x
ORDER BY event_type;

-- Export 2 of 4: invoice-level review candidates. Modeled recovery status is
-- included so original review cases and synthetic recovery scenarios remain distinct.
\copy (SELECT i.invoice_id,i.subscription_id,i.invoice_date,i.amount,i.record_source,p.status payment_status,coalesce(r.status,'no_recovery_record') recovery_status,CASE WHEN p.record_source='original' THEN 'original_failed_payment_paid_invoice' ELSE 'synthetic_failed_payment_paid_invoice' END candidate_type FROM invoices i JOIN payments p USING(invoice_id) LEFT JOIN revenue_recovery r USING(invoice_id) WHERE i.status='paid' AND p.status='failed' ORDER BY i.invoice_id) TO 'results/billing_review_candidates.csv' WITH (FORMAT csv, HEADER true);

COMMIT;
