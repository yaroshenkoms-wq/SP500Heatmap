import asyncio
import json
import os
import sys
from datetime import datetime, timezone

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import apns
import news as newsmod
import push
import push_i18n

TOKEN = "ab" * 32


def utc(y, m, d, h, mi=0):
    return datetime(y, m, d, h, mi, tzinfo=timezone.utc)


class FakeCtx:
    def __init__(self, quotes=None, indexes=None, news=None):
        self.q, self.ix, self.n = quotes or {}, indexes or {}, news or {}

    def quote(self, t):
        return self.q.get(t)

    def index(self, i, only=None):
        return self.ix.get(i)

    def news(self, t):
        return self.n.get(t, [])


# ---------------------------------------------------------------- правила
NOW = utc(2026, 11, 24, 15, 0)  # вторник, 10:00 NY


def test_price_above_hit_and_miss():
    r = {"id": "r1", "type": "price_above", "ticker": "AAPL", "value": 200}
    hit = push.evaluate_rule(r, FakeCtx({"AAPL": {"price": 201.5, "change_percent": 1.2}}), NOW)
    assert len(hit) == 1 and hit[0]["key"] == "r1:2026-11-24" and hit[0]["params"]["price"] == "201.50"
    assert push.evaluate_rule(r, FakeCtx({"AAPL": {"price": 199, "change_percent": 1}}), NOW) == []
    assert push.evaluate_rule(r, FakeCtx(), NOW) == []


def test_price_below_and_day_move_direction():
    r = {"id": "r2", "type": "price_below", "ticker": "X", "value": 10}
    assert push.evaluate_rule(r, FakeCtx({"X": {"price": 9, "change_percent": -3}}), NOW)
    d = {"id": "r3", "type": "day_move", "ticker": "X", "value": 3}
    up = push.evaluate_rule(d, FakeCtx({"X": {"price": 9, "change_percent": 3.5}}), NOW)[0]
    down = push.evaluate_rule(d, FakeCtx({"X": {"price": 9, "change_percent": -4}}), NOW)[0]
    assert up["template"] == "day_move_up" and down["template"] == "day_move_down"
    assert push.evaluate_rule(d, FakeCtx({"X": {"price": 9, "change_percent": 2.9}}), NOW) == []


def test_index_move():
    r = {"id": "i", "type": "index_move", "indexId": "sp500", "value": 1}
    ix = {"sp500": {"name": "S&P 500", "changePct": -1.4, "movers": [{"ticker": "NVDA", "changePct": -4.0}]}}
    ev = push.evaluate_rule(r, FakeCtx(indexes=ix), NOW)[0]
    assert ev["template"] == "index_move_down" and ev["params"]["top"] == "NVDA -4.00%"


def test_daily_summary_time_window():
    r = {"id": "s", "type": "daily_summary"}
    ix = {"sp500": {"name": "S&P 500", "changePct": 0.5, "movers": []}}
    c = FakeCtx(indexes=ix)
    assert push.evaluate_rule(r, c, utc(2026, 11, 24, 15), "Europe/Madrid") == []   # США открыты
    assert push.evaluate_rule(r, c, utc(2026, 11, 24, 21, 45), "Europe/Madrid")     # 22:45 Мадрид, после 16:30 NY
    assert push.evaluate_rule(r, c, utc(2026, 11, 28, 22, 0), "Europe/Madrid") == []  # суббота


def test_news_rule_skips_old_items():
    r = {"id": "n", "type": "news", "ticker": "AAPL"}
    items = [{"id": "a", "title": "Fresh", "published": "2026-11-24T14:00:00Z", "url": "u1"},
             {"id": "b", "title": "Old", "published": "2026-11-23T01:00:00Z", "url": "u2"}]
    evs = push.evaluate_rule(r, FakeCtx(news={"AAPL": items}), NOW)
    assert [e["news_id"] for e in evs] == ["a"]


def test_clean_rules_validation():
    ok = push.clean_rules([{"id": "1", "type": "price_above", "ticker": "aapl", "value": "190"}])
    assert ok[0]["ticker"] == "AAPL" and ok[0]["value"] == 190.0
    for bad in ([{"id": "1", "type": "nope"}], [{"id": "1", "type": "price_above"}],
                [{"id": "1", "type": "news"}, {"id": "1", "type": "news"}], "x"):
        with pytest.raises(ValueError):
            push.clean_rules(bad)


