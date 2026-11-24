"""Тесты мировых индексов: без сети, yfinance подменён."""
import csv
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import fetch_world as fw  # noqa: E402
import fetch_world_constituents as fc  # noqa: E402


def utc(y, m, d, hh, mm):
    return datetime(y, m, d, hh, mm, tzinfo=timezone.utc)


# ---------- защита от незаконченной сессии ----------

def test_guard_tokyo_open_then_closed():
    # вторник 2026-11-17: Токио закрывается 15:30 JST (06:30 UTC), готово с 16:00 JST (07:00 UTC)
    assert fw.unfinished_session_date("Asia/Tokyo", "15:30", utc(2026, 11, 17, 6, 45)) == "2026-11-17"
    assert fw.unfinished_session_date("Asia/Tokyo", "15:30", utc(2026, 11, 17, 7, 0)) is None


def test_guard_madrid_winter_time():
    # Мадрид закрывается 17:35 CET (16:35 UTC зимой), готово с 18:05 CET = 17:05 UTC
    assert fw.unfinished_session_date("Europe/Madrid", "17:35", utc(2026, 11, 17, 17, 0)) == "2026-11-17"
    assert fw.unfinished_session_date("Europe/Madrid", "17:35", utc(2026, 11, 17, 17, 5)) is None


def test_guard_new_york_and_weekend():
    assert fw.unfinished_session_date("America/New_York", "16:00", utc(2026, 11, 17, 21, 20)) == "2026-11-17"
    assert fw.unfinished_session_date("America/New_York", "16:00", utc(2026, 11, 17, 21, 30)) is None
    # суббота — торгов нет
    assert fw.unfinished_session_date("America/New_York", "16:00", utc(2026, 11, 21, 15, 0)) is None


def test_guard_uses_exchange_local_date():
    # понедельник 2026-11-16 23:30 UTC — в Сиднее уже вторник 10:30, сессия вторника идёт
    assert fw.unfinished_session_date("Australia/Sydney", "16:10", utc(2026, 11, 16, 23, 30)) == "2026-11-17"
    # воскресенье 22:00 UTC — в Токио уже понедельник 07:00 (до открытия), сессия понедельника «не закончена»
    assert fw.unfinished_session_date("Asia/Tokyo", "15:30", utc(2026, 11, 15, 22, 0)) == "2026-11-16"


# ---------- суффиксы Yahoo ----------

@pytest.mark.parametrize("fn,raw,expected", [
    (fc.with_suffix(".HK", pad=4), "SEHK: 5", "0005.HK"),
    (fc.with_suffix(".HK", pad=4), "SEHK: 9988", "9988.HK"),
    (fc.with_suffix(".KS", pad=6), "5930", "005930.KS"),
    (fc.with_suffix(".L"), "BT.A", "BT-A.L"),
    (fc.with_suffix(".L"), "BP.", "BP.L"),
    (fc.with_suffix(".T"), 9983.0, "9983.T"),
    (fc.with_suffix(".CO"), "MAERSK A", "MAERSK-A.CO"),
    (fc.with_suffix(".OL"), "OSE: AKRBP", "AKRBP.OL"),
    (fc.with_suffix(".IR"), "Euronext Dublin: A5G", "A5G.IR"),
    (fc.with_suffix(".MX", join_class=True), "ALFA A", "ALFAA.MX"),
    (fc.with_suffix(".SW", overrides={"ROP": "ROG"}), "ROP", "ROG.SW"),
    (fc.with_suffix(".KL", pad=4), "5326", "5326.KL"),
    (fc.china_symbol, "SSE: 600519", "600519.SS"),
    (fc.china_symbol, "SZSE: 300750", "300750.SZ"),
    (fc.us_symbol, "BRK.B", "BRK-B"),
    (fc.already_yahoo, "SAN.MC", "SAN.MC"),
    (fc.merval_symbol, "BCBA:YPFD NYSE: YPF", "YPFD.BA"),
    (fc.colcap_symbol, "BVC: BCOLOMBIA BVC: PFBCOLOM", "BCOLOMBIA.CL"),
    (fc.taiwan_symbol, "臺證所：2345", "2345.TW"),
])
def test_symbol_mapping(fn, raw, expected):
    assert fn(raw) == expected


def test_registry_ids_unique_and_valid():
    ids = [s["id"] for s in fc.INDICES]
    assert len(ids) == len(set(ids)) and "sp500" not in ids
    for s in fc.INDICES:
        assert s["region"] in {"americas", "europe", "asia_pacific"}
        assert len(s["close"]) == 5 and ":" in s["close"]
        # часовой пояс должен существовать
        fw.unfinished_session_date(s["tz"], s["close"], utc(2026, 11, 17, 12, 0))


# ---------- формат CSV и реестра ----------

