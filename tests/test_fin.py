"""Тесты /financials, /calendar, /screener, /brief и синхронизации гуру: без сети."""
import json
import os
import sqlite3
import sys
import time
from datetime import date, timedelta

import pandas as pd
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

import fetch_fundamentals
import fin
import screener
import server
import sync_udak_gurus
from test_extras import env, mk  # noqa: F401  (фикстура env)


@pytest.fixture
def client():
    return TestClient(server.app)


def today():
    return server.datetime.now(server.MARKET_TZ).date()


def fresh_spy():
    """В env история SPY короче крипты: без этого SPY счёлся бы «замёрзшим» (общая последняя дата — по BTC)."""
    server.world_history_cache["SPY"] = mk(*[500.0 + i for i in range(39)])


def put_fund(env, **rows):
    """rows: SYMBOL=dict(поля fundamentals)."""
    path = str(env / "fundamentals.db")
    conn = sqlite3.connect(path)
    fetch_fundamentals.init_db(conn)
    base = dict(name=None, pe=None, forward_pe=None, div_yield=None, dividend_rate=None, ex_dividend_date=None,
                earnings_date=None, beta=None, ps=None, pb=None, rev_growth=None, avg_volume=None, currency="USD",
                dividend_date=None)
    for sym, f in rows.items():
        fetch_fundamentals.save_one(conn, sym.replace("_", "."), {**base, **f})
    conn.commit()
    conn.close()


# ---------------------------------------------------------------- отчётность

def frame(rows, cols):
    df = pd.DataFrame.from_dict({k: list(v) for k, v in rows.items()}, orient="index")
    df.columns = [pd.Timestamp(c) for c in cols]
    return df


def fake_data():
    ann = ["2025-09-30", "2024-09-30", "2023-09-30", "2022-09-30", "2021-09-30"]
    qs = ["2026-09-30", "2026-06-30", "2026-03-31", "2025-12-31", "2025-09-30", "2025-06-30", "2025-03-31"]
    inc = lambda cols: frame({"Total Revenue": range(100, 100 + len(cols)), "Gross Profit": range(40, 40 + len(cols)),  # noqa: E731
                              "Operating Income": range(30, 30 + len(cols)), "Net Income": range(20, 20 + len(cols)),
                              "Diluted EPS": [1.5] * len(cols)}, cols)
    bal = lambda cols: frame({"Total Debt": [500] * len(cols), "Cash And Cash Equivalents": [50] * len(cols),  # noqa: E731
                              "Ordinary Shares Number": [1000] * len(cols)}, cols)
    cf = lambda cols: frame({"Free Cash Flow": [25] * len(cols)}, cols)  # noqa: E731
    info = {"financialCurrency": "USD", "grossMargins": 0.4878, "operatingMargins": 0.33, "profitMargins": 0.276,
            "returnOnEquity": 1.42, "returnOnAssets": 0.25, "debtToEquity": 84.0, "currentRatio": 1.02,
            "enterpriseToEbitda": 29.8, "trailingPegRatio": 2.7, "marketCap": 1000.0, "freeCashflow": 50.0,
            "recommendationKey": "buy", "numberOfAnalystOpinions": 39, "targetMeanPrice": 300.0,
            "targetHighPrice": 400.0, "targetLowPrice": 200.0, "currentPrice": 250.0}
    return {"income_a": inc(ann), "income_q": inc(qs), "balance_a": bal(ann), "balance_q": bal(qs),
            "cashflow_a": cf(ann), "cashflow_q": cf(qs), "info": info}


@pytest.fixture
def fin_env(env, monkeypatch):
    monkeypatch.setattr(server, "FINANCIALS_DB_PATH", str(env / "financials_cache.db"))
    guru = {"gurus": [
        {"key": "a", "name": "Guru A", "reportDate": "2026-09-30", "holdings": {"AAPL": {"weightPct": 5.0, "changeQ": "add"}}},
        {"key": "b", "name": "Guru B", "reportDate": "2026-06-30", "holdings": {"AAPL": {"weightPct": 9.5, "changeQ": "new"}}},
    ]}
    path = env / "guru.json"
    path.write_text(json.dumps(guru))
    monkeypatch.setattr(server, "GURU_HOLDINGS_PATH", str(path))
    return env


