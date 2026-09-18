import asyncio
import json
import os
import random
import csv
import sqlite3
import websockets
from contextlib import asynccontextmanager
from datetime import datetime
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
import time

load_dotenv()

MOCK_MODE = os.getenv("MOCK_MODE", "true").strip().lower() in ("1", "true", "yes")
FINNHUB_API_KEY = os.getenv("FINNHUB_API_KEY")
FINNHUB_WEBSOCKET_URL = os.getenv("FINNHUB_WEBSOCKET_URL", "wss://ws.finnhub.io")

MARKET_TZ = ZoneInfo("America/New_York")


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
history_cache = {}  # ticker -> [{"date": "YYYY-MM-DD", "close": float}, ...] по возрастанию даты


def load_history():
    """Загружает дневные цены закрытия из history.db (см. fetch_history.py)"""
    db_path = 'history.db'
    if not os.path.exists(db_path):
        print("⚠️ history.db не найден — запустите fetch_history.py для загрузки истории цен")
        return

    conn = sqlite3.connect(db_path)
    cur = conn.execute("SELECT ticker, date, close FROM daily_closes ORDER BY ticker, date")
    for ticker, date, close in cur.fetchall():
        history_cache.setdefault(ticker, []).append({"date": date, "close": close})
    conn.close()
    print(f"✅ Загружена история цен для {len(history_cache)} тикеров")


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


def seed_prices_from_history():
    """Инициализирует price_cache реальными ценами закрытия из history_cache.

    'anchor' — последняя реальная цена закрытия, вокруг которой WebSocket
    будет создавать небольшое живое дрожание цены (см. websocket_endpoint).
    'previous_close' — предыдущая реальная цена закрытия, от неё считается % изменения.
    """
    count = 0
    for ticker, series in history_cache.items():
        if len(series) < 2:
            continue
        anchor = series[-1]["close"]
        previous_close = series[-2]["close"]
        if anchor <= 0 or previous_close <= 0:
            continue
        price_cache[ticker] = {
            'price': anchor,
            'anchor': anchor,
            'previous_close': previous_close,
            'change_percent': (anchor - previous_close) / previous_close * 100,
            'timestamp': time.time()
        }
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

@app.get("/health")
async def health():
    """Лёгкий эндпоинт для keep-alive пингов (UptimeRobot/cron-job.org), чтобы бесплатный
    инстанс на Render не засыпал — ничего не парсит и не трогает price_cache."""
    return {"status": "ok"}


@app.get("/api/v1/market-hierarchy")
async def get_market_hierarchy():
    """Возвращает иерархию рынка с секторами, подсекторами и реальной капитализацией"""
    
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
    """Дневные цены закрытия за последний год для тикера"""
    return history_cache.get(ticker.upper(), [])


# Дополнительные периоды для переключателя SC/1d/3d/7d/30d/180d/1y на heatmap-экранах.
# 30d/180d/1y уже покрыты return1M/return6M/return1Y (тот же trading-days-back).
EXTRA_PERIOD_TRADING_DAYS = {"1d": 1, "3d": 3, "7d": 5}


@app.get("/api/v1/performance")
async def get_performance():
    """Доходность по всем тикерам, посчитанная из реальных цен закрытия.

    return1M/return6M/returnYTD/return1Y — для экрана "All Stocks".
    1d/3d/7d/30d/180d/1y — для переключателя периода на heatmap-экранах
    (30d/180d/1y дублируют return1M/return6M/return1Y под ключами, которые
    совпадают с кнопками в UI)."""
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
                        previous_close = entry.get("previous_close", price)
                        entry["price"] = price
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

    yield


app.router.lifespan_context = lifespan

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", 8000)))
