import csv
import psycopg2
from psycopg2.extras import execute_values
import re

# Подключение к БД
conn = psycopg2.connect(
    host="localhost",
    port=5432,
    database="sp500_heatmap",
    user="heatmap_user",
    password="heatmap_pass"
)
cur = conn.cursor()

# Функция для преобразования Market Cap (уже в млн)
def parse_market_cap(value):
    if not value or value.strip() == '':
        return 0
    value = value.replace(',', '').strip()
    try:
        return float(value) * 1_000_000
    except:
        return 0

# Функция для преобразования процентов
def parse_percent(value):
    if not value or value.strip() == '' or value == '-':
        return 0
    value = value.replace('%', '').strip()
    try:
        return float(value)
    except:
        return 0

# Читаем CSV
print("Чтение CSV файла...")
sectors = {}
subsectors = {}
companies = []

with open('companies_latest.csv', 'r', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f, delimiter=';')
    for row in reader:
        sector_name = row['Sector'].strip()
        subsector_name = row['Industry'].strip()
        ticker = row['Symbol'].strip()
        name = row['Company Name'].strip()
        market_cap = parse_market_cap(row['Market Cap'])
        
        if sector_name not in sectors:
            sectors[sector_name] = True
        
        key = f"{sector_name}|{subsector_name}"
        if key not in subsectors:
            subsectors[key] = sector_name
        
        companies.append({
            'ticker': ticker,
            'name': name,
            'market_cap': market_cap,
            'subsector_name': subsector_name,
            'sector_name': sector_name
        })

print(f"Найдено {len(companies)} компаний")

# 1. Вставляем сектора
print("Вставка секторов...")
for sector_name in sectors:
    cur.execute("INSERT INTO sectors (name, display_order) VALUES (%s, %s) ON CONFLICT (name) DO NOTHING",
                (sector_name, 0))
conn.commit()
print(f"  Добавлено секторов: {len(sectors)}")

# 2. Получаем id секторов
cur.execute("SELECT id, name FROM sectors")
sector_ids = {name: id for id, name in cur.fetchall()}

# 3. Вставляем подсектора (с проверкой существования)
print("Вставка подсекторов...")
subsector_count = 0
for key, sector_name in subsectors.items():
    subsector_name = key.split('|')[1]
    sector_id = sector_ids.get(sector_name)
    if sector_id:
        # Проверяем, существует ли уже такой подсектор
        cur.execute("SELECT id FROM subsectors WHERE name = %s AND sector_id = %s", (subsector_name, sector_id))
        if not cur.fetchone():
            cur.execute("INSERT INTO subsectors (name, sector_id, display_order) VALUES (%s, %s, %s)",
                        (subsector_name, sector_id, 0))
            subsector_count += 1
conn.commit()
print(f"  Добавлено подсекторов: {subsector_count}")

# 4. Получаем id подсекторов
cur.execute("SELECT s.id, s.name, sec.name as sector_name FROM subsectors s JOIN sectors sec ON s.sector_id = sec.id")
subsector_map = {}
for id, name, sector_name in cur.fetchall():
    subsector_map[f"{sector_name}|{name}"] = id

# 5. Вставляем компании
print("Вставка компаний...")
company_count = 0
for comp in companies:
    subsector_key = f"{comp['sector_name']}|{comp['subsector_name']}"
    subsector_id = subsector_map.get(subsector_key)
    if subsector_id:
        cur.execute("""
            INSERT INTO companies (ticker, name, description, market_cap, subsector_id, pe_ratio, dividend_yield, volume)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (ticker) DO UPDATE SET
                name = EXCLUDED.name,
                market_cap = EXCLUDED.market_cap,
                subsector_id = EXCLUDED.subsector_id
        """, (comp['ticker'], comp['name'], None, comp['market_cap'], subsector_id, None, None, None))
        company_count += 1

conn.commit()
print(f"  Добавлено/обновлено компаний: {company_count}")

# 6. Проверка
cur.execute("SELECT COUNT(*) FROM companies")
total_companies = cur.fetchone()[0]
print(f"\n✅ Итог: {total_companies} компаний в базе данных")

cur.close()
conn.close()
