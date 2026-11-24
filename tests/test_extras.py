import csv
import json
import os
import sqlite3
import sys
import time

import pandas as pd
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fetch_assets
import fetch_fundamentals
import server


def mk(*closes):
    d0 = pd.Timestamp("2025-02-01")
    return [{"date": (d0 + pd.Timedelta(days=i)).strftime("%Y-%m-%d"), "close": c} for i, c in enumerate(closes)]


# ---------------------------------------------------------------- 52 недели

class TestCompute52w:
    def test_position_between_low_and_high(self):
        pos, high, low = server.compute_52w(mk(100, 200, 150))
        assert (high, low) == (200, 100) and pos == 0.5

    def test_last_at_high_and_low(self):
        assert server.compute_52w(mk(100, 150, 200))[0] == 1.0
        assert server.compute_52w(mk(200, 150, 100))[0] == 0.0

    def test_flat_or_empty_is_none(self):
        assert server.compute_52w(mk(5, 5)) == (None, 5, 5)
        assert server.compute_52w([]) == (None, None, None)

    def test_only_last_year_used(self):
        s = [{"date": f"d{i}", "close": 1000.0} for i in range(10)] + [{"date": f"e{i}", "close": 10.0 + i % 2} for i in range(366)]
        pos, high, low = server.compute_52w(s)
        assert high == 11 and low == 10


# ---------------------------------------------------------------- фундаментал

def fake_info(**kw):
    base = {"shortName": "Acme", "trailingPE": 20.5, "forwardPE": 18.0, "currentPrice": 100.0, "dividendRate": 2.0,
            "exDividendDate": 1760000000, "beta": 1.1, "currency": "USD",
            "earningsTimestampStart": time.time() + 5 * 86400}
    base.update(kw)
    return base


class TestFundamentals:
    def test_yahoo_symbol(self):
        assert fetch_fundamentals.yahoo_symbol("BRK.B") == "BRK-B"
        assert fetch_fundamentals.yahoo_symbol("BF.B") == "BF-B"
        assert fetch_fundamentals.yahoo_symbol("BP.L") == "BP.L"
        assert fetch_fundamentals.yahoo_symbol("SAN.MC") == "SAN.MC"
        assert fetch_fundamentals.yahoo_symbol("AAPL") == "AAPL"

    def test_parse_info_percent_yield(self):
        f = fetch_fundamentals.parse_info(fake_info())
        assert f["div_yield"] == pytest.approx(2.0)  # 2/100 -> 2.0%
        assert f["pe"] == 20.5 and f["forward_pe"] == 18.0 and f["currency"] == "USD"
        assert f["ex_dividend_date"] == "2025-10-09"
        assert f["earnings_date"] is not None

    def test_parse_info_prefers_yahoo_percent_and_skips_pence(self):
        assert fetch_fundamentals.parse_info(fake_info(dividendYield=4.65))["div_yield"] == 4.65
        pence = fake_info(currency="GBp", currentPrice=544.0, dividendRate=0.25)
        assert fetch_fundamentals.parse_info(pence)["div_yield"] is None
        assert fetch_fundamentals.parse_info(fake_info(dividendYield=0.0, dividendRate=None))["div_yield"] is None

    def test_parse_info_missing_and_past_earnings(self):
        f = fetch_fundamentals.parse_info({"earningsTimestamp": 1000})
        assert f["pe"] is None and f["div_yield"] is None and f["earnings_date"] is None

    def test_refresh_uses_yahoo_dash_and_stores_our_ticker(self, tmp_path):
        db = str(tmp_path / "f.db")
        seen = []

        def fetcher(sym):
            seen.append(sym)
            return fake_info()
        res = fetch_fundamentals.refresh_fundamentals(db, ["BRK.B", "AAPL"], fetcher, throttle=0, sleep=lambda s: None)
        assert seen == ["BRK-B", "AAPL"] and res["ok"] == 2
        assert set(fetch_fundamentals.read_fundamentals(db)) == {"BRK.B", "AAPL"}
        assert fetch_fundamentals.stale_symbols(db, ["BRK.B", "ZZZ"]) == ["ZZZ"]

    def test_refresh_failure_counted_not_raised(self, tmp_path):
        def boom(sym):
            raise RuntimeError("429")
        res = fetch_fundamentals.refresh_fundamentals(str(tmp_path / "f.db"), ["AAPL"], boom, throttle=0, sleep=lambda s: None)
        assert res == {"ok": 0, "failed": 1, "skipped": 0}

    def test_news_both_formats_and_failure(self):
        new = {"content": {"title": "T1", "pubDate": "2025-01-01T10:00:00Z", "provider": {"displayName": "Reuters"},
                           "canonicalUrl": {"url": "https://x/1"}}}
        old = {"title": "T2", "publisher": "CNBC", "link": "https://x/2", "providerPublishTime": 1700000000}
        items = fetch_fundamentals.fetch_news("AAPL", lambda s: [new, old, {"title": "no link"}])
        assert items[0] == {"title": "T1", "publisher": "Reuters", "url": "https://x/1", "published": "2025-01-01T10:00:00Z"}
        assert items[1]["published"] == "2023-11-14T22:13:20Z"
        assert len(items) == 2

        def boom(s):
            raise RuntimeError("x")
        assert fetch_fundamentals.fetch_news("AAPL", boom) == []


