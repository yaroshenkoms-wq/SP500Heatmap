"""
Дневные цены закрытия за 1 год для всех не-S&P 500 индексов (indices/registry.json) -> history_world.db.
Схема как у history.db: daily_closes(ticker, date, close), ticker = символ Yahoo.

Правила:
- Закрытие ещё не закончившейся сессии (по часовому поясу биржи индекса: закрытие + 30 минут) не пишем
  и стираем, если оно уже лежит в базе (идея unfinished_session_date из fetch_history.py, но для каждой биржи).
- Если по индексу данные пришли меньше чем для 90% символов — старые строки этого индекса не трогаем.
- Символы, общие для нескольких индексов (Nasdaq-100 / Dow / S&P 400 и т.д.), качаются один раз.

Запуск: python3 fetch_world.py [--db history_world.db] [id ...]
"""
import argparse
import json
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

import volumes

BASE_DIR = Path(__file__).resolve().parent
REGISTRY_PATH = BASE_DIR / "indices" / "registry.json"
DB_PATH = "history_world.db"
CHUNK_SIZE = 60
MIN_COVERAGE = 0.90
GUARD_MARGIN = timedelta(minutes=30)  # после официального закрытия даём бирже 30 минут


def unfinished_session_date(tz_name, close, now=None):
    """Местная дата (YYYY-MM-DD) сегодняшней сессии биржи, если она ещё не завершилась, иначе None.
    tz_name — пояс биржи, close — 'HH:MM' местного закрытия. Готовой считаем с закрытия + 30 минут."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    local = now.astimezone(ZoneInfo(tz_name))
    if local.weekday() >= 5:
        return None
    hh, mm = (int(x) for x in close.split(":"))
    ready_at = local.replace(hour=hh, minute=mm, second=0, microsecond=0) + GUARD_MARGIN
    if local >= ready_at:
        return None
    return local.strftime("%Y-%m-%d")


def load_registry(path=None):
    return json.loads(Path(path or REGISTRY_PATH).read_text(encoding="utf-8"))


def load_symbols(entry):
    """Символы индекса из его CSV."""
    import csv
    path = BASE_DIR / entry["constituents"]
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return [r["Symbol"].strip() for r in csv.DictReader(f) if r["Symbol"].strip()]


def fx_symbol(currency):
    """Символ Yahoo курса валюты к доллару: EUR -> EURUSD=X (сколько долларов за 1 единицу)."""
    return f"{currency}USD=X"


def load_currencies(entries=None):
    """Все валюты (кроме USD) из колонки Currency в CSV индексов + валюта индекса из реестра."""
    import csv
    entries = load_registry() if entries is None else entries
    found = set()
    for e in entries:
        if e.get("currency"):
            found.add(e["currency"])
        path = BASE_DIR / e.get("constituents", "")
        if not path.exists():
            continue
        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                c = (r.get("Currency") or "").strip().upper()
                if c:
                    found.add(c)
    found.discard("USD")
    return sorted(found)


def init_db(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS daily_closes (
            ticker TEXT NOT NULL,
            date TEXT NOT NULL,
            close REAL NOT NULL,
            PRIMARY KEY (ticker, date)
        )
        """
    )
    conn.commit()


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def default_download(symbols):
    import yfinance as yf
    return yf.download(symbols, period="1y", interval="1d", group_by="ticker",
                       auto_adjust=True, progress=False, threads=True)


def extract_closes(data, symbol, single):
    """Серия закрытий одного символа из результата yf.download (пустая серия, если данных нет)."""
    try:
        frame = data if single else data[symbol]
        series = frame["Close"]
        if isinstance(series, pd.DataFrame):  # у одиночного символа yfinance иногда отдаёт MultiIndex
            series = series.iloc[:, 0]
        return series.dropna()
    except (KeyError, TypeError, AttributeError):
        return pd.Series(dtype=float)


def download_all(symbols, downloader, report, vol_out=None):
    """{symbol: Series закрытий}; символы без данных в словарь не попадают.
    vol_out — словарь, куда складываем {symbol: Series объёмов} (если передан)."""
    result = {}
    for chunk in chunked(symbols, CHUNK_SIZE):
        data = None
        for attempt in range(2):
            try:
                data = downloader(chunk)
                break
            except Exception as e:
                report.append(f"чанк {chunk[0]}..{chunk[-1]}: ошибка {e}")
                time.sleep(2)
        if data is None or getattr(data, "empty", True):
            continue
        for sym in chunk:
            series = extract_closes(data, sym, single=len(chunk) == 1)
            if not series.empty:
                result[sym] = series
                if vol_out is not None:
                    vs = volumes.extract_volumes(data, sym, single=len(chunk) == 1)
                    if not vs.empty:
                        vol_out[sym] = vs
        time.sleep(0.5)
    return result


