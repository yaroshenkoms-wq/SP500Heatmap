"""
Крипта (crypto50) и ETF (etf50) — два «индекса» региона assets.

Крипта: список и капитализация — CoinGecko free API (одним запросом /coins/markets, per_page=100).
  Из карты убираем (исключения документированы ниже):
   * стейблкоины и прочие привязанные к доллару/евро токены (USDT, USDC, DAI, USDe, ...): ловим по списку и по цене
     (цена ~1 и почти не двигается за 7 дней);
   * токенизированные деньги/фонды/золото (BUIDL, USYC, USDY, XAUt, PAXG, ...);
   * обёрнутые и застейканные дубликаты (WBTC, WETH, stETH, weETH, cbBTC, ... — по id и по словам Wrapped/Staked/Bridged/Peg в названии).
  Остаётся топ-50 по капитализации. Дневные закрытия — Yahoo (BTC-USD и т.п., 1 год, один пакетный запрос на 60 символов):
  дешевле и надёжнее, чем 50 вызовов CoinGecko market_chart на бесплатном лимите (~30/мин). Монеты, которых нет
  на Yahoo или у которых цена Yahoo расходится с CoinGecko больше чем на 20% (чужой тикер с тем же именем),
  отбрасываются, на их место берётся следующая.
  Категория (sector) — из справочника CATEGORY_BY_ID (CoinGecko free не отдаёт категорию в /coins/markets,
  а запрос категорий по каждой монете слишком дорог); неизвестное -> "Other". subsector = sector.
  Сегодняшняя (ещё идущая) дневная свеча хранится как последняя цена: рынок 24/7, периоды считаем от неё.

ETF: ~50 крупнейших ETF США, список зашит ниже (Sector = класс активов, Subsector = группа),
  MarketCap = AUM; при запуске refresh_etf_aum() подтягивает totalAssets из Yahoo (с паузой), иначе — зашитое значение.

Запуск: python3 fetch_assets.py crypto | etf
"""
import csv
import json
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CRYPTO_CSV = BASE_DIR / "indices" / "crypto50.csv"
ETF_CSV = BASE_DIR / "indices" / "etf50.csv"
WORLD_DB = str(BASE_DIR / "history_world.db")
COINGECKO_URL = ("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc"
                 "&per_page=100&page=1&price_change_percentage=24h,7d,30d,200d,1y")
CSV_COLUMNS = ["Symbol", "Security", "Sector", "Subsector", "MarketCap", "Currency"]
TOP_N = 50
CANDIDATES = 65  # столько проверяем на Yahoo, чтобы после отсева осталось 50

STABLE_IDS = {
    "tether", "usd-coin", "usds", "ethena-usde", "dai", "usd1-wlfi", "ripple-usd", "global-dollar", "paypal-usd",
    "falcon-finance", "united-stables", "usdd", "bfusd", "open-usd", "usdgo", "first-digital-usd", "true-usd",
    "stasis-eur", "euro-coin", "eurc", "gemini-dollar", "paxos-standard", "binance-usd", "frax", "usdx", "susds",
    "ethena-staked-usde", "usdtb", "usual-usd", "resolv-usr", "gho", "crvusd", "liquity-usd", "usda", "usdai",
}
# токенизированные деньги/облигации/золото: привязаны к активу, не «монеты»
PEGGED_ASSET_IDS = {
    "tether-gold", "pax-gold", "figure-heloc", "ondo-us-dollar-yield", "hashnote-usyc", "usyc",
    "blackrock-usd-institutional-digital-liquidity-fund", "spiko-amundi-overnight-swap-fund-eur",
    "superstate-short-duration-us-government-securities-fund-ustb", "franklin-onchain-u-s-government-money-fund",
}
WRAPPED_IDS = {
    "wrapped-bitcoin", "weth", "wrapped-steth", "staked-ether", "wrapped-eeth", "wrapped-beacon-eth", "coinbase-wrapped-btc",
    "binance-staked-sol", "jito-staked-sol", "rocket-pool-eth", "ether-fi-staked-eth", "wrapped-bnb", "bridged-usdc-polygon-pos-bridge",
    "lombard-staked-btc", "solv-btc", "binance-bitcoin", "kelp-dao-restaked-eth", "mantle-staked-ether", "wrapped-solana",
    "coinbase-wrapped-staked-eth", "sbtc", "tbtc", "kinetiq-staked-hype", "stakewise-staked-ether", "renzo-restaked-eth",
}
WRAPPED_WORDS = ("wrapped", "staked", "bridged", "restaked", "binance-peg", "liquid staking")