@pytest.fixture
def env(tmp_path, monkeypatch):
    (tmp_path / "indices").mkdir()
    registry = [
        {"id": "sp500", "name": "S&P 500", "region": "americas", "country": "US", "exchange_tz": "America/New_York",
         "close": "16:00", "currency": "USD", "live": True, "constituents": "SP500_with_market_cap.csv", "history": "history.db"},
        {"id": "crypto50", "name": "Crypto Top 50", "region": "assets", "country": "", "exchange_tz": "UTC",
         "close": "00:00", "currency": "USD", "live": False, "continuous": True, "source": "Data: CoinGecko",
         "constituents": "indices/crypto50.csv", "history": "history_world.db"},
        {"id": "etf50", "name": "Top 50 US ETFs", "region": "assets", "country": "US", "exchange_tz": "America/New_York",
         "close": "16:00", "currency": "USD", "live": False, "constituents": "indices/etf50.csv", "history": "history_world.db"},
    ]
    (tmp_path / "indices" / "registry.json").write_text(json.dumps(registry))
    (tmp_path / "SP500_with_market_cap.csv").write_text(
        "Symbol,Security,GICS Sector,GICS Sub-Industry,Market Cap\nAAPL,Apple,Tech,Hardware,3T\nBRK.B,Berkshire,Fin,Ins,1T\n")
    (tmp_path / "indices" / "crypto50.csv").write_text(
        "Symbol,Security,Sector,Subsector,MarketCap,Currency\nBTC-USD,Bitcoin,Layer 1,Layer 1,1200000000000,USD\n")
    (tmp_path / "indices" / "etf50.csv").write_text(
        "Symbol,Security,Sector,Subsector,MarketCap,Currency\nSPY,SPDR S&P 500,US equity,Large cap blend,650000000000,USD\n")
    monkeypatch.setattr(server, "BASE_DIR", str(tmp_path))
    monkeypatch.setattr(server, "REGISTRY_PATH", str(tmp_path / "indices" / "registry.json"))
    monkeypatch.setattr(server, "FUNDAMENTALS_DB_PATH", str(tmp_path / "fundamentals.db"))
    server._registry_cache.update(mtime=None, data=server.DEFAULT_REGISTRY)
    server._index_rows_cache.clear()
    server._metrics_cache.clear()
    server._company_names.update(data={})
    for c in (server.history_cache, server.world_history_cache, server.price_cache):
        c.clear()
    server._overview_cache.update(data=None, key=None)
    server.history_cache["AAPL"] = mk(100, 200, 150)
    server.history_cache["BRK.B"] = mk(10, 12)
    server.world_history_cache["BTC-USD"] = mk(*[float(x) for x in range(1, 40)])
    server.world_history_cache["SPY"] = mk(500, 510)
    yield tmp_path
    server._registry_cache.update(mtime=None, data=server.DEFAULT_REGISTRY)
    server._index_rows_cache.clear()
    server._metrics_cache.clear()
    server._company_names.update(data={})
    for c in (server.history_cache, server.world_history_cache):
        c.clear()


