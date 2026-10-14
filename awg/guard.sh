#!/bin/bash
# iptables/ip6tables всегда с ожиданием блокировки xtables: без -w iptables 1.8.7 (legacy) при занятой блокировке
# сразу падает, и проверка «есть ли правило» ошибочно отвечает «нет» → дубликаты.
iptables(){ command iptables -w 10 "$@"; }
ip6tables(){ command ip6tables -w 10 "$@"; }
# awg-guard: правила для транзитного трафика (клиенты LAN и VPN-сервера роутера).
#  1) Защита от утечек (LEAK_GUARD=yes, по умолчанию): пакет с меткой PBR AWG (MARK) не должен уходить в WAN.
#     Основная защита — blackhole в таблице PBR; это вторая линия на случай, если UniFi сотрёт маршруты/правила.
#     IPv6 (LEAK_V6=block, по умолчанию): помеченный IPv6-трафик и IPv6 клиентов VPN-сервера в WAN не выпускаются.
#     LEAK_V6=route (#23): помеченный IPv6 сторож ведёт через туннель; в WAN он всё так же не выпускается.
#     Метки дополнительных маршрутов (#22, route.d/*.env) защищаются так же, как основная.
#  2) Домены через туннель (TUN_DOMAINS): клиенты LAN (TUN_CLIENTS, пусто = вся LAN) ходят на эти домены через AWG.
#     Адреса доменов наполняют ipset AWG_DOM (это делает dnsmasq по файлу, который пишет self.sh).
#  3) Исключения (DIRECT_DOMAINS, DIRECT_SUBNETS): клиенты под PBR ходят туда напрямую, мимо туннеля.
#
#   guard.sh run      служба: каждые 5 с сверяет правила
#   guard.sh apply    один проход
#   guard.sh remove   убрать все правила и наборы
#   guard.sh check    проверка: OK / WARN / FAIL
#   guard.sh status   цепочки
DD=${DD:-/data/awg}
CF=AWG_GUARD        # filter FORWARD (IPv4) и ip6tables FORWARD
CD=AWG_DOM_PRE      # mangle PREROUTING, в начало: маркировка доменов
CX=AWG_DIRECT_POST  # mangle PREROUTING, в конец: снятие метки для исключений
DOMSET=AWG_DOM
DIRSET=AWG_DIRECT
HASHF=/tmp/awg-guard.hash

