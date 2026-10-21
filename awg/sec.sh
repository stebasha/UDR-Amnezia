#!/bin/bash
# sec.sh — защита входящих из интернета (1.10), по желанию (SEC_PROTECT=yes в awg.env). Настройки UniFi не меняет:
# свои цепочки AWG_SEC_IN (INPUT) и AWG_SEC_FWD (FORWARD), первыми и только для пакетов с WAN.
#   sec.sh apply      поставить правила по awg.env (выключено — убрать)
#   sec.sh ensure     для awg-guard: поставить заново, если правила пропали или изменились настройки (дёшево)
#   sec.sh remove     убрать свои правила и наборы
#   sec.sh geo        обновить адреса разрешённых стран (раз в неделю — сам)
#   sec.sh status     что включено, сколько адресов заблокировано
#   sec.sh unban IP   снять блокировку адреса
# Что делает (каждая часть включается отдельно):
#   SEC_GEO_ALLOW="ru" + SEC_GEO_PORTS="8123 44300"  на эти порты WAN (проброс в LAN и службы роутера) — только из
#                        этих стран; остальные отбрасываются. Порт 25 (почта) и 80 (Let's Encrypt) так не ограничивайте.
#   SEC_TRAP=yes         кто стучится на порты-ловушки роутера (SEC_TRAP_PORTS: 23, 3389, 445…; открытые и проброшенные
#                        исключаются сами) — сканер: его адрес блокируется на SEC_BAN_HOURS часов
#   SEC_RATE=30          больше 30 новых соединений в минуту с одного адреса на проброшенные порты — подбор паролей:
#                        блокировка на SEC_BAN_HOURS (0 — выключено)
#   SEC_ALLOW_IPS="…"    адреса и подсети, которые не блокируются никогда (частные сети — всегда)
export LC_ALL=C.UTF-8
iptables(){ command iptables -w 10 "$@"; }
DD=${DD:-/data/awg}
SD=$DD/sec
RUNF=${AWG_RUN:-/run}/awg-sec.hash
umask 077
SEC_PROTECT=no; SEC_GEO_ALLOW=""; SEC_GEO_PORTS=""; SEC_TRAP=yes; SEC_RATE=30; SEC_BAN_HOURS=24; SEC_ALLOW_IPS=""; WANIF=""
SEC_TRAP_PORTS="23 135 139 445 1433 2323 3306 3389 5432 5900 6379 7547 8291 9200 27017"
# shellcheck disable=SC1091
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
CI=AWG_SEC_IN; CF=AWG_SEC_FWD
S_OK=AWG_SEC_OK; S_GEO=AWG_SEC_GEO; S_TRAP=AWG_SEC_TRAP; S_RATE=AWG_SEC_RATE; S_BAN=AWG_SEC_BAN
GEO_MAX_AGE=${SEC_GEO_MAX_AGE:-604800}
GEO_MIN=${SEC_GEO_MIN:-50}           # меньше сетей — не похоже на страну: правило «только из стран» не ставим вовсе

