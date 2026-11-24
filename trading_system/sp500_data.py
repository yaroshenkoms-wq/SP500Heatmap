#!/usr/bin/env python3
"""
S&P 500 Data Module
Загружает актуальный список всех 503 акций S&P 500 и их котировки через IBKR API
"""

import asyncio
import csv
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from dataclasses import dataclass

# Установка: pip3 install pandas requests beautifulsoup4 ib-insync
import pandas as pd
import requests
from bs4 import BeautifulSoup
from ib_insync import IB, Stock, util

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


@dataclass
class StockQuote:
    """Котировка акции"""
    ticker: str
    name: str
    sector: str
    last_price: float
    bid: float
    ask: float
    volume: int
    timestamp: str


class SP500DataLoader:
    """
    Загрузчик данных S&P 500
    Источник: Wikipedia (503 акции, включая dual-class shares)
    """
    
    # Wikipedia URL с составом S&P 500
    WIKI_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
    
    def __init__(self, cache_file: str = "sp500_constituents.csv"):
        self.cache_file = Path(cache_file)
        self.constituents: List[Dict] = []
        self.tickers: Set[str] = set()
        
    def fetch_constituents(self, use_cache: bool = True) -> List[Dict]:
        """
        Загружает список компаний S&P 500 с Wikipedia.
        Возвращает список словарей с ключами: ticker, name, sector, etc.
        Всего 503 записи (включая GOOGL/GOOG, FOXA/FOX, NWS/NWSA и т.д.)
        """
        if use_cache and self.cache_file.exists():
            logger.info(f"Загрузка из кэша: {self.cache_file}")
            df = pd.read_csv(self.cache_file)
            self.constituents = df.to_dict('records')
            self.tickers = set(df['ticker'].values)
            logger.info(f"Загружено {len(self.constituents)} компаний из кэша")
            return self.constituents
        
        logger.info(f"Скачивание состава S&P 500 с Wikipedia...")
        
        try:
            # Читаем таблицу с Wikipedia
            headers = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'}
try:
    req = requests.get(self.WIKI_URL, headers=headers)
    req.raise_for_status()
    tables = pd.read_html(req.text)
except Exception as e:
    logger.error(f"Ошибка загрузки с Wikipedia: {e}")
    raise
            # Первая таблица на странице - это состав индекса
            df = tables[0]
            
            # Нормализуем колонки
            # Ожидаемые колонки: 'Symbol', 'Security', 'GICS Sector', ...
            df.columns = [col.strip() for col in df.columns]
            
            # Создаём унифицированный список
            self.constituents = []
            for _, row in df.iterrows():
                # Определяем ticker (может быть в колонке 'Symbol')
                ticker_col = None
                for col in ['Symbol', 'Ticker', 'symbol']:
                    if col in df.columns:
                        ticker_col = col
                        break
                
                if ticker_col is None:
                    raise ValueError("Не найдена колонка с тикерами")
                
                ticker = str(row[ticker_col]).strip()
                # Пропускаем пустые или NaN
                if not ticker or ticker == 'nan':
                    continue
                    
                # Получаем название компании
                name_col = 'Security' if 'Security' in df.columns else 'Name'
                name = str(row[name_col]).strip() if name_col in df.columns else ''
                
                # Сектор
                sector_col = 'GICS Sector' if 'GICS Sector' in df.columns else 'Sector'
                sector = str(row[sector_col]).strip() if sector_col in df.columns else ''
                
                self.constituents.append({
                    'ticker': ticker,
                    'name': name,
                    'sector': sector,
                    'date_added': row.get('Date added', ''),
                    'cik': row.get('CIK', ''),
                })
                self.tickers.add(ticker)
            
            # Сохраняем в кэш
            df_save = pd.DataFrame(self.constituents)
            df_save.to_csv(self.cache_file, index=False)
            logger.info(f"Сохранено {len(self.constituents)} компаний в {self.cache_file}")
            
            # Проверка количества (должно быть около 503-505)
            if len(self.constituents) < 490:
                logger.warning(f"Загружено только {len(self.constituents)} компаний, возможно таблица изменилась")
            else:
                logger.info(f"Успешно загружено {len(self.constituents)} компаний")
            
            return self.constituents
            
        except Exception as e:
            logger.error(f"Ошибка загрузки с Wikipedia: {e}")
            raise
    
    def get_all_tickers(self) -> List[str]:
        """Возвращает список всех тикеров (503 шт)"""
        if not self.tickers:
            self.fetch_constituents()
        return sorted(list(self.tickers))
    
    def get_tickers_by_sector(self, sector: str) -> List[str]:
        """Возвращает тикеры по сектору"""
        if not self.constituents:
            self.fetch_constituents()
        return [c['ticker'] for c in self.constituents if c.get('sector') == sector]
    
    def get_sectors(self) -> Set[str]:
        """Возвращает все сектора"""
        if not self.constituents:
            self.fetch_constituents()
        return {c.get('sector') for c in self.constituents if c.get('sector')}


