\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'
SET search_path = public;
BEGIN READ ONLY;

-- Retention analyses use the 2026-09-30 synthetic scenario snapshot. Active
-- populations include subscriptions started before the measurement date whose
-- end_date is NULL or on/after that date. Rates are descriptive for this hybrid
-- dataset and are not generalizable to a real SaaS business.

-- Q1. What is monthly logo churn by provenance?
-- Opening active base excludes subscriptions starting during the month. Churn
-- rate = churns during month / subscriptions active at the first day.
-- Expected columns: month, record_source, opening_active_subscriptions,
-- churned_subscriptions, monthly_churn_rate_pct.
-- Verified interpretation: synthetic monthly churn stays between 2.55% and
-- 3.47%; original history ranges 3.48%-5.02% before original churn events stop in 2026.
WITH months AS (
    SELECT generate_series(DATE '2023-02-01',DATE '2026-09-01',INTERVAL '1 month')::DATE AS month
), sources AS (
    SELECT unnest(ARRAY['original','synthetic']) AS record_source
), monthly AS (
    SELECT m.month,src.record_source,
           count(*) FILTER (
               WHERE s.start_date<m.month
                 AND (s.end_date IS NULL OR s.end_date>=m.month)
           ) AS opening_active_subscriptions,
           count(*) FILTER (
               WHERE s.end_date>=m.month
                 AND s.end_date<(m.month+INTERVAL '1 month')::DATE
           ) AS churned_subscriptions
    FROM months m CROSS JOIN sources src
    LEFT JOIN subscriptions s ON s.record_source=src.record_source
    GROUP BY m.month,src.record_source
)
SELECT month,record_source,opening_active_subscriptions,churned_subscriptions,
       round(100.0*churned_subscriptions/nullif(opening_active_subscriptions,0),2) AS monthly_churn_rate_pct
FROM monthly
ORDER BY month,record_source;

-- Q2. What are quarterly acquisition-cohort retention rates at 0, 3, 6, and
-- 12 months after each subscription start?
-- Only subscriptions mature enough to reach the age by the snapshot enter that
-- age denominator, preventing immature cohorts from being treated as churned.
-- Expected columns: cohort_quarter, age_months, eligible_subscriptions,
-- retained_subscriptions, retention_rate_pct.
-- Verified interpretation: mature 12-month cohort retention ranges from 66.22%
-- to 74.20%; later cohorts improve as the data mix shifts toward synthetic records.
WITH aged AS (
    SELECT date_trunc('quarter',s.start_date)::DATE AS cohort_quarter,
           a.age_months,s.subscription_id,
           s.start_date+(a.age_months*INTERVAL '1 month') AS measurement_date,
           s.end_date
    FROM subscriptions s
    CROSS JOIN (VALUES (0),(3),(6),(12)) a(age_months)
    WHERE s.start_date+(a.age_months*INTERVAL '1 month')<=DATE '2026-09-30'
)
SELECT cohort_quarter,age_months,
       count(*) AS eligible_subscriptions,
       count(*) FILTER (WHERE end_date IS NULL OR end_date>=measurement_date) AS retained_subscriptions,
       round(100.0*count(*) FILTER (WHERE end_date IS NULL OR end_date>=measurement_date)/count(*),2) AS retention_rate_pct
FROM aged
GROUP BY cohort_quarter,age_months
ORDER BY cohort_quarter,age_months;

-- Q3. What reasons are associated with churn and what contracted monthly value
-- was active at the recorded end state?
-- Effective-dated plan history determines the ending plan. MRR normalizes annual
-- price / 12 because subscriptions.plan_id is not consistently the latest plan.
-- Expected columns: churn_reason, churned_subscriptions,
-- ending_contracted_mrr, share_of_churn_pct.
-- Verified interpretation: price is the largest recorded reason at 6,708 churns
-- (17.64%), followed by product_fit at 6,494 and budget at 6,457.
WITH first_change AS (
    SELECT DISTINCT ON (subscription_id) subscription_id,old_plan_id
    FROM plan_changes ORDER BY subscription_id,change_date,change_id
), churn_plan AS (
    SELECT c.subscription_id,c.churn_reason,
           coalesce(lc.new_plan_id,fc.old_plan_id,s.plan_id) AS plan_id
    FROM churn_events c
    JOIN subscriptions s USING(subscription_id)
    LEFT JOIN first_change fc USING(subscription_id)
    LEFT JOIN LATERAL (
        SELECT pc.new_plan_id
        FROM plan_changes pc
        WHERE pc.subscription_id=c.subscription_id
          AND pc.change_date<=c.churn_date
        ORDER BY pc.change_date DESC,pc.change_id DESC
        LIMIT 1
    ) lc ON TRUE
)
SELECT cp.churn_reason,
       count(*) AS churned_subscriptions,
       round(sum(CASE WHEN p.billing_interval='monthly' THEN p.price ELSE p.price/12 END),2) AS ending_contracted_mrr,
       round(100.0*count(*)/sum(count(*)) OVER (),2) AS share_of_churn_pct
