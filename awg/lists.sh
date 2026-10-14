#!/bin/bash
# lists.sh — списки и GeoIP (#38), по желанию (LISTS_MODE в awg.env, по умолчанию off):
#   LISTS_MODE=blocked   устройства под PBR идут через туннель только к адресам из списков заблокированного,
#                        остальное — напрямую (домены TUN_DOMAINS — по-прежнему через туннель)
#   LISTS_MODE=geoip     устройства под PBR идут через туннель везде, кроме адресов стран GEO_COUNTRIES (например
#                        «ru cn by kz»): умный дом с серверами в Китае и местные сервисы — напрямую
# Наборы ipset AWG_LIST и AWG_GEO наполняются отсюда; правила, которые снимают метку PBR, ставит guard.sh (awg-guard).
#   lists.sh update [--force]   скачать списки (раз в сутки; при недоступности напрямую — через туннель), проверить формат
#                               и загрузить в ipset; при любой ошибке остаются прежние
#   lists.sh load               загрузить наборы из кэша (после загрузки роутера)
#   lists.sh status             режим, страны, число адресов, возраст
#   lists.sh json               то же для панели
#   lists.sh due                код 0, если пора обновлять (служба awg-guard проверяет раз в час)
# Источники (можно заменить в awg.env): LIST_URLS — списки заблокированного (CIDR IPv4 по строке),
# GEO_URL — адреса страны, %s — код страны в нижнем регистре.
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
LD=$DD/lists
umask 077
LISTS_MODE=off; GEO_COUNTRIES=""; LIST_URLS=""; GEO_URL=""; LIST_MAX_AGE=86400; MAIN=awgmain; BACKUP=""
# shellcheck disable=SC1091
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
LIST_URLS=${LIST_URLS:-"https://antifilter.download/list/allyouneed.lst"}
GEO_URL=${GEO_URL:-"https://raw.githubusercontent.com/ipverse/country-ip-blocks/master/country/%s/ipv4-aggregated.txt"}
LIST_SET=AWG_LIST
GEO_SET=AWG_GEO
MIN_LIST=${LIST_MIN:-100}    # меньше — ответ не похож на список (страница ошибки, обрезанный файл): не берём
MIN_GEO=${GEO_MIN:-5}

say(){ printf '%s\n' "$*"; }
die(){ say "ОШИБКА: $*"; exit 1; }
event(){ echo "$(date +%s)|lists|$1" >> "$DD/events.log"; }
valid_cc(){ [[ $1 =~ ^[a-z]{2}$ ]]; }
countries(){ local c; for c in $(echo "$GEO_COUNTRIES" | tr 'A-Z,' 'a-z '); do valid_cc "$c" && echo "$c"; done | sort -u; }