def test_build_rows_and_csv_format(tmp_path):
    spec = {"currency": "EUR"}
    members = [("SAN.MC", "Santander"), ("BBVA.MC", "BBVA"), ("XXX.MC", "Нет данных"),
               ("GOOG", "Alphabet C"), ("GOOGL", "Alphabet A")]
    info = {
        "SAN.MC": {"cap": 80e9, "sector": "Financial Services", "industry": "Banks - Diversified", "currency": "EUR"},
        "BBVA.MC": {"cap": 70e9, "sector": "", "industry": "", "currency": ""},
        "GOOG": {"cap": 3e12, "sector": "Communication Services", "industry": "Internet", "currency": "USD"},
        "GOOGL": {"cap": 3e12, "sector": "Communication Services", "industry": "Internet", "currency": "USD"},
    }
    rows, missing = fc.build_rows(spec, members, info)
    assert missing == ["XXX.MC"]
    assert [r["Symbol"] for r in rows] == ["SAN.MC", "BBVA.MC", "GOOG"]  # второй класс акций не дублируем
    assert rows[1]["Sector"] == "Other" and rows[1]["Subsector"] == "Other" and rows[1]["Currency"] == "EUR"

    path = tmp_path / "t.csv"
    fc.write_csv(path, rows)
    with open(path, encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        assert reader.fieldnames == ["Symbol", "Security", "Sector", "Subsector", "MarketCap", "Currency"]
        first = next(reader)
    assert first["MarketCap"] == "80000000000"  # обычное число, без B/T


def test_registry_entry_matches_contract():
    e = fc.registry_entry(fc.INDICES[0])
    assert set(e) == {"id", "name", "region", "country", "exchange_tz", "close", "currency", "live",
                      "constituents", "history"}
    assert e["history"] == "history_world.db" and e["constituents"].startswith("indices/")
    assert fc.SP500_ENTRY["constituents"] == "SP500_with_market_cap.csv"
    assert fc.SP500_ENTRY["history"] == "history.db"


# ---------- refresh с подменённым yfinance ----------

def make_download(data_by_symbol):
    """Подменяет yf.download: возвращает MultiIndex-таблицу (symbol, field) как group_by='ticker'."""
    def download(symbols):
        frames = {}
        for s in symbols:
            if s in data_by_symbol:
                frames[s] = pd.DataFrame({"Close": data_by_symbol[s]})
        if not frames:
            return pd.DataFrame()
        return pd.concat(frames, axis=1)
    return download


def series(dates, start=100.0):
    return pd.Series([start + i for i in range(len(dates))], index=pd.to_datetime(dates))


@pytest.fixture
def world(tmp_path, monkeypatch):
    """Два индекса: «Мадрид» (A.MC, B.MC) и «Токио» (C.T, D.T); общий символ B.MC есть и в «Токио»."""
    (tmp_path / "indices").mkdir()
    entries = [
        {"id": "mad", "name": "Mad", "region": "europe", "country": "ES", "exchange_tz": "Europe/Madrid",
         "close": "17:35", "currency": "EUR", "live": False, "constituents": "indices/mad.csv",
         "history": "history_world.db"},
        {"id": "tok", "name": "Tok", "region": "asia_pacific", "country": "JP", "exchange_tz": "Asia/Tokyo",
         "close": "15:30", "currency": "JPY", "live": False, "constituents": "indices/tok.csv",
         "history": "history_world.db"},
        {"id": "sp500", "name": "S&P 500", "region": "americas", "country": "US",
         "exchange_tz": "America/New_York", "close": "16:00", "currency": "USD", "live": True,
         "constituents": "SP500_with_market_cap.csv", "history": "history.db"},
    ]
    (tmp_path / "indices" / "registry.json").write_text(json.dumps(entries))
    for iid, syms in {"mad": ["A.MC", "B.MC"], "tok": ["B.MC", "C.T", "D.T"]}.items():
        with open(tmp_path / "indices" / f"{iid}.csv", "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(fc.CSV_COLUMNS)
            for s in syms:
                w.writerow([s, s, "Other", "Other", 1, "EUR"])
    monkeypatch.setattr(fw, "BASE_DIR", tmp_path)
    monkeypatch.setattr(fw, "REGISTRY_PATH", tmp_path / "indices" / "registry.json")
    return tmp_path


def rows_of(db):
    conn = sqlite3.connect(db)
    out = conn.execute("SELECT ticker, date, close FROM daily_closes ORDER BY ticker, date").fetchall()
    conn.close()
    return out


def test_refresh_writes_and_skips_unfinished_session(world):
    dates = ["2026-11-16", "2026-11-17"]
    data = {s: series(dates) for s in ["A.MC", "B.MC", "C.T", "D.T"]}
    db = str(world / "h.db")
    # 17.11.2026 12:00 UTC: Мадрид ещё торгуется (до 17:05 UTC), Токио уже закончил
    summary = fw.refresh(db, now=utc(2026, 11, 17, 12, 0), downloader=make_download(data))
    got = rows_of(db)
    assert ("A.MC", "2026-11-16", 100.0) in got
    assert not any(t == "A.MC" and d == "2026-11-17" for t, d, _ in got)  # сегодня в Мадриде не пишем
    assert ("C.T", "2026-11-17", 101.0) in got                            # в Токио сессия готова
    assert not any(t == "B.MC" and d == "2026-11-17" for t, d, _ in got)  # общий символ: строже из двух
    assert summary["skipped_dates"] == {"mad": "2026-11-17"}
    assert summary["indices"]["mad"]["updated"] and summary["indices"]["tok"]["updated"]
    assert not any(t == "sp500" for t, _, _ in got)


def test_refresh_deletes_existing_unfinished_rows(world):
    db = str(world / "h.db")
    conn = sqlite3.connect(db)
    fw.init_db(conn)
    conn.execute("INSERT INTO daily_closes VALUES ('A.MC', '2026-11-17', 999.0)")
    conn.commit()
    conn.close()
    data = {s: series(["2026-11-16"]) for s in ["A.MC", "B.MC", "C.T", "D.T"]}
    summary = fw.refresh(db, index_ids={"mad"}, now=utc(2026, 11, 17, 12, 0), downloader=make_download(data))
    assert not any(d == "2026-11-17" for _, d, _ in rows_of(db))
    assert summary["rows_removed"] >= 1


def test_refresh_keeps_old_rows_when_coverage_below_90(world):
    db = str(world / "h.db")
    conn = sqlite3.connect(db)
    fw.init_db(conn)
    conn.execute("INSERT INTO daily_closes VALUES ('C.T', '2026-11-10', 50.0)")
    conn.commit()
    conn.close()
    # у «Токио» данные есть только по B.MC (1 из 3 = 33%) -> индекс пропускается, старая строка C.T остаётся
    data = {"A.MC": series(["2026-11-16"]), "B.MC": series(["2026-11-16"])}
    summary = fw.refresh(db, now=utc(2026, 11, 18, 12, 0), downloader=make_download(data))
    assert summary["indices"]["tok"]["updated"] is False
    assert summary["indices"]["mad"]["updated"] is True
    got = rows_of(db)
    assert ("C.T", "2026-11-10", 50.0) in got
    assert ("B.MC", "2026-11-16", 100.0) in got  # B.MC входит в прошедший проверку «Мадрид»
    assert any("tok" in n for n in summary["notes"])


def test_refresh_downloads_shared_symbols_once(world):
    calls = []
    inner = make_download({s: series(["2026-11-16"]) for s in ["A.MC", "B.MC", "C.T", "D.T"]})

    def spy(symbols):
        calls.append(list(symbols))
        return inner(symbols)

    fw.refresh(str(world / "h.db"), now=utc(2026, 11, 18, 12, 0), downloader=spy)
    flat = [s for c in calls for s in c]
    assert sorted(flat) == ["A.MC", "B.MC", "C.T", "D.T", "EURUSD=X", "JPYUSD=X"]  # B.MC один раз, плюс курсы


# ---------- курсы валют ----------

def test_load_currencies_from_csv_and_registry(world):
    # в фикстуре: EUR (CSV) и JPY (реестр); USD не нужен
    assert fw.load_currencies() == ["EUR", "JPY"]
    assert fw.fx_symbol("EUR") == "EURUSD=X"


def test_refresh_downloads_and_stores_fx(world):
    fx = pd.Series([1.05, 1.06], index=pd.to_datetime(["2025-03-10", "2025-03-11"]))
    dl = make_download({"A.MC": series(["2025-03-10", "2025-03-11"]), "EURUSD=X": fx})
    db = world / "w.db"
    summary = fw.refresh(str(db), now=utc(2025, 3, 12, 12, 0), downloader=dl)
    assert ("EURUSD=X", "2025-03-11", 1.06) in rows_of(db)
    assert summary["fx_written"] == 2


def test_refresh_fx_only_downloads_fx(world):
    calls = []
    inner = make_download({"EURUSD=X": pd.Series([1.1], index=pd.to_datetime(["2025-03-11"]))})

    def dl(symbols):
        calls.append(list(symbols))
        return inner(symbols)
    db = world / "w.db"
    res = fw.refresh_fx(str(db), downloader=dl)
    assert calls == [["EURUSD=X", "JPYUSD=X"]]
    assert rows_of(db) == [("EURUSD=X", "2025-03-11", pytest.approx(1.1))]
    assert res["missing"] == ["JPY"] and res["rows_written"] == 1


import pytest as _pt


@_pt.mark.benchmarks
def test_fx_refresh_includes_index_benchmarks(tmp_path):
    import fetch_world
    asked = []

    def fake_download(symbols):
        asked.extend(symbols)
        return {}
    fetch_world.refresh_fx(str(tmp_path / "w.db"), currencies=["EUR"], downloader=fake_download)
    assert "EURUSD=X" in asked and "^GSPC" in asked and "^IBEX" in asked
