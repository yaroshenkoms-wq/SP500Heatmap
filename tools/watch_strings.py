#!/usr/bin/env python3
"""Строки Apple Watch: собирает WatchApp/Localizable.xcstrings и WatchWidgets/Localizable.xcstrings
(9 языков) и проверяет, что у каждого ключа есть все переводы.

  python3 tools/watch_strings.py          # собрать
  python3 tools/watch_strings.py --check  # только проверить (код выхода 1 при пропусках)

Часть ключей берётся готовой из каталогов iPhone-приложения и виджетов, новые переводы — ниже.
"""
import json, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent / "SP500Heatmap"
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]
APP_CAT = ROOT / "SP500Heatmap/Localizable.xcstrings"
WID_CAT = ROOT / "SP500HeatmapWidgets/Localizable.xcstrings"

# ключ -> (en, es, zh-Hans, ar, fr, bn, hi, ru, uk)
NEW = {
    "Sectors": ("Sectors", "Sectores", "板块", "القطاعات", "Secteurs", "সেক্টর", "सेक्टर", "Сектора", "Сектори"),
    "No data": ("No data", "Sin datos", "暂无数据", "لا توجد بيانات", "Aucune donnée", "কোনো তথ্য নেই", "कोई डेटा नहीं", "Нет данных", "Немає даних"),
    "Your lists are empty. Add stocks in the iPhone app.": (
        "Your lists are empty. Add stocks in the iPhone app.",
        "Tus listas están vacías. Añade acciones en la app del iPhone.",
        "你的列表是空的。请在 iPhone 应用中添加股票。",
        "قوائمك فارغة. أضف الأسهم من تطبيق iPhone.",
        "Vos listes sont vides. Ajoutez des actions dans l'app iPhone.",
        "আপনার তালিকা খালি। iPhone অ্যাপে শেয়ার যোগ করুন।",
        "आपकी सूचियाँ खाली हैं। iPhone ऐप में शेयर जोड़ें।",
        "Списки пусты. Добавьте акции в приложении на iPhone.",
        "Списки порожні. Додайте акції в застосунку на iPhone."),
    "Choose index": ("Choose index", "Elegir índice", "选择指数", "اختر المؤشر", "Choisir l'indice", "সূচক বেছে নিন", "सूचकांक चुनें", "Выбрать индекс", "Обрати індекс"),
    "Index change": ("Index change", "Variación del índice", "指数涨跌", "تغير المؤشر", "Variation de l'indice", "সূচকের পরিবর্তন", "सूचकांक में बदलाव", "Изменение индекса", "Зміна індексу"),
    "Today's change of an index.": (
        "Today's change of an index.", "La variación de hoy de un índice.", "指数今日涨跌幅。",
        "تغير المؤشر اليوم.", "La variation du jour d'un indice.", "একটি সূচকের আজকের পরিবর্তন।",
        "किसी सूचकांक में आज का बदलाव।", "Изменение индекса за сегодня.", "Зміна індексу за сьогодні."),
}
APP_KEYS = ["World markets", "Watchlists", "Americas", "Europe", "Asia-Pacific", "Crypto & ETFs", "Other",
            "Favorites", "Top gainers", "Top losers", "Sectors", "No data",
            "Your lists are empty. Add stocks in the iPhone app."]
WID_KEYS = ["Index", "Choose index", "Index change", "Today's change of an index."]


def existing(path):
    return {k: {l: v["stringUnit"]["value"] for l, v in e.get("localizations", {}).items()}
            for k, e in json.loads(path.read_text())["strings"].items()}


def build(keys, sources):
    out = {}
    for key in keys:
        loc = None
        if key in NEW:
            loc = dict(zip(LANGS, NEW[key]))
        else:
            for src in sources:
                if key in src:
                    loc = src[key]; break
        if loc is None:
            raise SystemExit(f"нет перевода для «{key}»")
        out[key] = {"extractionState": "manual", "localizations": {
            l: {"stringUnit": {"state": "translated", "value": loc[l]}} for l in LANGS if l in loc}}
    return {"sourceLanguage": "en", "strings": out, "version": "1.0"}


def check(doc, name):
    bad = [(k, l) for k, e in doc["strings"].items() for l in LANGS if l not in e["localizations"]]
    for k, l in bad:
        print(f"{name}: у «{k}» нет языка {l}")
    return not bad


def main():
    srcs = [existing(APP_CAT), existing(WID_CAT)]
    targets = [(ROOT / "WatchApp/Localizable.xcstrings", build(APP_KEYS, srcs), "WatchApp"),
               (ROOT / "WatchWidgets/Localizable.xcstrings", build(WID_KEYS, srcs), "WatchWidgets")]
    ok = True
    for path, doc, name in targets:
        ok &= check(doc, name)
        if "--check" not in sys.argv:
            path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
        elif path.exists():
            ok &= check(json.loads(path.read_text()), name + " (файл)")
        else:
            print(f"{name}: файла нет"); ok = False
    print("OK" if ok else "ЕСТЬ ПРОПУСКИ")
    sys.exit(0 if ok else 1)


main()
