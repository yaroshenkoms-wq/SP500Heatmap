"""
Свечи (OHLCV) тикера для графика: /api/v1/ohlc/{ticker}. Yahoo по запросу, кэш в SQLite ohlc_cache.db.
1m-1y — дневные свечи, 3y-10y — недельные. TTL: 6 часов (дневные), 3 дня (недельные).
В памяти ничего не держим: один ответ — до ~520 свечей, ~40 КБ, живёт только на время запроса.
"""
import json
import sqlite3
import time
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = str(BASE_DIR / "ohlc_cache.db")

# range -> (period Yahoo, interval, TTL секунд)
RANGES = {
    "1m": ("1mo", "1d", 6 * 3600), "3m": ("3mo", "1d", 6 * 3600), "6m": ("6mo", "1d", 6 * 3600),
    "1y": ("1y", "1d", 6 * 3600), "3y": ("3y", "1wk", 3 * 86400), "5y": ("5y", "1wk", 3 * 86400),
    "10y": ("10y", "1wk", 3 * 86400),
}


def init_db(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS ohlc_cache (
        ticker TEXT NOT NULL, range TEXT NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL,
        PRIMARY KEY (ticker, range))""")
    conn.commit()


def get_cached(db_path, ticker, rng, now=None, allow_stale=False):
    """(payload dict, возраст в секундах) или None. Просроченное отдаём только при allow_stale."""
    if not Path(db_path).exists():
        return None
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        init_db(conn)
        row = conn.execute("SELECT payload, updated_at FROM ohlc_cache WHERE ticker = ? AND range = ?",
                           (ticker, rng)).fetchone()
    finally:
        conn.close()
    if not row:
        return None
    age = (now or time.time()) - row[1]
    if age <= RANGES[rng][2] or allow_stale:
        return json.loads(row[0])
    return None


def put_cached(db_path, ticker, rng, payload, now=None):
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        init_db(conn)
        conn.execute("INSERT OR REPLACE INTO ohlc_cache (ticker, range, payload, updated_at) VALUES (?,?,?,?)",
                     (ticker, rng, json.dumps(payload, separators=(",", ":")), now or time.time()))
        conn.commit()
    finally:
        conn.close()


def default_fetcher(ysym, period, interval):
    """(DataFrame Open/High/Low/Close/Volume, валюта или None)."""
    import yfinance as yf
    t = yf.Ticker(ysym)
    df = t.history(period=period, interval=interval, auto_adjust=True)
    currency = None
    try:
        currency = (t.history_metadata or {}).get("currency")
    except Exception:
        pass
    return df, currency


def _f(v, nd=4):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return round(x, nd) if x == x and abs(x) != float("inf") else None


def build_bars(df):
    """DataFrame Yahoo -> [{"t","o","h","l","c","v"}]; строки без цены закрытия пропускаем."""
    bars = []
    if df is None or getattr(df, "empty", True):
        return bars
    for ts, r in df.iterrows():
        c, o, h, l = _f(r.get("Close")), _f(r.get("Open")), _f(r.get("High")), _f(r.get("Low"))
        if c is None or c <= 0:
            continue
        o = o if o is not None else c
        h = max(x for x in (h, o, c) if x is not None)
        l = min(x for x in (l, o, c) if x is not None)
        v = _f(r.get("Volume"), 0)
        bars.append({"t": ts.strftime("%Y-%m-%d"), "o": o, "h": h, "l": l, "c": c, "v": int(v) if v else 0})
    return bars


def build_ohlc(ticker, rng, ysym, fallback_currency="USD", db_path=DB_PATH, fetcher=None, now=None):
    """Готовый ответ. Кэш свежий — из кэша. Yahoo упал: просроченный кэш, если есть, иначе исключение."""
    cached = get_cached(db_path, ticker, rng, now)
    if cached is not None:
        return cached
    period, interval, _ = RANGES[rng]
    try:
        df, currency = (fetcher or default_fetcher)(ysym, period, interval)
        bars = build_bars(df)
        if not bars:
            raise RuntimeError("Yahoo вернул пустой ответ")
    except Exception:
        stale = get_cached(db_path, ticker, rng, now, allow_stale=True)
        if stale is not None:
            return stale
        raise
    payload = {"ticker": ticker, "currency": currency or fallback_currency or "USD", "interval": interval, "bars": bars}
    put_cached(db_path, ticker, rng, payload, now)
    return payload
