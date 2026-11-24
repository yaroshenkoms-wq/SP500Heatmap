import asyncio
import json
import os
import random
import csv
import sqlite3
import urllib.error
import urllib.request
import websockets
from contextlib import asynccontextmanager
from datetime import date, datetime
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from fastapi import FastAPI, Query, WebSocket
from fastapi.middleware.cors import CORSMiddleware
import sys
import time
from datetime import timedelta
from typing import Optional
from fastapi import HTTPException

load_dotenv()

# Логи сразу, без буфера (иначе на Render их видно с задержкой)
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

MOCK_MODE = os.getenv("MOCK_MODE", "true").strip().lower() in ("1", "true", "yes")
FINNHUB_API_KEY = os.getenv("FINNHUB_API_KEY")
FINNHUB_WEBSOCKET_URL = os.getenv("FINNHUB_WEBSOCKET_URL", "wss://ws.finnhub.io")

# Откуда сервер сам подтягивает свежий history.db (его каждый день обновляет GitHub Action),
# чтобы данные не зависели от того, пересобрал ли Render сервис после пуша.
# Пустая строка отключает автообновление — тогда используется только файл из образа.
HISTORY_DB_URL = os.getenv(
    "HISTORY_DB_URL",
    "https://raw.githubusercontent.com/yaroshenkoms-wq/SP500Heatmap/main/history.db",
).strip()
HISTORY_REFRESH_SECONDS = int(os.getenv("HISTORY_REFRESH_SECONDS", "3600"))
DB_PATH = "history.db"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REGISTRY_PATH = os.path.join(BASE_DIR, "indices", "registry.json")
WORLD_DB_PATH = os.path.join(BASE_DIR, "history_world.db")
# Автообновление мировых данных внутри сервера (WORLD_REFRESH=0 выключает)
WORLD_REFRESH = os.getenv("WORLD_REFRESH", "0").strip().lower() not in ("0", "false", "no", "")
WORLD_REFRESH_CHECK_SECONDS = int(os.getenv("WORLD_REFRESH_CHECK_SECONDS", "300"))
WORLD_REFRESH_DELAY_MINUTES = int(os.getenv("WORLD_REFRESH_DELAY_MINUTES", "30"))
WORLD_DB_MAX_AGE_SECONDS = int(os.getenv("WORLD_DB_MAX_AGE_SECONDS", "86400"))

# Длинные периоды 3y/5y/10y: недельные закрытия в history_long.db (в память — только базовые цены)
LONG_DB_PATH = os.path.join(BASE_DIR, "history_long.db")
LONG_PERIODS = {"3y": 3, "5y": 5, "10y": 10}
_long_env = os.getenv("LONG_REFRESH")
# по умолчанию включено только вместе с WORLD_REFRESH=1 (как крипта); LONG_REFRESH=0 выключает
LONG_REFRESH = (WORLD_REFRESH if _long_env is None
                else _long_env.strip().lower() not in ("0", "false", "no", ""))
LONG_CHECK_SECONDS = int(os.getenv("LONG_CHECK_SECONDS", "3600"))

MARKET_TZ = ZoneInfo("America/New_York")

# Фундаментал и новости (SQLite, не в памяти) — см. fetch_fundamentals.py
FUNDAMENTALS_DB_PATH = os.path.join(BASE_DIR, "fundamentals.db")
VOLUMES_DB_PATH = os.path.join(BASE_DIR, "volumes.db")
OHLC_DB_PATH = os.path.join(BASE_DIR, "ohlc_cache.db")
FINANCIALS_DB_PATH = os.path.join(BASE_DIR, "financials_cache.db")
GURU_HOLDINGS_PATH = os.path.join(BASE_DIR, "data", "guru_holdings.json")
# Недельный проход по всем тикерам: только ночью (UTC), не чаще ~1 запроса/сек (FUNDAMENTALS_REFRESH=1 включает)
FUNDAMENTALS_REFRESH = os.getenv("FUNDAMENTALS_REFRESH", "0").strip().lower() not in ("0", "false", "no", "")
FUNDAMENTALS_NIGHT_HOURS_UTC = (1, 7)  # [с, до)
FUNDAMENTALS_CHECK_SECONDS = 600
# Крипта 24/7: состав и закрытия раз в ~6 часов (CRYPTO_REFRESH=0 выключает)
CRYPTO_REFRESH = os.getenv("CRYPTO_REFRESH", "1").strip().lower() not in ("0", "false", "no", "")
CRYPTO_REFRESH_SECONDS = int(os.getenv("CRYPTO_REFRESH_SECONDS", str(6 * 3600)))


def market_today() -> str:
    """Сегодняшняя дата по Нью-Йорку в формате YYYY-MM-DD (как в history.db)."""
    return datetime.now(MARKET_TZ).strftime("%Y-%m-%d")


def is_regular_market_hours() -> bool:
    """9:30-16:00 America/New_York, будни. Не учитывает биржевые праздники."""
    now = datetime.now(MARKET_TZ)
    if now.weekday() >= 5:  # 5=суббота, 6=воскресенье
        return False
    open_time = now.replace(hour=9, minute=30, second=0, microsecond=0)
    close_time = now.replace(hour=16, minute=0, second=0, microsecond=0)
    return open_time <= now <= close_time


app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

price_cache = {}
_overview_cache = {"version": 0, "key": None, "at": 0.0, "data": None}  # кэш /api/v1/world-overview
world_history_cache = {}  # то же для history_world.db (все остальные индексы)
long_bases = {}  # ticker -> {"3y": база, "5y": база, "10y": база}; None если истории короче периода
_long_db_mtime = {"value": None}
history_cache = {}  # ticker -> [{"date": "YYYY-MM-DD", "close": float}, ...] по возрастанию даты


def read_history(db_path):
    """Читает дневные цены закрытия из файла SQLite: ticker -> [{"date", "close"}, ...]"""
    result = {}
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        cur = conn.execute("SELECT ticker, date, close FROM daily_closes ORDER BY ticker, date")
        for ticker, date, close in cur.fetchall():
            result.setdefault(ticker, []).append({"date": date, "close": close})
    finally:
        conn.close()
    return result


def history_last_date(history) -> str:
    """Самая свежая дата закрытия среди всех тикеров ('' если истории нет)."""
    # курсы валют (EURUSD=X) лежат в той же таблице, но не влияют на «последнюю дату» акций
    return max((series[-1]["date"] for t, series in history.items() if series and not t.endswith("=X")), default="")


def load_history():
    """Загружает дневные цены закрытия из history.db (см. fetch_history.py).

    Вызывается при старте и после каждого автообновления файла — кэш заменяется целиком."""
    if not os.path.exists(DB_PATH):
        print("⚠️ history.db не найден — запустите fetch_history.py для загрузки истории цен")
        return

    global history_cache
    fresh = read_history(DB_PATH)
    # Подмена одним присваиванием: запрос, который в этот момент обходит старый словарь
    # в другом потоке, не падает с «dictionary changed size during iteration» (24.11.2026).
    history_cache = fresh
    _overview_cache["version"] += 1
    print(f"✅ Загружена история цен для {len(history_cache)} тикеров (по {history_last_date(history_cache)})")
    warm_world_overview()


def download_history_db(etag):
    """Скачивает history.db по HISTORY_DB_URL и подменяет локальный файл.

    Возвращает новый ETag, либо None, если файл на сервере не менялся (HTTP 304).
    Скачанный файл проверяется до подмены: он должен читаться и быть не старее текущего."""
    request = urllib.request.Request(HISTORY_DB_URL, headers={"If-None-Match": etag} if etag else {})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            new_etag = response.headers.get("ETag") or ""
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return None
        raise

    tmp_path = DB_PATH + ".download"
    with open(tmp_path, "wb") as f:
        f.write(data)
    try:
        downloaded_date = history_last_date(read_history(tmp_path))
        if not downloaded_date:
            raise ValueError("в скачанном history.db нет данных")
        if downloaded_date < history_last_date(history_cache):
            raise ValueError(f"скачанный history.db старее текущего ({downloaded_date})")
        os.replace(tmp_path, DB_PATH)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    return new_etag


async def history_refresher():
    """Фоновая задача: сразу после старта и далее раз в HISTORY_REFRESH_SECONDS проверяет,
    не появился ли новый history.db, и перечитывает историю и цены закрытия."""
    etag = ""
    while True:
        try:
            new_etag = await asyncio.to_thread(download_history_db, etag)
            if new_etag is not None:
                etag = new_etag
                load_history()
                seed_prices_from_history()
        except Exception as e:
            print(f"⚠️ Не удалось обновить history.db: {e}")
        await asyncio.sleep(HISTORY_REFRESH_SECONDS)


def compute_return(series, trading_days_back):
    """% изменение цены закрытия за N торговых дней назад -> сейчас"""
    if len(series) < 2:
        return None
    start_index = max(0, len(series) - 1 - trading_days_back)
    start_price = series[start_index]["close"]
    end_price = series[-1]["close"]
    if start_price <= 0:
        return None
    return (end_price - start_price) / start_price * 100


def compute_ytd_return(series):
    """% изменение цены закрытия с первого торгового дня текущего года"""
    if not series:
        return None
    current_year = series[-1]["date"][:4]
    start_of_year = next((p for p in series if p["date"][:4] == current_year), None)
    if not start_of_year or start_of_year["close"] <= 0:
        return None
    return (series[-1]["close"] - start_of_year["close"]) / start_of_year["close"] * 100


