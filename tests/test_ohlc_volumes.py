"""Тесты свечей, объёмов и новых полей метрик: без сети."""
import os
import sqlite3
import sys

import pandas as pd
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fetch_fundamentals
import ohlc
import server
import volumes
from test_extras import env, mk  # noqa: F401  (фикстура env)


def frame(n=5, weekly=False):
    idx = pd.date_range("2025-03-03", periods=n, freq="7D" if weekly else "D")
    return pd.DataFrame({"Open": range(10, 10 + n), "High": range(12, 12 + n), "Low": range(9, 9 + n),
                         "Close": [float(x) for x in range(11, 11 + n)], "Volume": [1000 * (i + 1) for i in range(n)]},
                        index=idx)


@pytest.fixture
def client():
    return TestClient(server.app)


class TestOhlc:
    def test_shape_and_cache(self, env, client, monkeypatch):
        calls = []
        monkeypatch.setattr(ohlc, "default_fetcher",
                            lambda ys, period, interval: calls.append((ys, period, interval)) or (frame(), "USD"))
        monkeypatch.setattr(server, "OHLC_DB_PATH", str(env / "ohlc_cache.db"))
        r = client.get("/api/v1/ohlc/brk.b?range=1y")
        assert r.status_code == 200
        d = r.json()
        assert set(d) == {"ticker", "currency", "interval", "bars"}
        assert d["ticker"] == "BRK.B" and d["interval"] == "1d" and d["currency"] == "USD"
        assert d["bars"][0] == {"t": "2025-03-03", "o": 10.0, "h": 12.0, "l": 9.0, "c": 11.0, "v": 1000}
        assert calls == [("BRK-B", "1y", "1d")]
        assert client.get("/api/v1/ohlc/BRK.B?range=1y").json() == d
        assert len(calls) == 1  # второй раз из кэша

    def test_weekly_ranges(self, env, client, monkeypatch):
        calls = []
        monkeypatch.setattr(ohlc, "default_fetcher",
                            lambda ys, p, i: calls.append((p, i)) or (frame(weekly=True), "EUR"))
        monkeypatch.setattr(server, "OHLC_DB_PATH", str(env / "ohlc_cache.db"))
        d = client.get("/api/v1/ohlc/AAPL?range=10y").json()
        assert d["interval"] == "1wk" and d["currency"] == "EUR" and calls == [("10y", "1wk")]

    def test_errors(self, env, client, monkeypatch):
        monkeypatch.setattr(server, "OHLC_DB_PATH", str(env / "ohlc_cache.db"))
        assert client.get("/api/v1/ohlc/AAPL?range=2y").status_code == 400
        assert client.get("/api/v1/ohlc/NOPE").status_code == 404

        def boom(*a):
            raise RuntimeError("yahoo down")
        monkeypatch.setattr(ohlc, "default_fetcher", boom)
        assert client.get("/api/v1/ohlc/AAPL").status_code == 502

    def test_ttl_and_stale_fallback(self, tmp_path):
        db = str(tmp_path / "c.db")
        ohlc.build_ohlc("X", "1y", "X", db_path=db, fetcher=lambda *a: (frame(), "USD"), now=1000)
        assert ohlc.get_cached(db, "X", "1y", now=1000 + 6 * 3600 - 1) is not None
        assert ohlc.get_cached(db, "X", "1y", now=1000 + 6 * 3600 + 1) is None

        def boom(*a):
            raise RuntimeError("x")
        stale = ohlc.build_ohlc("X", "1y", "X", db_path=db, fetcher=boom, now=1000 + 10 * 3600)
        assert stale["bars"]  # Yahoo упал — отдаём просроченное
        assert ohlc.get_cached(db, "W", "10y", now=1) is None
        ohlc.build_ohlc("W", "10y", "W", db_path=db, fetcher=lambda *a: (frame(weekly=True), None), now=1000)
        assert ohlc.get_cached(db, "W", "10y", now=1000 + 2 * 86400) is not None
        assert ohlc.get_cached(db, "W", "10y", now=1000 + 4 * 86400) is None

    def test_bad_rows_skipped(self):
        df = frame(3)
        df.iloc[1, df.columns.get_loc("Close")] = float("nan")
        assert [b["t"] for b in ohlc.build_bars(df)] == ["2025-03-03", "2025-03-05"]


