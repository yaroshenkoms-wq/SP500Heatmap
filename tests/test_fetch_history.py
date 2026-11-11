import sys
import types
from datetime import datetime
from zoneinfo import ZoneInfo

sys.modules.setdefault("yfinance", types.ModuleType("yfinance"))
import fetch_history  # noqa: E402

NY = ZoneInfo("America/New_York")


def test_during_trading_today_is_skipped():
    now = datetime(2026, 11, 11, 13, 42, tzinfo=NY)
    assert fetch_history.unfinished_session_date(now) == "2026-11-11"


def test_before_open_today_is_skipped():
    now = datetime(2026, 11, 11, 8, 0, tzinfo=NY)
    assert fetch_history.unfinished_session_date(now) == "2026-11-11"


def test_after_close_nothing_skipped():
    now = datetime(2026, 11, 11, 16, 30, tzinfo=NY)
    assert fetch_history.unfinished_session_date(now) is None


def test_weekend_nothing_skipped():
    now = datetime(2026, 11, 14, 12, 0, tzinfo=NY)
    assert fetch_history.unfinished_session_date(now) is None