# Неоднозначные монеты: тикер Yahoo не совпадает с «СИМВОЛ-USD»
YAHOO_OVERRIDE = {
    "uniswap": "UNI7083-USD", "sui": "SUI20947-USD", "the-open-network": "TON11419-USD", "aptos": "APT21794-USD",
    "hyperliquid": "HYPE32196-USD", "pepe": "PEPE24478-USD", "arbitrum": "ARB11841-USD", "bittensor": "TAO22974-USD",
    "mantle": "MNT27075-USD", "world-liberty-financial": "WLFI33251-USD", "aave": "AAVE-USD", "kaspa": "KAS-USD",
    "polygon-ecosystem-token": "POL28321-USD", "ondo-finance": "ONDO-USD", "ethena": "ENA-USD",
    "worldcoin-wld": "WLD-USD", "jupiter-exchange-solana": "JUP29210-USD", "internet-computer": "ICP-USD",
    "quant-network": "QNT-USD", "okb": "OKB-USD", "sky": "SKY33038-USD", "morpho": "MORPHO-USD",
}

_L1 = "Layer 1"
_SC = "Smart Contract Platforms"
_PAY = "Payments"
_EX = "Exchange Tokens"
_DEFI = "DeFi"
_MEME = "Memes"
_AI = "AI"
_L2 = "Layer 2"
_PRIV = "Privacy"
CATEGORY_BY_ID = {
    "bitcoin": _L1, "ethereum-classic": _L1, "kaspa": _L1, "bitcoin-cash": _PAY, "litecoin": _PAY, "ripple": _PAY,
    "stellar": _PAY, "hedera-hashgraph": _SC, "monero": _PRIV, "zcash": _PRIV, "dash": _PRIV,
    "ethereum": _SC, "solana": _SC, "cardano": _SC, "avalanche-2": _SC, "tron": _SC, "near": _SC, "sui": _SC,
    "aptos": _SC, "polkadot": _SC, "internet-computer": _SC, "the-open-network": _SC, "cosmos": _SC, "algorand": _SC,
    "sei-network": _SC, "canton-network": _SC, "vechain": _SC, "filecoin": _SC, "stacks": _L2,
    "arbitrum": _L2, "optimism": _L2, "mantle": _L2, "polygon-ecosystem-token": _L2, "starknet": _L2,
    "binancecoin": _EX, "leo-token": _EX, "whitebit": _EX, "crypto-com-chain": _EX, "okb": _EX,
    "kucoin-shares": _EX, "bitget-token": _EX, "htx-dao": _EX, "gatechain-token": _EX,
    "chainlink": _DEFI, "uniswap": _DEFI, "aave": _DEFI, "ondo-finance": _DEFI, "ethena": _DEFI, "morpho": _DEFI,
    "jupiter-exchange-solana": _DEFI, "sky": _DEFI, "hyperliquid": _DEFI, "world-liberty-financial": _DEFI,
    "aster-2": _DEFI, "pendle": _DEFI, "lido-dao": _DEFI, "maker": _DEFI, "just": _DEFI, "curve-dao-token": _DEFI,
    "dogecoin": _MEME, "shiba-inu": _MEME, "pepe": _MEME, "bonk": _MEME, "official-trump": _MEME, "pump-fun": _MEME,
    "floki": _MEME, "dogwifcoin": _MEME,
    "bittensor": _AI, "render-token": _AI, "fetch-ai": _AI, "artificial-superintelligence-alliance": _AI,
    "virtual-protocol": _AI, "worldcoin-wld": _AI, "near-protocol": _SC, "venice-token": _AI,
}


