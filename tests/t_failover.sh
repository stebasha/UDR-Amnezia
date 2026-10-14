#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# тест failover v2 на заглушках. Запуск: bash tests/t_failover.sh <путь к comp>
COMP=${1:-comp}; HERE=$(cd "$(dirname "$0")" && pwd); COMP=$(cd "$COMP" && pwd)
T=$(mktemp -d); export STUB=$T/stub DD=$T/dd
export AWG_RUN=$T/run; mkdir -p "$AWG_RUN"
mkdir -p $STUB/{up,links,loss,rtt} $DD
export PATH=$HERE/stubs:$PATH AWG_SYSNET=$STUB/links
export BOOT_WAIT=0 FORCEF=$T/force STATEF=$T/state SIM=$T/sim INTERVAL=1 FAIL_MAX=3 RECOVER_SEC=6 QUALITY_INTERVAL=2 MIN_DWELL=0 QUALITY_FAILS=2
printf '#!/bin/bash\ntouch %s/links/$1\n' $STUB > $DD/up.sh; chmod +x $DD/up.sh
cat > $DD/awg.env <<ENV
TABLE=178
MARK=0x6a0000/0x7e0000
MAIN=awgmain
BACKUP=awgbackup
TUNNELS_EXTRA="awgalt1"
ENV
for i in awgmain awgbackup awgalt1; do touch $STUB/links/$i $STUB/up/$i; done
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
active(){ . $T/state 2>/dev/null; echo "$ACTIVE"; }
bash $COMP/failover.sh > $T/out.log 2>&1 &
FP=$!
sleep 3
ck "старт на основном" '[ "$(active)" = awgmain ]'
rm $STUB/up/awgmain
sleep 6
ck "падение основного → запасной" '[ "$(active)" = awgbackup ]'
ck "событие switch в events.log" 'grep -q "|switch|" $DD/events.log'
ck "в журнале есть ПЕРЕКЛЮЧЕНИЕ (для awg-notify)" 'grep -q "ПЕРЕКЛЮЧЕНИЕ на запасной канал awgbackup" $DD/failover.log'
touch $STUB/up/awgmain
sleep 12
ck "возврат на основной через RECOVER_SEC" '[ "$(active)" = awgmain ]'
ck "в журнале есть ВОЗВРАТ" 'grep -q "ВОЗВРАТ на основной канал awgmain" $DD/failover.log'
echo awgalt1 > $FORCEF
sleep 3
ck "ручное переключение на awgalt1" '[ "$(active)" = awgalt1 ]'
ck "состояние FORCED=awgalt1" '. $T/state; [ "$FORCED" = awgalt1 ]'
rm -f $FORCEF
sleep 3
ck "авто-режим снят" '. $T/state; [ -z "$FORCED" ]'
sleep 9
ck "после auto вернулись на основной" '[ "$(active)" = awgmain ]'
echo awgnope > $FORCEF; sleep 2
ck "неизвестный туннель в force игнорируется" '[ ! -e $FORCEF ] && [ "$(active)" = awgmain ]'
# качество
echo 80 > $STUB/loss/awgmain
sleep 10
ck "деградация (потери 80%) → переход" '[ "$(active)" != awgmain ]'
ck "в журнале ДЕГРАДАЦИЯ" 'grep -q "ДЕГРАДАЦИЯ awgmain" $DD/failover.log'
ck "событие degrade" 'grep -q "|degrade|" $DD/events.log'
# падение всех
rm -f $STUB/up/*
sleep 6
ck "все каналы не отвечают: blackhole остаётся, событие both" 'grep -q "|both|" $DD/events.log && grep -q "blackhole default metric 200" $STUB/routes.log'
kill -TERM $FP; wait $FP 2>/dev/null
ck "остановка пишет stop" 'grep -q "|stop|" $DD/events.log'
ck "остановка: blackhole остаётся (kill switch на время перезапуска)" '! grep -q "blackhole" $STUB/routes-del.log 2>/dev/null'
ck "при переключении сброшен conntrack прежнего туннеля" 'grep -q -- "-D -q 10.9.0." $STUB/conntrack.log'
bash "$COMP/failover.sh" cleanup all
ck "cleanup all убирает и blackhole" 'grep -q "blackhole" $STUB/routes-del.log'

# ---- дополнительный маршрут (#22): своя таблица, своё состояние и ручной выбор; чужой активный туннель не сбрасывается
mkdir -p $DD/route.d
printf 'RAIL_IF="wgclt2"\nPRIO="32505"\nMARK="0x6c0000/0x7e0000"\nTABLE="179"\nTUNNELS="awgalt1 awgbackup"\nLABEL="США"\n' > $DD/route.d/r2.env
for i in awgmain awgbackup awgalt1; do touch $STUB/up/$i; done; rm -f $STUB/loss/*
: > $STUB/routes.log; : > $STUB/conntrack.log
echo "ACTIVE=awgalt1" > $T/rs                 # «основной маршрут» сейчас на awgalt1
STATEF=$T/rs FORCEF=$T/rf bash $COMP/failover.sh --route r2 > $T/r2.log 2>&1 &
RP=$!
sleep 3
ck "маршрут r2: старт на первом туннеле маршрута, своё состояние" '. $T/rs-r2; [ "$ACTIVE" = awgalt1 ] && [ "$ROUTE" = r2 ] && [ "$TABLE" = 179 ] && [ "$RAIL" = wgclt2 ]'
ck "маршрут r2: маршрут в своей таблице 179" 'grep -q "default dev awgalt1 metric 5 table 179" $STUB/routes.log && grep -q "blackhole default metric 200 table 179" $STUB/routes.log'
ck "маршрут r2: основной маршрут не тронут" '! grep -q "table 178" $STUB/routes.log'
echo awgbackup > $T/rf-r2; sleep 3
ck "маршрут r2: ручной выбор awgbackup" '. $T/rs-r2; [ "$ACTIVE" = awgbackup ] && [ "$FORCED" = awgbackup ]'
ck "маршрут r2: соединения awgalt1 не сброшены — им пользуется основной маршрут" '! grep -q -- "-D -q 10.9.0.7" $STUB/conntrack.log'
ck "маршрут r2: события с приставкой маршрута" 'grep -q "|force|маршрут r2: ручное переключение на awgbackup" $DD/events.log && grep -q "маршрут r2: " $DD/failover-r2.log'
echo "ACTIVE=awgmain" > $T/rs; : > $STUB/conntrack.log; echo awgalt1 > $T/rf-r2; sleep 3
ck "маршрут r2: прежний туннель, который больше никому не нужен, сброшен" 'grep -q -- "-D -q 10.9.0.9" $STUB/conntrack.log'
kill -TERM $RP; wait $RP 2>/dev/null
STATEF=$T/rs bash $COMP/failover.sh --route r2 cleanup all
ck "маршрут r2: cleanup all — только своя таблица" 'grep -q "blackhole default metric 200 table 179" $STUB/routes-del.log'
ck "маршрут: неизвестный ID — отказ" '! bash $COMP/failover.sh --route nope >/dev/null 2>&1 && ! bash $COMP/failover.sh --route "a;b" >/dev/null 2>&1'
# туннели «только для маршрутов» основной маршрут не использует
printf 'ROUTE_ONLY="awgalt1"\n' >> $DD/awg.env
STATEF=$T/ms bash $COMP/failover.sh > $T/m.log 2>&1 &
MP=$!; sleep 3; kill -TERM $MP; wait $MP 2>/dev/null
ck "ROUTE_ONLY: основной маршрут без awgalt1" 'grep -q "^TUNNELS=\"awgmain awgbackup\"" $T/ms 2>/dev/null || grep -q "туннели awgmain awgbackup," $DD/failover.log'
sed -i '/^ROUTE_ONLY=/d' $DD/awg.env
# ---- IPv6 через туннель (#23): у awgbackup есть IPv6, у awgmain нет
mkdir -p $STUB/v6; touch $STUB/v6/awgbackup; : > $STUB/routes6.log; : > $STUB/rule6.log
printf 'LEAK_V6=route\n' >> $DD/awg.env
STATEF=$T/v6s FORCEF=$T/v6f bash $COMP/failover.sh > $T/v6.log 2>&1 &
VP=$!; sleep 3
ck "IPv6: правило PBR IPv6 для метки (proto 99)" 'grep -q "rule add fwmark 0x6a0000/0x7e0000 lookup 178 priority 32504 proto 99" $STUB/rule6.log'
ck "IPv6: у awgmain нет IPv6 — unreachable, IPv6-маршрута на него нет" 'grep -q "route replace unreachable default metric 200 table 178" $STUB/routes6.log && ! grep -q "replace default dev awgmain" $STUB/routes6.log'
ck "IPv6: NAT66 на туннелях" 'grep -q -- "-t nat -I POSTROUTING -o awgbackup -j MASQUERADE" $STUB/ip6tables.log'
echo awgbackup > $T/v6f; sleep 3
ck "IPv6: на awgbackup (есть IPv6) — маршрут IPv6 через туннель" 'grep -q "route replace default dev awgbackup metric 5 table 178" $STUB/routes6.log'
kill -TERM $VP; wait $VP 2>/dev/null
sed -i '/^LEAK_V6=/d' $DD/awg.env; printf 'rule 32504: from all fwmark 0x6a0000/0x7e0000 lookup 178 proto 99\n' > $STUB/rule6
STATEF=$T/v6s bash $COMP/failover.sh > $T/v6b.log 2>&1 &
VP=$!; sleep 2; kill -TERM $VP; wait $VP 2>/dev/null
ck "IPv6 выключен: своё правило IPv6 убирается, маршруты UniFi в таблице не трогаются" 'grep -q "rule del fwmark 0x6a0000/0x7e0000 lookup 178 priority 32504 proto 99" $STUB/rule6-del.log && ! grep -q "flush" $STUB/routes6.log'

# ---- экономия (1.7.1): живой трафик заменяет HTTPS-проверку; верная таблица не переписывается каждый проход
S2=$T/s2; mkdir -p $S2/up $S2/links/awgmain/statistics $S2/links/awgbackup/statistics $S2/loss $S2/rtt $T/dd2
for i in awgmain awgbackup; do touch $S2/up/$i; echo 0 > $S2/links/$i/statistics/rx_bytes; done
printf 'TABLE=190\nMARK=0x7a0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nQUALITY=no\n' > $T/dd2/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd2/up.sh; chmod +x $T/dd2/up.sh
( while :; do v=$(cat $S2/links/awgmain/statistics/rx_bytes); [ -e $S2/flow ] && echo $((v + 50000)) > $S2/links/awgmain/statistics/rx_bytes; sleep 0.3; done ) & RXP=$!
touch $S2/flow
STUB=$S2 DD=$T/dd2 AWG_SYSNET=$S2/links STATEF=$T/state2 FORCEF=$T/force2 CHECK_RX_MIN=10000 CHECK_MAX_AGE=60 bash "$COMP/failover.sh" > $T/out2.log 2>&1 &
FP2=$!
sleep 4
c1=$(grep -c -x awgmain $S2/curl.log); r1=$(grep -c "route replace" $S2/routes.log)
sleep 4
c2=$(grep -c -x awgmain $S2/curl.log); r2=$(grep -c "route replace" $S2/routes.log)
ck "трафик идёт: HTTPS-проверок основного не прибавилось" '[ "$c2" -le "$((c1 + 0))" ]'
ck "таблица верная: маршрут не переписывается каждый проход" '[ "$r2" = "$r1" ]'
rm -f $S2/flow $S2/up/awgmain
sleep 6
ck "трафик оборвался и канал лёг: переход на запасной без задержки" '. $T/state2; [ "$ACTIVE" = awgbackup ]'
kill $RXP 2>/dev/null; kill -TERM $FP2; wait $FP2 2>/dev/null
# сторож маршрута только что проверил тот же туннель — его успех засчитывается без второго запроса HTTPS
touch $S2/up/awgmain; rm -f $T/state2; : > $S2/curl.log
( while :; do printf '%(%s)T\n' -1 > $AWG_RUN/awg-chk-awgmain; sleep 0.3; done ) & CKP=$!
STUB=$S2 DD=$T/dd2 AWG_SYSNET=$S2/links STATEF=$T/state2 FORCEF=$T/force2 CHECK_RX_MIN=0 INTERVAL=5 bash "$COMP/failover.sh" > $T/out3.log 2>&1 &
FP3=$!; sleep 8
# за два прохода — только проба DNS (раз в минуту), без проверок HTTPS
ck "свежая проверка другого сторожа: свой запрос HTTPS не нужен" '[ "$(grep -cx awgmain $S2/curl.log)" -le 1 ] && . $T/state2 && [ "$ACTIVE" = awgmain ]'
kill $CKP 2>/dev/null; kill -TERM $FP3; wait $FP3 2>/dev/null; rm -f $AWG_RUN/awg-chk-awgmain
# состояние не меняется — файл не переписывается каждый проход (раз в 10 с — «сердцебиение»)
rm -f $T/state2
STUB=$S2 DD=$T/dd2 AWG_SYSNET=$S2/links STATEF=$T/state2 FORCEF=$T/force2 CHECK_RX_MIN=0 INTERVAL=1 bash "$COMP/failover.sh" > $T/out4.log 2>&1 &
FP4=$!; sleep 2; : > $T/inodes
for _ in $(seq 12); do stat -c %i $T/state2 >> $T/inodes 2>/dev/null; sleep 0.5; done
ck "состояние без изменений: файл не переписывается каждый проход" '[ "$(sort -u $T/inodes | wc -l)" -le 2 ] && . $T/state2 && [ "$ACTIVE" = awgmain ] && [ -n "$UPDATED" ]'
kill -TERM $FP4; wait $FP4 2>/dev/null
echo "failover: провалов $fails"
rm -rf "$T"; exit $fails
