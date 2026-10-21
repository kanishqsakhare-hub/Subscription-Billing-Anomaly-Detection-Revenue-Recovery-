\set ON_ERROR_STOP on
\pset pager off
\pset null '[NULL]'

\if :{?project_database}
\else
\set project_database saas_revenue_assurance
\endif
SELECT set_config('saas.project_database', :'project_database', false);

SET search_path = public;

-- Phase 4 advanced SQL: reusable database programming and isolated tests.
-- Imported source tables are never updated or deleted. The only durable data
-- object added is an initially empty reconciliation work queue. Demonstration
-- queue rows are rolled back or explicitly removed after COMMIT verification.

DO $database_guard$
BEGIN
    IF current_database() <> current_setting('saas.project_database') THEN
        RAISE EXCEPTION 'Refusing to install project objects in database %. Expected %',
            current_database(), current_setting('saas.project_database');
    END IF;
END
$database_guard$;

BEGIN;

-- A derived operational queue keeps review workflow separate from immutable
-- imported facts. invoice_id uniqueness provides duplicate-processing protection.
CREATE TABLE IF NOT EXISTS reconciliation_case_queue (
    case_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id    BIGINT NOT NULL UNIQUE
                  REFERENCES invoices(invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    case_reason   TEXT NOT NULL CHECK (case_reason IN (
                      'paid_invoice_without_success',
                      'nonpaid_invoice_with_success',
                      'payment_amount_mismatch',
                      'refund_exceeds_collection'
                  )),
    case_status   TEXT NOT NULL DEFAULT 'open'
                  CHECK (case_status IN ('open','investigating','resolved','dismissed')),
    priority      TEXT NOT NULL DEFAULT 'medium'
                  CHECK (priority IN ('low','medium','high')),
    source_class  TEXT NOT NULL CHECK (source_class IN ('original','synthetic')),
    notes         TEXT CHECK (notes IS NULL OR char_length(notes) <= 1000),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    resolved_at   TIMESTAMPTZ,
    CONSTRAINT queue_resolution_timestamp CHECK (
        (case_status IN ('resolved','dismissed') AND resolved_at IS NOT NULL)
        OR (case_status IN ('open','investigating') AND resolved_at IS NULL)
    )
);

-- Function 1: effective plan for a subscription on a supplied date.
-- The first old_plan_id represents the initial plan; later new_plan_id values
-- become effective on change_date. NULL means the subscription was not active.
CREATE OR REPLACE FUNCTION fn_plan_at_date(
    p_subscription_id BIGINT,
    p_as_of_date DATE
) RETURNS BIGINT
LANGUAGE plpgsql
STABLE
STRICT
AS $function$
DECLARE
    v_start_date DATE;
    v_end_date DATE;
    v_current_plan BIGINT;
    v_plan_id BIGINT;
BEGIN
    SELECT start_date,end_date,plan_id
    INTO v_start_date,v_end_date,v_current_plan
    FROM subscriptions
    WHERE subscription_id=p_subscription_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Subscription % does not exist',p_subscription_id
            USING ERRCODE='23503';
    END IF;

    IF p_as_of_date<v_start_date OR (v_end_date IS NOT NULL AND p_as_of_date>v_end_date) THEN
        RETURN NULL;
    END IF;

    SELECT new_plan_id INTO v_plan_id
    FROM plan_changes
    WHERE subscription_id=p_subscription_id AND change_date<=p_as_of_date
    ORDER BY change_date DESC,change_id DESC
    LIMIT 1;

    IF FOUND THEN
        RETURN v_plan_id;
    END IF;

    SELECT old_plan_id INTO v_plan_id
    FROM plan_changes
    WHERE subscription_id=p_subscription_id
    ORDER BY change_date,change_id
    LIMIT 1;

    RETURN coalesce(v_plan_id,v_current_plan);
END
$function$;

-- Function 2: contracted MRR for one active subscription on a supplied date.
-- Annual prices are divided by 12. This is contract run-rate, not revenue or cash.
CREATE OR REPLACE FUNCTION fn_subscription_mrr(
    p_subscription_id BIGINT,
    p_as_of_date DATE
) RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
STRICT
AS $function$
DECLARE
    v_plan_id BIGINT;
    v_mrr NUMERIC;
BEGIN
    v_plan_id:=fn_plan_at_date(p_subscription_id,p_as_of_date);
    IF v_plan_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT CASE WHEN billing_interval='monthly' THEN price ELSE price/12 END
    INTO STRICT v_mrr
    FROM subscription_plans
    WHERE plan_id=v_plan_id;

    RETURN v_mrr;
END
$function$;

-- Function 3: invoice-grain reconciliation without multiplying payments,
-- refunds, or recovery rows. Recovery remains explicitly modeled.
CREATE OR REPLACE FUNCTION fn_invoice_reconciliation(p_invoice_id BIGINT)
RETURNS TABLE (
    invoice_id BIGINT,
    subscription_id BIGINT,
    invoice_status TEXT,
    invoice_amount NUMERIC,
    successful_payment_amount NUMERIC,
    failed_payment_amount NUMERIC,
    completed_refund_amount NUMERIC,
    modeled_recovered_amount NUMERIC,
    reconciliation_status TEXT
)
LANGUAGE plpgsql
STABLE
STRICT
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_id=p_invoice_id) THEN
        RAISE EXCEPTION 'Invoice % does not exist',p_invoice_id USING ERRCODE='23503';
    END IF;

    RETURN QUERY
    WITH payment_totals AS (
        SELECT p.invoice_id,
               coalesce(sum(p.amount) FILTER (WHERE p.status='successful'),0) AS successful_amount,
               coalesce(sum(p.amount) FILTER (WHERE p.status='failed'),0) AS failed_amount
        FROM payments p WHERE p.invoice_id=p_invoice_id GROUP BY p.invoice_id
    ), refund_totals AS (
        SELECT r.invoice_id,
               coalesce(sum(r.refund_amount) FILTER (WHERE r.status='completed'),0) AS refund_amount
        FROM refunds r WHERE r.invoice_id=p_invoice_id GROUP BY r.invoice_id
    ), recovery_totals AS (
        SELECT rr.invoice_id,coalesce(sum(rr.recovered_amount),0) AS recovered_amount
        FROM revenue_recovery rr WHERE rr.invoice_id=p_invoice_id GROUP BY rr.invoice_id
    )
    SELECT i.invoice_id,i.subscription_id,i.status,i.amount,
           coalesce(pt.successful_amount,0),coalesce(pt.failed_amount,0),
           coalesce(rt.refund_amount,0),coalesce(rrt.recovered_amount,0),
           CASE
               WHEN i.status='paid' AND coalesce(pt.successful_amount,0)=0
                   THEN 'paid_invoice_without_success'
               WHEN i.status<>'paid' AND coalesce(pt.successful_amount,0)>0
                   THEN 'nonpaid_invoice_with_success'
               WHEN coalesce(pt.successful_amount,0)>0
                    AND coalesce(pt.successful_amount,0)<>i.amount
                   THEN 'payment_amount_mismatch'
               WHEN coalesce(rt.refund_amount,0)>coalesce(pt.successful_amount,0)
                   THEN 'refund_exceeds_collection'
               ELSE 'aligned'
           END
    FROM invoices i
    LEFT JOIN payment_totals pt USING(invoice_id)
    LEFT JOIN refund_totals rt USING(invoice_id)
    LEFT JOIN recovery_totals rrt USING(invoice_id)
    WHERE i.invoice_id=p_invoice_id;
