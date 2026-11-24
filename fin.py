"""Отчётность компании для /api/v1/financials/{ticker}: Yahoo (yfinance) -> компактный JSON, кэш 24 ч в SQLite
(financials_cache.db), держатели — из data/guru_holdings.json (tools/sync_udak_gurus.py).

В памяти ничего не держим: один символ за раз, файл гуру читаем с проверкой mtime (~50 КБ).
Сеть — только default_fetcher (подменяется в тестах)."""
import json
import math
import sqlite3
import time
from datetime import datetime
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = str(BASE_DIR / "financials_cache.db")
GURU_PATH = str(BASE_DIR / "data" / "guru_holdings.json")
CACHE_SECONDS = 24 * 3600
ANNUAL_LIMIT, QUARTERLY_LIMIT = 4, 6

# поле ответа -> варианты названия строки в отчёте Yahoo (по порядку предпочтения)
ROWS = {
    "revenue": ("Total Revenue", "Operating Revenue"),
    "grossProfit": ("Gross Profit",),
    "operatingIncome": ("Operating Income", "Total Operating Income As Reported"),
    "netIncome": ("Net Income", "Net Income Common Stockholders"),
    "eps": ("Diluted EPS", "Basic EPS"),
    "freeCashFlow": ("Free Cash Flow",),
    "totalDebt": ("Total Debt",),
    "cash": ("Cash And Cash Equivalents", "Cash Cash Equivalents And Short Term Investments"),
    "sharesOutstanding": ("Ordinary Shares Number", "Share Issued", "Diluted Average Shares"),
}
SOURCE_OF = {"revenue": "income", "grossProfit": "income", "operatingIncome": "income", "netIncome": "income",
             "eps": "income", "freeCashFlow": "cashflow", "totalDebt": "balance", "cash": "balance",
             "sharesOutstanding": "balance"}


def num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _round(v, nd=4):
    n = num(v)
    return None if n is None else round(n, nd)


def default_fetcher(ysym):
    """6 отчётов + info одной компании (7 запросов Yahoo). Возвращает словарь DataFrame/dict."""
    import yfinance as yf
    t = yf.Ticker(ysym)
    return {"income_a": t.income_stmt, "income_q": t.quarterly_income_stmt,
            "balance_a": t.balance_sheet, "balance_q": t.quarterly_balance_sheet,
            "cashflow_a": t.cashflow, "cashflow_q": t.quarterly_cashflow, "info": t.info}


def _period_label(ts, quarterly):
    d = ts if hasattr(ts, "year") else datetime.fromisoformat(str(ts)[:10])
    return f"{d.year}-Q{(d.month - 1) // 3 + 1}" if quarterly else str(d.year)


def _cell(df, names, col):
    if df is None or getattr(df, "empty", True):
        return None
    for name in names:
        if name in df.index and col in df.columns:
            v = num(df.at[name, col])
            if v is not None:
                return v
    return None


def build_periods(frames, quarterly, limit):
    """frames: {"income","balance","cashflow"} DataFrame -> список периодов, новые первыми (до limit).
    Периоды берём по датам отчёта о прибылях (нет его — по балансу)."""
    base = frames.get("income")
    if base is None or getattr(base, "empty", True):
        base = frames.get("balance")
    if base is None or getattr(base, "empty", True):
        return []
    cols = sorted(base.columns, reverse=True)[:limit]
    out = []
    for col in cols:
        row = {"period": _period_label(col, quarterly)}
        for field, names in ROWS.items():
            df = frames.get(SOURCE_OF[field])
            v = _cell(df, names, col)
            row[field] = _round(v, 4 if field == "eps" else 0)
        out.append(row)
    return out


def _pct(v):
    n = num(v)
    return None if n is None else round(n * 100, 2)


def build_ratios(info):
    info = info or {}
    mcap, fcf = num(info.get("marketCap")), num(info.get("freeCashflow"))
    de = num(info.get("debtToEquity"))
    return {
        "grossMargin": _pct(info.get("grossMargins")), "operatingMargin": _pct(info.get("operatingMargins")),
        "netMargin": _pct(info.get("profitMargins")), "roe": _pct(info.get("returnOnEquity")),
        "roa": _pct(info.get("returnOnAssets")),
        "debtToEquity": round(de / 100, 3) if de is not None else None,  # Yahoo даёт в процентах (84 = 0.84x)
        "currentRatio": _round(info.get("currentRatio"), 3),
        "evToEbitda": _round(info.get("enterpriseToEbitda"), 2),
        "peg": _round(info.get("trailingPegRatio") if num(info.get("trailingPegRatio")) is not None
                      else info.get("pegRatio"), 2),
        "priceToFcf": round(mcap / fcf, 2) if mcap and fcf and fcf > 0 else None,
    }


