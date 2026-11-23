"""
Составы мировых индексов -> indices/<id>.csv и indices/registry.json (контракт: .worktrees/CONTRACT.md).

Источники составов:
- Wikipedia (таблицы, requests + pandas.read_html с User-Agent браузера);
- Ibovespa — официальный API биржи B3;
- Dow Jones — 30 имён из навбокса Wikipedia + словарь тикеров.
Сектор, отрасль, капитализация, валюта — из yfinance (Ticker.info), с задержкой и повторами.
Кэш (страницы Wikipedia и ответы Yahoo) лежит в .cache_world/ и в git не попадает.

Запуск: python3 fetch_world_constituents.py [id ...]   (без аргументов — все индексы)
"""
import base64
import csv
import io
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd
import requests

BASE_DIR = Path(__file__).resolve().parent
OUT_DIR = BASE_DIR / "indices"
CACHE_DIR = BASE_DIR / ".cache_world"
INFO_CACHE = CACHE_DIR / "info.json"
INFO_TTL = 7 * 86400  # неделя: капитализацию не нужно обновлять чаще

HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                         "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"}

CSV_COLUMNS = ["Symbol", "Security", "Sector", "Subsector", "MarketCap", "Currency"]

# Валюты Yahoo, которые приводим к обычным кодам (GBp = пенсы, ILA = агороты, ZAc = центы)
CURRENCY_FIX = {"GBp": "GBP", "GBX": "GBP", "ILA": "ILS", "ZAc": "ZAR"}


# ---------- чистка символов ----------

def clean_code(raw):
    """'SEHK: 5' -> '5', 'BT.A' -> 'BT-A', 'MAERSK A' -> 'MAERSK-A', 'OSE: AKRBP' -> 'AKRBP'."""
    s = str(raw).strip()
    s = re.sub(r"\[.*?\]", "", s)
    if ":" in s or "：" in s:
        s = re.split(r"[:：]", s)[-1].strip()
    s = s.replace("\xa0", " ").strip().rstrip(".")
    s = re.sub(r"[\s.]+", "-", s)
    return s.strip("-")


def with_suffix(suffix, pad=0, overrides=None, join_class=False):
    """Фабрика: локальный код -> Yahoo-символ с биржевым суффиксом.
    pad — дополнить нулями слева (HK 4 знака, KR 6); join_class — слить класс акций без дефиса (Мексика)."""
    overrides = overrides or {}

    def convert(raw):
        code = re.sub(r"\.0$", "", str(raw).strip())  # pandas превратил 9983 в 9983.0
        code = clean_code(code)
        if not code or code.lower() == "nan":
            return None
        code = overrides.get(code, code)
        if join_class:
            code = code.replace("-", "")
        if pad and code.isdigit():
            code = code.zfill(pad)
        return code + suffix

    return convert


def already_yahoo(raw):
    s = clean_code(raw) if ":" in str(raw) else str(raw).strip()
    return None if not s or s.lower() == "nan" else s


def us_symbol(raw):
    """Wikipedia пишет BRK.B, Yahoo — BRK-B."""
    s = str(raw).strip().replace(".", "-")
    return None if not s or s.lower() == "nan" else s


def china_symbol(raw):
    s = str(raw)
    code = clean_code(s).zfill(6)
    return code + (".SS" if s.upper().startswith("SSE") else ".SZ")


def taiwan_symbol(raw):
    code = clean_code(raw)
    return code + ".TW" if code.isdigit() else None


def merval_symbol(raw):
    """'BCBA:YPFD NYSE: YPF' -> YPFD.BA (берём локальный код Буэнос-Айреса)."""
    m = re.search(r"BCBA\s*[:：]\s*([A-Z0-9]+)", str(raw))
    return m.group(1) + ".BA" if m else None


def colcap_symbol(raw):
    """'BVC: BCOLOMBIA BVC...' -> BCOLOMBIA.CL"""
    m = re.search(r"BVC\s*[:：]\s*([A-Z0-9]+)", str(raw))
    return m.group(1) + ".CL" if m else None


# ---------- реестр индексов ----------
# id, name, region, country, tz, close (местное закрытие), currency, expected (ожидаемое число),
# источник: ("wiki", lang, page, колонка_символа, колонка_названия, функция, мин_строк)
# или ("custom", имя_функции)

def wiki(page, sym_col, name_col, fn, min_rows=10, lang="en"):
    return ("wiki", lang, page, sym_col, name_col, fn, min_rows)


