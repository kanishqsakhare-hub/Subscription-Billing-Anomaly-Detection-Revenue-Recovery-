\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'
SET search_path = public;
BEGIN READ ONLY;

-- Financial definitions used in this file:
-- * Reporting window: calendar months through the 2026-09-30 scenario snapshot.
-- * Billed value: invoice amount; it is not recognized revenue.
-- * Collected value: successful payment amount in the payment month.
-- * Net collection proxy: collected value less completed refunds in the event
--   month. Modeled revenue_recovery is excluded from cash metrics.
-- * Contracted MRR: monthly plan price, or annual plan price divided by 12,
--   for subscriptions active at the snapshot. ARR run-rate is MRR * 12.

-- Q1. How did billed value, collections, refunds, and the net collection proxy
-- change by calendar month?
-- Expected columns: month, billed_amount, collected_amount, refunded_amount,
-- net_collection_proxy, collection_to_bill_pct.
-- Verified interpretation: through the snapshot, billed value is 33,555,578.00,
-- collections are 30,087,516.00, refunds are 251,650.00, and the net collection
-- proxy is 29,835,866.00; collection/bill timing yields an 89.66% aggregate ratio.
WITH months AS (
    SELECT generate_series(DATE '2023-01-01', DATE '2026-09-01', INTERVAL '1 month')::DATE AS month
), billed AS (
    SELECT date_trunc('month', invoice_date)::DATE AS month, sum(amount) AS amount
    FROM invoices WHERE invoice_date <= DATE '2026-09-30' GROUP BY 1
), collected AS (
    SELECT date_trunc('month', payment_date)::DATE AS month, sum(amount) AS amount
    FROM payments WHERE status='successful' AND payment_date <= DATE '2026-09-30' GROUP BY 1
), refunded AS (
    SELECT date_trunc('month', refund_date)::DATE AS month, sum(refund_amount) AS amount
    FROM refunds WHERE status='completed' AND refund_date <= DATE '2026-09-30' GROUP BY 1
)
SELECT m.month,
       coalesce(b.amount, 0) AS billed_amount,
       coalesce(c.amount, 0) AS collected_amount,
       coalesce(r.amount, 0) AS refunded_amount,
       coalesce(c.amount, 0) - coalesce(r.amount, 0) AS net_collection_proxy,
       round(100.0 * coalesce(c.amount, 0) / nullif(b.amount, 0), 2) AS collection_to_bill_pct
FROM months m
LEFT JOIN billed b USING (month)
LEFT JOIN collected c USING (month)
LEFT JOIN refunded r USING (month)
ORDER BY m.month;

-- Q2. What was month-over-month growth in successful collections?
-- Expected columns: month, collected_amount, prior_month_collected,
-- month_over_month_growth_pct, three_month_moving_average.
-- Verified interpretation: monthly collection growth ranges from -7.62% to
-- 48.18%; September 2026 declined 0.82% with a 1,208,105.00 three-month average.
WITH monthly AS (
    SELECT date_trunc('month', payment_date)::DATE AS month, sum(amount) AS collected_amount
    FROM payments
    WHERE status='successful' AND payment_date <= DATE '2026-09-30'
    GROUP BY 1
), trended AS (
    SELECT month, collected_amount,
           lag(collected_amount) OVER (ORDER BY month) AS prior_month_collected,
           avg(collected_amount) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_average
    FROM monthly
)
SELECT month, collected_amount, prior_month_collected,
       round(100.0 * (collected_amount - prior_month_collected) / nullif(prior_month_collected, 0), 2) AS month_over_month_growth_pct,
       round(moving_average, 2) AS three_month_moving_average
FROM trended
ORDER BY month;

