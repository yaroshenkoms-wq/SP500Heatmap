"""Скринер и календарь: чистая логика над готовыми строками (без сети и без глобальных кэшей сервера)."""
from datetime import date, timedelta

PERIODS = ("1d", "3d", "7d", "30d", "180d", "ytd", "1y", "3y", "5y", "10y")

# готовые наборы: фильтры по умолчанию (явные параметры запроса их перекрывают) + сортировка
PRESETS = {
    "gainers": {"filters": {}, "sort": "change", "order": "desc"},
    "losers": {"filters": {}, "sort": "change", "order": "asc"},
    "active": {"filters": {}, "sort": "relVolume", "order": "desc"},
    "dividend": {"filters": {"divMin": 1, "divMax": 15, "minCap": 1e9}, "sort": "divYield", "order": "desc"},
    "value": {"filters": {"peMin": 0.01, "peMax": 20, "minCap": 1e9}, "sort": "pe", "order": "asc"},
    "highs52": {"filters": {"pos52Min": 0.97}, "sort": "pos52w", "order": "desc"},
    "lows52": {"filters": {"pos52Max": 0.03}, "sort": "pos52w", "order": "asc"},
}

SORT_FIELDS = ("ticker", "name", "index", "sector", "capUSD", "change", "pe", "ps", "pb", "divYield", "beta",
               "revGrowth", "pos52w", "relVolume")

# параметр запроса -> (поле строки, "min" | "max")
FILTERS = {
    "minCap": ("capUSD", "min"), "maxCap": ("capUSD", "max"),
    "peMin": ("pe", "min"), "peMax": ("pe", "max"), "psMax": ("ps", "max"), "pbMax": ("pb", "max"),
    "divMin": ("divYield", "min"), "divMax": ("divYield", "max"), "betaMax": ("beta", "max"), "revGrowthMin": ("revGrowth", "min"),
    "chgMin": ("change", "min"), "chgMax": ("change", "max"),
    "pos52Min": ("pos52w", "min"), "pos52Max": ("pos52w", "max"), "relVolMin": ("relVolume", "min"),
}


def effective(params):
    """Параметры + пресет -> (фильтры {имя: число}, sort, order)."""
    preset = PRESETS.get(params.get("preset")) if params.get("preset") else None
    filters = dict(preset["filters"]) if preset else {}
    filters.update({k: v for k, v in params.items() if k in FILTERS and v is not None})
    sort = params.get("sort") or (preset["sort"] if preset else "capUSD")
    order = params.get("order") or (preset["order"] if preset else "desc")
    return filters, sort, order


def needs_volume(filters, sort):
    return "relVolMin" in filters or sort == "relVolume"


def passes(row, filters, sector=None):
    if sector and (row.get("sector") or "").lower() != sector.lower():
        return False
    for name, bound in filters.items():
        field, kind = FILTERS[name]
        v = row.get(field)
        if v is None:
            return False
        if (kind == "min" and v < bound) or (kind == "max" and v > bound):
            return False
    return True


def sort_rows(rows, sort, order):
    """Пустые значения — всегда в конце, при любом порядке."""
    present = [r for r in rows if r.get(sort) is not None]
    missing = [r for r in rows if r.get(sort) is None]
    present.sort(key=lambda r: (r[sort].lower() if isinstance(r[sort], str) else r[sort]), reverse=(order == "desc"))
    return present + missing


# ---------------------------------------------------------------- календарь

def _d(s):
    try:
        return date.fromisoformat(s)
    except (TypeError, ValueError):
        return None


def calendar_events(rows, start, end):
    """rows: [{"ticker","name","index", "earnings_date","ex_dividend_date","dividend_date","dividend_rate"}] ->
    события в [start, end] (даты date), отсортированные по дате, типу, тикеру."""
    events = []
    for r in rows:
        base = {"ticker": r["ticker"], "name": r["name"], "index": r["index"]}
        for key, typ in (("earnings_date", "earnings"), ("ex_dividend_date", "exDividend"),
                         ("dividend_date", "dividendPay")):
            d = _d(r.get(key))
            if d is None or not (start <= d <= end):
                continue
            detail = {}
            if typ in ("exDividend", "dividendPay") and r.get("dividend_rate") is not None:
                detail["dividendRate"] = r["dividend_rate"]
            events.append({"date": d.isoformat(), "type": typ, **base, "detail": detail})
    events.sort(key=lambda e: (e["date"], e["type"], e["ticker"]))
    return events


def default_range(start=None, end=None, today=None, span_days=14):
    today = today or date.today()
    start = start or today
    return start, end or start + timedelta(days=span_days)