INDICES = [
    # --- Америка ---
    dict(id="nasdaq100", name="Nasdaq-100", region="americas", country="US", tz="America/New_York",
         close="16:00", currency="USD", live=True, expected=100,
         src=wiki("List_of_NASDAQ-100_companies", "Ticker", "Company", us_symbol, 90)),
    dict(id="dow30", name="Dow Jones 30", region="americas", country="US", tz="America/New_York",
         close="16:00", currency="USD", live=True, expected=30, src=("custom", "dow30")),
    dict(id="sp400", name="S&P MidCap 400", region="americas", country="US", tz="America/New_York",
         close="16:00", currency="USD", live=True, expected=400,
         src=wiki("List_of_S%26P_400_companies", "Symbol", "Security", us_symbol, 350)),
    dict(id="sp600", name="S&P SmallCap 600", region="americas", country="US", tz="America/New_York",
         close="16:00", currency="USD", live=True, expected=600,
         src=wiki("List_of_S%26P_600_companies", "Symbol", "Security", us_symbol, 550)),
    dict(id="tsx60", name="S&P/TSX 60", region="americas", country="CA", tz="America/Toronto",
         close="16:00", currency="CAD", live=False, expected=60,
         src=wiki("S%26P/TSX_60", "Symbol", "Company", with_suffix(".TO"), 50)),
    dict(id="ipc", name="S&P/BMV IPC", region="americas", country="MX", tz="America/Mexico_City",
         close="15:00", currency="MXN", live=False, expected=35,
         src=wiki("Indice_de_Precios_y_Cotizaciones", "Symbol", "Name",
                  with_suffix(".MX", join_class=True, overrides={"CEMEX-CPO": "CEMEXCPO", "KOF-UBL": "KOFUBL"}), 25)),
    dict(id="ibovespa", name="Ibovespa", region="americas", country="BR", tz="America/Sao_Paulo",
         close="18:00", currency="BRL", live=False, expected=76, src=("custom", "ibovespa")),
    dict(id="merval", name="S&P Merval", region="americas", country="AR", tz="America/Argentina/Buenos_Aires",
         close="17:00", currency="ARS", live=False, expected=22,
         src=wiki("S%26P_Merval", "Símbolo", "Compañía", merval_symbol, 15, lang="es")),
    dict(id="colcap", name="MSCI COLCAP", region="americas", country="CO", tz="America/Bogota",
         close="16:00", currency="COP", live=False, expected=20,
         src=wiki("COLCAP", "Symbol", "Company", colcap_symbol, 15)),
    # --- Европа ---
    dict(id="eurostoxx50", name="Euro Stoxx 50", region="europe", country="EU", tz="Europe/Paris",
         close="17:35", currency="EUR", live=False, expected=50,
         src=wiki("Euro_Stoxx_50", "Ticker", "Name", already_yahoo, 45)),
    dict(id="ibex35", name="IBEX 35", region="europe", country="ES", tz="Europe/Madrid",
         close="17:35", currency="EUR", live=False, expected=35,
         src=wiki("IBEX_35", "Ticker", "Company", already_yahoo, 30)),
    dict(id="dax40", name="DAX 40", region="europe", country="DE", tz="Europe/Berlin",
         close="17:35", currency="EUR", live=False, expected=40,
         src=wiki("DAX", "Ticker", "Company", already_yahoo, 35)),
    dict(id="cac40", name="CAC 40", region="europe", country="FR", tz="Europe/Paris",
         close="17:35", currency="EUR", live=False, expected=40,
         src=wiki("CAC_40", "Ticker", "Company", already_yahoo, 35)),
    dict(id="ftse100", name="FTSE 100", region="europe", country="GB", tz="Europe/London",
         close="16:35", currency="GBP", live=False, expected=100,
         src=wiki("FTSE_100_Index", "Ticker", "Company", with_suffix(".L"), 90)),
    dict(id="ftsemib", name="FTSE MIB", region="europe", country="IT", tz="Europe/Rome",
         close="17:35", currency="EUR", live=False, expected=40,
         src=wiki("FTSE_MIB", "Ticker", "Company", already_yahoo, 35)),
    dict(id="aex", name="AEX", region="europe", country="NL", tz="Europe/Amsterdam",
         close="17:35", currency="EUR", live=False, expected=25,
         src=wiki("AEX_index", "Ticker", "Company", already_yahoo, 20)),
    dict(id="smi", name="SMI", region="europe", country="CH", tz="Europe/Zurich",
         close="17:30", currency="CHF", live=False, expected=20,
         src=wiki("Swiss_Market_Index", "Ticker", "Name", with_suffix(".SW", overrides={"ROP": "ROG"}), 18)),
    dict(id="omxs30", name="OMX Stockholm 30", region="europe", country="SE", tz="Europe/Stockholm",
         close="17:30", currency="SEK", live=False, expected=30,
         src=wiki("OMX_Stockholm_30", "Ticker", "Company", already_yahoo, 25)),
    dict(id="omxc25", name="OMX Copenhagen 25", region="europe", country="DK", tz="Europe/Copenhagen",
         close="17:05", currency="DKK", live=False, expected=25,
         src=wiki("OMX_Copenhagen_25", "Ticker symbol", "Company", with_suffix(".CO"), 20)),
    dict(id="omxh25", name="OMX Helsinki 25", region="europe", country="FI", tz="Europe/Helsinki",
         close="18:30", currency="EUR", live=False, expected=25,
         src=wiki("OMX_Helsinki_25", "Ticker", "Company", already_yahoo, 20)),
    dict(id="bel20", name="BEL 20", region="europe", country="BE", tz="Europe/Brussels",
         close="17:35", currency="EUR", live=False, expected=20,
         src=wiki("BEL_20", "Ticker symbol", "Company", with_suffix(".BR"), 18)),
    dict(id="psi", name="PSI", region="europe", country="PT", tz="Europe/Lisbon",
         close="16:35", currency="EUR", live=False, expected=16,
         src=wiki("PSI-20", "Ticker", "Company", with_suffix(".LS"), 14)),
    dict(id="atx", name="ATX", region="europe", country="AT", tz="Europe/Vienna",
         close="17:35", currency="EUR", live=False, expected=20, src=("custom", "atx")),
    dict(id="obx", name="OBX", region="europe", country="NO", tz="Europe/Oslo",
         close="16:30", currency="NOK", live=False, expected=25,
         src=wiki("OBX_Index", "Ticker symbol", "Company", with_suffix(".OL"), 20)),
    dict(id="iseq20", name="ISEQ 20", region="europe", country="IE", tz="Europe/Dublin",
         close="16:35", currency="EUR", live=False, expected=20,
         src=wiki("ISEQ_20", "MNEM code", "Company", with_suffix(".IR"), 15)),
    # --- Азия и Океания ---
    dict(id="nikkei225", name="Nikkei 225", region="asia_pacific", country="JP", tz="Asia/Tokyo",
         close="15:30", currency="JPY", live=False, expected=225,
         src=wiki("Nikkei_225", "Code", "Name", with_suffix(".T"), 200, lang="de")),
    dict(id="hsi", name="Hang Seng", region="asia_pacific", country="HK", tz="Asia/Hong_Kong",
         close="16:10", currency="HKD", live=False, expected=85,
         src=wiki("Hang_Seng_Index", "Ticker", "Name", with_suffix(".HK", pad=4), 70)),
    dict(id="csi300", name="CSI 300", region="asia_pacific", country="CN", tz="Asia/Shanghai",
         close="15:00", currency="CNY", live=False, expected=300,
         src=wiki("CSI_300_Index", "Ticker", "Company", china_symbol, 250)),
    dict(id="sse50", name="SSE 50", region="asia_pacific", country="CN", tz="Asia/Shanghai",
         close="15:00", currency="CNY", live=False, expected=50,
         src=wiki("SSE_50_Index", "Ticker symbol", "Name", china_symbol, 45)),
    dict(id="kospi200", name="KOSPI 200", region="asia_pacific", country="KR", tz="Asia/Seoul",
         close="15:30", currency="KRW", live=False, expected=200,
         src=wiki("KOSPI_200", "Symbol", "Company", with_suffix(".KS", pad=6), 180)),
    dict(id="taiwan50", name="Taiwan 50", region="asia_pacific", country="TW", tz="Asia/Taipei",
         close="13:30", currency="TWD", live=False, expected=50, src=("custom", "taiwan50")),
    dict(id="nifty50", name="Nifty 50", region="asia_pacific", country="IN", tz="Asia/Kolkata",
         close="15:30", currency="INR", live=False, expected=50,
         src=wiki("NIFTY_50", "Symbol", "Company name", with_suffix(".NS"), 45)),
    dict(id="sensex", name="BSE Sensex", region="asia_pacific", country="IN", tz="Asia/Kolkata",
         close="15:30", currency="INR", live=False, expected=30,
         src=wiki("BSE_SENSEX", "Symbol", "Company", already_yahoo, 25)),
    dict(id="sti", name="Straits Times (STI)", region="asia_pacific", country="SG", tz="Asia/Singapore",
         close="17:20", currency="SGD", live=False, expected=30,
         src=wiki("Straits_Times_Index", "Stock symbol", "Company", with_suffix(".SI"), 25)),
    dict(id="klci", name="FTSE Bursa Malaysia KLCI", region="asia_pacific", country="MY", tz="Asia/Kuala_Lumpur",
         close="17:05", currency="MYR", live=False, expected=30,
         src=wiki("FTSE_Bursa_Malaysia_KLCI", "Stock Code", "Constituent Name", with_suffix(".KL", pad=4), 25)),
    dict(id="set50", name="SET50", region="asia_pacific", country="TH", tz="Asia/Bangkok",
         close="16:40", currency="THB", live=False, expected=50,
         src=wiki("SET50_Index", "Symbol", "Securities Name", with_suffix(".BK"), 45)),
    dict(id="lq45", name="IDX LQ45", region="asia_pacific", country="ID", tz="Asia/Jakarta",
         close="16:15", currency="IDR", live=False, expected=45,
         src=wiki("LQ45", "Ticker", "Company", with_suffix(".JK"), 40)),
    dict(id="asx50", name="S&P/ASX 50", region="asia_pacific", country="AU", tz="Australia/Sydney",
         close="16:10", currency="AUD", live=False, expected=50,
         src=wiki("S%26P/ASX_50", "Symbol", "Company", with_suffix(".AX"), 45)),
    dict(id="nzx50", name="NZX 50", region="asia_pacific", country="NZ", tz="Pacific/Auckland",
         close="16:45", currency="NZD", live=False, expected=50,
         src=wiki("NZX_50_Index", "Ticker symbol", "Company", with_suffix(".NZ"), 45)),
]

