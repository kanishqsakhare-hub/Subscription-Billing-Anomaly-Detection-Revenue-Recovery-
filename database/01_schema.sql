\set ON_ERROR_STOP on

\if :{?project_database}
\else
\set project_database saas_revenue_assurance
\endif
SELECT set_config('saas.project_database', :'project_database', false);

-- Run with psql against the intended empty project database:
-- psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/01_schema.sql
--
-- This script deliberately contains no DROP statements. It fails if an object
-- already exists, protecting unrelated or previously loaded data.

BEGIN;

DO $database_guard$
BEGIN
    IF current_database() <> current_setting('saas.project_database') THEN
        RAISE EXCEPTION 'Refusing to create project tables in database %. Expected %',
            current_database(), current_setting('saas.project_database');
    END IF;
END
$database_guard$;

SET LOCAL search_path = public;

CREATE TABLE customers (
    customer_id         BIGINT PRIMARY KEY CHECK (customer_id > 0),
    signup_date         DATE NOT NULL,
    company_size        TEXT NOT NULL CHECK (company_size IN ('small', 'medium', 'large')),
    industry            TEXT NOT NULL CHECK (industry IN ('finance', 'health', 'retail', 'tech')),
    acquisition_channel TEXT NOT NULL CHECK (acquisition_channel IN ('referral', 'organic', 'ads')),
    country             TEXT NOT NULL CHECK (country IN ('Germany', 'US', 'UK', 'India')),
    record_source       TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic'))
);

CREATE TABLE subscription_plans (
    plan_id          BIGINT PRIMARY KEY CHECK (plan_id > 0),
    plan_name        TEXT NOT NULL CHECK (plan_name IN ('Free', 'Basic', 'Pro', 'Premium')),
    billing_interval TEXT NOT NULL CHECK (billing_interval IN ('monthly', 'annual')),
    price            NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    record_source    TEXT NOT NULL CHECK (record_source = 'original')
);