def live_previous_close(entry, today):
    """Закрытие предыдущей сессии для живой сделки, пришедшей в день today.

    Если последняя дата в истории раньше today, то база — последнее закрытие (anchor);
    если история уже содержит today — предпоследнее (previous_close)."""
    last_close_date = entry.get('last_close_date')
    if last_close_date and last_close_date < today:
        return entry['anchor']
    return entry['previous_close']


def seed_prices_from_history():
    """Инициализирует price_cache реальными ценами закрытия из history_cache.

    'anchor' — последняя реальная цена закрытия, вокруг которой WebSocket
    будет создавать небольшое живое дрожание цены (см. websocket_endpoint).
    'previous_close' — предыдущая реальная цена закрытия, от неё считается % изменения.

    Вызывается и при автообновлении истории: если по тикеру сегодня уже шли живые
    сделки, живая цена сохраняется, а % пересчитывается от нового закрытия.
    """
    today = market_today()
    count = 0
    for ticker, series in history_cache.items():
        if len(series) < 2:
            continue
        anchor = series[-1]["close"]
        previous_close = series[-2]["close"]
        if anchor <= 0 or previous_close <= 0:
            continue
        entry = {
            'price': anchor,
            'anchor': anchor,
            'previous_close': previous_close,
            'last_close_date': series[-1]["date"],
            'change_percent': (anchor - previous_close) / previous_close * 100,
            'timestamp': time.time()
        }
        old = price_cache.get(ticker)
        # Живую цену оставляем, только пока в истории ещё нет закрытия этого дня.
        # Как только закрытие пришло — показываем его: живая цена могла застрять
        # на последней сделке перед обрывом связи с Finnhub.
        if old and old.get('live_date') == today and entry['last_close_date'] < today:
            base = live_previous_close(entry, today)
            entry['price'] = old['price']
            entry['live_date'] = today
            entry['change_percent'] = (old['price'] - base) / base * 100
        price_cache[ticker] = entry
        count += 1
    if count > 0:
        print(f"✅ Инициализированы цены для {count} тикеров из реальной истории (history.db)")


def load_initial_prices():
    """Фоллбэк: догружает цены из CSV для тикеров, которых нет в реальной истории (history.db)"""
    csv_files = ['companies_latest.csv', 'companies.csv', 'SP500_with_market_cap.csv']
    
    for csv_path in csv_files:
        if not os.path.exists(csv_path):
            continue
            
        print(f"Пробуем загрузить: {csv_path}")
        try:
            with open(csv_path, 'r', encoding='utf-8-sig') as f:
                first_line = f.readline()
                f.seek(0)
                
                # Определяем разделитель
                delimiter = ';' if ';' in first_line else ','
                
                reader = csv.DictReader(f, delimiter=delimiter)
                count = 0
                
                for row in reader:
                    # Ищем колонку с тикером
                    ticker = None
                    for col in ['Symbol', 'Ticker', 'symbol']:
                        if col in row:
                            ticker = row[col].strip()
                            break
                    if not ticker:
                        continue
                    if ticker in price_cache:
                        continue  # уже есть реальная цена из history.db

                    # Ищем цену
                    price = None
                    for col in ['Price', 'price', 'Last', 'last']:
                        if col in row:
                            price_str = row[col].replace(',', '').strip()
                            if price_str and price_str != '':
                                try:
                                    price = float(price_str)
                                    break
                                except:
                                    pass
                    
                    if price is None or price <= 0:
                        continue
                    
                    # Ищем изменение
                    change = 0
                    for col in ['% Chg', '%Chg', 'change', 'Change']:
                        if col in row:
                            change_str = row[col].replace('%', '').strip()
                            if change_str and change_str != '':
                                try:
                                    change = float(change_str)
                                    break
                                except:
                                    pass
                    
                    price_cache[ticker] = {
                        'price': price,
                        'anchor': price,
                        'previous_close': price / (1 + change / 100) if change != -100 else price,
                        'change_percent': change,
                        'timestamp': time.time()
                    }
                    count += 1
                    if ticker in ['NVDA', 'AAPL', 'MSFT', 'GOOGL']:
                        print(f"Loaded {ticker}: price={price}, change={change}")
                
                if count > 0:
                    print(f"✅ Загружено {count} тикеров из {csv_path}")
                    return
                    
        except Exception as e:
            print(f"Ошибка загрузки {csv_path}: {e}")
            continue
    
    print("⚠️ Не удалось загрузить ни один CSV файл")

DELISTED_AFTER_DAYS = 7


def is_delisted(ticker) -> bool:
    """Тикер перестал торговаться (поглощение, выход из индекса): его последнее закрытие
    старше общего на DELISTED_AFTER_DAYS календарных дней. Такие компании не показываем,
    иначе на карте висит замёрзшая цена. Тикеры без истории не трогаем."""
    series = history_cache.get(ticker)
    if not series:
        return False
    latest = history_last_date(history_cache)
    if not latest:
        return False
    gap = datetime.strptime(latest, "%Y-%m-%d") - datetime.strptime(series[-1]["date"], "%Y-%m-%d")
    return gap.days > DELISTED_AFTER_DAYS


# ---------------------------------------------------------------- мировые индексы

DEFAULT_REGISTRY = [{
    "id": "sp500", "name": "S&P 500", "region": "americas", "country": "US",
    "exchange_tz": "America/New_York", "close": "16:00", "currency": "USD",
    "live": True, "constituents": "SP500_with_market_cap.csv", "history": "history.db",
}]

_registry_cache = {"mtime": None, "data": DEFAULT_REGISTRY}
_index_rows_cache = {}  # id -> (mtime, rows)
_world_db_mtime = {"value": None}


def get_registry():
    """Список индексов из indices/registry.json; нет файла (или он битый) — только sp500."""
    try:
        mtime = os.path.getmtime(REGISTRY_PATH)
    except OSError:
        return DEFAULT_REGISTRY
    if _registry_cache["mtime"] != mtime or _registry_cache.get("path") != REGISTRY_PATH:
        try:
            with open(REGISTRY_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, list) or not all(isinstance(e, dict) and e.get("id") for e in data):
                raise ValueError("неверный формат registry.json")
            if not any(e["id"] == "sp500" for e in data):
                data = DEFAULT_REGISTRY + data
        except Exception as e:
            print(f"⚠️ registry.json не прочитан: {e}")
            return DEFAULT_REGISTRY
        _registry_cache.update(mtime=mtime, data=data, path=REGISTRY_PATH)
    return _registry_cache["data"]


def find_index(index_id):
    for entry in get_registry():
        if entry["id"] == index_id:
            return entry
    return None


def _parse_cap(cap_str) -> float:
    cap_str = (cap_str or "").strip()
    try:
        if cap_str.endswith("T"):
            return float(cap_str[:-1]) * 1_000_000_000_000
        if cap_str.endswith("B"):
            return float(cap_str[:-1]) * 1_000_000_000
        return float(cap_str)
    except ValueError:
        return 0.0


def load_index_rows(entry):
    """Строки CSV индекса: [{"ticker","name","sector","subsector","cap"}]. Перечитывается при смене mtime файла."""
    path = os.path.join(BASE_DIR, entry.get("constituents", ""))
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return []
    cached = _index_rows_cache.get(entry["id"])
    if cached and cached[0] == (path, mtime):
        return cached[1]
    legacy = entry["id"] == "sp500"
    rows = []
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f, delimiter=",")
            reader.fieldnames = [n.replace("\xa0", " ") for n in reader.fieldnames or []]
            for row in reader:
                ticker = (row.get("Symbol") or "").strip()
                if not ticker:
                    continue
                if legacy:
                    sector, subsector = (row.get("GICS Sector") or "").strip(), (row.get("GICS Sub-Industry") or "").strip()
                    cap = _parse_cap(row.get("Market Cap"))
                    currency = "USD"
                else:
                    sector = (row.get("Sector") or "").strip() or "Other"
                    subsector = (row.get("Subsector") or "").strip() or "Other"
                    cap = _parse_cap(row.get("MarketCap"))
                    currency = (row.get("Currency") or "").strip().upper() or entry.get("currency", "USD")
                rows.append({"ticker": ticker, "name": (row.get("Security") or "").strip() or ticker,
                             "sector": sector, "subsector": subsector, "cap": cap, "currency": currency})
    except Exception as e:
        print(f"⚠️ CSV индекса {entry['id']} не прочитан: {e}")
        return []
    _index_rows_cache[entry["id"]] = ((path, mtime), rows)
    return rows


def lookup_series(ticker):
    return world_history_cache.get(ticker) or history_cache.get(ticker)


def index_series(entry):
    """Тикер -> ряд закрытий для индекса (только его тикеры)."""
    out = {}
    for row in load_index_rows(entry):
        series = lookup_series(row["ticker"])
        if series:
            out[row["ticker"]] = series
    return out


def index_history_through(entry) -> str:
    return max((s[-1]["date"] for s in index_series(entry).values()), default="")


def load_world_history():
    """Читает history_world.db в world_history_cache (кэш заменяется целиком)."""
    if not os.path.exists(WORLD_DB_PATH):
        return False
    global world_history_cache
    fresh = read_history(WORLD_DB_PATH)
    world_history_cache = fresh  # подмена целиком, см. load_history
    _world_db_mtime["value"] = os.path.getmtime(WORLD_DB_PATH)
    _overview_cache["version"] += 1
    print(f"✅ Загружена мировая история для {len(world_history_cache)} тикеров (по {history_last_date(world_history_cache)})")
    warm_world_overview()
    return True


def years_ago(today, years):
    """Дата на N лет раньше today (date); 29 февраля -> 28 февраля."""
    try:
        return today.replace(year=today.year - years)
    except ValueError:
        return today.replace(year=today.year - years, day=28)


