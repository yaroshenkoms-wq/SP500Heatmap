"""
Фундаментальные данные и новости (Yahoo через yfinance) -> fundamentals.db (SQLite, не в git).

Таблицы:
  fundamentals(symbol PK, name, pe, forward_pe, div_yield, dividend_rate, ex_dividend_date,
               earnings_date, beta, ps, pb, rev_growth, avg_volume, currency, updated_at)   -- наш тикер (BRK.B), не Yahoo (BRK-B)
  company_cache(symbol PK, payload TEXT(json), updated_at)  -- готовый ответ /api/v1/company, кэш >= 6 ч

Память: в RAM ничего не держим — всё в SQLite, по одному символу за раз.
Yahoo ограничивает частоту: не чаще ~1 запроса в секунду (THROTTLE_SECONDS), повторы с паузой.

Запуск: python3 fetch_fundamentals.py [--db fundamentals.db] [--limit 30] [SYMBOL ...]
"""
import argparse
import json
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = str(BASE_DIR / "fundamentals.db")
THROTTLE_SECONDS = 1.2
STALE_SECONDS = 7 * 86400
COMPANY_CACHE_SECONDS = 6 * 3600
NEWS_LIMIT = 8

_US_CLASS_SHARE = re.compile(r"^[A-Z]{1,5}\.[A-Z]$")


def yahoo_symbol(symbol):
    """Наш тикер -> тикер Yahoo. Американские классы акций у нас с точкой (BRK.B), у Yahoo с тире (BRK-B).
    Лондонские (.L) и прочие биржевые суффиксы не трогаем."""
    if _US_CLASS_SHARE.match(symbol) and not symbol.endswith(".L"):
        return symbol.replace(".", "-")
    return symbol


def init_db(conn):
    # WAL: чтение из сервера не ждёт, пока ночной проход пишет (24.11.2026: «database is locked» → 500 у /metrics)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass  # база занята — режим переключится при следующем открытии
    conn.execute("""CREATE TABLE IF NOT EXISTS fundamentals (
        symbol TEXT PRIMARY KEY, name TEXT, pe REAL, forward_pe REAL, div_yield REAL, dividend_rate REAL,
        ex_dividend_date TEXT, earnings_date TEXT, beta REAL, currency TEXT, updated_at REAL NOT NULL,
        ps REAL, pb REAL, rev_growth REAL, avg_volume REAL, dividend_date TEXT)""")
    have = {r[1] for r in conn.execute("PRAGMA table_info(fundamentals)")}
    for col, typ in (("ps", "REAL"), ("pb", "REAL"), ("rev_growth", "REAL"), ("avg_volume", "REAL"),
                     ("dividend_date", "TEXT")):  # база с прежней схемой (на сервере) — докидываем колонки
        if col not in have:
            conn.execute(f"ALTER TABLE fundamentals ADD COLUMN {col} {typ}")
    conn.execute("""CREATE TABLE IF NOT EXISTS company_cache (
        symbol TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL)""")
    conn.commit()


def _num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f == f and abs(f) != float("inf") else None


def _positive(v):
    n = _num(v)
    return n if n is not None and n > 0 else None


def _pct(v):
    n = _num(v)
    return n * 100 if n is not None else None


def _date(ts):
    n = _num(ts)
    if n is None or n <= 0:
        return None
    return datetime.fromtimestamp(n, timezone.utc).strftime("%Y-%m-%d")


