#!/usr/bin/env python3
"""Сборка awg/web/static/app.js из частей awg/web/src/*.js (#18): части склеиваются по порядку имён, без изменений.
Все части — внутри одной функции-обёртки (начало в 00-head.js, конец в 90-start.js), поэтому видят общие помощники
без глобальных имён; на роутер по-прежнему ставится один app.js, сборщик на роутере не нужен.
    python3 tools/build-app.py           собрать
    python3 tools/build-app.py --check   код 1, если app.js не совпадает с частями (так проверяет CI)"""
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(R, "awg/web/src")
OUT = os.path.join(R, "awg/web/static/app.js")
parts = sorted(f for f in os.listdir(SRC) if f.endswith(".js"))
text = "".join(open(os.path.join(SRC, f), encoding="utf-8").read() for f in parts)
cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
if "--check" in sys.argv:
    if cur != text:
        print("app.js не совпадает с awg/web/src/*.js: правьте части и выполните python3 tools/build-app.py")
        sys.exit(1)
    print("app.js собран из %d частей" % len(parts))
    sys.exit(0)
if cur != text:
    open(OUT, "w", encoding="utf-8").write(text)
    print("app.js обновлён (%d частей)" % len(parts))
else:
    print("app.js без изменений")