def compute_long_bases(db_path=None, today=None):
    """ticker -> {"3y","5y","10y"} = недельное закрытие на дату «сегодня − N лет» или раньше.
    Нет базы (история короче N лет, с запасом 7 дней на недельный шаг) — None. В памяти только эти числа."""
    db_path = db_path or LONG_DB_PATH
    today = today or datetime.now(ZoneInfo("UTC")).date()
    if not os.path.exists(db_path):
        return {}
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        first = dict(conn.execute("SELECT ticker, MIN(date) FROM weekly_closes GROUP BY ticker"))
        bases = {t: {} for t in first}
        for key, years in LONG_PERIODS.items():
            target = years_ago(today, years)
            limit = (target + timedelta(days=7)).isoformat()
            cur = conn.execute("SELECT ticker, close, MAX(date) FROM weekly_closes WHERE date <= ? GROUP BY ticker",
                               (target.isoformat(),))
            got = {t: c for t, c, _ in cur}
            for t in first:
                bases[t][key] = got.get(t) if first[t] <= limit else None
        return bases
    except sqlite3.Error as e:
        print(f"⚠️ history_long.db не прочитан: {e}")
        return {}
    finally:
        conn.close()


def load_long_history():
    """Пересчитывает маленький словарь баз длинных периодов (подмена целиком)."""
    global long_bases
    if not os.path.exists(LONG_DB_PATH):
        return False
    fresh = compute_long_bases()
    long_bases = fresh
    _long_db_mtime["value"] = os.path.getmtime(LONG_DB_PATH)
    _overview_cache["version"] += 1
    print(f"✅ Длинные периоды: базы для {len(long_bases)} тикеров")
    warm_world_overview()
    return True


def long_returns(ticker, series):
    """{"3y","5y","10y"}: % от недельной базы до последнего дневного закрытия (нет дневных — последнее недельное нельзя,
    поэтому None); None, если базы нет."""
    bases = long_bases.get(ticker)
    last = series[-1]["close"] if series else None
    out = {}
    for key in LONG_PERIODS:
        base = bases.get(key) if bases else None
        out[key] = ((last - base) / base * 100) if (base and base > 0 and last is not None) else None
    return out


def world_db_changed() -> bool:
    try:
        return os.path.getmtime(WORLD_DB_PATH) != _world_db_mtime["value"]
    except OSError:
        return False


def build_world_hierarchy(entry):
    """Иерархия сектор -> подсектор -> компании из CSV индекса (Sector/Subsector)."""
    rows = load_index_rows(entry)
    latest = history_last_date(world_history_cache)
    sectors = {}
    for row in rows:
        series = lookup_series(row["ticker"])
        if latest:
            # нет закрытий за последние DELISTED_AFTER_DAYS дней — не показываем
            if not series:
                continue
            gap = datetime.strptime(latest, "%Y-%m-%d") - datetime.strptime(series[-1]["date"], "%Y-%m-%d")
            if gap.days > DELISTED_AFTER_DAYS:
                continue
        sectors.setdefault(row["sector"], {}).setdefault(row["subsector"], []).append(
            {"ticker": row["ticker"], "name": row["name"], "marketCap": row["cap"]})
    result = []
    for sector_name, subsectors in sectors.items():
        subs = []
        for sub_name, companies in subsectors.items():
            companies.sort(key=lambda c: c["marketCap"], reverse=True)
            subs.append({"id": f"{sector_name}_{sub_name}", "name": sub_name, "companies": companies})
        result.append({"id": sector_name, "name": sector_name, "subsectors": subs})
    return result


# Рынок 24/7 (крипта): в году ~365 дневных свечей, поэтому периоды — календарные дни
CONTINUOUS_PERIOD_DAYS = {"1d": 1, "3d": 3, "7d": 7, "30d": 30, "180d": 180, "1y": 365}


def performance_entry(series, continuous=False, ticker=None):
    days_of = CONTINUOUS_PERIOD_DAYS if continuous else {"30d": 21, "180d": 126, "1y": 252}
    return_1m = compute_return(series, days_of["30d"])
    return_6m = compute_return(series, days_of["180d"])
    return_1y = compute_return(series, days_of["1y"])
    entry = {
        "return1M": return_1m,
        "return6M": return_6m,
        "returnYTD": compute_ytd_return(series),
        "return1Y": return_1y,
        "30d": return_1m,
        "180d": return_6m,
        "1y": return_1y,
    }
    for period, days in EXTRA_PERIOD_TRADING_DAYS.items():
        entry[period] = compute_return(series, CONTINUOUS_PERIOD_DAYS[period] if continuous else days)
    entry.update(long_returns(ticker, series))
    return entry


def indices_due(registry, now, last_refreshed, delay_minutes=30):
    """Какие индексы пора обновить: биржа закрылась ≥ delay_minutes назад (будний день по её
    часовому поясу), и сессия этого дня ещё не обновлялась. Только индексы с history_world.db.
    last_refreshed: id -> 'YYYY-MM-DD' (дата сессии, которую уже обновили). now — aware datetime."""
    due = []
    for entry in registry:
        if entry.get("history") != "history_world.db" or entry.get("continuous"):
            continue  # круглосуточные (крипта) обновляет crypto_refresher
        try:
            local = now.astimezone(ZoneInfo(entry["exchange_tz"]))
            hh, mm = entry["close"].split(":")
        except Exception:
            continue
        if local.weekday() >= 5:
            continue
        ready_at = local.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0) + timedelta(minutes=delay_minutes)
        if local < ready_at:
            continue
        if last_refreshed.get(entry["id"]) == local.strftime("%Y-%m-%d"):
            continue
        due.append(entry["id"])
    return due


def session_dates(registry, now, delay_minutes=30):
    """id -> дата сессии, закрытие которой (+ delay) уже прошло к моменту now."""
    out = {}
    for iid in indices_due(registry, now, {}, delay_minutes):
        entry = next(e for e in registry if e["id"] == iid)
        out[iid] = now.astimezone(ZoneInfo(entry["exchange_tz"])).strftime("%Y-%m-%d")
    return out


def run_world_refresh(index_ids):
    """Синхронно (в потоке) запускает fetch_world.refresh. ImportError — мягко."""
    try:
        import fetch_world
    except ImportError:
        print("⚠️ fetch_world.py не найден — автообновление мировых данных пропущено")
        return None
    return fetch_world.refresh(WORLD_DB_PATH, index_ids=index_ids)


US_SESSION_INDICES = {"nasdaq100", "dow30", "sp400", "sp600"}


def run_sp500_refresh() -> bool:
    """Запускает fetch_history.py (обновляет history.db S&P 500) отдельным процессом в папке сервера.

    Скрипт сам не пишет незакрытую сессию. Скачанный позже с GitHub history.db той же даты
    заменит локальный (download_history_db отвергает только более старый файл)."""
    import subprocess
    try:
        done = subprocess.run([sys.executable, "fetch_history.py"], cwd=BASE_DIR,
                              capture_output=True, text=True, timeout=1800)
    except Exception as e:
        print(f"⚠️ Обновление S&P 500 не удалось: {e}")
        return False
    tail = (done.stdout or "").strip().splitlines()[-1:] or [""]
    print(f"📈 Обновление S&P 500: код {done.returncode}; {tail[0]}")
    return done.returncode == 0


async def world_refresher():
    """Фоновая задача: после закрытия бирж обновляет history_world.db; при старте — если файла нет
    или он старше суток. Не блокирует цикл событий (refresh идёт в потоке)."""
    last_refreshed = {}
    registry = get_registry()
    startup_ids = [e["id"] for e in registry if e.get("history") == "history_world.db"]
    stale = (not os.path.exists(WORLD_DB_PATH)
             or time.time() - os.path.getmtime(WORLD_DB_PATH) > WORLD_DB_MAX_AGE_SECONDS)
    if startup_ids and stale:
        try:
            print("🌍 Стартовое обновление мировых данных")
            await asyncio.to_thread(run_world_refresh, None)
            await asyncio.to_thread(load_world_history)
        except Exception as e:
            print(f"⚠️ Стартовое обновление мировых данных не удалось: {e}")
    elif startup_ids:
        # новые индексы (например, etf50 после выкладки) без единой цены в базе — догружаем сразу, не ждём закрытия
        empty = [e["id"] for e in registry if e.get("history") == "history_world.db" and not e.get("continuous")
                 and not any(r["ticker"] in world_history_cache for r in load_index_rows(e))]
        if empty:
            try:
                print(f"🌍 Нет данных для новых индексов: {', '.join(empty)}")
                await asyncio.to_thread(run_world_refresh, empty)
                await asyncio.to_thread(load_world_history)
            except Exception as e:
                print(f"⚠️ Догрузка новых индексов не удалась: {e}")
    if os.path.exists(WORLD_DB_PATH):
        # то, что файл уже покрывает, повторно не качаем
        mtime = datetime.fromtimestamp(os.path.getmtime(WORLD_DB_PATH), ZoneInfo("UTC"))
        last_refreshed.update(session_dates(registry, mtime, WORLD_REFRESH_DELAY_MINUTES))
    while True:
        try:
            registry = get_registry()
            due = indices_due(registry, datetime.now(ZoneInfo("UTC")), last_refreshed, WORLD_REFRESH_DELAY_MINUTES)
            if due:
                dates = session_dates(registry, datetime.now(ZoneInfo("UTC")), WORLD_REFRESH_DELAY_MINUTES)
                print(f"🌍 Обновляем мировые данные: {', '.join(due)}")
                result = await asyncio.to_thread(run_world_refresh, due)
                if result is not None:
                    for iid in due:
                        last_refreshed[iid] = dates[iid]
                    await asyncio.to_thread(load_world_history)
                if any(iid in US_SESSION_INDICES for iid in due):
                    # S&P 500 тоже обновляем сами сразу после закрытия США: GitHub Action опаздывает
                    # на часы, и на главной карте S&P 500 стоял бы на день позади Nasdaq и Dow.
                    if await asyncio.to_thread(run_sp500_refresh):
                        load_history()
                        seed_prices_from_history()
                else:
                    for iid in due:  # без fetch_world не долбим каждые 5 минут
                        last_refreshed[iid] = dates[iid]
            elif world_db_changed():
                await asyncio.to_thread(load_world_history)
        except Exception as e:
            print(f"⚠️ Обновление мировых данных не удалось: {e}")
        await asyncio.sleep(WORLD_REFRESH_CHECK_SECONDS)