class TestFinancials:
    def test_shape_limits_cache_and_holders(self, fin_env, client, monkeypatch):
        calls = []
        monkeypatch.setattr(fin, "default_fetcher", lambda ys: calls.append(ys) or fake_data())
        r = client.get("/api/v1/financials/aapl")
        assert r.status_code == 200
        d = r.json()
        assert set(d) == {"ticker", "currency", "annual", "quarterly", "ratios", "analysts", "holders"}
        assert d["ticker"] == "AAPL" and d["currency"] == "USD"
        assert len(d["annual"]) == 4 and len(d["quarterly"]) == 6
        assert d["annual"][0]["period"] == "2025" and d["quarterly"][0]["period"] == "2026-Q3"
        assert set(d["annual"][0]) == {"period", "revenue", "grossProfit", "operatingIncome", "netIncome", "eps",
                                       "freeCashFlow", "totalDebt", "cash", "sharesOutstanding"}
        assert d["annual"][0]["revenue"] == 100 and d["annual"][0]["eps"] == 1.5 and d["annual"][0]["cash"] == 50
        assert set(d["ratios"]) == {"grossMargin", "operatingMargin", "netMargin", "roe", "roa", "debtToEquity",
                                    "currentRatio", "evToEbitda", "peg", "priceToFcf"}
        assert d["ratios"]["grossMargin"] == 48.78 and d["ratios"]["debtToEquity"] == 0.84
        assert d["ratios"]["priceToFcf"] == 20.0
        assert d["analysts"] == {"recommendation": "buy", "count": 39, "targetMean": 300.0, "targetHigh": 400.0,
                                 "targetLow": 200.0, "currentPrice": 250.0}
        assert [h["name"] for h in d["holders"]] == ["Guru B", "Guru A"]  # по убыванию доли
        assert d["holders"][0] == {"name": "Guru B", "weightPct": 9.5, "changeQ": "new", "reportDate": "2026-06-30"}
        client.get("/api/v1/financials/AAPL")
        assert len(calls) == 1  # второй раз — из кэша

    def test_brk_b_uses_yahoo_dash(self, fin_env, client, monkeypatch):
        calls = []
        monkeypatch.setattr(fin, "default_fetcher", lambda ys: calls.append(ys) or fake_data())
        assert client.get("/api/v1/financials/BRK.B").status_code == 200
        assert calls == ["BRK-B"]

    def test_unknown_ticker_404(self, fin_env, client):
        assert client.get("/api/v1/financials/NOPE").status_code == 404

    def test_yahoo_down_502_then_stale_cache(self, fin_env, client, monkeypatch):
        def boom(ys):
            raise RuntimeError("down")
        monkeypatch.setattr(fin, "default_fetcher", boom)
        assert client.get("/api/v1/financials/AAPL").status_code == 502
        stale = {"ticker": "AAPL", "currency": "USD", "annual": [], "quarterly": [], "ratios": {}, "analysts": {}}
        fin.put_cached(str(fin_env / "financials_cache.db"), "AAPL", stale, now=time.time() - 3 * 86400)
        r = client.get("/api/v1/financials/AAPL")
        assert r.status_code == 200 and r.json()["ticker"] == "AAPL" and r.json()["holders"]

    def test_empty_data_is_200_with_empty_lists(self, fin_env, client, monkeypatch):
        monkeypatch.setattr(fin, "default_fetcher", lambda ys: {"info": {"currency": "USD", "quoteType": "ETF"}})
        d = client.get("/api/v1/financials/SPY").json()
        assert d["annual"] == [] and d["quarterly"] == [] and d["holders"] == []

    def test_missing_rows_become_null(self):
        data = fake_data()
        data["income_a"] = data["income_a"].drop(index="Gross Profit")
        out = fin.build_financials("X", "X", lambda s: data)
        assert out["annual"][0]["grossProfit"] is None and out["annual"][0]["revenue"] == 100