def is_excluded(coin):
    """Стейблкоин / токенизированный актив / обёрнутый или застейканный дубликат (см. docstring модуля)."""
    cid = coin.get("id", "")
    name = (coin.get("name") or "").lower()
    if cid in STABLE_IDS or cid in PEGGED_ASSET_IDS or cid in WRAPPED_IDS:
        return True
    if any(w in name or w in cid for w in WRAPPED_WORDS):
        return True
    price = coin.get("current_price") or 0
    sym = (coin.get("symbol") or "").lower()
    if sym.startswith("usd") or sym.endswith("usd") or "usd" in name.split():
        if 0.9 < price < 1.3:
            return True
    d7 = coin.get("price_change_percentage_7d_in_currency")
    if 0.97 < price < 1.03 and d7 is not None and abs(d7) < 1.5:
        return True  # цена прибита к доллару
    return False


def yahoo_ticker(coin):
    return YAHOO_OVERRIDE.get(coin["id"]) or f"{coin['symbol'].upper()}-USD"


def build_crypto_rows(markets, top_n=TOP_N, candidates=None):
    """Чистая функция: ответ CoinGecko -> строки CSV (без проверки Yahoo), топ top_n по капитализации
    без исключённых. candidates — сколько вернуть сверх (для запаса на отсев Yahoo)."""
    rows = []
    for c in sorted(markets, key=lambda m: m.get("market_cap") or 0, reverse=True):
        if not c.get("symbol") or not c.get("market_cap") or is_excluded(c):
            continue
        cat = CATEGORY_BY_ID.get(c["id"], "Other")
        rows.append({"Symbol": yahoo_ticker(c), "Security": c.get("name") or c["symbol"].upper(), "Sector": cat,
                     "Subsector": cat, "MarketCap": int(c["market_cap"]), "Currency": "USD",
                     "_price": c.get("current_price")})
        if len(rows) >= (candidates or top_n):
            break
    return rows