@app.get("/api/v1/indices")
async def get_indices():
    result = []
    for entry in get_registry():
        item = {
            "id": entry["id"],
            "name": entry.get("name", entry["id"]),
            "region": entry.get("region", ""),
            "country": entry.get("country", ""),
            "currency": entry.get("currency", ""),
            "live": bool(entry.get("live", False)),
            "count": len(load_index_rows(entry)),
            "historyThrough": index_history_through(entry) if entry["id"] != "sp500" else history_last_date(history_cache),
        }
        if entry.get("source"):
            item["source"] = entry["source"]
        result.append(item)
    return result


# ---------------------------------------------------------------- обзор мира (главный экран)

OVERVIEW_REGIONS = ["americas", "europe", "asia_pacific", "assets"]
OVERVIEW_PERIODS = {"1d": 1, "3d": 3, "7d": 5, "30d": 21, "180d": 126, "1y": 252}  # торговых дней назад
OVERVIEW_TTL_SECONDS = int(os.getenv("OVERVIEW_TTL_SECONDS", "300"))
FX_STARTUP_REFRESH = os.getenv("FX_STARTUP_REFRESH", "1").strip().lower() not in ("0", "false", "no", "")


def fx_symbol_for(currency) -> str:
    return f"{currency}USD=X"


def fx_rate(currency):
    """Сколько долларов за 1 единицу валюты (последнее закрытие курса); USD = 1; нет курса — None."""
    if currency == "USD":
        return 1.0
    series = world_history_cache.get(fx_symbol_for(currency))
    if not series:
        return None
    rate = series[-1]["close"]
    return rate if rate and rate > 0 else None


def needed_currencies():
    """Все валюты (кроме USD), которые встречаются в индексах реестра."""
    found = set()
    for entry in get_registry():
        if entry.get("currency"):
            found.add(entry["currency"])
        for row in load_index_rows(entry):
            found.add(row["currency"])
    found.discard("USD")
    return found


def missing_fx_currencies():
    return sorted(c for c in needed_currencies() if fx_rate(c) is None)


def _overview_row_shown(entry, row, latest) -> bool:
    """Компания показана на карте: есть история и она не «замёрзла» (как в build_world_hierarchy / is_delisted).
    latest — самая свежая дата нужного кэша, посчитанная один раз на индекс."""
    if entry["id"] == "sp500":
        series = history_cache.get(row["ticker"])
    else:
        series = lookup_series(row["ticker"])
    if not series:
        return False
    if latest:
        gap = datetime.strptime(latest, "%Y-%m-%d") - datetime.strptime(series[-1]["date"], "%Y-%m-%d")
        if gap.days > DELISTED_AFTER_DAYS:
            return False
    return True


def start_weight(cap, ret_percent):
    """Вес компании в изменении индекса — её капитализация на НАЧАЛО периода: сегодняшняя / (1 + рост).
    С весом по сегодняшней капитализации победители раздували итог (S&P 500 за 10 лет +1225 % вместо ~+230 %,
    24.11.2026). Так итог равен росту общей стоимости компаний, как у индекса."""
    growth = 1.0 + ret_percent / 100.0
    return cap / growth if growth > 0.01 else cap / 0.01


def build_index_overview(entry):
    """Сводка одного индекса. Компании без курса валюты исключаются и из капитализации, и из изменения;
    если не осталось ни одной — capUSD = None и changes = None (плитку клиент не рисует)."""
    total = 0.0
    shown = 0
    days_of = CONTINUOUS_PERIOD_DAYS if entry.get("continuous") else OVERVIEW_PERIODS
    all_periods = list(OVERVIEW_PERIODS) + list(LONG_PERIODS)
    weighted = {p: [0.0, 0.0, 0] for p in all_periods}  # period -> [сумма w*ret, сумма w, сколько компаний с данными]
    through = ""
    latest = history_last_date(history_cache if entry["id"] == "sp500" else world_history_cache)
    for row in load_index_rows(entry):
        if not _overview_row_shown(entry, row, latest):
            continue
        rate = fx_rate(row["currency"])
        if rate is None or row["cap"] <= 0:
            continue
        cap_usd = row["cap"] * rate
        series = history_cache.get(row["ticker"]) if entry["id"] == "sp500" else lookup_series(row["ticker"])
        total += cap_usd
        shown += 1
        if series and series[-1]["date"] > through:
            through = series[-1]["date"]
        for period in OVERVIEW_PERIODS:
            ret = compute_return(series, days_of[period])
            if ret is not None:
                w = start_weight(cap_usd, ret)
                weighted[period][0] += w * ret
                weighted[period][1] += w
                weighted[period][2] += 1
        for period, ret in long_returns(row["ticker"], series).items():
            if ret is not None:
                w = start_weight(cap_usd, ret)
                weighted[period][0] += w * ret
                weighted[period][1] += w
                weighted[period][2] += 1
    ok = shown > 0 and total > 0
    result = {
        "id": entry["id"], "name": entry.get("name", entry["id"]), "country": entry.get("country", ""),
        "currency": entry.get("currency", ""), "live": bool(entry.get("live", False)), "count": shown,
        "capUSD": total if ok else None, "historyThrough": through,
        # Период без истории у половины компаний не показываем: иначе итог по 2 монетам из 50
        # выдавался за всю крипту (+7926 % за 10 лет, 24.11.2026).
        "changes": {p: (w[0] / w[1] if w[1] > 0 and w[2] * 2 >= shown else None) for p, w in weighted.items()} if ok
                   else {p: None for p in all_periods},
    }
    if entry.get("source"):
        result["source"] = entry["source"]  # атрибуция данных (крипта: "Data: CoinGecko")
    return result


def build_world_overview():
    regions = {r: [] for r in OVERVIEW_REGIONS}
    for entry in get_registry():
        region = entry.get("region")
        if region in regions:
            regions[region].append(build_index_overview(entry))
    return {"asOf": market_today(), "regions": [{"id": r, "indices": regions[r]} for r in OVERVIEW_REGIONS]}


def warm_world_overview():
    """Считает карту мира сразу после перезагрузки истории (в том же фоновом потоке),
    чтобы первый запрос приложения не ждал несколько секунд."""
    try:
        get_world_overview_cached()
    except Exception as e:
        print(f"⚠️ Не удалось заранее посчитать карту мира: {e}")


def get_world_overview_cached():
    """Пересчёт при перезагрузке истории или раз в OVERVIEW_TTL_SECONDS; иначе отдаём готовый результат."""
    now = time.time()
    c = _overview_cache
    if c["data"] is None or c["key"] != c["version"] or now - c["at"] > OVERVIEW_TTL_SECONDS:
        c["data"] = build_world_overview()
        c["key"] = c["version"]
        c["at"] = now
    return c["data"]


def run_fx_refresh():
    try:
        import fetch_world
    except ImportError:
        print("⚠️ fetch_world.py не найден — курсы валют не скачаны")
        return None
    return fetch_world.refresh_fx(WORLD_DB_PATH)


async def fx_startup_refresher():
    """При старте: если не хватает курса какой-то валюты — быстро качаем только курсы и перечитываем кэш."""
    try:
        if not os.path.exists(WORLD_DB_PATH) or not missing_fx_currencies():
            return
        print(f"💱 Нет курсов валют: {', '.join(missing_fx_currencies())} — скачиваем")
        result = await asyncio.to_thread(run_fx_refresh)
        if result is not None:
            await asyncio.to_thread(load_world_history)
    except Exception as e:
        print(f"⚠️ Курсы валют не скачаны: {e}")


@app.get("/api/v1/world-overview")
async def get_world_overview():
    """Все индексы по регионам: размер плитки = капитализация в USD, цвет = изменение за период."""
    return get_world_overview_cached()


def resolve_index(index):
    if index is None or index == "sp500":
        return None
    entry = find_index(index)
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown index")
    return entry


@app.get("/health")
async def health():
    """Лёгкий эндпоинт для keep-alive пингов (UptimeRobot/cron-job.org), чтобы бесплатный
    инстанс на Render не засыпал — ничего не парсит и не трогает price_cache."""
    return {"status": "ok", "history_through": history_last_date(history_cache)}


