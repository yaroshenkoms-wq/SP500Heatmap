#!/usr/bin/env python3
"""
SP500 Pre-Market Signal System
Выдаёт сигналы на покупку в 9:25 NYSE, принудительную продажу в 15:55
"""

import sys
import sqlite3
import json
import logging
from datetime import datetime, time
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass, asdict
from enum import Enum
from textblob import TextBlob

class SignalType(Enum):
    BUY = "BUY_SIGNAL"
    FORCE_SELL = "FORCE_SELL_SIGNAL"

@dataclass
class BuySignal:
    ticker: str
    position_usd: float
    shares: float
    pre_market_price: float
    tp1: float
    tp2: float
    sl: float
    fee_entry: float
    fee_exit: float
    catalyst: str
    timestamp: str

@dataclass
class ForceSellSignal:
    ticker: str
    current_price: float
    estimated_pnl: float
    action: str = "Sell at market"

class DataFetcher:
    def __init__(self, ibkr_host='127.0.0.1', ibkr_port=7497, client_id=1):
        self.ibkr_host = ibkr_host
        self.ibkr_port = ibkr_port
        self.client_id = client_id
        self._connected = False
        logging.info("DataFetcher initialized (IBKR stub)")

    def connect(self):
        self._connected = True
        logging.info("IBKR connected (stub)")

    def get_premarket_price(self, ticker: str) -> Optional[float]:
        mock_prices = {
            'AAPL': 145.20, 'MSFT': 325.50, 'GOOGL': 132.80, 'AMZN': 162.50,
            'TSLA': 170.20, 'META': 310.50, 'NVDA': 115.30, 'JPM': 195.40,
            'V': 265.20, 'PG': 160.30, 'JNJ': 155.60, 'WMT': 68.40,
            'XOM': 112.30, 'BAC': 38.20, 'UNH': 495.80, 'HD': 360.50,
            'CVX': 148.30, 'KO': 62.10, 'PEP': 168.40, 'COST': 735.20,
            'ADBE': 525.60, 'CRM': 245.30, 'NFLX': 620.40, 'DIS': 98.70,
            'ABT': 112.40, 'TMO': 585.20, 'CMCSA': 39.80, 'NEE': 72.50, 'DHR': 245.60
        }
        return mock_prices.get(ticker, None)

    def get_volume_profile(self, ticker: str) -> Dict:
        return {'pre_vol': 250000, 'avg_daily_vol': 800000, 'ratio': 0.3125}

    def get_sp500_tickers(self) -> List[str]:
        return [
            'AAPL', 'MSFT', 'GOOGL', 'AMZN', 'TSLA', 'META', 'NVDA', 'JPM', 'V', 'PG',
            'JNJ', 'WMT', 'XOM', 'BAC', 'UNH', 'HD', 'CVX', 'KO', 'PEP', 'COST',
            'ADBE', 'CRM', 'NFLX', 'DIS', 'ABT', 'TMO', 'CMCSA', 'NEE', 'DHR', 'LLY',
            'ABBV', 'MRK', 'TMO', 'AVGO', 'ACN', 'DHR', 'INTC', 'QCOM', 'TXN', 'AMD',
            'IBM', 'CSCO', 'ORCL', 'INTU', 'NOW', 'UBER', 'BKNG', 'SBUX', 'NKE', 'MCD'
        ]

    def get_historical_prices(self, ticker: str, days: int = 5) -> List[float]:
        # Генерируем падение -6..-10% для всех тикеров
        import random
        random.seed(hash(ticker) % 1000)
        base_price = 150.0
        prices = [base_price]
        for i in range(1, days):
            drop = random.uniform(0.015, 0.035)
            prices.append(prices[-1] * (1 - drop))
        return prices[::-1]

    def fetch_news(self, ticker: str) -> List[Dict]:
        return [{'title': f'{ticker} upgraded by analyst', 'summary': '', 'source': 'Benzinga'}]