END
$function$;

-- Trigger 1: enforce legal workflow transitions and immutable case identity.
CREATE OR REPLACE FUNCTION trg_reconciliation_case_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $trigger$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.case_status<>'open' THEN
            RAISE EXCEPTION 'New reconciliation cases must start open'
                USING ERRCODE='23514';
        END IF;
        NEW.created_at:=coalesce(NEW.created_at,clock_timestamp());
        NEW.updated_at:=NEW.created_at;
        NEW.resolved_at:=NULL;
        RETURN NEW;
    END IF;

    IF NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
       OR NEW.case_reason IS DISTINCT FROM OLD.case_reason
       OR NEW.source_class IS DISTINCT FROM OLD.source_class THEN
        RAISE EXCEPTION 'Invoice, reason, and source are immutable after queueing'
            USING ERRCODE='23514';
    END IF;

    IF NEW.case_status IS DISTINCT FROM OLD.case_status THEN
        IF OLD.case_status='open' AND NEW.case_status NOT IN ('investigating','dismissed') THEN
            RAISE EXCEPTION 'Invalid transition from % to %',OLD.case_status,NEW.case_status
                USING ERRCODE='23514';
        ELSIF OLD.case_status='investigating' AND NEW.case_status NOT IN ('resolved','dismissed') THEN
            RAISE EXCEPTION 'Invalid transition from % to %',OLD.case_status,NEW.case_status
                USING ERRCODE='23514';
        ELSIF OLD.case_status IN ('resolved','dismissed') THEN
            RAISE EXCEPTION 'Terminal case % cannot transition from %',OLD.case_id,OLD.case_status
                USING ERRCODE='23514';
        END IF;
    END IF;

    NEW.updated_at:=clock_timestamp();
    IF NEW.case_status IN ('resolved','dismissed') THEN
        NEW.resolved_at:=coalesce(OLD.resolved_at,clock_timestamp());
    ELSE
        NEW.resolved_at:=NULL;
    END IF;
    RETURN NEW;
