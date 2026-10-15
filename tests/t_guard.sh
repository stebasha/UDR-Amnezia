#!/bin/bash
# shellcheck disable=SC2034,SC1090  # переменные используются в строках для eval (проверки t/ck), источники — заглушки
COMP=${1:-comp}; HERE=$(cd "$(dirname "$0")" && pwd); COMP=$(cd "$COMP" && pwd)
T=$(mktemp -d); export STUB=$T/stub DD=$T/dd; mkdir -p $STUB $DD
export AWG_RUN=$T/run; mkdir -p "$AWG_RUN"
export PATH=$HERE/stubs2:$PATH
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
cat > $DD/awg.env <<ENV
TABLE=178
MARK=0x6a0000/0x7e0000
MAIN=awgmain
WANIF=
TUN_DOMAINS="openai.com"
DIRECT_DOMAINS="gosuslugi.ru"
DIRECT_SUBNETS="10.99.0.0/16"
EXTRA_SUBNETS="192.168.3.0/24"
ENV
G="bash $COMP/guard.sh"
ck "служба не включена — check: INFO, не FAIL" '$G check | grep -q "^INFO   awg-guard не включён" && ! $G check | grep -q "^FAIL"'
echo awg-guard > $DD/.units
# имитируем UniFi: в mangle PREROUTING уже есть её переход
iptables -t mangle -A PREROUTING -j UBIOS_PREROUTING_PBR
$G apply
ck "FORWARD: AWG_GUARD первой" 'iptables -S FORWARD | sed -n 2p | grep -q -- "-j AWG_GUARD"'
ck "DROP помеченного в eth3" 'iptables -S AWG_GUARD | grep -q -- "-o eth3 -m mark --mark 0x6a0000/0x7e0000 -j DROP"'
ck "ip6tables: REJECT помеченного" 'ip6tables -S AWG_GUARD | grep -q -- "-o eth3 -m mark --mark 0x6a0000/0x7e0000 -j REJECT"'
ck "ip6tables: REJECT клиентов VPN-сервера" 'ip6tables -S AWG_GUARD | grep -q -- "-i wgsrv1 -o eth3 -j REJECT"'
ck "домены: AWG_DOM_PRE первой в PREROUTING" 'iptables -t mangle -S PREROUTING | sed -n 2p | grep -q -- "-j AWG_DOM_PRE"'
ck "домены: маркировка из br+ по набору" 'iptables -t mangle -S AWG_DOM_PRE | grep -q -- "-i br+ -m set --match-set AWG_DOM dst -j MARK --set-xmark 0x6a0000/0x7e0000"'
ck "исключения: AWG_DIRECT_POST последней" 'iptables -t mangle -S PREROUTING | tail -n1 | grep -q -- "-j AWG_DIRECT_POST"'
ck "исключения: подсеть и набор снимают метку (и флаг kill switch 0x10000 — иначе blackhole UniFi)" 'iptables -t mangle -S AWG_DIRECT_POST | grep -q -- "-d 10.99.0.0/16 -j MARK --set-xmark 0x0/0x7f0000" && iptables -t mangle -S AWG_DIRECT_POST | grep -q -- "--match-set AWG_DIRECT dst -j MARK --set-xmark 0x0/0x7f0000"'
ck "наборы ipset созданы" 'grep -qx AWG_DOM $STUB/ipsets && grep -qx AWG_DIRECT $STUB/ipsets'
n1=$(iptables -S AWG_GUARD | wc -l); $G apply; $G apply
ck "идемпотентность (число правил не растёт)" '[ "$(iptables -S AWG_GUARD | wc -l)" = "$n1" ] && [ "$(iptables -t mangle -S PREROUTING | grep -c AWG_)" = 2 ]'
# UniFi добавила свой переход после нашего: исключения должны вернуться в конец
iptables -t mangle -A PREROUTING -j UBIOS_LATE
$G apply
ck "после перестановки UniFi исключения снова последние" 'iptables -t mangle -S PREROUTING | tail -n1 | grep -q -- "-j AWG_DIRECT_POST"'
# UniFi вставила своё правило в начало FORWARD
iptables -I FORWARD 1 -j UBIOS_FORWARD
$G apply
ck "после вставки UniFi AWG_GUARD снова первая" 'iptables -S FORWARD | sed -n 2p | grep -q -- "-j AWG_GUARD"'
out=$($G check); rc=$?
ck "check: без FAIL" '[ $rc = 0 ] && ! echo "$out" | grep -q "^FAIL"'
echo "$out" | sed 's/^/        /'
sed -i 's/^TUN_DOMAINS=.*/TUN_DOMAINS=""/; s/^DIRECT_DOMAINS=.*/DIRECT_DOMAINS=""/; s/^DIRECT_SUBNETS=.*/DIRECT_SUBNETS=""/' $DD/awg.env
$G apply
ck "домены выключены: правил маркировки нет" '! iptables -t mangle -S AWG_DOM_PRE | grep -q MARK'
# дополнительный маршрут (#22): его метка тоже не выпускается в WAN; IPv6 через туннель (#23) — защита IPv6 остаётся
mkdir -p $DD/route.d; printf 'RAIL_IF="wgclt2"\nMARK="0x6c0000/0x7e0000"\nTABLE="179"\nTUNNELS="awgmain"\n' > $DD/route.d/r2.env
printf 'LEAK_V6=route\n' >> $DD/awg.env
$G apply
ck "маршрут r2: DROP его метки в WAN (IPv4 и IPv6)" 'iptables -S AWG_GUARD | grep -q -- "-o eth3 -m mark --mark 0x6c0000/0x7e0000 -j DROP" && ip6tables -S AWG_GUARD | grep -q -- "-o eth3 -m mark --mark 0x6c0000/0x7e0000 -j REJECT"'
ck "IPv6 через туннель: REJECT помеченного IPv6 в WAN остаётся" 'ip6tables -S AWG_GUARD | grep -q -- "-o eth3 -m mark --mark 0x6a0000/0x7e0000 -j REJECT"'
# перехват DNS (#39): UniFi уже держит FORWARD и nat PREROUTING (её переход должен остаться первым в nat)
iptables -A FORWARD -j UBIOS_FORWARD_JUMP; iptables -t nat -A PREROUTING -j UBIOS_PREROUTING_JUMP
printf 'DNS_INTERCEPT=yes\n' >> $DD/awg.env; $G apply
ck "DNS: перехват последним в nat PREROUTING, после UniFi" 'iptables -t nat -S PREROUTING | sed -n 2p | grep -q UBIOS_PREROUTING_JUMP && iptables -t nat -S PREROUTING | tail -n1 | grep -q -- "-j AWG_DNS_PRE"'
ck "DNS: вся LAN, UDP и TCP, только к чужим адресам" 'iptables -t nat -S AWG_DNS_PRE | grep -q -- "-i br+ -p udp --dport 53 -m addrtype ! --dst-type LOCAL -j REDIRECT --to-ports 53" && iptables -t nat -S AWG_DNS_PRE | grep -q -- "-i br+ -p tcp --dport 53"'
ck "DNS: без DNS_BLOCK_DOT 853 не трогается" '! iptables -S FORWARD | grep -q AWG_DNS_FWD'
printf 'DNS_BLOCK_DOT=yes\n' >> $DD/awg.env; $G apply
ck "DoT: IPv6 DNS и DoT мимо роутера отклоняются (вся LAN)" 'ip6tables -S AWG_DNS_FWD | grep -q -- "-i br+ -p udp --dport 53 -j REJECT" && ip6tables -S AWG_DNS_FWD | grep -q -- "--dport 853" && iptables -S AWG_DNS_FWD | grep -q -- "-i br+ -p tcp --dport 853 -j REJECT"'
printf 'DNS_CLIENTS="192.168.1.50 192.168.1.64/28"\n' >> $DD/awg.env; $G apply
ck "DNS: только выбранные клиенты" 'iptables -t nat -S AWG_DNS_PRE | grep -q -- "-s 192.168.1.50 -p udp" && iptables -t nat -S AWG_DNS_PRE | grep -q -- "-s 192.168.1.64/28 -p tcp" && ! iptables -t nat -S AWG_DNS_PRE | grep -q "br+"'
ck "DoT: отказ 853 сразу после AWG_GUARD (защита остаётся первой)" 'iptables -S FORWARD | sed -n 2p | grep -q -- "-j AWG_GUARD" && iptables -S FORWARD | sed -n 3p | grep -q -- "-j AWG_DNS_FWD" && iptables -S AWG_DNS_FWD | grep -q -- "-s 192.168.1.50 -p tcp --dport 853 -j REJECT"'
ck "DoT: для выбранных клиентов правил IPv6 нет (их IPv6 неизвестны)" '! ip6tables -S FORWARD | grep -q AWG_DNS_FWD'
iptables -I FORWARD 1 -j UBIOS_X; $G apply >/dev/null
ck "DNS: порядок восстанавливается, переходы не двоятся" '[ "$(iptables -S FORWARD | grep -c -- "-j AWG_DNS_FWD")" = 1 ] && iptables -S FORWARD | sed -n 2p | grep -q AWG_GUARD && iptables -S FORWARD | sed -n 3p | grep -q AWG_DNS_FWD'
out=$($G check)
ck "check: DNS в отчёте" 'echo "$out" | grep -q "^OK     DNS устройств (192.168.1.50 192.168.1.64/28)" && echo "$out" | grep -q "^OK     DNS-over-TLS" && ! echo "$out" | grep -q "^FAIL"' || echo "$out"
sed -i 's/^DNS_INTERCEPT=.*/DNS_INTERCEPT=no/' $DD/awg.env; $G apply
ck "DNS выключен: цепочки убраны" '! iptables -t nat -S PREROUTING | grep -q AWG_ && ! iptables -S FORWARD | grep -q AWG_DNS_FWD && ! ip6tables -S FORWARD | grep -q AWG_DNS_FWD'
sed -i 's/^DNS_INTERCEPT=.*/DNS_INTERCEPT=yes/' $DD/awg.env; $G apply
# бюджет процессов (1.7.1): обычный проход службы (ничего не менялось) — не больше 5 внешних команд (в 1.7.0 — ~50)
SH=$T/shim; mkdir -p $SH; CNT=$T/execs.log
for c in date grep sed awk cat cut tr head tail sort wc mv rm mkdir stat sleep ip iptables ip6tables ipset md5sum flock logger; do
  printf '#!/bin/bash\necho %s >> "%s"\nIFS=: read -ra P <<< "$PATH"\nfor d in "${P[@]}"; do [ "$d" = "%s" ] && continue; [ -x "$d/%s" ] && exec "$d/%s" "$@"; done\nexit 127\n' \
    "$c" "$CNT" "$SH" "$c" "$c" > $SH/$c
done
chmod +x $SH/*
PATH=$SH:$PATH bash "$COMP/guard.sh" run > /dev/null 2>&1 &
GP=$!; sleep 2; : > $CNT; sleep 10; ng=$(grep -c . $CNT); np=$(grep -cx flock $CNT); kill -TERM $GP; wait $GP 2>/dev/null
ck "guard: обычный проход — не больше 5 внешних команд (проходов $np, команд $ng; $(sort $CNT | uniq -c | sort -rn | head -4 | awk '{printf "%s×%s ", $2, $1}'))" '[ "$np" -ge 1 ] && [ "$ng" -le $((5 * np)) ]'
$G remove
ck "remove: цепочек нет" '! iptables -S FORWARD | grep -q AWG_GUARD && ! iptables -t mangle -S PREROUTING | grep -q AWG_ && ! ip6tables -S FORWARD | grep -q AWG_GUARD && ! iptables -t nat -S PREROUTING | grep -q AWG_ && ! iptables -S FORWARD | grep -q AWG_DNS'
echo "guard: провалов $fails"; rm -rf $T; exit $fails
