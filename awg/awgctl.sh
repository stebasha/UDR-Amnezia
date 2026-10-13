#!/bin/bash
# awgctl: управление и просмотр AmneziaWG-failover.
#   awgctl status             активный канал, handshake, потери/RTT каждого туннеля
#   awgctl switch <имя|main|backup>   принудительно перейти на туннель (пока он жив)
#   awgctl auto               вернуть автоматический выбор
#   awgctl events [N]         последние N событий (по умолчанию 20)
#   awgctl stats [дней]       статистика по событиям за период (по умолчанию 7)
#   awgctl ip                 внешний IP через каждый туннель и напрямую
#   awgctl selftest [--full]  полная самопроверка (selftest.sh)
#   awgctl mtu [...]          подбор MTU (mtu.sh)
#   awgctl backup [...]       резервная копия (backup.sh)
#   awgctl dedup              убрать дубликаты правил iptables для туннелей
#   awgctl diagnose           дерево причин: что сломано и как исправить
#   awgctl domain ДОМЕН       куда пойдёт сайт, открывается ли через туннель и напрямую
#   awgctl ping [auto|icmp|tcp] ИНТЕРФЕЙС УЗЕЛ [ПОРТ]   задержка через туннель/WAN; auto: ICMP, без ответа — TCP
#   awgctl report             обезличенный отчёт для issue (ключи и IP скрыты)
#   awgctl drift [save|repair]   сверка правил и служб с эталоном; repair — вернуть правила набора
#   awgctl web [passwd ИМЯ|users|totp-off ИМЯ|cert|url]   веб-панель
#   awgctl vps [--vps ID] [list|test|status|versions|update|rotate-keys|obfs]   свой VPS (vps.sh); несколько VPS — #32
DD=${DD:-/data/awg}
AWG=$DD/awg
FORCEF=${FORCEF:-/run/awg-force}
STATEF=${STATEF:-/run/awg-state}
EVF=$DD/events.log
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TABLE=${TABLE:-0}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"

hs_age(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
fa(){ local a=$1; if [ "$a" -lt 0 ]; then echo "нет"; elif [ "$a" -lt 120 ]; then echo "${a}с"; elif [ "$a" -lt 7200 ]; then echo "$((a/60))м"; else echo "$((a/3600))ч"; fi; }
fd(){ local s=$1; if [ "$s" -ge 86400 ]; then printf '%dд %02dч' $((s/86400)) $((s%86400/3600)); elif [ "$s" -ge 3600 ]; then printf '%dч %02dм' $((s/3600)) $((s%3600/60)); else printf '%dм %02dс' $((s/60)) $((s%60)); fi; }
resolve_name(){ case "$1" in main|основной) echo "$MAIN";; backup|запасной) echo "$BACKUP";; *) echo "$1";; esac; }
active_from_table(){ ip route show table "$TABLE" 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev" && $(i+1) ~ /^awg/){print $(i+1); exit}}'; }

cmd_status(){
  local a t forced upd
  # shellcheck source=/dev/null
  [ -r "$STATEF" ] && . "$STATEF"
  a=${ACTIVE:-$(active_from_table)}; forced=${FORCED:-}
  echo "Активный канал : ${a:-нет (трафик PBR блокируется)}${forced:+ (выбран вручную)}"
  if [ -n "$UPDATED" ]; then upd=$(( $(date +%s) - UPDATED )); [ $upd -gt 30 ] && echo "ВНИМАНИЕ        : состояние сторожа не обновлялось ${upd} с (awg-failover работает?)"; fi
  printf '%-12s %-10s %-9s %-8s\n' Туннель handshake потери RTT
  for t in $TUNS; do
    local l r lv rv; eval "l=\${LOSS_$t:-}; r=\${RTT_$t:-}"
    lv=${l:+$l%}; rv=${r:+$r мс}
    printf '%-12s %-10s %-9s %-8s\n' "$t" "$(fa "$(hs_age "$t")")" "${lv:--}" "${rv:--}"
  done
  echo "Сторож         : $(systemctl is-active awg-failover 2>/dev/null)"
}

cmd_switch(){
  local n; n=$(resolve_name "$1")
  [ -n "$n" ] || { echo "укажите туннель: $TUNS"; return 1; }
  case " $TUNS " in *" $n "*) ;; *) echo "нет туннеля «$n». Есть: $TUNS"; return 1;; esac
  echo "$n" > "$FORCEF"
  # круг сторожа с проверками качества бывает дольше 10 с: ждём до 30 с, отказ сторожа видно по удалённому FORCEF
  local i
  for i in $(seq 1 30); do
    sleep 1
    # shellcheck source=/dev/null
    [ -r "$STATEF" ] && . "$STATEF"
    [ "$ACTIVE" = "$n" ] && { echo "переключено: активен $n (вручную). Вернуть автомат: awgctl auto"; return 0; }
    [ -s "$FORCEF" ] || { echo "отклонено: канал $n не отвечает (см. $DD/failover.log)"; return 1; }
  done
  echo "не переключилось за 30 с: сторож не запущен или занят (см. $DD/failover.log)"; return 1
}
# shellcheck source=/dev/null
cmd_auto(){ rm -f "$FORCEF"; sleep 7; [ -r "$STATEF" ] && . "$STATEF"; echo "автоматический режим. Сейчас активен: ${ACTIVE:-?}. Возврат на приоритетный канал — после RECOVER_SEC=${RECOVER_SEC:-600} с стабильной работы."; }

