#!/bin/bash
# failover.sh — сторож: держит AWG-туннель в таблице PBR UniFi и переключает каналы.
#   failover.sh            основной цикл (запускает systemd: awg-failover.service)
#   failover.sh cleanup    убрать свои маршруты из таблицы PBR
# Параметры: /data/awg/awg.env (создаёт awg-detect.sh).
DD=${DD:-/data/awg}
RS_ENV=$RECOVER_SEC                # RECOVER_SEC из командной строки важнее awg.env (для тестов)
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -n "$RS_ENV" ] && RECOVER_SEC=$RS_ENV
TABLE=${TABLE:?нет TABLE в awg.env: запустите awg-detect.sh}
MARK=${MARK:?нет MARK в awg.env: запустите awg-detect.sh}
PRIO=${PRIO:-32504}
MAIN=${MAIN:-awgmain}
BACKUP=${BACKUP:-}
RECOVER_SEC=${RECOVER_SEC:-600}   # сколько основной должен проработать без сбоев до возврата
TARGETS=${TARGETS:-"1.1.1.1 8.8.8.8"}
INTERVAL=${INTERVAL:-5}           # секунд между проверками
FAIL_MAX=${FAIL_MAX:-3}           # сбоев подряд до переключения
METRIC=5                          # метрика активного туннеля в таблице PBR
SIM=/tmp/awg-sim-down             # флаг имитации падения основного канала
LOGF=$DD/failover.log

log(){
  local m; m="$(date '+%F %T') $*"
  echo "$m"; logger -t awg-failover "$*" 2>/dev/null; echo "$m" >> "$LOGF"
  if [ "$(wc -l < "$LOGF")" -gt 1000 ]; then tail -n 500 "$LOGF" > "$LOGF.tmp" && mv "$LOGF.tmp" "$LOGF"; fi
}

# Канал жив, если через него открывается HTTPS (или, если не открылся, проходит ping).
# Первым идёт HTTPS: ICMP через туннели многих операторов не проходит.
check(){
  [ "$1" = "$MAIN" ] && [ -e "$SIM" ] && return 1
  local t c
  for t in $TARGETS; do
    c=$(curl -sk -o /dev/null --connect-timeout 3 -m 5 --interface "$1" -w '%{http_code}' "https://$t/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && return 0
    ping -I "$1" -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0
  done
  return 1
}

ensure(){ local t=$1; shift; iptables -w 5 -t "$t" -C "$@" 2>/dev/null || iptables -w 5 -t "$t" -I "$@"; }

prepare(){
  local i s
  for i in $MAIN $BACKUP; do
    ensure nat POSTROUTING -o "$i" -j MASQUERADE
    ensure mangle FORWARD -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure mangle FORWARD -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure filter FORWARD -o "$i" -j ACCEPT
    ensure filter FORWARD -i "$i" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  done
  ip rule show | grep -q "fwmark $MARK" || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"
  # дополнительные подсети (например, клиенты VPN-сервера роутера) в ipset локальных сетей UniFi
  for s in $EXTRA_SUBNETS; do
    ipset test UBIOS4local_network "$s" >/dev/null 2>&1 || ipset add UBIOS4local_network "$s" 2>/dev/null
  done
}

declare -A NEXT_TRY
ensure_tunnels(){
  local i now; now=$(date +%s)
  for i in $MAIN $BACKUP; do
    ip link show "$i" >/dev/null 2>&1 && continue
    [ "${NEXT_TRY[$i]:-0}" -gt "$now" ] && continue
    NEXT_TRY[$i]=$((now + 30))
    log "$i отсутствует, поднимаю"
    "$DD/up.sh" "$i" >/dev/null 2>&1 || log "$i: не удалось поднять (проверьте: $DD/up.sh $i)"
  done
}

set_active(){
  local a=$1 o
  if [ "$a" = "$MAIN" ]; then o=$BACKUP; else o=$MAIN; fi
  ip route replace default dev "$a" metric $METRIC table "$TABLE"
  [ -n "$o" ] && ip route del default dev "$o" table "$TABLE" 2>/dev/null
  ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
}

cleanup(){
  ip route del default dev "$MAIN" table "$TABLE" 2>/dev/null
  [ -n "$BACKUP" ] && ip route del default dev "$BACKUP" table "$TABLE" 2>/dev/null
  ip route del blackhole default metric 200 table "$TABLE" 2>/dev/null
}

[ "$1" = cleanup ] && { cleanup; exit 0; }
trap 'cleanup; log "остановка: маршруты убраны"; exit 0' INT TERM

# после загрузки роутера даём UniFi 30 с собрать свои правила и таблицы
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && sleep "${BOOT_WAIT:-30}"

state=$MAIN; fails=0; bfails=0; ok_since=0; both_flag=0
log "старт: основной $MAIN, запасной ${BACKUP:-нет}, таблица $TABLE, возврат через ${RECOVER_SEC}с"

while true; do
  ensure_tunnels
  prepare

  if [ "$state" = "$MAIN" ]; then
    if check "$MAIN"; then
      [ $both_flag -eq 1 ] && log "ВОССТАНОВЛЕН канал $MAIN, трафик по PBR снова идёт"
      fails=0; both_flag=0
    else
      fails=$((fails+1))
    fi
    if [ $fails -ge $FAIL_MAX ]; then
      if [ -n "$BACKUP" ] && check "$BACKUP"; then
        state=$BACKUP; fails=0; bfails=0; ok_since=0; both_flag=0
        log "ПЕРЕКЛЮЧЕНИЕ на запасной канал $BACKUP"
      elif [ $both_flag -eq 0 ]; then
        both_flag=1
        if [ -n "$BACKUP" ]; then log "оба канала не отвечают, остаюсь на $MAIN (трафик по PBR блокируется)"
        else log "единственный канал $MAIN не отвечает (трафик по PBR блокируется)"; fi
      fi
    fi
  else
    if check "$MAIN"; then
      [ $ok_since -eq 0 ] && { ok_since=$(date +%s); log "основной снова отвечает, жду ${RECOVER_SEC}с без сбоев"; }
      if [ $(( $(date +%s) - ok_since )) -ge "$RECOVER_SEC" ]; then
        state=$MAIN; fails=0; ok_since=0
        log "ВОЗВРАТ на основной канал $MAIN"
      fi
    else
      [ $ok_since -ne 0 ] && log "основной снова сбоит, отсчёт возврата сброшен"
      ok_since=0
    fi
    if [ "$state" = "$BACKUP" ]; then
      if check "$BACKUP"; then bfails=0; else bfails=$((bfails+1)); fi
      if [ $bfails -ge $FAIL_MAX ] && check "$MAIN"; then
        state=$MAIN; fails=0; bfails=0; ok_since=0
        log "запасной не отвечает, основной жив: возврат на $MAIN"
      fi
    fi
  fi

  set_active "$state"
  sleep "$INTERVAL"
done
