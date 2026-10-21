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
#  4) Списки и GeoIP (#38, LISTS_MODE): blocked — устройства под PBR идут через туннель только к адресам из списков
#     заблокированного (набор AWG_LIST), geoip — напрямую к адресам стран GEO_COUNTRIES (набор AWG_GEO). Наборы
#     наполняет lists.sh; служба раз в час проверяет, не пора ли обновить (раз в сутки).
#  5) DNS устройств (#39, DNS_INTERCEPT=yes): запросы клиентов LAN (DNS_CLIENTS, пусто = вся LAN) к чужим DNS-серверам
#     (порт 53) заворачиваются на dnsmasq роутера — домены через туннель, исключения и правила UniFi по доменам видят и
#     такие устройства; с DNS_ALL_TUNNEL=yes роутер спрашивает DNS через туннель. DNS_BLOCK_DOT=yes — ещё отказ DNS-over-TLS
#     (853) и DNS по IPv6 мимо роутера, чтобы устройства перешли на обычный DNS. Правило — последним в nat PREROUTING:
#     фильтр контента UniFi (свой перехват DNS) срабатывает раньше и не обходится.
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
LISTSET=AWG_LIST    # списки заблокированного (#38), наполняет lists.sh
KEEPSET=AWG_KEEP    # list:set — что остаётся в туннеле при списках/GeoIP: наборы маршрутов UniFi по доменам и адресам + AWG_DOM
GEOSET=AWG_GEO      # адреса стран GEO_COUNTRIES (#38)
CN=AWG_DNS_PRE      # nat PREROUTING, в конец: перехват DNS клиентов (#39)
CQ=AWG_DNS_FWD      # filter FORWARD, сразу после $CF: отказ DoT и DNS по IPv6 мимо роутера (#39)
HASHF=/tmp/awg-guard.hash
WANS_TTL=${WANS_TTL:-30}   # WAN и интерфейсы подсетей VPN-сервера пересматриваются раз в столько секунд, не каждый проход
# Проход повторяется каждые 5 с, поэтому в обычном проходе (ничего не менялось) — без лишних процессов: настройки и
# метки маршрутов читает сам bash, сверка — по одному снимку FORWARD/PREROUTING, время — printf %(%s)T.
epoch(){ printf -v "$1" '%(%s)T' -1; }