@pytest.fixture
def client():
    return TestClient(server.app)


class TestMetricsEndpoint:
    def test_metrics_with_and_without_fundamentals(self, env, client):
        fetch_fundamentals.refresh_fundamentals(server.FUNDAMENTALS_DB_PATH, ["AAPL"], lambda s: fake_info(),
                                                throttle=0, sleep=lambda s: None)
        data = client.get("/api/v1/metrics?index=sp500").json()
        assert set(data) == {"AAPL", "BRK.B"}
        assert set(data["AAPL"]) == {"pe", "divYield", "pos52w", "high52w", "low52w", "ps", "pb", "beta", "revGrowth",
                                     "volume", "avgVolume", "relVolume", "turnoverUSD"}
        assert data["AAPL"]["pe"] == 20.5 and data["AAPL"]["divYield"] == pytest.approx(2.0)
        assert data["AAPL"]["pos52w"] == 0.5 and data["AAPL"]["high52w"] == 200 and data["AAPL"]["low52w"] == 100
        assert data["BRK.B"]["pe"] is None and data["BRK.B"]["pos52w"] == 1.0

    def test_default_index_and_unknown(self, env, client):
        assert client.get("/api/v1/metrics").json() == client.get("/api/v1/metrics?index=sp500").json()
        assert client.get("/api/v1/metrics?index=nope").status_code == 404

    def test_cache_invalidated_on_history_reload(self, env, client):
        first = client.get("/api/v1/metrics?index=sp500").json()
        server.history_cache["AAPL"] = mk(100, 200, 100)
        assert client.get("/api/v1/metrics?index=sp500").json() == first  # из кэша
        server._overview_cache["version"] += 1  # как после load_history()
        assert client.get("/api/v1/metrics?index=sp500").json()["AAPL"]["pos52w"] == 0.0

    def test_assets_index(self, env, client):
        assert client.get("/api/v1/metrics?index=crypto50").json()["BTC-USD"]["pos52w"] == 1.0
        assert "SPY" in client.get("/api/v1/metrics?index=etf50").json()


class TestCompanyEndpoint:
    def test_shape_and_cache(self, env, client, monkeypatch):
        calls = []
        news = [{"content": {"title": "Big news", "pubDate": "2025-01-01T10:00:00Z", "provider": {"displayName": "AP"},
                             "canonicalUrl": {"url": "https://x/1"}}}]
        monkeypatch.setattr(fetch_fundamentals, "default_info_fetcher", lambda s: calls.append(s) or fake_info())
        monkeypatch.setattr(fetch_fundamentals, "default_news_fetcher", lambda s: news)
        r = client.get("/api/v1/company/brk.b")
        assert r.status_code == 200
        d = r.json()
        assert set(d) == {"ticker", "name", "pe", "forwardPe", "divYield", "dividendRate", "exDividendDate",
                          "earningsDate", "high52w", "low52w", "beta", "currency", "news"}
        assert d["ticker"] == "BRK.B" and d["pe"] == 20.5 and d["high52w"] == 12 and d["low52w"] == 10
        assert d["news"] == [{"title": "Big news", "publisher": "AP", "url": "https://x/1", "published": "2025-01-01T10:00:00Z"}]
        assert calls == ["BRK-B"]
        assert client.get("/api/v1/company/BRK.B").json() == d
        assert calls == ["BRK-B"]  # второй раз — из SQLite-кэша

    def test_yahoo_failure_gives_nulls(self, env, client, monkeypatch):
        def boom(s):
            raise RuntimeError("down")
        monkeypatch.setattr(fetch_fundamentals, "default_info_fetcher", boom)
        monkeypatch.setattr(fetch_fundamentals, "default_news_fetcher", boom)
        monkeypatch.setattr(fetch_fundamentals.time, "sleep", lambda s: None)
        d = client.get("/api/v1/company/AAPL").json()
        assert d["pe"] is None and d["news"] == [] and d["name"] == "Apple" and d["high52w"] == 200

    def test_unknown_ticker_404(self, env, client):
        assert client.get("/api/v1/company/ZZZZ").status_code == 404