class TestSyncGurus:
    def test_changes_weights_and_options(self, tmp_path):
        def h(name, cusip, value, shares, pc=""):
            return {"name": name, "cusip": cusip, "put_call": pc, "value": value, "shares": shares}
        data = {"key": "buffett", "cik": 1, "name": "X", "quarters": [
            {"period": "2026-06-30", "filed": "x", "holdings": [h("APPLE INC", "1", 10, 100), h("COCA COLA CO", "2", 10, 100),
                                                                  h("BANK OF AMER CORP", "3", 10, 100), h("APPLE INC", "9", 5, 5, "Put")]},
            {"period": "2026-09-30", "filed": "x", "holdings": [h("APPLE INC", "1", 40, 100), h("COCA COLA CO", "2", 20, 150),
                                                                  h("BANK OF AMER CORP", "3", 20, 50), h("ALPHABET INC", "02079K305", 20, 1),
                                                                  h("UNKNOWN WIDGETS", "7", 100, 1), h("APPLE INC", "1", 500, 5, "Call")]}]}
        (tmp_path / "buffett.json").write_text(json.dumps(data))
        names = {"APPLE": "AAPL"}
        out = sync_udak_gurus.build(tmp_path, names)
        g = out["gurus"][0]
        assert g["reportDate"] == "2026-09-30" and g["name"].startswith("Warren Buffett")
        hold = g["holdings"]
        assert hold["AAPL"] == {"weightPct": round(40 / 200 * 100, 3), "changeQ": "hold"}  # опцион в итог не входит
        assert hold["KO"]["changeQ"] == "add" and hold["BAC"]["changeQ"] == "reduce"
        assert hold["GOOGL"]["changeQ"] == "new"
        assert "UNKNOWN WIDGETS" not in str(hold) and len(hold) == 4

    def test_name_matching(self):
        names = {"TENCENT MUSIC ENTERTAINMENT": "TME", "APPLE": "AAPL", "TARGET": "TGT"}
        assert sync_udak_gurus.match_ticker("TENCENT MUSIC ENTERTAINM", "x", names) == "TME"
        assert sync_udak_gurus.match_ticker("Apple Inc", "x", names) == "AAPL"
        assert sync_udak_gurus.match_ticker("TARGET HOSPITALITY CORP", "x", names) is None
        assert sync_udak_gurus.match_ticker("BERKSHIRE HATHAWAY INC DEL", "084670702", names) == "BRK.B"

    def test_committed_file_is_valid(self):
        data = json.loads(open(os.path.join(os.path.dirname(fin.__file__), "data", "guru_holdings.json")).read())
        assert len(data["gurus"]) >= 10
        for g in data["gurus"]:
            assert {"key", "name", "reportDate", "holdings"} <= set(g)
            for v in g["holdings"].values():
                assert v["changeQ"] in ("new", "add", "reduce", "hold") and 0 < v["weightPct"] <= 100


# ---------------------------------------------------------------- календарь

class TestCalendar:
    def setup_funds(self, env):
        fresh_spy()
        t = today()
        iso = lambda n: (t + timedelta(days=n)).isoformat()  # noqa: E731
        put_fund(env, AAPL=dict(name="Apple Inc.", earnings_date=iso(3), ex_dividend_date=iso(5), dividend_date=iso(20),
                                dividend_rate=1.0),
                 BRK_B=dict(name="Berkshire", earnings_date=iso(30), ex_dividend_date=iso(-3)),
                 SPY=dict(name="SPDR", ex_dividend_date=iso(1), dividend_rate=6.0))
        return iso

    def test_default_range_14_days_sorted(self, env, client):
        iso = self.setup_funds(env)
        ev = client.get("/api/v1/calendar").json()["events"]
        assert [(e["date"], e["type"], e["ticker"]) for e in ev] == [
            (iso(3), "earnings", "AAPL"), (iso(5), "exDividend", "AAPL")]  # SPY не в sp500; 20 и 30 дней — вне диапазона
        assert ev[0]["name"] == "Apple Inc." and ev[0]["index"] == "sp500" and ev[0]["detail"] == {}
        assert ev[1]["detail"] == {"dividendRate": 1.0}

    def test_explicit_range_all_indices_and_types(self, env, client):
        iso = self.setup_funds(env)
        ev = client.get(f"/api/v1/calendar?from={iso(-5)}&to={iso(25)}&index=all").json()["events"]
        got = [(e["date"], e["type"], e["ticker"], e["index"]) for e in ev]
        assert got == [(iso(-3), "exDividend", "BRK.B", "sp500"), (iso(1), "exDividend", "SPY", "etf50"),
                       (iso(3), "earnings", "AAPL", "sp500"), (iso(5), "exDividend", "AAPL", "sp500"),
                       (iso(20), "dividendPay", "AAPL", "sp500")]

    def test_tickers_filter_and_empty(self, env, client):
        iso = self.setup_funds(env)
        ev = client.get(f"/api/v1/calendar?index=all&tickers=spy,brk.b&from={iso(-5)}&to={iso(40)}").json()["events"]
        assert {e["ticker"] for e in ev} == {"SPY", "BRK.B"}
        assert client.get(f"/api/v1/calendar?from={iso(100)}&to={iso(110)}").json() == {"events": []}

    def test_bad_input(self, env, client):
        assert client.get("/api/v1/calendar?from=bad").status_code == 400
        assert client.get("/api/v1/calendar?from=2026-02-01&to=2026-01-01").status_code == 400
        assert client.get("/api/v1/calendar?from=2024-01-01&to=2026-01-01").status_code == 400
        assert client.get("/api/v1/calendar?index=zzz").status_code == 404

    def test_range_logic_pure(self):
        rows = [{"ticker": "A", "name": "A", "index": "i", "earnings_date": "2026-01-10", "ex_dividend_date": "2026-01-10",
                 "dividend_date": None, "dividend_rate": 2.0}]
        ev = screener.calendar_events(rows, date(2026, 1, 10), date(2026, 1, 10))
        assert [e["type"] for e in ev] == ["earnings", "exDividend"]  # границы включены
        assert screener.calendar_events(rows, date(2026, 1, 11), date(2026, 1, 20)) == []


