#!/usr/bin/env python3
"""Добавить переводы в lang-en.js: python3 tools/add-en.py ФАЙЛ.json  ({"русская строка": "English", …}).
Уже существующие ключи пропускаются; новые вставляются в начало словаря s."""
import json
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(R, "awg/web/static/lang-en.js")
add = json.load(open(sys.argv[1], encoding="utf-8"))
s = open(P, encoding="utf-8").read()
anchor = "  s: {\n"
assert anchor in s, "нет начала словаря s"
new = "".join(" %s: %s,\n" % (json.dumps(k, ensure_ascii=False), json.dumps(v, ensure_ascii=False))
              for k, v in add.items() if " %s:" % json.dumps(k, ensure_ascii=False) not in s)
s = s.replace(anchor, anchor + new, 1)
open(P, "w", encoding="utf-8").write(s)
print("добавлено: %d" % new.count("\n"))