# ping через интерфейс: ICMP, TCP (время подключения, как у сторожа при проверке качества) или auto —
# ICMP, а если ни одного ответа (его часто режут провайдер или сервер туннеля) — TCP. Код: 0 — ответы были.
cmd_ping(){
  local mode=${1:-auto} dev=${2:-} host=${3:-} port=${4:-443} n=${COUNT:-10} out rc
  case "$mode" in auto|icmp|tcp) ;; *) echo "awgctl ping [auto|icmp|tcp] ИНТЕРФЕЙС УЗЕЛ [ПОРТ]"; return 2;; esac
  [ -n "$dev" ] && [ -n "$host" ] || { echo "awgctl ping [auto|icmp|tcp] ИНТЕРФЕЙС УЗЕЛ [ПОРТ]"; return 2; }
  [[ $port =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo "порт: 1–65535"; return 2; }
  _icmp(){
    local out rc
    out=$(ping -c "$n" -i 0.5 -W 2 -I "$dev" "$host" 2>&1); rc=$?
    echo "$out"
    return $rc
  }

  _tcp(){
    local i t ok=0 sum=0 min="" max="" ms
    echo "TCP: время подключения к $host:$port через $dev, попыток: $n"
    for i in $(seq 1 "$n"); do
      t=$(curl -sk -o /dev/null --connect-timeout 2 -m 3 --interface "$dev" -w '%{time_connect}' "https://$host:$port/" 2>/dev/null)
      ms=$(awk -v t="${t:-0}" 'BEGIN{printf "%d", t*1000}')
      if [ "${ms:-0}" -gt 0 ]; then
        ok=$((ok+1)); sum=$((sum+ms))
        { [ -z "$min" ] || [ "$ms" -lt "$min" ]; } && min=$ms
        { [ -z "$max" ] || [ "$ms" -gt "$max" ]; } && max=$ms
        echo "  $i: $ms мс"
      else
        echo "  $i: нет соединения"
      fi
      [ "$i" -lt "$n" ] && sleep 0.5
    done
    echo "--- $host:$port, TCP ---"
    echo "попыток: $n, соединений: $ok, потери: $(( (n-ok)*100/n ))%"
    [ $ok -gt 0 ] && echo "задержка мин/сред/макс: $min/$((sum/ok))/$max мс"
    [ $ok -gt 0 ]
  }

  case "$mode" in
    icmp) _icmp;;
    tcp)  _tcp;;
    auto)
      out=$(_icmp); rc=$?
      echo "$out"
      if [ $rc -ne 0 ] && ! echo "$out" | grep -qE ' [1-9][0-9]* received'; then
        echo
        echo "ICMP не ответил (часто его режет провайдер или сервер туннеля) — меряю по TCP:"
        _tcp
      fi;;
  esac
}

