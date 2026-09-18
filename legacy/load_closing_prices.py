import psycopg2
import requests
import time
from dotenv import load_dotenv
import os
from datetime import datetime, timedelta

# Явный путь к .env
load_dotenv('/Users/maximyaroshenko/Desktop/SP500Heatmap/.env')

api_key = os.getenv("FINNHUB_API_KEY")
if not api_key:
    print("FINNHUB_API_KEY не найден в .env")
    exit(1)

conn = psycopg2.connect(
    host="localhost",
    port=5432,
    database="sp500_heatmap",
    user="heatmap_user",
    password="heatmap_pass"
)
cur = conn.cursor()

cur.execute("SELECT ticker FROM companies")
tickers = [row[0] for row in cur.fetchall()]
print(f"Найдено {len(tickers)} тикеров")

yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
print(f"Загружаем цены закрытия за {yesterday}")

count = 0
for ticker in tickers:
    url = f"https://finnhub.io/api/v1/quote?symbol={ticker}&token={api_key}"
    try:
        resp = requests.get(url, timeout=10)
        data = resp.json()
        pc = data.get('pc')
        if pc is not None:
            cur.execute("""
                INSERT INTO daily_closes (ticker, close_date, close_price)
                VALUES (%s, %s, %s)
                ON CONFLICT (ticker, close_date) DO UPDATE SET close_price = EXCLUDED.close_price
            """, (ticker, yesterday, pc))
            count += 1
            if count % 50 == 0:
                print(f"Загружено {count}/{len(tickers)}")
        else:
            print(f"Нет pc для {ticker}: {data}")
        time.sleep(0.15)
    except Exception as e:
        print(f"Ошибка для {ticker}: {e}")

conn.commit()
print(f"Загрузка завершена. Добавлено/обновлено {count} записей.")

cur.execute("SELECT COUNT(*) FROM daily_closes")
total = cur.fetchone()[0]
print(f"Всего записей в daily_closes: {total}")

cur.close()
conn.close()
