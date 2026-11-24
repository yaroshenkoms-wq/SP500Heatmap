import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server
from server import compute_return, compute_ytd_return, history_last_date, live_previous_close


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


class TestLivePreviousClose:
    ENTRY = {"anchor": 110, "previous_close": 100, "last_close_date": "2025-01-02"}

    def test_uses_last_close_when_history_ends_before_today(self):
        assert live_previous_close(self.ENTRY, "2025-01-03") == 110

    def test_uses_prior_close_when_history_already_has_today(self):
        assert live_previous_close(self.ENTRY, "2025-01-02") == 100

    def test_csv_fallback_entry_without_date_keeps_previous_close(self):
        assert live_previous_close({"anchor": 110, "previous_close": 100}, "2025-01-03") == 100


def test_history_last_date():
    assert history_last_date({}) == ""
    assert history_last_date({"A": series(1, 2), "B": series(1, 2, 3)}) == "2025-01-03"


class TestSeedPricesFromHistory:
    def setup_method(self):
        server.price_cache.clear()
        server.history_cache.clear()

    def test_official_close_replaces_stale_live_price(self, monkeypatch):
        monkeypatch.setattr(server, "market_today", lambda: "2025-01-03")
        server.price_cache["X"] = {"price": 95, "live_date": "2025-01-03"}
        server.history_cache["X"] = [{"date": "2025-01-02", "close": 100}, {"date": "2025-01-03", "close": 110}]
        server.seed_prices_from_history()
        assert server.price_cache["X"]["price"] == 110
        assert round(server.price_cache["X"]["change_percent"], 6) == 10

    def test_live_price_kept_while_today_close_not_in_history(self, monkeypatch):
        monkeypatch.setattr(server, "market_today", lambda: "2025-01-03")
        server.price_cache["X"] = {"price": 121, "live_date": "2025-01-03"}
        server.history_cache["X"] = [{"date": "2025-01-01", "close": 100}, {"date": "2025-01-02", "close": 110}]
        server.seed_prices_from_history()
        assert server.price_cache["X"]["price"] == 121
        assert round(server.price_cache["X"]["change_percent"], 6) == 10


def test_is_delisted(monkeypatch):
    server.history_cache.clear()
    server.history_cache.update({
        "LIVE": [{"date": "2025-03-20", "close": 1}],
        "LAG": [{"date": "2025-03-14", "close": 1}],
        "GONE": [{"date": "2025-03-01", "close": 1}],
    })
    assert not server.is_delisted("LIVE")
    assert not server.is_delisted("LAG")
    assert server.is_delisted("GONE")
    assert not server.is_delisted("NOHISTORY")


# ------------------------------------------------------------ world indices

import json
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient


def day(i):
    return f"2025-03-{i:02d}"


def mk_series(*closes, start=10):
    return [{"date": day(start + i), "close": c} for i, c in enumerate(closes)]


