#!/usr/bin/env python3
"""Заполняет черновик версии 1.1 в App Store Connect текстами из appstore/1.1/metadata/<locale>.json.
НА ПРОВЕРКУ НЕ ОТПРАВЛЯЕТ (правило владельца: только после последнего «да» на «Отправлять?»).
Запуск: python3 tools/appstore_meta_11.py [--dry]"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path.home() / "Desktop/App/Uni/Tools"))
import asc  # noqa: E402

APP = "6813677835"
VERSION = "1.1"
ROOT = pathlib.Path(__file__).resolve().parent.parent
META = ROOT / "appstore" / "1.1" / "metadata"
DRY = "--dry" in sys.argv


def main():
    vid = asc.version_id(APP, VERSION)  # создаёт черновик, если его нет
    print("version", VERSION, vid)
    existing = {x["attributes"]["locale"]: x for x in
                asc.call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=200").get("data", [])}
    info = [x for x in asc.call("GET", f"/v1/apps/{APP}/appInfos").get("data", [])
            if x["attributes"].get("appStoreState") != "READY_FOR_SALE"] or \
        asc.call("GET", f"/v1/apps/{APP}/appInfos").get("data", [])
    info_id = info[0]["id"]
    info_loc = {x["attributes"]["locale"]: x for x in
                asc.call("GET", f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=200").get("data", [])}
    en = existing.get("en-US", {}).get("attributes", {})
    support, marketing = en.get("supportUrl"), en.get("marketingUrl")
    privacy = (info_loc.get("en-US") or {}).get("attributes", {}).get("privacyPolicyUrl")
    ok, failed = [], []
    for f in sorted(META.glob("*.json")):
        loc = f.stem
        m = json.loads(f.read_text(encoding="utf-8"))
        attrs = {"description": m["description"], "keywords": m["keywords"], "promotionalText": m.get("promotionalText")}
        if loc in existing:  # у новой версии «Что нового» обязательно только для уже существующих языков
            attrs["whatsNew"] = m["whatsNew"]
        if support:
            attrs["supportUrl"] = support
        if marketing:
            attrs["marketingUrl"] = marketing
        if DRY:
            print("dry", loc)
            continue
        if loc in existing:
            r = asc.call("PATCH", f"/v1/appStoreVersionLocalizations/{existing[loc]['id']}",
                         {"data": {"type": "appStoreVersionLocalizations", "id": existing[loc]["id"], "attributes": attrs}})
        else:
            attrs.pop("whatsNew", None)
            r = asc.call("POST", "/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations",
                         "attributes": dict(attrs, locale=loc),
                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
        if "http" in r:
            failed.append((loc, "version", r["http"], r["body"][:300]))
            continue
        # App Store Connect сам заводит appInfoLocalization при новом языке версии — перечитываем.
        info_loc = {x["attributes"]["locale"]: x for x in
                    asc.call("GET", f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=200").get("data", [])}
        ia = {"name": m["name"], "subtitle": m["subtitle"]}
        if privacy:
            ia["privacyPolicyUrl"] = privacy
        if loc in info_loc:
            r2 = asc.call("PATCH", f"/v1/appInfoLocalizations/{info_loc[loc]['id']}",
                          {"data": {"type": "appInfoLocalizations", "id": info_loc[loc]["id"], "attributes": ia}})
        else:
            r2 = asc.call("POST", "/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations",
                          "attributes": dict(ia, locale=loc),
                          "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}}}})
        if "http" in r2:
            failed.append((loc, "appInfo", r2["http"], r2["body"][:300]))
        else:
            ok.append(loc)
    print("ok", len(ok), ok)
    for x in failed:
        print("FAILED", x)


if __name__ == "__main__":
    main()
