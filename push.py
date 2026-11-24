"""Push-уведомления и Live Activity: реестр (push.db), вычисление правил (чистые функции), цикл отправки.

Серверные данные (цены, история, индексы) приходят через объект `ctx` (см. ServerContext) —
так правила проверяются без сети и без server.py.
"""
import asyncio
import json
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import push_i18n

RULE_TYPES = {"price_above", "price_below", "day_move", "index_move", "daily_summary", "news"}
MAX_RULES = 50
TOKEN_RE = re.compile(r"^[0-9A-Fa-f]{16,200}$")
NY = ZoneInfo("America/New_York")
BERLIN = ZoneInfo("Europe/Berlin")
LIVE_ATTRIBUTES_TYPE = os.getenv("LIVE_ACTIVITY_ATTRIBUTES_TYPE", "IndexActivityAttributes")


# ------------------------------------------------------------------ реестр (SQLite)

def connect(path):
    conn = sqlite3.connect(path, timeout=30)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, platform TEXT, env TEXT, lang TEXT, tz TEXT,
            rules TEXT NOT NULL DEFAULT '[]', created REAL, updated REAL);
        CREATE TABLE IF NOT EXISTS fired (token TEXT, key TEXT, at REAL, PRIMARY KEY (token, key));
        CREATE TABLE IF NOT EXISTS live (token TEXT PRIMARY KEY, kind TEXT, index_id TEXT, tickers TEXT,
            env TEXT, lang TEXT, last_sent_day TEXT, started_day TEXT, updated REAL);
    """)
    return conn


def register_device(path, token, platform="ios", env="production", lang="en", tz="UTC", now=None):
    if not TOKEN_RE.match(token or ""):
        raise ValueError("bad token")
    env = "sandbox" if env == "sandbox" else "production"
    try:
        ZoneInfo(tz or "UTC")
    except Exception:
        tz = "UTC"
    now = now or time.time()
    conn = connect(path)
    try:
        with conn:
            conn.execute(
                "INSERT INTO devices (token,platform,env,lang,tz,created,updated) VALUES (?,?,?,?,?,?,?) "
                "ON CONFLICT(token) DO UPDATE SET platform=excluded.platform, env=excluded.env, lang=excluded.lang, "
                "tz=excluded.tz, updated=excluded.updated",
                (token, platform or "ios", env, push_i18n.normalize_lang(lang), tz or "UTC", now, now))
    finally:
        conn.close()
    return token[:12]


def delete_device(path, token):
    conn = connect(path)
    try:
        with conn:
            n = conn.execute("DELETE FROM devices WHERE token=?", (token,)).rowcount
            conn.execute("DELETE FROM fired WHERE token=?", (token,))
        return n > 0
    finally:
        conn.close()


def clean_rules(rules):
    """Проверка и нормализация правил. Ошибка формата -> ValueError."""
    if not isinstance(rules, list) or len(rules) > MAX_RULES:
        raise ValueError("rules must be a list of at most %d" % MAX_RULES)
    out, seen = [], set()
    for r in rules:
        if not isinstance(r, dict) or r.get("type") not in RULE_TYPES or not str(r.get("id") or ""):
            raise ValueError("bad rule")
        rule = {"id": str(r["id"])[:64], "type": r["type"]}
        if rule["id"] in seen:
            raise ValueError("duplicate rule id")
        seen.add(rule["id"])
        if r.get("ticker"):
            rule["ticker"] = str(r["ticker"]).strip().upper()[:20]
        if r.get("indexId"):
            rule["indexId"] = str(r["indexId"]).strip()[:40]
        if r.get("value") is not None:
            try:
                rule["value"] = float(r["value"])
            except (TypeError, ValueError):
                raise ValueError("bad value")
        t = rule["type"]
        if t in ("price_above", "price_below", "day_move") and ("ticker" not in rule or "value" not in rule):
            raise ValueError(f"{t} needs ticker and value")
        if t == "index_move" and ("indexId" not in rule or "value" not in rule):
            raise ValueError("index_move needs indexId and value")
        out.append(rule)
    return out


def set_rules(path, token, rules, now=None):
    rules = clean_rules(rules)
    conn = connect(path)
    try:
        with conn:
            n = conn.execute("UPDATE devices SET rules=?, updated=? WHERE token=?",
                             (json.dumps(rules), now or time.time(), token)).rowcount
        return len(rules) if n else None
    finally:
        conn.close()


def list_devices(path):
    conn = connect(path)
    try:
        out = []
        for r in conn.execute("SELECT * FROM devices"):
            d = dict(r)
            d["rules"] = json.loads(d["rules"] or "[]")
            out.append(d)
        return out
    finally:
        conn.close()


def was_fired(path, token, key):
    conn = connect(path)
    try:
        return conn.execute("SELECT 1 FROM fired WHERE token=? AND key=?", (token, key)).fetchone() is not None
    finally:
        conn.close()


def mark_fired(path, token, key, now=None, keep_days=3):
    now = now or time.time()
    conn = connect(path)
    try:
        with conn:
            conn.execute("INSERT OR IGNORE INTO fired VALUES (?,?,?)", (token, key, now))
            conn.execute("DELETE FROM fired WHERE at < ?", (now - keep_days * 86400,))
    finally:
        conn.close()


def upsert_live(path, token, kind, index_id, tickers, env="production", lang="en", now=None):
    if not TOKEN_RE.match(token or ""):
        raise ValueError("bad token")
    if kind not in ("start", "update"):
        raise ValueError("bad kind")
    conn = connect(path)
    try:
        with conn:
            conn.execute(
                "INSERT INTO live (token,kind,index_id,tickers,env,lang,updated) VALUES (?,?,?,?,?,?,?) "
                "ON CONFLICT(token) DO UPDATE SET kind=excluded.kind, index_id=excluded.index_id, "
                "tickers=excluded.tickers, env=excluded.env, lang=excluded.lang, updated=excluded.updated",
                (token, kind, index_id, json.dumps([t.upper() for t in (tickers or [])][:10]),
                 "sandbox" if env == "sandbox" else "production", push_i18n.normalize_lang(lang), now or time.time()))
    finally:
        conn.close()


def delete_live(path, token):
    conn = connect(path)
    try:
        with conn:
            return conn.execute("DELETE FROM live WHERE token=?", (token,)).rowcount > 0
    finally:
        conn.close()


def list_live(path):
    conn = connect(path)
    try:
        out = []
        for r in conn.execute("SELECT * FROM live"):
            d = dict(r)
            d["tickers"] = json.loads(d["tickers"] or "[]")
            out.append(d)
        return out
    finally:
        conn.close()


def mark_live(path, token, **fields):
    conn = connect(path)
    try:
        with conn:
            for k, v in fields.items():
                if k in ("last_sent_day", "started_day"):
                    conn.execute(f"UPDATE live SET {k}=? WHERE token=?", (v, token))
    finally:
        conn.close()


# ------------------------------------------------------------------ чистые функции правил

def fmt_pct(x):
    return f"{x:+.2f}%"


def fmt_price(x):
    return f"{x:,.2f}" if x < 1000 else f"{x:,.0f}"


def fmt_value(x):
    return f"{x:g}"


def top_mover_text(movers):
    return f"{movers[0]['ticker']} {fmt_pct(movers[0]['changePct'])}" if movers else "-"


def local_summary_due(now_utc, tz_name):
    """Итоги дня: после закрытия США (16:30 NY, будни) и не раньше 18:00 по времени устройства."""
    ny = now_utc.astimezone(NY)
    if ny.weekday() >= 5 or (ny.hour, ny.minute) < (16, 30):
        return False
    try:
        local = now_utc.astimezone(ZoneInfo(tz_name or "UTC"))
    except Exception:
        local = now_utc
    return local.hour >= 18


def evaluate_rule(rule, ctx, now_utc, tz="UTC", news_max_age=3 * 3600):
    """Возвращает список событий: {"key","template","params","data"}; дедупликацию делает вызывающий (по key).

    ctx: quote(ticker)->{"price","change_percent"}|None, index(id)->{"name","changePct","movers"}|None,
         news(ticker|None)->[{"id","title","published",...}]."""
    t = rule["type"]
    day = now_utc.astimezone(NY).strftime("%Y-%m-%d")
    rid = rule["id"]
    ev = []
    if t in ("price_above", "price_below"):
        q = ctx.quote(rule["ticker"])
        if q and q.get("price") is not None:
            hit = q["price"] >= rule["value"] if t == "price_above" else q["price"] <= rule["value"]
            if hit:
                ev.append({"key": f"{rid}:{day}", "template": t,
                           "params": {"ticker": rule["ticker"], "value": fmt_value(rule["value"]),
                                      "price": fmt_price(q["price"]), "chg": fmt_pct(q["change_percent"])},
                           "data": {"ruleId": rid, "type": t, "ticker": rule["ticker"]}})
    elif t == "day_move":
        q = ctx.quote(rule["ticker"])
        if q and q.get("change_percent") is not None and abs(q["change_percent"]) >= rule["value"]:
            up = q["change_percent"] >= 0
            ev.append({"key": f"{rid}:{day}", "template": "day_move_up" if up else "day_move_down",
                       "params": {"ticker": rule["ticker"], "value": fmt_value(rule["value"]),
                                  "price": fmt_price(q["price"]), "chg": f"{abs(q['change_percent']):.2f}%"},
                       "data": {"ruleId": rid, "type": t, "ticker": rule["ticker"]}})
    elif t == "index_move":
        ix = ctx.index(rule["indexId"])
        if ix and ix.get("changePct") is not None and abs(ix["changePct"]) >= rule["value"]:
            up = ix["changePct"] >= 0
            ev.append({"key": f"{rid}:{day}", "template": "index_move_up" if up else "index_move_down",
                       "params": {"name": ix["name"], "chg": f"{abs(ix['changePct']):.2f}%", "top": top_mover_text(ix["movers"])},
                       "data": {"ruleId": rid, "type": t, "indexId": rule["indexId"]}})
    elif t == "daily_summary":
        if local_summary_due(now_utc, tz):
            ix = ctx.index(rule.get("indexId") or "sp500")
            if ix and ix.get("changePct") is not None:
                ev.append({"key": f"{rid}:{day}", "template": "daily_summary",
                           "params": {"name": ix["name"], "chg": fmt_pct(ix["changePct"]), "top": top_mover_text(ix["movers"])},
                           "data": {"ruleId": rid, "type": t, "indexId": rule.get("indexId") or "sp500"}})
    elif t == "news":
        tk = rule.get("ticker")
        for n in ctx.news(tk):
            pub = n.get("published")
            if pub:
                try:
                    age = now_utc.timestamp() - datetime.fromisoformat(pub.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    age = 0
                if age > news_max_age:
                    continue
            ev.append({"key": f"{rid}:news:{n['id']}", "template": "news" if tk else "news_market",
                       "params": {"ticker": tk or "", "title": n["title"]},
                       "data": {"ruleId": rid, "type": t, "ticker": tk, "url": n.get("url")},
                       "news_id": n["id"]})
    return ev


def build_alert_payload(event, lang):
    title, body = push_i18n.render(lang, event["template"], **event["params"])
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default",
                       "thread-id": event["data"].get("ticker") or event["data"].get("indexId") or "market"}}
    payload.update({k: v for k, v in event["data"].items() if v is not None})
    return payload


# ------------------------------------------------------------------ Live Activity

def iso_utc(now_utc):
    return now_utc.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def live_content_state(index_id, name, change_pct, movers, now_utc, value=None):
    """Формат ActivityAttributes.ContentState (JSON-ключи): indexId, name, changePct, value?, movers[{ticker,changePct}], asOf (ISO-строка)."""
    st = {"indexId": index_id, "name": name, "changePct": round(change_pct, 2),
          "movers": [{"ticker": m["ticker"], "changePct": round(m["changePct"], 2)} for m in movers[:3]],
          "asOf": iso_utc(now_utc)}
    if value is not None:
        st["value"] = value
    return st


def live_payload(event, state, now_utc, lang="en", attributes=None, final=False):
    """event: start | update | end."""
    ts = int(now_utc.timestamp())
    aps = {"timestamp": ts, "event": event, "content-state": state}
    if event == "start":
        aps["attributes-type"] = LIVE_ATTRIBUTES_TYPE
        aps["attributes"] = attributes or {"indexId": state["indexId"], "name": state["name"]}
        title, body = push_i18n.render(lang, "la_start", name=state["name"], chg=fmt_pct(state["changePct"]))
        aps["alert"] = {"title": title, "body": body}
    if event == "end":
        aps["dismissal-date"] = ts + 30 * 60  # итог остаётся на экране ещё 30 минут
    return {"aps": aps}


def session_open_us(now_utc):
    ny = now_utc.astimezone(NY)
    if ny.weekday() >= 5:
        return False
    return (9, 30) <= (ny.hour, ny.minute) < (16, 0)


def session_open_eu(now_utc):
    b = now_utc.astimezone(BERLIN)
    if b.weekday() >= 5:
        return False
    return (8, 55) <= (b.hour, b.minute) < (17, 35)


# ------------------------------------------------------------------ данные сервера для правил

class ServerContext:
    """Обёртка над server.py: котировки из price_cache, индексы по составу CSV, новости из кэша. Кэш на один цикл."""

    def __init__(self, srv, news_path, news_fetcher=None):
        self.srv, self.news_path, self.news_fetcher = srv, news_path, news_fetcher
        self._index = {}
        self._news = {}

    def quote(self, ticker):
        e = self.srv.price_cache.get(ticker)
        if e and e.get("price") is not None:
            return {"price": e["price"], "change_percent": e.get("change_percent") or 0.0}
        s = self.srv.lookup_series(ticker)
        if s and len(s) >= 2 and s[-2]["close"] > 0:
            return {"price": s[-1]["close"], "change_percent": (s[-1]["close"] / s[-2]["close"] - 1) * 100}
        return None

    def index(self, index_id, only=None):
        key = (index_id, tuple(only or ()))
        if key in self._index:
            return self._index[key]
        res = None
        entry = self.srv.find_index(index_id)
        if entry:
            res = index_snapshot(entry["name"], self.srv.load_index_rows(entry), self.quote, self.srv._parse_cap, only)
        self._index[key] = res
        return res

    def news(self, ticker):
        if ticker in self._news:
            return self._news[ticker]
        import news as newsmod
        try:
            items = newsmod.symbol_news(self.news_path, ticker, self.news_fetcher) if ticker else \
                newsmod.merge([newsmod.symbol_news(self.news_path, s, self.news_fetcher) for s in newsmod.MARKET_SYMBOLS[:1]], 20)
        except Exception:
            items = []
        self._news[ticker] = items
        return items


def index_snapshot(name, rows, quote, parse_cap, only=None):
    """Изменение индекса за день (взвешено по капитализации) и три сильнейших движения. only — ограничить тикерами."""
    num = den = 0.0
    movers = []
    for r in rows:
        if only and r["ticker"] not in only:
            continue
        q = quote(r["ticker"])
        if not q:
            continue
        w = parse_cap(r.get("cap")) or 1.0
        num += w * q["change_percent"]
        den += w
        movers.append({"ticker": r["ticker"], "changePct": q["change_percent"]})
    if not den:
        return None
    movers.sort(key=lambda m: abs(m["changePct"]), reverse=True)
    return {"name": name, "changePct": num / den, "movers": movers[:3]}


# ------------------------------------------------------------------ цикл отправки

def collect_events(path, ctx, now_utc, include_news=True):
    """Синхронно: [(device, event)] по ещё не отправленным ключам. Новостные правила при первом просмотре только «засеваются»."""
    out = []
    for dev in list_devices(path):
        for rule in dev["rules"]:
            if rule["type"] == "news" and not include_news:
                continue
            try:
                evs = evaluate_rule(rule, ctx, now_utc, dev["tz"])
            except Exception as e:
                print(f"⚠️ push rule {rule.get('id')}: {e}")
                continue
            if rule["type"] == "news":
                seed = f"{rule['id']}:seeded"
                if not was_fired(path, dev["token"], seed):
                    # первый просмотр: помечаем всё текущее, не шлём (иначе лавина старых новостей)
                    tk = rule.get("ticker")
                    import news as newsmod
                    for n in ctx.news(tk):
                        mark_fired(path, dev["token"], f"{rule['id']}:news:{n['id']}")
                    mark_fired(path, dev["token"], seed)
                    continue
                evs = evs[:1]
            for ev in evs:
                if not was_fired(path, dev["token"], ev["key"]):
                    out.append((dev, ev))
    return out


async def dispatch_events(path, client, events):
    sent = 0
    for dev, ev in events:
        payload = build_alert_payload(ev, dev["lang"])
        res = await client.send(dev["token"], payload, env=dev["env"], push_type="alert",
                                collapse_id=ev["key"][:60])
        if res.ok:
            mark_fired(path, dev["token"], ev["key"])
            sent += 1
        elif res.dead_token:
            print(f"push: токен {dev['token'][:8]}… удалён ({res.status} {res.reason})")
            delete_device(path, dev["token"])
        else:
            print(f"⚠️ APNs {res.status} {res.reason} для {dev['token'][:8]}…")
    return sent


def plan_live(path, ctx, now_utc):
    """[(row, event_name, payload)] для Live Activity: update каждый цикл в сессию США, start — раз в день для
    push-to-start токенов, end — после закрытия (один раз в день)."""
    out = []
    us_open = session_open_us(now_utc)
    ny = now_utc.astimezone(NY)
    day = ny.strftime("%Y-%m-%d")
    after_close = ny.weekday() < 5 and (ny.hour, ny.minute) >= (16, 0) and ny.hour < 20
    for row in list_live(path):
        ix = ctx.index(row["index_id"], only=set(row["tickers"]) or None)
        if not ix:
            continue
        state = live_content_state(row["index_id"], ix["name"], ix["changePct"], ix["movers"], now_utc)
        if us_open:
            if row["kind"] == "start":
                if row["started_day"] != day:
                    out.append((row, "start", live_payload("start", state, now_utc, row["lang"])))
            else:
                out.append((row, "update", live_payload("update", state, now_utc)))
        elif after_close and row["last_sent_day"] != day and (row["kind"] == "update" or row["started_day"] == day):
            out.append((row, "end", live_payload("end", state, now_utc)))
    return out


async def dispatch_live(path, client, plan, now_utc):
    day = now_utc.astimezone(NY).strftime("%Y-%m-%d")
    for row, name, payload in plan:
        res = await client.send(row["token"], payload, env=row["env"], push_type="liveactivity",
                                priority=5 if name == "update" else 10)
        if res.ok:
            if name == "start":
                mark_live(path, row["token"], started_day=day)
            elif name == "end":
                mark_live(path, row["token"], last_sent_day=day)
                if row["kind"] == "update":
                    delete_live(path, row["token"])
        elif res.dead_token:
            delete_live(path, row["token"])
        else:
            print(f"⚠️ APNs live {res.status} {res.reason}")


async def sender_loop(srv, path, news_path, client, interval=60):
    """Раз в минуту: правила (в сессии США/Европы и для итогов дня) + Live Activity. Нет ключей APNs — только лог."""
    if not client.enabled:
        print("APNs disabled: нет APNS_KEY_PATH/APNS_KEY_ID/APNS_TEAM_ID/APNS_TOPIC — регистрации хранятся, отправки нет")
        return
    print("APNs enabled: проверка правил раз в минуту")
    cycle = 0
    while True:
        try:
            now = datetime.now(timezone.utc)
            ctx = ServerContext(srv, news_path)
            events = await asyncio.to_thread(collect_events, path, ctx, now, cycle % 5 == 0)
            await dispatch_events(path, client, events)
            plan = await asyncio.to_thread(plan_live, path, ctx, now)
            await dispatch_live(path, client, plan, now)
        except Exception as e:
            print(f"⚠️ push цикл: {e}")
        cycle += 1
        await asyncio.sleep(interval)