@app.get("/api/v1/market-hierarchy")
async def get_market_hierarchy(index: Optional[str] = None):
    """Возвращает иерархию рынка с секторами, подсекторами и реальной капитализацией"""
    entry = resolve_index(index)
    if entry is not None:
        return build_world_hierarchy(entry)
    
    # Загружаем данные с секторами из SP500_with_market_cap.csv
    sectors_data = {}  # sector_name -> {subsector_name -> [tickers]}
    companies_info = {}  # ticker -> {name, sector, subsector, market_cap}
    
    csv_path = 'SP500_with_market_cap.csv'
    if os.path.exists(csv_path):
        try:
            with open(csv_path, 'r', encoding='utf-8-sig') as f:
                reader = csv.DictReader(f, delimiter=',')
                # Нормализуем неразрывные пробелы в заголовках — разные источники CSV
                # (ручной экспорт vs Wikipedia) используют разные виды пробелов в "GICS Sector"
                reader.fieldnames = [name.replace('\xa0', ' ') for name in reader.fieldnames]
                for row in reader:
                    ticker = row['Symbol'].strip()
                    if is_delisted(ticker):
                        continue
                    name = row['Security'].strip()
                    sector = row['GICS Sector'].strip()
                    subsector = row['GICS Sub-Industry'].strip()
                    
                    # Парсим капитализацию
                    cap_str = row.get('Market Cap', '').strip()
                    cap_value = 0
                    if cap_str.endswith('T'):
                        cap_value = float(cap_str[:-1]) * 1_000_000_000_000
                    elif cap_str.endswith('B'):
                        cap_value = float(cap_str[:-1]) * 1_000_000_000
                    else:
                        try:
                            cap_value = float(cap_str)
                        except:
                            pass
                    
                    companies_info[ticker] = {
                        'name': name,
                        'sector': sector,
                        'subsector': subsector,
                        'market_cap': cap_value
                    }
                    
                    # Строим иерархию
                    if sector not in sectors_data:
                        sectors_data[sector] = {}
                    if subsector not in sectors_data[sector]:
                        sectors_data[sector][subsector] = []
                    sectors_data[sector][subsector].append(ticker)
            
            print(f"✅ Загружена структура секторов для {len(companies_info)} компаний")
        except Exception as e:
            print(f"Ошибка загрузки структуры: {e}")
    
    # Формируем результат
    result = []
    for sector_name, subsectors in sectors_data.items():
        sector_entry = {
            "id": sector_name,
            "name": sector_name,
            "subsectors": []
        }
        
        for subsector_name, tickers in subsectors.items():
            companies_list = []
            for ticker in tickers:
                info = companies_info.get(ticker, {})
                # Берем цену из price_cache
                price_data = price_cache.get(ticker, {})
                price = price_data.get('price', 0)
                
                companies_list.append({
                    "ticker": ticker,
                    "name": info.get('name', ticker),
                    "marketCap": info.get('market_cap', price * 1_000_000)
                })
            
            # Сортируем компании внутри подсектора по капитализации
            companies_list.sort(key=lambda x: x['marketCap'], reverse=True)
            
            sector_entry["subsectors"].append({
                "id": f"{sector_name}_{subsector_name}",
                "name": subsector_name,
                "companies": companies_list
            })
        
        result.append(sector_entry)
    
    # Если не загрузились сектора — fallback
    if not result:
        companies_list = []
        for ticker, data in price_cache.items():
            companies_list.append({
                "ticker": ticker,
                "name": ticker,
                "marketCap": data.get('price', 0) * 1_000_000
            })
        companies_list.sort(key=lambda x: x['marketCap'], reverse=True)
        result = [{
            "id": "1",
            "name": "All S&P 500",
            "subsectors": [{
                "id": "1-1",
                "name": "All Companies",
                "companies": companies_list
            }]
        }]
    
    return result

@app.get("/api/v1/history/{ticker}")
async def get_history(ticker: str, range: Optional[str] = None):
    """Дневные цены закрытия за последний год для тикера (history.db и history_world.db).
    ?range=3y|5y|10y — недельный ряд из history_long.db (читается по запросу); нет базы — []."""
    t = ticker.upper()
    daily = history_cache.get(t) or world_history_cache.get(t) or []
    if range is None:
        return daily
    years = LONG_PERIODS.get(range)
    if years is None:
        raise HTTPException(status_code=400, detail="range must be 3y, 5y or 10y")
    return read_long_series(t, years, daily)


def read_long_series(ticker, years, daily=None, db_path=None):
    """Недельные точки от базы (закрытие на дату «сегодня − N лет» или раньше) до конца; в конец добавляем
    последнее дневное закрытие, если оно новее последней недельной точки."""
    db_path = db_path or LONG_DB_PATH
    if not os.path.exists(db_path):
        return []
    target = years_ago(datetime.now(ZoneInfo("UTC")).date(), years).isoformat()
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        # тикер в базе — как в CSV (BRK.B); запрос мог прийти и в варианте с дефисом
        names = [ticker, ticker.replace("-", ".")] if "-" in ticker and not ticker.endswith("-USD") else [ticker]
        rows = []
        for name in names:
            rows = conn.execute("SELECT date, close FROM weekly_closes WHERE ticker = ? AND date >= "
                                "COALESCE((SELECT MAX(date) FROM weekly_closes WHERE ticker = ? AND date <= ?), '') "
                                "ORDER BY date", (name, name, target)).fetchall()
            if rows:
                break
    except sqlite3.Error:
        return []
    finally:
        conn.close()
    out = [{"date": d, "close": c} for d, c in rows]
    if out and daily and daily[-1]["date"] > out[-1]["date"]:
        out.append({"date": daily[-1]["date"], "close": daily[-1]["close"]})
    return out


# Дополнительные периоды для переключателя SC/1d/3d/7d/30d/180d/1y на heatmap-экранах.
# 30d/180d/1y уже покрыты return1M/return6M/return1Y (тот же trading-days-back).
EXTRA_PERIOD_TRADING_DAYS = {"1d": 1, "3d": 3, "7d": 5}


@app.get("/api/v1/performance")
async def get_performance(index: Optional[str] = None):
    """Доходность по всем тикерам, посчитанная из реальных цен закрытия.

    return1M/return6M/returnYTD/return1Y — для экрана "All Stocks".
    1d/3d/7d/30d/180d/1y — для переключателя периода на heatmap-экранах
    (30d/180d/1y дублируют return1M/return6M/return1Y под ключами, которые
    совпадают с кнопками в UI)."""
    entry_ = resolve_index(index)
    if entry_ is not None:
        continuous = bool(entry_.get("continuous"))
        return {t: performance_entry(s, continuous, t) for t, s in index_series(entry_).items()}
    result = {}
    for ticker, series in history_cache.items():
        return1M = compute_return(series, 21)
        return6M = compute_return(series, 126)
        return1Y = compute_return(series, 252)
        entry = {
            "return1M": return1M,
            "return6M": return6M,
            "returnYTD": compute_ytd_return(series),
            "return1Y": return1Y,
            "30d": return1M,
            "180d": return6M,
            "1y": return1Y,
        }
        for period, days in EXTRA_PERIOD_TRADING_DAYS.items():
            entry[period] = compute_return(series, days)
        entry.update(long_returns(ticker, series))
        result[ticker] = entry
    return result


# ---------------------------------------------------------------- метрики и карточка компании

_metrics_cache = {}  # id индекса -> (версия истории, время, dict) — сбрасывается при перезагрузке истории
METRICS_TTL_SECONDS = int(os.getenv("METRICS_TTL_SECONDS", "3600"))


def compute_52w(series):
    """(pos52w, high52w, low52w) по последним ~год закрытиям ряда (в кэше и так 1 год).
    pos52w в 0..1: где последнее закрытие между минимумом и максимумом; плоский ряд/нет данных — None."""
    closes = [p["close"] for p in series[-366:] if p["close"] and p["close"] > 0] if series else []
    if not closes:
        return None, None, None
    high, low, last = max(closes), min(closes), closes[-1]
    pos = (last - low) / (high - low) if high > low else None
    return pos, high, low


MINOR_UNIT_SUFFIXES = {".L": "GBP", ".TA": "ILS", ".JO": "ZAR"}  # Yahoo даёт цену в пенсах/агоротах/центах


def price_unit_divisor(ticker, currency):
    """100 для бирж, где Yahoo отдаёт цену в сотых долях валюты (Лондон, Тель-Авив, Йоханнесбург), иначе 1."""
    for suffix, cur in MINOR_UNIT_SUFFIXES.items():
        if ticker.endswith(suffix) and currency == cur:
            return 100.0
    return 1.0


def volume_fields(ticker, entry, row, series, vol, avg_volume):
    """volume, avgVolume, relVolume, turnoverUSD (null, если данных нет).
    avgVolume: 3-месячное среднее Yahoo (из фундаментала), иначе среднее по хранимым сессиям (>= 5).
    turnoverUSD = объём × последнее закрытие × курс к доллару; у крипты объём Yahoo уже в долларах."""
    out = {"volume": None, "avgVolume": None, "relVolume": None, "turnoverUSD": None}
    if not vol:
        return out
    volume = vol["volume"]
    avg = avg_volume if avg_volume and avg_volume > 0 else (vol["mean"] if vol["n"] >= 5 else None)
    out["volume"] = volume
    out["avgVolume"] = avg
    if avg:
        out["relVolume"] = volume / avg
    if entry.get("continuous"):
        out["turnoverUSD"] = volume
    else:
        last = series[-1]["close"] if series else None
        rate = fx_rate(row["currency"])
        if last and last > 0 and rate:
            out["turnoverUSD"] = volume * last / price_unit_divisor(ticker, row["currency"]) * rate
    return out


def build_metrics(entry):
    import fetch_fundamentals
    import volumes
    rows = load_index_rows(entry)
    legacy = entry["id"] == "sp500"
    tickers = [r["ticker"] for r in rows]
    fund = fetch_fundamentals.read_fundamentals(FUNDAMENTALS_DB_PATH, tickers)
    vols = volumes.read_stats(VOLUMES_DB_PATH, tickers)
    result = {}
    for row in rows:
        t = row["ticker"]
        series = history_cache.get(t) if legacy else lookup_series(t)
        pos, high, low = compute_52w(series)
        f = fund.get(t) or {}
        result[t] = {"pe": f.get("pe"), "divYield": f.get("div_yield"),
                     "pos52w": pos, "high52w": high, "low52w": low,
                     "ps": f.get("ps"), "pb": f.get("pb"), "beta": f.get("beta"), "revGrowth": f.get("rev_growth"),
                     **volume_fields(t, entry, row, series, vols.get(t), f.get("avg_volume"))}
    return result


