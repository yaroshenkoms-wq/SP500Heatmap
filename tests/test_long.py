"""Длинные периоды 3y/5y/10y: без сети, yfinance подменён."""
import json
import sqlite3
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

from zoneinfo import ZoneInfo

import pandas as pd
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import fetch_long as fl  # noqa: E402
import server  # noqa: E402

TODAY = date(2026, 11, 24)  # вторник


def weekly_frame(symbols, start, weeks, price=100.0, step=1.0):
    idx = pd.date_range(start=start, periods=weeks, freq="W-MON")
    cols = pd.MultiIndex.from_product([symbols, ["Close"]])
    data = {(s, "Close"): [price + step * i for i in range(weeks)] for s in symbols}
    return pd.DataFrame(data, index=idx, columns=cols)


# ---------- fetch_long ----------

def test_all_symbols_dash_only_for_us(tmp_path):
    (tmp_path / "indices").mkdir()
    (tmp_path / "sp.csv").write_text("Symbol,x\nBRK.B,1\nAAPL,1\n")
    (tmp_path / "indices" / "ibex.csv").write_text("Symbol,x\nSAN.MC,1\nAAPL,1\n")
    reg = [{"id": "sp500", "constituents": "sp.csv"}, {"id": "ibex35", "constituents": "indices/ibex.csv"}]
    assert fl.all_symbols(reg, tmp_path) == [("BRK.B", "BRK-B"), ("AAPL", "AAPL"), ("SAN.MC", "SAN.MC")]


def test_refresh_resumes_and_marks(tmp_path):
    db = str(tmp_path / "l.db")
    calls = []

    def dl(syms):
        calls.append(list(syms))
        if "BAD" in syms:
            raise RuntimeError("boom")
        return weekly_frame([s for s in syms if s != "EMPTY"] or ["X"], "2015-01-05", 600)

    logs = []
    sleeps = []
    syms = [("AAA", "AAA"), ("EMPTY", "EMPTY"), ("BRK.B", "BRK-B")]
    now = datetime(2026, 11, 24, 12, 0)
    st = fl.refresh(db, syms, dl, now=now, log=logs.append, sleep=sleeps.append)
    assert st["ok"] == 2 and st["empty"] == 1 and st["failed"] == 0
    conn = sqlite3.connect(db)
    assert conn.execute("SELECT COUNT(*) FROM weekly_closes WHERE ticker='BRK.B'").fetchone()[0] > 500
    assert conn.execute("SELECT COUNT(*) FROM long_meta").fetchone()[0] == 3
    # текущая (ещё не законченная) неделя не пишется
    assert conn.execute("SELECT MAX(date) FROM weekly_closes").fetchone()[0] <= (now.date() - timedelta(days=5)).isoformat()
    n = len(calls)
    # повторный запуск через 3 дня: всё свежее, сеть не трогаем
    st2 = fl.refresh(db, syms, dl, now=now + timedelta(days=3), log=logs.append, sleep=sleeps.append)
    assert st2["skipped"] == 3 and len(calls) == n
    # через 7 дней — качаем заново
    st3 = fl.refresh(db, syms, dl, now=now + timedelta(days=7), log=logs.append, sleep=sleeps.append)
    assert st3["skipped"] == 0 and len(calls) > n
    assert any("[long]" in m for m in logs)


def test_failed_chunk_not_marked(tmp_path):
    db = str(tmp_path / "l.db")

    def dl(syms):
        raise RuntimeError("down")

    st = fl.refresh(db, [("BAD", "BAD")], dl, now=datetime(2026, 11, 24), log=lambda m: None, sleep=lambda s: None)
    assert st["failed"] == 1
    assert sqlite3.connect(db).execute("SELECT COUNT(*) FROM long_meta").fetchone()[0] == 0


# ---------- server ----------

@pytest.fixture
def longdb(tmp_path, monkeypatch):
    p = tmp_path / "history_long.db"
    conn = sqlite3.connect(p)
    fl.init_db(conn)
    rows = []
    # LONG: еженедельно с 2014-01-06, цена растёт на 1 за неделю; SHORT: только последние 2 года
    d = date(2014, 1, 6)
    price = 100.0
    while d <= date(2026, 11, 16):
        rows.append(("LONG", d.isoformat(), price))
        if d >= date(2024, 11, 1):
            rows.append(("SHORT", d.isoformat(), price))
        d += timedelta(days=7)
        price += 1
    conn.executemany("INSERT INTO weekly_closes VALUES (?,?,?)", rows)
    conn.commit()
    conn.close()
    monkeypatch.setattr(server, "LONG_DB_PATH", str(p))
    monkeypatch.setattr(server, "long_bases", {})
    return p


