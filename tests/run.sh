#!/bin/bash
# Все тесты на заглушках: без root и без роутера. Запуск из корня репозитория: bash tests/run.sh
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$H")
INST=${INST:-$ROOT/install.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0
echo "== синтаксис"; bash -n "$INST" && echo "  install.sh: ok" || rc=1
for f in "$ROOT"/awg/*.sh "$ROOT"/server/*.sh "$H"/*.sh; do bash -n "$f" || { echo "  синтаксическая ошибка: $f"; rc=1; }; done
for t in t_failover t_guard t_fw t_misc; do echo "== $t"; bash "$H/$t.sh" "$ROOT/awg" || rc=1; done
echo "== t_installer"; bash "$H/t_installer.sh" "$INST" || rc=1
echo "== t_update"; bash "$H/t_update.sh" "$INST" || rc=1
echo "== t_web (веб-панель)"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3,7))' "$ROOT/awg/web/panel.py" && echo "  panel.py: синтаксис Python 3.7 ok" || rc=1
command -v node >/dev/null && { node --check "$ROOT/awg/web/static/app.js" && echo "  app.js: ok" || rc=1; }
python3 "$H/t_web.py" || rc=1
[ $rc = 0 ] && echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $rc