# ---------------------------------------------------------------- тексты
def test_templates_complete_for_all_languages():
    base = set(push_i18n.T["en"])
    assert set(push_i18n.T) == set(push_i18n.LANGS) and len(push_i18n.LANGS) == 9
    for lang in push_i18n.LANGS:
        assert set(push_i18n.T[lang]) == base, lang
        for key in base:
            t, b = push_i18n.render(lang, key, ticker="AAPL", value="200", price="201", chg="+1.00%",
                                    name="S&P 500", top="NVDA +3%", title="Hello")
            assert t and b and "{" not in t + b


def test_normalize_lang():
    assert push_i18n.normalize_lang("zh-Hans-CN") == "zh-Hans"
    assert push_i18n.normalize_lang("es_ES") == "es"
    assert push_i18n.normalize_lang("xx") == "en"


def test_alert_payload_shape():
    ev = push.evaluate_rule({"id": "r", "type": "price_above", "ticker": "AAPL", "value": 200},
                            FakeCtx({"AAPL": {"price": 210, "change_percent": 2}}), NOW)[0]
    p = push.build_alert_payload(ev, "es")
    assert p["aps"]["alert"]["title"] == "AAPL supera 200"
    assert p["ruleId"] == "r" and p["ticker"] == "AAPL" and p["aps"]["sound"] == "default"


# ---------------------------------------------------------------- Live Activity
def test_live_payloads():
    st = push.live_content_state("sp500", "S&P 500", 0.456, [{"ticker": "A", "changePct": 1.234}] * 5, NOW)
    assert st == {"indexId": "sp500", "name": "S&P 500", "changePct": 0.46,
                  "movers": [{"ticker": "A", "changePct": 1.23}] * 3, "asOf": "2026-11-24T15:00:00Z"}
    up = push.live_payload("update", st, NOW)
    assert up["aps"]["event"] == "update" and up["aps"]["content-state"] == st and "attributes" not in up["aps"]
    start = push.live_payload("start", st, NOW, "ru")
    assert start["aps"]["attributes-type"] and start["aps"]["attributes"]["indexId"] == "sp500"
    assert start["aps"]["alert"]["title"] == "S&P 500 онлайн"
    end = push.live_payload("end", st, NOW)
    assert end["aps"]["event"] == "end" and end["aps"]["dismissal-date"] > end["aps"]["timestamp"]


def test_index_snapshot_weighting():
    rows = [{"ticker": "A", "cap": "300"}, {"ticker": "B", "cap": "100"}]
    q = {"A": {"change_percent": 1.0}, "B": {"change_percent": -3.0}}.get
    snap = push.index_snapshot("T", rows, q, float)
    assert snap["changePct"] == pytest.approx(0.0) and snap["movers"][0]["ticker"] == "B"


# ---------------------------------------------------------------- реестр и цикл
def test_registry_roundtrip_and_dedupe(tmp_path):
    db = str(tmp_path / "p.db")
    push.register_device(db, TOKEN, "ios", "sandbox", "fr", "Europe/Paris")
    assert push.set_rules(db, TOKEN, [{"id": "r", "type": "price_above", "ticker": "AAPL", "value": 100}]) == 1
    assert push.set_rules(db, "ff" * 20, []) is None
    ctx = FakeCtx({"AAPL": {"price": 150, "change_percent": 1}})
    evs = push.collect_events(db, ctx, NOW)
    assert len(evs) == 1 and evs[0][0]["lang"] == "fr" and evs[0][0]["env"] == "sandbox"
    push.mark_fired(db, TOKEN, evs[0][1]["key"])
    assert push.collect_events(db, ctx, NOW) == []
    with pytest.raises(ValueError):
        push.register_device(db, "zz!", "ios")
    assert push.delete_device(db, TOKEN) and push.list_devices(db) == []


def test_news_rule_first_pass_seeds_silently(tmp_path):
    db = str(tmp_path / "p.db")
    push.register_device(db, TOKEN)
    push.set_rules(db, TOKEN, [{"id": "n", "type": "news", "ticker": "AAPL"}])
    item = {"id": "a", "title": "T", "published": "2026-11-24T14:30:00Z", "url": "u"}
    ctx = FakeCtx(news={"AAPL": [item]})
    assert push.collect_events(db, ctx, NOW) == []
    new = {"id": "b", "title": "T2", "published": "2026-11-24T14:50:00Z", "url": "u2"}
    ctx = FakeCtx(news={"AAPL": [new, item]})
    evs = push.collect_events(db, ctx, NOW)
    assert [e[1]["news_id"] for e in evs] == ["b"]


class FakeClient:
    enabled = True

    def __init__(self, status=200, reason=""):
        self.sent, self.status, self.reason = [], status, reason

    async def send(self, token, payload, **kw):
        self.sent.append((token, payload, kw))
        return apns.ApnsResult(self.status, self.reason)