# ---------------------------------------------------------------- крипта / ETF / регионы

def coin(id, sym, cap, price=10.0, name=None, d7=5.0):
    return {"id": id, "symbol": sym, "name": name or id.title(), "market_cap": cap, "current_price": price,
            "price_change_percentage_7d_in_currency": d7}


class TestCrypto:
    MARKETS = [
        coin("bitcoin", "btc", 1_200, 60000, "Bitcoin"),
        coin("tether", "usdt", 1_100, 0.999, "Tether", d7=0.01),
        coin("ethereum", "eth", 1_000, 1700, "Ethereum"),
        coin("usd-coin", "usdc", 900, 1.0, "USDC", d7=0.0),
        coin("wrapped-bitcoin", "wbtc", 800, 60000, "Wrapped Bitcoin"),
        coin("staked-ether", "steth", 700, 1700, "Lido Staked Ether"),
        coin("some-usd-coin", "xusd", 650, 1.001, "Some Dollar", d7=0.2),
        coin("tether-gold", "xaut", 600, 3600, "Tether Gold"),
        coin("uniswap", "uni", 500, 4.7, "Uniswap"),
        coin("dogecoin", "doge", 400, 0.05, "Dogecoin"),
        coin("mystery", "myst", 300, 2.0, "Mystery"),
    ]

    def test_stablecoins_wrapped_and_pegged_excluded(self):
        rows = fetch_assets.build_crypto_rows(self.MARKETS, top_n=50)
        syms = [r["Symbol"] for r in rows]
        assert syms == ["BTC-USD", "ETH-USD", "UNI7083-USD", "DOGE-USD", "MYST-USD"]

    def test_top_n_and_columns_and_categories(self):
        rows = fetch_assets.build_crypto_rows(self.MARKETS, top_n=2)
        assert [r["Symbol"] for r in rows] == ["BTC-USD", "ETH-USD"]
        r = fetch_assets.build_crypto_rows(self.MARKETS, top_n=50)
        by = {x["Symbol"]: x for x in r}
        assert by["BTC-USD"]["Sector"] == "Layer 1" and by["ETH-USD"]["Sector"] == "Smart Contract Platforms"
        assert by["DOGE-USD"]["Sector"] == "Memes" and by["MYST-USD"]["Sector"] == "Other"
        assert by["BTC-USD"]["MarketCap"] == 1200 and by["BTC-USD"]["Currency"] == "USD"

    def test_csv_columns(self, tmp_path):
        p = tmp_path / "c.csv"
        fetch_assets.write_csv(p, fetch_assets.build_crypto_rows(self.MARKETS))
        with open(p) as f:
            rd = csv.DictReader(f)
            assert rd.fieldnames == ["Symbol", "Security", "Sector", "Subsector", "MarketCap", "Currency"]

    def test_refresh_crypto_no_network(self, tmp_path):
        markets = [coin(f"c{i}", f"c{i}", 1000 - i, 10.0, f"Coin{i}") for i in range(60)]
        idx = pd.date_range("2025-01-01", periods=5)

        def dl(chunk):
            return pd.concat({s: pd.DataFrame({"Close": [10.0] * 5}, index=idx) for s in chunk}, axis=1)
        db, csv_path = str(tmp_path / "w.db"), tmp_path / "crypto.csv"
        res = fetch_assets.refresh_crypto(db, csv_path, markets=markets, downloader=dl)
        assert res["coins"] == 50 and res["rows_written"] == 250
        assert len(open(csv_path).read().strip().splitlines()) == 51
        assert sqlite3.connect(db).execute("SELECT COUNT(DISTINCT ticker) FROM daily_closes").fetchone()[0] == 50

    def test_refresh_crypto_drops_wrong_price(self, tmp_path):
        markets = [coin(f"c{i}", f"c{i}", 1000 - i, 10.0, f"Coin{i}") for i in range(60)]
        idx = pd.date_range("2025-01-01", periods=5)

        def dl(chunk):
            return pd.concat({s: pd.DataFrame({"Close": [999.0 if s == "C0-USD" else 10.0] * 5}, index=idx) for s in chunk}, axis=1)
        res = fetch_assets.refresh_crypto(str(tmp_path / "w.db"), tmp_path / "c.csv", markets=markets, downloader=dl)
        assert any("C0-USD" in d for d in res["dropped"]) and res["coins"] == 50
        assert "C0-USD" not in open(tmp_path / "c.csv").read()