load(){
  TABLE=""; MARK=""; WANIF=""
  LEAK_GUARD=yes; LEAK_V6=block; TUN_DOMAINS=""; TUN_CLIENTS=""; DIRECT_DOMAINS=""; DIRECT_SUBNETS=""; EXTRA_SUBNETS=""
  [ -r "$DD/awg.env" ] && . "$DD/awg.env"
  MASK=${MARK#*/}; [ "$MASK" = "$MARK" ] && MASK=0xffffffff
  ROUTE_MARKS=$(sed -n 's/^MARK="\{0,1\}\([0-9a-fx\/]*\)"\{0,1\}$/\1/p' "$DD"/route.d/*.env 2>/dev/null | sort -u | tr '\n' ' ')
  V6ON=0; case "$LEAK_V6" in block|route) V6ON=1;; esac
}
WANF=${AWG_RUN:-/run}/awg-guard.wans
wans(){  # интерфейсы WAN: default-маршруты в любых таблицах, кроме туннелей/рельсы.
  # Список только растёт (с загрузки роутера): если WAN на минуту пропал (PPPoE переподключается, резервный WAN),
  # защита для него остаётся, а не пересобирается без него.
  { cat "$WANF" 2>/dev/null
    ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
    ip -6 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
    echo "$WANIF"; } | grep -v -E '^(awg|wg|lo|wgclt|br|switch|ifb|tun|tlprt|$)' | sort -u > "$WANF.t" 2>/dev/null && mv -f "$WANF.t" "$WANF"
  cat "$WANF" 2>/dev/null
}
sub_iface(){ ip -4 route show table all to "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
ipt(){ iptables "$@" 2>/dev/null; }
ipt6(){ command -v ip6tables >/dev/null && ip6tables "$@" 2>/dev/null; }

rm_chain(){  # rm_chain команда таблица родитель цепочка
  local cmd=$1 t=$2 par=$3 ch=$4
  while $cmd -t "$t" -D "$par" -j "$ch" 2>/dev/null; do :; done
  $cmd -t "$t" -F "$ch" 2>/dev/null; $cmd -t "$t" -X "$ch" 2>/dev/null
}
# Переход в нашу цепочку: ровно один и на нужном месте. Если список правил не прочитался (блокировка xtables
# не освободилась), ничего не трогаем: иначе можно оставить два перехода или ни одного. Повтор — через 5 с.
jump_place(){ # jump_place first|last команда таблица родитель цепочка
  local pos=$1 cmd=$2 t=$3 par=$4 ch=$5 o n k at
  o=$($cmd -t "$t" -S "$par" 2>/dev/null) || return 0
  n=$(printf '%s\n' "$o" | grep -c -x -- "-A $par -j $ch")
  if [ "$pos" = first ]; then at=$(printf '%s\n' "$o" | grep '^-A' | head -n1); else at=$(printf '%s\n' "$o" | grep '^-A' | tail -n1); fi
  [ "$n" = 1 ] && [ "$at" = "-A $par -j $ch" ] && return 0
  for ((k=0; k<n; k++)); do $cmd -t "$t" -D "$par" -j "$ch" 2>/dev/null || return 0; done
  if [ "$pos" = first ]; then $cmd -t "$t" -I "$par" 1 -j "$ch" 2>/dev/null; else $cmd -t "$t" -A "$par" -j "$ch" 2>/dev/null; fi
}
jump_first(){ jump_place first "$@"; }
jump_last(){ jump_place last "$@"; }
BERR=0
# команда сборки цепочки; код 4 = блокировка xtables не освободилась: цепочки соберём заново через 5 с
B(){ "$@" 2>/dev/null; [ $? -eq 4 ] && BERR=1; return 0; }
chains_ok(){  # все наши цепочки на месте (UniFi при перепровижнинге может удалить пользовательские цепочки)
  iptables -t mangle -S $CX >/dev/null 2>&1 && iptables -t mangle -S $CD >/dev/null 2>&1 || return 1
  if [ "$LEAK_GUARD" = yes ]; then
    iptables -t filter -S $CF >/dev/null 2>&1 || return 1
    if [ "$V6ON" = 1 ] && command -v ip6tables >/dev/null; then ip6tables -t filter -S $CF >/dev/null 2>&1 || return 1; fi
  fi
  return 0
}

build_leak(){  # $1 = список WAN-интерфейсов
  local w s i
  iptables -t filter -N $CF 2>/dev/null; B iptables -t filter -F $CF
  local m
  if [ -n "$MARK" ]; then for w in $1; do for m in $MARK $ROUTE_MARKS; do B iptables -t filter -A $CF -o "$w" -m mark --mark "$m" -j DROP; done; done; fi
  jump_first iptables filter FORWARD $CF
  if command -v ip6tables >/dev/null && [ "$V6ON" = 1 ]; then
    ip6tables -t filter -N $CF 2>/dev/null; B ip6tables -t filter -F $CF
    for w in $1; do
      if [ -n "$MARK" ]; then for m in $MARK $ROUTE_MARKS; do B ip6tables -t filter -A $CF -o "$w" -m mark --mark "$m" -j REJECT --reject-with icmp6-adm-prohibited; done; fi
      for s in $EXTRA_SUBNETS; do i=$(sub_iface "$s"); [ -n "$i" ] && B ip6tables -t filter -A $CF -i "$i" -o "$w" -j REJECT --reject-with icmp6-adm-prohibited; done
      # «домены через туннель» работают по IPv4: их IPv6-адреса (AAAA) отклоняем, и устройства переходят на IPv4 → туннель
      [ -n "$TUN_DOMAINS" ] && B ip6tables -t filter -A $CF -i br+ -o "$w" -m set --match-set ${DOMSET}6 dst -j REJECT --reject-with icmp6-adm-prohibited
    done
    jump_first ip6tables filter FORWARD $CF
  else
    rm_chain ip6tables filter FORWARD $CF                    # LEAK_V6 выключили: правила IPv6 убрать
  fi
}

build_dom(){
  local c n
  iptables -t mangle -N $CD 2>/dev/null; B iptables -t mangle -F $CD
  if [ -n "$TUN_DOMAINS" ] && [ -n "$MARK" ]; then
    B iptables -t mangle -A $CD -m mark ! --mark 0x0/"$MASK" -j RETURN
    if [ -n "$TUN_CLIENTS" ]; then
      for c in $TUN_CLIENTS; do B iptables -t mangle -A $CD -s "$c" -m set --match-set $DOMSET dst -j MARK --set-xmark "$MARK"; done
    else
      B iptables -t mangle -A $CD -i br+ -m set --match-set $DOMSET dst -j MARK --set-xmark "$MARK"
    fi
  fi
  jump_first iptables mangle PREROUTING $CD
}

build_direct(){
  local n
  iptables -t mangle -N $CX 2>/dev/null; B iptables -t mangle -F $CX
  if [ -n "$MARK" ]; then
    for n in $DIRECT_SUBNETS; do B iptables -t mangle -A $CX -d "$n" -j MARK --set-xmark "0x0/$MASK"; done
    [ -n "$DIRECT_DOMAINS" ] && B iptables -t mangle -A $CX -m set --match-set $DIRSET dst -j MARK --set-xmark "0x0/$MASK"
  fi
  jump_last iptables mangle PREROUTING $CX
}

apply(){  # один проход за раз (служба и ручной запуск не мешают друг другу: иначе две сборки цепочки дают дубликаты)
  if command -v flock >/dev/null; then ( flock -w 30 9 || exit 0; apply_body ) 9>"${AWG_RUN:-/run}/awg-guard.lock"; else apply_body; fi
  return 0
}
apply_body(){
  load
  [ -n "$TABLE" ] && [ -n "$MARK" ] || return 0
  local W h
  BERR=0
  W=$(wans | tr '\n' ' ')
  [ -n "$TUN_DOMAINS" ] && { ipset create $DOMSET hash:ip family inet timeout 43200 -exist 2>/dev/null; ipset create ${DOMSET}6 hash:ip family inet6 timeout 43200 -exist 2>/dev/null; }
  [ -n "$DIRECT_DOMAINS" ] && ipset create $DIRSET hash:ip family inet timeout 43200 -exist 2>/dev/null
  h=$(printf 'g4|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$MARK" "$ROUTE_MARKS" "$W" "$LEAK_GUARD" "$LEAK_V6" "$TUN_DOMAINS" "$TUN_CLIENTS" "$DIRECT_DOMAINS" "$DIRECT_SUBNETS" "$EXTRA_SUBNETS" "$(for s in $EXTRA_SUBNETS; do sub_iface "$s"; done | tr '\n' ' ')" | md5sum | cut -c1-12)
  if [ "$(cat $HASHF 2>/dev/null)" != "$h" ] || ! chains_ok; then
    if [ "$LEAK_GUARD" = yes ]; then build_leak "$W"; else rm_chain iptables filter FORWARD $CF; rm_chain ip6tables filter FORWARD $CF; fi
    build_dom
    build_direct
    if [ "$BERR" = 0 ]; then echo "$h" > $HASHF; else rm -f $HASHF; fi   # не всё применилось — повторим через 5 с
  fi
  # порядок цепочек относительно UniFi проверяем каждый проход (UniFi может переставить свои переходы)
  [ "$LEAK_GUARD" = yes ] && { jump_first iptables filter FORWARD $CF; [ "$V6ON" = 1 ] && jump_first ip6tables filter FORWARD $CF; }
  jump_first iptables mangle PREROUTING $CD
  jump_last iptables mangle PREROUTING $CX
  return 0
}

remove(){
  load
  rm_chain iptables filter FORWARD $CF; rm_chain ip6tables filter FORWARD $CF
  rm_chain iptables mangle PREROUTING $CD; rm_chain iptables mangle PREROUTING $CX
  ipset destroy $DOMSET 2>/dev/null; ipset destroy ${DOMSET}6 2>/dev/null; ipset destroy $DIRSET 2>/dev/null; rm -f "$WANF"
  rm -f $HASHF
}

check(){
  load
  local rc=0 w
  [ -n "$MARK" ] || { echo "FAIL   нет MARK в awg.env (запустите awg-detect.sh)"; return 1; }
  if [ "$LEAK_GUARD" = yes ]; then
    if iptables -S FORWARD 2>/dev/null | grep '^-A' | head -n1 | grep -q -- "-j $CF"; then echo "OK     IPv4: цепочка $CF стоит первой в FORWARD (помеченный трафик в WAN не выпускается)"
    else echo "FAIL   IPv4: цепочка $CF не стоит первой в FORWARD (служба awg-guard запущена?)"; rc=1; fi
    w=$(wans | tr '\n' ' '); [ -n "$w" ] && echo "INFO   WAN-интерфейсы под защитой: $w" || echo "WARN   WAN-интерфейс не определён: защита IPv4 пуста"
    [ -n "$ROUTE_MARKS" ] && echo "INFO   метки дополнительных маршрутов под защитой: $ROUTE_MARKS"
    if [ "$LEAK_V6" = route ]; then
      if ip -6 rule show 2>/dev/null | grep -q "fwmark $MARK"; then echo "OK     IPv6 через туннель: помеченный IPv6 идёт в таблицу $TABLE (туннель или отказ), в WAN не выпускается"
      else echo "WARN   IPv6 через туннель включён, но правила IPv6 для метки $MARK нет (сторож awg-failover запущен?)"; fi
    fi
    if [ "$V6ON" = 1 ]; then
      if ! command -v ip6tables >/dev/null; then echo "INFO   ip6tables нет: защита IPv6 недоступна"
      elif ip6tables -S FORWARD 2>/dev/null | grep '^-A' | head -n1 | grep -q -- "-j $CF"; then echo "OK     IPv6: помеченный трафик и IPv6 клиентов VPN-сервера в WAN не выпускаются"
      else echo "FAIL   IPv6: цепочка $CF не стоит первой в ip6tables FORWARD"; rc=1; fi
    else echo "INFO   защита IPv6 выключена (LEAK_V6=$LEAK_V6)"; fi
    # IPv6 клиентов LAN под PBR: если у WAN есть IPv6, а UniFi не метит IPv6-трафик этих клиентов, он идёт мимо туннеля
    if ip -6 route show default 2>/dev/null | grep -q . && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
      if ! ip6tables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null | grep -q -- '-j MARK'; then
        echo "WARN   у роутера есть IPv6 в интернет, а правил PBR для IPv6 нет: IPv6-трафик клиентов под PBR может идти мимо туннеля. Отключите IPv6 в сетях с такими клиентами (Settings → Networks → IPv6) или на самих устройствах"
      fi
    fi
  else echo "INFO   защита от утечек выключена (LEAK_GUARD=$LEAK_GUARD)"; fi
  if [ -n "$TUN_DOMAINS" ]; then
    if iptables -t mangle -S PREROUTING 2>/dev/null | grep '^-A' | head -n1 | grep -q -- "-j $CD"; then echo "OK     домены через туннель ($TUN_DOMAINS): правило стоит первым в mangle PREROUTING"
    else echo "FAIL   правило доменов не стоит первым в mangle PREROUTING"; rc=1; fi
    ipset list -n 2>/dev/null | grep -qx $DOMSET && echo "OK     набор $DOMSET: адресов $(ipset list $DOMSET 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | grep -c .) (наполняется по мере DNS-запросов клиентов)" || { echo "FAIL   набора $DOMSET нет"; rc=1; }
    echo "INFO   клиенты: ${TUN_CLIENTS:-вся LAN (br+)}"
  fi
  if [ -n "$DIRECT_DOMAINS$DIRECT_SUBNETS" ]; then
    if iptables -t mangle -S PREROUTING 2>/dev/null | grep '^-A' | tail -n1 | grep -q -- "-j $CX"; then echo "OK     исключения ($DIRECT_DOMAINS $DIRECT_SUBNETS): правило стоит последним в mangle PREROUTING (после PBR UniFi)"
    else echo "FAIL   правило исключений не стоит последним в mangle PREROUTING"; rc=1; fi
  fi
  return $rc
}

case "${1:-run}" in
  run)    trap 'exit 0' TERM INT; while :; do apply; sleep 5 & wait $!; done;;
  apply)  rm -f "$HASHF"; apply;;      # ручной запуск всегда пересобирает цепочки
  remove) remove;;
  check)  check;;
  status) for t in "filter FORWARD $CF" "mangle PREROUTING $CD" "mangle PREROUTING $CX"; do set -- $t; echo "-- iptables -t $1 $3"; iptables -t "$1" -S "$3" 2>/dev/null; done; echo "-- ip6tables filter $CF"; ip6tables -S $CF 2>/dev/null;;
  *)      echo "использование: $0 [run|apply|remove|check|status]"; exit 1;;
esac
