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
#   awgctl report             обезличенный отчёт для issue (ключи и IP скрыты)
#   awgctl drift [save|repair]   сверка правил и служб с эталоном; repair — вернуть правила набора
#   awgctl web [passwd ИМЯ|users|totp-off ИМЯ|cert|url]   веб-панель
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
  sleep 7
  [ -r "$STATEF" ] && . "$STATEF"
  if [ "$ACTIVE" = "$n" ]; then echo "переключено: активен $n (вручную). Вернуть автомат: awgctl auto"
  else echo "не переключилось: канал $n не отвечает или сторож не запущен (см. $DD/failover.log)"; return 1; fi
}
cmd_auto(){ rm -f "$FORCEF"; sleep 7; [ -r "$STATEF" ] && . "$STATEF"; echo "автоматический режим. Сейчас активен: ${ACTIVE:-?}. Возврат на приоритетный канал — после RECOVER_SEC=${RECOVER_SEC:-600} с стабильной работы."; }

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
  awk -F'|' -v from="$from" -v now="$now" -v days="$days" '
    function fmt(s){ if(s>=86400) return sprintf("%dд %02dч", s/86400, (s%86400)/3600); if(s>=3600) return sprintf("%dч %02dм", s/3600, (s%3600)/60); return sprintf("%dм %02dс", s/60, s%60) }
    function ov(a,b){ if(b<=from) return 0; return b-(a<from?from:a) }
    { if($1>=from) c[$2]++
      if($2=="switch"||$2=="degrade"||$2=="force"){ if(!on){ on=1; st=$1 } }
      else if($2=="return"||$2=="auto"){ if(on){ off+=ov(st,$1); on=0 } } }
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
  domain)  exec "$DD/domain-check.sh" "$2";;
  report)  shift; exec "$DD/report.sh" "$@";;
  drift)   shift; exec "$DD/drift.sh" "$@";;
  web)     shift
           case "${1:-url}" in
             url) p=$(sed -n 's/^WEB_PORT=//p' "$DD/web/web.conf" 2>/dev/null); b=$(ip -4 -br addr show br0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
                  echo "https://${b:-IP_РОУТЕРА}:${p:-4443}/  (служба awg-web: $(systemctl is-active awg-web 2>/dev/null))";;
             *) exec python3 "$DD/web/panel.py" "$@";;
           esac;;
  help|-h|--help) sed -n '2,19p' "$0";;
  *) echo "неизвестная команда: $1 (awgctl help)"; exit 1;;
esac
