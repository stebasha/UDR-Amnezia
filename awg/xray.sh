#!/bin/bash
# xray.sh — Xray для туннелей VLESS/Reality (#42): только официальные релизы XTLS/Xray-core, сверка SHA256 из .dgst релиза.
#   xray.sh version     установленная версия (пусто — не установлен)
#   xray.sh latest      последняя версия в github.com/XTLS/Xray-core
#   xray.sh install [ВЕРСИЯ]   установить или обновить (без версии — последнюю); прежняя остаётся как xray.prev
#   xray.sh rollback    вернуть прежнюю версию
#   xray.sh restart     перезапустить туннели VLESS (после обновления)
# Качает напрямую, при неудаче — через активный туннель. Файлы: $DD/xray/ (xray, xray.prev, конфиги туннелей).
set -o pipefail
DD=${DD:-/data/awg}
XD="$DD/xray"
REPO=XTLS/Xray-core
GH=${XRAY_GH:-https://github.com}
API=${XRAY_API:-https://api.github.com}
umask 077

say(){ printf '%s\n' "$*"; }
die(){ say "ОШИБКА: $*" >&2; exit 1; }
ver(){ [ -x "$XD/xray" ] && "$XD/xray" version 2>/dev/null | sed -n '1s/^Xray \([0-9][0-9.]*\).*/\1/p'; }
asset(){
  case "$(uname -m)" in
    aarch64|arm64) echo Xray-linux-arm64-v8a.zip ;;
    x86_64|amd64) echo Xray-linux-64.zip ;;
    armv7l) echo Xray-linux-arm32-v7a.zip ;;
    *) return 1 ;;
  esac
}
active(){ sed -n 's/^ACTIVE=//p' "${STATEF:-/run/awg-state}" 2>/dev/null | head -1; }
fetch(){  # fetch АДРЕС ФАЙЛ [время] — напрямую, затем через активный туннель
  local a
  curl -fsSL --proto =https --proto-redir =https -m "${3:-60}" "$1" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
  a=$(active)
  [ -n "$a" ] && curl -fsSL --proto =https --proto-redir =https -m "${3:-60}" --interface "$a" "$1" -o "$2" 2>/dev/null && [ -s "$2" ]
}
latest(){
  local t
  t=$(mktemp) || return 1
  fetch "$API/repos/$REPO/releases/latest" "$t" 20 \
    && sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' "$t" | head -1
  rm -f "$t"
}
restart_tunnels(){
  local t
  # shellcheck disable=SC1091
  . "$DD/awg.env" 2>/dev/null
  for t in $XRAY_TUNNELS; do
    if "$DD/up.sh" "$t" >/dev/null 2>&1; then say "  туннель $t перезапущен"; else say "  туннель $t не поднялся: проверьте «Туннели → VLESS»"; fi
  done
}

install(){
  local v="${1:-}" a t sum have
  a=$(asset) || die "архитектура $(uname -m) не поддерживается"
  [ -n "$v" ] || v=$(latest) || true
  [ -n "$v" ] || die "не удалось узнать последнюю версию Xray (github.com недоступен?)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "неверная версия: $v"
  if [ "$(ver)" = "$v" ]; then say "Xray $v уже установлен"; return 0; fi
  [ "$(df -Pm "$DD" | awk 'NR==2{print $4}')" -ge 80 ] 2>/dev/null || die "на $DD меньше 80 МБ свободного места"
  mkdir -p "$XD" && chmod 700 "$XD" || die "нет папки $XD"
  t=$(mktemp -d) || die "нет временной папки"
  trap 'rm -rf "$t"' EXIT
  say "Xray $v ($a) из $GH/$REPO/releases"
  fetch "$GH/$REPO/releases/download/v$v/$a" "$t/x.zip" 300 || die "архив не скачался"
  fetch "$GH/$REPO/releases/download/v$v/$a.dgst" "$t/x.dgst" 30 || die "нет файла контрольных сумм $a.dgst"
  sum=$(sed -n 's/^SHA2-256= *\([0-9a-fA-F]\{64\}\).*/\1/p' "$t/x.dgst" | head -1)
  [ -n "$sum" ] || die "в $a.dgst нет строки SHA2-256"
  have=$(sha256sum "$t/x.zip" | cut -d' ' -f1)
  [ "$have" = "${sum,,}" ] || die "SHA-256 архива не совпал с релизом: файл не устанавливаю"
  say "  SHA-256 совпал: ${have:0:16}…"
  python3 -I - "$t/x.zip" "$t/xray" <<'PY' || die "в архиве нет файла xray"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    with z.open("xray") as s, open(sys.argv[2], "wb") as d:
        while True:
            b = s.read(1 << 20)
            if not b:
                break
            d.write(b)
PY
  chmod 755 "$t/xray"
  "$t/xray" version 2>/dev/null | head -1 | grep -q "^Xray $v" || die "скачанный xray не запускается на этом роутере"
  [ -x "$XD/xray" ] && cp -p "$XD/xray" "$XD/xray.prev"
  mv -f "$t/xray" "$XD/xray.new" && mv -f "$XD/xray.new" "$XD/xray" || die "не удалось записать $XD/xray"
  say "установлен: $("$XD/xray" version | head -1)"
  [ -f "$XD/xray.prev" ] && say "  прежняя версия: $XD/xray.prev (откат: xray.sh rollback)"
  restart_tunnels
}

case "${1:-}" in
  version) ver ;;
  latest) latest ;;
  install|update) install "${2:-}" ;;
  rollback)
    [ -x "$XD/xray.prev" ] || die "прежней версии нет"
    mv -f "$XD/xray" "$XD/xray.bad" 2>/dev/null; mv -f "$XD/xray.prev" "$XD/xray" && say "возвращён: $("$XD/xray" version | head -1)"
    restart_tunnels ;;
  restart) restart_tunnels ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
