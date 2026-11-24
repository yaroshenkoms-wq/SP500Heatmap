#!/usr/bin/env python3
"""Читает данные портфелей сайта udak.eu (только чтение) и пишет два файла в ресурсы приложения:
  SP500Heatmap/SP500Heatmap/Resources/portfolios_data.json  — месячные ряды, модели, эпохи;
  SP500Heatmap/SP500Heatmap/Resources/portfolios_text.json  — тексты по языкам.
Запуск: python3 tools/sync_udak_portfolios.py [путь к Udak/Brokers]
Языки: en/es/fr/ru — из Udak; zh-Hans/ar/bn/hi/uk — названия моделей, классов и эпох переведены машиной
(tools/portfolio_translations.py), поле "machine" в тексте; описание для них — английское."""
import json, os, re, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
UDAK = sys.argv[1] if len(sys.argv) > 1 else "/Users/maximyaroshenko/Udak/Brokers"
OUT = os.path.join(ROOT, "SP500Heatmap", "SP500Heatmap", "Resources")
sys.dont_write_bytecode = True
sys.path[:0] = [HERE, os.path.join(UDAK, "site"), os.path.join(UDAK, "models")]
import portfolio_translations as TR   # noqa: E402
import models_text as MT              # noqa: E402
import portfolios as P                # noqa: E402
import portfolios_ui as UI            # noqa: E402
import portfolios_ui_es as UIES       # noqa: E402
import portfolios_ui_fr as UIFR       # noqa: E402

SRC = ["en", "es", "fr", "ru"]
MACHINE = TR.LANGS
RES = os.path.join(UDAK, "models", "research")


def load(path):
    return json.load(open(path, encoding="utf-8"))


def main():
    d = load(os.path.join(UDAK, "site", "static", "calc", "data.json"))
    os.makedirs(OUT, exist_ok=True)
    rnd = lambda a: [None if v is None else v for v in a]
    data = {
        "months": d["months"],
        "assets": {c: rnd(v) for c, v in d["assets"].items()},
        "cpi": d["cpi"], "fx": d["fx"], "cpiEur": d["cpi_eur"],
        "models": [{"key": m["key"], "w": m["w"], "risk": m["risk"]} for m in d["models"]],
        "eras": [{"id": e["id"], "start": e["start"], "end": e["end"]} for e in d["eras"]],
    }
    with open(os.path.join(OUT, "portfolios_data.json"), "w") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)

    # --- тексты ---
    names = {"en": {}, "es": {}, "fr": {}}
    for L in ("en", "es", "fr"):
        for k, v in MT.BOTS[L].items():
            names[L][k] = v
        for N in (MT.NEW, MT.NEW2, MT.NEW3):
            names[L].update(N[L])
    ru = {m[1]: (m[3], m[5]) for m in P.MODELS}
    spy_names = {"en": ("Buy and hold the S&P 500", "One purchase of an index fund of the 500 largest US companies, held without any changes. Every other model is compared with it."),
                 "es": ("Comprar y mantener el S&P 500", "Una sola compra de un fondo de las 500 mayores empresas de EE. UU., mantenida sin cambios. Todos los demás modelos se comparan con él."),
                 "fr": ("Acheter et conserver le S&P 500", "Un seul achat d'un fonds des 500 plus grandes entreprises américaines, conservé sans changement. Tous les autres modèles sont comparés à lui."),
                 "ru": ru["spy"]}
    models = {}
    for m in d["models"]:
        k = m["key"]
        e = {"risk": m["risk"], "name": {}, "short": {}, "author": {}, "rationale": {}, "criticisms": {}, "machine": MACHINE}
        for L in SRC:
            if k == "spy":
                nm, sh = spy_names[L]
            elif L == "ru":
                nm, sh = ru[k]
            else:
                nm, sh = names[L][k]
            e["name"][L], e["short"][L] = nm, sh
        for i, L in enumerate(MACHINE):
            e["name"][L] = TR.MODELS.get(k, (None,) * 5)[i] or e["name"]["en"]
        e["year"] = ""
        e["sources"] = []
        if k != "spy":
            en = load(os.path.join(RES, k + ".json"))
            mt = re.search(r"\b(1[89]\d\d|20\d\d)\b", en.get("first_published", ""))
            e["year"] = mt.group(1) if mt else ""
            e["sources"] = [s for s in en.get("sources", []) if isinstance(s, str)][:6]
            for L in SRC:
                t = en if L == "en" else load(os.path.join(RES, L, k + ".json"))
                e["author"][L] = t.get("author", "")
                e["rationale"][L] = t.get("rationale", "")
                e["criticisms"][L] = [c for c in t.get("criticisms", []) if isinstance(c, str)][:3]
        models[k] = e

    classes = {"en": UI.CLASSES["en"], "ru": UI.CLASSES["ru"], "es": UIES.CLASSES_ES, "fr": UIFR.CLASSES_FR}
    classes = {L: {c: v[c] for c in TR.CLASSES} for L, v in classes.items()}
    for i, L in enumerate(MACHINE):
        classes[L] = {c: TR.CLASSES[c][i] for c in TR.CLASSES}

    eras = {}
    en_eras = {e["id"]: e["name"] for e in d["eras"]}
    tr_eras = {L: {e["id"]: e["name"] for e in load(os.path.join(RES, L, "eras.json"))["eras"]} for L in ("es", "fr", "ru")}
    for e in d["eras"]:
        i = e["id"]
        nm = {"en": en_eras[i]}
        for L in ("es", "fr", "ru"):
            nm[L] = tr_eras[L].get(i, en_eras[i])
        for j, L in enumerate(MACHINE):
            nm[L] = TR.ERAS[i][j] if i in TR.ERAS else en_eras[i]
        eras[i] = nm

    text = {"machine": MACHINE, "classes": classes, "eras": eras, "models": models}
    with open(os.path.join(OUT, "portfolios_text.json"), "w") as f:
        json.dump(text, f, separators=(",", ":"), ensure_ascii=False)
    for n in ("portfolios_data.json", "portfolios_text.json"):
        print(n, os.path.getsize(os.path.join(OUT, n)) // 1024, "KB")


main()
