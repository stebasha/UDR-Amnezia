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
ck "по умолчанию: ловушки (без проброшенного 3389, консоли 443 и WireGuard), подбор паролей выключен" 'ci | grep -q -- "--dports 23,135,139,445,1433,2323,3306,5432,5900,6379,7547,8291,9200,27017 -j SET --add-set AWG_SEC_TRAP src" && ! ci | grep -- "--dports" | grep -qE "(,|\s)3389(,|\s)" && ! cf | grep -q "recent --name"' || ci
ck "сначала уже установленные соединения и свои адреса, потом блокировки" '[ "$(ci | sed -n 2p)" = "-A AWG_SEC_IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" ] && ci | sed -n 3p | grep -q AWG_SEC_OK && ci | sed -n 4p | grep -q "AWG_SEC_PEER src -j RETURN" && ci | sed -n 5p | grep -q "AWG_SEC_TRAP src -j DROP"'
ck "роутер (VPN-сервер) закрывается только для сканеров, не за частоту" '! ci | grep -q AWG_SEC_BAN && ! ci | grep -q AWG_SEC_RATE && cf | grep -q "AWG_SEC_BAN src -j DROP"'
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
# не скачалось при включении — сверка повторяет сама (не чаще раза в 10 минут), причина — в apply.log
mv "$T/srv/ru.cidr" "$T/srv/ru.off"; rm -f "$DD/lists/geo-ru.cidr" "$DD/sec/geo.cidr" "$DD/sec/geo.ts"; ipset destroy AWG_SEC_GEO
printf 'SEC_GEO_ALLOW="ru"\n' >> "$DD/awg.env"
"$X" ensure
ck "страны не скачались: правила нет, причина в журнале" '! cf | grep -q AWG_SEC_GEO && grep -q "✘ RU" "$DD/sec/apply.log"' || cat "$DD/sec/apply.log"
mv "$T/srv/ru.off" "$T/srv/ru.cidr"
"$X" ensure
ck "повтор не раньше чем через 10 минут" '! cf | grep -q AWG_SEC_GEO'
echo $(( $(date +%s) - 700 )) > "$DD/sec/geo.try"
"$X" ensure
ck "через 10 минут — скачано, правило поставлено" 'cf | grep -q ctorigdstport && [ "$(grep -c . "$STUB/ipset-AWG_SEC_GEO")" = 6 ]' || cat "$DD/sec/apply.log"
rm -f "$DD/sec/geo.ts"; "$X" geo > $T/o 2>&1
ck "sec.sh geo: скачать сейчас и поставить" 'grep -q "только из RU" $T/o' || cat $T/o
printf 'SEC_GEO_ALLOW="ru"\nSEC_RATE=0\nSEC_TRAP=no\n' >> "$DD/awg.env"
"$X" apply > /dev/null 2>&1
ck "ловушки и частота выключаются по отдельности" '! ci | grep -q "add-set AWG_SEC_TRAP" && ! cf | grep -q "recent --name" && cf | grep -q ctorigdstport'
printf 'SEC_TRAP=yes\nSEC_RATE=20\n' >> "$DD/awg.env"; "$X" apply > /dev/null 2>&1
ck "подбор паролей включён: xt_recent, блокировка на 1 ч (только проброс)" 'cf | grep -q -- "-m recent --name awgsec --set --rsource" && cf | grep -q -- "--rcheck --seconds 60 --hitcount 20 --rsource -j SET --add-set AWG_SEC_RATE src --exist --timeout 3600" && cf | grep -q -- "--match-set AWG_SEC_RATE src -j DROP"' || cf
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
# клиент VPN-сервера роутера подключён с 80.83.225.5 (handshake только что) — свой: снимается блокировка, не блокируется
ipset add AWG_SEC_RATE 80.83.225.5; ipset add AWG_SEC_TRAP 94.243.30.96
cat > "$T/bin/wg" <<S
#!/bin/bash
case "\$3" in
  endpoints) printf 'wgsrv1\tPK1=\t80.83.225.5:49666\nwgsrv1\tPK2=\t94.243.30.96:51328\nwgsrv1\tPK3=\t(none)\nawgmain\tPK4=\t203.0.113.9:443\n';;
  latest-handshakes) printf 'wgsrv1\tPK1=\t%s\nwgsrv1\tPK2=\t%s\nwgsrv1\tPK3=\t0\nawgmain\tPK4=\t%s\n' \$(date +%s) \$((\$(date +%s) - 900)) \$(date +%s);;
esac
S
chmod +x "$T/bin/wg"
"$X" ensure; "$X" ensure
ck "свой клиент VPN-сервера (свежий handshake): блокировка снята, в списке своих" '! grep -qx 80.83.225.5 "$STUB/ipset-AWG_SEC_RATE" && grep -qx 80.83.225.5 "$STUB/ipset-AWG_SEC_PEER"'
ck "клиент без свежего handshake и туннели роутера — не трогаются" 'grep -qx 94.243.30.96 "$STUB/ipset-AWG_SEC_TRAP" && ! grep -qx 203.0.113.9 "$STUB/ipset-AWG_SEC_PEER"'
ck "журнал блокировок: новые адреса — по одному разу, за что" '[ "$(grep -c "|trap|45.1.1.1" "$DD/sec/bans.log")" = 1 ] && grep -q "|rate|45.2.2.2" "$DD/sec/bans.log"'
"$X" unban 45.1.1.1 > /dev/null
ck "снять блокировку" '! grep -qx 45.1.1.1 "$STUB/ipset-AWG_SEC_TRAP"'
ck "снять блокировку: только IPv4" '! "$X" unban "1.2.3.4;id" >/dev/null'
"$X" status > $T/o
ck "частота: порты 25 и 80 не считаются (по умолчанию), до подсчёта" 'cf | grep -n -- "--ctorigdstport 25 -j RETURN" | cut -d: -f1 | { read a; b=$(cf | grep -n -- "recent --name awgsec --set" | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ]; } && cf | grep -q -- "--ctorigdstport 80 -j RETURN"'
printf 'SEC_RATE_SKIP=""\n' >> "$DD/awg.env"; "$X" ensure
ck "частота: пустой список — считаются все порты" '! cf | grep -q -- "--ctorigdstport 25 -j RETURN"'
printf 'SEC_RATE=50\n' >> "$DD/awg.env"; "$X" apply > /dev/null 2>&1
ck "частота больше 20 — до 20 (предел xt_recent)" 'cf | grep -q -- "--hitcount 20 "'
printf 'SEC_RATE=20\n' >> "$DD/awg.env"; "$X" apply > /dev/null 2>&1
ck "состояние" 'grep -q "по странам: порты 443 8123 — только RU" $T/o && grep -q "частота: больше 20" $T/o' || cat $T/o
sed -i 's/^SEC_PROTECT=yes/SEC_PROTECT=no/' "$DD/awg.env"
"$X" ensure
ck "выключили — сверка убирает всё" '! iptables -S INPUT | grep -q AWG_SEC && ! iptables -S FORWARD | grep -q AWG_SEC && ! ci | grep -q . && ! grep -qx AWG_SEC_TRAP "$STUB/ipsets"'
ck "правила UniFi не тронуты" 'iptables -S INPUT | grep -q UBIOS_INPUT_JUMP && iptables -t nat -S UBIOS_PREROUTING_USER_HOOK | grep -q 8123'
echo "== sec: ошибок $fails"
[ $fails = 0 ]
