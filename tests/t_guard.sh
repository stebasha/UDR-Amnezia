#!/bin/bash
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
ck "исключения: подсеть и набор снимают метку" 'iptables -t mangle -S AWG_DIRECT_POST | grep -q -- "-d 10.99.0.0/16 -j MARK --set-xmark 0x0/0x7e0000" && iptables -t mangle -S AWG_DIRECT_POST | grep -q -- "--match-set AWG_DIRECT dst -j MARK --set-xmark 0x0/0x7e0000"'
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
$G remove
ck "remove: цепочек нет" '! iptables -S FORWARD | grep -q AWG_GUARD && ! iptables -t mangle -S PREROUTING | grep -q AWG_ && ! ip6tables -S FORWARD | grep -q AWG_GUARD'
echo "guard: провалов $fails"; rm -rf $T; exit $fails