# Отброшены: S&P IPSA (Чили), WIG20 (Польша), Hang Seng Tech — нет надёжного источника состава;
# PSEi (Филиппины) — Yahoo не знает эти символы.
DROPPED = {
    "psei": "PSEi (Филиппины): Yahoo не отдаёт ни цен, ни капитализации по суффиксу .PS (0 из 30)",
    "ipsa": "S&P IPSA: на Wikipedia нет таблицы состава, официального открытого API нет",
    "wig20": "WIG20: на Wikipedia нет таблицы состава (только история уровней), сайт GPW без открытого API",
    "hstech": "Hang Seng Tech: страницы Wikipedia нет, состав из памяти не берём (меняется ежеквартально)",
}

SP500_ENTRY = dict(id="sp500", name="S&P 500", region="americas", country="US", exchange_tz="America/New_York",
                   close="16:00", currency="USD", live=True,
                   constituents="SP500_with_market_cap.csv", history="history.db")


# ---------- загрузка страниц ----------

def http_get(url, retries=3):
    for attempt in range(retries):
        try:
            resp = requests.get(url, headers=HEADERS, timeout=30)
            if resp.status_code == 429:
                time.sleep(5 * (attempt + 1))
                continue
            resp.raise_for_status()
            return resp
        except requests.RequestException:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def wiki_tables(lang, page):
    """Все таблицы страницы Wikipedia (HTML кэшируется на диск)."""
    CACHE_DIR.mkdir(exist_ok=True)
    cache = CACHE_DIR / f"wiki_{lang}_{re.sub(r'[^A-Za-z0-9]+', '_', page)}.html"
    if cache.exists() and time.time() - cache.stat().st_mtime < INFO_TTL:
        html = cache.read_text(encoding="utf-8")
    else:
        html = http_get(f"https://{lang}.wikipedia.org/wiki/{page}").text
        cache.write_text(html, encoding="utf-8")
        time.sleep(1.5)  # вежливо к Wikipedia
    return pd.read_html(io.StringIO(html))