fetch(){  # fetch URL ФАЙЛ — напрямую, при неудаче через активный туннель
  local u=$1 f=$2 i act
  case "$u" in https://*) ;; *) return 1;; esac
  curl -fsSL -m 60 --max-filesize 20000000 -o "$f" "$u" 2>/dev/null && return 0
  act=$(sed -n 's/^ACTIVE=//p' "${STATEF:-/run/awg-state}" 2>/dev/null)
  for i in $act $MAIN $BACKUP; do
    ip link show "$i" >/dev/null 2>&1 || continue
    curl -fsSL -m 60 --max-filesize 20000000 --interface "$i" -o "$f" "$u" 2>/dev/null && return 0
  done
  return 1
}
clean(){  # только корректные CIDR/адреса IPv4, без частных и служебных сетей
  awk '{ sub(/\r$/,""); sub(/[ \t]*#.*/,""); gsub(/[ \t]/,"") }
       /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {   # без {n,m}: mawk их не понимает
         split($0, p, "/"); split(p[1], o, "."); ok = 1
         for (i = 1; i <= 4; i++) if (length(o[i]) > 3 || o[i] + 0 > 255) ok = 0
         if (length(p[2]) > 2) ok = 0
         if (p[2] != "" && (p[2] + 0 < 1 || p[2] + 0 > 32)) ok = 0
         for (i = 1; i <= 4; i++) o[i] += 0
         if (o[1] == 0 || o[1] == 10 || o[1] == 127 || o[1] >= 224 || (o[1] == 192 && o[2] == 168) || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 100 && o[2] >= 64 && o[2] <= 127) || (o[1] == 169 && o[2] == 254)) ok = 0
         if (ok) print }' "$1" | sort -u
}
load_set(){  # load_set НАБОР ФАЙЛ — атомарно: временный набор, затем swap
  local s=$1 f=$2 n
  [ -s "$f" ] || return 1
  n=$(wc -l < "$f")
  ipset create "$s" hash:net family inet maxelem 262144 -exist 2>/dev/null || return 1
  ipset destroy "$s.new" 2>/dev/null
  { echo "create $s.new hash:net family inet maxelem 262144"; sed "s/^/add $s.new /" "$f"; } | ipset restore 2>/dev/null || { ipset destroy "$s.new" 2>/dev/null; return 1; }
  ipset swap "$s.new" "$s" && ipset destroy "$s.new" 2>/dev/null
  echo "$n"
}
count(){ ipset list -t "$1" 2>/dev/null | sed -n 's/^Number of entries: //p'; }
update(){
  local force=$1 tmp u n c ok=1 got=0 msg=""
  mkdir -p "$LD"; chmod 700 "$LD"
  [ "$LISTS_MODE" = off ] && [ "$force" != --force ] && { say "списки выключены (LISTS_MODE=off)"; return 0; }
  tmp=$(mktemp -d "$DD/.lists.XXXXXX")
  if [ "$LISTS_MODE" = blocked ] || [ "$force" = --force ]; then
    : > "$tmp/list.raw"
    for u in $LIST_URLS; do
      if fetch "$u" "$tmp/one"; then cat "$tmp/one" >> "$tmp/list.raw"; got=$((got+1)); else say "▲ не скачался $u"; fi
    done
    clean "$tmp/list.raw" > "$tmp/list"
    n=$(wc -l < "$tmp/list")
    if [ "$got" -gt 0 ] && [ "$n" -ge "$MIN_LIST" ]; then
      mv -f "$tmp/list" "$LD/blocked.cidr"; date +%s > "$LD/blocked.ts"; echo "$LIST_URLS" > "$LD/blocked.src"; msg="$msg заблокированное: $n;"
      say "✔ список заблокированного: $n сетей"
    else ok=0; say "✘ список заблокированного не обновлён (скачано источников: $got, сетей: $n) — остаётся прежний"; fi
  fi
  if [ "$LISTS_MODE" = geoip ] || [ "$force" = --force ]; then
    : > "$tmp/geo"
    for c in $(countries); do
      # shellcheck disable=SC2059
      if fetch "$(printf "$GEO_URL" "$c")" "$tmp/$c.raw"; then
        clean "$tmp/$c.raw" > "$tmp/$c"; n=$(wc -l < "$tmp/$c")
        if [ "$n" -ge "$MIN_GEO" ]; then mv -f "$tmp/$c" "$LD/geo-$c.cidr"; say "✔ ${c^^}: $n сетей"
        else ok=0; say "✘ ${c^^}: ответ не похож на список ($n строк) — остаётся прежний"; fi
      else ok=0; say "✘ ${c^^}: не скачался — остаётся прежний"; fi
      [ -s "$LD/geo-$c.cidr" ] && cat "$LD/geo-$c.cidr" >> "$tmp/geo"
    done
    sort -u "$tmp/geo" > "$LD/geo.cidr"; date +%s > "$LD/geo.ts"; countries | tr '\n' ' ' > "$LD/geo.src"; msg="$msg страны $(countries | tr 'a-z\n' 'A-Z '): $(wc -l < "$LD/geo.cidr");"
  fi
  rm -rf "$tmp"
  load
  event "списки обновлены:${msg:- нечего}"
  [ $ok = 1 ]
}
load(){  # из кэша в ipset (наборы нужны, даже пустые: на них ссылаются правила guard.sh)
  local n
  ipset create $LIST_SET hash:net family inet maxelem 262144 -exist 2>/dev/null
  ipset create $GEO_SET hash:net family inet maxelem 262144 -exist 2>/dev/null
  if [ -s "$LD/blocked.cidr" ]; then n=$(load_set $LIST_SET "$LD/blocked.cidr") && say "· $LIST_SET: $n"; fi
  if [ -s "$LD/geo.cidr" ]; then n=$(load_set $GEO_SET "$LD/geo.cidr") && say "· $GEO_SET: $n"; fi
  return 0
}
age(){ local t; t=$(cat "$LD/$1.ts" 2>/dev/null); [[ $t =~ ^[0-9]+$ ]] && echo $(( $(date +%s) - t )) || echo -1; }
src(){ case "$1" in blocked) echo "$LIST_URLS";; geo) countries | tr '\n' ' ';; esac; }
due(){  # пора: кэша нет, он старше LIST_MAX_AGE или собран для других стран/источников
  local a k
  case "$LISTS_MODE" in blocked) k=blocked;; geoip) k=geo;; *) return 1;; esac
  a=$(age $k); [ "$a" -lt 0 ] || [ "$a" -ge "$LIST_MAX_AGE" ] || [ "$(cat "$LD/$k.src" 2>/dev/null)" != "$(src $k)" ]
}

case "${1:-status}" in
  update) update "${2:-}";;
  load)   load;;
  due)    due;;
  json)  # для панели: режим, страны, по каждому списку — в наборе, в кэше, возраст, совпадает ли с настройками
    printf '{"mode":"%s","countries":"%s","sets":{' "$LISTS_MODE" "$(src geo)"
    sep=""
    for k in blocked geo; do
      s=$LIST_SET; [ $k = geo ] && s=$GEO_SET
      n=$(count $s); c=$( { wc -l < "$LD/$k.cidr"; } 2>/dev/null || echo 0)
      printf '%s"%s":{"set":%d,"cache":%d,"age":%d,"stale":%s}' "$sep" $k "${n:-0}" "$c" "$(age $k)" \
        "$([ "$(cat "$LD/$k.src" 2>/dev/null)" = "$(src $k)" ] && echo false || echo true)"
      sep=,
    done
    printf '},"due":%s}\n' "$(due && echo true || echo false)";;
  status)
    say "режим: $LISTS_MODE$( [ "$LISTS_MODE" = geoip ] && echo " (напрямую: $(countries | tr 'a-z\n' 'A-Z '))")"
    for k in blocked geo; do
      a=$(age $k); s=$LIST_SET; [ $k = geo ] && s=$GEO_SET
      say "$k: в наборе $s $(count $s || echo 0), в кэше $( { wc -l < "$LD/$k.cidr"; } 2>/dev/null || echo 0), обновлён $( [ "$a" -ge 0 ] && echo "$((a/3600)) ч назад" || echo никогда)"
    done;;
  *) sed -n '2,17p' "$0";;
esac