# ---------------------------------------------------------------- скринер

@pytest.fixture
def scr(env):
    """sp500: AAPL (3 цены, +50 % к последнему), BRK.B (+20 %); etf50: AAPL повторно (дубль) и SPY."""
    (env / "indices" / "etf50.csv").write_text(
        "Symbol,Security,Sector,Subsector,MarketCap,Currency\nAAPL,Apple ETF dup,Other,Other,1,USD\n"
        "SPY,SPDR S&P 500,US equity,Large cap blend,650000000000,USD\n")
    server._index_rows_cache.clear()
    put_fund(env, AAPL=dict(pe=30.0, ps=7.0, pb=40.0, div_yield=0.5, beta=1.2, rev_growth=8.0, avg_volume=100.0),
             BRK_B=dict(pe=12.0, ps=2.0, pb=1.4, div_yield=None, beta=0.8, rev_growth=-1.0),
             SPY=dict(div_yield=1.3))
    server.history_cache["AAPL"] = mk(100, 100, 150)
    server.history_cache["BRK.B"] = mk(10, 10, 12)
    fresh_spy()
    return env


def rows_of(client, qs):
    r = client.get("/api/v1/screener?" + qs)
    assert r.status_code == 200, r.text
    return r.json()


class TestScreener:
    def test_shape_and_defaults(self, scr, client):
        d = rows_of(client, "index=sp500")
        assert set(d) == {"total", "rows"} and d["total"] == 2
        row = d["rows"][0]
        assert set(row) == {"ticker", "name", "index", "sector", "capUSD", "change", "pe", "ps", "pb", "divYield", "beta",
                            "revGrowth", "pos52w", "relVolume"}
        assert [r["ticker"] for r in d["rows"]] == ["AAPL", "BRK.B"]  # по умолчанию — по капитализации
        assert row["capUSD"] == 3e12 and row["change"] == pytest.approx(50.0) and row["pos52w"] == 1.0

    def test_no_index_means_sp500(self, scr, client):
        assert {r["index"] for r in rows_of(client, "")["rows"]} == {"sp500"}

    def test_all_dedupes_first_index_wins(self, scr, client):
        d = rows_of(client, "index=all&limit=500")
        tickers = [r["ticker"] for r in d["rows"]]
        assert len(tickers) == len(set(tickers)) and d["total"] == len(tickers)
        assert {r["ticker"]: r["index"] for r in d["rows"]}["AAPL"] == "sp500"  # не etf50
        assert {"AAPL", "BRK.B", "SPY", "BTC-USD"} == set(tickers)

    def test_filters(self, scr, client):
        assert [r["ticker"] for r in rows_of(client, "index=sp500&peMax=20")["rows"]] == ["BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&peMin=20")["rows"]] == ["AAPL"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&minCap=2e12")["rows"]] == ["AAPL"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&maxCap=2e12")["rows"]] == ["BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&divMin=0.1")["rows"]] == ["AAPL"]  # null исключён
        assert [r["ticker"] for r in rows_of(client, "index=sp500&betaMax=1")["rows"]] == ["BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&revGrowthMin=0")["rows"]] == ["AAPL"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&psMax=3&pbMax=2")["rows"]] == ["BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&chgMin=30")["rows"]] == ["AAPL"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&chgMax=30")["rows"]] == ["BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&pos52Min=0.99")["rows"]] == ["AAPL", "BRK.B"]
        assert rows_of(client, "index=sp500&pos52Max=0.5")["rows"] == []
        assert [r["ticker"] for r in rows_of(client, "index=sp500&sector=hardware")["rows"]] == []  # сектор — «Tech»
        assert [r["ticker"] for r in rows_of(client, "index=sp500&sector=tech")["rows"]] == ["AAPL"]

    def test_sort_order_limit_and_nulls_last(self, scr, client):
        d = rows_of(client, "index=sp500&sort=pe&order=asc&limit=1")
        assert d["total"] == 2 and [r["ticker"] for r in d["rows"]] == ["BRK.B"]
        d = rows_of(client, "index=sp500&sort=divYield&order=asc")
        assert [r["ticker"] for r in d["rows"]] == ["AAPL", "BRK.B"]  # у BRK.B нет дивиденда — в конце даже при asc
        d = rows_of(client, "index=sp500&sort=divYield&order=desc")
        assert [r["ticker"] for r in d["rows"]] == ["AAPL", "BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&sort=name&order=asc")["rows"]] == ["AAPL", "BRK.B"]
        assert len(rows_of(client, "index=sp500&limit=0")["rows"]) == 1  # минимум 1

    def test_presets(self, scr, client):
        assert [r["ticker"] for r in rows_of(client, "index=sp500&preset=gainers")["rows"]] == ["AAPL", "BRK.B"]
        assert [r["ticker"] for r in rows_of(client, "index=sp500&preset=losers")["rows"]] == ["BRK.B", "AAPL"]
        assert [r["ticker"] for r in rows_of(client, "index=all&preset=highs52")["rows"]][:2] in (["AAPL", "BRK.B"], ["BRK.B", "AAPL"])
        assert rows_of(client, "index=sp500&preset=lows52")["rows"] == []
        # dividend: divYield 1..15 % и капитализация от 1 млрд -> в sp500 нет (у AAPL 0.5 %), в all — SPY (1.3 %)
        assert rows_of(client, "index=sp500&preset=dividend")["rows"] == []
        assert [r["ticker"] for r in rows_of(client, "index=all&preset=dividend")["rows"]] == ["SPY"]
        # value: P/E 0..20 и капитализация от 1 млрд -> BRK.B
        assert [r["ticker"] for r in rows_of(client, "index=all&preset=value")["rows"]] == ["BRK.B"]
        # явный параметр перекрывает пресет
        assert [r["ticker"] for r in rows_of(client, "index=all&preset=value&peMax=40")["rows"]] == ["BRK.B", "AAPL"]

    def test_preset_active_uses_volumes(self, scr, client, monkeypatch):
        import volumes
        vdb = str(scr / "volumes.db")
        monkeypatch.setattr(server, "VOLUMES_DB_PATH", vdb)
        volumes.save_series(vdb, {"AAPL": pd.Series([100.0, 100.0, 300.0], index=pd.date_range("2025-02-01", periods=3)),
                                  "BRK.B": pd.Series([50.0], index=pd.date_range("2025-02-03", periods=1))})
        d = rows_of(client, "index=sp500&preset=active")
        assert d["rows"][0]["ticker"] == "AAPL" and d["rows"][0]["relVolume"] == pytest.approx(3.0)  # 300 / avg_volume 100
        assert d["rows"][1]["relVolume"] is None  # нет средней
        assert [r["ticker"] for r in rows_of(client, "index=sp500&relVolMin=2")["rows"]] == ["AAPL"]
        assert rows_of(client, "index=sp500")["rows"][0]["relVolume"] == pytest.approx(3.0)  # объём и в обычной выдаче

    def test_periods(self, scr, client):
        server.history_cache["AAPL"] = [{"date": f"2026-01-{i:02d}", "close": float(100 + i)} for i in range(1, 29)]
        server.long_bases.clear()
        server.long_bases["AAPL"] = {"3y": 50.0, "5y": None, "10y": 25.0}
        ch = lambda p: rows_of(client, f"index=sp500&period={p}&sort=ticker&order=asc")["rows"][0]["change"]  # noqa: E731
        assert ch("1d") == pytest.approx((128 - 127) / 127 * 100)
        assert ch("3d") == pytest.approx((128 - 125) / 125 * 100)
        assert ch("7d") == pytest.approx((128 - 123) / 123 * 100)  # 5 торговых дней
        assert ch("30d") == pytest.approx((128 - 107) / 107 * 100)  # 21 торговый день назад
        assert ch("ytd") == pytest.approx(27 / 101 * 100)  # от первого закрытия года
        assert ch("3y") == pytest.approx((128 - 50) / 50 * 100)
        assert ch("5y") is None and ch("10y") == pytest.approx((128 - 25) / 25 * 100)
        assert rows_of(client, "index=sp500&period=3y&chgMin=100")["rows"][0]["ticker"] == "AAPL"

    def test_crypto_uses_calendar_days(self, scr, client):
        d = rows_of(client, "index=crypto50&period=7d")["rows"][0]
        assert d["change"] == pytest.approx((39 - 32) / 32 * 100)  # 7 календарных дней, а не 5 торговых

    def test_frozen_ticker_hidden(self, scr, client):
        server.history_cache["BRK.B"] = mk(10, 12)[:1]  # последнее закрытие на 2 дня раньше общего — ещё показан
        assert len(rows_of(client, "index=sp500")["rows"]) == 2
        server.history_cache["BRK.B"] = [{"date": "2024-01-01", "close": 10.0}] * 2
        assert [r["ticker"] for r in rows_of(client, "index=sp500")["rows"]] == ["AAPL"]

    def test_bad_params(self, scr, client):
        for qs in ("period=2d", "preset=nope", "sort=bad", "order=up"):
            assert client.get("/api/v1/screener?index=sp500&" + qs).status_code == 400
        assert client.get("/api/v1/screener?index=zzz").status_code == 404
        assert client.get("/api/v1/screener?peMax=abc").status_code == 422