def test_years_ago_leap():
    assert server.years_ago(date(2028, 2, 29), 3) == date(2025, 2, 28)
    assert server.years_ago(TODAY, 10) == date(2016, 11, 24)


def test_compute_bases_and_returns(longdb):
    b = server.compute_long_bases(str(longdb), TODAY)
    assert set(b) == {"LONG", "SHORT"}
    assert b["LONG"]["3y"] and b["LONG"]["5y"] and b["LONG"]["10y"]
    # база 10y — закрытие недели на/до 2016-11-24 (понедельник 2016-11-21)
    weeks = (date(2016, 11, 21) - date(2014, 1, 6)).days // 7
    assert b["LONG"]["10y"] == 100 + weeks
    assert b["SHORT"] == {"3y": None, "5y": None, "10y": None}
    server.long_bases = b
    r = server.long_returns("LONG", [{"date": "2026-11-23", "close": 1000.0}])
    assert r["10y"] == pytest.approx((1000 - (100 + weeks)) / (100 + weeks) * 100)
    assert server.long_returns("SHORT", [{"date": "x", "close": 5}]) == {"3y": None, "5y": None, "10y": None}
    assert server.long_returns("NONE", [{"date": "x", "close": 5}])["3y"] is None


def test_missing_db(tmp_path):
    assert server.compute_long_bases(str(tmp_path / "no.db"), TODAY) == {}
    assert server.read_long_series("A", 3, None, str(tmp_path / "no.db")) == []


def test_read_series_appends_daily(longdb):
    daily = [{"date": "2026-11-23", "close": 777.0}]
    s = server.read_long_series("LONG", 3, daily, str(longdb))
    assert s[0]["date"] <= server.years_ago(datetime.now(ZoneInfo('UTC')).date(), 3).isoformat()
    assert s[-1] == {"date": "2026-11-23", "close": 777.0}
    assert [p["date"] for p in s] == sorted(p["date"] for p in s)
    assert server.read_long_series("BRK-B", 3, None, str(longdb)) == []  # нет такого тикера


def test_refresh_due(longdb, monkeypatch, tmp_path):
    sat = datetime(2026, 11, 21, 3, 0)
    mon = datetime(2026, 11, 23, 3, 0)
    assert server.long_refresh_due(sat, None)
    assert not server.long_refresh_due(sat, sat.date())
    assert not server.long_refresh_due(mon, None)
    monkeypatch.setattr(server, "LONG_DB_PATH", str(tmp_path / "missing.db"))
    assert server.long_refresh_due(mon, None)


def test_long_env_default():
    # LONG_REFRESH следует за WORLD_REFRESH, если не задан явно (проверяем логику на текущем окружении)
    import os
    if os.getenv("LONG_REFRESH") is None:
        assert server.LONG_REFRESH == server.WORLD_REFRESH


# эндпоинты через фикстуру world из test_server
from tests.test_server import world, mk_series  # noqa: E402,F401


def test_performance_and_overview_have_long(world, longdb):
    server.long_bases = {"SAN.MC": {"3y": 5.0, "5y": 4.0, "10y": None}, "AAPL": {"3y": 50.0, "5y": 25.0, "10y": 20.0}}
    client = TestClient(server.app)
    perf = client.get("/api/v1/performance").json()
    assert perf["AAPL"]["3y"] == pytest.approx(120.0)  # 110 vs 50
    assert perf["AAPL"]["10y"] == pytest.approx(450.0)
    ib = client.get("/api/v1/performance?index=ibex35").json()
    assert ib["SAN.MC"]["3y"] == pytest.approx(120.0) and ib["SAN.MC"]["10y"] is None
    assert ib["ITX.MC"]["3y"] is None
    server.world_history_cache["EURUSD=X"] = mk_series(1.0, 1.0)
    server._overview_cache.update(data=None, key=None)
    ov = client.get("/api/v1/world-overview").json()
    idx = {i["id"]: i for r in ov["regions"] for i in r["indices"]}
    assert idx["ibex35"]["changes"]["3y"] == pytest.approx(120.0)
    assert idx["ibex35"]["changes"]["10y"] is None
    assert idx["sp500"]["changes"]["5y"] == pytest.approx(340.0)


def test_history_range(world, longdb):
    client = TestClient(server.app)
    assert client.get("/api/v1/history/AAPL").json() == server.history_cache["AAPL"]
    assert client.get("/api/v1/history/AAPL?range=2y").status_code == 400
    r = client.get("/api/v1/history/LONG?range=5y").json()
    assert len(r) > 200 and set(r[0]) == {"date", "close"}
    assert client.get("/api/v1/history/NOPE?range=10y").json() == []
