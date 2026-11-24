#!/usr/bin/env python3
"""Checks that every string key used in News/*.swift and AI/Chat/*.swift exists in Localizable.xcstrings in all 9 languages,
and that format placeholders match the English text."""
import glob, json, os, re, sys
ROOT = os.path.join(os.path.dirname(__file__), "..", "SP500Heatmap", "SP500Heatmap")
LANGS = ["en", "es", "zh-Hans", "ar", "fr", "bn", "hi", "ru", "uk"]
strings = json.load(open(os.path.join(ROOT, "Localizable.xcstrings")))["strings"]
keys = set()
call = r'(?:Text|Button|Label|Picker|AppLanguage\.string|AIL\.s|AIL\.f|segButton|note)'
files = glob.glob(os.path.join(ROOT, "News", "*.swift")) + glob.glob(os.path.join(ROOT, "AI", "Chat", "*.swift"))
for f in files:
    s = open(f).read()
    for m in re.finditer(call + r'\(\s*"((?:[^"\\]|\\.)*)"', s): keys.add(m.group(1))
    for m in re.finditer(r'Text\("((?:[^"\\]|\\.)*)"\)', s): keys.add(m.group(1))
    if f.endswith("View.swift"):
        for m in re.finditer(r'\? "([^"]+)" : "([^"]+)"', s): keys.update(m.groups())
keys = {k.replace('\\"', '"') for k in keys}
skip = {"end", "sparkles", "newspaper", "info.circle", "arrow.up.right", "link", "arrow.up", "square.and.pencil", "star", "globe", "xmark"}
def ph(s): return sorted(re.findall(r'%(?:\d+\$)?(?:lld|@|d|f)', s))
bad = 0
for k in sorted(keys - skip):
    if k not in strings:
        print("NOT IN CATALOG", repr(k)); bad += 1; continue
    loc = strings[k].get("localizations", {})
    for l in LANGS:
        v = loc.get(l, {}).get("stringUnit", {}).get("value")
        if not v and l == "en": continue   # source language: the key itself is shown
        if not v: print("MISSING", repr(k), l); bad += 1
        elif ph(v) != ph(k): print("PLACEHOLDERS", repr(k), l); bad += 1
print("checked", len(keys - skip), "keys;", "problems:", bad)
sys.exit(1 if bad else 0)