@app.get("/api/v1/metrics")
async def get_metrics(index: Optional[str] = None):
    """P/E, P/S, P/B, beta, рост выручки (%), дивидендная доходность (%, из fundamentals.db; нет — null),
    положение цены в 52-недельном диапазоне (из годовой истории в памяти) и объёмы (volumes.db: volume, avgVolume,
    relVolume, turnoverUSD) для всех тикеров индекса. Кэш на индекс, сбрасывается при перезагрузке истории."""
    entry = find_index(index or "sp500")
    if entry is None:
        raise HTTPException(status_code=404, detail="unknown index")
    cached = _metrics_cache.get(entry["id"])
    now = time.time()
    if cached and cached[0] == _overview_cache["version"] and now - cached[1] < METRICS_TTL_SECONDS:
        return cached[2]
    data = await asyncio.to_thread(build_metrics, entry)
    _metrics_cache[entry["id"]] = (_overview_cache["version"], now, data)
    return data


_ohlc_semaphore = None


@app.get("/api/v1/ohlc/{ticker}")
async def get_ohlc(ticker: str, range: str = "1y"):
    """Свечи для графика: ?range=1m|3m|6m|1y (дневные) или 3y|5y|10y (недельные).
    Yahoo по запросу, кэш в SQLite ohlc_cache.db (6 ч / 3 дня); не больше двух одновременных запросов к Yahoo."""
    global _ohlc_semaphore
    import ohlc
    import fetch_fundamentals
    if range not in ohlc.RANGES:
        raise HTTPException(status_code=400, detail="range must be one of " + ", ".join(ohlc.RANGES))
    t = ticker.strip().upper()
    if not (t in known_company_names() or lookup_series(t) or t in history_cache):
        raise HTTPException(status_code=404, detail="unknown ticker")
    cached = await asyncio.to_thread(ohlc.get_cached, OHLC_DB_PATH, t, range)
    if cached is not None:
        return cached
    currency = "USD"
    for entry in get_registry():
        match = next((r for r in load_index_rows(entry) if r["ticker"] == t), None)
        if match:
            currency = match["currency"]
            break
    if _ohlc_semaphore is None:
        _ohlc_semaphore = asyncio.Semaphore(2)
    async with _ohlc_semaphore:
        try:
            return await asyncio.to_thread(ohlc.build_ohlc, t, range, fetch_fundamentals.yahoo_symbol(t), currency,
                                           OHLC_DB_PATH)
        except Exception as e:
            print(f"⚠️ /ohlc {t} {range}: {e}")
            raise HTTPException(status_code=502, detail="price data unavailable")


_company_names = {"mtime": None, "data": {}}
_company_semaphore = None


def known_company_names():
    """ticker -> название из CSV всех индексов (строится при первом обращении, ~5000 строк)."""
    if not _company_names["data"]:
        names = {}
        for entry in get_registry():
            for row in load_index_rows(entry):
                names.setdefault(row["ticker"], row["name"])
        _company_names["data"] = names
    return _company_names["data"]


def build_company_payload(ticker):
    """Синхронно (в потоке): кэш SQLite >= 6 ч, иначе Yahoo; сбой Yahoo — null-поля и пустые новости (не кэшируем)."""
    import fetch_fundamentals
    cached = fetch_fundamentals.get_cached_company(FUNDAMENTALS_DB_PATH, ticker)
    if cached is not None:
        return cached
    try:
        data = fetch_fundamentals.build_company(FUNDAMENTALS_DB_PATH, ticker)
        ok = True
    except Exception as e:
        print(f"⚠️ /company {ticker}: {e}")
        data, ok = {}, False
    series = lookup_series(ticker)
    _, high, low = compute_52w(series)
    payload = {
        "ticker": ticker, "name": data.get("name") or known_company_names().get(ticker),
        "pe": data.get("pe"), "forwardPe": data.get("forwardPe"), "divYield": data.get("divYield"),
        "dividendRate": data.get("dividendRate"), "exDividendDate": data.get("exDividendDate"),
        "earningsDate": data.get("earningsDate"), "high52w": high, "low52w": low,
        "beta": data.get("beta"), "currency": data.get("currency"), "news": data.get("news") or [],
    }
    if ok and (payload["news"] or payload["pe"] is not None or payload["divYield"] is not None or payload["name"]):
        fetch_fundamentals.put_cached_company(FUNDAMENTALS_DB_PATH, ticker, payload)
    return payload


@app.get("/api/v1/company/{ticker}")
async def get_company(ticker: str):
    """Карточка компании: фундаментал + заголовки новостей Yahoo. Кэш в SQLite >= 6 ч; не блокирует цикл событий."""
    global _company_semaphore
    t = ticker.strip().upper()
    if not (t in known_company_names() or lookup_series(t) or t in history_cache):
        raise HTTPException(status_code=404, detail="unknown ticker")
    if _company_semaphore is None:
        _company_semaphore = asyncio.Semaphore(2)  # не больше двух одновременных запросов к Yahoo
    async with _company_semaphore:
        return await asyncio.to_thread(build_company_payload, t)


# ---------------------------------------------------------------- отчётность, календарь, скринер, дайджест

_financials_semaphore = None
FIN_EMPTY_RETRY_SECONDS = 3600  # пустой ответ Yahoo (ETF, крипта или сбой) помним 1 час, а не сутки


def ticker_currency(ticker):
    for entry in get_registry():
        match = next((r for r in load_index_rows(entry) if r["ticker"] == ticker), None)
        if match:
            return match["currency"]
    return None


def build_financials_payload(ticker):
    """Синхронно (в потоке): Yahoo -> компактный JSON (без holders). Исключение — Yahoo недоступен."""
    import fin
    import fetch_fundamentals
    data = fin.build_financials(ticker, fetch_fundamentals.yahoo_symbol(ticker), fallback_currency=ticker_currency(ticker))
    empty = not data["annual"] and not data["quarterly"]
    fin.put_cached(FINANCIALS_DB_PATH, ticker, data,
                   now=time.time() - (fin.CACHE_SECONDS - FIN_EMPTY_RETRY_SECONDS if empty else 0))
    return data


@app.get("/api/v1/financials/{ticker}")
async def get_financials(ticker: str):
    """Отчётность: до 4 лет и 6 кварталов, коэффициенты, мнения аналитиков (Yahoo) и держатели из 13F гуру.
    Кэш 24 ч в financials_cache.db; не больше двух одновременных запросов к Yahoo; Yahoo упал — отдаём устаревший кэш."""
    global _financials_semaphore
    import fin
    t = ticker.strip().upper()
    if not (t in known_company_names() or lookup_series(t) or t in history_cache):
        raise HTTPException(status_code=404, detail="unknown ticker")
    cached, fresh = await asyncio.to_thread(fin.get_cached, FINANCIALS_DB_PATH, t)
    data = cached if fresh else None
    if data is None:
        if _financials_semaphore is None:
            _financials_semaphore = asyncio.Semaphore(2)
        async with _financials_semaphore:
            try:
                data = await asyncio.to_thread(build_financials_payload, t)
            except Exception as e:
                print(f"⚠️ /financials {t}: {e}")
                data = cached  # устаревшее лучше ошибки
        if data is None:
            raise HTTPException(status_code=502, detail="financial data unavailable")
    return {**data, "holders": fin.holders_for(t, GURU_HOLDINGS_PATH)}


SCREENER_PERIOD_DAYS = {"1d": 1, "3d": 3, "7d": 5, "30d": 21, "180d": 126, "1y": 252}  # торговых дней назад


def period_change(entry, ticker, series, period):
    """% изменения за период теми же функциями, что /performance (длинные 3y/5y/10y — из недельных баз)."""
    if period == "ytd":
        return compute_ytd_return(series)
    if period in LONG_PERIODS:
        return long_returns(ticker, series)[period]
    days = (CONTINUOUS_PERIOD_DAYS if entry.get("continuous") else SCREENER_PERIOD_DAYS)[period]
    return compute_return(series, days)


def rel_volume(vol, avg_volume):
    if not vol:
        return None
    avg = avg_volume if avg_volume and avg_volume > 0 else (vol["mean"] if vol["n"] >= 5 else None)
    return vol["volume"] / avg if avg else None


def screener_candidates(index):
    """[(entry, row, series)] без повторов: тикер из нескольких индексов — один раз, по первому индексу реестра.
    index: None/'sp500', id индекса или 'all'. Замёрзшие и бесхистории тикеры не показываем (как на карте)."""
    if index == "all":
        entries = list(get_registry())
    else:
        entry = find_index(index or "sp500")
        if entry is None:
            raise HTTPException(status_code=404, detail="unknown index")
        entries = [entry]
    latest_hist = history_last_date(history_cache)
    latest_world = history_last_date(world_history_cache)
    seen, out = set(), []
    for entry in entries:
        legacy = entry["id"] == "sp500"
        latest = latest_hist if legacy else latest_world
        for row in load_index_rows(entry):
            t = row["ticker"]
            if t in seen:
                continue
            seen.add(t)
            if not _overview_row_shown(entry, row, latest):
                continue
            out.append((entry, row, history_cache.get(t) if legacy else lookup_series(t)))
    return out


