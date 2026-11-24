"""Новости для /api/v1/news. Источники (короткий список):
  * Yahoo (через yfinance, как в /company): тикеры области + рыночные ^GSPC ^IXIC ^DJI;
  * lang=es дополнительно публичные RSS (только заголовок+ссылка): Expansión «Mercados», Cinco Días «Mercados financieros».
    (El Economista отдаёт 403 автоматическим клиентам — не используем.)
Кэш каждого источника в news_cache.db (SQLite, WAL) на 15 минут. Любой сбой источника = пустой список от него.
"""
import hashlib
import json
import os
import sqlite3
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

CACHE_SECONDS = 15 * 60
MARKET_SYMBOLS = ["^GSPC", "^IXIC", "^DJI"]
RSS_FEEDS = {
    "es": [
        ("Expansión", "https://e00-expansion.uecdn.es/rss/mercados.xml"),
        ("Cinco Días", "https://feeds.elpais.com/mrss-s/pages/ep/site/cincodias.elpais.com/section/mercados-financieros/portada"),
    ],
}
SCOPE_TICKERS = 6  # у скольких крупнейших компаний области просим новости


def _conn(path):
    conn = sqlite3.connect(path, timeout=30)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass
    conn.execute("CREATE TABLE IF NOT EXISTS news_cache (key TEXT PRIMARY KEY, fetched_at REAL, payload TEXT)")
    return conn


def cache_get(path, key, now=None, ttl=CACHE_SECONDS):
    conn = _conn(path)
    try:
        row = conn.execute("SELECT fetched_at, payload FROM news_cache WHERE key=?", (key,)).fetchone()
    finally:
        conn.close()
    if row and (now or time.time()) - row[0] <= ttl:
        return json.loads(row[1])
    return None


def cache_put(path, key, items, now=None):
    conn = _conn(path)
    try:
        with conn:
            conn.execute("INSERT OR REPLACE INTO news_cache VALUES (?,?,?)", (key, now or time.time(), json.dumps(items)))
    finally:
        conn.close()


def item_id(url):
    return hashlib.sha1(url.encode("utf-8")).hexdigest()[:12]


def make_item(title, publisher, url, published, tickers, lang):
    return {"id": item_id(url), "title": title, "publisher": publisher, "url": url,
            "published": published, "tickers": tickers, "lang": lang}


def parse_rss(xml_bytes, publisher, lang, limit=25):
    """RSS 2.0 -> элементы новостей (только title, link, pubDate)."""
    out = []
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return out
    for it in root.iter("item"):
        title = (it.findtext("title") or "").strip()
        link = (it.findtext("link") or "").strip()
        pub = (it.findtext("pubDate") or "").strip()
        if not title or not link:
            continue
        try:
            published = parsedate_to_datetime(pub).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            published = None
        out.append(make_item(title, publisher, link, published, [], lang))
        if len(out) >= limit:
            break
    return out


def default_rss_fetcher(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


def symbol_news(path, symbol, news_fetcher=None, now=None):
    """Новости одного символа Yahoo (кэш 15 мин). Тикеры в элементе: [symbol] (для рыночных ^… — [])."""
    key = f"y:{symbol}"
    cached = cache_get(path, key, now)
    if cached is not None:
        return cached
    import fetch_fundamentals
    items = fetch_fundamentals.fetch_news(symbol, news_fetcher)
    tick = [] if symbol.startswith("^") else [symbol]
    out = [make_item(i["title"], i.get("publisher"), i["url"], i.get("published"), tick, "en") for i in items]
    if out:  # пустой ответ (сбой Yahoo) не кэшируем
        cache_put(path, key, out, now)
    return out


def rss_news(path, lang, rss_fetcher=None, now=None):
    out = []
    fetch = rss_fetcher or default_rss_fetcher
    for publisher, url in RSS_FEEDS.get(lang, []):
        key = f"r:{url}"
        cached = cache_get(path, key, now)
        if cached is None:
            try:
                cached = parse_rss(fetch(url), publisher, lang)
            except Exception:
                cached = []
            if cached:
                cache_put(path, key, cached, now)
        out.extend(cached)
    return out


def merge(groups, limit):
    """Объединяет списки: дедуп по url (тикеры сливаются), сортировка по дате по убыванию."""
    by_url = {}
    for items in groups:
        for it in items:
            cur = by_url.get(it["url"])
            if cur is None:
                by_url[it["url"]] = dict(it, tickers=list(it["tickers"]))
            else:
                for t in it["tickers"]:
                    if t not in cur["tickers"]:
                        cur["tickers"].append(t)
    merged = sorted(by_url.values(), key=lambda i: i["published"] or "", reverse=True)
    return merged[:limit]


def build_news(path, scope, symbols, lang="en", limit=50, news_fetcher=None, rss_fetcher=None, now=None):
    """symbols — тикеры области (уже выбранные сервером). scope=market -> только рыночные символы + RSS."""
    from concurrent.futures import ThreadPoolExecutor
    syms = list(MARKET_SYMBOLS) if scope == "market" else (list(symbols) + MARKET_SYMBOLS[:1] if scope == "index" else list(symbols))
    with ThreadPoolExecutor(max_workers=2) as pool:
        groups = list(pool.map(lambda s: symbol_news(path, s, news_fetcher, now), syms))
    if lang in RSS_FEEDS and scope in ("market", "index"):
        groups.insert(0, rss_news(path, lang, rss_fetcher, now))
    return merge(groups, max(1, min(limit, 200)))
