#!/bin/bash
# subnets.sh (служба awg-subnets): подсети VPN-сервера роутера (WireGuard Server, Teleport и т.п.) целиком идут через AWG-туннель.
#   subnets.sh run      служба: каждые 5 с сверяет правила
#   subnets.sh apply    один проход
#   subnets.sh remove   убрать все правила и маршруты этой службы
#   subnets.sh check    проверка: OK / WARN / FAIL
#   subnets.sh status   правила и таблица PBR
# Для каждой подсети из EXTRA_SUBNETS (awg.env):
#   1) ip rule from <подсеть> lookup main suppress_prefixlength 0  (приоритет 6100): роутер, LAN и другие VPN-подсети остаются локальными;
#   2) ip rule from <подсеть> lookup <ТАБЛИЦА PBR>                 (приоритет 6101): остальное (интернет) — в таблицу PBR, где маршрут сторожа на туннель;
#   3) маршрут <подсеть> dev <интерфейс VPN-сервера> в таблице PBR: устройства LAN под PBR по-прежнему достают клиентов VPN-сервера.
# NAT на туннеле делает сторож. UniFi при перепровижнинге может стереть правила, поэтому служба сверяет их каждые 5 секунд.
iptables(){ command iptables -w 10 "$@"; }
DD=${DD:-/data/awg}
P_LOCAL=${SUBNET_PRIO_LOCAL:-6100}
P_PBR=${SUBNET_PRIO_PBR:-6101}
load(){ EXTRA_SUBNETS=""; TABLE=""; [ -r "$DD/awg.env" ] && . "$DD/awg.env"; }
sub_iface(){ ip -4 route show table all to "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
probe_host(){ local a b c d; IFS=. read -r a b c d <<< "${1%/*}"; d=$((d+2)); [ "$d" -gt 254 ] && d=$((d-3)); echo "$a.$b.$c.$d"; }
has_rule(){ ip -4 rule show | grep -q -E "^$1:[[:space:]]+from $2 lookup $3( |\$)"; }   # has_rule ПРИОРИТЕТ ПОДСЕТЬ ТАБЛИЦА

cleanup(){  # убрать правила для подсетей не из списка и правила, ведущие не в текущую таблицу; лишние копии тоже
  local p src tbl keep s n
  ip -4 rule show | awk -v a="$P_LOCAL:" -v b="$P_PBR:" '$1==a || $1==b {print $1, $3, $5}' | sort | uniq -c | while read -r n p src tbl; do
    keep=0
    for s in $EXTRA_SUBNETS; do [ "$s" = "$src" ] && keep=1; done
    [ "$p" = "$P_PBR:" ] && [ "${tbl%%.*}" != "$TABLE" ] && keep=0
    if [ $keep = 0 ]; then
      while ip -4 rule del from "$src" priority "${p%:}" 2>/dev/null; do :; done
      [ "$p" = "$P_PBR:" ] && ip -4 route del "$src" table "$TABLE" 2>/dev/null
    elif [ "$n" -gt 1 ]; then
      for ((; n>1; n--)); do ip -4 rule del from "$src" priority "${p%:}" 2>/dev/null; done
    fi
  done
}
# Проход повторяется каждые 5 с: одно чтение правил и таблицы за проход, разбор — средствами bash; изменения — только если нужны
rule_in(){  # rule_in СНИМОК ПРИОРИТЕТ ПОДСЕТЬ ТАБЛИЦА(main | номер) — правило есть
  local l
  while IFS= read -r l; do
    [[ $l =~ ^"$2:"[[:space:]]+"from $3 lookup "([^ ]+) ]] || continue
    if [ "$4" = main ]; then [ "${BASH_REMATCH[1]}" = main ] && return 0
    else [ "${BASH_REMATCH[1]%%.*}" = "$4" ] && return 0; fi
  done <<< "$1"
  return 1
}
cleanup_from(){  # как cleanup, по снимку правил; ip rule del — только если есть что убирать
  local l p src tbl key keep s n; local -A cnt=()
  while IFS= read -r l; do
    read -r p _ src _ tbl _ <<< "$l"
    [ "$p" = "$P_LOCAL:" ] || [ "$p" = "$P_PBR:" ] || continue
    cnt["$p $src $tbl"]=$(( ${cnt["$p $src $tbl"]:-0} + 1 ))
  done <<< "$1"
  for key in "${!cnt[@]}"; do
    read -r p src tbl <<< "$key"; n=${cnt[$key]}
    keep=0
    for s in $EXTRA_SUBNETS; do [ "$s" = "$src" ] && keep=1; done
    [ "$p" = "$P_PBR:" ] && [ "${tbl%%.*}" != "$TABLE" ] && keep=0
    if [ $keep = 0 ]; then
      while ip -4 rule del from "$src" priority "${p%:}" 2>/dev/null; do :; done
      [ "$p" = "$P_PBR:" ] && ip -4 route del "$src" table "$TABLE" 2>/dev/null
    elif [ "$n" -gt 1 ]; then
      for ((; n>1; n--)); do ip -4 rule del from "$src" priority "${p%:}" 2>/dev/null; done
    fi
  done
}
apply_body(){
  load
  [ -n "$TABLE" ] && [ "$TABLE" != 0 ] || return 0
  local R RT s i o
  R=$(ip -4 rule show 2>/dev/null) || return 0
  cleanup_from "$R"
  [ -n "$EXTRA_SUBNETS" ] || return 0
  RT=$(ip -4 route show table "$TABLE" 2>/dev/null)
  for s in $EXTRA_SUBNETS; do
    rule_in "$R" "$P_LOCAL" "$s" main || ip -4 rule add from "$s" lookup main suppress_prefixlength 0 priority "$P_LOCAL" 2>/dev/null
    rule_in "$R" "$P_PBR" "$s" "$TABLE" || ip -4 rule add from "$s" lookup "$TABLE" priority "$P_PBR" 2>/dev/null
    o=$(ip -4 route show table all to "$s" 2>/dev/null); i=""
    [[ $o =~ (^|[[:space:]])dev[[:space:]]+([^[:space:]]+) ]] && i=${BASH_REMATCH[2]}
    [ -n "$i" ] && [[ $'\n'$RT == *$'\n'"$s dev $i "* ]] && continue
    [ -n "$i" ] && ip -4 route replace "$s" dev "$i" table "$TABLE" 2>/dev/null
  done
  return 0
}
apply(){  # один проход за раз (служба и ручной запуск не мешают друг другу)
  if command -v flock >/dev/null; then ( flock -w 30 9 || exit 0; apply_body ) 9>"${AWG_RUN:-/run}/awg-subnets.lock"; else apply_body; fi
  return 0
}
check(){
  load
  local s i h out dev rc=0 n
  [ -n "$EXTRA_SUBNETS" ] || { echo "INFO   подсети не заданы"; return 0; }
  for s in $EXTRA_SUBNETS; do
    n=$(ip -4 rule show | grep -c -E "^$P_LOCAL:[[:space:]]+from $s lookup main")
    if [ "$n" -ge 1 ]; then echo "OK     $s: локальные адреса остаются локальными (правило $P_LOCAL)"
    else echo "FAIL   $s: нет правила $P_LOCAL (служба awg-subnets запущена?)"; rc=1; fi
    [ "$n" -gt 1 ] && echo "WARN   $s: правил $P_LOCAL — $n (служба уберёт лишние)"
    if has_rule "$P_PBR" "$s" "${TABLE}[^ ]*"; then echo "OK     $s: интернет-трафик отправляется в таблицу PBR $TABLE (правило $P_PBR)"
    else echo "FAIL   $s: нет правила $P_PBR в таблицу $TABLE"; rc=1; fi
    i=$(sub_iface "$s")
    [ -n "$i" ] || echo "WARN   $s: сейчас нет интерфейса с этой подсетью (VPN-сервер выключен?)"
    h=$(probe_host "$s")
    out=$(ip -4 route get 1.1.1.1 from "$h" ${i:+iif $i} 2>&1 | head -n 1)
    dev=$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$dev" in
      awg*) echo "OK     $s: интернет через $dev"
            iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $dev -j MASQUERADE" || { echo "FAIL   нет NAT MASQUERADE на $dev (сторож не запущен?)"; rc=1; } ;;
      "")   if echo "$out" | grep -qiE 'unreachable|prohibit|blackhole'; then echo "OK     $s: туннели сейчас недоступны, трафик блокируется (без утечки в WAN)"
            else echo "WARN   $s: маршрут не определён (${out:-нет ответа})"; fi ;;
      *)    echo "FAIL   $s: интернет идёт через «$dev», а не через awg-туннель (сторож awg-failover ещё не положил маршрут?)"; rc=1 ;;
    esac
  done
  return $rc
}
case "${1:-run}" in
  run)    trap 'exit 0' TERM INT; exec {SLEEPFD}<> <(:); while :; do apply; read -r -t 5 -u "$SLEEPFD" _ 2>/dev/null; done;;
  apply)  apply;;
  remove) load; EXTRA_SUBNETS=""; cleanup;;
  check)  check;;
  status) load; ip -4 rule show | grep -E "^($P_LOCAL|$P_PBR):"; echo "-- таблица $TABLE:"; ip -4 route show table "$TABLE";;
  *)      echo "использование: $0 [run|apply|remove|check|status]"; exit 1;;
esac
