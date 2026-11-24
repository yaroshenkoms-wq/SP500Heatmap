#!/usr/bin/env python3
"""Checks that every string key used in SP500Heatmap/Portfolio/*.swift exists in Localizable.xcstrings in all 9 languages."""
import glob, json, os, re, sys
ROOT = os.path.join(os.path.dirname(__file__), "..", "SP500Heatmap", "SP500Heatmap")
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]
strings = json.load(open(os.path.join(ROOT, "Localizable.xcstrings")))["strings"]
keys = set()
call = r'(?:Text|Button|Label|TextField|Picker|alert|confirmationDialog|AppLanguage\.string|pfText|stat|detail|field|PortfolioChip\(title:|ProgressView)'
for f in glob.glob(os.path.join(ROOT, "Portfolio", "*.swift")):
    s = open(f).read()
    for m in re.finditer(call + r'\(\s*(?:type == \.dividend \? )?"((?:[^"\\]|\\.)*)"', s): keys.add(m.group(1))
    for m in re.finditer(r'title: "((?:[^"\\]|\\.)*)"', s): keys.add(m.group(1))
    for m in re.finditer(r'\? "([^"]+)" :', s): keys.add(m.group(1))
    for m in re.finditer(r'\("(\w+)", "([^"]+)", (?:\d+|nil)\)', s): keys.add(m.group(2))
    for m in re.finditer(r'(?:string|stat)\("([^"]+)"', s): keys.add(m.group(1))
keys = {k.replace('\\"', '"') for k in keys}
skip = {"0", "checkmark", "x", "briefcase", "Sold %@ of %@"}
bad = 0
for k in sorted(keys - skip):
    loc = strings.get(k, {}).get("localizations", {})
    missing = [l for l in LANGS if not loc.get(l, {}).get("stringUnit", {}).get("value")]
    if missing:
        print("MISSING", repr(k), missing); bad += 1
print("checked", len(keys - skip), "keys;", "problems:", bad)
sys.exit(1 if bad else 0)
