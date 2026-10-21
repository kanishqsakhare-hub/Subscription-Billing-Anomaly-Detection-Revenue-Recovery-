\set ON_ERROR_STOP on
\pset pager off

\if :{?project_database}
\else
\set project_database saas_revenue_assurance
\endif
SELECT set_config('saas.project_database', :'project_database', false);

SET search_path = public;

-- Reproducible benchmark harness for PostgreSQL 18.4.
--
-- Run from the repository root in a fresh psql session before indexes, then run
-- database/03_indexes.sql, open another fresh psql session, and run this file
-- again. Each query executes twice; compare run 2 as a warm-cache observation.
-- TIMING OFF reduces per-node instrumentation overhead while the plan summary
-- still reports total execution time. BUFFERS and track_io_timing distinguish
-- cache hits, physical reads, temporary I/O, and sort spill behavior.
--
-- Measured evidence from PostgreSQL 18.4 is recorded below. Baseline values are
-- the second execution before indexes. Indexed ranges are the second execution
-- from two fresh-session harness runs after ANALYZE. Runtime is machine- and
-- cache-dependent and should not be generalized.
--
-- B1 effective-dated snapshot MRR
-- Baseline: 21,054.244 ms; 2,878,485 shared hits.
-- Indexed:  1,185.356-1,207.687 ms; 557,077 shared hits.
-- Finding:  94.3% faster and 80.6% fewer shared-buffer accesses. The 144 kB
--           effective-date index replaces repeated plan_changes scans.
--
-- B2 paid-invoice/failed-payment reconciliation
-- Baseline: 146.336 ms; 15,328 shared blocks (9,605 hits + 5,723 reads).
-- Indexed:  119.660-134.030 ms; 8,651 shared blocks in the last run.
-- Finding:  8.4-18.2% faster and 43.6% fewer shared-buffer accesses in the
--           last run. A partial index-only scan reads 63,078 failed payments.
--
-- B3 recurring-invoice cadence window
-- Baseline: 725.183 ms; 5,904 shared blocks; 2,992 temp blocks read and 3,003
--           written by a 23,936 kB external merge sort.
-- Indexed:  639.717-670.579 ms; 4,478 shared hits; no temporary I/O.
-- Finding:  7.5-11.8% faster. The covering index-only scan supplies window
--           order directly and removes the disk-spilling sort.
--
-- B4 final-attempt/payment reconciliation
-- Baseline: 1,198.653 ms; 16,023 shared blocks; 9,053 temp blocks read and
--           9,065 written. The attempt sort spilled 31,984 kB to disk.
-- Indexed:  899.161-962.105 ms; 12,552 shared blocks; 5,055 temp blocks read
--           and written in the last run.
-- Finding:  19.7-25.0% faster. Ordered index-only access removes the attempt
--           sort, but the 4 MB payment hash still uses eight batches.
--
-- B5 unresolved recovery aging
-- Baseline: 77.105 ms (second execution; first was 81.708 ms).
-- Indexed:  82.884-151.068 ms across indexed warm observations.
-- Finding:  No improvement. Parallel worker and cache variation dominate; the
--           planner retains sequential scans, so no recovery index was added.
--
-- B6 monthly successful-collection aggregation (control)
-- Baseline: 145.382 ms (second execution; first was 142.798 ms).
-- Indexed:  141.499-177.948 ms across indexed warm observations.
-- Finding:  No reliable change. The filter retains about 90% of payments, so
--           the unchanged parallel sequential scan is cheaper than an index.
--
-- Planner observations after ANALYZE:
-- * B2 still uses a parallel sequential scan for predominantly paid invoices;
--   its indexed join estimate is 25,510 rows/worker versus 11,878.67 actual.
-- * B3 estimates 204,717 filtered candidates versus zero actual because basic
--   statistics cannot model the LAG-derived date gap and amount combination.
-- * B4 estimates 303,821 mismatches versus zero actual. Cross-table correlation
--   between final-attempt outcome and payment status is unavailable to the
--   planner. Its full payment scan and eight-batch hash are therefore retained;
--   a covering copy of the payment primary key was rejected as duplication.
-- * B5 estimates 1,346 aging groups versus five actual because the groups are a
--   CASE expression. B6 estimates 1,352 months versus 45 actual. Both complete
--   quickly, and neither estimation error justifies another persistent object.
--
-- Phase 6 clean-database confirmation (warm run, 2026-10-21): B1
-- 22,261.637 -> 1,173.659 ms; B2 156.285 -> 127.189 ms; B3 712.723 ->
-- 629.117 ms with its external sort removed; B4 1,151.949 -> 955.402 ms with
-- its attempt sort removed. B5 was effectively unchanged (141.535 -> 141.848
-- ms), and B6 varied from 147.997 -> 159.288 ms. These results confirm the
-- plan changes while also showing why timings should be treated as ranges.