CREATE TABLE subscriptions (
    subscription_id BIGINT PRIMARY KEY CHECK (subscription_id > 0),
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    start_date      DATE NOT NULL,
    end_date        DATE,
    status          TEXT NOT NULL CHECK (status IN ('active', 'churned')),
    plan_id         BIGINT NOT NULL REFERENCES subscription_plans(plan_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    record_source   TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic')),
    CONSTRAINT subscriptions_date_order CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT subscriptions_status_end_date CHECK (
        (status = 'active' AND end_date IS NULL)
        OR (status = 'churned' AND end_date IS NOT NULL)
    )
);

CREATE TABLE plan_changes (
    change_id      BIGINT PRIMARY KEY CHECK (change_id > 0),
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    old_plan_id    BIGINT NOT NULL REFERENCES subscription_plans(plan_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    new_plan_id    BIGINT NOT NULL REFERENCES subscription_plans(plan_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    change_date    DATE NOT NULL,
    record_source  TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic')),
    CONSTRAINT plan_changes_distinct_plans CHECK (old_plan_id <> new_plan_id)
);

CREATE TABLE churn_events (
    churn_event_id BIGINT PRIMARY KEY CHECK (churn_event_id > 0),
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    churn_date     DATE NOT NULL,
    churn_reason   TEXT NOT NULL CHECK (churn_reason IN (
        'other', 'price', 'budget', 'product_fit', 'competitor',
        'low_usage', 'payment_failure', 'support_issues',
        'billing_dispute', 'company_closed'
    )),
    record_source  TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic'))
);

CREATE TABLE invoices (
    invoice_id     BIGINT PRIMARY KEY CHECK (invoice_id > 0),
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    invoice_date   DATE NOT NULL,
    due_date       DATE NOT NULL,
    amount         NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    status         TEXT NOT NULL CHECK (status IN ('paid', 'open', 'uncollectible')),
    record_source  TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic')),
    CONSTRAINT invoices_due_date_order CHECK (due_date >= invoice_date)
);

CREATE TABLE payments (
    payment_id     BIGINT PRIMARY KEY CHECK (payment_id > 0),
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    payment_date   DATE NOT NULL,
    amount         NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    status         TEXT NOT NULL CHECK (status IN ('successful', 'failed')),
    failure_reason TEXT,
    invoice_id     BIGINT NOT NULL REFERENCES invoices(invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    record_source  TEXT NOT NULL CHECK (record_source IN ('original', 'synthetic')),
    CONSTRAINT payments_failure_reason_values CHECK (
        failure_reason IS NULL OR failure_reason IN (
            'card_declined', 'authentication_required', 'insufficient_funds',
            'processor_decline', 'expired_card'
        )
    ),
    CONSTRAINT payments_success_has_no_failure CHECK (
        status <> 'successful' OR failure_reason IS NULL
    )
);

CREATE TABLE payment_attempts (
    attempt_id      BIGINT PRIMARY KEY CHECK (attempt_id > 0),
    invoice_id      BIGINT NOT NULL REFERENCES invoices(invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    payment_id      BIGINT REFERENCES payments(payment_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    attempt_date    DATE NOT NULL,
    attempt_number  INTEGER NOT NULL CHECK (attempt_number > 0),
    attempted_amount NUMERIC(12,2) NOT NULL CHECK (attempted_amount >= 0),
    outcome         TEXT NOT NULL CHECK (outcome IN ('successful', 'failed')),
    failure_reason  TEXT,
    record_source   TEXT NOT NULL CHECK (record_source IN ('synthetic', 'original_derived')),
    CONSTRAINT payment_attempts_failure_reason_values CHECK (
        failure_reason IS NULL OR failure_reason IN (
            'legacy_status_unspecified', 'card_declined',
            'authentication_required', 'insufficient_funds',
            'processor_decline', 'expired_card'
        )
    ),
    CONSTRAINT payment_attempts_outcome_reason CHECK (
        (outcome = 'successful' AND failure_reason IS NULL)
        OR (outcome = 'failed' AND failure_reason IS NOT NULL)
    )
);

CREATE TABLE refunds (
    refund_id       BIGINT PRIMARY KEY CHECK (refund_id > 0),
    invoice_id      BIGINT NOT NULL REFERENCES invoices(invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    payment_id      BIGINT NOT NULL REFERENCES payments(payment_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    refund_date     DATE NOT NULL,
    refund_amount   NUMERIC(12,2) NOT NULL CHECK (refund_amount >= 0),
    reason          TEXT NOT NULL CHECK (reason IN (
        'customer_request', 'duplicate_charge', 'proration_adjustment', 'service_issue'
    )),
    status          TEXT NOT NULL CHECK (status = 'completed'),
    record_source   TEXT NOT NULL CHECK (record_source = 'synthetic')
);

CREATE TABLE revenue_recovery (
    recovery_id     BIGINT PRIMARY KEY CHECK (recovery_id > 0),
    invoice_id      BIGINT NOT NULL REFERENCES invoices(invoice_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    subscription_id BIGINT NOT NULL REFERENCES subscriptions(subscription_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    recovery_type   TEXT NOT NULL CHECK (recovery_type IN (
        'failed_payment_retry', 'failed_payment_followup',
        'legacy_invoice_payment_mismatch'
    )),
    at_risk_amount  NUMERIC(12,2) NOT NULL CHECK (at_risk_amount >= 0),
    recovered_amount NUMERIC(12,2) NOT NULL CHECK (recovered_amount >= 0),
    recovery_date   DATE,
    status          TEXT NOT NULL CHECK (status IN ('recovered', 'unrecovered', 'requires_review')),
    record_source   TEXT NOT NULL CHECK (record_source IN ('synthetic', 'original_derived')),
    CONSTRAINT recovery_amount_limit CHECK (recovered_amount <= at_risk_amount),
    CONSTRAINT recovery_status_date CHECK (
        (status = 'recovered' AND recovery_date IS NOT NULL)
        OR (status IN ('unrecovered', 'requires_review') AND recovery_date IS NULL)
    )
);

COMMIT;