class NewsScorer:
    def __init__(self):
        self.negative_keywords = ['miss', 'lawsuit', 'downgrade', 'recall', 'investigation', 'EPS miss']
        self.positive_keywords = ['upgrade', 'buyback', 'FDA approval', 'contract', 'beat', 'raised']

    def analyze(self, news_list: List[Dict]) -> Tuple[str, float]:
        if not news_list:
            return ('NEUTRAL', 0.5)
        
        titles = ' '.join([n['title'].lower() for n in news_list])
        summaries = ' '.join([n.get('summary', '').lower() for n in news_list])
        full_text = titles + ' ' + summaries
        
        has_negative = any(kw.lower() in full_text for kw in self.negative_keywords)
        has_positive = any(kw.lower() in full_text for kw in self.positive_keywords)
        
        blob = TextBlob(full_text)
        polarity = blob.sentiment.polarity
        
        if has_negative and not has_positive:
            return ('NEGATIVE', 0.85)
        if has_positive and not has_negative:
            return ('POSITIVE', 0.75)
        if polarity > 0.2:
            return ('POSITIVE', abs(polarity))
        if polarity < -0.2:
            return ('NEGATIVE', abs(polarity))
        return ('NEUTRAL', 0.5)

class PreMarketAnalyzer:
    @staticmethod
    def is_valid(pre_price: float, prev_close: float, volume_ratio: float, spread_pct: float) -> bool:
        if pre_price > prev_close:
            return False
        if volume_ratio < 1.0:
            return False
        if spread_pct >= 0.5:
            return False
        return True

    @staticmethod
    def get_vwap_stub(ticker: str) -> float:
        return 147.50

class Screener:
    def __init__(self, data_fetcher: DataFetcher):
        self.df = data_fetcher

    def get_candidates(self) -> List[Tuple[str, float]]:
        all_tickers = self.df.get_sp500_tickers()
        candidates = []
        for ticker in all_tickers:
            closes = self.df.get_historical_prices(ticker, days=4)
            if len(closes) < 3:
                continue
            two_days_ago = closes[-3]
            pre_price = self.df.get_premarket_price(ticker)
            if pre_price is None:
                continue
            drop_pct = (pre_price - two_days_ago) / two_days_ago * 100
            if drop_pct <= -5.0:
                candidates.append((ticker, abs(drop_pct)))
        candidates.sort(key=lambda x: x[1], reverse=True)
        return candidates

class CommissionCalculator:
    @staticmethod
    def estimate(shares: int, price: float, is_entry: bool = True) -> float:
        gross = shares * price
        commission = max(0.0035 * shares, 0.35)
        external = gross * 0.0002
        total = commission + external
        return round(total, 2)

class RiskManager:
    @staticmethod
    def calculate_levels(entry_price: float, volatility_mode: str = 'normal') -> Dict:
        if volatility_mode == 'high':
            sl_pct = -2.5
        else:
            sl_pct = -1.5
        return {
            'tp1': round(entry_price * 1.03, 2),
            'tp2': round(entry_price * 1.05, 2),
            'sl': round(entry_price * (1 + sl_pct/100), 2),
            'sl_pct': sl_pct
        }

    @staticmethod
    def force_sell_time() -> bool:
        now = datetime.now()
        target = time(15, 55)
        return now.time() >= target

class Notifier:
    @staticmethod
    def send_buy_signal(signal: BuySignal):
        msg = f"""
[BUY SIGNAL] 9:25 NYSE
Ticker: {signal.ticker}
Position: ${signal.position_usd:.0f} ({signal.shares:.2f} shares)
Pre-market price: ${signal.pre_market_price:.2f}
TP: ${signal.tp1:.2f} (+3%) / ${signal.tp2:.2f} (+5%)
SL: ${signal.sl:.2f} ({signal.sl/signal.pre_market_price - 1:.1%})
IBKR fee est.: ${signal.fee_entry:.2f} entry + ${signal.fee_exit:.2f} exit
Catalyst: {signal.catalyst}
Force sell: 15:55
"""
        print(msg)

    @staticmethod
    def send_force_sell(signal: ForceSellSignal):
        msg = f"""
[FORCE SELL SIGNAL] 15:55 NYSE
Ticker: {signal.ticker}
Current price: ${signal.current_price:.2f}
P&L est.: ${signal.estimated_pnl:.2f}
Action: {signal.action}
"""
        print(msg)