FROM churn_plan cp
JOIN subscription_plans p USING(plan_id)
GROUP BY cp.churn_reason
ORDER BY churned_subscriptions DESC;

-- Q4. How many plan changes are upgrades or downgrades on a monthly-equivalent
-- price basis, and how much contracted MRR did they move?
-- Expected columns: change_month, change_direction, plan_changes,
-- contracted_mrr_delta.
-- Verified interpretation: all 2,166 recorded changes are upgrades of 19.00 in
-- normalized MRR, totaling 41,154.00; the lack of downgrades is a dataset limitation.
WITH valued AS (
    SELECT date_trunc('month',pc.change_date)::DATE AS change_month,
           CASE WHEN (CASE WHEN np.billing_interval='monthly' THEN np.price ELSE np.price/12 END)
                       >(CASE WHEN op.billing_interval='monthly' THEN op.price ELSE op.price/12 END) THEN 'upgrade'
                WHEN (CASE WHEN np.billing_interval='monthly' THEN np.price ELSE np.price/12 END)
                       <(CASE WHEN op.billing_interval='monthly' THEN op.price ELSE op.price/12 END) THEN 'downgrade'
                ELSE 'lateral' END AS change_direction,
           (CASE WHEN np.billing_interval='monthly' THEN np.price ELSE np.price/12 END)
           -(CASE WHEN op.billing_interval='monthly' THEN op.price ELSE op.price/12 END) AS mrr_delta
    FROM plan_changes pc
    JOIN subscription_plans op ON op.plan_id=pc.old_plan_id
    JOIN subscription_plans np ON np.plan_id=pc.new_plan_id
)
SELECT change_month,change_direction,count(*) AS plan_changes,
       round(sum(mrr_delta),2) AS contracted_mrr_delta
FROM valued
GROUP BY change_month,change_direction
ORDER BY change_month,change_direction;

-- Q5. What observed subscription lifetimes are present by provenance and
-- censoring status?
-- Active rows are right-censored at the snapshot; churned rows are completed
-- observed lifetimes. No predictive lifetime or LTV is asserted.
-- Expected columns: record_source, lifecycle_state, subscriptions,
-- average_observed_days, median_observed_days, p90_observed_days.
-- Verified interpretation: churned median lifetime is 184 days for original and
-- 251 for synthetic rows; active medians of 545/382 days remain right-censored.
WITH lifetimes AS (
    SELECT record_source,
           CASE WHEN end_date IS NULL THEN 'active_censored' ELSE 'churned_complete' END AS lifecycle_state,
           coalesce(end_date,DATE '2026-09-30')-start_date AS observed_days
    FROM subscriptions
    WHERE start_date<=DATE '2026-09-30'
)
SELECT record_source,lifecycle_state,count(*) AS subscriptions,
       round(avg(observed_days),1) AS average_observed_days,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY observed_days)::NUMERIC(12,1) AS median_observed_days,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY observed_days)::NUMERIC(12,1) AS p90_observed_days
FROM lifetimes
GROUP BY record_source,lifecycle_state
ORDER BY record_source,lifecycle_state;

-- Export 4 of 4: maturity-adjusted quarterly cohort retention.
\copy (WITH aged AS (SELECT date_trunc('quarter',s.start_date)::DATE cohort_quarter,a.age_months,s.subscription_id,s.start_date+(a.age_months*INTERVAL '1 month') measurement_date,s.end_date FROM subscriptions s CROSS JOIN (VALUES(0),(3),(6),(12)) a(age_months) WHERE s.start_date+(a.age_months*INTERVAL '1 month')<=DATE '2026-09-30') SELECT cohort_quarter,age_months,count(*) eligible_subscriptions,count(*) FILTER(WHERE end_date IS NULL OR end_date>=measurement_date) retained_subscriptions,round(100.0*count(*) FILTER(WHERE end_date IS NULL OR end_date>=measurement_date)/count(*),2) retention_rate_pct FROM aged GROUP BY cohort_quarter,age_months ORDER BY cohort_quarter,age_months) TO 'results/cohort_retention.csv' WITH (FORMAT csv, HEADER true);

COMMIT;