-- Q3. How do billing and collection outcomes differ by provenance?
-- Expected columns: record_source, invoices, billed_amount,
-- successful_collections, failed_payment_value, completed_refunds,
-- net_collection_proxy.
-- Verified interpretation: original rows show 3,221,429.00 collected and
-- 240,760.00 failed; synthetic net collection proxy is 26,614,437.00.
WITH invoice_totals AS (
    SELECT record_source, count(*) AS invoices, sum(amount) AS billed_amount
    FROM invoices WHERE invoice_date <= DATE '2026-09-30' GROUP BY record_source
), payment_totals AS (
    SELECT record_source,
           sum(amount) FILTER (WHERE status='successful' AND payment_date <= DATE '2026-09-30') AS successful_collections,
           sum(amount) FILTER (WHERE status='failed' AND payment_date <= DATE '2026-09-30') AS failed_payment_value
    FROM payments GROUP BY record_source
), refund_totals AS (
    SELECT 'synthetic'::TEXT AS record_source,
           sum(refund_amount) FILTER (WHERE refund_date <= DATE '2026-09-30') AS completed_refunds
    FROM refunds
)
SELECT i.record_source, i.invoices, i.billed_amount,
       coalesce(p.successful_collections,0) AS successful_collections,
       coalesce(p.failed_payment_value,0) AS failed_payment_value,
       coalesce(r.completed_refunds,0) AS completed_refunds,
       coalesce(p.successful_collections,0)-coalesce(r.completed_refunds,0) AS net_collection_proxy
FROM invoice_totals i
LEFT JOIN payment_totals p USING (record_source)
LEFT JOIN refund_totals r USING (record_source)
ORDER BY i.record_source;

-- Q4. Which historically effective plans generated billed and collected value?
-- Plan segments start with the first recorded old plan and then apply each plan
-- change. This avoids attributing all historical invoices to the current plan.
-- Expected columns: plan_id, plan_name, billing_interval, invoices,
-- billed_amount, successful_collections, collection_to_bill_pct.
-- Verified interpretation: plan collection/bill ratios are narrowly distributed
-- from 89.34% to 90.08%; Pro monthly has the largest billed value at 8,160,607.00.
WITH first_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id, old_plan_id
    FROM plan_changes ORDER BY subscription_id, change_date, change_id
), plan_events AS (
    SELECT s.subscription_id, s.start_date AS effective_date,
           coalesce(fc.old_plan_id, s.plan_id) AS plan_id
    FROM subscriptions s LEFT JOIN first_change fc USING (subscription_id)
    UNION ALL
    SELECT subscription_id, change_date, new_plan_id FROM plan_changes
), segments AS (
    SELECT subscription_id, plan_id, effective_date,
           lead(effective_date) OVER (PARTITION BY subscription_id ORDER BY effective_date, plan_id) AS next_date
    FROM plan_events
), invoice_plan AS (
    SELECT i.*, seg.plan_id
    FROM invoices i
    JOIN segments seg ON seg.subscription_id=i.subscription_id
                     AND i.invoice_date>=seg.effective_date
                     AND (seg.next_date IS NULL OR i.invoice_date<seg.next_date)
    WHERE i.invoice_date <= DATE '2026-09-30'
)
SELECT sp.plan_id, sp.plan_name, sp.billing_interval,
       count(*) AS invoices,
       sum(ip.amount) AS billed_amount,
       sum(p.amount) FILTER (WHERE p.status='successful' AND p.payment_date<=DATE '2026-09-30') AS successful_collections,
       round(100.0 * sum(p.amount) FILTER (WHERE p.status='successful' AND p.payment_date<=DATE '2026-09-30') / nullif(sum(ip.amount),0), 2) AS collection_to_bill_pct
FROM invoice_plan ip
JOIN subscription_plans sp USING (plan_id)
JOIN payments p USING (invoice_id)
GROUP BY sp.plan_id, sp.plan_name, sp.billing_interval
ORDER BY sp.plan_id;

