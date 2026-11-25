#!/usr/bin/env python3
"""Загружает снимки версии 1.1 в App Store Connect: appstore/1.1/{iphone,ipad}/<locale>/*.png.
iPhone 1206×2622 пересчитываются в 1320×2868 (6,9″, обязательный размер; пропорции совпадают до 0,07 %).
iPad 2064×2752 — набор APP_IPAD_PRO_3GEN_129 (13″). На проверку НЕ отправляет.
Запуск: python3 tools/appstore_shots_upload_11.py [локаль ...]"""
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path.home() / "Desktop/App/Uni/Tools"))
import asc  # noqa: E402

APP, VERSION = "6813677835", "1.1"
ROOT = pathlib.Path(__file__).resolve().parent.parent / "appstore" / "1.1"
TYPES = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129"}
TMP = pathlib.Path(tempfile.mkdtemp(prefix="sp500shots"))


def prepared(device, png):
    if device != "iphone":
        return png.read_bytes()
    out = TMP / f"{png.parent.name}_{png.name}"
    if not out.exists():
        subprocess.run(["sips", "-z", "2868", "1320", str(png), "--out", str(out)], capture_output=True, check=True)
    return out.read_bytes()


def upload_set(loc_id, locale, device):
    folder = ROOT / device / locale
    files = sorted(folder.glob("*.png"))
    if not files:
        return f"{locale} {device}: нет файлов"
    set_id = None
    for s in asc.call("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets").get("data", []):
        if s["attributes"]["screenshotDisplayType"] == TYPES[device]:
            set_id = s["id"]  # набор уже есть: очищаем его (удалить набор целиком Apple не всегда даёт)
            for sh in asc.call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50").get("data", []):
                asc.call("DELETE", f"/v1/appScreenshots/{sh['id']}")
    if set_id is None:
        r = asc.call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                     "attributes": {"screenshotDisplayType": TYPES[device]},
                     "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
        if "http" in r:
            return f"{locale} {device}: набор {r['http']} {r['body'][:200]}"
        set_id = r["data"]["id"]
    errors = []
    for png in files:
        data = prepared(device, png)
        r = asc.call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
                     "attributes": {"fileName": png.name, "fileSize": len(data)},
                     "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
        if "http" in r:
            errors.append(f"{png.name}: {r['http']}")
            continue
        for op in r["data"]["attributes"]["uploadOperations"]:
            req = urllib.request.Request(op["url"], method=op["method"], data=data[op["offset"]:op["offset"] + op["length"]],
                                         headers={h["name"]: h["value"] for h in op["requestHeaders"]})
            urllib.request.urlopen(req, timeout=180).read()
        sid = r["data"]["id"]
        r2 = asc.call("PATCH", f"/v1/appScreenshots/{sid}", {"data": {"type": "appScreenshots", "id": sid,
                      "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        if "http" in r2:
            errors.append(f"{png.name}: commit {r2['http']}")
    return f"{locale} {device}: {len(files) - len(errors)}/{len(files)}" + (f" ошибки {errors}" if errors else "")


def main():
    vid = asc.version_id(APP, VERSION)
    locs = {l["attributes"]["locale"]: l["id"] for l in
            asc.call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=200")["data"]}
    wanted = sys.argv[1:] or sorted(locs)
    jobs = [(locs[l], l, d) for l in wanted if l in locs for d in ("iphone", "ipad")]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for line in pool.map(lambda j: upload_set(*j), jobs):
            print(line, flush=True)


if __name__ == "__main__":
    main()