def build_analysts(info):
    info = info or {}
    rec = info.get("recommendationKey")
    return {
        "recommendation": rec if rec and rec != "none" else None,
        "count": int(info["numberOfAnalystOpinions"]) if num(info.get("numberOfAnalystOpinions")) is not None else None,
        "targetMean": _round(info.get("targetMeanPrice"), 2), "targetHigh": _round(info.get("targetHighPrice"), 2),
        "targetLow": _round(info.get("targetLowPrice"), 2),
        "currentPrice": _round(info.get("currentPrice") or info.get("regularMarketPrice"), 2),
    }


def build_financials(ticker, ysym, fetcher=None, fallback_currency=None):
    """Ответ без holders. Нет ни одного отчёта и нет info — ValueError (эндпоинт отдаст 502, ничего не кэшируем)."""
    data = (fetcher or default_fetcher)(ysym) or {}
    info = data.get("info") or {}
    annual = build_periods({"income": data.get("income_a"), "balance": data.get("balance_a"),
                            "cashflow": data.get("cashflow_a")}, False, ANNUAL_LIMIT)
    quarterly = build_periods({"income": data.get("income_q"), "balance": data.get("balance_q"),
                               "cashflow": data.get("cashflow_q")}, True, QUARTERLY_LIMIT)
    if not annual and not quarterly and not info:
        raise ValueError("no financial data")
    return {"ticker": ticker, "currency": info.get("financialCurrency") or info.get("currency") or fallback_currency,
            "annual": annual, "quarterly": quarterly, "ratios": build_ratios(info), "analysts": build_analysts(info)}


# ---------------------------------------------------------------- кэш

def _connect(db_path):
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass
    conn.execute("CREATE TABLE IF NOT EXISTS fin_cache (symbol TEXT PRIMARY KEY, payload TEXT NOT NULL, "
                 "updated_at REAL NOT NULL)")
    return conn


def get_cached(db_path, symbol, max_age=CACHE_SECONDS, now=None):
    """(payload, свежий?) или (None, False). Устаревшее отдаём как запасное, если Yahoo не ответил."""
    if not Path(db_path).exists():
        return None, False
    conn = _connect(db_path)
    try:
        row = conn.execute("SELECT payload, updated_at FROM fin_cache WHERE symbol = ?", (symbol,)).fetchone()
    finally:
        conn.close()
    if not row:
        return None, False
    return json.loads(row[0]), (now or time.time()) - row[1] <= max_age


def put_cached(db_path, symbol, payload, now=None):
    conn = _connect(db_path)
    try:
        conn.execute("INSERT OR REPLACE INTO fin_cache (symbol, payload, updated_at) VALUES (?,?,?)",
                     (symbol, json.dumps(payload, ensure_ascii=False), now or time.time()))
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- держатели (13F гуру)

_guru_cache = {"mtime": None, "path": None, "data": {"gurus": []}}


def load_gurus(path=None):
    path = path or GURU_PATH
    try:
        mtime = Path(path).stat().st_mtime
    except OSError:
        return {"gurus": []}
    if _guru_cache["mtime"] != mtime or _guru_cache["path"] != path:
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
            if not isinstance(data.get("gurus"), list):
                raise ValueError("bad format")
        except Exception as e:
            print(f"⚠️ guru_holdings.json не прочитан: {e}")
            return {"gurus": []}
        _guru_cache.update(mtime=mtime, path=path, data=data)
    return _guru_cache["data"]


def holders_for(ticker, path=None):
    """[{"name","weightPct","changeQ","reportDate"}] по убыванию доли; тикер у гуру не найден — []."""
    out = []
    for g in load_gurus(path)["gurus"]:
        h = (g.get("holdings") or {}).get(ticker)
        if h:
            out.append({"name": g["name"], "weightPct": h["weightPct"], "changeQ": h["changeQ"],
                        "reportDate": g.get("reportDate")})
    out.sort(key=lambda x: -x["weightPct"])
    return out
