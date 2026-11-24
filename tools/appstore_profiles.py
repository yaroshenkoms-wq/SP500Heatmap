#!/usr/bin/env python3
"""Создаёт профили App Store для приложения и виджета через ключ App Store Connect API
(в командной строке Xcode не видит аккаунт, облачной подписи у ключа нет).
Возможности (push, iCloud, App Group) у идентификаторов уже включены — их зарегистрировал Xcode.
Запуск: python3 tools/appstore_profiles.py  → печатает имена профилей для ExportOptions."""
import base64
import hashlib
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path.home() / "Desktop/App/Uni/Tools"))
import asc  # noqa: E402

TARGETS = [("com.maximyaroshenko.SP500Heatmap2", "SP500Heatmap AppStore 1.1"),
           ("com.maximyaroshenko.SP500Heatmap2.Widgets", "SP500Heatmap Widgets AppStore 1.1")]

local = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
certs = asc.call("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50").get("data", [])
mine = [c for c in certs if hashlib.sha1(base64.b64decode(c["attributes"]["certificateContent"])).hexdigest().upper() in local]
if not mine:
    sys.exit("нет сертификата распространения, совпадающего с ключами на этом Mac")
mine.sort(key=lambda c: c["attributes"]["expirationDate"], reverse=True)
print("certificate", mine[0]["attributes"]["name"], mine[0]["attributes"]["expirationDate"][:10])

for bundle, name in TARGETS:
    ids = [b for b in asc.call("GET", f"/v1/bundleIds?filter[identifier]={bundle}").get("data", [])
           if b["attributes"]["identifier"] == bundle]
    if not ids:
        sys.exit(f"идентификатор {bundle} не зарегистрирован")
    for p in asc.call("GET", "/v1/profiles?filter[name]=" + name.replace(" ", "%20")).get("data", []):
        asc.call("DELETE", f"/v1/profiles/{p['id']}")
    r = asc.call("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": ids[0]["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": mine[0]["id"]}]}}}})
    if "data" not in r:
        sys.exit(f"profile {bundle}: {r}")
    raw = base64.b64decode(r["data"]["attributes"]["profileContent"])
    uuid = r["data"]["attributes"]["uuid"]
    for d in ("Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"):
        dst = pathlib.Path.home() / d
        dst.mkdir(parents=True, exist_ok=True)
        (dst / f"{uuid}.mobileprovision").write_bytes(raw)
    print("profile", bundle, name, uuid)