def parse_info(info, now=None):
    """Словарь Yahoo info -> наши поля. Дивидендная доходность — в процентах (2.1 = 2.1%).
    Берём dividendYield Yahoo (уже в процентах), без него — годовой дивиденд / цена."""
    now = now or time.time()
    info = info or {}
    price = _num(info.get("currentPrice")) or _num(info.get("regularMarketPrice")) or _num(info.get("previousClose"))
    rate = _num(info.get("dividendRate")) or _num(info.get("trailingAnnualDividendRate"))
    yld = _num(info.get("dividendYield"))  # Yahoo (yfinance >= 0.2.54) уже отдаёт проценты: 0.31 = 0.31%
    if yld is None and rate and price and price > 0 and info.get("currency") not in ("GBp", "GBX", "ZAc", "ILA"):
        yld = rate / price * 100  # запасной путь (в пенсах цена и дивиденд в разных единицах — не считаем)
    elif yld is None:
        frac = _num(info.get("trailingAnnualDividendYield")) or _num(info.get("yield"))
        if frac is not None:
            yld = frac * 100
    if yld == 0:
        yld = None
    if yld is not None and not 0 <= yld < 100:
        yld = None
    earn = None
    for key in ("earningsTimestampStart", "earningsTimestamp"):
        n = _num(info.get(key))
        if n and n >= now - 86400:  # только будущая дата
            earn = _date(n)
            break
    pe = _num(info.get("trailingPE"))
    return {
        "name": info.get("shortName") or info.get("longName"),
        "pe": pe if pe is not None and pe > 0 else None,
        "forward_pe": _num(info.get("forwardPE")),
        "div_yield": yld,
        "dividend_rate": rate,
        "ex_dividend_date": _date(info.get("exDividendDate")),
        "dividend_date": _date(info.get("dividendDate")),  # дата выплаты
        "earnings_date": earn,
        "beta": _num(info.get("beta")),
        "ps": _positive(info.get("priceToSalesTrailing12Months")),
        "pb": _positive(info.get("priceToBook")),
        "rev_growth": _pct(info.get("revenueGrowth")),  # Yahoo: 0.12 = 12% -> отдаём 12.0
        "avg_volume": _positive(info.get("averageVolume")),
        "currency": info.get("currency") or info.get("financialCurrency"),
    }


def default_info_fetcher(ysym):
    import yfinance as yf
    return yf.Ticker(ysym).info


def default_news_fetcher(ysym):
    import yfinance as yf
    return yf.Ticker(ysym).news


def fetch_one(symbol, info_fetcher=None, retries=2, sleep=time.sleep):
    """Поля одного символа или None, если Yahoo не отдал (после повторов)."""
    info_fetcher = info_fetcher or default_info_fetcher
    for attempt in range(retries + 1):
        try:
            info = info_fetcher(yahoo_symbol(symbol))
            if info:
                return parse_info(info)
        except Exception:
            pass
        if attempt < retries:
            sleep(3 * (attempt + 1))
    return None


def save_one(conn, symbol, fields, now=None):
    conn.execute(
        "INSERT OR REPLACE INTO fundamentals (symbol, name, pe, forward_pe, div_yield, dividend_rate, "
        "ex_dividend_date, earnings_date, beta, currency, updated_at, ps, pb, rev_growth, avg_volume, dividend_date) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (symbol, fields["name"], fields["pe"], fields["forward_pe"], fields["div_yield"], fields["dividend_rate"],
         fields["ex_dividend_date"], fields["earnings_date"], fields["beta"], fields["currency"], now or time.time(),
         fields["ps"], fields["pb"], fields["rev_growth"], fields["avg_volume"], fields.get("dividend_date")))


def refresh_fundamentals(db_path, symbols, info_fetcher=None, throttle=THROTTLE_SECONDS, sleep=time.sleep,
                         max_seconds=None):
    """Скачивает фундаментал по списку наших тикеров, по одному, с паузой. Возвращает {"ok", "failed", "skipped"}.
    max_seconds — остановиться, когда прошло столько секунд (окно ночного прохода)."""
    conn = sqlite3.connect(db_path, timeout=30)
    init_db(conn)
    started = time.time()
    ok = failed = 0
    done = 0
    try:
        for symbol in symbols:
            if max_seconds is not None and time.time() - started > max_seconds:
                break
            fields = fetch_one(symbol, info_fetcher, sleep=sleep)
            if fields is None:
                failed += 1
            else:
                save_one(conn, symbol, fields)
                conn.commit()  # сразу: не держим запись открытой, пока ждём Yahoo
                ok += 1
            done += 1
            sleep(throttle)
        conn.commit()
    finally:
        conn.close()
    return {"ok": ok, "failed": failed, "skipped": len(symbols) - done}


def stale_symbols(db_path, symbols, max_age=STALE_SECONDS, now=None):
    """Символы без записи или старше max_age — в порядке исходного списка."""
    now = now or time.time()
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        init_db(conn)
        fresh = {s for (s,) in conn.execute("SELECT symbol FROM fundamentals WHERE updated_at > ?", (now - max_age,))}
    finally:
        conn.close()
    return [s for s in symbols if s not in fresh]