say(){ printf '%s\n' "$*"; }
event(){ echo "$(date +%s)|sec|$1" >> "$DD/events.log"; }
on(){ [ "$SEC_PROTECT" = yes ]; }
nums(){ local x; for x in $1; do [[ $x =~ ^[0-9]{1,5}$ ]] && [ "$x" -ge 1 ] && [ "$x" -le 65535 ] && echo "$x"; done | sort -un; }
ccs(){ local x; for x in $(echo "$SEC_GEO_ALLOW" | tr 'A-Z,' 'a-z '); do [[ $x =~ ^[a-z]{2}$ ]] && echo "$x"; done | sort -u; }
wans(){
  { cat "${AWG_RUN:-/run}/awg-guard.wans" 2>/dev/null; echo "$WANIF"
    ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'; } \
    | grep -v -E '^(awg|wg|lo|wgclt|br|switch|ifb|tun|tlprt|$)' | sort -u
}
members(){ ipset list "$1" 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | awk '{print $1}'; }
open_ports(){  # порты, которые WAN уже принимает: проброс (DNAT), консоль, WireGuard, правила UniFi с портом назначения
  { iptables -t nat -S 2>/dev/null | grep -E -- '-j DNAT' | grep -oE -- '--dport [0-9]+' | awk '{print $2}'
    for s in $(ipset list -n 2>/dev/null | grep -E '^UBIOS_(unifi_console_https_port|wireguard_ports|policy_dst_port_[0-9]+|.*_dst_port.*)$'); do members "$s"; done
  } | grep -E '^[0-9]+$' | sort -un
}
traps(){  # SEC_TRAP_PORTS без открытых: роутер не должен блокировать тех, кто идёт на настоящую службу
  local o p; o=" $(open_ports | tr '\n' ' ') "
  for p in $(nums "$SEC_TRAP_PORTS"); do [[ $o == *" $p "* ]] || echo "$p"; done | head -n 15   # multiport — до 15 портов
}

# ------------------------------------------------------------------ адреса стран
geo_age(){ local t; t=$(cat "$SD/geo.ts" 2>/dev/null); [[ $t =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - t )) || echo -1; }
geo_update(){
  local want; want=$(ccs | tr '\n' ' ')
  [ -n "$want" ] || return 0
  mkdir -p "$SD"; chmod 700 "$SD"
  # shellcheck disable=SC2046
  if bash "$DD/lists.sh" geo-file "$SD/geo.new" $(ccs) && [ "$(wc -l < "$SD/geo.new")" -ge "$GEO_MIN" ]; then
    mv -f "$SD/geo.new" "$SD/geo.cidr"; date +%s > "$SD/geo.ts"; echo "$want" > "$SD/geo.src"
    say "✔ адреса стран $(echo "$want" | tr a-z A-Z): $(wc -l < "$SD/geo.cidr") сетей"
  else
    rm -f "$SD/geo.new"; say "✘ адреса стран не обновились — остаются прежние ($( { wc -l < "$SD/geo.cidr"; } 2>/dev/null || echo 0) сетей)"
    return 1
  fi
}
geo_load(){  # → 0, если набор стран загружен и в нём достаточно сетей
  [ -s "$SD/geo.cidr" ] && [ "$(cat "$SD/geo.src" 2>/dev/null)" = "$(ccs | tr '\n' ' ')" ] || return 1
  [ "$(wc -l < "$SD/geo.cidr")" -ge "$GEO_MIN" ] || return 1
  ipset create $S_GEO hash:net family inet maxelem 262144 -exist 2>/dev/null || return 1
  ipset destroy $S_GEO.new 2>/dev/null
  { echo "create $S_GEO.new hash:net family inet maxelem 262144"; sed "s/^/add $S_GEO.new /" "$SD/geo.cidr"; } | ipset restore 2>/dev/null \
    || { ipset destroy $S_GEO.new 2>/dev/null; return 1; }
  ipset swap $S_GEO.new $S_GEO && ipset destroy $S_GEO.new 2>/dev/null
}

# ------------------------------------------------------------------ правила
sets(){
  local t=$(( ${SEC_BAN_HOURS:-24} * 3600 )) x
  [ "$t" -ge 3600 ] && [ "$t" -le 2592000 ] || t=86400
  ipset create $S_OK hash:net family inet -exist 2>/dev/null
  ipset flush $S_OK 2>/dev/null
  for x in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 $SEC_ALLOW_IPS; do
    [[ $x =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] && ipset add $S_OK "$x" -exist 2>/dev/null
  done
  # адрес VPS и серверов туннелей — тоже свои
  for x in $VPS_IP $(cat "$DD"/.endpoint-* 2>/dev/null | awk '{print $2}') $(cat "$DD"/xray/*.server 2>/dev/null); do
    [[ $x =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ipset add $S_OK "$x" -exist 2>/dev/null
  done
  # с ловушек и за частоту — разные наборы (видно, за что), проверка — одна (list:set); counters — сколько пакетов отброшено
  ipset create $S_TRAP hash:ip family inet timeout "$t" counters maxelem 65536 -exist 2>/dev/null
  ipset create $S_RATE hash:ip family inet timeout "$t" counters maxelem 65536 -exist 2>/dev/null
  ipset create $S_BAN list:set -exist 2>/dev/null
  ipset add $S_BAN $S_TRAP -exist 2>/dev/null; ipset add $S_BAN $S_RATE -exist 2>/dev/null
}
rules_in(){  # правила цепочки INPUT (служба роутера на WAN)
  local tp p
  echo "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  echo "-m set --match-set $S_OK src -j RETURN"
  echo "-m set --match-set $S_BAN src -j DROP"
  if [ "$SEC_TRAP" = yes ]; then
    tp=$(traps | paste -sd, -)
    if [ -n "$tp" ]; then
      echo "-p tcp -m multiport --dports $tp -j SET --add-set $S_TRAP src --exist"
      echo "-p tcp -m multiport --dports $tp -j DROP"
    fi
  fi
  if [ "$GEO_OK" = 1 ]; then
    for p in $(nums "$SEC_GEO_PORTS"); do
      echo "-p tcp -m tcp --dport $p -m set ! --match-set $S_GEO src -j DROP"
      echo "-p udp -m udp --dport $p -m set ! --match-set $S_GEO src -j DROP"
    done
  fi
  echo "-j RETURN"
}
rules_fwd(){  # FORWARD: проброшенные порты (адрес назначения уже заменён — порт WAN берём из conntrack)
  local p r=${SEC_RATE:-0}
  echo "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  echo "-m set --match-set $S_OK src -j RETURN"
  echo "-m set --match-set $S_BAN src -j DROP"
  if [ "$GEO_OK" = 1 ]; then
    for p in $(nums "$SEC_GEO_PORTS"); do
      echo "-m conntrack --ctstate DNAT --ctorigdstport $p -m set ! --match-set $S_GEO src -j DROP"
    done
  fi
  if [[ $r =~ ^[0-9]+$ ]] && [ "$r" -gt 0 ]; then
    echo "-m conntrack --ctstate DNAT -m hashlimit --hashlimit-above $r/min --hashlimit-burst $r --hashlimit-mode srcip --hashlimit-name awgsec -j SET --add-set $S_RATE src --exist"
    echo "-m set --match-set $S_RATE src -j DROP"
  fi
  echo "-j RETURN"
}
fill(){  # fill ЦЕПОЧКА ФУНКЦИЯ — цепочку заново на месте: переходы в неё из INPUT/FORWARD не трогаются
  local c=$1 f=$2 r
  iptables -N "$c" 2>/dev/null || iptables -F "$c"
  while IFS= read -r r; do
    # shellcheck disable=SC2086
    iptables -A "$c" $r || say "✘ правило не принято: $r"
  done < <("$f")
}
HOOKS=("INPUT $CI" "FORWARD $CF")
hook_off(){  # убрать переходы в цепочку из INPUT/FORWARD (все копии)
  local c=$1 b l
  for b in INPUT FORWARD; do
    while IFS= read -r l; do
      # shellcheck disable=SC2086
      iptables -D $b ${l#-A $b } 2>/dev/null
    done < <(iptables -S $b 2>/dev/null | grep -E -- "-j $c( |$)")
  done
}
hook_on(){
  local h b c w
  for h in "${HOOKS[@]}"; do
    read -r b c <<< "$h"
    for w in $(wans); do
      iptables -C "$b" -i "$w" -j "$c" 2>/dev/null; [ $? -eq 1 ] && iptables -I "$b" 1 -i "$w" -j "$c"
    done
  done
}
fingerprint(){ printf '%s|' "$SEC_PROTECT" "$SEC_GEO_ALLOW" "$SEC_GEO_PORTS" "$SEC_TRAP" "$SEC_TRAP_PORTS" "$SEC_RATE" "$SEC_BAN_HOURS" "$SEC_ALLOW_IPS" "$(wans | tr '\n' ' ')" "$(open_ports | tr '\n' ' ')" "$(cat "$SD/geo.ts" 2>/dev/null)"; }

apply(){
  local a
  if ! on; then remove quiet; return 0; fi
  mkdir -p "$SD"; chmod 700 "$SD"
  if [ -n "$(ccs)" ] && [ -n "$(nums "$SEC_GEO_PORTS")" ]; then
    a=$(geo_age)
    if [ "$a" -lt 0 ] || [ "$a" -ge "$GEO_MAX_AGE" ] || [ "$(cat "$SD/geo.src" 2>/dev/null)" != "$(ccs | tr '\n' ' ')" ]; then geo_update; fi
  fi
  GEO_OK=0
  if [ -n "$(ccs)" ] && [ -n "$(nums "$SEC_GEO_PORTS")" ]; then
    if geo_load; then GEO_OK=1; else say "▲ адресов разрешённых стран нет — ограничение по странам не ставлю (иначе отбросились бы все)"; fi
  fi
  sets
  fill $CI rules_in
  fill $CF rules_fwd
  hook_on
  fingerprint > "$RUNF"
  say "✔ защита входящих: $( [ "$GEO_OK" = 1 ] && echo "порты $(nums "$SEC_GEO_PORTS" | tr '\n' ' ')— только из $(ccs | tr 'a-z\n' 'A-Z '); ")$( [ "$SEC_TRAP" = yes ] && echo "ловушки $(traps | tr '\n' ' '); ")$( [ "${SEC_RATE:-0}" -gt 0 ] 2>/dev/null && echo "частота > $SEC_RATE/мин; ")WAN: $(wans | tr '\n' ' ')"
}
remove(){
  local c
  for c in $CI $CF; do hook_off "$c"; iptables -F "$c" 2>/dev/null; iptables -X "$c" 2>/dev/null; done
  for c in $S_BAN $S_TRAP $S_RATE $S_GEO $S_OK; do ipset destroy "$c" 2>/dev/null; done
  rm -f "$RUNF"
  [ "${1:-}" = quiet ] || say "правила защиты входящих убраны"
}
BANSF=${AWG_RUN:-/run}/awg-sec.bans
bans_log(){  # новые блокировки — в журнал $SD/bans.log (время|за что|адрес), до 2000 строк
  local s ip why new=0
  for s in $S_TRAP $S_RATE; do
    why="trap"; [ $s = $S_RATE ] && why="rate"
    for ip in $(members $s); do
      grep -qx "$why $ip" "$BANSF" 2>/dev/null && continue
      echo "$why $ip" >> "$BANSF"; echo "$(date +%s)|$why|$ip" >> "$SD/bans.log"; new=$((new + 1))
    done
  done
  if [ "$new" -gt 0 ] && [ "$(wc -l < "$SD/bans.log")" -gt 2000 ]; then tail -n 1500 "$SD/bans.log" > "$SD/bans.t" && mv -f "$SD/bans.t" "$SD/bans.log"; fi
  return 0
}
ensure(){  # awg-guard, раз в минуту: правила на месте и настройки те же — только журнал новых блокировок
  local h b c w miss=0
  if command -v flock >/dev/null; then exec 7>"${AWG_RUN:-/run}/awg-sec.lock"; flock -n 7 || return 0; fi
  if ! on; then iptables -S $CI >/dev/null 2>&1 && remove quiet; return 0; fi
  for h in "${HOOKS[@]}"; do
    read -r b c <<< "$h"
    for w in $(wans); do iptables -C "$b" -i "$w" -j "$c" 2>/dev/null || { miss=1; break 2; }; done
  done
  [ "$miss" = 0 ] && [ "$(fingerprint)" = "$(cat "$RUNF" 2>/dev/null)" ] || apply >/dev/null
  bans_log
}
count(){ ipset list -t "$1" 2>/dev/null | sed -n 's/^Number of entries: //p'; }
status(){
  if ! on; then say "защита входящих выключена (SEC_PROTECT=yes — включить)"; return 0; fi
  say "по странам: $( [ -n "$(ccs)" ] && [ -n "$(nums "$SEC_GEO_PORTS")" ] && echo "порты $(nums "$SEC_GEO_PORTS" | tr '\n' ' ')— только $(ccs | tr 'a-z\n' 'A-Z '), сетей в наборе $(count $S_GEO)" || echo выключено)"
  say "ловушки: $( [ "$SEC_TRAP" = yes ] && echo "$(traps | tr '\n' ' ')— заблокировано адресов $(count $S_TRAP)" || echo выключены)"
  say "частота: $( [ "${SEC_RATE:-0}" -gt 0 ] 2>/dev/null && echo "больше $SEC_RATE новых соединений в минуту — заблокировано $(count $S_RATE)" || echo выключено)"
  say "правил на месте: $(iptables -S $CI 2>/dev/null | grep -c '^-A') + $(iptables -S $CF 2>/dev/null | grep -c '^-A')"
}

case "${1:-status}" in
  apply)  apply;;
  ensure) ensure;;
  remove) remove;;
  geo)    geo_update && on && apply >/dev/null;;
  status) status;;
  unban)  [[ ${2:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { say "использование: sec.sh unban IP"; exit 2; }
          ipset del $S_TRAP "$2" 2>/dev/null; ipset del $S_RATE "$2" 2>/dev/null; event "блокировка снята: $2"; say "$2: блокировка снята";;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//';;
esac
