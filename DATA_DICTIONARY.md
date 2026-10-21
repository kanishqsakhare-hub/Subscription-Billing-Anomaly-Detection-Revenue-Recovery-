# Dataset Dictionary and Modeling Notes

Source: supplied hybrid SaaS dataset ZIP. These column names are read from the *actual expanded CSV headers*. Data volume and validation counts are taken from the packaged `validation_report.json`. Always recheck before creating tables.

## Field inventory

| Table | Columns (in CSV order) | Primary key |
|---|---|---|
| `customers` | `customer_id`, `signup_date`, `company_size`, `industry`, `acquisition_channel`, `country`, `record_source` | `customer_id` |
| `subscription_plans` | `plan_id`, `plan_name`, `billing_interval`, `price`, `record_source` | `plan_id` |
| `subscriptions` | `subscription_id`, `customer_id`, `start_date`, `end_date`, `status`, `plan_id`, `record_source` | `subscription_id` |
| `plan_changes` | `change_id`, `subscription_id`, `old_plan_id`, `new_plan_id`, `change_date`, `record_source` | `change_id` |
| `churn_events` | `churn_event_id`, `subscription_id`, `churn_date`, `churn_reason`, `record_source` | `churn_event_id` |
| `invoices` | `invoice_id`, `subscription_id`, `invoice_date`, `due_date`, `amount`, `status`, `record_source` | `invoice_id` |
| `payments` | `payment_id`, `subscription_id`, `payment_date`, `amount`, `status`, `failure_reason`, `invoice_id`, `record_source` | `payment_id` |
| `payment_attempts` | `attempt_id`, `invoice_id`, `payment_id`, `subscription_id`, `attempt_date`, `attempt_number`, `attempted_amount`, `outcome`, `failure_reason`, `record_source` | `attempt_id` |
| `refunds` | `refund_id`, `invoice_id`, `payment_id`, `subscription_id`, `refund_date`, `refund_amount`, `reason`, `status`, `record_source` | `refund_id` |
| `revenue_recovery` | `recovery_id`, `invoice_id`, `subscription_id`, `recovery_type`, `at_risk_amount`, `recovered_amount`, `recovery_date`, `status`, `record_source` | `recovery_id` |

## Relationships
- `subscriptions.customer_id → customers.customer_id`; `subscriptions.plan_id → subscription_plans.plan_id`.
- `plan_changes.subscription_id → subscriptions.subscription_id`; both `old_plan_id` and `new_plan_id → subscription_plans.plan_id`.
- `churn_events.subscription_id → subscriptions.subscription_id`.
- `invoices.subscription_id → subscriptions.subscription_id`.
- `payments.subscription_id → subscriptions.subscription_id`; `payments.invoice_id → invoices.invoice_id`.
- `payment_attempts.invoice_id → invoices.invoice_id`; `payment_attempts.payment_id → payments.payment_id` where non-NULL; `subscription_id → subscriptions`.
- `refunds.invoice_id → invoices.invoice_id`; `refunds.payment_id → payments.payment_id`; `subscription_id → subscriptions`.
- `revenue_recovery.invoice_id → invoices.invoice_id`; `subscription_id → subscriptions`.

## Expected PostgreSQL data types
- All identifiers: `BIGINT` (attempt numbers: `INTEGER`).
- Dates: `DATE`.
- Currency amounts: `NUMERIC(12,2)` rather than binary floating point.
- Labels, outcomes, source flags: `TEXT` or grounded `CHECK` constraints after profiling.
- Empty cells in optional fields (`end_date`, `failure_reason`, optional `payment_id`, etc.) should load as `NULL`, not literal strings.

## Record provenance
- `original`: row preserved from source Kaggle data.
- `synthetic`: generated event/record used for project experimentation.
- `original_derived`: modeled/inferred event based on an original record; **not** an observed attempt or retry.
- Source categories may vary by table; verify distinct values.

## Material limitations and cautions
1. The 4,797 originally failed payments are aligned with invoices labeled `paid`. Preserve and flag the mismatch; it is not automatically real missing revenue or fraud.
2. Original payment-to-invoice relationships were inferred from aligned records; no native invoice FK was present in the source.
3. There were no directly observed retry sequences in original payments. Source-derived attempts are one-to-one modeling, not evidence of retry activity.
4. Refund and recovery histories in the hybrid dataset are synthetic. `recovered_amount` is scenario-specific simulation, not externally verified cash.
5. Most generated recurring invoices are full-cycle (not churn-prorated). Do not label all differences relative to hypothetical proration as actual mistakes.
6. Billing intervals and prices must be read from `subscription_plans`, not assumed monthly for every tier.
7. Use the synthetic scenario snapshot **2026-09-30** where needed, but some preserved source record dates may lie outside it.
8. The seven original plans remain unchanged; `plan_changes` tracks changes separately and the current `subscriptions.plan_id` may not reconstruct the historical price without appropriate effective-dated logic.
9. `payments` and `payment_attempts` are separate layers; aggregate at the correct grain to prevent duplicated sums when joining attempts.

## Grounded expected counts
| Table | Original | Synthetic | Original-derived | Total |
|---|---:|---:|---:|---:|
| customers | 25,000 | 75,000 | 0 | 100,000 |
| subscriptions | 25,000 | 75,000 | 0 | 100,000 |
| subscription_plans | 7 | 0 | 0 | 7 |
| invoices | 68,411 | 557,912 | 0 | 626,323 |
| payments | 68,411 | 557,912 | 0 | 626,323 |
| plan_changes | 787 | 1,379 | 0 | 2,166 |
| churn_events | 9,757 | 28,277 | 0 | 38,034 |
| payment_attempts | 0 | 588,751 | 68,411 | 657,162 |
| refunds | 0 | 8,121 | 0 | 8,121 |
| revenue_recovery | 0 | 45,040 | 4,797 | 49,837 |

The underlying generator's validation report reports primary key, foreign key, original-row preservation, churn date/status, and synthetic invoice-to-attempt validations as passed; independent *database import validation* remains required.
