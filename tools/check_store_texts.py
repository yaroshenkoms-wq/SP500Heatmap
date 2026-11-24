#!/usr/bin/env python3
"""Validate appstore/1.1/metadata/*.json against App Store Connect limits."""
import json, re, sys
from pathlib import Path

LOCALES = ("ar-SA bn-BD ca zh-Hans zh-Hant hr cs da nl-NL en-US en-GB en-AU en-CA fi fr-FR fr-CA de-DE "
           "el he hi hu id it ja ko ms no pl pt-BR pt-PT ro ru sk sl-SI es-ES es-MX sv th tr uk vi").split()
LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000, "keywords": 100, "whatsNew": 4000}
DISCLAIMER_MIN = 20

def words(s):
    return {w.lower() for w in re.split(r"[\s,.:;/&()\-]+", s) if len(w) > 2}

def main():
    root = Path(__file__).resolve().parent.parent / "appstore" / "1.1" / "metadata"
    errors, warns = [], []
    for loc in LOCALES:
        f = root / f"{loc}.json"
        if not f.exists():
            errors.append(f"{loc}: file missing"); continue
        d = json.loads(f.read_text(encoding="utf-8"))
        for k, lim in LIMITS.items():
            v = d.get(k)
            if not isinstance(v, str) or not v.strip():
                errors.append(f"{loc}: {k} missing/empty"); continue
            if len(v) > lim:
                errors.append(f"{loc}: {k} {len(v)}>{lim}")
        if d.get("name") != "SP500Heatmap":
            errors.append(f"{loc}: name must stay SP500Heatmap")
        if not d.get("name_proposal") or len(d["name_proposal"]) > 30:
            errors.append(f"{loc}: name_proposal missing or >30")
        kw = d.get("keywords", "")
        if ", " in kw or kw.startswith(",") or kw.endswith(",") or ",," in kw:
            errors.append(f"{loc}: keywords formatting (no spaces after commas)")
        kws = [x.strip().lower() for x in kw.split(",")]
        if len(set(kws)) != len(kws):
            warns.append(f"{loc}: duplicate keywords")
        overlap = {x for x in kws if x in words(d.get("name", "") + " " + d.get("subtitle", ""))}
        if overlap:
            warns.append(f"{loc}: keywords repeat name/subtitle words: {sorted(overlap)}")
        desc = d.get("description", "")
        if desc.count("•") < 10:
            warns.append(f"{loc}: few bullets in description")
        if "SP500" not in desc:
            warns.append(f"{loc}: description lacks brand")
        if len(desc) < (600 if loc.split('-')[0] in ('zh', 'ja', 'ko') else 1200):
            warns.append(f"{loc}: description short ({len(desc)})")
    extra = sorted(p.stem for p in root.glob("*.json") if p.stem not in LOCALES)
    if extra:
        warns.append(f"unexpected files: {extra}")
    for w in warns: print("WARN ", w)
    for e in errors: print("ERROR", e)
    print(f"{len(LOCALES)} locales expected, {len(list(root.glob('*.json')))} files, {len(errors)} errors, {len(warns)} warnings")
    sys.exit(1 if errors else 0)

if __name__ == "__main__":
    main()
