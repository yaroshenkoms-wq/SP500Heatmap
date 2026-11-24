"""
Объёмы торгов за последние ~30 сессий по тикерам -> volumes.db (SQLite, не в git).
Таблица daily_volumes(ticker, date, volume). Заполняется теми же дневными проходами, что и цены
(fetch_history.py, fetch_world.py, fetch_assets.py): в память ничего не грузим, сервер читает по запросу.
"""
import os
import sqlite3
from pathlib import Path

import pandas as pd

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = str(BASE_DIR / "volumes.db")
KEEP_SESSIONS = 30


def path_next_to(db_path):
    """volumes.db лежит рядом с базой цен, которую обновляет проход."""
    return os.path.join(os.path.dirname(os.path.abspath(db_path)), "volumes.db")


def init_db(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS daily_volumes (
        ticker TEXT NOT NULL, date TEXT NOT NULL, volume REAL NOT NULL, PRIMARY KEY (ticker, date))""")
    conn.commit()


def upsert(conn, rows):
    """rows: [(ticker, 'YYYY-MM-DD', volume)]. Нулевые и нечисловые объёмы пропускаем."""
    clean = []
    for t, d, v in rows:
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        if v == v and v > 0:
            clean.append((t, d, v))
    conn.executemany("INSERT OR REPLACE INTO daily_volumes (ticker, date, volume) VALUES (?,?,?)", clean)
    return len(clean)


def trim(conn, keep=KEEP_SESSIONS):
    """Оставляет у каждого тикера последние keep дат. Возвращает число стёртых строк."""
    cur = conn.execute(
        """DELETE FROM daily_volumes WHERE rowid IN (
             SELECT rowid FROM (SELECT rowid, ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY date DESC) AS n
                                FROM daily_volumes) WHERE n > ?)""", (keep,))
    return cur.rowcount


def extract_volumes(data, symbol, single):
    """Серия объёмов одного символа из результата yf.download (пустая, если нет)."""
    try:
        frame = data if single else data[symbol]
        series = frame["Volume"]
        if isinstance(series, pd.DataFrame):
            series = series.iloc[:, 0]
        return series.dropna()
    except (KeyError, TypeError, AttributeError):
        return pd.Series(dtype=float)


def save_series(db_path, series_by_symbol, skip_dates=None, keep=KEEP_SESSIONS):
    """Пишет {symbol: Series объёмов} в volumes.db и обрезает до keep сессий.
    skip_dates: {symbol: set(дат)} — незаконченные сессии, их не пишем (и стираем, если уже лежат)."""
    skip_dates = skip_dates or {}
    conn = sqlite3.connect(db_path)
    try:
        init_db(conn)
        n = 0
        for sym, series in series_by_symbol.items():
            skips = skip_dates.get(sym) or set()
            for d in skips:
                conn.execute("DELETE FROM daily_volumes WHERE ticker = ? AND date = ?", (sym, d))
            rows = [(sym, ts.strftime("%Y-%m-%d"), v) for ts, v in series.items()
                    if ts.strftime("%Y-%m-%d") not in skips]
            n += upsert(conn, rows[-keep:])
        trim(conn, keep)
        conn.commit()
        return n
    finally:
        conn.close()


def read_stats(db_path, tickers):
    """{ticker: {"volume": последний, "date": дата, "mean": среднее по хранимым, "n": сколько сессий}}.
    Читаем пачками по 500 тикеров (до ~15 тыс. строк), в памяти не держим."""
    out = {}
    if not Path(db_path).exists():
        return out
    conn = sqlite3.connect(db_path)
    try:
        init_db(conn)
        tickers = list(tickers)
        for i in range(0, len(tickers), 500):
            part = tickers[i:i + 500]
            acc = {}
            for t, d, v in conn.execute(
                    f"SELECT ticker, date, volume FROM daily_volumes WHERE ticker IN ({','.join('?' * len(part))}) "
                    "ORDER BY ticker, date", part):
                a = acc.setdefault(t, [None, None, 0.0, 0])
                a[0], a[1] = v, d
                a[2] += v
                a[3] += 1
            for t, (v, d, s, n) in acc.items():
                out[t] = {"volume": v, "date": d, "mean": s / n, "n": n}
    finally:
        conn.close()
    return out