def pick_table(tables, sym_col, min_rows):
    for t in tables:
        cols = [str(c) for c in t.columns]
        if any(sym_col.lower() == re.sub(r"\[.*?\]", "", c).strip().lower() for c in cols) and len(t) >= min_rows:
            return t
    raise ValueError(f"таблица с колонкой {sym_col!r} и ≥{min_rows} строк не найдена")


def parse_wiki(src):
    _, lang, page, sym_col, name_col, fn, min_rows = src
    t = pick_table(wiki_tables(lang, page), sym_col, min_rows)
    cols = {re.sub(r"\[.*?\]", "", str(c)).strip().lower(): c for c in t.columns}
    sym_c, name_c = cols[sym_col.lower()], cols[name_col.lower()]
    out = []
    for raw_sym, raw_name in zip(t[sym_c], t[name_c]):
        if pd.isna(raw_sym):
            continue
        sym = fn(raw_sym)
        if sym:
            out.append((sym, re.sub(r"\s*\[.*?\]", "", str(raw_name)).strip()))
    return out


# ---------- особые источники ----------

DOW_TICKERS = {
    "3M": "MMM", "Alphabet": "GOOGL", "Amazon": "AMZN", "American Express": "AXP", "Amgen": "AMGN",
    "Apple": "AAPL", "Boeing": "BA", "Caterpillar": "CAT", "Chevron": "CVX", "Cisco": "CSCO",
    "Coca-Cola": "KO", "Disney": "DIS", "Goldman Sachs": "GS", "Home Depot": "HD",
    "Honeywell Technologies": "HON", "Honeywell": "HON", "IBM": "IBM", "Johnson & Johnson": "JNJ",
    "JPMorgan Chase": "JPM", "McDonald's": "MCD", "Merck": "MRK", "Microsoft": "MSFT", "Nike": "NKE",
    "Nvidia": "NVDA", "Procter & Gamble": "PG", "Salesforce": "CRM", "Sherwin-Williams": "SHW",
    "Travelers": "TRV", "UnitedHealth": "UNH", "Visa": "V", "Walmart": "WMT",
}


