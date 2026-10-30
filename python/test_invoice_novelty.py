import unittest
import pandas as pd
from invoice_novelty import build_features, periods, FEATURES


class FeatureTests(unittest.TestCase):
    def setUp(self):
        self.subs = pd.DataFrame({"subscription_id": [1], "start_date": pd.to_datetime(["2023-01-01"])})
        self.invoices = pd.DataFrame({"invoice_id": [1, 2], "subscription_id": [1, 1],
            "invoice_date": pd.to_datetime(["2023-01-01", "2023-02-01"]),
            "due_date": pd.to_datetime(["2023-01-10", "2023-02-10"]), "amount": [19, 19]})

    def test_future_rows_do_not_change_past_features(self):
        past = build_features(self.invoices.iloc[:1], self.subs)
        all_rows = build_features(self.invoices.iloc[::-1], self.subs)
        pd.testing.assert_frame_equal(past[FEATURES], all_rows.iloc[:1][FEATURES])
        self.assertEqual(all_rows.loc[1, "prior_gap_days"], 31)

    def test_duplicate_parents_rejected(self):
        with self.assertRaises(pd.errors.MergeError):
            build_features(self.invoices, pd.concat([self.subs, self.subs]))

    def test_duplicate_invoices_rejected(self):
        with self.assertRaises(ValueError):
            build_features(pd.concat([self.invoices, self.invoices]), self.subs)

    def test_split_boundaries(self):
        dates = pd.Series(pd.to_datetime(["2024-12-31", "2025-01-01", "2026-01-01"]))
        self.assertEqual(list(periods(dates)), ["train", "calibration", "test"])

    def test_outcomes_not_features(self):
        changed = self.invoices.assign(status="failed", recovered_amount=999)
        pd.testing.assert_frame_equal(build_features(changed, self.subs)[FEATURES],
                                      build_features(self.invoices, self.subs)[FEATURES])


if __name__ == "__main__":
    unittest.main()
