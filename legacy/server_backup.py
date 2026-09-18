import asyncio
import json
import os
import random
import csv
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
import psycopg2
from dotenv import load_dotenv
import time

load_dotenv()

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

def get_db():
    return psycopg2.connect(
        host="localhost",
        port=5432,
        database="sp500_heatmap",
        user="heatmap_user",
        password="heatmap_pass"
    )

price_cache = {}  # {ticker: {'price': float, 'change_percent': float}}

def load_initial_prices():
    """Загружает цены и изменения из CSV"""
    csv_path = 'companies_latest.csv'
    if not os.path.exists(csv_path):
        print("CSV file not found, using random data")
        return
    try:
        with open(csv_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f, delimiter=';')
            for row in reader:
                ticker = row['Symbol'].strip()
                price_str = row['Price'].replace(',', '').strip()
                change_str = row['% Chg'].replace('%', '').strip()
                try:
                    price = float(price_str) if price_str else 0
                except:
                    price = 0
                try:
                    change = float(change_str) if change_str else 0
                except:
                    change = 0
                if ticker and price > 0:
                    price_cache[ticker] = {'price': price, 'change_percent': change, 'timestamp': time.time()}
        print(f"Loaded {len(price_cache)} tickers from CSV")
    except Exception as e:
        print(f"Error loading CSV: {e}")

def generate_mock_updates():
    """Обновляет цены случайными изменениями относительно текущих"""
    for ticker, data in price_cache.items():
        # Случайное изменение от -0.5 до +0.5 процента
        delta = random.uniform(-0.5, 0.5)
        new_price = data['price'] * (1 + delta / 100)
        new_change = data['change_percent'] + delta
        price_cache[ticker] = {'price': new_price, 'change_percent': new_change, 'timestamp': time.time()}

@app.get("/api/v1/market-hierarchy")
async def get_market_hierarchy():
    conn = get_db()
    cur = conn.cursor()
    cur.execute("SELECT id, name, display_order FROM sectors ORDER BY display_order")
    sectors = cur.fetchall()
    result = []
    for sector_id, sector_name, _ in sectors:
        cur.execute("SELECT id, name FROM subsectors WHERE sector_id = %s ORDER BY display_order", (sector_id,))
        subsectors = cur.fetchall()
        subsector_list = []
        for subsector_id, subsector_name in subsectors:
            cur.execute("SELECT ticker, name, market_cap FROM companies WHERE subsector_id = %s ORDER BY market_cap DESC", (subsector_id,))
            companies = cur.fetchall()
            companies_list = [{"ticker": c[0], "name": c[1], "marketCap": float(c[2])} for c in companies]
            subsector_list.append({"id": str(subsector_id), "name": subsector_name, "companies": companies_list})
        result.append({"id": str(sector_id), "name": sector_name, "subsectors": subsector_list})
    cur.close()
    conn.close()
    return result

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            updates = [{"t": ticker, "p": data['price'], "c": round(data['change_percent'], 2)} for ticker, data in price_cache.items()]
            if updates:
                await websocket.send_text(json.dumps(updates))
            await asyncio.sleep(1)
    except Exception as e:
        print(f"WebSocket error: {e}")

@app.on_event("startup")
async def startup_event():
    load_initial_prices()
    # Если CSV не загрузился, загружаем тикеры из БД и генерируем случайные
    if not price_cache:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT ticker FROM companies")
        tickers = [row[0] for row in cur.fetchall()]
        cur.close()
        conn.close()
        for ticker in tickers:
            price = random.uniform(10, 1000)
            change = random.uniform(-5, 5)
            price_cache[ticker] = {'price': price, 'change_percent': change, 'timestamp': time.time()}
        print("Generated random data for all tickers")
    else:
        print("Using real prices from CSV")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
