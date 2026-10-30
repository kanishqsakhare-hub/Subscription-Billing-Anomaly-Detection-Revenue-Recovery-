# Project Specification

## Goal
**SaaS Subscription Revenue Assurance & Billing Anomaly Detection Using Advanced SQL.** Develop a PostgreSQL-only portfolio project analyzing subscription billing, invoice/payment mismatches, failed-payment retries, refunds, simulated revenue recovery, plan changes, churn, and retention. All outputs must be reproducible from supplied CSV files and SQL scripts.

## Data and scale
Ten CSVs are supplied in `data/`, containing **2,207,973 rows** per the packaged validation report (verify actual import counts):

| Table | Rows |
|---|---:|
| customers | 100,000 |
| subscriptions | 100,000 |
| subscription_plans | 7 |
| invoices | 626,323 |
| payments | 626,323 |
| payment_attempts | 657,162 |
| refunds | 8,121 |
| revenue_recovery | 49,837 |
| plan_changes | 2,166 |
| churn_events | 38,034 |

Data is a hybrid of preserved Kaggle records, additional synthetic events, and inferred `original_derived` records. Snapshot for synthetic scenarios: **2026-09-30**; original source dates may exceed it. See `DATA_DICTIONARY.md` for full columns and caveats.

## Folder contract
```
SaaS-Subscription-Revenue-Assurance/
├── AGENTS.md
├── PROJECT_SPEC.md
├── DATA_DICTIONARY.md
├── README.md
├── .gitignore
├── data/
│   ├── customers.csv
│   ├── subscriptions.csv
│   ├── subscription_plans.csv
│   ├── invoices.csv
│   ├── payments.csv
│   ├── payment_attempts.csv
│   ├── refunds.csv
│   ├── revenue_recovery.csv
│   ├── plan_changes.csv
│   └── churn_events.csv
├── database/
│   ├── 01_schema.sql
│   ├── 02_import.sql
│   └── 03_indexes.sql
├── sql/
│   ├── 01_data_exploration.sql
│   ├── 02_revenue_analysis.sql
│   ├── 03_billing_anomalies.sql
│   ├── 04_payment_recovery.sql
│   ├── 05_churn_retention.sql
│   ├── 06_advanced_sql.sql
│   └── 07_query_optimization.sql
├── tests/
│   ├── data_integrity.sql
│   └── financial_reconciliation.sql
├── results/          # only exports of executed SQL
└── assets/           # optional ER diagram / measured benchmark graphic
```
No other `.md` files should be introduced unless necessary. An included dataset-vendor `schema.sql` is a starting reference, not an excuse to bypass baseline benchmarking: it contains indexes that should be split out into `03_indexes.sql`.

## Five gated phases

### Phase 1 — Audit and plan (no file modifications)
- Inventory CSV filenames, headers, types, counts, key uniqueness, blanks, categorical values, date ranges, and relationship consistency.
- Validate source data assumptions and list import blockers. Identify whether PostgreSQL/`psql` is available.
- Compare actual files to documented totals. Report any mismatch, then wait for approval.

### Phase 2 — Relational schema and import
- Create PostgreSQL tables with appropriate NUMERIC currency types, PKs, FKs, and reasonable constraints that do **not** reject known, preserved source anomalies.
- Generate `database/01_schema.sql` and a documented `database/02_import.sql` using `\copy` for local Windows/VS Code `psql`, or SQL `COPY` when the server can reach the paths. Do not confuse `\copy` (psql command) with pure server-side SQL.
- Make input path assumptions explicit and document invocation location. Load in order: `customers`, `subscription_plans`, `subscriptions`, `plan_changes`, `churn_events`, `invoices`, `payments`, `payment_attempts`, `refunds`, `revenue_recovery`.
- Run `tests/data_integrity.sql`, verify imported counts and relational keys. Do not repair original financial inconsistencies; flag them.

### Phase 3 — Analysis (~25–30 business questions across the first five analysis files)
- `01_data_exploration.sql`: composition, missing values, status distribution, source segmentation, invoice/payment baseline.
- `02_revenue_analysis.sql`: invoice trends, plan mix, invoiced vs collected vs refunded value, MRR/ARR with explicit eligibility and plan-billing-interval definitions, growth/cohorts. Never pass invoiced money off as recognized revenue.
- `03_billing_anomalies.sql`: paid-invoice/failed-payment mismatches, invoice without success, unmatched payments, duplicate billing candidates, missing bills, under-/over-billing candidates and contextual root causes. State false-positive caveats, especially free plans and plan changes.
- `04_payment_recovery.sql`: failed-attempt rates, retry behavior, recovered share, refund and recovery funnel, aging of unresolved candidates; distinguish synthetic recovery cases and observed payment successes.
- `05_churn_retention.sql`: cancellation cohorts, rate denominators, retention curves, plan transitions and risk segments; define active base and snapshot date before counting.
- Break analyses into commented, individually executable questions and use CTEs, window functions, conditional aggregation, and joins where justified.

### Phase 4 — Advanced SQL and performance
- `06_advanced_sql.sql`: defensible transaction examples, stored procedures/functions, trigger validation or auditable change logging. Avoid modifying source-loaded facts unless the transaction demonstration is isolated and rolled back.
- `07_query_optimization.sql`: pre-index benchmark instructions/query plans, then apply `03_indexes.sql`, then post-index plans using the same data/settings and repeated runs. Capture actual measurements or clearly mark pending. No automatic claim that all indexes help.
- `tests/financial_reconciliation.sql`: checks about successful payments, attempts, refunds, recovery statuses, double-counting, and known preserved anomalies.

### Phase 5 — Evidence and publication
- Re-run from a clean approved database and document exact setup/import commands, results, count reconciliation and benchmark evidence.
- Export meaningful findings to `results/` through SQL/`psql` only. Keep results out if not executed.
- Update the root `README.md` to contain only verified findings, limitations, schema relationships and human-readable setup instructions.
- Do a final GitHub hygiene pass; avoid committed credentials, auto-agent logs, binary database directories, and filler screenshots.

## Acceptance criteria
- All 10 CSVs load without unintended data loss; source row counts match; original vs synthetic segment count checks match.
- All declared FK links resolve; tests distinguish legitimate source anomalies from corruption.
- Analytical SQL answers substantive business questions with correct denominators, units, and period definitions.
- Recovery claims are qualified as simulated/inferred, not real-world payments or fraud determinations.
- Reproducible from documented PostgreSQL version, commands and local relative file paths (or explicit environment-specific setup).
- Performance claims backed by executed `EXPLAIN (ANALYZE, BUFFERS)` outputs before and after indexing, not guesses.

## Authorized optional Python extension

The PostgreSQL core above remains the original contract. The subsequent project scope permits a separate Python extension while preserving every existing SQL file and source CSV. The extension adds only `python/invoice_novelty.py`, `python/test_invoice_novelty.py`, `python/requirements.txt`, and executed artifacts under `results/python/`; explanations remain in this README and the existing root documentation. The extension is unsupervised invoice-time novelty detection with a temporal holdout, not fake-engagement detection, acquisition-funnel analysis or prediction of future payment failures. No independent anomaly labels are available; rule overlap must not be described as accuracy. See README for commands, methodology and measured results.
