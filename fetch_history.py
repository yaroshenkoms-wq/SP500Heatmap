"""
Бэкфилл дневных цен закрытия за 1 год для всех тикеров S&P 500 через yfinance.
Сохраняет в SQLite (history.db), таблица daily_closes(ticker, date, close).

Запуск: python3 fetch_history.py
"""
import csv
import sqlite3
import sys
import time

import yfinance as yf

DB_PATH = "history.db"
CSV_PATH = "SP500_with_market_cap.csv"
CHUNK_SIZE = 80


def load_tickers():
    tickers = []
    with open(CSV_PATH, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ticker = row["Symbol"].strip()
            if ticker:
                tickers.append(ticker)
    return tickers


def init_db(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS daily_closes (
            ticker TEXT NOT NULL,
            date TEXT NOT NULL,
            close REAL NOT NULL,
            PRIMARY KEY (ticker, date)
        )
        """
    )
    conn.commit()


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def main():
    tickers = load_tickers()
    print(f"Тикеров к загрузке: {len(tickers)}")

    conn = sqlite3.connect(DB_PATH)
    init_db(conn)

    ok_count = 0
    failed = []

    for chunk in chunked(tickers, CHUNK_SIZE):
        print(f"Загружаю чанк из {len(chunk)} тикеров: {chunk[0]}..{chunk[-1]}")
        try:
            data = yf.download(
                chunk,
                period="1y",
                interval="1d",
                group_by="ticker",
                auto_adjust=True,
                progress=False,
                threads=True,
            )
        except Exception as e:
            print(f"  Ошибка загрузки чанка: {e}")
            failed.extend(chunk)
            continue

        rows = []
        for ticker in chunk:
            try:
                if len(chunk) == 1:
                    series = data["Close"]
                else:
                    series = data[ticker]["Close"]
                series = series.dropna()
                if series.empty:
                    failed.append(ticker)
                    continue
                for date, close in series.items():
                    rows.append((ticker, date.strftime("%Y-%m-%d"), float(close)))
                ok_count += 1
            except Exception:
                failed.append(ticker)

        conn.executemany(
            "INSERT OR REPLACE INTO daily_closes (ticker, date, close) VALUES (?, ?, ?)",
            rows,
        )
        conn.commit()
        time.sleep(0.5)

    print(f"\n✅ Успешно загружено тикеров: {ok_count}")
    if failed:
        print(f"⚠️ Не удалось загрузить ({len(failed)}): {', '.join(failed)}")

    cur = conn.execute("SELECT COUNT(DISTINCT ticker), COUNT(*) FROM daily_closes")
    tickers_n, rows_n = cur.fetchone()
    print(f"В базе: {tickers_n} тикеров, {rows_n} строк")
    conn.close()


if __name__ == "__main__":
    sys.exit(main())
