#!/bin/bash
# notify.sh — отправка в Telegram с резервированием: основной туннель -> запасной -> WAN.
#   notify.sh [--html] "текст"
# Не доставилось никуда — сообщение откладывается в notify.spool и уходит при следующей удачной отправке.
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
. "$DD/telegram.env" || exit 2
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}

MODE=""
[ "$1" = "--html" ] && { MODE=html; shift; }
TEXT="${1:0:3900}"
[ -z "$TEXT" ] && exit 0

LOG=$DD/notify.log
SPOOL=$DD/notify.spool
# Порядок попыток. Пустая строка = напрямую через WAN. Если WAN не нужен, задайте TG_NO_WAN=1 в telegram.env.
IFACES=("$MAIN")
[ -n "$BACKUP" ] && IFACES+=("$BACKUP")
[ "${TG_NO_WAN:-0}" = 1 ] || IFACES+=("")

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  if [ "$(wc -l < "$LOG")" -gt 300 ]; then tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; fi
}

# $1=интерфейс или "", $2=таймаут, $3=текст. Токен идёт через stdin: в списке процессов его не видно.
send_via() {
  local args=(-4 -s -m "$2" -o /dev/null -w '%{http_code}')
  [ -n "$1" ] && args+=(--interface "$1")
  [ "$MODE" = html ] && args+=(--data-urlencode "parse_mode=HTML")
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" |
    curl "${args[@]}" -K - \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=$3" \
      --data-urlencode "disable_web_page_preview=true" 2>/dev/null
}

send_text() {
  local i to code
  for i in "${IFACES[@]}"; do
    if [ "$i" = "$MAIN" ]; then to=10; else to=15; fi
    code=$(send_via "$i" "$to" "$1")
    if [ "$code" = 200 ]; then
      [ "$i" != "$MAIN" ] && log "доставлено через ${i:-WAN}"
      return 0
    fi
    log "не удалось через ${i:-WAN}: HTTP ${code:-000}"
  done
  return 1
}

spool_add() {
  printf '%s|%s\n' "$MODE" "$(printf '%s' "$1" | base64 -w0)" >> "$SPOOL"
  chmod 600 "$SPOOL"
  tail -n 20 "$SPOOL" > "$SPOOL.t" && mv "$SPOOL.t" "$SPOOL"
}

spool_flush() {
  [ -s "$SPOOL" ] || return 0
  local m b t keep=$MODE
  mv "$SPOOL" "$SPOOL.run"
  while IFS='|' read -r m b; do
    t=$(printf '%s' "$b" | base64 -d)
    MODE=$m
    send_text "$t" || printf '%s|%s\n' "$m" "$b" >> "$SPOOL"
  done < "$SPOOL.run"
  rm -f "$SPOOL.run"
  MODE=$keep
}

# одна отправка за раз (событие и отчёт могут совпасть)
exec 9>/tmp/awg-notify.lock
command -v flock >/dev/null && flock -w 120 9

if send_text "$TEXT"; then
  spool_flush
  exit 0
fi
log "ВСЕ КАНАЛЫ НЕДОСТУПНЫ, сообщение отложено"
spool_add "🕓 (отложено, событие в $(date '+%F %T'))"$'\n'"$TEXT"
exit 1