class IBKRRealtimeQuotes:
    """
    Получение реальных котировок через IBKR TWS/IB Gateway
    Поддерживает потоковую передачу для множества тикеров (~100+)
    """
    
    def __init__(self, host: str = '127.0.0.1', port: int = 7497, client_id: int = 1):
        """
        Параметры подключения:
        - port 7497: TWS Paper Trading
        - port 7496: TWS Live Trading
        - port 4002: IB Gateway Paper
        - port 4001: IB Gateway Live
        """
        self.host = host
        self.port = port
        self.client_id = client_id
        self.ib = IB()
        self.connected = False
        self.quotes: Dict[str, Dict] = {}
        
    def connect(self) -> bool:
        """Подключение к TWS/IB Gateway"""
        try:
            self.ib.connect(self.host, self.port, clientId=self.client_id)
            self.connected = True
            logger.info(f"Connected to IBKR at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to IBKR: {e}")
            logger.info("Убедитесь, что TWS/IB Gateway запущен и API включён")
            return False
    
    def disconnect(self):
        """Отключение"""
        if self.connected:
            self.ib.disconnect()
            self.connected = False
            logger.info("Disconnected from IBKR")
    
    def get_snapshot_prices(self, tickers: List[str]) -> Dict[str, float]:
        """
        Получает snapshot-цены для списка тикеров.
        Snapshot быстрее потоковой подписки для большого количества тикеров,
        но имеет ограничение ~50 запросов в секунду.
        
        Для 503 тикеров нужно будет делать пачками.
        """
        if not self.connected:
            raise ConnectionError("Not connected to IBKR")
        
        results = {}
        contracts = [Stock(t, 'SMART', 'USD') for t in tickers]
        
        # Метод 1: массовая подписка (до 100 тикеров одновременно)
        # Более эффективно, чем по одному запросу
        
        # Используем MarketData для потоковых данных
        # Создаём словарь для хранения последних цен
        ticker_id_map = {}
        
        for i, contract in enumerate(contracts):
            ticker_id = i + 1
            ticker_id_map[ticker_id] = contract.symbol
            # Запрашиваем маркет-дату (snapshot=True для однократного запроса)
            # Внимание: snapshot=True может не вернуть все поля
            self.ib.reqMktData(contract, '', snapshot=True, genericTickList='')
        
        # Ждём получения данных (несколько секунд)
        import time
        time.sleep(3)
        
        # Собираем результаты
        for ticker_id, symbol in ticker_id_map.items():
            contract = contracts[ticker_id - 1]
            # Получаем последние данные
            ticker_obj = self.ib.ticker(contract)
            if ticker_obj and ticker_obj.last > 0:
                results[symbol] = ticker_obj.last
            elif ticker_obj and ticker_obj.bid > 0:
                results[symbol] = ticker_obj.bid
            else:
                results[symbol] = None
        
        return results
    
    def stream_quotes(self, tickers: List[str], callback):
        """
        Потоковое получение котировок для списка тикеров.
        
        Лимиты IBKR:
        - до 100 тикеров одновременно для потоковой подписки (default)
        - при увеличении лимита через IBKR - до 300-500
        
        Для 503 тикеров оптимально:
        - Использовать snapshot-запросы пакетами по 50-100 тикеров
        - Или разделить на несколько потоков с разными client_id
        """
        if not self.connected:
            raise ConnectionError("Not connected to IBKR")
        
        contracts = [Stock(t, 'SMART', 'USD') for t in tickers]
        
        # Подписываемся на потоковые данные
        for contract in contracts:
            self.ib.reqMktData(contract, '', snapshot=False, genericTickList='')
        
        # Обработчик обновлений
        def on_pending_tickers(tickers):
            for ticker in tickers:
                if ticker.contract and ticker.contract.symbol:
                    callback({
                        'ticker': ticker.contract.symbol,
                        'last': ticker.last,
                        'bid': ticker.bid,
                        'ask': ticker.ask,
                        'volume': ticker.volume,
                        'time': datetime.now().isoformat()
                    })
        
        self.ib.pendingTickersEvent += on_pending_tickers
        logger.info(f"Streaming quotes for {len(tickers)} tickers")
        
        # Запускаем цикл обработки
        util.startLoop()
        
        return self.ib
    
    def get_historical_bars(self, ticker: str, duration: str = "1 D", bar_size: str = "5 mins"):
        """
        Получение исторических данных
        
        duration: "1 D", "1 M", "1 Y"
        bar_size: "1 min", "5 mins", "1 hour", "1 day"
        """
        if not self.connected:
            raise ConnectionError("Not connected to IBKR")
        
        contract = Stock(ticker, 'SMART', 'USD')
        bars = self.ib.reqHistoricalData(
            contract,
            endDateTime='',
            durationStr=duration,
            barSizeSetting=bar_size,
            whatToShow='TRADES',
            useRTH=True,
            formatDate=1
        )
        
        return bars


