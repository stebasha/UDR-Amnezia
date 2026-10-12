#!/bin/bash
# awg-bot: управление из Telegram + дополнительные оповещения + недельный отчёт.
# Команды (отвечает только в чате TG_CHAT из telegram.env, остальные чаты игнорируются):
#   /status  /ip  /switch <main|backup|имя>  /auto  /events [N]  /stats [дней]  /selftest  /restart  /help
# Оповещения (поверх awg-notify, без повторов): отклонённое ручное переключение, мало места на /data, остановка служб awg-*,
# пропавший интерфейс VPN-сервера, неверное время; раз в неделю (понедельник, после REPORT_TIME) сводка.
#   bot.sh              демон (systemd)
#   bot.sh --once-from ФАЙЛ   обработать готовый ответ getUpdates из файла (для тестов)
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -r "$DD/telegram.env" ] && . "$DD/telegram.env" || { echo "нет $DD/telegram.env"; exit 2; }
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
REPORT_TIME=${REPORT_TIME:-0900}
BOT_DISK_MB=${BOT_DISK_MB:-100}
OFFF=$DD/bot.offset
LOG=$DD/bot.log
STATEF=${STATEF:-/run/awg-state}
H=$(hostname)

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 300 ]; then tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; fi; }
esc(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
send(){ "$DD/notify.sh" --html "$1" >/dev/null 2>&1; }
reply(){ send "<b>$1</b> · $H"$'\n'"<pre>$(printf '%s' "$2" | esc | cut -c1-3300)</pre>"; }

iface_order(){  # через какие интерфейсы ходить в Telegram: активный туннель, остальные, затем WAN
  local a=""; [ -r "$STATEF" ] && a=$(. "$STATEF"; echo "$ACTIVE")
  { [ -n "$a" ] && echo "$a"; for t in $TUNS; do echo "$t"; done; [ "${TG_NO_WAN:-0}" = 1 ] || echo ""; } | awk '!s[$0]++'
}
api(){  # api МЕТОД?параметры [curl-аргументы] — токен только через stdin
  local m=$1 i r; shift
  while IFS= read -r i; do
    r=$(printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TG_TOKEN" "$m" | curl -4 -s -m 40 ${i:+--interface $i} -K - "$@" 2>/dev/null)
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  done < <(iface_order)
  return 1
}

parse(){  # JSON getUpdates → строки update_id|chat_id|текст|тип
  # Разбор через python3 (надёжно при любом форматировании JSON); без него — запасной разбор по одной строке
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for u in d.get("result", []):
    kind = next((k for k in u if k != "update_id"), "?")
    m = u.get("message") or u.get("edited_message") or {}
    c = (m.get("chat") or {}).get("id", "")
    t = (m.get("text") or "").replace("|", " ").replace("\n", " ")
    print("%s|%s|%s|%s" % (u.get("update_id", ""), c, t, kind))
'
    return
  fi
  local u id chat text
  tr -d '\r\n' | sed 's/{"update_id"/\n{"update_id"/g' | grep '^{"update_id"' | while IFS= read -r u; do
    id=$(printf '%s' "$u" | grep -o '^{"update_id": *[0-9]*' | grep -o '[0-9]*$')
    chat=$(printf '%s' "$u" | grep -o '"chat": *{ *"id": *-\?[0-9]*' | head -n1 | grep -o -- '-\?[0-9]*$')
    text=$(printf '%s' "$u" | grep -o '"text": *"[^"]*"' | head -n1 | sed 's/^"text": *"//; s/"$//')
    echo "$id|$chat|$text|message"
  done
}

handle(){  # handle "/команда аргументы"
  local cmd arg rest out
  cmd=${1%% *}; rest=${1#"$cmd"}; arg=${rest# }
  cmd=${cmd%%@*}
  case "$cmd" in /events|/stats) [[ $arg =~ ^[0-9]{1,4}$ ]] || arg="";; /switch) [[ $arg =~ ^[A-Za-z0-9_-]{1,20}$ ]] || arg="";; esac
  case "$cmd" in
    /status)   reply "Статус" "$("$DD/awgctl.sh" status 2>&1)";;
    /ip)       reply "Внешние IP" "$("$DD/awgctl.sh" ip 2>&1)";;
    /switch)   if [ -z "$arg" ]; then reply "Переключение" "Укажите канал: /switch main | backup | имя ($TUNS)"; else reply "Переключение" "$("$DD/awgctl.sh" switch "$arg" 2>&1)"; fi;;
    /auto)     reply "Авто-режим" "$("$DD/awgctl.sh" auto 2>&1)";;
    /events)   reply "События" "$("$DD/awgctl.sh" events "${arg:-15}" 2>&1)";;
    /stats)    reply "Статистика" "$("$DD/awgctl.sh" stats "${arg:-7}" 2>&1)";;
    /selftest) out=$(NO_COLOR=1 "$DD/selftest.sh" 2>&1 | grep -v -E '^  OK |^$|^== '); reply "Самопроверка" "${out:-все проверки пройдены}";;
    /restart)  systemctl restart awg-failover; sleep 6; reply "Перезапуск сторожа" "$("$DD/awgctl.sh" status 2>&1)";;
    /start|/help) reply "Команды" $'/status  состояние каналов\n/ip  внешние IP\n/switch main|backup|имя  вручную на канал\n/auto  вернуть автоматику\n/events [N]  последние события\n/stats [дней]  статистика\n/selftest  самопроверка (только замечания)\n/restart  перезапустить сторож';;
    *) reply "Команда не распознана" "Список: /help";;
  esac
}