class TestEtfList:
    def test_about_fifty_unique_with_asset_classes(self):
        rows = fetch_assets.etf_rows()
        assert 48 <= len(rows) <= 52
        assert len({r["Symbol"] for r in rows}) == len(rows)
        assert {r["Sector"] for r in rows} == {"US equity", "International equity", "Bonds", "Commodities", "Real estate", "Sector"}
        assert all(r["MarketCap"] > 0 and r["Currency"] == "USD" for r in rows)

    def test_aum_from_yahoo_with_fallback(self, tmp_path):
        p = tmp_path / "e.csv"
        res = fetch_assets.refresh_etf_aum(p, lambda s: {"totalAssets": 123.0} if s == "SPY" else {}, sleep=lambda s: None)
        assert res["live_aum"] == 1
        rows = {r["Symbol"]: r for r in csv.DictReader(open(p))}
        assert float(rows["SPY"]["MarketCap"]) == 123.0 and float(rows["QQQ"]["MarketCap"]) > 1e9


class TestAssetsRegion:
    def test_registry_file_has_assets(self):
        reg = json.load(open(server.os.path.join(os.path.dirname(server.__file__), "indices", "registry.json")))
        by = {e["id"]: e for e in reg}
        assert by["crypto50"]["region"] == "assets" and by["crypto50"]["source"] == "Data: CoinGecko"
        assert by["etf50"]["region"] == "assets" and by["etf50"]["exchange_tz"] == "America/New_York"

    def test_indices_and_overview(self, env, client):
        idx = {i["id"]: i for i in client.get("/api/v1/indices").json()}
        assert idx["crypto50"]["region"] == "assets" and idx["crypto50"]["source"] == "Data: CoinGecko"
        assert "source" not in idx["etf50"] and "source" not in idx["sp500"]
        ov = client.get("/api/v1/world-overview").json()
        assert [r["id"] for r in ov["regions"]] == ["americas", "europe", "asia_pacific", "assets"]
        assets = ov["regions"][3]["indices"]
        assert [i["id"] for i in assets] == ["crypto50", "etf50"]
        assert assets[0]["source"] == "Data: CoinGecko" and assets[0]["capUSD"] == 1_200_000_000_000

    def test_crypto_periods_are_calendar_days(self, env, client):
        # 39 дневных свечей 1..39: 7 дней назад от 39 = 32, а не 5 торговых
        perf = client.get("/api/v1/performance?index=crypto50").json()["BTC-USD"]
        assert perf["7d"] == pytest.approx((39 - 32) / 32 * 100)
        assert perf["30d"] == pytest.approx((39 - 9) / 9 * 100)
        etf = client.get("/api/v1/performance?index=etf50").json()["SPY"]
        assert etf["1d"] == pytest.approx(2.0)

    def test_continuous_not_in_close_scheduler(self):
        reg = [{"id": "crypto50", "exchange_tz": "UTC", "close": "00:00", "history": "history_world.db", "continuous": True},
               {"id": "etf50", "exchange_tz": "America/New_York", "close": "16:00", "history": "history_world.db"}]
        from datetime import datetime
        from zoneinfo import ZoneInfo
        now = datetime(2025, 3, 11, 22, 0, tzinfo=ZoneInfo("UTC"))
        assert server.indices_due(reg, now, {}) == ["etf50"]

    def test_night_window(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        assert server.in_night_window(datetime(2025, 1, 1, 3, 0, tzinfo=ZoneInfo("UTC")))
        assert not server.in_night_window(datetime(2025, 1, 1, 12, 0, tzinfo=ZoneInfo("UTC")))