class SP500QuoteCollector:
    """
    Основной класс для сбора котировок всех 503 акций S&P 500
    """
    
    def __init__(self, ibkr_port: int = 7497):
        self.loader = SP500DataLoader()
        self.ibkr = IBKRRealtimeQuotes(port=ibkr_port)
        self.quotes_cache: Dict[str, StockQuote] = {}
        
    def update_constituents(self):
        """Обновляет локальный список компаний S&P 500"""
        self.loader.fetch_constituents(use_cache=False)
        logger.info(f"Updated constituents: {len(self.loader.tickers)} tickers")
        
    def get_all_quotes_snapshot(self) -> Dict[str, float]:
        """
        Получает snapshot-цены для ВСЕХ акций S&P 500.
        
        Стратегия: разбиваем на пачки по 50 тикеров из-за лимитов IBKR.
        Каждая пачка ~3 секунды, всего ~30 секунд на все 503 тикера.
        """
        if not self.ibkr.connected:
            if not self.ibkr.connect():
                logger.error("Cannot connect to IBKR")
                return {}
        
        tickers = self.loader.get_all_tickers()
        logger.info(f"Fetching quotes for {len(tickers)} tickers...")
        
        all_prices = {}
        batch_size = 50
        
        for i in range(0, len(tickers), batch_size):
            batch = tickers[i:i+batch_size]
            logger.info(f"Batch {i//batch_size + 1}: {batch[:3]}... ({len(batch)} tickers)")
            
            try:
                batch_prices = self.ibkr.get_snapshot_prices(batch)
                all_prices.update(batch_prices)
            except Exception as e:
                logger.error(f"Error fetching batch {i//batch_size + 1}: {e}")
            
            # Пауза между пачками, чтобы не превысить лимиты
            import time
            time.sleep(2)
        
        logger.info(f"Received {len([p for p in all_prices.values() if p])} valid quotes")
        return all_prices
    
    def save_quotes_to_csv(self, quotes: Dict[str, float], filename: str = None):
        """Сохраняет котировки в CSV"""
        if filename is None:
            filename = f"sp500_quotes_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
        
        data = []
        for ticker, price in quotes.items():
            # Находим информацию о компании
            company_info = next((c for c in self.loader.constituents if c['ticker'] == ticker), {})
            data.append({
                'ticker': ticker,
                'price': price,
                'name': company_info.get('name', ''),
                'sector': company_info.get('sector', ''),
                'timestamp': datetime.now().isoformat()
            })
        
        df = pd.DataFrame(data)
        df.to_csv(filename, index=False)
        logger.info(f"Saved {len(data)} quotes to {filename}")
        return filename


# ============================================================
# Пример использования
# ============================================================

def main():
    """Пример: загрузка списка S&P 500 и получение котировок"""
    
    # 1. Загружаем список всех 503 компаний
    print("=" * 60)
    print("ШАГ 1: Загрузка списка S&P 500")
    print("=" * 60)
    
    loader = SP500DataLoader()
    constituents = loader.fetch_constituents()
    tickers = loader.get_all_tickers()
    
    print(f"Загружено компаний: {len(constituents)}")
    print(f"Уникальных тикеров: {len(tickers)}")
    print(f"Первые 10 тикеров: {tickers[:10]}")
    
    # 2. Подключение к IBKR и получение котировок (опционально)
    print("\n" + "=" * 60)
    print("ШАГ 2: Получение котировок через IBKR")
    print("=" * 60)
    print("ВНИМАНИЕ: Убедитесь, что TWS/IB Gateway запущен и API включён!")
    print("Порт по умолчанию: 7497 (TWS Paper Trading)")
    
    response = input("\nПолучить котировки через IBKR? (y/n): ")
    
    if response.lower() == 'y':
        collector = SP500QuoteCollector(ibkr_port=7497)
        quotes = collector.get_all_quotes_snapshot()
        
        # Подсчёт успешных
        valid_quotes = {k: v for k, v in quotes.items() if v}
        print(f"\nПолучено котировок: {len(valid_quotes)} из {len(tickers)}")
        
        if valid_quotes:
            collector.save_quotes_to_csv(valid_quotes)
            
            # Вывод топ-10 по цене
            top10 = sorted(valid_quotes.items(), key=lambda x: x[1], reverse=True)[:10]
            print("\nТоп-10 по цене:")
            for ticker, price in top10:
                print(f"  {ticker}: ${price:.2f}")
    
    # 3. Сохранение списка компаний в CSV
    print("\n" + "=" * 60)
    print("ШАГ 3: Сохранение списка компаний")
    print("=" * 60)
    
    df = pd.DataFrame(constituents)
    df.to_csv("sp500_full_list.csv", index=False)
    print(f"Список всех {len(constituents)} компаний сохранён в sp500_full_list.csv")


if __name__ == "__main__":
    main()
