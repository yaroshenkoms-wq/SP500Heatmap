"""APNs-отправитель: JWT ES256 (кэш ~50 мин) + HTTP/2. Без переменных окружения — режим «disabled».

Переменные: APNS_KEY_PATH (.p8), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id).
"""
import os
import time
from dataclasses import dataclass
from typing import Optional

HOST_PRODUCTION = "https://api.push.apple.com"
HOST_SANDBOX = "https://api.sandbox.push.apple.com"
TOKEN_TTL = 50 * 60  # Apple: токен действует 1 час, обновлять не чаще чем раз в 20 мин
# причины, после которых токен устройства бесполезен и его удаляем
DEAD_REASONS = {"Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"}


@dataclass
class ApnsConfig:
    key_path: str = ""
    key_id: str = ""
    team_id: str = ""
    topic: str = ""

    @classmethod
    def from_env(cls):
        return cls(os.getenv("APNS_KEY_PATH", "").strip(), os.getenv("APNS_KEY_ID", "").strip(),
                   os.getenv("APNS_TEAM_ID", "").strip(), os.getenv("APNS_TOPIC", "").strip())

    @property
    def enabled(self) -> bool:
        return bool(self.key_path and self.key_id and self.team_id and self.topic and os.path.exists(self.key_path))


@dataclass
class ApnsResult:
    status: int
    reason: str = ""
    apns_id: str = ""

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def dead_token(self) -> bool:
        return self.status == 410 or (self.status == 400 and self.reason in DEAD_REASONS) or self.reason == "Unregistered"


def build_jwt(key_pem, key_id, team_id, now=None) -> str:
    import jwt
    return jwt.encode({"iss": team_id, "iat": int(now or time.time())}, key_pem, algorithm="ES256",
                      headers={"kid": key_id})


def host_for(env) -> str:
    return HOST_SANDBOX if (env or "").lower() == "sandbox" else HOST_PRODUCTION


class ApnsClient:
    def __init__(self, config: ApnsConfig, http=None, clock=time.time):
        self.config = config
        self._http = http  # httpx.AsyncClient (в тестах — подмена)
        self._clock = clock
        self._jwt = None
        self._jwt_at = 0.0

    @property
    def enabled(self) -> bool:
        return self.config.enabled

    def provider_token(self) -> str:
        now = self._clock()
        if self._jwt is None or now - self._jwt_at > TOKEN_TTL:
            with open(self.config.key_path, "rb") as f:
                pem = f.read()
            self._jwt = build_jwt(pem, self.config.key_id, self.config.team_id, now)
            self._jwt_at = now
        return self._jwt

    def reset_token(self):
        self._jwt = None

    def _client(self):
        if self._http is None:
            import httpx
            self._http = httpx.AsyncClient(http2=True, timeout=10.0)
        return self._http

    async def send(self, device_token, payload, *, env="production", push_type="alert", topic=None,
                   priority=10, collapse_id=None, expiration=None, _retry=True) -> ApnsResult:
        if not self.enabled:
            return ApnsResult(0, "disabled")
        import json
        base_topic = topic or self.config.topic
        if push_type == "liveactivity" and not base_topic.endswith(".push-type.liveactivity"):
            base_topic += ".push-type.liveactivity"
        headers = {"authorization": f"bearer {self.provider_token()}", "apns-topic": base_topic,
                   "apns-push-type": push_type, "apns-priority": str(priority)}
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        if expiration is not None:
            headers["apns-expiration"] = str(int(expiration))
        try:
            r = await self._client().post(f"{host_for(env)}/3/device/{device_token}", headers=headers,
                                          content=json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        except Exception as e:
            return ApnsResult(0, f"network:{type(e).__name__}")
        reason = ""
        if r.status_code != 200:
            try:
                reason = r.json().get("reason", "")
            except Exception:
                reason = r.text[:80]
        if r.status_code == 403 and reason in ("ExpiredProviderToken", "InvalidProviderToken") and _retry:
            self.reset_token()
            return await self.send(device_token, payload, env=env, push_type=push_type, topic=topic,
                                   priority=priority, collapse_id=collapse_id, expiration=expiration, _retry=False)
        return ApnsResult(r.status_code, reason, r.headers.get("apns-id", ""))
