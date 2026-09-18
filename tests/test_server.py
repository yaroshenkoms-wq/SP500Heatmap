import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from server import compute_return, compute_ytd_return


def series(*closes):
    return [{"date": f"2025-01-{i + 1:02d}", "close": c} for i, c in enumerate(closes)]


class TestComputeReturn:
    def test_basic_gain(self):
        assert compute_return(series(100, 110), 1) == 10.0

    def test_basic_loss(self):
        assert compute_return(series(100, 90), 1) == -10.0

    def test_clamps_to_start_of_series_when_not_enough_history(self):
        # trading_days_back=10 but series only has 2 points -> uses the earliest point
        assert compute_return(series(50, 60), 10) == 20.0

    def test_none_with_fewer_than_two_points(self):
        assert compute_return(series(100), 21) is None
        assert compute_return([], 21) is None

    def test_none_when_start_price_not_positive(self):
        assert compute_return(series(0, 100), 1) is None
        assert compute_return(series(-5, 100), 1) is None

    def test_zero_change(self):
        assert compute_return(series(100, 100), 1) == 0.0


class TestComputeYtdReturn:
    def test_basic_ytd(self):
        s = [
            {"date": "2025-01-02", "close": 100},
            {"date": "2025-06-15", "close": 120},
        ]
        assert compute_ytd_return(s) == 20.0

    def test_uses_first_trading_day_of_current_year_not_series_start(self):
        s = [
            {"date": "2024-12-31", "close": 90},
            {"date": "2025-01-02", "close": 100},
            {"date": "2025-06-15", "close": 110},
        ]
        assert compute_ytd_return(s) == 10.0

    def test_empty_series_returns_none(self):
        assert compute_ytd_return([]) is None

    def test_none_when_year_start_price_not_positive(self):
        s = [
            {"date": "2025-01-02", "close": 0},
            {"date": "2025-06-15", "close": 110},
        ]
        assert compute_ytd_return(s) is None
