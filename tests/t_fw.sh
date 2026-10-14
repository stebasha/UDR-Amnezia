#!/bin/bash
# shellcheck disable=SC2034,SC1090  # переменные используются в строках для eval (проверки t/ck), источники — заглушки
# Правила iptables под нагрузкой: дубликаты, занятая блокировка xtables, удаление туннеля.
# Запуск: bash tests/t_fw.sh <папка awg>
H=$(cd "$(dirname "$0")" && pwd)
COMP=$(cd "${1:?укажите папку awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWG_RUN=$T/run; mkdir -p "$AWG_RUN"
export STUB=$T/stub DD=$T/dd; mkdir -p "$STUB" "$DD"
export PATH="$H/stubs2:$PATH"
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nWANIF=eth3\nLEAK_GUARD=yes\nLEAK_V6=block\n' > "$DD/awg.env"
cnt(){ iptables -t "$1" -S 2>/dev/null | grep -c -x -F -- "$2"; }

# --- dedup: накопленные копии (как у версий без -w) убираются, одна остаётся
for k in 1 2 3; do iptables -t nat -A POSTROUTING -o awgmain -j MASQUERADE; done
for k in 1 2; do iptables -A FORWARD -o awgbackup -j ACCEPT; done
iptables -A FORWARD -o eth3 -j ACCEPT; iptables -A FORWARD -o eth3 -j ACCEPT      # чужие дубли не трогаем
out=$(bash "$COMP/failover.sh" dedup)
ck "dedup: убрано 3 копии" '[ "$out" = "убрано дубликатов: 3" ]'
ck "dedup: MASQUERADE awgmain осталось одно" '[ "$(cnt nat "-A POSTROUTING -o awgmain -j MASQUERADE")" = 1 ]'
ck "dedup: FORWARD awgbackup осталось одно" '[ "$(cnt filter "-A FORWARD -o awgbackup -j ACCEPT")" = 1 ]'
ck "dedup: чужие правила не тронуты" '[ "$(cnt filter "-A FORWARD -o eth3 -j ACCEPT")" = 2 ]'
ck "dedup: повторный запуск ничего не меняет" '[ "$(bash "$COMP/failover.sh" dedup)" = "убрано дубликатов: 0" ]'

# --- блокировка xtables занята: ensure не добавляет и не удаляет
source <(sed -n '/^iptables(){/p;/^ensure(){/p' "$COMP/failover.sh")
touch "$STUB/locked"
ensure nat -I POSTROUTING -o awgx -j MASQUERADE
rm -f "$STUB/locked"
ck "ensure при занятой блокировке ничего не добавил" '[ "$(cnt nat "-A POSTROUTING -o awgx -j MASQUERADE")" = 0 ]'
ensure nat -I POSTROUTING -o awgx -j MASQUERADE; ensure nat -I POSTROUTING -o awgx -j MASQUERADE
ck "ensure добавляет ровно одно правило" '[ "$(cnt nat "-A POSTROUTING -o awgx -j MASQUERADE")" = 1 ]'

# --- forget: все правила удалённого туннеля
for r in "nat|POSTROUTING -o awgbackup -j MASQUERADE" "mangle|FORWARD -o awgbackup -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" "filter|FORWARD -i awgbackup -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"; do
  iptables -t "${r%%|*}" -A ${r#*|}; iptables -t "${r%%|*}" -A ${r#*|}
done
bash "$COMP/failover.sh" forget awgbackup
ck "forget: правил awgbackup не осталось" '! iptables -t nat -S | grep -q awgbackup && ! iptables -t mangle -S | grep -q awgbackup && ! iptables -S | grep -q awgbackup'
ck "forget: правила awgmain целы" '[ "$(cnt nat "-A POSTROUTING -o awgmain -j MASQUERADE")" = 1 ]'

# --- guard: занятая блокировка не ломает цепочки и не плодит переходы
bash "$COMP/guard.sh" apply
ck "guard: один переход в FORWARD" '[ "$(cnt filter "-A FORWARD -j AWG_GUARD")" = 1 ]'
touch "$STUB/locked"; bash "$COMP/guard.sh" apply; rm -f "$STUB/locked"
bash "$COMP/guard.sh" apply
ck "guard после занятой блокировки: переход по-прежнему один и первый" '[ "$(cnt filter "-A FORWARD -j AWG_GUARD")" = 1 ] && [ "$(iptables -S FORWARD | grep "^-A" | head -n1)" = "-A FORWARD -j AWG_GUARD" ]'
iptables -I FORWARD 1 -j AWG_GUARD                       # второй переход (как от гонки)
bash "$COMP/guard.sh" apply
ck "guard: лишний переход убран" '[ "$(cnt filter "-A FORWARD -j AWG_GUARD")" = 1 ]'
iptables -F AWG_GUARD; iptables -X AWG_GUARD               # UniFi удалил нашу цепочку
bash "$COMP/guard.sh" apply 2>/dev/null; sleep 0; bash "$COMP/guard.sh" run >/dev/null 2>&1 & GP=$!; sleep 2; kill $GP 2>/dev/null; wait $GP 2>/dev/null
ck "guard: удалённая цепочка восстановлена службой" 'iptables -S AWG_GUARD 2>/dev/null | grep -q -- "-o eth3 -m mark --mark 0x6a0000/0x7e0000 -j DROP"'
( bash "$COMP/guard.sh" apply & bash "$COMP/guard.sh" apply & wait )
ck "guard: два одновременных запуска не дают дублей в цепочке" '[ "$(iptables -S AWG_GUARD | grep -c -- "-o eth3 -m mark")" = 1 ]'

# --- awg-self: цепочка собирается целиком, занятая блокировка не оставляет полупустую цепочку
printf 'UI_FIX=no\n' >> "$DD/awg.env"
iptables -t mangle -N UBIOS_PREROUTING_PBR
iptables -t mangle -A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set PBR_DST dst -j MARK --set-xmark 0x6a0000/0x7e0000
iptables -t mangle -A UBIOS_PREROUTING_PBR -m mac --mac-source aa:bb:cc:dd:ee:ff -j MARK --set-xmark 0x6a0000/0x7e0000
iptables -t mangle -A OUTPUT -j UBIOS_OUTPUT_JUMP
bash "$COMP/self.sh" apply >/dev/null 2>&1
ck "self: переход AWG_SELF первым в mangle OUTPUT" '[ "$(iptables -t mangle -S OUTPUT | grep "^-A" | head -n1)" = "-A OUTPUT -j AWG_SELF" ]'
ck "self: ответы на входящие соединения не уходят в туннель" 'iptables -t mangle -S AWG_SELF | grep -q -- "--ctdir REPLY -j RETURN"'
ck "self: DHCP и широковещание мимо туннеля" 'iptables -t mangle -S AWG_SELF | grep -q -- "--dport 67:68 -j RETURN" && iptables -t mangle -S AWG_SELF | grep -q -- "-d 255.255.255.255/32 -j RETURN"'
ck "self: правило PBR по адресам назначения повторено для роутера" 'iptables -t mangle -S AWG_SELF | grep -q -- "-m set --match-set PBR_DST dst -j MARK"'
ck "self: правило PBR по MAC клиента не повторяется" '! iptables -t mangle -S AWG_SELF | grep -q -- "--mac-source"'
n0=$(iptables -t mangle -S AWG_SELF | wc -l)
iptables -t mangle -I OUTPUT 1 -j AWG_SELF                     # лишний переход (как от гонки)
bash "$COMP/self.sh" apply >/dev/null 2>&1
ck "self: лишний переход убран" '[ "$(cnt mangle "-A OUTPUT -j AWG_SELF")" = 1 ]'
touch "$STUB/locked"; bash "$COMP/self.sh" apply >/dev/null 2>&1; rm -f "$STUB/locked"
ck "self: после занятой блокировки цепочка цела" '[ "$(iptables -t mangle -S AWG_SELF | wc -l)" = "$n0" ] && [ "$(cnt mangle "-A OUTPUT -j AWG_SELF")" = 1 ]'
ck "self: временных цепочек не осталось" '! iptables -t mangle -S AWG_SELF_NEW >/dev/null 2>&1 && ! iptables -t mangle -S AWG_SELF_OLD >/dev/null 2>&1'
printf 'TUN_DOMAINS="good.com bad;rm x/y"\n' >> "$DD/awg.env"
source <(sed -n '/^valid_domain(){/p;/^domains(){/p;/^log(){/p' "$COMP/self.sh")
ck "self: в файл dnsmasq попадают только корректные домены" '[ "$(domains good.com "bad;rm" x/y | tr "\n" " ")" = "good.com " ]'
# --- self (1.7.1): быстрый разбор правил UniFi совпадает с прежним конвейером; время старта процесса — без awk
cat > "$T/mg" <<'MG'
-P PREROUTING ACCEPT
-N UBIOS_PREROUTING_PBR
-A PREROUTING -j UBIOS_PREROUTING_JUMP
-A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_trafficroute_clients_13 src -m set --match-set UBIOS_trafficroute_dn_13 dst -m comment --comment 00000001095216670481 -j MARK --set-xmark 0x6c0000/0x7e0000
-A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_ip_6 dst -m comment --comment 00000001095216670482 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_ip_6 dst -j RETURN
-A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_network src -m set --match-set UBIOS_trafficroute_dn_1 dst -m comment --comment 00000001095216670484 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -m set --match-set UBIOS_local_networkv6 src -m set --match-set UBIOS_trafficroute_dn_1 dst -m comment --comment 00000001095216670499 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -m mac --mac-source aa:bb:cc:dd:ee:ff -m comment --comment 1 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -i br20 -m comment --comment 2 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -s 192.168.1.50/32 -m comment --comment 3 -j MARK --set-xmark 0x6a0000/0x7e0000
-A UBIOS_PREROUTING_PBR -d 203.0.113.0/24 -m comment --comment 4 -j MARK --set-xmark 0x6a0000/0x7e0000
MG
mkdir -p "$T/mgbin"; printf '#!/bin/bash\ncat "%s/mg"\n' "$T" > "$T/mgbin/iptables"; chmod 755 "$T/mgbin/iptables"
source <(sed -n '/^want(){/,/^}/p;/^want_from(){/,/^}/p;/^pstart(){/,/^}/p;/^pstart_v(){/,/^}/p' "$COMP/self.sh")
old_w=$(PATH="$T/mgbin:$PATH"; want); want_from "$(cat "$T/mg")"
ck "self: want_from совпадает с прежним want (правила как на роутере)" '[ "$W" = "$old_w" ] && [ "$(printf "%s\n" "$W" | wc -l)" = 3 ]' || printf '%s\n---\n%s\n' "$old_w" "$W"
HZ=$(getconf CLK_TCK); pstart_v pv $$
ck "self: время старта процесса — как у прежнего pstart" '[ "$pv" = "$(pstart $$)" ]'
echo "fw: провалов $fails"; [ $fails = 0 ]
