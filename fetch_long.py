"""
Недельные закрытия за 10+ лет для всех тикеров всех индексов реестра -> history_long.db.
Таблицы: weekly_closes(ticker, date, close) — ticker как в наших CSV (BRK.B), запрос к Yahoo идёт как BRK-B;
         long_meta(ticker, refreshed_at, rows) — когда и сколько строк скачано (нужно для докачки).

Правила:
- yfinance interval=1wk, auto_adjust=True, период LONG_YEARS (11 лет: запас для базы 10y).
- Недельная точка датирована понедельником недели; ещё не законченную неделю не пишем.
- Докачка: тикеры, обновлённые меньше SKIP_DAYS (6) дней назад, пропускаем — можно прервать и запустить снова.
- Чанки по ~50 символов с паузой, 3 попытки на чанк; тикер без данных тоже помечается (не долбим его каждый запуск),
  а чанк, упавший с ошибкой, не помечается — его возьмёт следующий запуск.

Запуск: python3 fetch_long.py [--db history_long.db] [--force]
"""
import argparse
import csv
import json
import sqlite3
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

BASE_DIR = Path(__file__).resolve().parent
REGISTRY_PATH = BASE_DIR / "indices" / "registry.json"
DB_PATH = str(BASE_DIR / "history_long.db")
CHUNK_SIZE = 50
CHUNK_PAUSE = 1.5
RETRIES = 3
SKIP_DAYS = 6
LONG_YEARS = 11
LONG_PERIODS = {"3y": 3, "5y": 5, "10y": 10}
US_DOT_INDICES = {"sp500", "nasdaq100", "dow30", "sp400", "sp600"}  # классы акций: BRK.B -> BRK-B на Yahoo


def init_db(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS weekly_closes ("
                 "ticker TEXT NOT NULL, date TEXT NOT NULL, close REAL NOT NULL, PRIMARY KEY (ticker, date))")
    conn.execute("CREATE TABLE IF NOT EXISTS long_meta ("
                 "ticker TEXT PRIMARY KEY, refreshed_at TEXT NOT NULL, rows INTEGER NOT NULL)")
    conn.commit()


def yahoo_symbol(ticker, index_id=None):
    if index_id in US_DOT_INDICES:
        return ticker.replace(".", "-")
    return ticker


def all_symbols(registry=None, base_dir=None):
    """[(наш тикер, символ Yahoo)] по всем индексам реестра без повторов (S&P 500 первым)."""
    base_dir = Path(base_dir or BASE_DIR)
    if registry is None:
        registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    seen = {}
    for e in registry:
        path = base_dir / e.get("constituents", "")
        if not path.exists():
            continue
        with open(path, "r", encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                t = (r.get("Symbol") or "").strip()
                if t and t not in seen:
                    seen[t] = yahoo_symbol(t, e["id"])
    # курсы валют и ряды индексов — для графика личного портфеля дальше года
    import fetch_world
    for c in fetch_world.load_currencies(registry):
        seen.setdefault(fetch_world.fx_symbol(c), fetch_world.fx_symbol(c))
    for b in fetch_world.BENCHMARK_SYMBOLS:
        seen.setdefault(b, b)
    return list(seen.items())


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def default_download(symbols):
    import yfinance as yf
    start = (date.today() - timedelta(days=int(365.25 * LONG_YEARS))).isoformat()
    return yf.download(symbols, start=start, interval="1wk", group_by="ticker",
                       auto_adjust=True, progress=False, threads=True)


def extract_closes(data, symbol, single):
    try:
        frame = data if single else data[symbol]
        series = frame["Close"]
        if isinstance(series, pd.DataFrame):
            series = series.iloc[:, 0]
        return series.dropna()
    except (KeyError, TypeError, AttributeError):
        return pd.Series(dtype=float)


def series_rows(ticker, series, today=None):
    """Строки (ticker, 'YYYY-MM-DD', close); неделю, чья пятница ещё не прошла, отбрасываем."""
    today = today or date.today()
    cutoff = (today - timedelta(days=5)).isoformat()
    rows = []
    for ts, close in series.items():
        day = ts.strftime("%Y-%m-%d")
        if day > cutoff or close is None or not close > 0:
            continue
        rows.append((ticker, day, float(close)))
    return rows


def fresh_tickers(conn, now, skip_days=SKIP_DAYS):
    limit = (now - timedelta(days=skip_days)).strftime("%Y-%m-%dT%H:%M:%S")
    return {t for (t,) in conn.execute("SELECT ticker FROM long_meta WHERE refreshed_at >= ?", (limit,))}


def refresh(db_path=DB_PATH, symbols=None, downloader=None, now=None, force=False, log=print, sleep=time.sleep):
    """Докачивает недельную историю. Возвращает {"total","skipped","ok","empty","failed","rows"}."""
    downloader = downloader or default_download
    now = now or datetime.now(timezone.utc).replace(tzinfo=None)
    symbols = all_symbols() if symbols is None else symbols
    conn = sqlite3.connect(db_path, timeout=30)
    init_db(conn)
    skip = set() if force else fresh_tickers(conn, now)
    todo = [(t, y) for t, y in symbols if t not in skip]
    stats = {"total": len(symbols), "skipped": len(symbols) - len(todo), "ok": 0, "empty": 0, "failed": 0, "rows": 0}
    log(f"[long] символов {stats['total']}, к загрузке {len(todo)}, пропущено свежих {stats['skipped']}")
    started = time.time()
    stamp = now.strftime("%Y-%m-%dT%H:%M:%S")
    done = 0
    for chunk in chunked(todo, CHUNK_SIZE):
        data = None
        for attempt in range(RETRIES):
            try:
                data = downloader([y for _, y in chunk])
                break
            except Exception as e:
                log(f"[long] чанк {chunk[0][0]}..{chunk[-1][0]}: ошибка {e} (попытка {attempt + 1})")
                sleep(2 * (attempt + 1))
        if data is None:
            stats["failed"] += len(chunk)
            continue
        for ticker, ysym in chunk:
            series = extract_closes(data, ysym, single=len(chunk) == 1)
            rows = series_rows(ticker, series, now.date()) if not series.empty else []
            if rows:
                conn.execute("DELETE FROM weekly_closes WHERE ticker = ?", (ticker,))
                conn.executemany("INSERT OR REPLACE INTO weekly_closes (ticker, date, close) VALUES (?, ?, ?)", rows)
                stats["ok"] += 1
                stats["rows"] += len(rows)
            else:
                stats["empty"] += 1
            conn.execute("INSERT OR REPLACE INTO long_meta (ticker, refreshed_at, rows) VALUES (?, ?, ?)",
                         (ticker, stamp, len(rows)))
        conn.commit()
        done += len(chunk)
        log(f"[long] {done}/{len(todo)} (ok {stats['ok']}, пусто {stats['empty']}, ошибок {stats['failed']}), "
            f"{time.time() - started:.0f} с")
        sleep(CHUNK_PAUSE)
    conn.close()
    log(f"[long] готово: {stats}")
    return stats


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--db", default=DB_PATH)
    p.add_argument("--force", action="store_true", help="качать заново, даже если тикер свежий")
    args = p.parse_args(argv)
    refresh(args.db, force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