def screener_row(entry, row, series, f, period, vol=None):
    pos = compute_52w(series)[0]
    rate = fx_rate(row["currency"])
    return {
        "ticker": row["ticker"], "name": row["name"], "index": entry["id"], "sector": row["sector"],
        "capUSD": row["cap"] * rate if rate is not None and row["cap"] > 0 else None,
        "change": period_change(entry, row["ticker"], series, period),
        "pe": f.get("pe"), "ps": f.get("ps"), "pb": f.get("pb"), "divYield": f.get("div_yield"),
        "beta": f.get("beta"), "revGrowth": f.get("rev_growth"), "pos52w": pos,
        "relVolume": rel_volume(vol, f.get("avg_volume")),
    }


def build_screener(index, params, period, limit):
    import fetch_fundamentals
    import screener
    import volumes
    filters, sort, order = screener.effective(params)
    cands = screener_candidates(index)
    tickers = [row["ticker"] for _, row, _ in cands]
    fund = fetch_fundamentals.read_fundamentals(FUNDAMENTALS_DB_PATH, tickers)
    vols = volumes.read_stats(VOLUMES_DB_PATH, tickers) if screener.needs_volume(filters, sort) else {}
    rows = []
    for entry, row, series in cands:
        r = screener_row(entry, row, series, fund.get(row["ticker"]) or {}, period, vols.get(row["ticker"]))
        if screener.passes(r, filters, params.get("sector")):
            rows.append(r)
    rows = screener.sort_rows(rows, sort, order)
    shown = rows[:limit]
    if not vols and shown:  # объёмы нужны только для выдачи
        vols = volumes.read_stats(VOLUMES_DB_PATH, [r["ticker"] for r in shown])
        for r in shown:
            r["relVolume"] = rel_volume(vols.get(r["ticker"]), (fund.get(r["ticker"]) or {}).get("avg_volume"))
    return {"total": len(rows), "rows": shown}


@app.get("/api/v1/screener")
async def get_screener(index: Optional[str] = None, sector: Optional[str] = None,
                       minCap: Optional[float] = None, maxCap: Optional[float] = None,
                       peMin: Optional[float] = None, peMax: Optional[float] = None,
                       psMax: Optional[float] = None, pbMax: Optional[float] = None,
                       divMin: Optional[float] = None, betaMax: Optional[float] = None,
                       revGrowthMin: Optional[float] = None, period: str = "1d",
                       chgMin: Optional[float] = None, chgMax: Optional[float] = None,
                       pos52Min: Optional[float] = None, pos52Max: Optional[float] = None,
                       relVolMin: Optional[float] = None, sort: Optional[str] = None, order: Optional[str] = None,
                       limit: int = 100, preset: Optional[str] = None):
    """Фильтр акций по индексу или по всем индексам сразу (index=all, повторы тикеров убраны).
    Капитализация — в долларах; pos52w/pos52Min/pos52Max — 0..1 (1 = у годового максимума); divYield, revGrowth,
    change — в процентах. Строки с пустым значением фильтруемого поля исключаются; в сортировке пустые — в конце.
    Считается на лету из кэшей в памяти и SQLite, лимит выдачи 500."""
    import screener
    if period not in screener.PERIODS:
        raise HTTPException(status_code=400, detail="period must be one of " + ", ".join(screener.PERIODS))
    if preset is not None and preset not in screener.PRESETS:
        raise HTTPException(status_code=400, detail="preset must be one of " + ", ".join(screener.PRESETS))
    if sort is not None and sort not in screener.SORT_FIELDS:
        raise HTTPException(status_code=400, detail="sort must be one of " + ", ".join(screener.SORT_FIELDS))
    if order is not None and order not in ("asc", "desc"):
        raise HTTPException(status_code=400, detail="order must be asc or desc")
    params = {"sector": sector, "minCap": minCap, "maxCap": maxCap, "peMin": peMin, "peMax": peMax, "psMax": psMax,
              "pbMax": pbMax, "divMin": divMin, "betaMax": betaMax, "revGrowthMin": revGrowthMin, "chgMin": chgMin,
              "chgMax": chgMax, "pos52Min": pos52Min, "pos52Max": pos52Max, "relVolMin": relVolMin, "sort": sort,
              "order": order, "preset": preset}
    return await asyncio.to_thread(build_screener, index, params, period, max(1, min(limit, 500)))


CALENDAR_MAX_DAYS = 366
CALENDAR_MAX_EVENTS = 5000


def build_calendar(index, tickers, start, end):
    import fetch_fundamentals
    import screener
    cands = screener_candidates(index) if index else screener_candidates("sp500")
    if tickers:
        wanted = set(tickers)
        cands = [c for c in cands if c[1]["ticker"] in wanted]
    fund = fetch_fundamentals.read_fundamentals(FUNDAMENTALS_DB_PATH, [row["ticker"] for _, row, _ in cands])
    rows = []
    for entry, row, _ in cands:
        f = fund.get(row["ticker"])
        if f:
            rows.append({"ticker": row["ticker"], "name": f.get("name") or row["name"], "index": entry["id"],
                         "earnings_date": f.get("earnings_date"), "ex_dividend_date": f.get("ex_dividend_date"),
                         "dividend_date": f.get("dividend_date"), "dividend_rate": f.get("dividend_rate")})
    return {"events": screener.calendar_events(rows, start, end)[:CALENDAR_MAX_EVENTS]}


@app.get("/api/v1/calendar")
async def get_calendar(index: Optional[str] = None, tickers: Optional[str] = None,
                       from_: Optional[str] = Query(None, alias="from"), to: Optional[str] = None):
    """События в диапазоне дат (по умолчанию ближайшие 14 дней): earnings (отчёт), exDividend (отсечка),
    dividendPay (выплата) из fundamentals.db. index = id или all; tickers=A,B сужает список. Диапазон до 366 дней."""
    import screener
    try:
        start = date.fromisoformat(from_) if from_ else None
        end = date.fromisoformat(to) if to else None
    except ValueError:
        raise HTTPException(status_code=400, detail="from/to must be YYYY-MM-DD")
    start, end = screener.default_range(start, end, datetime.now(MARKET_TZ).date())
    if end < start or (end - start).days > CALENDAR_MAX_DAYS:
        raise HTTPException(status_code=400, detail=f"range must be 0..{CALENDAR_MAX_DAYS} days")
    wanted = [t.strip().upper() for t in tickers.split(",") if t.strip()][:200] if tickers else None
    return await asyncio.to_thread(build_calendar, index, wanted, start, end)


BRIEF_TTL_SECONDS = 900
BRIEF_HEADLINES = 8
_brief_cache = {"at": 0.0, "version": None, "data": None}


def brief_headlines(movers):
    """Заголовки из кэша /company у самых заметных бумаг (нет в кэше — докачиваем, не больше двух параллельно)."""
    import fetch_fundamentals
    from concurrent.futures import ThreadPoolExecutor

    def news_for(t):
        payload = fetch_fundamentals.get_cached_company(FUNDAMENTALS_DB_PATH, t, max_age=24 * 3600)
        if payload is None:
            try:
                payload = build_company_payload(t)
            except Exception as e:
                print(f"⚠️ brief news {t}: {e}")
                return []
        return payload.get("news") or []

    with ThreadPoolExecutor(max_workers=2) as pool:
        per_ticker = list(pool.map(news_for, movers))
    out, seen = [], set()
    for rank in range(3):
        for t, news in zip(movers, per_ticker):
            if rank < len(news) and news[rank].get("url") not in seen and len(out) < BRIEF_HEADLINES:
                n = news[rank]
                seen.add(n["url"])
                out.append({"title": n.get("title"), "publisher": n.get("publisher"), "url": n["url"], "ticker": t})
    return out


def build_brief():
    import fetch_fundamentals
    cands = screener_candidates("sp500")
    fund = fetch_fundamentals.read_fundamentals(FUNDAMENTALS_DB_PATH, [row["ticker"] for _, row, _ in cands])
    rows = [screener_row(e, r, s, fund.get(r["ticker"]) or {}, "1d") for e, r, s in cands]
    movers = [r for r in rows if r["change"] is not None]
    movers.sort(key=lambda r: r["change"], reverse=True)
    brief_cols = ("ticker", "name", "sector", "capUSD", "change")
    top = lambda lst: [{k: r[k] for k in brief_cols} for r in lst]  # noqa: E731
    gainers, losers = top(movers[:5]), top(movers[::-1][:5])
    sectors = {}
    for r in movers:
        if r["capUSD"]:
            w = start_weight(r["capUSD"], r["change"])
            acc = sectors.setdefault(r["sector"], [0.0, 0.0])
            acc[0] += w * r["change"]
            acc[1] += w
    sector_rows = sorted(({"name": n, "change": a[0] / a[1]} for n, a in sectors.items() if a[1] > 0),
                         key=lambda x: x["change"], reverse=True)
    overview = get_world_overview_cached()
    indices = [{"id": i["id"], "change1d": (i.get("changes") or {}).get("1d")}
               for reg in overview["regions"] for i in reg["indices"] if reg["id"] != "assets"]
    # заголовки: по два самых сильных роста и падения плюс крупнейшие компании среди движущихся
    focus = [r["ticker"] for r in gainers[:3] + losers[:3]]
    focus += [r["ticker"] for r in sorted(movers, key=lambda r: -(r["capUSD"] or 0))[:2] if r["ticker"] not in focus]
    return {"date": history_last_date(history_cache), "indices": indices, "topGainers": gainers, "topLosers": losers,
            "sectors": sector_rows, "headlines": brief_headlines(focus)}