def test_dispatch_marks_fired_and_removes_dead(tmp_path):
    db = str(tmp_path / "p.db")
    push.register_device(db, TOKEN, lang="ru")
    push.set_rules(db, TOKEN, [{"id": "r", "type": "price_above", "ticker": "AAPL", "value": 100}])
    ctx = FakeCtx({"AAPL": {"price": 150, "change_percent": 1}})
    ok = FakeClient()
    asyncio.run(push.dispatch_events(db, ok, push.collect_events(db, ctx, NOW)))
    assert ok.sent[0][1]["aps"]["alert"]["title"] == "AAPL выше 100"
    assert push.collect_events(db, ctx, NOW) == []
    push.mark_fired  # noqa
    dead = FakeClient(410, "Unregistered")
    conn = push.connect(db); conn.execute("DELETE FROM fired"); conn.commit(); conn.close()
    asyncio.run(push.dispatch_events(db, dead, push.collect_events(db, ctx, NOW)))
    assert push.list_devices(db) == []


def test_plan_live_session_logic(tmp_path):
    db = str(tmp_path / "p.db")
    push.upsert_live(db, TOKEN, "update", "sp500", [])
    push.upsert_live(db, "cd" * 20, "start", "sp500", [])
    ix = {"sp500": {"name": "S&P 500", "changePct": 0.3, "movers": [{"ticker": "A", "changePct": 1.0}]}}
    ctx = FakeCtx(indexes=ix)
    plan = push.plan_live(db, ctx, NOW)
    assert sorted(p[1] for p in plan) == ["start", "update"]
    after = push.plan_live(db, ctx, utc(2026, 11, 24, 21, 10))  # 16:10 NY
    assert [p[1] for p in after] == ["end"]  # start-токен без начатой сегодня активности не закрываем
    assert push.plan_live(db, ctx, utc(2026, 11, 28, 15)) == []