def read_fundamentals(db_path, symbols=None):
    """{symbol: row dict}. symbols=None — все. Для 5000 символов это пара МБ, держим только на время запроса."""
    if not Path(db_path).exists():
        return {}
    conn = sqlite3.connect(db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        init_db(conn)
        if symbols is None:
            rows = conn.execute("SELECT * FROM fundamentals").fetchall()
        else:
            rows = []
            symbols = list(symbols)
            for i in range(0, len(symbols), 500):
                part = symbols[i:i + 500]
                rows += conn.execute(
                    f"SELECT * FROM fundamentals WHERE symbol IN ({','.join('?' * len(part))})", part).fetchall()
        return {r["symbol"]: dict(r) for r in rows}
    finally:
        conn.close()


def _news_item(n):
    """Элемент Yahoo news (новый формат с content{} или старый) -> {"title","publisher","url","published"}."""
    c = n.get("content") if isinstance(n.get("content"), dict) else None
    if c:
        url = ((c.get("canonicalUrl") or {}).get("url") or (c.get("clickThroughUrl") or {}).get("url"))
        pub = c.get("pubDate") or c.get("displayTime")
        return {"title": c.get("title"), "publisher": (c.get("provider") or {}).get("displayName"),
                "url": url, "published": pub}
    ts = _num(n.get("providerPublishTime"))
    return {"title": n.get("title"), "publisher": n.get("publisher"), "url": n.get("link"),
            "published": datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else None}


def fetch_news(symbol, news_fetcher=None):
    """Заголовки новостей (до NEWS_LIMIT). Любой сбой Yahoo — пустой список."""
    news_fetcher = news_fetcher or default_news_fetcher
    try:
        items = [_news_item(n) for n in (news_fetcher(yahoo_symbol(symbol)) or []) if isinstance(n, dict)]
    except Exception:
        return []
    return [i for i in items if i["title"] and i["url"]][:NEWS_LIMIT]


def get_cached_company(db_path, symbol, max_age=COMPANY_CACHE_SECONDS, now=None):
    if not Path(db_path).exists():
        return None
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        init_db(conn)
        row = conn.execute("SELECT payload, updated_at FROM company_cache WHERE symbol = ?", (symbol,)).fetchone()
    finally:
        conn.close()
    if row and (now or time.time()) - row[1] <= max_age:
        return json.loads(row[0])
    return None


def put_cached_company(db_path, symbol, payload, now=None):
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        init_db(conn)
        conn.execute("INSERT OR REPLACE INTO company_cache (symbol, payload, updated_at) VALUES (?,?,?)",
                     (symbol, json.dumps(payload, ensure_ascii=False), now or time.time()))
        conn.commit()
    finally:
        conn.close()


def build_company(db_path, symbol, info_fetcher=None, news_fetcher=None):
    """Данные для /api/v1/company без цен 52 недель (их считает сервер из истории).
    Фундаментал старше 7 дней (или нет) — докачивается сейчас. Сбой Yahoo -> поля None, новости []."""
    stale = stale_symbols(db_path, [symbol])
    if stale and not symbol.endswith("-USD"):
        refresh_fundamentals(db_path, [symbol], info_fetcher, throttle=0)
    row = read_fundamentals(db_path, [symbol]).get(symbol) or {}
    return {
        "name": row.get("name"), "pe": row.get("pe"), "forwardPe": row.get("forward_pe"),
        "divYield": row.get("div_yield"), "dividendRate": row.get("dividend_rate"),
        "exDividendDate": row.get("ex_dividend_date"), "earningsDate": row.get("earnings_date"),
        "beta": row.get("beta"), "currency": row.get("currency"),
        "news": fetch_news(symbol, news_fetcher),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("symbols", nargs="*")
    ap.add_argument("--db", default=DB_PATH)
    ap.add_argument("--limit", type=int, default=0, help="только первые N символов")
    args = ap.parse_args(argv)
    symbols = args.symbols
    if not symbols:
        import fetch_world
        seen = []
        for e in fetch_world.load_registry():
            if e.get("region") == "assets" and e["id"] == "crypto50":
                continue
            seen += fetch_world.load_symbols(e)
        symbols = list(dict.fromkeys(seen))
    if args.limit:
        symbols = symbols[:args.limit]
    print(refresh_fundamentals(args.db, symbols))
    return 0


if __name__ == "__main__":
    sys.exit(main())