def refresh(db_path=DB_PATH, index_ids=None, now=None, downloader=None):
    """Обновляет history_world.db. Возвращает сводку:
    {"indices": {id: {"symbols", "with_data", "coverage", "updated"}}, "rows_written", "rows_removed",
     "skipped_dates": {id: date}, "notes": [...]}"""
    downloader = downloader or default_download
    registry = [e for e in load_registry()
                if e.get("history") == "history_world.db" and (index_ids is None or e["id"] in index_ids)]
    notes = []

    symbols_of = {e["id"]: load_symbols(e) for e in registry}
    skip_of_index = {e["id"]: unfinished_session_date(e["exchange_tz"], e["close"], now) for e in registry}

    # символ -> индексы; у символа пропускаем даты, которые «незакончены» хотя бы в одном его индексе
    owners = {}
    for iid, syms in symbols_of.items():
        for s in syms:
            owners.setdefault(s, []).append(iid)
    all_symbols = sorted(owners)

    fx_symbols = [fx_symbol(c) for c in load_currencies(registry)]
    vol_series = {}
    closes = download_all(all_symbols + fx_symbols, downloader, notes, vol_series)

    summary = {"indices": {}, "rows_written": 0, "rows_removed": 0,
               "skipped_dates": {i: d for i, d in skip_of_index.items() if d}, "notes": notes}
    passing = set()
    for iid, syms in symbols_of.items():
        with_data = sum(1 for s in syms if s in closes)
        coverage = with_data / len(syms) if syms else 0.0
        ok = coverage >= MIN_COVERAGE
        if ok:
            passing.add(iid)
        else:
            notes.append(f"{iid}: данных только {with_data} из {len(syms)} ({coverage:.0%}) — старые строки оставлены")
        summary["indices"][iid] = {"symbols": len(syms), "with_data": with_data,
                                   "coverage": round(coverage, 3), "updated": ok}

    conn = sqlite3.connect(db_path, timeout=30)
    init_db(conn)
    for sym in all_symbols:
        if sym not in closes or not (set(owners[sym]) & passing):
            continue
        skip_dates = {skip_of_index[i] for i in owners[sym] if skip_of_index[i]}
        for d in skip_dates:
            summary["rows_removed"] += conn.execute(
                "DELETE FROM daily_closes WHERE ticker = ? AND date = ?", (sym, d)).rowcount
        rows = []
        for ts, close in closes[sym].items():
            day = ts.strftime("%Y-%m-%d")
            if day in skip_dates:
                continue
            rows.append((sym, day, float(close)))
        conn.executemany("INSERT OR REPLACE INTO daily_closes (ticker, date, close) VALUES (?, ?, ?)", rows)
        summary["rows_written"] += len(rows)
    summary["fx_written"] = write_fx(conn, closes, fx_symbols)
    try:  # объёмы (последние 30 сессий) — рядом с базой цен; сбой не ломает цены
        vol_skip = {s: {skip_of_index[i] for i in owners[s] if skip_of_index[i]} for s in all_symbols}
        vol_ok = {s: v for s, v in vol_series.items() if s in owners and set(owners[s]) & passing}
        summary["volumes_written"] = volumes.save_series(volumes.path_next_to(db_path), vol_ok, vol_skip)
    except Exception as e:
        notes.append(f"объёмы не записаны: {e}")
    # даже для символов без новых данных стираем незаконченную сессию, если она вдруг уже в базе
    for iid, d in skip_of_index.items():
        if d:
            for sym in symbols_of[iid]:
                summary["rows_removed"] += conn.execute(
                    "DELETE FROM daily_closes WHERE ticker = ? AND date = ?", (sym, d)).rowcount
    conn.commit()
    conn.close()
    return summary


def write_fx(conn, closes, fx_symbols):
    """Пишет курсы в ту же таблицу daily_closes (ticker = EURUSD=X). Сессию не отсекаем: курс — последний закрытый."""
    n = 0
    for sym in fx_symbols:
        if sym not in closes:
            continue
        rows = [(sym, ts.strftime("%Y-%m-%d"), float(c)) for ts, c in closes[sym].items() if float(c) > 0]
        conn.executemany("INSERT OR REPLACE INTO daily_closes (ticker, date, close) VALUES (?, ?, ?)", rows)
        n += len(rows)
    return n


def refresh_fx(db_path=DB_PATH, currencies=None, downloader=None):
    """Быстро (секунды): качает только курсы валют к USD. Возвращает {"currencies": [...], "rows_written": n, "missing": [...]}."""
    downloader = downloader or default_download
    currencies = currencies if currencies is not None else load_currencies()
    symbols = [fx_symbol(c) for c in currencies]
    notes = []
    closes = download_all(symbols, downloader, notes)
    conn = sqlite3.connect(db_path, timeout=30)
    init_db(conn)
    n = write_fx(conn, closes, symbols)
    conn.commit()
    conn.close()
    return {"currencies": list(currencies), "rows_written": n,
            "missing": [c for c in currencies if fx_symbol(c) not in closes], "notes": notes}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("ids", nargs="*", help="id индексов (по умолчанию все)")
    ap.add_argument("--db", default=DB_PATH)
    ap.add_argument("--fx-only", action="store_true", help="скачать только курсы валют")
    args = ap.parse_args(argv)
    if args.fx_only:
        print(refresh_fx(args.db))
        return 0
    summary = refresh(args.db, args.ids or None)
    print(f"Записано строк: {summary['rows_written']}, стёрто незаконченных: {summary['rows_removed']}")
    for iid, s in summary["indices"].items():
        flag = "ok " if s["updated"] else "СКИП"
        print(f"  {flag} {iid:12} {s['with_data']:4}/{s['symbols']:4} ({s['coverage']:.0%})")
    for iid, d in summary["skipped_dates"].items():
        print(f"  сессия {d} в {iid} ещё не закончилась — не пишем")
    for n in summary["notes"]:
        print("  !", n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