def fetch_dow30():
    """30 имён из навбокса «Components of the Dow Jones Industrial Average» на странице Dow."""
    tables = wiki_tables("en", "Dow_Jones_Industrial_Average")
    blob = None
    for t in tables:
        if "Components of the Dow Jones" in " ".join(str(c) for c in t.columns):
            blob = str(t.iloc[0, 0])
            break
    if blob is None:
        raise ValueError("навбокс состава Dow не найден")
    out, rest = [], blob
    # имена из словаря, самые длинные первыми (чтобы «Honeywell Technologies» не съел «Honeywell»)
    for name in sorted(DOW_TICKERS, key=len, reverse=True):
        if name in rest:
            rest = rest.replace(name, " ", 1)
            out.append((DOW_TICKERS[name], name))
    seen, uniq = set(), []
    for sym, name in out:
        if sym not in seen:
            seen.add(sym)
            uniq.append((sym, name))
    return uniq


def fetch_ibovespa():
    """Официальный API B3. Если у компании несколько классов акций (PETR3/PETR4) — берём класс с большим весом,
    иначе капитализация компании задвоится."""
    payload = base64.b64encode(json.dumps({"language": "en-us", "pageNumber": 1, "pageSize": 200,
                                           "index": "IBOV", "segment": "1"}).encode()).decode()
    url = f"https://sistemaswebb3-listados.b3.com.br/indexProxy/indexCall/GetPortfolioDay/{payload}"
    results = http_get(url).json()["results"]
    best = {}
    for r in results:
        weight = float(r["part"].replace(",", ""))
        key = r["asset"].strip()
        if key not in best or weight > best[key][0]:
            best[key] = (weight, r["cod"].strip())
    return [(code + ".SA", asset.title()) for asset, (_, code) in best.items()]


