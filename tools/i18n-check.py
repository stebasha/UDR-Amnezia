#!/usr/bin/env python3
"""Проверка перевода панели: каждая строка T('…') из app.js должна быть в lang-en.js. Код 1 — есть пропуски."""
import json, os, re, subprocess, sys
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
app = open(os.path.join(R, "awg/web/static/app.js"), encoding="utf-8").read()
keys = json.loads(subprocess.check_output(["node", "-e", "global.window={};require(process.argv[1]);process.stdout.write(JSON.stringify(Object.keys(window.AWG_EN.s)))",
                                           os.path.join(R, "awg/web/static/lang-en.js")]).decode())
miss = []
for m in re.finditer(r"\bT\('((?:[^'\\\n]|\\.)*)'\)", app):
    k = m.group(1).replace("\\n", "\n").replace("\\'", "'")
    if k not in keys and k not in miss:
        miss.append(k)
for k in miss:
    print("нет перевода:", repr(k))
print("строк без перевода: %d" % len(miss))
sys.exit(1 if miss else 0)