END
$trigger$;

CREATE OR REPLACE TRIGGER reconciliation_case_transition
BEFORE INSERT OR UPDATE ON reconciliation_case_queue
FOR EACH ROW EXECUTE FUNCTION trg_reconciliation_case_transition();

-- Trigger 2: enforce cross-table invoice/payment/subscription consistency for
-- future writes. Existing source facts are not changed.
CREATE OR REPLACE FUNCTION trg_validate_financial_parentage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $trigger$
DECLARE
    v_invoice_subscription BIGINT;
    v_payment_invoice BIGINT;
    v_payment_subscription BIGINT;
BEGIN
    SELECT subscription_id INTO v_invoice_subscription
    FROM invoices WHERE invoice_id=NEW.invoice_id;

    IF v_invoice_subscription IS NULL OR v_invoice_subscription<>NEW.subscription_id THEN
        RAISE EXCEPTION '% invoice % belongs to subscription %, not %',
            TG_TABLE_NAME,NEW.invoice_id,v_invoice_subscription,NEW.subscription_id
            USING ERRCODE='23514';
    END IF;

    IF TG_TABLE_NAME IN ('payment_attempts','refunds') AND NEW.payment_id IS NOT NULL THEN
        SELECT invoice_id,subscription_id
        INTO v_payment_invoice,v_payment_subscription
        FROM payments WHERE payment_id=NEW.payment_id;

        IF v_payment_invoice IS NULL
           OR v_payment_invoice<>NEW.invoice_id
           OR v_payment_subscription<>NEW.subscription_id THEN
            RAISE EXCEPTION '% payment % does not match invoice/subscription parentage',
                TG_TABLE_NAME,NEW.payment_id USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END
$trigger$;

CREATE OR REPLACE TRIGGER payments_parent_consistency
BEFORE INSERT OR UPDATE OF invoice_id,subscription_id ON payments
FOR EACH ROW EXECUTE FUNCTION trg_validate_financial_parentage();

CREATE OR REPLACE TRIGGER attempts_parent_consistency
BEFORE INSERT OR UPDATE OF invoice_id,payment_id,subscription_id ON payment_attempts
FOR EACH ROW EXECUTE FUNCTION trg_validate_financial_parentage();

CREATE OR REPLACE TRIGGER refunds_parent_consistency
BEFORE INSERT OR UPDATE OF invoice_id,payment_id,subscription_id ON refunds
FOR EACH ROW EXECUTE FUNCTION trg_validate_financial_parentage();

CREATE OR REPLACE TRIGGER recovery_parent_consistency
BEFORE INSERT OR UPDATE OF invoice_id,subscription_id ON revenue_recovery
FOR EACH ROW EXECUTE FUNCTION trg_validate_financial_parentage();

