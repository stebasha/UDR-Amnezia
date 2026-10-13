#!/usr/bin/env python3
"""Проверка разбиения панели на модули (#18): порядок модулей в awgweb = порядок зависимостей.
Каждый модуль импортирует предыдущий целиком; глобальное имя, на которое ссылается модуль, должно быть определено
в нём самом или в одном из предыдущих (ссылка вперёд даст NameError только при вызове — ловим заранее).
Запуск: python3 tools/check-modules.py"""
import ast
import builtins
import os
import re
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(R, "awg/web/awgweb")
srv = open(os.path.join(PKG, "server.py")).read()
order = []
m = "server"
while True:      # цепочка from .X import * от server к core
    order.insert(0, m)
    x = re.search(r"^from \.(\w+) import \*", open(os.path.join(PKG, m + ".py")).read(), re.M)
    if not x:
        break
    m = x.group(1)
files = sorted(f[:-3] for f in os.listdir(PKG) if f.endswith(".py") and f != "__init__.py")
bad = []
if sorted(order) != files:
    bad.append("модули вне цепочки импортов: %s" % sorted(set(files) - set(order)))
defined = {}
trees = {}
for m in order:
    t = ast.parse(open(os.path.join(PKG, m + ".py")).read(), feature_version=(3, 7))
    trees[m] = t
    for n in t.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
            defined.setdefault(n.name, m)
        elif isinstance(n, ast.Assign):
            for x in n.targets:
                if isinstance(x, ast.Name):
                    defined.setdefault(x.id, m)
        elif isinstance(n, ast.Import):
            for a in n.names:
                defined.setdefault((a.asname or a.name).split(".")[0], m)
bi = set(dir(builtins))
for i, m in enumerate(order):
    seen_imports = set()
    for n in trees[m].body:
        if isinstance(n, ast.ImportFrom) and n.level == 1:
            seen_imports |= {a.name for a in n.names}
    for n in trees[m].body:
        for x in ast.walk(n):
            if isinstance(x, ast.Name) and isinstance(x.ctx, ast.Load):
                d = defined.get(x.id)
                if d is None:
                    continue           # локальные имена и встроенные
                if order.index(d) > i:
                    bad.append("%s.py: %s определено позже, в %s.py" % (m, x.id, d))
                elif x.id.startswith("_") and d != m and x.id not in seen_imports:
                    bad.append("%s.py: %s из %s.py не импортировано явно (звёздочка не переносит имена с _)" % (m, x.id, d))
print("модули панели: %s" % " → ".join(order))
if bad:
    print("\n".join(sorted(set(bad))))
    sys.exit(1)
print("ссылок вперёд нет")