process(){  # process ФАЙЛ_С_JSON → обработать, сохранить offset
  local u cid txt kind last="" want
  want=$(printf '%s' "$TG_CHAT" | tr -cd '0-9-')       # без пробелов и \r из telegram.env
  while IFS='|' read -r u cid txt kind; do
    [ -n "$u" ] || continue
    last=$u
    if [ -z "$cid" ]; then log "пропускаю обновление без чата (тип ${kind:-?})"; continue; fi
    if [ "$cid" != "$want" ]; then log "игнорирую чужой чат $cid (ожидается $want)"; continue; fi
    case "$txt" in /*) log "команда: ${txt%% *}"; handle "$txt";; esac
  done < <(parse < "$1")
  [ -n "$last" ] && echo $((last+1)) > "$OFFF"
}

# ---------- оповещения ----------
declare -A BAD ALR
chk(){  # chk имя плохо(1/0) "текст тревоги" "текст восстановления"; тревога после 3 плохих проверок подряд
  local n=$1
  if [ "$2" = 1 ]; then
    BAD[$n]=$(( ${BAD[$n]:-0} + 1 ))
    [ "${BAD[$n]}" -ge 3 ] && [ "${ALR[$n]:-0}" = 0 ] && { ALR[$n]=1; send "<b>$3</b> · $H"; }
  else
    BAD[$n]=0
    [ "${ALR[$n]:-0}" = 1 ] && { ALR[$n]=0; send "<b>$4</b> · $H"; }
  fi
}
events_watch(){  # события из events.log, о которых awg-notify не сообщает (деградацию и ручное переключение он шлёт сам)
  local ts ty tx
  tail -n0 -F "$DD/events.log" 2>/dev/null | while IFS='|' read -r ts ty tx; do
    case "$ty" in
      refused) send "<b>⚠️ Ручное переключение отклонено</b> · $H"$'\n'"$(printf '%s' "$tx" | esc)";;
    esac
  done
}
monitor(){
  local bad fr s i lastw=""
  while sleep 60; do
    fr=$(df -Pm "$DD" 2>/dev/null | awk 'NR==2{print $4}'); bad=0; [ -n "$fr" ] && [ "$fr" -lt "$BOT_DISK_MB" ] && bad=1
    chk disk "$bad" "⚠️ На /data мало места: ${fr} МБ" "✅ Место на /data в норме"
    bad=0; [ "$(date +%Y)" -lt 2025 ] && bad=1
    chk time "$bad" "⚠️ Часы роутера неверны ($(date)): handshake может не проходить" "✅ Часы роутера в норме"
    for s in awg-subnets awg-self awg-guard awg-metrics; do
      bad=0
      if [ -f "/etc/systemd/system/$s.service" ] && ! systemctl is-active --quiet $s 2>/dev/null; then bad=1; fi
      chk "svc_$s" "$bad" "🛑 Служба $s остановлена" "✅ Служба $s снова работает"
    done
    for s in $EXTRA_SUBNETS; do
      bad=0; ip -4 route show table all to "$s" 2>/dev/null | grep -q dev || bad=1
      chk "sub_$s" "$bad" "⚠️ Подсеть VPN-сервера $s пропала (VPN-сервер выключен?)" "✅ Подсеть $s снова на месте"
    done
    # недельный отчёт: понедельник, после REPORT_TIME, один раз
    if [ "$(date +%u)" = 1 ] && [ $((10#$(date +%H%M))) -ge $((10#$REPORT_TIME)) ] && [ "$(cat "$DD/bot.lastweek" 2>/dev/null)" != "$(date +%G-%V)" ]; then
      date +%G-%V > "$DD/bot.lastweek"
      reply "Недельный отчёт · $(date +%F)" "$("$DD/awgctl.sh" stats 7 2>&1)"$'\n\n'"$("$DD/awgctl.sh" status 2>&1)"
    fi
  done
}

if [ "$1" = --once-from ]; then process "$2"; exit 0; fi

monitor & MON=$!
events_watch & EVW=$!
trap 'kill $MON $EVW 2>/dev/null; exit 0' INT TERM EXIT
sleep 25
log "бот запущен, чат $TG_CHAT"
while :; do
  off=$(cat "$OFFF" 2>/dev/null || echo 0)
  r=$(api "getUpdates?offset=$off&timeout=25&allowed_updates=%5B%22message%22%5D")
  if [ -z "$r" ]; then sleep 10; continue; fi
  if ! printf '%s' "$r" | grep -q '"ok":true'; then
    log "Telegram вернул ошибку: $(printf '%s' "$r" | cut -c1-120)"
    printf '%s' "$r" | grep -q '"error_code":409' && log "конфликт 409: этот бот читает ещё какая-то программа"
    sleep 30; continue
  fi
  tmp=$(mktemp "$DD/.bot.XXXXXX"); printf '%s' "$r" > "$tmp"; process "$tmp"; rm -f "$tmp"
done
