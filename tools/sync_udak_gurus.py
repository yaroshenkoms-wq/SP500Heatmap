"""Компактный файл data/guru_holdings.json из 13F-данных Udak (только чтение чужой папки).

Источник: <Udak>/articles/data/*.json — {"key","cik","name","quarters":[{"period","filed","holdings":[{"name","cusip",
"put_call","value","shares"}]}]}. Тикеров в источнике нет, поэтому сопоставляем с нашими индексами по названию
(нормализованному) и по CUSIP-исправлениям. В файл попадают только позиции, которые удалось привязать к нашему тикеру.

weightPct = доля позиции в стоимости всего портфеля фонда (без опционов) в %.
changeQ   = new (нет в прошлом квартале) | add (+>1% акций) | reduce (−>1%) | hold.

Запуск: python3 tools/sync_udak_gurus.py [--src ПАПКА] [--out data/guru_holdings.json]
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
DEFAULT_SRC = Path("/Users/maximyaroshenko/Udak/Brokers/articles/data")

GURUS = {
    "buffett": "Warren Buffett (Berkshire Hathaway)", "ackman": "Bill Ackman (Pershing Square)",
    "burry": "Michael Burry (Scion)", "dalio": "Ray Dalio (Bridgewater)",
    "druckenmiller": "Stanley Druckenmiller (Duquesne)", "klarman": "Seth Klarman (Baupost)",
    "lilu": "Li Lu (Himalaya Capital)", "loeb": "Dan Loeb (Third Point)", "pabrai": "Mohnish Pabrai (Dalal Street)",
    "soros": "George Soros (Soros Fund Management)", "tepper": "David Tepper (Appaloosa)",
    "wood": "Cathie Wood (ARK Invest)",
}

# Исправления, где название 13F слишком не похоже на название в индексе (CUSIP точнее имени).
CUSIP_TICKER = {"02079K305": "GOOGL", "02079K107": "GOOG", "084670702": "BRK.B", "084670108": "BRK.A"}
NAME_TICKER = {"BANK OF AMER CORP": "BAC", "COCA COLA CO": "KO", "OCCIDENTAL PETE CORP": "OXY",
               "AMERICAN EXPRESS CO": "AXP", "CHEVRON CORPORATION": "CVX", "MOODYS CORP": "MCO",
               "KRAFT HEINZ CO": "KHC", "CAPITAL ONE FINL CORP": "COF", "NEW YORK TIMES CO MTN BE": "NYT",
               "JEFFERIES FINANCIAL GROUP IN": "JEF", "DELTA AIR LINES INC": "DAL", "CHUBB LIMITED": "CB"}

STOP = {"INC", "CORP", "CORPORATION", "CO", "COMPANY", "LTD", "LIMITED", "LLC", "PLC", "HOLDINGS", "HOLDING", "GROUP",
        "THE", "DEL", "NEW", "CL", "CLASS", "SA", "NV", "AG", "LP", "ADR", "ORD", "COM", "A", "B", "C", "INCORPORATED",
        "SHS", "SHARES", "TRUST", "INTERNATIONAL", "INTL"}


ABBREV = {"FINL": "FINANCIAL", "MATLS": "MATERIALS", "INDS": "INDUSTRIES", "MNG": "MINING", "SYS": "SYSTEMS",
          "PETE": "PETROLEUM", "AMER": "AMERICAN", "TECHN": "TECHNOLOGY", "TECH": "TECHNOLOGIES", "PHARMACEUTICALS": "PHARMA",
          "PHARMACEUTICAL": "PHARMA", "HLDGS": "", "HLDNGS": "", "HLDG": "", "SYST": "SYSTEMS", "ENTMT": "ENTERTAINMENT",
          "BANCORP": "BANCORP", "FINANCIALS": "FINANCIAL", "TECHNOLOGY": "TECHNOLOGIES"}


def norm(name):
    s = re.sub(r"[^A-Z0-9 ]", " ", (name or "").upper().replace("&", " AND ").replace("'", "").replace("’", ""))
    return " ".join(ABBREV.get(w, w) for w in s.split() if w not in STOP and ABBREV.get(w, w))


def load_name_map(base=BASE):
    """norm(название) -> тикер; при совпадении названий побеждает первый индекс реестра."""
    reg = json.loads((base / "indices" / "registry.json").read_text(encoding="utf-8"))
    names = {}
    for e in reg:
        path = base / e.get("constituents", "")
        if not path.is_file():
            continue
        with open(path, encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                t = (row.get("Symbol") or "").strip()
                n = norm(row.get("Security"))
                if t and n and n not in names:
                    names[n] = t
    return names


def match_ticker(name, cusip, names):
    if cusip in CUSIP_TICKER:
        return CUSIP_TICKER[cusip]
    if name.upper() in NAME_TICKER:
        return NAME_TICKER[name.upper()]
    n = norm(name)
    if not n:
        return None
    if n in names:
        return names[n]
    # 13F режет длинные названия («TENCENT MUSIC ENTERTAINM»): ищем единственное название с таким началом
    cands = {t for k, t in names.items() if min(len(k), len(n)) >= 5 and ((len(n.split()) > 1 and k.startswith(n)) or k.startswith(n + " "))}
    return cands.pop() if len(cands) == 1 else None


def build(src, names):
    gurus = []
    for key, display in GURUS.items():
        f = Path(src) / f"{key}.json"
        if not f.is_file():
            continue
        data = json.loads(f.read_text(encoding="utf-8"))
        quarters = sorted(data.get("quarters", []), key=lambda q: q["period"], reverse=True)
        if not quarters:
            continue
        cur = quarters[0]
        prev = quarters[1] if len(quarters) > 1 else None
        prev_shares = {}
        if prev:
            for h in prev["holdings"]:
                if not h.get("put_call"):
                    prev_shares[h["cusip"]] = prev_shares.get(h["cusip"], 0) + (h.get("shares") or 0)
        longs = [h for h in cur["holdings"] if not h.get("put_call")]
        total = sum(h.get("value") or 0 for h in longs)
        agg = {}
        for h in longs:
            t = match_ticker(h["name"], h["cusip"], names)
            if not t or total <= 0:
                continue
            a = agg.setdefault(t, {"value": 0, "shares": 0, "prev": 0, "had_prev": False})
            a["value"] += h.get("value") or 0
            a["shares"] += h.get("shares") or 0
            if h["cusip"] in prev_shares:
                a["had_prev"] = True
                a["prev"] += prev_shares[h["cusip"]]
        holdings = {}
        for t, a in agg.items():
            if prev is None:
                change = "hold"
            elif not a["had_prev"]:
                change = "new"
            elif a["shares"] > a["prev"] * 1.01:
                change = "add"
            elif a["shares"] < a["prev"] * 0.99:
                change = "reduce"
            else:
                change = "hold"
            weight = round(a["value"] / total * 100, 3)
            if weight > 0:  # доли тысячных процента не показываем
                holdings[t] = {"weightPct": weight, "changeQ": change}
        gurus.append({"key": key, "name": display, "reportDate": cur["period"], "holdings": holdings})
    return {"gurus": gurus}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", default=str(DEFAULT_SRC))
    ap.add_argument("--out", default=str(BASE / "data" / "guru_holdings.json"))
    args = ap.parse_args(argv)
    out = build(args.src, load_name_map())
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    for g in out["gurus"]:
        print(f"{g['key']:14s} {g['reportDate']}  привязано позиций: {len(g['holdings'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