-- Procedure 1: queue only genuine reconciliation candidates. ON CONFLICT makes
-- repeated processing idempotent without rewriting the existing case.
CREATE OR REPLACE PROCEDURE sp_queue_invoice_reconciliation(
    p_invoice_id BIGINT,
    p_priority TEXT DEFAULT 'medium',
    p_notes TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_result RECORD;
    v_source TEXT;
    v_inserted INTEGER;
BEGIN
    IF p_priority NOT IN ('low','medium','high') THEN
        RAISE EXCEPTION 'Unsupported priority: %',p_priority USING ERRCODE='22023';
    END IF;

    SELECT * INTO v_result FROM fn_invoice_reconciliation(p_invoice_id);
    IF v_result.reconciliation_status='aligned' THEN
        RAISE EXCEPTION 'Invoice % is aligned and should not be queued',p_invoice_id
            USING ERRCODE='P0001';
    END IF;

    SELECT record_source INTO STRICT v_source FROM invoices WHERE invoice_id=p_invoice_id;

    INSERT INTO reconciliation_case_queue(
        invoice_id,case_reason,priority,source_class,notes
    ) VALUES (
        p_invoice_id,v_result.reconciliation_status,p_priority,v_source,p_notes
    ) ON CONFLICT(invoice_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted=ROW_COUNT;
    IF v_inserted=0 THEN
        RAISE NOTICE 'Invoice % is already queued; duplicate ignored',p_invoice_id;
    END IF;
END
$procedure$;

-- Procedure 2: lock and transition one queued case. The trigger independently
-- enforces the state machine, while this procedure supplies clear exceptions.
CREATE OR REPLACE PROCEDURE sp_transition_reconciliation_case(
    p_invoice_id BIGINT,
    p_new_status TEXT,
    p_notes TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_case_id BIGINT;
BEGIN
    IF p_new_status NOT IN ('investigating','resolved','dismissed') THEN
        RAISE EXCEPTION 'Unsupported target status: %',p_new_status USING ERRCODE='22023';
    END IF;

    SELECT case_id INTO v_case_id
    FROM reconciliation_case_queue
    WHERE invoice_id=p_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % has no queued reconciliation case',p_invoice_id
            USING ERRCODE='P0002';
    END IF;

    UPDATE reconciliation_case_queue
    SET case_status=p_new_status,
        notes=coalesce(p_notes,notes)
    WHERE case_id=v_case_id;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION 'Rejected transition for invoice % to %',p_invoice_id,p_new_status
            USING ERRCODE='23514';
END
$procedure$;

COMMIT;

-- ---------------------------------------------------------------------------
-- Executed validation and transaction demonstrations
-- ---------------------------------------------------------------------------

-- Select an unqueued documented candidate and retain its identity for all tests.
CREATE TEMP TABLE phase4_demo_context ON COMMIT PRESERVE ROWS AS
SELECT i.invoice_id,i.subscription_id
FROM invoices i
JOIN payments p USING(invoice_id)
WHERE i.status='paid' AND p.status='failed'
  AND NOT EXISTS (
      SELECT 1 FROM reconciliation_case_queue q WHERE q.invoice_id=i.invoice_id
  )
ORDER BY i.invoice_id
LIMIT 1;

DO $assert_demo_candidate$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM phase4_demo_context) THEN
        RAISE EXCEPTION 'No unqueued paid-invoice/failed-payment candidate is available';
    END IF;
END
$assert_demo_candidate$;

SELECT invoice_id AS demo_invoice_id
FROM phase4_demo_context
\gset

-- Function evidence: effective plan, normalized MRR, and reconciliation output.
SELECT s.subscription_id,
       fn_plan_at_date(s.subscription_id,DATE '2026-09-30') AS effective_plan_id,
       round(fn_subscription_mrr(s.subscription_id,DATE '2026-09-30'),2) AS contracted_mrr
FROM subscriptions s
WHERE s.start_date<=DATE '2026-09-30'
  AND (s.end_date IS NULL OR s.end_date>DATE '2026-09-30')
ORDER BY s.subscription_id
LIMIT 5;

SELECT r.*
FROM phase4_demo_context d
CROSS JOIN LATERAL fn_invoice_reconciliation(d.invoice_id) r;

-- Exception handling evidence: a missing subscription must raise 23503 and be caught.
DO $missing_subscription_test$
DECLARE
    v_caught BOOLEAN:=FALSE;
BEGIN
    BEGIN
        PERFORM fn_plan_at_date(9223372036854775807,DATE '2026-09-30');
    EXCEPTION WHEN foreign_key_violation THEN
        v_caught:=TRUE;
        RAISE NOTICE 'PASS: missing subscription exception was caught';
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'FAIL: missing subscription was not rejected';
    END IF;
END
$missing_subscription_test$;

-- Consistency test: attempt a mismatched future payment inside a transaction.
-- The parentage trigger must reject it; ROLLBACK guarantees no source change.
BEGIN;
DO $parent_trigger_test$
DECLARE
    v_invoice_id BIGINT;
    v_invoice_subscription BIGINT;
    v_other_subscription BIGINT;
    v_amount NUMERIC(12,2);
    v_test_payment_id BIGINT;
    v_caught BOOLEAN:=FALSE;
BEGIN
    SELECT invoice_id,subscription_id,amount
    INTO v_invoice_id,v_invoice_subscription,v_amount
    FROM invoices ORDER BY invoice_id LIMIT 1;
    SELECT subscription_id INTO v_other_subscription
    FROM subscriptions WHERE subscription_id<>v_invoice_subscription
    ORDER BY subscription_id LIMIT 1;
    SELECT max(payment_id)+1000000 INTO v_test_payment_id FROM payments;

    BEGIN
        INSERT INTO payments(
            payment_id,subscription_id,payment_date,amount,status,
            failure_reason,invoice_id,record_source
        ) VALUES (
            v_test_payment_id,v_other_subscription,DATE '2026-09-30',v_amount,
            'successful',NULL,v_invoice_id,'synthetic'
        );
    EXCEPTION WHEN check_violation THEN
        v_caught:=TRUE;
        RAISE NOTICE 'PASS: mismatched financial parentage was rejected';
    END;

    IF NOT v_caught THEN
        RAISE EXCEPTION 'FAIL: parentage trigger accepted a mismatched payment';
    END IF;
END
$parent_trigger_test$;
ROLLBACK;

-- Durability/COMMIT demonstration: commit a derived queue case, verify it in a
-- separate transaction, then remove only the uniquely marked demonstration row.
BEGIN;
CALL sp_queue_invoice_reconciliation(
    :demo_invoice_id,
    'high','phase4_commit_demo_do_not_keep'
);
COMMIT;

SELECT count(*) AS committed_case_visible
FROM reconciliation_case_queue q
JOIN phase4_demo_context d USING(invoice_id)
WHERE q.notes='phase4_commit_demo_do_not_keep';

BEGIN;
DELETE FROM reconciliation_case_queue q
USING phase4_demo_context d
WHERE q.invoice_id=d.invoice_id
  AND q.notes='phase4_commit_demo_do_not_keep';
COMMIT;

-- Atomicity/ROLLBACK demonstration: the queued case exists inside the
-- transaction and disappears after rollback.
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
CALL sp_queue_invoice_reconciliation(
    :demo_invoice_id,
    'medium','phase4_rollback_demo_do_not_keep'
);
SELECT current_setting('transaction_isolation') AS isolation_level,
       count(*) AS case_visible_inside_transaction
FROM reconciliation_case_queue q
JOIN phase4_demo_context d USING(invoice_id);
ROLLBACK;

SELECT count(*) AS case_visible_after_rollback
FROM reconciliation_case_queue q
JOIN phase4_demo_context d USING(invoice_id);

-- Duplicate protection, invalid-transition handling, and valid state changes
-- are tested together and rolled back.
BEGIN;
CALL sp_queue_invoice_reconciliation(
    :demo_invoice_id,'high','phase4_state_demo'
);
CALL sp_queue_invoice_reconciliation(
    :demo_invoice_id,'high','duplicate_should_be_ignored'
);

SELECT count(*) AS cases_after_duplicate_calls
FROM reconciliation_case_queue q
JOIN phase4_demo_context d USING(invoice_id);

DO $invalid_transition_test$
DECLARE
    v_invoice_id BIGINT;
    v_caught BOOLEAN:=FALSE;
BEGIN
    SELECT invoice_id INTO STRICT v_invoice_id FROM phase4_demo_context;
    BEGIN
        CALL sp_transition_reconciliation_case(v_invoice_id,'resolved','invalid direct resolution');
    EXCEPTION WHEN check_violation THEN
        v_caught:=TRUE;
        RAISE NOTICE 'PASS: invalid open-to-resolved transition was rejected';
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'FAIL: invalid queue transition was accepted';
    END IF;
END
$invalid_transition_test$;

CALL sp_transition_reconciliation_case(
    :demo_invoice_id,'investigating','review started'
);
CALL sp_transition_reconciliation_case(
    :demo_invoice_id,'resolved','demonstration resolved'
);

SELECT q.case_status,(q.resolved_at IS NOT NULL) AS resolved_timestamp_set
FROM reconciliation_case_queue q
JOIN phase4_demo_context d USING(invoice_id);
ROLLBACK;

-- Advanced operational query: prioritize review candidates into deterministic
-- 500-case work batches without populating the queue. The window calculation is
-- over invoice-grain candidates, so attempts and refunds cannot multiply value.
WITH candidates AS (
    SELECT i.invoice_id,i.record_source,i.due_date,i.amount,
           coalesce(r.status,'no_recovery_record') AS recovery_status,
           greatest(DATE '2026-09-30'-i.due_date,0) AS age_days
    FROM invoices i
    JOIN payments p USING(invoice_id)
    LEFT JOIN revenue_recovery r USING(invoice_id)
    WHERE i.status='paid' AND p.status='failed'
), ranked AS (
    SELECT c.*,
           row_number() OVER (
               PARTITION BY record_source
               ORDER BY (recovery_status='requires_review') DESC,age_days DESC,amount DESC,invoice_id
           ) AS priority_rank,
           sum(amount) OVER (
               PARTITION BY record_source
               ORDER BY (recovery_status='requires_review') DESC,age_days DESC,amount DESC,invoice_id
           ) AS cumulative_review_amount
    FROM candidates c
), batched AS (
    SELECT *,1+((priority_rank-1)/500) AS work_batch
    FROM ranked
)
SELECT record_source,work_batch,count(*) AS cases,
       sum(amount) AS batch_review_amount,
       max(age_days) AS oldest_days,
       max(cumulative_review_amount) AS cumulative_review_amount
FROM batched
GROUP BY record_source,work_batch
ORDER BY record_source,work_batch;

-- Final assertions: no demonstration rows remain and source totals are intact.
DO $final_assertions$
DECLARE
    v_demo_rows BIGINT;
    v_source_rows BIGINT;
BEGIN
    SELECT count(*) INTO v_demo_rows
    FROM reconciliation_case_queue
    WHERE notes LIKE 'phase4\_%\_demo%';

    SELECT sum(n) INTO v_source_rows
    FROM (
        SELECT count(*) n FROM customers
        UNION ALL SELECT count(*) FROM subscription_plans
        UNION ALL SELECT count(*) FROM subscriptions
        UNION ALL SELECT count(*) FROM plan_changes
        UNION ALL SELECT count(*) FROM churn_events
        UNION ALL SELECT count(*) FROM invoices
        UNION ALL SELECT count(*) FROM payments
        UNION ALL SELECT count(*) FROM payment_attempts
        UNION ALL SELECT count(*) FROM refunds
        UNION ALL SELECT count(*) FROM revenue_recovery
    ) counts;

    IF v_demo_rows<>0 THEN
        RAISE EXCEPTION 'FAIL: % demonstration queue rows remain',v_demo_rows;
    END IF;
    IF v_source_rows<>2207973 THEN
        RAISE EXCEPTION 'FAIL: source row total changed to %',v_source_rows;
    END IF;
    RAISE NOTICE 'PASS: no demo rows remain; source row total is %',v_source_rows;
END
$final_assertions$;