# ---------------------------------------------------------------- APNs
@pytest.fixture
def key_file(tmp_path):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    k = ec.generate_private_key(ec.SECP256R1())
    p = tmp_path / "AuthKey_TEST.p8"
    p.write_bytes(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    return str(p), k


class FakeResp:
    def __init__(self, status, body=None):
        self.status_code, self._b, self.headers, self.text = status, body or {}, {"apns-id": "X"}, ""

    def json(self):
        return self._b


class FakeHttp:
    def __init__(self, *responses):
        self.responses, self.calls = list(responses), []

    async def post(self, url, headers=None, content=None):
        self.calls.append((url, headers, json.loads(content)))
        return self.responses.pop(0)


def make_client(key_file, http, clock=lambda: 1000.0):
    path, _ = key_file
    return apns.ApnsClient(apns.ApnsConfig(path, "KEYID123", "TEAMID1234", "com.x.app"), http, clock)


def test_jwt_is_valid_es256_and_cached(key_file):
    import jwt
    path, k = key_file
    t = {"now": 1000.0}
    c = make_client(key_file, None, clock=lambda: t["now"])
    tok = c.provider_token()
    hdr = jwt.get_unverified_header(tok)
    claims = jwt.decode(tok, k.public_key(), algorithms=["ES256"], options={"verify_iat": False})
    assert hdr["kid"] == "KEYID123" and hdr["alg"] == "ES256" and claims["iss"] == "TEAMID1234" and claims["iat"] == 1000
    t["now"] = 1000 + 49 * 60
    assert c.provider_token() == tok
    t["now"] = 1000 + 51 * 60
    assert c.provider_token() != tok


def test_send_hosts_headers_and_live_topic(key_file):
    http = FakeHttp(FakeResp(200), FakeResp(200))
    c = make_client(key_file, http)
    r = asyncio.run(c.send("tok", {"aps": {}}, env="sandbox"))
    assert r.ok and http.calls[0][0] == "https://api.sandbox.push.apple.com/3/device/tok"
    assert http.calls[0][1]["apns-topic"] == "com.x.app" and http.calls[0][1]["apns-push-type"] == "alert"
    asyncio.run(c.send("tok", {"aps": {}}, env="production", push_type="liveactivity", priority=5))
    assert http.calls[1][0].startswith("https://api.push.apple.com/")
    assert http.calls[1][1]["apns-topic"] == "com.x.app.push-type.liveactivity"
    assert http.calls[1][1]["apns-push-type"] == "liveactivity" and http.calls[1][1]["apns-priority"] == "5"


def test_send_error_handling(key_file):
    for status, reason, dead in [(410, "Unregistered", True), (400, "BadDeviceToken", True),
                                 (429, "TooManyRequests", False), (500, "InternalServerError", False)]:
        r = asyncio.run(make_client(key_file, FakeHttp(FakeResp(status, {"reason": reason}))).send("t", {}))
        assert r.dead_token is dead and r.reason == reason and not r.ok
    http = FakeHttp(FakeResp(403, {"reason": "ExpiredProviderToken"}), FakeResp(200))
    r = asyncio.run(make_client(key_file, http).send("t", {}))
    assert r.ok and len(http.calls) == 2


def test_disabled_mode(monkeypatch):
    for k in ("APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"):
        monkeypatch.delenv(k, raising=False)
    c = apns.ApnsClient(apns.ApnsConfig.from_env())
    assert not c.enabled
    assert asyncio.run(c.send("t", {})).reason == "disabled"
    asyncio.run(push.sender_loop(None, "x", "y", c))  # возвращается сразу, без ошибок


# ---------------------------------------------------------------- новости
RSS = b"""<?xml version="1.0"?><rss version="2.0"><channel>
<item><title>Bolsa sube</title><link>https://e.es/1</link><pubDate>Tue, 24 Nov 2026 10:00:00 +0100</pubDate></item>
<item><title>Sin enlace</title></item></channel></rss>"""


def test_parse_rss_and_merge():
    items = newsmod.parse_rss(RSS, "Exp", "es")
    assert len(items) == 1 and items[0]["published"] == "2026-11-24T09:00:00Z" and items[0]["lang"] == "es"
    a = newsmod.make_item("T", "P", "u", "2026-11-24T10:00:00Z", ["AAPL"], "en")
    b = newsmod.make_item("T", "P", "u", "2026-11-24T10:00:00Z", ["MSFT"], "en")
    c = newsmod.make_item("T2", "P", "u2", "2026-11-24T11:00:00Z", [], "en")
    m = newsmod.merge([[a], [b, c]], 10)
    assert [i["url"] for i in m] == ["u2", "u"] and m[1]["tickers"] == ["AAPL", "MSFT"]


def test_build_news_cache_and_lang(tmp_path):
    db = str(tmp_path / "n.db")
    calls = []

    def yahoo(sym):
        calls.append(sym)
        return [{"title": f"News {sym}", "publisher": "Y", "link": f"https://y/{sym}", "providerPublishTime": 1795000000}]

    rss_calls = []

    def rss(url):
        rss_calls.append(url)
        return RSS

    out = newsmod.build_news(db, "tickers", ["AAPL"], "en", 50, yahoo, rss)
    assert [i["tickers"] for i in out] == [["AAPL"]]
    newsmod.build_news(db, "tickers", ["AAPL"], "en", 50, yahoo, rss)
    assert calls == ["AAPL"]  # второй раз из кэша
    es = newsmod.build_news(db, "market", [], "es", 50, yahoo, rss)
    assert any(i["lang"] == "es" for i in es) and rss_calls
    assert all(set(i) == {"id", "title", "publisher", "url", "published", "tickers", "lang"} for i in es)


# ---------------------------------------------------------------- HTTP-эндпоинты
def test_endpoints(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    import server
    monkeypatch.setattr(server, "PUSH_DB_PATH", str(tmp_path / "p.db"))
    monkeypatch.setattr(server, "NEWS_DB_PATH", str(tmp_path / "n.db"))
    c = TestClient(server.app)
    r = c.post("/api/v1/push/register", json={"token": TOKEN, "platform": "ios", "env": "sandbox", "lang": "es", "tz": "Europe/Madrid"})
    assert r.status_code == 200 and "id" in r.json()
    assert c.post("/api/v1/push/register", json={"token": "bad"}).status_code == 422
    rules = {"rules": [{"id": "1", "type": "price_above", "ticker": "AAPL", "value": 200}]}
    assert c.put(f"/api/v1/push/rules/{TOKEN}", json=rules).json() == {"count": 1}
    assert c.put("/api/v1/push/rules/" + "ee" * 20, json=rules).status_code == 404
    assert c.put(f"/api/v1/push/rules/{TOKEN}", json={"rules": [{"id": "1", "type": "zzz"}]}).status_code == 422
    la = {"token": "cd" * 20, "kind": "update", "indexId": "sp500", "tickers": ["AAPL"], "deviceToken": TOKEN}
    assert c.post("/api/v1/push/liveactivity", json=la).json() == {"ok": True}
    assert c.post("/api/v1/push/liveactivity", json=dict(la, indexId="nope")).status_code == 404
    assert c.delete("/api/v1/push/liveactivity/" + "cd" * 20).json() == {"deleted": True}
    assert c.delete(f"/api/v1/push/register/{TOKEN}").json() == {"deleted": True}
    assert c.get("/api/v1/news?scope=bogus").status_code == 422
    assert c.get("/api/v1/news?scope=tickers").json() == {"items": []}