# ---------------------------------------------------------------- дайджест

class TestBrief:
    def test_shape(self, scr, client, monkeypatch):
        server._brief_cache.update(at=0.0, data=None)
        news = [{"content": {"title": f"News {i}", "provider": {"displayName": "Wire"},
                             "canonicalUrl": {"url": f"https://x/{i}"}, "pubDate": "2026-11-24T10:00:00Z"}}
                for i in range(5)]
        monkeypatch.setattr(fetch_fundamentals, "default_news_fetcher", lambda s: news)
        monkeypatch.setattr(fetch_fundamentals, "default_info_fetcher",
                            lambda s: {"shortName": s, "trailingPE": 10, "currency": "USD"})
        d = client.get("/api/v1/brief?date=today").json()
        assert set(d) == {"date", "indices", "topGainers", "topLosers", "sectors", "headlines"}
        assert d["date"] == "2025-02-03"
        assert [i["id"] for i in d["indices"]] == ["sp500"]  # регион assets (крипта, ETF) в обзор индексов не входит
        assert d["indices"][0]["change1d"] == pytest.approx((50 * 3e12 / 1.5 + 20 * 1e12 / 1.2) / (3e12 / 1.5 + 1e12 / 1.2), rel=1e-6)
        assert [g["ticker"] for g in d["topGainers"]] == ["AAPL", "BRK.B"]
        assert [g["ticker"] for g in d["topLosers"]] == ["BRK.B", "AAPL"]
        assert set(d["topGainers"][0]) == {"ticker", "name", "sector", "capUSD", "change"}
        assert {s["name"] for s in d["sectors"]} == {"Tech", "Fin"}
        assert 0 < len(d["headlines"]) <= 8
        assert set(d["headlines"][0]) == {"title", "publisher", "url", "ticker"}
        assert len({h["url"] for h in d["headlines"]}) == len(d["headlines"])  # без повторов

    def test_bad_date(self, scr, client):
        assert client.get("/api/v1/brief?date=yesterday").status_code == 400