ATX_TICKERS = {
    "Erste Bank": "EBS", "Verbund": "VER", "OMV": "OMV", "Raiffeisen Bank International": "RBI",
    "Raiffeisen": "RBI", "voestalpine": "VOE", "Andritz": "ANDR", "Wienerberger": "WIE",
    "Vienna Insurance Group": "VIG", "Uniqa": "UQA", "UNIQA": "UQA", "Mayr-Melnhof": "MMK",
    "Mayr-Melnhof Karton": "MMK", "Lenzing": "LNZ", "Telekom Austria": "TKA", "A1 Telekom Austria": "TKA",
    "Schoeller-Bleckmann": "SBO", "Strabag": "STR", "STRABAG": "STR", "Palfinger": "PAL",
    "BAWAG": "BG", "BAWAG Group": "BG", "EVN": "EVN", "CA Immo": "CAI", "IMMOFINANZ": "IIA",
    "Immofinanz": "IIA", "Do & Co": "DOC", "DO & CO": "DOC", "AT&S": "ATS", "Österreichische Post": "POST",
    "Austrian Post": "POST", "Porr": "POR", "Agrana": "AGR", "Semperit": "SEM", "S Immo": "SPI",
    "Zumtobel": "ZAG", "Kapsch TrafficCom": "KTCG", "Rosenbauer": "ROS", "Flughafen Wien": "FLU",
    "Addiko Bank": "ADKO", "Voestalpine": "VOE", "Raiffeisen International": "RBI", "EVN Group": "EVN",
    "Uniqa Insurance Group": "UQA", "Schoeller-Bleckmann Oilfield Equipment": "SBO", "Bawag": "BG", "FACC": "FACC", "Verbund AG": "VER", "Telekom Austria Group": "TKA",
}


def fetch_atx():
    """В таблице ATX на Wikipedia нет тикеров — сопоставляем по названиям словарём. Несопоставленные — в отчёт."""
    t = pick_table(wiki_tables("en", "Austrian_Traded_Index"), "Company", 15)
    out, unknown = [], []
    for name in t["Company"].dropna():
        name = re.sub(r"\s*\[.*?\]", "", str(name)).strip()
        code = ATX_TICKERS.get(name)
        if code:
            out.append((code + ".VI", name))
        else:
            unknown.append(name)
    if unknown:
        print(f"  ATX: нет тикера для {unknown}")
    return out


def fetch_taiwan50():
    """zh.wikipedia: таблица в две колонки-группы (код, имя, вес) — склеиваем."""
    tables = wiki_tables("zh", "臺灣50指數")
    t = next(t for t in tables if len(t) >= 20 and str(t.columns[0]).startswith("股票代號"))
    out = []
    for code_c, name_c in (("股票代號", "名稱"), ("股票代號.1", "名稱.1")):
        for raw, name in zip(t[code_c], t[name_c]):
            sym = taiwan_symbol(raw)
            if sym:
                out.append((sym, str(name).strip()))
    return out


CUSTOM = {"dow30": fetch_dow30, "ibovespa": fetch_ibovespa, "atx": fetch_atx, "taiwan50": fetch_taiwan50}


def fetch_constituents(spec):
    src = spec["src"]
    rows = parse_wiki(src) if src[0] == "wiki" else CUSTOM[src[1]]()
    seen, uniq = set(), []
    for sym, name in rows:
        if sym not in seen:
            seen.add(sym)
            uniq.append((sym, name))
    return uniq


# ---------- Yahoo: сектор, капитализация, валюта ----------

def load_info_cache():
    try:
        return json.loads(INFO_CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def yahoo_info(symbol, retries=4):
    """Сектор/отрасль/капитализация/валюта одного символа; None — Yahoo ничего не знает."""
    import yfinance as yf
    last_err = None
    for attempt in range(retries):
        try:
            tk = yf.Ticker(symbol)
            info = tk.info or {}
            cap = info.get("marketCap")
            if not cap:
                try:
                    cap = tk.fast_info.get("marketCap")
                except Exception:
                    cap = None
            if not cap and not info.get("sector") and not info.get("shortName"):
                raise ValueError("пустой ответ")
            cur = info.get("currency") or info.get("financialCurrency") or ""
            return {"sector": info.get("sector") or "", "industry": info.get("industry") or "",
                    "cap": float(cap) if cap else 0.0, "currency": CURRENCY_FIX.get(cur, cur),
                    "name": info.get("longName") or info.get("shortName") or "", "ts": time.time()}
        except Exception as e:  # сеть, лимиты Yahoo
            last_err = e
            if "Too Many" in str(e) or "Rate" in str(e):
                time.sleep(25 * (attempt + 1))  # лимит Yahoo: ждём долго, иначе только ухудшим
            else:
                time.sleep(1.5 * (attempt + 1))
    return {"sector": "", "industry": "", "cap": 0.0, "currency": "", "name": "", "ts": time.time(),
            "error": str(last_err)[:80]}


def collect_info(symbols, workers=3):
    cache = load_info_cache()
    todo = [s for s in symbols
            if s not in cache or time.time() - cache[s].get("ts", 0) > INFO_TTL or
            (cache[s].get("error") and "пустой" not in cache[s]["error"])]  # ошибки сети/лимита пробуем снова
    print(f"Yahoo: символов {len(symbols)}, в кэше {len(symbols) - len(todo)}, запрашиваю {len(todo)}")
    CACHE_DIR.mkdir(exist_ok=True)
    done = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for sym, res in zip(todo, pool.map(yahoo_info, todo)):
            cache[sym] = res
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(todo)}")
                INFO_CACHE.write_text(json.dumps(cache), encoding="utf-8")
    INFO_CACHE.write_text(json.dumps(cache), encoding="utf-8")
    return cache


