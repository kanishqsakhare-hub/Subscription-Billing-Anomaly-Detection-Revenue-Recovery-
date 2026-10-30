"""Invoice-time novelty detection; scores are review priorities, not fraud probabilities."""
from pathlib import Path
import hashlib
import json
import platform
import numpy as np
import pandas as pd
import sklearn
from sklearn.ensemble import IsolationForest

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ["log_amount", "due_days", "tenure_days", "prior_gap_days", "first_invoice"]


def build_features(invoices, subscriptions):
    if invoices.invoice_id.duplicated().any():
        raise ValueError("Duplicate invoice IDs")
    frame = invoices.merge(subscriptions[["subscription_id", "start_date"]],
                           on="subscription_id", how="left", validate="many_to_one")
    if frame.start_date.isna().any():
        raise ValueError("Missing subscription parent")
    frame = frame.sort_values(["subscription_id", "invoice_date", "invoice_id"]).copy()
    prior = frame.groupby("subscription_id").invoice_date.shift()
    frame["log_amount"] = np.log1p(frame.amount)
    frame["due_days"] = (frame.due_date - frame.invoice_date).dt.days
    frame["tenure_days"] = (frame.invoice_date - frame.start_date).dt.days
    frame["prior_gap_days"] = (frame.invoice_date - prior).dt.days.fillna(0)
    frame["first_invoice"] = prior.isna().astype(int)
    if not np.isfinite(frame[FEATURES].to_numpy()).all():
        raise ValueError("Non-finite feature")
    return frame.sort_values("invoice_id").reset_index(drop=True)


def periods(dates):
    return np.select([dates < pd.Timestamp("2025-01-01"),
                      dates < pd.Timestamp("2026-01-01")],
                     ["train", "calibration"], default="test")


def main():
    files = {name: ROOT / "data" / f"{name}.csv"
             for name in ("invoices", "subscriptions", "payments")}
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest()
              for name, path in files.items()}
    invoices = pd.read_csv(files["invoices"], parse_dates=["invoice_date", "due_date"])
    subscriptions = pd.read_csv(files["subscriptions"], parse_dates=["start_date"])
    frame = build_features(invoices, subscriptions)
    frame = frame.loc[frame.invoice_date <= "2026-09-30"].copy()
    frame["period"] = periods(frame.invoice_date)
    model = IsolationForest(n_estimators=100, max_samples=2048,
                            contamination="auto", random_state=42, n_jobs=1)
    print("Training on earlier invoices", flush=True)
    model.fit(frame.loc[frame.period == "train", FEATURES])
    # sklearn scores are lower for unusual rows; negate for a higher-is-unusual score.
    print("Scoring chronological partitions", flush=True)
    frame["novelty_score"] = -model.score_samples(frame[FEATURES])
    calibration = frame.loc[frame.period == "calibration", "novelty_score"]
    if calibration.empty or not (frame.period == "test").any():
        raise ValueError("Empty calibration/test period")
    threshold = float(calibration.quantile(0.99))
    frame["review_flag"] = frame.novelty_score > threshold
    # Outcomes are joined only AFTER scoring. This is retrospective overlap,
    # not an input feature, ground truth label, or supervised prediction target.
    print("Comparing retrospective review flags", flush=True)
    payments = pd.read_csv(files["payments"], usecols=["invoice_id", "status"])
    outcomes = payments.assign(success=payments.status.eq("successful")).groupby("invoice_id").success.any()
    frame["sql_review_proxy"] = frame.status.eq("paid") & ~frame.invoice_id.map(outcomes).fillna(False)
    test = frame.loc[frame.period == "test"].copy()
    summary = []
    for source, group in test.groupby("record_source"):
        flagged = group.loc[group.review_flag]
        summary.append({"record_source": source, "test_invoices": len(group),
                        "flagged": len(flagged), "flag_rate": float(group.review_flag.mean()),
                        "sql_review_proxy_rows": int(group.sql_review_proxy.sum()),
                        "flagged_proxy_overlap": int(flagged.sql_review_proxy.sum())})
    out = ROOT / "results" / "python"
    out.mkdir(exist_ok=True)
    columns = ["invoice_id", "subscription_id", "invoice_date", "record_source",
               "amount", *FEATURES, "novelty_score", "review_flag", "sql_review_proxy"]
    test.sort_values(["novelty_score", "invoice_id"], ascending=[False, True])[columns].to_csv(
        out / "invoice_novelty_scores.csv", index=False)
    pd.DataFrame(summary).to_csv(out / "novelty_summary.csv", index=False)
    metadata = {"model": "IsolationForest", "seed": 42, "features": FEATURES,
                "train_before": "2025-01-01", "calibration_before": "2026-01-01",
                "test_through": "2026-09-30", "rows_by_period": frame.period.value_counts().to_dict(),
                "threshold": threshold, "threshold_policy": "strictly above calibration 99th percentile",
                "source_sha256": hashes, "python": platform.python_version(),
                "pandas": pd.__version__, "numpy": np.__version__, "sklearn": sklearn.__version__,
                "limitations": ["No independently verified anomaly labels; no accuracy claimed",
                                "Mixed source/synthetic training; distribution shift can dominate scores",
                                "Same subscriptions may occur across time periods",
                                "Invoice-time novelty detection, not future payment-failure prediction",
                                "No model tuning on test outcomes; SQL overlap is retrospective only"]}
    (out / "run_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    assert hashes == {name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for name, path in files.items()}, "Source files changed"
    print(json.dumps({"periods": metadata["rows_by_period"], "summary": summary}, indent=2))


if __name__ == "__main__":
    main()
