"""
Обновляет SP500_with_market_cap.csv:
- актуальный список компаний S&P 500 (Wikipedia)
- реальная рыночная капитализация каждой компании (yfinance fast_info)

Запуск: python3 fetch_constituents.py
"""
import csv
import io
import sys
import time

import requests
import pandas as pd
import yfinance as yf

WIKI_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
OUT_PATH = "SP500_with_market_cap.csv"

# Тикеры, где формат S&P 500 (точка) отличается от формата Yahoo Finance (дефис)
YAHOO_TICKER_OVERRIDES = {
    "BRK.B": "BRK-B",
    "BF.B": "BF-B",
}


def fetch_constituents():
    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) research-script/1.0"}
    resp = requests.get(WIKI_URL, headers=headers, timeout=15)
    resp.raise_for_status()
    df = pd.read_html(io.StringIO(resp.text))[0]
    df["Symbol"] = df["Symbol"].str.strip()
    return df


def format_market_cap(value):
    if value is None or value <= 0:
        return ""
    if value >= 1_000_000_000_000:
        return f"{value / 1_000_000_000_000:.2f}T"
    return f"{value / 1_000_000_000:.2f}B"


def main():
    print("Загружаю актуальный список компаний S&P 500 с Wikipedia...")
    df = fetch_constituents()
    print(f"Получено {len(df)} компаний")

    rows = []
    failed = []
    for i, row in df.iterrows():
        ticker = row["Symbol"]
        yahoo_ticker = YAHOO_TICKER_OVERRIDES.get(ticker, ticker)
        market_cap = None
        try:
            fi = yf.Ticker(yahoo_ticker).fast_info
            market_cap = fi.get("marketCap") if hasattr(fi, "get") else fi.market_cap
        except Exception as e:
            print(f"  ⚠️ {ticker}: {e}")

        if not market_cap:
            failed.append(ticker)

        rows.append({
            "Symbol": ticker,
            "Security": row["Security"],
            "GICS Sector": row["GICS Sector"],
            "GICS Sub-Industry": row["GICS Sub-Industry"],
            "Headquarters Location": row["Headquarters Location"],
            "Date added": row["Date added"],
            "Founded": row["Founded"],
            "Market Cap": format_market_cap(market_cap),
        })

        if (i + 1) % 25 == 0:
            print(f"  {i + 1}/{len(df)} обработано...")

    with open(OUT_PATH, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "Symbol", "Security", "GICS Sector", "GICS Sub-Industry",
            "Headquarters Location", "Date added", "Founded", "Market Cap"
        ])
        writer.writeheader()
        writer.writerows(rows)

    print(f"\n✅ Записано {len(rows)} компаний в {OUT_PATH}")
    if failed:
        print(f"⚠️ Не удалось получить капитализацию ({len(failed)}): {', '.join(failed)}")


if __name__ == "__main__":
    sys.exit(main())