-- Q5. What contracted MRR and ARR run-rate were active at the snapshot?
-- Eligibility: start_date <= snapshot and end_date is NULL or after snapshot.
-- These are contractual run-rate metrics, not GAAP revenue or collected cash.
-- Expected columns: plan_name, billing_interval, active_subscriptions,
-- contracted_mrr, arr_run_rate, mrr_share_pct.
-- Verified interpretation: effective-dated snapshot MRR is 1,549,314.17 and
-- ARR run-rate is 18,591,770.00; monthly Pro contributes the largest MRR share, 25.62%.
WITH first_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id,old_plan_id
    FROM plan_changes ORDER BY subscription_id,change_date,change_id
), latest_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id,new_plan_id
    FROM plan_changes
    WHERE change_date<=DATE '2026-09-30'
    ORDER BY subscription_id,change_date DESC,change_id DESC
), active AS (
    SELECT sp.plan_name, sp.billing_interval,
           CASE WHEN sp.billing_interval='monthly' THEN sp.price ELSE sp.price/12 END AS monthly_value
    FROM subscriptions s
    LEFT JOIN first_change fc USING(subscription_id)
    LEFT JOIN latest_change lc USING(subscription_id)
    JOIN subscription_plans sp
      ON sp.plan_id=coalesce(lc.new_plan_id,fc.old_plan_id,s.plan_id)
    WHERE s.start_date <= DATE '2026-09-30'
      AND (s.end_date IS NULL OR s.end_date > DATE '2026-09-30')
), plan_mrr AS (
    SELECT plan_name, billing_interval, count(*) AS active_subscriptions,
           sum(monthly_value) AS contracted_mrr
    FROM active GROUP BY plan_name, billing_interval
)
SELECT plan_name, billing_interval, active_subscriptions,
       round(contracted_mrr,2) AS contracted_mrr,
       round(contracted_mrr*12,2) AS arr_run_rate,
       round(100.0*contracted_mrr/sum(contracted_mrr) OVER (),2) AS mrr_share_pct
FROM plan_mrr
ORDER BY contracted_mrr DESC;

-- Q6. How much normalized starting MRR entered with each acquisition cohort?
-- The initial plan is the earliest old_plan_id when a change exists; otherwise
-- it is subscriptions.plan_id. This measures starting contract value, not cash.
-- Expected columns: cohort_month, new_subscriptions, starting_mrr,
-- cumulative_starting_mrr.
-- Verified interpretation: normalized starting MRR sums to 2,351,065.17 across
-- all acquisition cohorts; September 2026 adds 57,149.67 from 2,103 starts.
WITH first_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id, old_plan_id
    FROM plan_changes ORDER BY subscription_id, change_date, change_id
), cohort AS (
    SELECT date_trunc('month',s.start_date)::DATE AS cohort_month,
           CASE WHEN sp.billing_interval='monthly' THEN sp.price ELSE sp.price/12 END AS starting_monthly_value
    FROM subscriptions s
    LEFT JOIN first_change fc USING (subscription_id)
    JOIN subscription_plans sp ON sp.plan_id=coalesce(fc.old_plan_id,s.plan_id)
    WHERE s.start_date <= DATE '2026-09-30'
), monthly AS (
    SELECT cohort_month, count(*) AS new_subscriptions, sum(starting_monthly_value) AS starting_mrr
    FROM cohort GROUP BY cohort_month
)
SELECT cohort_month, new_subscriptions, round(starting_mrr,2) AS starting_mrr,
       round(sum(starting_mrr) OVER (ORDER BY cohort_month),2) AS cumulative_starting_mrr
FROM monthly
ORDER BY cohort_month;

-- Export 1 of 4: executed monthly financial series. Run from repository root.
\copy (WITH months AS (SELECT generate_series(DATE '2023-01-01',DATE '2026-09-01',INTERVAL '1 month')::DATE AS report_month), billed AS (SELECT date_trunc('month',invoice_date)::DATE AS report_month,sum(amount) AS amount FROM invoices WHERE invoice_date<=DATE '2026-09-30' GROUP BY 1), collected AS (SELECT date_trunc('month',payment_date)::DATE AS report_month,sum(amount) AS amount FROM payments WHERE status='successful' AND payment_date<=DATE '2026-09-30' GROUP BY 1), refunded AS (SELECT date_trunc('month',refund_date)::DATE AS report_month,sum(refund_amount) AS amount FROM refunds WHERE status='completed' AND refund_date<=DATE '2026-09-30' GROUP BY 1) SELECT m.report_month AS month,coalesce(b.amount,0) AS billed_amount,coalesce(c.amount,0) AS collected_amount,coalesce(r.amount,0) AS refunded_amount,coalesce(c.amount,0)-coalesce(r.amount,0) AS net_collection_proxy,round(100.0*coalesce(c.amount,0)/nullif(b.amount,0),2) AS collection_to_bill_pct FROM months m LEFT JOIN billed b USING(report_month) LEFT JOIN collected c USING(report_month) LEFT JOIN refunded r USING(report_month) ORDER BY m.report_month) TO 'results/monthly_revenue_summary.csv' WITH (FORMAT csv, HEADER true);

COMMIT;