load(){
  TABLE=""; MARK=""; WANIF=""
  LEAK_GUARD=yes; LEAK_V6=block; TUN_DOMAINS=""; TUN_CLIENTS=""; DIRECT_DOMAINS=""; DIRECT_SUBNETS=""; EXTRA_SUBNETS=""; LISTS_MODE=off; GEO_COUNTRIES=""
  DNS_INTERCEPT=no; DNS_CLIENTS=""; DNS_BLOCK_DOT=no
  [ -r "$DD/awg.env" ] && . "$DD/awg.env"
  MASK=${MARK#*/}; [ "$MASK" = "$MARK" ] && MASK=0xffffffff
  ROUTE_MARKS=""
  local f l
  for f in "$DD"/route.d/*.env; do
    [ -r "$f" ] || continue
    while IFS= read -r l || [ -n "$l" ]; do
      [[ $l =~ ^MARK=\"?([0-9a-fx/]+)\"?$ ]] && [[ " $ROUTE_MARKS" != *" ${BASH_REMATCH[1]} "* ]] && ROUTE_MARKS+="${BASH_REMATCH[1]} "
    done < "$f"
  done
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
wans_cached(){  # → W (WAN через пробел) и SUBIF (интерфейсы подсетей VPN-сервера); пересчёт раз в WANS_TTL секунд
  local now ts="" l
  epoch now
  { read -r ts < "$WANF.ts"; } 2>/dev/null
  if [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt "$WANS_TTL" ] && [ -f "$WANF" ]; then
    W=""; while IFS= read -r l; do [ -n "$l" ] && W+="$l "; done < "$WANF"
    SUBIF=""; { IFS= read -r SUBIF < "$WANF.sub"; } 2>/dev/null   # IFS= — с тем же пробелом в конце, что при пересчёте: иначе отпечаток другой и цепочки пересобирались каждые 30 с
    return 0
  fi
  W=$(wans | tr '\n' ' ')
  SUBIF=$(for l in $EXTRA_SUBNETS; do sub_iface "$l"; done | tr '\n' ' ')
  printf '%s\n' "$SUBIF" > "$WANF.sub"; printf '%s\n' "$now" > "$WANF.ts"
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
jump_at(){  # jump_at first|last|N СНИМОК родитель цепочка → 0, если переход ровно один и на своём месте
  local pos=$1 o=$2 par=$3 ch=$4 l k=0 n=0 at="" want="-A $3 -j $4"
  while IFS= read -r l; do
    [[ $l == "-A "* ]] || continue
    k=$((k + 1))
    [ "$l" = "$want" ] && n=$((n + 1))
    case "$pos" in first) [ $k = 1 ] && at=$l;; last) at=$l;; *) [ "$k" = "$pos" ] && at=$l;; esac
  done <<< "$o"
  [ "$n" = 1 ] && [ "$at" = "$want" ]
}
jump_place(){ # jump_place first|last|N команда таблица родитель цепочка [снимок родителя]
  local pos=$1 cmd=$2 t=$3 par=$4 ch=$5 o n k l
  if [ $# -ge 6 ]; then o=$6; else o=$($cmd -t "$t" -S "$par" 2>/dev/null) || return 0; fi
  jump_at "$pos" "$o" "$par" "$ch" && return 0
  n=0; while IFS= read -r l; do [ "$l" = "-A $par -j $ch" ] && n=$((n + 1)); done <<< "$o"
  for ((k=0; k<n; k++)); do $cmd -t "$t" -D "$par" -j "$ch" 2>/dev/null || return 0; done
  case "$pos" in
    first) $cmd -t "$t" -I "$par" 1 -j "$ch" 2>/dev/null;;
    last) $cmd -t "$t" -A "$par" -j "$ch" 2>/dev/null;;
    *) $cmd -t "$t" -I "$par" "$pos" -j "$ch" 2>/dev/null || $cmd -t "$t" -A "$par" -j "$ch" 2>/dev/null;;
  esac
}
jump_first(){ jump_place first "$@"; }
jump_last(){ jump_place last "$@"; }
jump_nth(){ jump_place "$@"; }   # jump_nth N команда таблица родитель цепочка [снимок] — переход ровно один и N-м правилом
BERR=0
# команда сборки цепочки; код 4 = блокировка xtables не освободилась: цепочки соберём заново через 5 с
B(){ "$@" 2>/dev/null; [ $? -eq 4 ] && BERR=1; return 0; }

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
      # вся LAN и клиенты VPN-сервера роутера (WireGuard-сервер UniFi — wgsrv*, а также EXTRA_SUBNETS)
      B iptables -t mangle -A $CD -i br+ -m set --match-set $DOMSET dst -j MARK --set-xmark "$MARK"
      B iptables -t mangle -A $CD -i wgsrv+ -m set --match-set $DOMSET dst -j MARK --set-xmark "$MARK"
      for c in $EXTRA_SUBNETS; do B iptables -t mangle -A $CD -s "$c" -m set --match-set $DOMSET dst -j MARK --set-xmark "$MARK"; done
    fi
  fi
  jump_first iptables mangle PREROUTING $CD
}

dns_src(){  # источники для перехвата DNS: адреса из DNS_CLIENTS или вся LAN (br+)
  local c
  if [ -n "$DNS_CLIENTS" ]; then for c in $DNS_CLIENTS; do echo "-s $c"; done; else echo "-i br+"; fi
}
fwd_pos(){ [ "$LEAK_GUARD" = yes ] && echo 2 || echo 1; }   # $CQ — сразу после $CF
build_dns(){
  local a p
  if [ "$DNS_INTERCEPT" != yes ]; then
    rm_chain iptables nat PREROUTING $CN; rm_chain iptables filter FORWARD $CQ; rm_chain ip6tables filter FORWARD $CQ; return 0
  fi
  iptables -t nat -N $CN 2>/dev/null; B iptables -t nat -F $CN
  while read -r a; do
    # shellcheck disable=SC2086
    for p in udp tcp; do B iptables -t nat -A $CN $a -p $p --dport 53 -m addrtype ! --dst-type LOCAL -j REDIRECT --to-ports 53; done
  done < <(dns_src)
  jump_last iptables nat PREROUTING $CN
  if [ "$DNS_BLOCK_DOT" = yes ]; then
    iptables -t filter -N $CQ 2>/dev/null; B iptables -t filter -F $CQ
    while read -r a; do
      # shellcheck disable=SC2086
      { B iptables -t filter -A $CQ $a -p tcp --dport 853 -j REJECT --reject-with tcp-reset
        B iptables -t filter -A $CQ $a -p udp --dport 853 -j REJECT --reject-with icmp-port-unreachable; }
    done < <(dns_src)
    jump_nth "$(fwd_pos)" iptables filter FORWARD $CQ
    # IPv6: у перехвата нет NAT66 — чужие DNS и DoT по IPv6 отклоняются (для всей LAN: IPv6-адреса клиентов из DNS_CLIENTS неизвестны)
    if command -v ip6tables >/dev/null && [ -z "$DNS_CLIENTS" ]; then
      ip6tables -t filter -N $CQ 2>/dev/null; B ip6tables -t filter -F $CQ
      for p in udp tcp; do
        B ip6tables -t filter -A $CQ -i br+ -p $p --dport 53 -j REJECT --reject-with icmp6-adm-prohibited
        B ip6tables -t filter -A $CQ -i br+ -p $p --dport 853 -j REJECT --reject-with icmp6-adm-prohibited
      done
      jump_nth "$( [ "$LEAK_GUARD" = yes ] && [ "$V6ON" = 1 ] && echo 2 || echo 1)" ip6tables filter FORWARD $CQ
    else rm_chain ip6tables filter FORWARD $CQ; fi
  else rm_chain iptables filter FORWARD $CQ; rm_chain ip6tables filter FORWARD $CQ; fi
}

list_n(){  # list_n ПЕРЕМЕННАЯ НАБОР — число адресов (только заголовок набора, без перечисления адресов)
  local o; o=$(ipset list -t "$2" 2>/dev/null)
  if [[ $o =~ Number\ of\ entries:\ ([0-9]+) ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" 0; fi
}
# Явные маршруты UniFi по доменам и адресам (и «Домены через туннель») — намерение «этот сервис через туннель». Списки и
# GeoIP их не отменяют: иначе домен из маршрута UniFi, ответивший российским адресом (кэш YouTube у провайдера),
# уходил напрямую. Наборы назначения правил UBIOS_PREROUTING_PBR с нашими метками (UBIOS_trafficroute_dn_1 — это
# list:set, вложить его нельзя, берём его IPv4-часть UBIOS4trafficroute_dn_1) собираются в list:set AWG_KEEP.
# Маршруты UniFi меняются редко: сверка раз в 60 с (или сразу после пересборки цепочки), подмена набора — swap.
KEEPF=${AWG_RUN:-/run}/awg-guard.keep
sync_keep(){  # sync_keep [force]
  local now ts="" o l w prev names="" cur="" n
  local -A seen=() mine=()
  epoch now
  { read -r ts < "$KEEPF.ts"; } 2>/dev/null
  [ "${1:-}" != force ] && [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt 60 ] && return 0
  o=$(iptables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null) || o=""
  printf '%s\n' "$now" > "$KEEPF.ts"
  # метка правила с Kill Switch — 0x6b0000/0x7f0000: сравниваем под нашей маской (без флага 0x10000)
  for n in $MARK $ROUTE_MARKS; do mine[$((${n%/*} & ~KS))]=1; done
  while IFS= read -r l; do
    [[ $l == *" -j MARK --set-xmark "* ]] || continue
    w=${l##* --set-xmark }
    [[ $w =~ ^0x[0-9a-fA-F]+/0x[0-9a-fA-F]+$ ]] || continue
    [ -n "${mine[$(( ${w%/*} & ~KS ))]:-}" ] || continue
    prev=""
    for w in $l; do
      if [ "$w" = dst ] && [[ $prev == UBIOS_* ]] && [[ $prev != UBIOS_local_network* ]] && [[ " $l" != *" ! --match-set $prev dst"* ]]; then
        n=UBIOS4${prev#UBIOS_}; [ -n "${seen[$n]:-}" ] || { seen[$n]=1; names+=" $n"; }
      fi
      prev=$w
    done
  done <<< "$o"
  [ -n "$TUN_DOMAINS" ] && names+=" $DOMSET"
  { IFS= read -r cur < "$KEEPF"; } 2>/dev/null
  [ "$cur" = "$names" ] && ipset list -n $KEEPSET >/dev/null 2>&1 && return 0
  o=$(ipset list -n 2>/dev/null)
  {
    echo "create $KEEPSET.new list:set size 256"
    for n in $names; do [[ $'\n'$o$'\n' == *$'\n'$n$'\n'* ]] && echo "add $KEEPSET.new $n"; done
  } > "$KEEPF.r"
  ipset destroy $KEEPSET.new 2>/dev/null
  ipset create $KEEPSET list:set size 256 -exist 2>/dev/null
  if ipset restore < "$KEEPF.r" 2>/dev/null && ipset swap $KEEPSET.new $KEEPSET 2>/dev/null; then
    printf '%s\n' "$names" > "$KEEPF"
  else rm -f "$KEEPF"; fi
  ipset destroy $KEEPSET.new 2>/dev/null; rm -f "$KEEPF.r"
  return 0
}
# Флаг kill switch UniFi (0x10000): маршрут с включённым Kill Switch ставит метку туннеля вместе с ним (0x6b0000/0x7f0000),
# а правило ip «fwmark 0x10000/0x10000 → blackhole» ловит всё, что осталось с флагом. Снимая метку туннеля (исключения,
# списки, GeoIP), снимаем и флаг — иначе «напрямую» превращалось в blackhole.
KS=0x10000
build_direct(){
  local n m mk mks mv mks2 mask2
  iptables -t mangle -N $CX 2>/dev/null; B iptables -t mangle -F $CX
  [ "$LISTS_MODE" != off ] && ipset create $KEEPSET list:set size 256 -exist 2>/dev/null
  if [ -n "$MARK" ]; then
    printf -v mask2 '0x%x' $(( MASK | KS ))
    # Kill Switch UniFi в маршруте на наш профиль-«рельсу» — лишний (при падении туннелей трафик маршрута блокирует
    # сторож: blackhole в таблице маршрута и запрет выхода помеченного в WAN) и ломает DNS: UniFi отбрасывает DNS к
    # роутеру с флагом 0x10000, ждёт DNS-сервер VPN-клиента (у «рельсы» его нет), а ответы фильтра контента
    # (127.0.0.1:1053) на соединения с флагом в метке соединения не доходили — ERR_NAME_NOT_RESOLVED у всей сети.
    # Снимаем флаг с пакета и с метки соединения: метки становятся такими же, как у маршрута с выключенным Kill Switch
    # (с ним DNS на роутере работает). Правила — первыми в этой цепочке, она последняя в mangle PREROUTING.
    for m in $MARK $ROUTE_MARKS; do
      mv=${m%/*}; mk=${m#*/}; [ "$mk" = "$m" ] && mk=0xffffffff
      printf -v mks '0x%x/0x%x' $(( mv | KS )) $(( mk | KS ))
      B iptables -t mangle -A $CX -m mark --mark "$mks" -j CONNMARK --set-xmark "0x0/$KS"
      B iptables -t mangle -A $CX -m mark --mark "$mks" -j MARK --set-xmark "0x0/$KS"
    done
    for n in $DIRECT_SUBNETS; do B iptables -t mangle -A $CX -d "$n" -j MARK --set-xmark "0x0/$mask2"; done
    [ -n "$DIRECT_DOMAINS" ] && B iptables -t mangle -A $CX -m set --match-set $DIRSET dst -j MARK --set-xmark "0x0/$mask2"
    # списки и GeoIP (#38) — для меток основного и дополнительных маршрутов; пустой набор — правила нет (всё через туннель)
    for m in $MARK $ROUTE_MARKS; do
      mk=${m#*/}; [ "$mk" = "$m" ] && mk=0xffffffff
      printf -v mks2 '0x%x' $(( mk | KS ))
      # AWG_KEEP: маршруты UniFi по доменам/адресам и «Домены через туннель» остаются в туннеле при любом режиме
      if [ "$LISTS_MODE" = geoip ] && [ "${GEON:-0}" -gt 0 ]; then
        B iptables -t mangle -A $CX -m mark --mark "$m" -m set --match-set $GEOSET dst -m set ! --match-set $KEEPSET dst -j MARK --set-xmark "0x0/$mks2"
      elif [ "$LISTS_MODE" = blocked ] && [ "${LISTN:-0}" -gt 0 ]; then
        B iptables -t mangle -A $CX -m mark --mark "$m" -m set ! --match-set $LISTSET dst -m set ! --match-set $KEEPSET dst -j MARK --set-xmark "0x0/$mks2"
      fi
    done
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
  local W SUBIF h old="" o mpre fwd="" fwd6="" npre="" need=0 v6c=0
  BERR=0
  wans_cached
  LISTN=0; GEON=0
  if [ "$LISTS_MODE" != off ] && [ -x "$DD/lists.sh" ]; then
    o=$(ipset list -n 2>/dev/null)
    [[ $'\n'$o$'\n' == *$'\n'$LISTSET$'\n'* ]] || "$DD/lists.sh" load >/dev/null 2>&1   # после загрузки роутера — из кэша
    list_n LISTN $LISTSET; list_n GEON $GEOSET
  fi
  local hl="" hg=""; [ "$LISTN" -gt 0 ] && hl=L; [ "$GEON" -gt 0 ] && hg=G   # без $( ): каждая подстановка — fork
  printf -v h 'g11|%s|%s|%s%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$DNS_INTERCEPT $DNS_BLOCK_DOT $DNS_CLIENTS" "$LISTS_MODE" \
    "$hl" "$hg" "$MARK" "$ROUTE_MARKS" "$W" "$LEAK_GUARD" "$LEAK_V6" \
    "$TUN_DOMAINS" "$TUN_CLIENTS" "$DIRECT_DOMAINS" "$DIRECT_SUBNETS" "$EXTRA_SUBNETS" "$SUBIF"
  { IFS= read -r old < "$HASHF"; } 2>/dev/null   # IFS= — отпечаток может кончаться пробелом (интерфейсы подсетей): без него «изменился» каждый проход
  # по одному снимку родительских цепочек на проход; не прочитался (блокировка xtables) — в следующий проход
  mpre=$(iptables -t mangle -S PREROUTING 2>/dev/null) || return 0
  if [ "$LEAK_GUARD" = yes ] || [ "$DNS_BLOCK_DOT" = yes ]; then fwd=$(iptables -S FORWARD 2>/dev/null) || return 0; fi
  command -v ip6tables >/dev/null && { { [ "$LEAK_GUARD" = yes ] && [ "$V6ON" = 1 ]; } || { [ "$DNS_BLOCK_DOT" = yes ] && [ -z "$DNS_CLIENTS" ]; }; } && v6c=1
  if [ $v6c = 1 ]; then fwd6=$(ip6tables -S FORWARD 2>/dev/null) || return 0; fi
  if [ "$DNS_INTERCEPT" = yes ]; then npre=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 0; fi
  # переходы в наши цепочки на месте — значит, и цепочки на месте (UniFi при перепровижнинге удаляет их вместе)
  has(){ [[ $'\n'$1$'\n' == *$'\n'"$2"$'\n'* ]]; }
  has "$mpre" "-A PREROUTING -j $CD" && has "$mpre" "-A PREROUTING -j $CX" || need=1
  [ "$LEAK_GUARD" = yes ] && ! has "$fwd" "-A FORWARD -j $CF" && need=1
  [ "$LEAK_GUARD" = yes ] && [ "$V6ON" = 1 ] && [ $v6c = 1 ] && ! has "$fwd6" "-A FORWARD -j $CF" && need=1
  if [ "$DNS_INTERCEPT" = yes ]; then
    has "$npre" "-A PREROUTING -j $CN" || need=1
    [ "$DNS_BLOCK_DOT" = yes ] && ! has "$fwd" "-A FORWARD -j $CQ" && need=1
  fi
  if [ "$old" != "$h" ] || [ $need = 1 ]; then
    [ -n "$TUN_DOMAINS" ] && { ipset create $DOMSET hash:ip family inet timeout 43200 -exist 2>/dev/null; ipset create ${DOMSET}6 hash:ip family inet6 timeout 43200 -exist 2>/dev/null; }
    [ -n "$DIRECT_DOMAINS" ] && ipset create $DIRSET hash:ip family inet timeout 43200 -exist 2>/dev/null
    if [ "$LEAK_GUARD" = yes ]; then build_leak "$W"; else rm_chain iptables filter FORWARD $CF; rm_chain ip6tables filter FORWARD $CF; fi
    build_dom
    build_direct
    build_dns
    [ "$LISTS_MODE" != off ] && sync_keep force
    if [ "$BERR" = 0 ]; then printf '%s\n' "$h" > $HASHF; else rm -f $HASHF; fi   # не всё применилось — повторим через 5 с
    # цепочки только что собраны: места переходов сверяем по свежим снимкам
    mpre=$(iptables -t mangle -S PREROUTING 2>/dev/null) || return 0
    [ -n "$fwd" ] && { fwd=$(iptables -S FORWARD 2>/dev/null) || return 0; }
    [ $v6c = 1 ] && { fwd6=$(ip6tables -S FORWARD 2>/dev/null) || return 0; }
    [ -n "$npre" ] && { npre=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 0; }
  fi
  { [ "$GEON" -gt 0 ] || [ "$LISTN" -gt 0 ]; } && sync_keep
  # порядок переходов относительно UniFi проверяем каждый проход (UniFi может переставить свои); всё на месте — без iptables
  [ "$LEAK_GUARD" = yes ] && { jump_first iptables filter FORWARD $CF "$fwd"; [ "$V6ON" = 1 ] && [ $v6c = 1 ] && jump_first ip6tables filter FORWARD $CF "$fwd6"; }
  jump_first iptables mangle PREROUTING $CD "$mpre"
  jump_last iptables mangle PREROUTING $CX "$mpre"
  if [ "$DNS_INTERCEPT" = yes ]; then
    jump_last iptables nat PREROUTING $CN "$npre"
    if [ "$DNS_BLOCK_DOT" = yes ]; then
      jump_nth "$(fwd_pos)" iptables filter FORWARD $CQ "$fwd"
      [ $v6c = 1 ] && [ -z "$DNS_CLIENTS" ] && jump_nth "$( [ "$LEAK_GUARD" = yes ] && [ "$V6ON" = 1 ] && echo 2 || echo 1)" ip6tables filter FORWARD $CQ "$fwd6"
    fi
  fi
  return 0
}

remove(){
  load
  rm_chain iptables filter FORWARD $CF; rm_chain ip6tables filter FORWARD $CF
  rm_chain iptables mangle PREROUTING $CD; rm_chain iptables mangle PREROUTING $CX
  ipset destroy $DOMSET 2>/dev/null; ipset destroy ${DOMSET}6 2>/dev/null; ipset destroy $DIRSET 2>/dev/null; rm -f "$WANF"
  ipset destroy $LISTSET 2>/dev/null; ipset destroy $GEOSET 2>/dev/null; ipset destroy $KEEPSET 2>/dev/null; rm -f "$KEEPF" "$KEEPF.ts"
  rm_chain iptables nat PREROUTING $CN; rm_chain iptables filter FORWARD $CQ; rm_chain ip6tables filter FORWARD $CQ
  [ -x "$DD/sec.sh" ] && "$DD/sec.sh" remove >/dev/null 2>&1   # защита входящих живёт, пока её сверяет сторож
  rm -f $HASHF
}

check(){
  load
  local rc=0 w
  [ -n "$MARK" ] || { echo "FAIL   нет MARK в awg.env (запустите awg-detect.sh)"; return 1; }
  # служба не включена — её правил и не должно быть: это не сбой, а выбор (защита — только blackhole в таблице PBR)
  if ! grep -qx awg-guard "$DD/.units" 2>/dev/null && ! systemctl is-active --quiet awg-guard 2>/dev/null; then
    echo "INFO   awg-guard не включён: от утечек защищает только blackhole в таблице PBR (вторая линия — «Маршрутизация → Защита от утечек»)"
    return 0
  fi
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
  if [ "$DNS_INTERCEPT" = yes ]; then
    if iptables -t nat -S PREROUTING 2>/dev/null | grep '^-A' | tail -n1 | grep -q -- "-j $CN"; then
      echo "OK     DNS устройств (${DNS_CLIENTS:-вся LAN}): запросы к чужим DNS-серверам идут на роутер"
    else echo "FAIL   перехват DNS включён, но правила $CN нет последним в nat PREROUTING"; rc=1; fi
    if [ "$DNS_BLOCK_DOT" = yes ]; then
      iptables -S FORWARD 2>/dev/null | grep -q -- "-j $CQ" && echo "OK     DNS-over-TLS (853) и DNS по IPv6 мимо роутера отклоняются" || { echo "FAIL   нет перехода в $CQ в FORWARD"; rc=1; }
    fi
    [ "${DNS_ALL_TUNNEL:-no}" = yes ] && echo "OK     роутер спрашивает DNS через туннель (DNS_ALL_TUNNEL=yes)" \
      || echo "INFO   DNS_ALL_TUNNEL=no: роутер спрашивает DNS мимо туннеля (зашифрованно, если в UniFi включён DNS over HTTPS)"
  fi
  if [ "$LISTS_MODE" != off ]; then
    local ln gn; list_n ln $LISTSET; list_n gn $GEOSET
    case "$LISTS_MODE" in
      blocked) [ "${ln:-0}" -gt 0 ] && echo "OK     списки: через туннель только заблокированное ($ln сетей)" || { echo "WARN   списки: набор $LISTSET пуст — всё под PBR идёт через туннель (lists.sh update)"; };;
      geoip)   [ "${gn:-0}" -gt 0 ] && echo "OK     GeoIP: напрямую $(echo "$GEO_COUNTRIES" | tr 'a-z' 'A-Z') ($gn сетей), остальное через туннель" || { echo "WARN   GeoIP: набор $GEOSET пуст — всё под PBR идёт через туннель (lists.sh update)"; };;
    esac
    [ -x "$DD/lists.sh" ] && [ "$("$DD/lists.sh" full 2>/dev/null)" = 0 ] && \
      echo "WARN   списки: в UniFi нет маршрута PBR «весь интернет» в туннель — режим $LISTS_MODE ни на что не влияет (через туннель идут только домены и адреса из маршрутов UniFi)"
  fi
  if [ -n "$DIRECT_DOMAINS$DIRECT_SUBNETS" ]; then
    if iptables -t mangle -S PREROUTING 2>/dev/null | grep '^-A' | tail -n1 | grep -q -- "-j $CX"; then echo "OK     исключения ($DIRECT_DOMAINS $DIRECT_SUBNETS): правило стоит последним в mangle PREROUTING (после PBR UniFi)"
    else echo "FAIL   правило исключений не стоит последним в mangle PREROUTING"; rc=1; fi
  fi
  return $rc
}