# ---------- сборка ----------

def build_rows(spec, members, info):
    rows, missing, seen_caps = [], [], set()
    for sym, name in members:
        d = info.get(sym) or {}
        if not d.get("cap"):
            missing.append(sym)
            continue
        # второй класс акций той же компании (GOOG/GOOGL, MAERSK A/B): Yahoo даёт ту же капитализацию компании,
        # плитку рисуем один раз
        if (d["cap"], d.get("sector")) in seen_caps:
            continue
        seen_caps.add((d["cap"], d.get("sector")))
        rows.append({
            "Symbol": sym,
            "Security": name or d.get("name") or sym,
            "Sector": d.get("sector") or "Other",
            "Subsector": d.get("industry") or "Other",
            "MarketCap": int(d["cap"]),
            "Currency": d.get("currency") or spec["currency"],
        })
    return rows, missing


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows)


def registry_entry(spec):
    return dict(id=spec["id"], name=spec["name"], region=spec["region"], country=spec["country"],
                exchange_tz=spec["tz"], close=spec["close"], currency=spec["currency"], live=spec["live"],
                constituents=f"indices/{spec['id']}.csv", history="history_world.db")


def main(argv):
    wanted = set(argv) or {s["id"] for s in INDICES}
    OUT_DIR.mkdir(exist_ok=True)
    parsed, failed = {}, {}
    for spec in INDICES:
        if spec["id"] not in wanted:
            continue
        try:
            parsed[spec["id"]] = fetch_constituents(spec)
            print(f"{spec['id']}: состав {len(parsed[spec['id']])} (ожидалось {spec['expected']})")
        except Exception as e:
            failed[spec["id"]] = str(e)
            print(f"{spec['id']}: ОШИБКА {e}")

    symbols = sorted({s for members in parsed.values() for s, _ in members})
    info = collect_info(symbols)

    report, ok_ids = [], []
    for spec in INDICES:
        if spec["id"] not in parsed:
            continue
        rows, missing = build_rows(spec, parsed[spec["id"]], info)
        # индекс считаем годным, если получено ≥ 85% ожидаемого состава с капитализацией
        if len(rows) < 0.85 * spec["expected"]:
            failed[spec["id"]] = f"с капитализацией только {len(rows)} из {spec['expected']}"
            report.append((spec["id"], spec["expected"], len(parsed[spec["id"]]), len(rows), missing, "ОТБРОШЕН"))
            continue
        write_csv(OUT_DIR / f"{spec['id']}.csv", rows)
        ok_ids.append(spec["id"])
        report.append((spec["id"], spec["expected"], len(parsed[spec["id"]]), len(rows), missing, "ok"))

    # реестр: sp500 первым, дальше по порядку INDICES (регион, важность); только годные
    previous = []
    reg_path = OUT_DIR / "registry.json"
    if wanted != {s["id"] for s in INDICES} and reg_path.exists():
        previous = {e["id"]: e for e in json.loads(reg_path.read_text(encoding="utf-8"))}
    entries = [SP500_ENTRY]
    for spec in INDICES:
        if spec["id"] in ok_ids:
            entries.append(registry_entry(spec))
        elif previous and spec["id"] in previous:
            entries.append(previous[spec["id"]])
    reg_path.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("\nИтог: id | ожидалось | состав | с капитализацией | без капитализации")
    for iid, exp, got, withcap, missing, status in report:
        print(f"{status:9} {iid:12} {exp:4} {got:4} {withcap:4}  {', '.join(missing)}")
    for iid, why in failed.items():
        print(f"НЕ ВКЛЮЧЁН {iid}: {why}")
    for iid, why in DROPPED.items():
        print(f"ОТБРОШЕН заранее {iid}: {why}")


if __name__ == "__main__":
    main(sys.argv[1:])