cmd_events(){
  local n=${1:-20}
  [ -s "$EVF" ] || { echo "событий пока нет"; return 0; }
  tail -n "$n" "$EVF" | while IFS='|' read -r ts ty tx; do printf '%s  %-8s %s\n' "$(date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts")" "$ty" "$tx"; done
}

# статистика: переключения, время не на основном канале
cmd_stats(){
  local days=${1:-7} now from
  now=$(date +%s); from=$((now - days*86400))
  [ -s "$EVF" ] || { echo "событий пока нет"; return 0; }
  awk -F'|' -v from="$from" -v now="$now" -v days="$days" -v main="$MAIN" '
    function fmt(s){ if(s>=86400) return sprintf("%dд %02dч", s/86400, (s%86400)/3600); if(s>=3600) return sprintf("%dч %02dм", s/3600, (s%3600)/60); return sprintf("%dм %02dс", s/60, s%60) }
    function ov(a,b){ if(b<=from) return 0; return b-(a<from?from:a) }
    { if($1>=from) c[$2]++
      tomain=($2=="force" && $3 ~ (" " main "$"))   # auto канал не меняет; ручной выбор основного — возврат
      if(($2=="switch"||$2=="degrade"||$2=="force") && !tomain){ if(!on){ on=1; st=$1 } }
      else if($2=="return"||$2=="start"||tomain){ if(on){ off+=ov(st,$1); on=0 } } }
    END{
      if(on) off+=ov(st,now)
      printf "Период                      : %d дн.\n", days
      printf "Переключений на запасной    : %d\n", c["switch"]+0
      printf "Деградаций по качеству      : %d\n", c["degrade"]+0
      printf "Ручных переключений         : %d\n", c["force"]+0
      printf "Возвратов на приоритетный   : %d\n", c["return"]+0
      printf "Все каналы не отвечали      : %d раз\n", c["both"]+0
      printf "Запусков сторожа            : %d\n", c["start"]+0
      printf "Время не на основном канале : %s (%.1f%% периода)\n", fmt(off), off*100/(days*86400)
    }' "$EVF"
}

cmd_ip(){
  local t ip w
  for t in $TUNS; do ip=$(curl -4 -s -m 6 --interface "$t" https://api.ipify.org 2>/dev/null); printf '%-12s %s\n' "$t" "${ip:-недоступен}"; done
  w=${WANIF:-}; ip=$(curl -4 -s -m 6 ${w:+--interface $w} https://api.ipify.org 2>/dev/null); printf '%-12s %s\n' "напрямую(WAN)" "${ip:-недоступен}"
}

case "${1:-status}" in
  status)  cmd_status;;
  switch)  cmd_switch "$2";;
  auto)    cmd_auto;;
  events)  cmd_events "$2";;
  stats)   cmd_stats "$2";;
  ip)      cmd_ip;;
  selftest) shift; exec "$DD/selftest.sh" "$@";;
  mtu)     shift; exec "$DD/mtu.sh" "$@";;
  backup)  shift; exec "$DD/backup.sh" "$@";;
  dedup)   exec "$DD/failover.sh" dedup;;
  diagnose|diag) exec "$DD/diagnose.sh";;
  ping)    shift; cmd_ping "$@";;
  domain|domain-check) exec "$DD/domain-check.sh" "$2";;
  report)  shift; exec "$DD/report.sh" "$@";;
  drift)   shift; exec "$DD/drift.sh" "$@";;
  vps)     shift; exec "$DD/vps.sh" "$@";;
  web)     shift
           case "${1:-url}" in
             url) p=$(sed -n 's/^WEB_PORT=//p' "$DD/web/web.conf" 2>/dev/null); b=$(ip -4 -br addr show br0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
                  echo "https://${b:-IP_РОУТЕРА}:${p:-4443}/  (служба awg-web: $(systemctl is-active awg-web 2>/dev/null))";;
             *) exec python3 "$DD/web/panel.py" "$@";;
           esac;;
  help|-h|--help) sed -n '2,19p' "$0";;
  *) echo "неизвестная команда: $1 (awgctl help)"; exit 1;;
esac
