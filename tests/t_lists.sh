#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# Списки и GeoIP (#38) на заглушках: скачивание (напрямую и через туннель), проверка формата, ipset, правила guard.sh.
# Запуск: bash tests/t_lists.sh <папка awg>
H=$(cd "$(dirname "$0")" && pwd); SRC=$(cd "${1:-$H/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB=$T/stub DD=$T/dd AWG_RUN=$T/run STATEF=$T/run/awg-state
mkdir -p "$STUB" "$DD" "$AWG_RUN" "$T/bin" "$T/srv"
cp "$SRC/lists.sh" "$SRC/guard.sh" "$DD/"; chmod 755 "$DD"/*.sh
cp "$H"/stubs2/* "$T/bin/"
# «интернет»: файлы в $T/srv по последней части URL; $STUB/direct_down — напрямую не открывается, только через туннель
cat > "$T/bin/curl" <<'S'
#!/bin/bash
o=""; i=""; u=""; while [ $# -gt 0 ]; do case "$1" in -o) o=$2; shift;; --interface) i=$2; shift;; http*) u=$1;; esac; shift; done
echo "curl ${i:-wan} $u" >> "$STUB/curl.log"
[ -z "$i" ] && [ -e "$STUB/direct_down" ] && exit 7
f="$SRV/$(basename "$u")"; [ -f "$f" ] || exit 22
cp "$f" "$o"
S
printf '#!/bin/bash\n[ "$1 $2" = "link show" ] && exit 0\nexit 0\n' > "$T/bin/ip"
chmod 755 "$T"/bin/*; export PATH="$T/bin:$PATH" SRV=$T/srv
{ for i in $(seq 1 150); do echo "203.0.$((i % 250)).0/24"; done; echo "10.0.0.0/8"; echo "<html>"; echo "1.2.3.4/33"; echo "198.51.100.7"; } > "$T/srv/allyouneed.lst"
printf -- '---\n# Country: Russia (RU)\n#\n5.8.0.0/16\n5.9.0.0/16\n31.13.0.0/16\n37.9.0.0/16\n46.0.0.0/16\n77.88.0.0/16\n' > "$T/srv/ru.cidr"
printf '1.0.1.0/24\n1.0.2.0/23\n1.0.8.0/21\n14.0.0.0/21\n27.0.0.0/22\n36.0.0.0/22\n' > "$T/srv/cn.cidr"
printf '<html>not found</html>\n' > "$T/srv/zz.cidr"
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nWANIF=eth3\nLEAK_GUARD=yes\nGEO_URL=https://geo.test/%%s.cidr\n' > "$DD/awg.env"
echo "ACTIVE=awgmain" > "$STATEF"; echo awg-guard > "$DD/.units"
L="$DD/lists.sh"; G="$DD/guard.sh"; fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
cx(){ iptables -t mangle -S AWG_DIRECT_POST 2>/dev/null; }

ck "выключено: ничего не скачивается, правил нет" '"$L" update | grep -q "выключены" && [ ! -s "$STUB/curl.log" ] && "$G" apply && ! cx | grep -q AWG_LIST'
printf 'LISTS_MODE=blocked\n' >> "$DD/awg.env"
"$L" update > $T/o 2>&1
ck "blocked: список скачан, мусор, частные сети и ошибки формата отброшены" 'grep -q "✔ список заблокированного: 151 сетей" $T/o && ! grep -q "10.0.0.0" "$DD/lists/blocked.cidr" && grep -qx "198.51.100.7" "$DD/lists/blocked.cidr" && [ "$(stat -c %a "$DD/lists")" = 700 ]' || cat $T/o
ck "blocked: набор AWG_LIST загружен" '[ "$(grep -c . "$STUB/ipset-AWG_LIST")" = 151 ]'
"$G" apply
ck "blocked: под PBR через туннель только список (метка снимается для остального)" 'cx | grep -q -- "-m mark --mark 0x6a0000/0x7e0000 -m set ! --match-set AWG_LIST dst -m set ! --match-set AWG_KEEP dst -j MARK --set-xmark 0x0/0x7e0000"'
printf 'TUN_DOMAINS="openai.com"\n' >> "$DD/awg.env"; "$G" apply
ck "blocked + домены через туннель: домены не теряют туннель (AWG_DOM в AWG_KEEP)" 'grep -qx AWG_DOM "$STUB/ipset-AWG_KEEP"'
sed -i '/^TUN_DOMAINS=/d' "$DD/awg.env"
cp "$DD/lists/blocked.cidr" $T/keep; printf '<html>blocked</html>\n' > "$T/srv/allyouneed.lst"
ck "плохой ответ источника — прежний список остаётся" '! "$L" update --force > $T/o2 2>&1; grep -q "остаётся прежний" $T/o2 && cmp -s $T/keep "$DD/lists/blocked.cidr"'
sed -i 's/^LISTS_MODE=.*/LISTS_MODE=geoip/' "$DD/awg.env"; printf 'GEO_COUNTRIES="RU, cn zz"\n' >> "$DD/awg.env"
: > "$STUB/curl.log"; touch "$STUB/direct_down"
"$L" update > $T/o3 2>&1
ck "geoip: напрямую недоступно — скачано через туннель" 'grep -q "curl awgmain .*ru.cidr" "$STUB/curl.log" && grep -q "✔ RU: 6" $T/o3 && grep -q "✔ CN: 6" $T/o3'
ck "geoip: страна с ответом-не-списком пропущена" 'grep -q "✘ ZZ" $T/o3 && [ "$(grep -c . "$STUB/ipset-AWG_GEO")" = 12 ]'
rm -f "$STUB/direct_down"; "$G" apply
ck "geoip: адреса стран — напрямую (метка снимается), остальное через туннель" 'cx | grep -q -- "-m mark --mark 0x6a0000/0x7e0000 -m set --match-set AWG_GEO dst -m set ! --match-set AWG_KEEP dst -j MARK --set-xmark 0x0/0x7e0000" && ! cx | grep -q AWG_LIST'
mkdir -p "$DD/route.d"; printf 'RAIL_IF="wgclt2"\nMARK="0x6c0000/0x7e0000"\nTABLE="179"\nTUNNELS="awgmain"\n' > "$DD/route.d/iot.env"; "$G" apply
ck "geoip: и для дополнительного маршрута (умный дом на своём профиле)" 'cx | grep -q -- "-m mark --mark 0x6c0000/0x7e0000 -m set --match-set AWG_GEO dst"'
"$G" check > $T/c
ck "check: GeoIP в отчёте" 'grep -q "OK     GeoIP: напрямую RU, CN ZZ (12 сетей)" $T/c || grep -q "OK     GeoIP: напрямую" $T/c'
ck "due: свежий — рано, старый — пора" '! "$L" due && echo 1 > "$DD/lists/geo.ts" && "$L" due'
"$L" status > $T/s
ck "status: режим и числа" 'grep -q "режим: geoip (напрямую: CN RU ZZ )" $T/s && grep -q "geo: в наборе AWG_GEO 12" $T/s'
: > "$STUB/ipsets"; rm -f "$STUB"/ipset-AWG_*; "$G" apply
ck "после загрузки роутера наборы берутся из кэша" '[ "$(grep -c . "$STUB/ipset-AWG_GEO")" = 12 ] && cx | grep -q AWG_GEO'
date +%s > "$DD/lists/geo.ts"
ck "due: страны поменялись — пора, хоть кэш и свежий" '! "$L" due && sed -i "s/^GEO_COUNTRIES=.*/GEO_COUNTRIES=\"ru by\"/" "$DD/awg.env" && "$L" due'
"$L" json > $T/j
ck "json: разбирается, видно расхождение со странами" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"mode\"]==\"geoip\" and d[\"sets\"][\"geo\"][\"set\"]==12 and d[\"sets\"][\"geo\"][\"stale\"] and d[\"due\"]" $T/j' || cat $T/j
( flock 8; sleep 2 ) 8>"$DD/lists/.lock" & LP=$!; sleep 0.3
ck "второе обновление при идущем первом — пропускается" '"$L" update | grep -q "уже идёт"'
wait $LP
# маршрута UniFi «весь интернет» нет — режим ни на что не влияет: панель и check предупреждают
ck "full: цепочки UniFi нет — не знаем (-1), не предупреждаем" '[ "$("$L" full)" = -1 ]'
iptables -t mangle -N UBIOS_PREROUTING_PBR
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_dn_1 dst -j MARK --set-xmark 0x6a0000/0x7e0000
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_trafficroute_clients_9 src -j MARK --set-xmark 0x1a0000/0x7e0000
"$G" check > $T/c2; "$L" json > $T/j2; "$L" status > $T/s2
ck "full: только маршруты по доменам — 0 и предупреждение (check, status, json)" '[ "$("$L" full)" = 0 ] && grep -q "WARN   списки: в UniFi нет маршрута PBR" $T/c2 && grep -q "нет маршрута PBR" $T/s2 && python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"full\"]==0" $T/j2'
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_trafficroute_clients_13 src -m set ! --match-set UBIOS_local_network dst -j MARK --set-xmark 0x6c0000/0x7e0000
"$G" check > $T/c3
ck "full: маршрут на весь интернет (кроме локальных сетей) для профиля route.d — считается, предупреждения нет" '[ "$("$L" full)" = 1 ] && ! grep -q "нет маршрута PBR" $T/c3'
# явные маршруты UniFi по доменам/адресам остаются в туннеле и при GeoIP (их IPv4-наборы — в AWG_KEEP), чужие метки и
# отрицания не в счёт; изменения маршрутов UniFi подхватываются (сверка раз в 60 с)
for n in UBIOS4trafficroute_dn_1 UBIOS4trafficroute_dn_13 UBIOS4trafficroute_ip_9 UBIOS4trafficroute_dn_2; do ipset create $n hash:ip; done
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_dn_2 dst -j MARK --set-xmark 0x1a0000/0x7e0000
rm -f "$AWG_RUN/awg-guard.keep.ts"; "$G" apply
ck "GeoIP: наборы маршрутов UniFi с нашей меткой — в AWG_KEEP, чужая метка и «кроме» (отрицание) — нет" 'grep -qx UBIOS4trafficroute_dn_1 "$STUB/ipset-AWG_KEEP" && ! grep -q -e trafficroute_dn_2 -e local_network "$STUB/ipset-AWG_KEEP"'
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_ip_9 dst -j MARK --set-xmark 0x6a0000/0x7e0000
"$G" run > /dev/null 2>&1 & GP=$!; sleep 3
ck "GeoIP: служба не перечитывает маршруты UniFi каждые 5 с — новый подхватывается при сверке раз в 60 с" '! grep -qx UBIOS4trafficroute_ip_9 "$STUB/ipset-AWG_KEEP"'
echo 1 > "$AWG_RUN/awg-guard.keep.ts"; sleep 6; kill -TERM $GP; wait $GP 2>/dev/null
ck "GeoIP: …и подхвачен при сверке" 'grep -qx UBIOS4trafficroute_ip_9 "$STUB/ipset-AWG_KEEP"'
echo "== lists: ошибок $fails"
[ $fails = 0 ]