class TestVolumes:
    def test_upsert_and_trim(self, tmp_path):
        db = str(tmp_path / "volumes.db")
        idx = pd.date_range("2025-01-01", periods=40, freq="D")
        s = pd.Series([100.0 + i for i in range(40)], index=idx)
        s.iloc[3] = 0.0
        assert volumes.save_series(db, {"AAA": s, "BBB": s.iloc[-5:]}) == 30 + 5
        conn = sqlite3.connect(db)
        assert conn.execute("SELECT COUNT(*) FROM daily_volumes WHERE ticker='AAA'").fetchone()[0] == 30
        assert conn.execute("SELECT MIN(date) FROM daily_volumes WHERE ticker='AAA'").fetchone()[0] == "2025-01-11"
        volumes.save_series(db, {"AAA": pd.Series([5.0], index=[idx[-1]])})  # upsert той же даты
        assert conn.execute("SELECT volume FROM daily_volumes WHERE ticker='AAA' AND date='2025-02-09'").fetchone()[0] == 5.0
        assert conn.execute("SELECT COUNT(*) FROM daily_volumes WHERE ticker='AAA'").fetchone()[0] == 30
        conn.close()

    def test_skip_unfinished_session(self, tmp_path):
        db = str(tmp_path / "volumes.db")
        idx = pd.to_datetime(["2025-01-01", "2025-01-02"])
        s = pd.Series([10.0, 20.0], index=idx)
        volumes.save_series(db, {"A": s})
        volumes.save_series(db, {"A": s}, {"A": {"2025-01-02"}})
        assert volumes.read_stats(db, ["A"])["A"]["date"] == "2025-01-01"

    def test_read_stats(self, tmp_path):
        db = str(tmp_path / "volumes.db")
        idx = pd.date_range("2025-01-01", periods=4, freq="D")
        volumes.save_series(db, {"A": pd.Series([1.0, 2.0, 3.0, 6.0], index=idx)})
        st = volumes.read_stats(db, ["A", "Z"])
        assert st["A"] == {"volume": 6.0, "date": "2025-01-04", "mean": 3.0, "n": 4} and "Z" not in st
        assert volumes.read_stats(str(tmp_path / "none.db"), ["A"]) == {}

    def test_extract(self):
        data = pd.concat({"AAA": frame(3)}, axis=1)
        assert list(volumes.extract_volumes(data, "AAA", single=False)) == [1000, 2000, 3000]
        assert volumes.extract_volumes(data, "ZZZ", single=False).empty


class TestMetricsNewFields:
    def test_fundamentals_parse_and_migrate(self, tmp_path):
        f = fetch_fundamentals.parse_info({"priceToSalesTrailing12Months": 7.5, "priceToBook": 40, "revenueGrowth": 0.123,
                                           "averageVolume": 5e7, "beta": 1.2, "trailingPE": 20})
        assert f["ps"] == 7.5 and f["pb"] == 40 and f["rev_growth"] == pytest.approx(12.3) and f["avg_volume"] == 5e7
        assert fetch_fundamentals.parse_info({})["ps"] is None
        db = str(tmp_path / "old.db")
        conn = sqlite3.connect(db)  # старая схема без новых колонок
        conn.execute("""CREATE TABLE fundamentals (symbol TEXT PRIMARY KEY, name TEXT, pe REAL, forward_pe REAL,
            div_yield REAL, dividend_rate REAL, ex_dividend_date TEXT, earnings_date TEXT, beta REAL, currency TEXT,
            updated_at REAL NOT NULL)""")
        conn.commit(); conn.close()
        fetch_fundamentals.refresh_fundamentals(db, ["A"], lambda s: {"priceToBook": 3.0}, throttle=0, sleep=lambda s: None)
        assert fetch_fundamentals.read_fundamentals(db)["A"]["pb"] == 3.0

    def test_metrics_fields(self, env, client, monkeypatch):
        monkeypatch.setattr(server, "VOLUMES_DB_PATH", str(env / "volumes.db"))
        info = {"priceToSalesTrailing12Months": 7.5, "priceToBook": 40, "revenueGrowth": 0.1, "beta": 1.1,
                "averageVolume": 1000.0, "trailingPE": 20}
        fetch_fundamentals.refresh_fundamentals(server.FUNDAMENTALS_DB_PATH, ["AAPL"], lambda s: info,
                                                throttle=0, sleep=lambda s: None)
        idx = pd.date_range("2025-02-01", periods=3, freq="D")
        volumes.save_series(str(env / "volumes.db"), {"AAPL": pd.Series([900.0, 1000.0, 2000.0], index=idx),
                                                      "BTC-USD": pd.Series([5e9], index=idx[:1])})
        d = client.get("/api/v1/metrics?index=sp500").json()
        a = d["AAPL"]
        assert a["ps"] == 7.5 and a["pb"] == 40 and a["beta"] == 1.1 and a["revGrowth"] == pytest.approx(10.0)
        assert a["volume"] == 2000 and a["avgVolume"] == 1000 and a["relVolume"] == 2.0
        assert a["turnoverUSD"] == 2000 * 150 * 1.0  # последнее закрытие 150, USD
        b = d["BRK.B"]  # нет ни фундаментала, ни объёма -> null
        assert all(b[k] is None for k in ("ps", "pb", "beta", "revGrowth", "volume", "avgVolume", "relVolume", "turnoverUSD"))
        assert client.get("/api/v1/metrics?index=crypto50").json()["BTC-USD"]["turnoverUSD"] == 5e9

    def test_turnover_needs_fx_and_pence(self):
        entry, row = {"id": "x"}, {"currency": "EUR"}
        vol = {"volume": 10.0, "mean": 10.0, "n": 1}
        server.world_history_cache.clear()
        assert server.volume_fields("SAN.MC", entry, row, mk(5.0), vol, None)["turnoverUSD"] is None  # нет курса
        server.world_history_cache["EURUSD=X"] = mk(1.1)
        out = server.volume_fields("SAN.MC", entry, row, mk(5.0), vol, None)
        assert out["turnoverUSD"] == pytest.approx(55.0) and out["avgVolume"] is None and out["relVolume"] is None
        server.world_history_cache["GBPUSD=X"] = mk(1.25)
        gb = server.volume_fields("III.L", entry, {"currency": "GBP"}, mk(1000.0), vol, None)
        assert gb["turnoverUSD"] == pytest.approx(10 * 10 * 1.25)  # цена в пенсах
        server.world_history_cache.clear()
