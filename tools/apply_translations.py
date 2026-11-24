#!/usr/bin/env python3
"""Вставляет переводы из <dir>/<lang>.json (формат: {"<файл>": {"<ключ>": "<перевод>"}}) в
String Catalogs приложения, тексты портфелей Udak и шаблоны push на сервере.

Запуск: python3 tools/apply_translations.py /private/tmp/claude-501/tr/out
Файлы-ключи: пути String Catalog относительно папки SP500Heatmap/, плюс
«portfolios_text.json» (ключи вида models.<key>.name / classes.<k>.<поле> / eras.<i>.<поле>)
и «push_i18n.py» (ключи шаблонов).
"""
import json
import pprint
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "SP500Heatmap"


def apply_catalog(path, entries, lang):
    d = json.loads(path.read_text(encoding="utf-8"))
    n = 0
    for key, value in entries.items():
        s = d["strings"].get(key)
        if s is None or s.get("shouldTranslate") is False:
            continue
        s.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": value}}
        n += 1
    path.write_text(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return n


def apply_portfolios(entries, lang, data):
    n = 0
    for key, value in entries.items():
        sect, k, fld = key.split(".", 2)
        node = data[sect]
        node = node[int(k)] if isinstance(node, list) else node[k]
        node[fld][lang] = value
        if sect == "models":
            data.setdefault("machine", {}) if isinstance(data.get("machine"), dict) else None
        n += 1
    return n


def main(out_dir):
    out_dir = Path(out_dir)
    pf_path = APP / "SP500Heatmap" / "Resources" / "portfolios_text.json"
    pf = json.loads(pf_path.read_text(encoding="utf-8"))
    push = {}
    for f in sorted(out_dir.glob("*.json")):
        lang = f.stem
        tr = json.loads(f.read_text(encoding="utf-8"))
        counts = {}
        for target, entries in tr.items():
            if target == "portfolios_text.json":
                counts[target] = apply_portfolios(entries, lang, pf)
            elif target == "push_i18n.py":
                # ключи «<шаблон>.title» и «<шаблон>.body» -> кортеж (заголовок, текст)
                pairs = {}
                for k, v in entries.items():
                    name, part = k.rsplit(".", 1)
                    pairs.setdefault(name, ["", ""])[0 if part == "title" else 1] = v
                push[lang] = {k: tuple(v) for k, v in pairs.items()}
                counts[target] = len(pairs)
            else:
                counts[target] = apply_catalog(APP / target, entries, lang)
        print(lang, counts)
    # пометка «перевод машинный» для языков без текстов на Udak
    if isinstance(pf.get("machine"), list):
        pf["machine"] = sorted(set(pf["machine"]) | {f.stem for f in out_dir.glob("*.json")})
    pf_path.write_text(json.dumps(pf, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if push:
        ns = {}
        src = (ROOT / "push_i18n.py").read_text(encoding="utf-8")
        exec(src, ns)
        T = ns["T"]
        T.update(push)
        langs = list(ns["LANGS"]) + [l for l in sorted(push) if l not in ns["LANGS"]]
        head, _, tail = src.partition("T = {")
        # хвост файла после словаря T (функции) сохраняем как есть
        rest = tail[tail.index("\n}\n") + 3:] if "\n}\n" in tail else ""
        head = head.replace(head[head.index("LANGS = "):head.index("\n", head.index("LANGS = "))],
                            "LANGS = " + json.dumps(langs, ensure_ascii=False))
        (ROOT / "push_i18n.py").write_text(head + "T = " + pprint.pformat(T, width=120, sort_dicts=False) + "\n" + rest,
                                           encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1])
