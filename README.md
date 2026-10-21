# SaaS Subscription Revenue Assurance & Billing Anomaly Detection

A PostgreSQL project for reconciling subscription billing events, identifying records that require review, measuring modeled recovery, and analyzing churn and retention. It keeps invoices, payments, attempts, refunds, and recovery events at their correct grains so inconsistencies remain visible instead of being hidden by summary reporting.

The implementation is SQL-only: PostgreSQL SQL, PL/pgSQL, `psql`, and `\copy`. It includes a constrained relational schema, reproducible import, 29 business analyses, integrity and financial tests, functions and procedures, workflow triggers, transaction demonstrations, four result exports, and measured query-plan optimization.

All figures below were reproduced on **PostgreSQL 18.4** on **2026-10-21** from the ten repository CSVs. The clean audit loaded **2,207,973 rows**.

## Table of contents

- [Business problem](#business-problem)
- [Objectives and technology](#objectives-and-technology)
- [Dataset and provenance](#dataset-and-provenance)
- [Database architecture](#database-architecture)
- [Repository structure](#repository-structure)
- [SQL implementation](#sql-implementation)
- [Verified business results](#verified-business-results)
- [Performance optimization](#performance-optimization)
- [Validation evidence](#validation-evidence)
- [Reproducing the project](#reproducing-the-project)
- [Limitations](#limitations)
- [Conclusion](#conclusion)

## Business problem

Subscription reports can look plausible while their underlying events disagree. A paid invoice may have no successful payment, a retry sequence may end differently from its linked payment, a refund may predate the collection it references, or activity may continue after churn. Joining these tables without controlling grain can also duplicate money and blur the difference between billed value, cash collection, and modeled recovery.

This project builds an auditable PostgreSQL model around those problems. It preserves supplied anomalies, classifies them for review, and separates directly observed records from synthetic and inferred artifacts. A flagged record is a review candidate; it is not proof of fraud, realized loss, or verified recovery.

## Objectives and technology

- Load ten related CSVs without rewriting or silently repairing source rows.
- Enforce supported entity, relationship, category, date, and financial rules.
- Reconcile invoices, payments, attempts, refunds, and recovery without multiplying amounts across one-to-many joins.
- Measure billed value, collections, a net collection proxy, contracted MRR, and ARR run-rate with explicit definitions.
- Analyze failed payments, modeled retries, refunds, churn, retention, and plan changes.
- Demonstrate PL/pgSQL functions, procedures, triggers, exceptions, transactions, and idempotent workflow behavior.
- Benchmark representative queries before and after indexing on the same data.

| Area | Implementation |
|---|---|
| Database | PostgreSQL 18.4 |
| Languages | PostgreSQL SQL and PL/pgSQL |
| Loading | `psql` and client-side `\copy` |
| Core types | `BIGINT`, `DATE`, `NUMERIC(12,2)`, `TEXT`, `TIMESTAMPTZ` |
| Analysis | Joins, CTEs, filtered aggregates, window functions, `LATERAL` |
| Database programming | Functions, procedures, triggers, identity keys, exception blocks |
| Optimization | `EXPLAIN (ANALYZE, BUFFERS)`, repeat runs, partial and covering indexes |
| Outputs | SQL-generated CSVs and SVG documentation assets |

No Python, JavaScript, notebook, dashboard, web service, or application framework is required.

## Dataset and provenance

The hybrid dataset combines preserved Kaggle-derived rows with generated scenario data. The exact Kaggle listing and redistribution license were not supplied; confirm both before publishing the CSVs publicly. The synthetic reporting snapshot is **2026-09-30**, although some preserved and follow-up events extend beyond it.

| Table | Original | Synthetic | Original-derived | Total |
|---|---:|---:|---:|---:|
| `customers` | 25,000 | 75,000 | 0 | 100,000 |
| `subscriptions` | 25,000 | 75,000 | 0 | 100,000 |
| `subscription_plans` | 7 | 0 | 0 | 7 |
| `invoices` | 68,411 | 557,912 | 0 | 626,323 |
| `payments` | 68,411 | 557,912 | 0 | 626,323 |
| `payment_attempts` | 0 | 588,751 | 68,411 | 657,162 |
| `refunds` | 0 | 8,121 | 0 | 8,121 |
| `revenue_recovery` | 0 | 45,040 | 4,797 | 49,837 |
| `plan_changes` | 787 | 1,379 | 0 | 2,166 |
| `churn_events` | 9,757 | 28,277 | 0 | 38,034 |
| **Total** | **197,373** | **1,937,392** | **73,208** | **2,207,973** |

`original` identifies preserved source rows. `synthetic` identifies generated scenarios. `original_derived` identifies inferred artifacts based on original rows; these are not observed retries. Refund and recovery histories are synthetic, so their recovered amounts do not establish real cash recovery.

## Database architecture

![Entity relationship diagram](assets/er-diagram.svg)

The ten imported tables use primary keys and 17 foreign-key relationships. The advanced script creates `reconciliation_case_queue` as a derived operational table; imported facts remain unchanged.

| Domain | Relationships |
|---|---|
| Subscription | `customers` and `subscription_plans` → `subscriptions` |
| Plan history | `subscriptions` → `plan_changes`; both plan IDs → `subscription_plans` |
| Lifecycle | `subscriptions` → `churn_events` |
| Billing | `subscriptions` → `invoices` → `payments` |
| Attempts | `invoices`, optional `payments`, and `subscriptions` → `payment_attempts` |
| Adjustments | `invoices`, `payments`, and `subscriptions` → `refunds` |
| Recovery | `invoices` and `subscriptions` → `revenue_recovery` |
| Workflow | `invoices` → `reconciliation_case_queue` through a unique invoice key |

Currency uses `NUMERIC(12,2)`. Check constraints enforce known categories, non-negative amounts, date ordering, recovery limits, and valid status/reason combinations.

## Repository structure

```text
.
|-- assets/                         # ER and benchmark visuals
|-- data/                           # ten immutable source CSVs
|-- database/
|   |-- 01_schema.sql               # tables, keys, checks, foreign keys
|   |-- 02_import.sql               # dependency-ordered import
|   `-- 03_indexes.sql              # four measured indexes
|-- sql/
|   |-- 01_data_exploration.sql
|   |-- 02_revenue_analysis.sql
|   |-- 03_billing_anomalies.sql
|   |-- 04_payment_recovery.sql
|   |-- 05_churn_retention.sql
|   |-- 06_advanced_sql.sql
|   `-- 07_query_optimization.sql
|-- tests/
|   |-- data_integrity.sql
|   `-- financial_reconciliation.sql
|-- results/                         # four executed CSV exports
|-- DATA_DICTIONARY.md
|-- PROJECT_SPEC.md
|-- README.md
`-- .gitignore
```

## SQL implementation

### Schema, import, and validation

[database/01_schema.sql](database/01_schema.sql) creates the source tables in a transaction. It contains no `DROP` statement and refuses to run unless the connected database matches the configured project database.

[database/02_import.sql](database/02_import.sql) loads parents before children, maps unquoted empty CSV fields to SQL `NULL`, and refuses to load populated tables. One source-specific issue is handled without editing the CSV: populated `payment_attempts.payment_id` values use text such as `1.0`. The script stages them as text, rejects non-integral input, and converts validated values losslessly to `BIGINT`.

The order is `customers`, `subscription_plans`, `subscriptions`, `plan_changes`, `churn_events`, `invoices`, `payments`, `payment_attempts`, `refunds`, then `revenue_recovery`.

[tests/data_integrity.sql](tests/data_integrity.sql) checks counts, keys, null policy, foreign-key orphans, provenance, parent consistency, and dates. [tests/financial_reconciliation.sql](tests/financial_reconciliation.sql) checks invoice/payment cardinality, amounts, final attempts, duplicate attempt numbers, refund linkage, and recovery rules.

### Analysis design

The first five analysis files answer 29 business questions:

- [Data exploration](sql/01_data_exploration.sql): composition, segments, observed lifetimes, event ranges, invoice/payment alignment.
- [Revenue analysis](sql/02_revenue_analysis.sql): billing, collections, plan attribution, MRR/ARR, acquisition cohorts, moving averages.
- [Billing anomalies](sql/03_billing_anomalies.sql): status conflicts, duplicate candidates, cadence, price variance, post-churn events.
- [Payment recovery](sql/04_payment_recovery.sql): failure rates, reasons, attempts, modeled funnels, aging, refunds.
- [Churn and retention](sql/05_churn_retention.sql): logo churn, mature cohorts, churn reasons, plan changes, censored lifetimes.

CTEs establish the correct grain before aggregation. Window functions support growth, moving averages, effective plan segments, attempt sequences, cadence, cohorts, and work batches. Filtered aggregates make each numerator and denominator explicit.

Contracted MRR normalizes annual price by 12 and includes subscriptions active at the reporting date:

```sql
SELECT round(sum(fn_subscription_mrr(
           subscription_id, DATE '2026-09-30'
       )), 2) AS contracted_mrr
FROM subscriptions
WHERE start_date <= DATE '2026-09-30'
  AND (end_date IS NULL OR end_date > DATE '2026-09-30');
```

Billing conflicts remain candidates for investigation:

```sql
SELECT i.record_source,
       count(*) AS candidate_invoices,
       sum(i.amount) AS amount_for_review
FROM invoices i
JOIN payments p USING (invoice_id)
WHERE i.status = 'paid' AND p.status = 'failed'
GROUP BY i.record_source;
```

### Advanced PostgreSQL

[sql/06_advanced_sql.sql](sql/06_advanced_sql.sql) installs three functions—effective plan, subscription MRR, and invoice reconciliation—plus two procedures for idempotent queueing and locked workflow transitions. One queue-state trigger and four financial-parent triggers protect future writes.

Its demonstrations verify caught exceptions, parent mismatch rejection, duplicate protection, legal and illegal transitions, committed visibility, and serializable rollback. Test rows are rolled back or removed. The clean audit ended with no demonstration rows and all **2,207,973** source rows intact.

## Verified business results

Financial totals use events dated through **2026-09-30**.

### Revenue and contract value

| Metric | Verified value | Meaning |
|---|---:|---|
| Billed value | 33,555,578.00 | Invoice value; not recognized revenue |
| Successful collections | 30,087,516.00 | Successful payments |
| Completed refunds | 251,650.00 | Synthetic refund value |
| Net collection proxy | 29,835,866.00 | Collections less refunds |
| Contracted MRR | 1,549,314.17 | Monthly-equivalent plan value active at snapshot |
| ARR run-rate | 18,591,770.00 | MRR × 12 |
| Collection-to-bill ratio | 89.66% | Collection timing divided by billing timing |

MRR and ARR are contract run rates, not GAAP revenue, cash balances, or forecasts. The 45-row series is in [monthly_revenue_summary.csv](results/monthly_revenue_summary.csv).

### Billing anomalies and failed payments

| Finding | Rows | Amount | Interpretation |
|---|---:|---:|---|
| Paid invoices without successful payment | 35,636 | 1,884,768.00 | Combined review population |
| Original failed payment aligned to paid invoice | 4,797 | 240,760.00 | Requires review; linkage was inferred |
| Synthetic paid invoice with modeled recovery | 30,839 | 1,644,008.00 | Scenario outcome, not verified cash |
| Synthetic failed payment on open invoice | 17,749 | 961,645.00 | Open-billing context |
| Synthetic failed payment on uncollectible invoice | 9,693 | 530,143.00 | Uncollectible context |

No invoice lacks a payment; no invoice has multiple payments; and no payment differs from its invoice in amount or subscription. The analyses also found no duplicate billing groups, recurring-invoice gaps, invoices after churn, or effective-plan price differences.

There are **1,106 payments totaling 52,880.00** and **1,178 attempts totaling 56,089.00** after subscription end. These require context because later collection activity may be legitimate. The invoice-level export is [billing_review_candidates.csv](results/billing_review_candidates.csv).

### Retry, recovery, and refunds

| Provenance/status | Cases | At-risk amount | Modeled recovered |
|---|---:|---:|---:|
| Original-derived / requires review | 4,797 | 240,760.00 | 0.00 |
| Synthetic / recovered | 30,839 | 1,644,008.00 | 1,644,008.00 |
| Synthetic / unrecovered | 14,201 | 761,892.00 | 0.00 |

Synthetic sequences contain 58,281 invoices with failed attempts and 30,839 modeled recoveries: a **52.91% modeled retry recovery rate**. Original-derived attempts are inferred and excluded from observed retry claims.

Payment failure through the snapshot is **7.01%** for original rows and **10.48%** for synthetic rows. The 8,121 synthetic refunds total **251,650.00**. A known inconsistency affects 22 refunds totaling **562.75**, dated one to four days before their linked successful payments; the rows are preserved. See [payment_recovery_funnel.csv](results/payment_recovery_funnel.csv).

### Churn and retention

Mature 12-month quarterly retention ranges from **66.22% to 74.20%**. Only cohorts mature enough to reach an age enter that age's denominator.

| Churn reason | Subscriptions | Share |
|---|---:|---:|
| Price | 6,708 | 17.64% |
| Product fit | 6,494 | 17.07% |
| Budget | 6,457 | 16.98% |
| Competitor | 5,253 | 13.81% |
| Other | 4,877 | 12.82% |

All **2,166** plan changes are upgrades of exactly **19.00** normalized MRR, totaling **41,154.00**. This uniformity is a generator limitation. Active lifetimes are right-censored, so the project reports observed duration rather than predicted lifetime value. See [cohort_retention.csv](results/cohort_retention.csv).

## Performance optimization

[sql/07_query_optimization.sql](sql/07_query_optimization.sql) runs each benchmark twice before and after indexing. The table uses the warm second execution from the clean audit with `jit=off`, `track_io_timing=on`, `work_mem='4MB'`, and two parallel workers.

![Before-and-after query performance](assets/benchmark-comparison.svg)

| Benchmark | Before | After | Change | Plan effect |
|---|---:|---:|---:|---|
| Effective-dated snapshot MRR | 23,173.213 ms | 1,192.708 ms | 94.9% faster | Effective-date index replaces repeated history scans |
| Failed-payment reconciliation | 216.494 ms | 163.639 ms | 24.4% faster | Partial index-only scan reads failures |
| Recurring-invoice cadence | 874.007 ms | 691.758 ms | 20.9% faster | Covering index removes a 23,936 kB external sort |
| Final-attempt reconciliation | 1,401.318 ms | 1,065.169 ms | 24.0% faster | Ordered index removes a 31,984 kB attempt sort |
| Unresolved recovery aging | 128.868 ms | 176.060 ms | 36.6% slower | Sequential scans retained; no index added |
| Monthly collections | 177.986 ms | 179.377 ms | 0.8% slower | Broad sequential scan remains appropriate |

[database/03_indexes.sql](database/03_indexes.sql) retains four measured indexes:

| Index | Purpose | Size |
|---|---|---:|
| `idx_plan_changes_subscription_effective` | Effective plan lookup | 144 kB |
| `idx_invoices_subscription_date` | Billing history and cadence | 35 MB |
| `idx_payment_attempts_invoice_sequence` | Final attempt per invoice | 42 MB |
| `idx_payments_failed_invoice` | Failed-payment reconciliation | 4,176 kB |

They occupy about 81 MB. Recovery aging and monthly collections show why every filter does not receive an index: broad predicates retained sequential plans and showed no benefit. Timings depend on hardware, cache, and worker scheduling; the plan changes are more portable than one runtime.

## Validation evidence

| Validation group | Clean-audit result |
|---|---|
| 10 table totals | All passed |
| 10 primary-key uniqueness checks | All passed |
| 15 required/expected-null checks | All passed |
| 17 foreign-key orphan checks | All passed |
| 18 provenance totals | All passed |
| Invoice/payment cardinality and amounts | Passed; documented status conflicts retained |
| Attempt parents, numbering, final outcome | All passed |
| Refund parents and amount limits | Passed |
| Recovery parents, amounts, dates, failure linkage | All passed |
| Source date rules | One documented failure: 22 pre-payment refunds |
| Transaction demonstrations | All passed; no demo rows remained |

Post-churn payments, attempts, and recoveries are informational review cases because validity depends on collection policy.

## Reproducing the project

Install PostgreSQL and expose `createdb` and `psql` on the command line. Configure authentication through PostgreSQL, such as `pgpass.conf`; never commit credentials. Run from the repository root so `data/` and `results/` resolve.

### 1. Create an empty database

```powershell
createdb -w -h localhost -p 5432 -U postgres saas_revenue_assurance
```

### 2. Build, import, and validate

```powershell
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/01_schema.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/02_import.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f tests/data_integrity.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f tests/financial_reconciliation.sql
```

`\copy` reads client-side files, uses headers, maps empty fields to SQL `NULL`, and leaves source files unchanged.

### 3. Run analyses and generate exports

```powershell
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/01_data_exploration.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/02_revenue_analysis.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/03_billing_anomalies.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/04_payment_recovery.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/05_churn_retention.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/06_advanced_sql.sql
```

### 4. Benchmark before and after indexes

```powershell
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/07_query_optimization.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f database/03_indexes.sql
psql -X -w -h localhost -p 5432 -U postgres -d saas_revenue_assurance -f sql/07_query_optimization.sql
```

For another deliberate database name, pass it consistently:

```powershell
psql -X -w -h localhost -U postgres -d my_audit_database -v project_database=my_audit_database -f database/01_schema.sql
```

Apply the same variable to `02_import.sql`, `06_advanced_sql.sql`, `07_query_optimization.sql`, and `03_indexes.sql`. There is no destructive reset; use a new empty database for a rebuild.

## Limitations

- The exact Kaggle URL, citation, and redistribution license need confirmation before public CSV distribution.
- Original payment-to-invoice links were inferred; the 4,797 original mismatches do not prove fraud or loss.
- Original-derived attempts are proxies, not observed retries.
- Refund and recovery records are synthetic; recovered amounts are not verified cash.
- Twenty-two synthetic refunds predate linked payments and remain unchanged.
- Most synthetic recurring invoices use full cycles without churn proration.
- Some events occur after churn or the scenario snapshot and need business context.
- Uniform upgrade-only plan history limits conclusions about expansion and contraction.
- Active lifetimes are right-censored; no predictive lifetime value is claimed.
- Benchmarks describe this installation and dataset, not universal production performance.

## Conclusion

This project turns a 2.2-million-row hybrid subscription dataset into a reproducible PostgreSQL revenue-assurance workflow. It enforces relational integrity, preserves known inconsistencies, reconciles money at the invoice grain, distinguishes observed records from modeled recovery, and documents review candidates without overstating their meaning.

The verified analysis establishes a **29,835,866.00** net collection proxy, **1,549,314.17** contracted MRR, a **52.91%** synthetic retry recovery rate, and mature 12-month retention between **66.22% and 74.20%**. The advanced SQL layer adds auditable case management, while measured indexing reduces the most expensive effective-plan query by **94.9%** and deliberately leaves broad scans unindexed when they show no benefit.