case "${1:-run}" in
  run)    STOP=""; trap 'STOP=1' TERM INT; k=0; exec {SLEEPFD}<> <(:)   # пауза — read -t на канале, в который никто не пишет
          while [ -z "$STOP" ]; do      # сигнал — флажок: выход из обработчика посреди read -t bash может оборвать
            apply
            # списки (#38): раз в час проверить возраст, раз в сутки обновить — в фоне, цепочки не ждут
            if [ $((k % 720)) = 0 ] && [ -x "$DD/lists.sh" ] && "$DD/lists.sh" due; then setsid "$DD/lists.sh" update > "$DD/lists.log" 2>&1 < /dev/null & fi
            # защита входящих (1.10): раз в минуту (первый раз — через 10 с после старта) сверить правила и записать новые блокировки — в фоне
            # (настройки apply читает в подоболочке — здесь их нет: смотрим awg.env сами, раз в минуту — один grep)
            if [ $((k % 12)) = 2 ] && [ -x "$DD/sec.sh" ] && { [ -e "${AWG_RUN:-/run}/awg-sec.hash" ] || grep -qsE '^SEC_PROTECT="?yes' "$DD/awg.env"; }; then setsid "$DD/sec.sh" ensure > /dev/null 2>&1 < /dev/null & fi
            # подписки VLESS (#42): раз в час — те, что старше суток (сдвиг на полчаса от списков)
            if [ $((k % 720)) = 360 ] && [ -s "$DD/xray/vless.json" ]; then setsid python3 "$DD/web/panel.py" vless-refresh --due >> "$DD/xray/vless.log" 2>&1 < /dev/null & fi
            k=$((k + 1)); [ -z "$STOP" ] && read -r -t 5 -u "$SLEEPFD" _ 2>/dev/null
          done; exit 0;;
  apply)  rm -f "$HASHF"; apply;;      # ручной запуск всегда пересобирает цепочки
  remove) remove;;
  check)  check;;
  status) for t in "filter FORWARD $CF" "filter FORWARD $CQ" "mangle PREROUTING $CD" "mangle PREROUTING $CX" "nat PREROUTING $CN"; do set -- $t; echo "-- iptables -t $1 $3"; iptables -t "$1" -S "$3" 2>/dev/null; done; echo "-- ip6tables filter $CF"; ip6tables -S $CF 2>/dev/null;;
  *)      echo "использование: $0 [run|apply|remove|check|status]"; exit 1;;
esac