@pytest.fixture
def world(tmp_path, monkeypatch):
    (tmp_path / "indices").mkdir()
    registry = [
        {"id": "sp500", "name": "S&P 500", "region": "americas", "country": "US",
         "exchange_tz": "America/New_York", "close": "16:00", "currency": "USD",
         "live": True, "constituents": "SP500_with_market_cap.csv", "history": "history.db"},
        {"id": "ibex35", "name": "IBEX 35", "region": "europe", "country": "ES",
         "exchange_tz": "Europe/Madrid", "close": "17:35", "currency": "EUR",
         "live": False, "constituents": "indices/ibex35.csv", "history": "history_world.db"},
    ]
    (tmp_path / "indices" / "registry.json").write_text(json.dumps(registry))
    (tmp_path / "indices" / "ibex35.csv").write_text(
        "Symbol,Security,Sector,Subsector,MarketCap,Currency\n"
        "SAN.MC,Santander,Financial Services,Banks,80000000000,EUR\n"
        "BBVA.MC,BBVA,Financial Services,Banks,90000000000,EUR\n"
        "ITX.MC,Inditex,Consumer Cyclical,Apparel,150000000000,EUR\n"
        "OLD.MC,Old Co,,,1000,EUR\n"
        "NOHIST.MC,No History,Utilities,Power,5,EUR\n")
    (tmp_path / "SP500_with_market_cap.csv").write_text(
        "Symbol,Security,GICS Sector,GICS Sub-Industry,Market Cap\n"
        "AAPL,Apple,Tech,Hardware,3T\n")
    monkeypatch.setattr(server, "BASE_DIR", str(tmp_path))
    monkeypatch.setattr(server, "REGISTRY_PATH", str(tmp_path / "indices" / "registry.json"))
    server._registry_cache.update(mtime=None, data=server.DEFAULT_REGISTRY)
    server._index_rows_cache.clear()
    server.history_cache.clear()
    server.world_history_cache.clear()
    server.price_cache.clear()
    server._overview_cache.update(data=None, key=None)
    server.history_cache["AAPL"] = mk_series(100, 110)
    server.world_history_cache.update({
        "SAN.MC": mk_series(10, 11),
        "BBVA.MC": mk_series(20, 22),
        "ITX.MC": mk_series(50, 45),
        "OLD.MC": mk_series(1, 1, start=1),  # last close 2025-03-02, > 7 days before latest
    })
    yield tmp_path
    server._registry_cache.update(mtime=None, data=server.DEFAULT_REGISTRY)
    server._index_rows_cache.clear()
    server.history_cache.clear()
    server.world_history_cache.clear()


@pytest.fixture
def client():
    # без `with`: lifespan (сеть, Finnhub, планировщик) не запускаем
    return TestClient(server.app)


class TestIndicesEndpoint:
    def test_list(self, world, client):
        data = client.get("/api/v1/indices").json()
        assert [i["id"] for i in data] == ["sp500", "ibex35"]
        ibex = data[1]
        assert ibex == {"id": "ibex35", "name": "IBEX 35", "region": "europe", "country": "ES",
                        "currency": "EUR", "live": False, "count": 5, "historyThrough": day(11)}
        assert data[0]["live"] is True and data[0]["count"] == 1

    def test_missing_registry_means_sp500_only(self, world, client):
        os.remove(server.REGISTRY_PATH)
        data = client.get("/api/v1/indices").json()
        assert [i["id"] for i in data] == ["sp500"]
        assert client.get("/api/v1/market-hierarchy?index=ibex35").status_code == 404


class TestHierarchyIndex:
    def test_world_hierarchy(self, world, client):
        data = client.get("/api/v1/market-hierarchy?index=ibex35").json()
        names = {s["name"]: s for s in data}
        assert set(names) == {"Financial Services", "Consumer Cyclical"}  # OLD/NOHIST skipped
        banks = names["Financial Services"]["subsectors"][0]
        assert banks["name"] == "Banks"
        assert [c["ticker"] for c in banks["companies"]] == ["BBVA.MC", "SAN.MC"]  # by cap desc
        assert banks["companies"][0] == {"ticker": "BBVA.MC", "name": "BBVA", "marketCap": 90000000000.0}

    def test_default_and_sp500_are_legacy(self, world, client):
        a = client.get("/api/v1/market-hierarchy")
        b = client.get("/api/v1/market-hierarchy?index=sp500")
        assert a.json() == b.json()
        first = a.json()[0]["subsectors"][0]["companies"][0]
        assert set(first) == {"ticker", "name", "marketCap"}  # legacy shape (reads cwd CSV as before)

    def test_unknown_index_404(self, world, client):
        assert client.get("/api/v1/market-hierarchy?index=nope").status_code == 404
        assert client.get("/api/v1/performance?index=nope").status_code == 404