DO $database_guard$
BEGIN
    IF current_database()<>current_setting('saas.project_database') THEN
        RAISE EXCEPTION 'Refusing to benchmark database %. Expected %',
            current_database(),current_setting('saas.project_database');
    END IF;
END
$database_guard$;

SET jit=off;
SET track_io_timing=on;
SET work_mem='4MB';
SET max_parallel_workers_per_gather=2;

SELECT current_setting('server_version') AS server_version,
       current_setting('jit') AS jit,
       current_setting('track_io_timing') AS track_io_timing,
       current_setting('work_mem') AS work_mem,
       current_setting('max_parallel_workers_per_gather') AS max_parallel_workers_per_gather;

BEGIN READ ONLY;

-- B1. Repeated effective-plan lookup inside the verified snapshot MRR metric.
PREPARE benchmark_b1 AS
SELECT round(sum(fn_subscription_mrr(subscription_id,DATE '2026-09-30')),2) AS snapshot_mrr
FROM subscriptions
WHERE start_date<=DATE '2026-09-30'
  AND (end_date IS NULL OR end_date>DATE '2026-09-30');

\echo 'B1 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b1;
\echo 'B1 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b1;

-- B2. Review candidates join a selective failed-payment subset to invoices and
-- modeled recovery. This is central to billing reconciliation.
PREPARE benchmark_b2 AS
SELECT i.record_source,
       coalesce(r.status,'no_recovery_record') AS recovery_status,
       count(*) AS candidate_invoices,
       sum(i.amount) AS amount_for_review
FROM payments p
JOIN invoices i USING(invoice_id)
LEFT JOIN revenue_recovery r USING(invoice_id)
WHERE p.status='failed' AND i.status='paid'
GROUP BY i.record_source,coalesce(r.status,'no_recovery_record')
ORDER BY i.record_source,recovery_status;

\echo 'B2 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b2;
\echo 'B2 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b2;

-- B3. Window ordering required for recurring-invoice gap detection.
PREPARE benchmark_b3 AS
WITH sequenced AS (
    SELECT subscription_id,invoice_date,amount,
           lag(invoice_date) OVER (
               PARTITION BY subscription_id ORDER BY invoice_date,invoice_id
           ) AS prior_invoice_date
    FROM invoices
), candidates AS (
    SELECT *
    FROM sequenced
    WHERE prior_invoice_date IS NOT NULL
      AND (
          (amount IN (19,49,99) AND invoice_date-prior_invoice_date>35)
          OR (amount IN (190,490,990) AND invoice_date-prior_invoice_date>370)
      )
)
SELECT count(*) AS gap_candidates FROM candidates;

\echo 'B3 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b3;
\echo 'B3 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b3;

-- B4. Latest attempt per invoice requires the same ordering used by payment
-- reconciliation, followed by a payment lookup and outcome comparison.
PREPARE benchmark_b4 AS
WITH final_attempts AS (
    SELECT DISTINCT ON (invoice_id)
           invoice_id,payment_id,outcome
    FROM payment_attempts
    ORDER BY invoice_id,attempt_number DESC,attempt_id DESC
)
SELECT count(*) AS outcome_mismatches
FROM final_attempts a
JOIN payments p USING(payment_id)
WHERE (a.outcome='successful')<>(p.status='successful');

\echo 'B4 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b4;
\echo 'B4 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b4;

-- B5. Aging aggregates a moderately sized unresolved subset and joins invoice
-- due dates. It tests whether another recovery index would be justified.
PREPARE benchmark_b5 AS
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
ORDER BY aging_bucket;

\echo 'B5 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b5;
\echo 'B5 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b5;

-- B6. Control query touches most successful payments. A sequential scan may be
-- preferable because the filter retains roughly 90% of the large table.
PREPARE benchmark_b6 AS
SELECT date_trunc('month',payment_date)::DATE AS month,
       sum(amount) AS collected_amount
FROM payments
WHERE status='successful' AND payment_date<=DATE '2026-09-30'
GROUP BY 1
ORDER BY 1;

\echo 'B6 run 1'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b6;
\echo 'B6 run 2'
EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,SUMMARY ON,SETTINGS ON) EXECUTE benchmark_b6;

DEALLOCATE benchmark_b1;
DEALLOCATE benchmark_b2;
DEALLOCATE benchmark_b3;
DEALLOCATE benchmark_b4;
DEALLOCATE benchmark_b5;
DEALLOCATE benchmark_b6;

COMMIT;