class SignalEngine:
    def __init__(self):
        self.data = DataFetcher()
        self.data.connect()
        self.news_scorer = NewsScorer()
        self.screener = Screener(self.data)
        self.commission = CommissionCalculator()
        self.risk = RiskManager()
        self.notifier = Notifier()
        self.db_conn = sqlite3.connect('trading_signals.db')
        self._init_db()

    def _init_db(self):
        cursor = self.db_conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS signals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT,
                ticker TEXT,
                type TEXT,
                details TEXT
            )
        ''')
        self.db_conn.commit()

    def _log_signal(self, signal_type: str, ticker: str, details: Dict):
        cursor = self.db_conn.cursor()
        cursor.execute(
            "INSERT INTO signals (timestamp, ticker, type, details) VALUES (?, ?, ?, ?)",
            (datetime.now().isoformat(), ticker, signal_type, json.dumps(details))
        )
        self.db_conn.commit()

    def run_premarket_screening(self, max_signals: int = 10):
        print("\n=== Запуск скрининга в 9:25 NYSE ===\n")
        candidates = self.screener.get_candidates()
        print(f"Найдено кандидатов с падением -5%: {len(candidates)}")
        final_signals = []

        for ticker, drop_pct in candidates:
            if len(final_signals) >= max_signals:
                break

            pre_price = self.data.get_premarket_price(ticker)
            if pre_price is None:
                continue

            news = self.data.fetch_news(ticker)
            sentiment, conf = self.news_scorer.analyze(news)
            if sentiment == 'NEGATIVE':
                print(f"{ticker}: rejected due to negative news")
                continue

            vol_profile = self.data.get_volume_profile(ticker)
            volume_ratio = vol_profile.get('ratio', 0.5)
            spread_pct = 0.2

            hist_closes = self.data.get_historical_prices(ticker, 1)
            prev_close = hist_closes[-1] if hist_closes else pre_price * 0.98
            valid = PreMarketAnalyzer.is_valid(pre_price, prev_close, volume_ratio, spread_pct)
            if not valid:
                print(f"{ticker}: failed pre-market validation")
                continue

            position_usd = 1000.0
            shares = position_usd / pre_price
            fee_entry = self.commission.estimate(int(shares), pre_price, is_entry=True)
            fee_exit = self.commission.estimate(int(shares), pre_price, is_entry=False)
            levels = self.risk.calculate_levels(pre_price)
            catalyst = f"dropped {drop_pct:.1f}% in 2 days, news: {sentiment}"

            signal = BuySignal(
                ticker=ticker,
                position_usd=position_usd,
                shares=shares,
                pre_market_price=pre_price,
                tp1=levels['tp1'],
                tp2=levels['tp2'],
                sl=levels['sl'],
                fee_entry=fee_entry,
                fee_exit=fee_exit,
                catalyst=catalyst,
                timestamp=datetime.now().isoformat()
            )
            final_signals.append(signal)
            self.notifier.send_buy_signal(signal)
            self._log_signal("BUY", ticker, asdict(signal))

        print(f"\n=== Итого сигналов: {len(final_signals)} из {max_signals} максимально ===")
        return final_signals

    def run_force_sell_check(self):
        print("\n=== Принудительная продажа в 15:55 NYSE ===\n")
        cursor = self.db_conn.cursor()
        cursor.execute("SELECT ticker, details FROM signals WHERE type='BUY' ORDER BY id DESC LIMIT 10")
        rows = cursor.fetchall()
        
        for row in rows:
            ticker = row[0]
            details = json.loads(row[1])
            entry_price = details.get('pre_market_price', 150.0)
            current_price = self.data.get_premarket_price(ticker)
            if current_price is None:
                current_price = entry_price * 1.01
            pnl = (current_price - entry_price) * (1000 / entry_price)
            force = ForceSellSignal(ticker, current_price, pnl)
            self.notifier.send_force_sell(force)
            self._log_signal("FORCE_SELL", ticker, asdict(force))

def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
    engine = SignalEngine()

    if len(sys.argv) > 1:
        mode = sys.argv[1]
        if mode == 'screening':
            engine.run_premarket_screening()
        elif mode == 'forcesell':
            engine.run_force_sell_check()
        else:
            print("Usage: python main.py screening | forcesell")
    else:
        print("No mode specified. Run with 'screening' or 'forcesell'")

if __name__ == "__main__":
    main()