class TestPerformanceIndex:
    def test_world_performance_only_index_tickers(self, world, client):
        data = client.get("/api/v1/performance?index=ibex35").json()
        assert set(data) == {"SAN.MC", "BBVA.MC", "ITX.MC", "OLD.MC"}
        assert data["BBVA.MC"]["1d"] == 10.0
        assert set(data["BBVA.MC"]) == {"return1M", "return6M", "returnYTD", "return1Y", "30d", "180d", "1y", "1d", "3d", "7d", "3y", "5y", "10y"}

    def test_default_is_history_db_only(self, world, client):
        data = client.get("/api/v1/performance").json()
        assert set(data) == {"AAPL"}
        assert data == client.get("/api/v1/performance?index=sp500").json()


def test_history_looks_in_both_caches(world, client):
    assert client.get("/api/v1/history/aapl").json() == mk_series(100, 110)
    assert client.get("/api/v1/history/san.mc").json() == mk_series(10, 11)
    assert client.get("/api/v1/history/ZZZ").json() == []


class TestSchedulerDue:
    REG = [
        {"id": "sp500", "exchange_tz": "America/New_York", "close": "16:00", "history": "history.db"},
        {"id": "ibex35", "exchange_tz": "Europe/Madrid", "close": "17:35", "history": "history_world.db"},
        {"id": "n225", "exchange_tz": "Asia/Tokyo", "close": "15:30", "history": "history_world.db"},
    ]

    @staticmethod
    def utc(y, m, d, h, mi):
        return datetime(y, m, d, h, mi, tzinfo=ZoneInfo("UTC"))

    def test_before_and_after_close_plus_30(self):
        # Tue 2025-03-11, Madrid = UTC+1: 17:35+30m = 18:05 local = 17:05 UTC
        assert "ibex35" not in server.indices_due(self.REG, self.utc(2025, 3, 11, 17, 4), {})
        assert "ibex35" in server.indices_due(self.REG, self.utc(2025, 3, 11, 17, 5), {})

    def test_only_world_db_indices(self):
        assert server.indices_due(self.REG, self.utc(2025, 3, 11, 17, 5), {}) == ["ibex35"]
        assert server.indices_due(self.REG, self.utc(2025, 3, 11, 7, 0), {}) == ["n225"]  # no sp500: GitHub Action

    def test_already_refreshed_session_skipped(self):
        now = self.utc(2025, 3, 11, 17, 5)
        assert server.indices_due(self.REG, now, {"ibex35": "2025-03-11"}) == []
        assert server.indices_due(self.REG, now, {"ibex35": "2025-03-10"}) == ["ibex35"]

    def test_weekend_none(self):
        assert server.indices_due(self.REG, self.utc(2025, 3, 15, 23, 0), {}) == []

    def test_uses_exchange_local_date(self):
        # Mon 2025-03-10 16:00 UTC: Tokyo is already Tue 01:00 local, before 15:30 -> not due; Madrid Mon 17:00 -> not due
        assert server.indices_due(self.REG, self.utc(2025, 3, 10, 16, 0), {}) == []


def test_run_world_refresh_without_module(monkeypatch):
    monkeypatch.setitem(sys.modules, "fetch_world", None)  # import -> ImportError
    assert server.run_world_refresh(["ibex35"]) is None