def write_csv(path, rows):
    tmp = Path(str(path) + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    tmp.replace(path)


def fetch_markets(url=COINGECKO_URL, retries=3):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "sp500heatmap-server", "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except Exception as e:
            last = e
            time.sleep(10 * (attempt + 1))
    raise RuntimeError(f"CoinGecko недоступен: {last}")


def refresh_crypto(db_path=WORLD_DB, csv_path=CRYPTO_CSV, markets=None, downloader=None):
    """Обновляет indices/crypto50.csv (состав и капитализация) и закрытия монет в history_world.db.
    Возвращает {"coins": n, "dropped": [...], "rows_written": n}. Ошибка CoinGecko — исключение, файлы не тронуты."""
    import fetch_world
    markets = markets if markets is not None else fetch_markets()
    cand = build_crypto_rows(markets, candidates=CANDIDATES)
    notes = []
    vol_series = {}
    closes = fetch_world.download_all([c["Symbol"] for c in cand], downloader or fetch_world.default_download,
                                      notes, vol_series)
    keep, dropped = [], []
    for c in cand:
        s = closes.get(c["Symbol"])
        price = c.get("_price")
        if s is None or s.empty:
            dropped.append(f"{c['Symbol']}: нет на Yahoo")
        elif price and not 0.8 <= float(s.iloc[-1]) / price <= 1.25:
            dropped.append(f"{c['Symbol']}: цена Yahoo {float(s.iloc[-1]):.4g} != CoinGecko {price:.4g}")
        else:
            keep.append(c)
    keep = keep[:TOP_N]
    if len(keep) < TOP_N * 0.8:
        raise RuntimeError(f"Крипта: годных монет только {len(keep)} — ничего не пишем")
    conn = sqlite3.connect(db_path, timeout=30)
    fetch_world.init_db(conn)
    n = 0
    for c in keep:
        rows = [(c["Symbol"], ts.strftime("%Y-%m-%d"), float(v)) for ts, v in closes[c["Symbol"]].items() if float(v) > 0]
        conn.executemany("INSERT OR REPLACE INTO daily_closes (ticker, date, close) VALUES (?,?,?)", rows)
        n += len(rows)
    conn.commit()
    conn.close()
    try:  # объём крипты у Yahoo — уже в долларах за сутки
        import volumes
        volumes.save_series(volumes.path_next_to(db_path), {c["Symbol"]: vol_series[c["Symbol"]] for c in keep
                                                            if c["Symbol"] in vol_series})
    except Exception as e:
        notes.append(f"объёмы не записаны: {e}")
    write_csv(csv_path, keep)
    return {"coins": len(keep), "dropped": dropped, "rows_written": n, "notes": notes}


# ---------------------------------------------------------------- ETF

# (тикер, название, класс активов, группа, AUM в млрд USD — запасное значение, обновляется из Yahoo)
ETF_LIST = [
    ("SPY", "SPDR S&P 500 ETF Trust", "US equity", "Large cap blend", 650),
    ("VOO", "Vanguard S&P 500 ETF", "US equity", "Large cap blend", 750),
    ("IVV", "iShares Core S&P 500 ETF", "US equity", "Large cap blend", 650),
    ("VTI", "Vanguard Total Stock Market ETF", "US equity", "Total market", 520),
    ("QQQ", "Invesco QQQ Trust", "US equity", "Large cap growth", 380),
    ("VUG", "Vanguard Growth ETF", "US equity", "Large cap growth", 190),
    ("VTV", "Vanguard Value ETF", "US equity", "Large cap value", 200),
    ("IWF", "iShares Russell 1000 Growth ETF", "US equity", "Large cap growth", 110),
    ("IWM", "iShares Russell 2000 ETF", "US equity", "Small cap", 70),
    ("IJH", "iShares Core S&P Mid-Cap ETF", "US equity", "Mid cap", 95),
    ("IJR", "iShares Core S&P Small-Cap ETF", "US equity", "Small cap", 85),
    ("SCHD", "Schwab US Dividend Equity ETF", "US equity", "Dividend", 70),
    ("ITOT", "iShares Core S&P Total U.S. Stock Market ETF", "US equity", "Total market", 75),
    ("QQQM", "Invesco NASDAQ 100 ETF", "US equity", "Large cap growth", 60),
    ("DIA", "SPDR Dow Jones Industrial Average ETF", "US equity", "Large cap blend", 35),
    ("VIG", "Vanguard Dividend Appreciation ETF", "US equity", "Dividend", 90),
    ("VO", "Vanguard Mid-Cap ETF", "US equity", "Mid cap", 80),
    ("VEA", "Vanguard FTSE Developed Markets ETF", "International equity", "Developed markets", 160),
    ("IEFA", "iShares Core MSCI EAFE ETF", "International equity", "Developed markets", 130),
    ("EFA", "iShares MSCI EAFE ETF", "International equity", "Developed markets", 65),
    ("VWO", "Vanguard FTSE Emerging Markets ETF", "International equity", "Emerging markets", 90),
    ("IEMG", "iShares Core MSCI Emerging Markets ETF", "International equity", "Emerging markets", 100),
    ("VXUS", "Vanguard Total International Stock ETF", "International equity", "Total international", 100),
    ("VT", "Vanguard Total World Stock ETF", "International equity", "Global", 50),
    ("AGG", "iShares Core U.S. Aggregate Bond ETF", "Bonds", "Aggregate", 130),
    ("BND", "Vanguard Total Bond Market ETF", "Bonds", "Aggregate", 130),
    ("BNDX", "Vanguard Total International Bond ETF", "Bonds", "International bonds", 60),
    ("TLT", "iShares 20+ Year Treasury Bond ETF", "Bonds", "Long Treasury", 55),
    ("IEF", "iShares 7-10 Year Treasury Bond ETF", "Bonds", "Intermediate Treasury", 30),
    ("SHY", "iShares 1-3 Year Treasury Bond ETF", "Bonds", "Short Treasury", 24),
    ("BIL", "SPDR Bloomberg 1-3 Month T-Bill ETF", "Bonds", "Short Treasury", 40),
    ("LQD", "iShares iBoxx $ Investment Grade Corporate Bond ETF", "Bonds", "Corporate", 30),
    ("VCIT", "Vanguard Intermediate-Term Corporate Bond ETF", "Bonds", "Corporate", 60),
    ("MBB", "iShares MBS ETF", "Bonds", "Mortgage-backed", 40),
    ("TIP", "iShares TIPS Bond ETF", "Bonds", "Inflation-protected", 14),
    ("GLD", "SPDR Gold Shares", "Commodities", "Gold", 150),
    ("IAU", "iShares Gold Trust", "Commodities", "Gold", 70),
    ("SLV", "iShares Silver Trust", "Commodities", "Silver", 20),
    ("VNQ", "Vanguard Real Estate ETF", "Real estate", "US REIT", 35),
    ("XLK", "Technology Select Sector SPDR Fund", "Sector", "Technology", 80),
    ("XLF", "Financial Select Sector SPDR Fund", "Sector", "Financials", 50),
    ("XLE", "Energy Select Sector SPDR Fund", "Sector", "Energy", 35),
    ("XLV", "Health Care Select Sector SPDR Fund", "Sector", "Health care", 40),
    ("XLY", "Consumer Discretionary Select Sector SPDR Fund", "Sector", "Consumer discretionary", 20),
    ("XLI", "Industrial Select Sector SPDR Fund", "Sector", "Industrials", 22),
    ("XLC", "Communication Services Select Sector SPDR Fund", "Sector", "Communication services", 22),
    ("XLP", "Consumer Staples Select Sector SPDR Fund", "Sector", "Consumer staples", 16),
    ("XLU", "Utilities Select Sector SPDR Fund", "Sector", "Utilities", 20),
    ("VGT", "Vanguard Information Technology ETF", "Sector", "Technology", 100),
    ("SMH", "VanEck Semiconductor ETF", "Sector", "Semiconductors", 25),
]


def etf_rows(aum=None):
    aum = aum or {}
    return [{"Symbol": t, "Security": n, "Sector": s, "Subsector": g,
             "MarketCap": int(aum.get(t) or fb * 1e9), "Currency": "USD"} for t, n, s, g, fb in ETF_LIST]


def default_etf_info(symbol):
    import yfinance as yf
    return yf.Ticker(symbol).info


def refresh_etf_aum(csv_path=ETF_CSV, info_fetcher=None, throttle=1.2, sleep=time.sleep):
    """Пишет indices/etf50.csv; AUM (totalAssets) из Yahoo по одному запросу в секунду, при сбое — зашитое значение."""
    info_fetcher = info_fetcher or default_etf_info
    aum, failed = {}, []
    for t, *_ in ETF_LIST:
        try:
            v = (info_fetcher(t) or {}).get("totalAssets")
            if v and float(v) > 0:
                aum[t] = float(v)
            else:
                failed.append(t)
        except Exception:
            failed.append(t)
        sleep(throttle)
    write_csv(csv_path, etf_rows(aum))
    return {"etfs": len(ETF_LIST), "live_aum": len(aum), "fallback": failed}


def main(argv=None):
    what = (argv or sys.argv[1:] or [""])[0]
    if what == "crypto":
        print(refresh_crypto())
    elif what == "etf":
        print(refresh_etf_aum())
    else:
        print(__doc__.split("\n")[-2])
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