@app.get("/api/v1/brief")
async def get_brief(date: str = "today"):
    """Сырьё для ИИ-дайджеста дня: индексы, 5 лидеров роста и падения S&P 500, секторы, до 8 заголовков.
    Данные всегда за последнюю торговую сессию в истории; ?date принимает today или YYYY-MM-DD (проверяется формат).
    Кэш 15 минут."""
    if date != "today":
        try:
            datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise HTTPException(status_code=400, detail="date must be today or YYYY-MM-DD")
    version = (_overview_cache["version"], history_last_date(history_cache))
    now = time.time()
    if _brief_cache["data"] and _brief_cache["version"] == version and now - _brief_cache["at"] < BRIEF_TTL_SECONDS:
        return _brief_cache["data"]
    data = await asyncio.to_thread(build_brief)
    _brief_cache.update(at=now, version=version, data=data)
    return data


# ---------------------------------------------------------------- фоновые задачи: крипта, ETF, фундаментал

def all_fundamental_symbols():
    """Тикеры всех индексов (кроме крипты) в порядке реестра; S&P 500 первым."""
    seen = {}
    for entry in get_registry():
        if entry.get("continuous"):
            continue
        for row in load_index_rows(entry):
            seen.setdefault(row["ticker"], None)
    return list(seen)


def run_crypto_refresh():
    try:
        import fetch_assets
    except ImportError:
        return None
    return fetch_assets.refresh_crypto(WORLD_DB_PATH)


def run_long_refresh():
    try:
        import fetch_long
    except ImportError:
        print("⚠️ fetch_long.py не найден — длинные периоды не обновлены")
        return None
    return fetch_long.refresh(LONG_DB_PATH)


def long_refresh_due(now_utc, last_run_date):
    """Пора качать: базы нет — сразу; иначе по субботам (UTC), один раз в сутки."""
    if not os.path.exists(LONG_DB_PATH):
        return True
    return now_utc.weekday() == 5 and last_run_date != now_utc.date()


async def long_refresher():
    """Недельные закрытия 10+ лет: при старте, если базы нет, и каждую субботу. Докачка пропускает свежие тикеры,
    так что повторный запуск после обрыва дешёвый."""
    last_run = None
    while True:
        try:
            now = datetime.now(ZoneInfo("UTC"))
            if long_refresh_due(now, last_run):
                last_run = now.date()
                print("📚 Обновляем длинные периоды (history_long.db)")
                result = await asyncio.to_thread(run_long_refresh)
                if result:
                    await asyncio.to_thread(load_long_history)
            elif os.path.exists(LONG_DB_PATH) and os.path.getmtime(LONG_DB_PATH) != _long_db_mtime["value"]:
                await asyncio.to_thread(load_long_history)
        except Exception as e:
            print(f"⚠️ Обновление длинных периодов не удалось: {e}")
        await asyncio.sleep(LONG_CHECK_SECONDS)


async def crypto_refresher():
    """Каждые ~6 часов, 24/7: состав/капитализация CoinGecko + закрытия Yahoo -> history_world.db."""
    while True:
        try:
            fresh = (os.path.exists(WORLD_DB_PATH)
                     and time.time() - os.path.getmtime(WORLD_DB_PATH) < CRYPTO_REFRESH_SECONDS / 2)
            result = None if fresh and world_history_cache.get("BTC-USD") else await asyncio.to_thread(run_crypto_refresh)
            if result:
                print(f"🪙 Крипта обновлена: {result['coins']} монет")
                await asyncio.to_thread(load_world_history)
        except Exception as e:
            print(f"⚠️ Обновление крипты не удалось: {e}")
        await asyncio.sleep(CRYPTO_REFRESH_SECONDS)


def run_fundamentals_pass(max_seconds):
    import fetch_fundamentals
    todo = fetch_fundamentals.stale_symbols(FUNDAMENTALS_DB_PATH, all_fundamental_symbols())
    if not todo:
        return None
    return fetch_fundamentals.refresh_fundamentals(FUNDAMENTALS_DB_PATH, todo, max_seconds=max_seconds)


def in_night_window(now_utc):
    lo, hi = FUNDAMENTALS_NIGHT_HOURS_UTC
    return lo <= now_utc.hour < hi


async def fundamentals_refresher():
    """Недельный проход: ночью (UTC 01–07) докачивает фундаментал у тикеров, которым >7 дней (или данных нет),
    по ~1 запросу/сек; что не успели — на следующую ночь. Раз в неделю обновляет AUM у ETF."""
    last_etf = 0.0
    while True:
        try:
            if in_night_window(datetime.now(ZoneInfo("UTC"))):
                result = await asyncio.to_thread(run_fundamentals_pass, 3300)
                if result:
                    print(f"📊 Фундаментал: ок {result['ok']}, сбоев {result['failed']}, осталось {result['skipped']}")
                if time.time() - last_etf > 7 * 86400:
                    import fetch_assets
                    etf = await asyncio.to_thread(fetch_assets.refresh_etf_aum)
                    last_etf = time.time()
                    print(f"📊 AUM ETF: {etf['live_aum']}/{etf['etfs']}")
        except Exception as e:
            print(f"⚠️ Обновление фундаментала не удалось: {e}")
        await asyncio.sleep(FUNDAMENTALS_CHECK_SECONDS)


async def finnhub_listener():
    """Держит соединение с Finnhub WS и обновляет price_cache реальными сделками.

    Используется только когда MOCK_MODE=false. Бесплатный тариф Finnhub может
    ограничивать число одновременных подписок — тикеры, на которые подписаться
    не удалось, просто останутся на последней известной цене закрытия.
    """
    if not FINNHUB_API_KEY:
        print("⚠️ FINNHUB_API_KEY не задан — живые цены недоступны, отдаём последние цены закрытия")
        return

    url = f"{FINNHUB_WEBSOCKET_URL}?token={FINNHUB_API_KEY}"
    backoff = 5
    while True:
        try:
            async with websockets.connect(url) as ws:
                print(f"✅ Подключено к Finnhub WS, подписываемся на {len(price_cache)} тикеров")
                for ticker in price_cache:
                    await ws.send(json.dumps({"type": "subscribe", "symbol": ticker}))
                    await asyncio.sleep(0.02)  # не бьём rate limit на подписке
                backoff = 5
                async for message in ws:
                    msg = json.loads(message)
                    if msg.get("type") != "trade":
                        continue
                    if not is_regular_market_hours():
                        # Игнорируем пре-/постмаркет сделки — цена замирает на
                        # последней цене regular session вместо хаотичных скачков
                        # на низкой ликвидности вне основной сессии.
                        continue
                    for trade in msg.get("data", []):
                        ticker = trade.get("s")
                        price = trade.get("p")
                        entry = price_cache.get(ticker)
                        if not entry or price is None:
                            continue
                        today = market_today()
                        previous_close = live_previous_close(entry, today)
                        entry["price"] = price
                        entry["live_date"] = today
                        entry["change_percent"] = (price - previous_close) / previous_close * 100 if previous_close > 0 else 0
                        entry["timestamp"] = time.time()
        except Exception as e:
            print(f"⚠️ Finnhub WS обрыв: {e} — переподключение через {backoff}с")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60)


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            updates = []
            for ticker, data in price_cache.items():
                if MOCK_MODE:
                    # MOCK: имитируем живое дрожание цены вокруг реальной последней цены
                    # закрытия (anchor). Это НЕ реальные котировки — используется только
                    # для разработки/демо, когда нет доступа к Finnhub live-данным.
                    anchor = data.get('anchor', data['price'])
                    jitter = random.uniform(-0.003, 0.003)
                    live_price = anchor * (1 + jitter)
                    previous_close = data.get('previous_close', anchor)
                    data['price'] = live_price
                    data['change_percent'] = (live_price - previous_close) / previous_close * 100 if previous_close > 0 else 0
                # иначе цены уже обновляются в реальном времени в finnhub_listener()

                updates.append({
                    "t": ticker,
                    "p": round(data['price'], 2),
                    "c": round(data['change_percent'], 2)
                })
            if updates:
                await websocket.send_text(json.dumps(updates))
            await asyncio.sleep(1)
    except Exception as e:
        print(f"WebSocket error: {e}")

@asynccontextmanager
async def lifespan(_: FastAPI):
    load_history()
    load_world_history()
    load_long_history()
    seed_prices_from_history()
    load_initial_prices()  # фоллбэк для тикеров без реальной истории
    if not price_cache:
        print("⚠️ Нет данных, используем случайные")
        for ticker in ['AAPL', 'MSFT', 'GOOGL', 'NVDA', 'AMZN', 'META', 'TSLA', 'JPM', 'V', 'PG']:
            price = random.uniform(10, 1000)
            change = random.uniform(-5, 5)
            price_cache[ticker] = {'price': price, 'anchor': price, 'previous_close': price, 'change_percent': change, 'timestamp': time.time()}
        print("Generated random data for test")
    else:
        print("✅ Данные загружены успешно")

    if MOCK_MODE:
        print("🧪 MOCK_MODE=true — цены симулируются локально, это НЕ реальные live-котировки")
    else:
        print("📡 MOCK_MODE=false — подключаемся к Finnhub за реальными live-котировками")
        asyncio.create_task(finnhub_listener())

    if HISTORY_DB_URL:
        asyncio.create_task(history_refresher())
    if FX_STARTUP_REFRESH:
        asyncio.create_task(fx_startup_refresher())
    if WORLD_REFRESH:
        asyncio.create_task(world_refresher())
    if CRYPTO_REFRESH and WORLD_REFRESH:
        asyncio.create_task(crypto_refresher())
    if LONG_REFRESH:
        asyncio.create_task(long_refresher())
    if FUNDAMENTALS_REFRESH:
        asyncio.create_task(fundamentals_refresher())

    yield


app.router.lifespan_context = lifespan

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", 8000)))