class TestWorldOverview:
    @staticmethod
    def add_fx(rate=1.10):
        server.world_history_cache["EURUSD=X"] = [{"date": day(10), "close": 1.0}, {"date": day(11), "close": rate}]
        server._overview_cache["version"] += 1

    def test_fx_conversion_weighted_change_and_shape(self, world, client):
        self.add_fx(1.10)
        data = client.get("/api/v1/world-overview").json()
        assert [r["id"] for r in data["regions"]] == ["americas", "europe", "asia_pacific", "assets"]
        assert data["asOf"] == server.market_today()
        americas, europe, asia, assets = data["regions"]
        assert [i["id"] for i in americas["indices"]] == ["sp500"] and asia["indices"] == [] and assets["indices"] == []
        spx = americas["indices"][0]
        assert spx["capUSD"] == 3e12 and spx["count"] == 1 and spx["currency"] == "USD" and spx["live"] is True
        assert spx["changes"]["1d"] == 10.0
        ibex = europe["indices"][0]
        assert set(ibex) == {"id", "name", "country", "currency", "live", "count", "capUSD", "historyThrough", "changes"}
        assert set(ibex["changes"]) == {"1d", "3d", "7d", "30d", "180d", "1y", "3y", "5y", "10y"}
        # SAN 80B, BBVA 90B, ITX 150B (EUR) * 1.10; OLD (stale) and NOHIST (no data) are not shown
        assert ibex["count"] == 3
        assert ibex["capUSD"] == pytest.approx(320e9 * 1.10)
        # SAN +10%, BBVA +10%, ITX -10%, weights 80/90/150
        # вес — капитализация на начало периода: сегодняшняя / (1 + рост)
        w = [80 / 1.1, 90 / 1.1, 150 / 0.9]
        assert ibex["changes"]["1d"] == pytest.approx((w[0] * 10 + w[1] * 10 - w[2] * 10) / sum(w))
        assert ibex["historyThrough"] == day(11)

    def test_row_currency_overrides_index_currency(self, world, client):
        (world / "indices" / "ibex35.csv").write_text(
            "Symbol,Security,Sector,Subsector,MarketCap,Currency\n"
            "SAN.MC,Santander,F,B,100,EUR\nBBVA.MC,BBVA,F,B,100,USD\n")
        self.add_fx(2.0)
        server._index_rows_cache.clear()
        server._overview_cache["version"] += 1
        ibex = client.get("/api/v1/world-overview").json()["regions"][1]["indices"][0]
        assert ibex["capUSD"] == 300.0  # 100 EUR * 2 + 100 USD

    def test_missing_fx_excludes_index(self, world, client):
        # курса EUR нет: у индекса capUSD = null, changes = null, но он остаётся в списке (клиент не рисует плитку)
        ibex = client.get("/api/v1/world-overview").json()["regions"][1]["indices"][0]
        assert ibex["capUSD"] is None and ibex["count"] == 0
        assert all(v is None for v in ibex["changes"].values())
        assert server.missing_fx_currencies() == ["EUR"]
        assert client.get("/api/v1/world-overview").json()["regions"][0]["indices"][0]["capUSD"] == 3e12

    def test_missing_fx_skips_only_that_company(self, world, client):
        (world / "indices" / "ibex35.csv").write_text(
            "Symbol,Security,Sector,Subsector,MarketCap,Currency\n"
            "SAN.MC,Santander,F,B,100,USD\nBBVA.MC,BBVA,F,B,100,EUR\n")
        server._index_rows_cache.clear()
        server._overview_cache["version"] += 1
        ibex = client.get("/api/v1/world-overview").json()["regions"][1]["indices"][0]
        assert ibex["capUSD"] == 100.0 and ibex["count"] == 1 and ibex["changes"]["1d"] == 10.0

    def test_cache_and_invalidation(self, world, client):
        self.add_fx(1.0)
        a = server.get_world_overview_cached()
        assert server.get_world_overview_cached() is a
        server._overview_cache["version"] += 1  # как после load_history / load_world_history
        assert server.get_world_overview_cached() is not a
        b = server.get_world_overview_cached()
        server._overview_cache["at"] -= server.OVERVIEW_TTL_SECONDS + 1
        assert server.get_world_overview_cached() is not b

    def test_fx_series_do_not_move_latest_date(self):
        h = {"A": mk_series(1, 2), "EURUSD=X": [{"date": "2030-01-01", "close": 1.0}]}
        assert history_last_date(h) == day(11)

    def test_legacy_endpoints_unchanged_by_fx(self, world, client):
        self.add_fx()
        assert set(client.get("/api/v1/performance?index=ibex35").json()) == {"SAN.MC", "BBVA.MC", "ITX.MC", "OLD.MC"}


def test_run_sp500_refresh_reports_failure(monkeypatch):
    import subprocess
    import server

    class Done:
        returncode = 1
        stdout = "boom\n"

    monkeypatch.setattr(subprocess, "run", lambda *a, **k: Done())
    assert server.run_sp500_refresh() is False
    Done.returncode = 0
    assert server.run_sp500_refresh() is True
