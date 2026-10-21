#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# Защита входящих (sec.sh, 1.10) на заглушках iptables/ipset: цепочки, ловушки, страны, частота, сверка, журнал блокировок.
# Запуск: bash tests/t_sec.sh <папка awg>
H=$(cd "$(dirname "$0")" && pwd); SRC=$(cd "${1:-$H/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB=$T/stub DD=$T/dd AWG_RUN=$T/run STATEF=$T/run/awg-state SEC_GEO_MIN=3
mkdir -p "$STUB" "$DD" "$AWG_RUN" "$T/bin" "$T/srv"
cp "$SRC/sec.sh" "$SRC/lists.sh" "$DD/"; chmod 755 "$DD"/*.sh
cp "$H"/stubs2/* "$T/bin/"
cat > "$T/bin/curl" <<'S'
#!/bin/bash
o=""; u=""; while [ $# -gt 0 ]; do case "$1" in -o) o=$2; shift;; http*) u=$1;; esac; shift; done
echo "curl $u" >> "$STUB/curl.log"
f="$SRV/$(basename "$u")"; [ -f "$f" ] || exit 22
cp "$f" "$o"
S
printf '#!/bin/bash\n[ "$1 $2" = "-4 route" ] && echo "default via 188.113.154.1 dev eth3"\nexit 0\n' > "$T/bin/ip"
chmod 755 "$T"/bin/*; export PATH="$T/bin:$PATH" SRV=$T/srv
printf '5.8.0.0/16\n5.9.0.0/16\n31.13.0.0/16\n37.9.0.0/16\n46.0.0.0/16\n77.88.0.0/16\n' > "$T/srv/ru.cidr"
# правила UniFi: проброс 8123 и 25, консоль 443 и WireGuard 51820 в наборах портов; RDP 3389 проброшен — не ловушка
iptables -t nat -N UBIOS_PREROUTING_USER_HOOK
iptables -t nat -A UBIOS_PREROUTING_USER_HOOK -d 188.113.154.234/32 -p tcp -m tcp --dport 8123 -j DNAT --to-destination 192.168.1.168:8123
iptables -t nat -A UBIOS_PREROUTING_USER_HOOK -d 188.113.154.234/32 -p tcp -m tcp --dport 3389 -j DNAT --to-destination 192.168.1.20:3389
ipset create UBIOS_unifi_console_https_port bitmap:port; ipset add UBIOS_unifi_console_https_port 443
ipset create UBIOS_wireguard_ports bitmap:port; ipset add UBIOS_wireguard_ports 51820
iptables -A INPUT -j UBIOS_INPUT_JUMP; iptables -A FORWARD -j UBIOS_FORWARD_JUMP
printf 'WANIF=eth3\nGEO_URL=https://geo.test/%%s.cidr\nVPS_IP=203.0.113.5\n' > "$DD/awg.env"
X="$DD/sec.sh"; fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
ci(){ iptables -S AWG_SEC_IN 2>/dev/null; }; cf(){ iptables -S AWG_SEC_FWD 2>/dev/null; }

"$X" apply > $T/o 2>&1
ck "выключено: цепочек нет" '! ci | grep -q . && ! iptables -S INPUT | grep -q AWG_SEC'
printf 'SEC_PROTECT=yes\n' >> "$DD/awg.env"
"$X" apply > $T/o 2>&1
ck "включено: переход первым в INPUT и FORWARD только с WAN" '[ "$(iptables -S INPUT | sed -n 2p)" = "-A INPUT -i eth3 -j AWG_SEC_IN" ] && [ "$(iptables -S FORWARD | sed -n 2p)" = "-A FORWARD -i eth3 -j AWG_SEC_FWD" ]' || { iptables -S INPUT; cat $T/o; }
ck "свои адреса не блокируются: частные сети и VPS" 'grep -qx 192.168.0.0/16 "$STUB/ipset-AWG_SEC_OK" && grep -qx 203.0.113.5 "$STUB/ipset-AWG_SEC_OK"'
ck "по умолчанию: ловушки (без проброшенного 3389, консоли 443 и WireGuard), частота 30/мин" 'ci | grep -q -- "--dports 23,135,139,445,1433,2323,3306,5432,5900,6379,7547,8291,9200,27017 -j SET --add-set AWG_SEC_TRAP src" && ! ci | grep -- "--dports" | grep -qE "(,|\s)3389(,|\s)" && cf | grep -q -- "--hashlimit-above 30/min" && cf | grep -q -- "--match-set AWG_SEC_RATE src -j DROP"' || ci
ck "сначала уже установленные соединения и свои адреса, потом блокировки" '[ "$(ci | sed -n 2p)" = "-A AWG_SEC_IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" ] && ci | sed -n 3p | grep -q AWG_SEC_OK && ci | sed -n 4p | grep -q "AWG_SEC_BAN src -j DROP"'
ck "наборы блокировок с ловушек и за частоту — одна проверка" 'grep -qx AWG_SEC_TRAP "$STUB/ipset-AWG_SEC_BAN" && grep -qx AWG_SEC_RATE "$STUB/ipset-AWG_SEC_BAN"'
ck "без стран — правил «только из стран» нет" '! ci | grep -q AWG_SEC_GEO && ! cf | grep -q AWG_SEC_GEO'
printf 'SEC_GEO_ALLOW="RU"\nSEC_GEO_PORTS="8123 443"\n' >> "$DD/awg.env"
"$X" apply > $T/o 2>&1
ck "страны: адреса скачаны, проброс 8123 и консоль 443 — только из RU" 'grep -q "✔ адреса стран RU" $T/o && [ "$(grep -c . "$STUB/ipset-AWG_SEC_GEO")" = 6 ] && cf | grep -q -- "--ctstate DNAT --ctorigdstport 8123 -m set ! --match-set AWG_SEC_GEO src -j DROP" && ci | grep -q -- "-p tcp -m tcp --dport 443 -m set ! --match-set AWG_SEC_GEO src -j DROP"' || { cat $T/o; cf; }
ck "страны: кэш общий со списками" '[ -s "$DD/lists/geo-ru.cidr" ] && [ -s "$DD/sec/geo.cidr" ]'
n0=$(wc -l < "$STUB/curl.log")
"$X" apply > /dev/null 2>&1
ck "страны: свежие (неделя) — не скачиваются снова" '[ "$(wc -l < "$STUB/curl.log")" = "$n0" ]'
printf 'SEC_GEO_ALLOW="zz"\n' >> "$DD/awg.env"
"$X" apply > $T/o 2>&1
ck "страна без адресов: правило по странам не ставится (иначе отбросились бы все)" 'grep -q "▲ адресов разрешённых стран нет" $T/o && ! cf | grep -q AWG_SEC_GEO && ! ci | grep -q AWG_SEC_GEO' || cat $T/o
printf 'SEC_GEO_ALLOW="ru"\nSEC_RATE=0\nSEC_TRAP=no\n' >> "$DD/awg.env"
"$X" apply > /dev/null 2>&1
ck "ловушки и частота выключаются по отдельности" '! ci | grep -q AWG_SEC_TRAP && ! cf | grep -q hashlimit && cf | grep -q ctorigdstport'
printf 'SEC_TRAP=yes\nSEC_RATE=20\n' >> "$DD/awg.env"
"$X" apply > /dev/null 2>&1
r0=$(ci; cf)
"$X" ensure
ck "сверка: всё на месте — правила не пересобираются" '[ "$(ci; cf)" = "$r0" ] && [ "$(iptables -S INPUT | grep -c AWG_SEC_IN)" = 1 ]'
iptables -D INPUT -i eth3 -j AWG_SEC_IN
"$X" ensure
ck "сверка: переход пропал (UniFi пересобрал правила) — поставлен снова, один" '[ "$(iptables -S INPUT | grep -c AWG_SEC_IN)" = 1 ]'
iptables -t nat -A UBIOS_PREROUTING_USER_HOOK -d 188.113.154.234/32 -p tcp -m tcp --dport 5900 -j DNAT --to-destination 192.168.1.20:5900
"$X" ensure
ck "сверка: новый проброс 5900 — он больше не ловушка" '! ci | grep -- "--dports" | grep -qE "(,|\s)5900(,|\s)"' || ci
ipset add AWG_SEC_TRAP 45.1.1.1; ipset add AWG_SEC_RATE 45.2.2.2
"$X" ensure; "$X" ensure
ck "журнал блокировок: новые адреса — по одному разу, за что" '[ "$(grep -c "|trap|45.1.1.1" "$DD/sec/bans.log")" = 1 ] && grep -q "|rate|45.2.2.2" "$DD/sec/bans.log"'
"$X" unban 45.1.1.1 > /dev/null
ck "снять блокировку" '! grep -qx 45.1.1.1 "$STUB/ipset-AWG_SEC_TRAP"'
ck "снять блокировку: только IPv4" '! "$X" unban "1.2.3.4;id" >/dev/null'
"$X" status > $T/o
ck "состояние" 'grep -q "по странам: порты 443 8123 — только RU" $T/o && grep -q "частота: больше 20" $T/o' || cat $T/o
sed -i 's/^SEC_PROTECT=yes/SEC_PROTECT=no/' "$DD/awg.env"
"$X" ensure
ck "выключили — сверка убирает всё" '! iptables -S INPUT | grep -q AWG_SEC && ! iptables -S FORWARD | grep -q AWG_SEC && ! ci | grep -q . && ! grep -qx AWG_SEC_TRAP "$STUB/ipsets"'
ck "правила UniFi не тронуты" 'iptables -S INPUT | grep -q UBIOS_INPUT_JUMP && iptables -t nat -S UBIOS_PREROUTING_USER_HOOK | grep -q 8123'
echo "== sec: ошибок $fails"
[ $fails = 0 ]
