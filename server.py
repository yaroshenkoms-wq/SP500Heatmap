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
from datetime import datetime
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
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

MARKET_TZ = ZoneInfo("America/New_York")


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
world_history_cache = {}  # то же для history_world.db (все остальные индексы)
history_cache = {}  # ticker -> [{"date": "YYYY-MM-DD", "close": float}, ...] по возрастанию даты


def read_history(db_path):
    """Читает дневные цены закрытия из файла SQLite: ticker -> [{"date", "close"}, ...]"""
    result = {}
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute("SELECT ticker, date, close FROM daily_closes ORDER BY ticker, date")
        for ticker, date, close in cur.fetchall():
            result.setdefault(ticker, []).append({"date": date, "close": close})
    finally:
        conn.close()
    return result


def history_last_date(history) -> str:
    """Самая свежая дата закрытия среди всех тикеров ('' если истории нет)."""
    return max((series[-1]["date"] for series in history.values() if series), default="")


def load_history():
    """Загружает дневные цены закрытия из history.db (см. fetch_history.py).

    Вызывается при старте и после каждого автообновления файла — кэш заменяется целиком."""
    if not os.path.exists(DB_PATH):
        print("⚠️ history.db не найден — запустите fetch_history.py для загрузки истории цен")
        return

    fresh = read_history(DB_PATH)
    history_cache.clear()
    history_cache.update(fresh)
    print(f"✅ Загружена история цен для {len(history_cache)} тикеров (по {history_last_date(history_cache)})")


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
                else:
                    sector = (row.get("Sector") or "").strip() or "Other"
                    subsector = (row.get("Subsector") or "").strip() or "Other"
                    cap = _parse_cap(row.get("MarketCap"))
                rows.append({"ticker": ticker, "name": (row.get("Security") or "").strip() or ticker,
                             "sector": sector, "subsector": subsector, "cap": cap})
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
    fresh = read_history(WORLD_DB_PATH)
    world_history_cache.clear()
    world_history_cache.update(fresh)
    _world_db_mtime["value"] = os.path.getmtime(WORLD_DB_PATH)
    print(f"✅ Загружена мировая история для {len(world_history_cache)} тикеров (по {history_last_date(world_history_cache)})")
    return True


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


def performance_entry(series):
    return_1m = compute_return(series, 21)
    return_6m = compute_return(series, 126)
    return_1y = compute_return(series, 252)
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
        entry[period] = compute_return(series, days)
    return entry


def indices_due(registry, now, last_refreshed, delay_minutes=30):
    """Какие индексы пора обновить: биржа закрылась ≥ delay_minutes назад (будний день по её
    часовому поясу), и сессия этого дня ещё не обновлялась. Только индексы с history_world.db.
    last_refreshed: id -> 'YYYY-MM-DD' (дата сессии, которую уже обновили). now — aware datetime."""
    due = []
    for entry in registry:
        if entry.get("history") != "history_world.db":
            continue
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
        result.append({
            "id": entry["id"],
            "name": entry.get("name", entry["id"]),
            "region": entry.get("region", ""),
            "country": entry.get("country", ""),
            "currency": entry.get("currency", ""),
            "live": bool(entry.get("live", False)),
            "count": len(load_index_rows(entry)),
            "historyThrough": index_history_through(entry) if entry["id"] != "sp500" else history_last_date(history_cache),
        })
    return result


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
async def get_history(ticker: str):
    """Дневные цены закрытия за последний год для тикера (history.db и history_world.db)"""
    t = ticker.upper()
    return history_cache.get(t) or world_history_cache.get(t) or []


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
        return {t: performance_entry(s) for t, s in index_series(entry_).items()}
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
        result[ticker] = entry
    return result


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
    if WORLD_REFRESH:
        asyncio.create_task(world_refresher())

    yield


app.router.lifespan_context = lifespan

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", 8000)))
