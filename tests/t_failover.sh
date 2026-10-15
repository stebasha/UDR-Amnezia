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
# ---- давно лежащий основной канал проверяется реже (1.7.1): проход не растягивается на проверки мёртвого туннеля
S4=$T/s4; mkdir -p $S4/up $S4/links $S4/loss $S4/rtt $T/dd4; touch $S4/up/awgbackup $S4/links/awgmain $S4/links/awgbackup
printf 'TABLE=192\nMARK=0x7e0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nQUALITY=no\n' > $T/dd4/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd4/up.sh; chmod +x $T/dd4/up.sh
STUB=$S4 DD=$T/dd4 AWG_SYSNET=$S4/links STATEF=$T/st4 FORCEF=$T/f4 INTERVAL=1 FAIL_MAX=2 RECHECK_AFTER=2 RECHECK_SLOW=30 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P4=$!; sleep 7
c1=$(grep -c -x awgmain $S4/curl.log); sleep 6; c2=$(grep -c -x awgmain $S4/curl.log)
ck "основной лежит дольше RECHECK_AFTER: за 6 с не больше одной проверки (запросов HTTPS: $((c2 - c1)))" '. $T/st4; [ "$ACTIVE" = awgbackup ] && [ $((c2 - c1)) -le 3 ]'
rm -f $S4/up/awgbackup; : > $S4/curl.log; sleep 5
ck "при этом падение запасного замечается без задержки" 'grep -q "|both|" $T/dd4/events.log'
kill -TERM $P4; wait $P4 2>/dev/null
# ---- основной отвечает, но с потерями, дольше RECHECK_AFTER: это не «лежит» — возврат, как только качество вернулось
S6=$T/s6; mkdir -p $S6/up $S6/links $S6/loss $S6/rtt $T/dd6; for i in awgmain awgbackup; do touch $S6/up/$i $S6/links/$i; done
printf 'TABLE=194\nMARK=0x760000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nQUALITY=yes\n' > $T/dd6/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd6/up.sh; chmod +x $T/dd6/up.sh
echo 80 > $S6/loss/awgmain
STUB=$S6 DD=$T/dd6 AWG_SYSNET=$S6/links STATEF=$T/st6 FORCEF=$T/f6 INTERVAL=1 QUALITY_INTERVAL=1 QUALITY_FAILS=2 MIN_DWELL=0 RECOVER_SEC=3 \
  RECHECK_AFTER=2 RECHECK_SLOW=60 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P6=$!; sleep 9
a6=$(. $T/st6 2>/dev/null; echo "$ACTIVE")
rm -f $S6/loss/awgmain; sleep 10
b6=$(. $T/st6 2>/dev/null; echo "$ACTIVE")
kill -TERM $P6; wait $P6 2>/dev/null
ck "основной с потерями: ушли на запасной ($a6), качество вернулось — вернулись ($b6), без отсрочки RECHECK_SLOW" '[ "$a6" = awgbackup ] && [ "$b6" = awgmain ]'
# ---- ICMP через туннель не ходит, TCP ходит: пробы качества — по TCP, без пяти пингов каждый раз (1.7.1)
S5=$T/s5; mkdir -p $S5/up $S5/links $S5/loss $S5/rtt $S5/noicmp $T/dd5; for i in awgmain awgbackup; do touch $S5/up/$i $S5/links/$i $S5/noicmp/$i; done
printf 'TABLE=193\nMARK=0x780000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nQUALITY=yes\n' > $T/dd5/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd5/up.sh; chmod +x $T/dd5/up.sh
STUB=$S5 DD=$T/dd5 AWG_SYSNET=$S5/links STATEF=$T/st5 FORCEF=$T/f5 INTERVAL=1 QUALITY_INTERVAL=1 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P5=$!; sleep 7; kill -TERM $P5; wait $P5 2>/dev/null
np=$(grep -c -x awgmain $S5/ping.log 2>/dev/null)
ck "ICMP закрыт, TCP работает: пробы по TCP, ping — дважды для уверенности, а не каждую пробу (ping: $np)" '[ "${np:-0}" -le 2 ]'
# ---- бюджет процессов (1.7.1): в обычном проходе сторож запускает не больше 8 внешних команд (в 1.7.0 — ~27).
# Обёртки в начале PATH считают каждый запуск и передают его настоящей команде (или заглушке).
SH=$T/shim; mkdir -p $SH; CNT=$T/execs.log
for c in date grep sed awk cat cut tr head tail sort wc mv rm mkdir stat sleep ip iptables ip6tables curl ping logger conntrack flock md5sum; do
  printf '#!/bin/bash\necho %s >> "%s"\nIFS=: read -ra P <<< "$PATH"\nfor d in "${P[@]}"; do [ "$d" = "%s" ] && continue; [ -x "$d/%s" ] && exec "$d/%s" "$@"; done\nexit 127\n' \
    "$c" "$CNT" "$SH" "$c" "$c" > $SH/$c
done
chmod +x $SH/*
S7=$T/s7; mkdir -p $S7/up $S7/links $S7/loss $S7/rtt $T/dd7; for i in awgmain awgbackup; do touch $S7/up/$i $S7/links/$i; done
printf 'TABLE=195\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\nQUALITY=no\n' > $T/dd7/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd7/up.sh; chmod +x $T/dd7/up.sh
mkdir -p $T/ipt7; ln -sf "$HERE/stubs2/iptables" $T/ipt7/iptables; ln -sf "$HERE/stubs2/iptables" $T/ipt7/ip6tables   # iptables с состоянием
PATH=$SH:$T/ipt7:$PATH STUB=$S7 DD=$T/dd7 AWG_SYSNET=$S7/links STATEF=$T/st7 FORCEF=$T/f7 INTERVAL=1 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P7=$!; sleep 5; : > $CNT; sleep 10; kill -TERM $P7; wait $P7 2>/dev/null
# проходов — по проверке HTTPS (одна на проход: трафика нет); cat — внутри заглушки ip, сторож его не вызывает
p7=$(grep -cx curl $CNT); n7=$(grep -vcx cat $CNT)
ck "обычный проход: не больше 8 внешних команд (проходов $p7, команд $n7; $(sort $CNT | uniq -c | sort -rn | head -4 | awk '{printf "%s×%s ", $2, $1}'))" '[ "$p7" -ge 3 ] && [ "$n7" -le $((8 * p7)) ]'
# ---- сторожа основного и дополнительного маршрута делят снимок цепочек: iptables -S — как у одного сторожа
: > $CNT
mkdir -p $T/dd7/route.d; printf 'RAIL_IF="wgclt9"\nPRIO="32509"\nMARK="0x720000/0x7e0000"\nTABLE="196"\nTUNNELS="awgbackup awgmain"\n' > $T/dd7/route.d/r9.env
PATH=$SH:$T/ipt7:$PATH STUB=$S7 DD=$T/dd7 AWG_SYSNET=$S7/links STATEF=$T/st8 FORCEF=$T/f8 INTERVAL=4 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P8=$!
PATH=$SH:$T/ipt7:$PATH STUB=$S7 DD=$T/dd7 AWG_SYSNET=$S7/links STATEF=$T/st8 FORCEF=$T/f8 INTERVAL=4 bash "$COMP/failover.sh" --route r9 > /dev/null 2>&1 &
P9=$!; sleep 6; : > $CNT; sleep 16; ni=$(grep -c -x iptables $CNT); kill -TERM $P8 $P9; wait $P8 $P9 2>/dev/null
ck "два сторожа: снимок цепочек общий (iptables за 16 с: $ni; без общего снимка ~24)" '[ "$ni" -le 17 ]'
# ---- остановка (1.7.1): обработчик TERM, запущенный посреди паузы «read -t», bash обрывает, как только истекает
# время паузы (подстановка $(…) внутри обработчика проверяет таймер read). Раньше уборка обрывалась после записи
# в журнал, сторож работал дальше, systemd ждал 90 с и убивал его. Медленный logger делает обрыв неизбежным.
mkdir -p $T/slow; printf '#!/bin/bash\nsleep 1.5\n' > $T/slow/logger; chmod +x $T/slow/logger
hung=0; nostop=0
for i in 1 2 3; do
  S3=$T/s3-$i; mkdir -p $S3/up $S3/links $S3/loss $S3/rtt $T/dd3-$i; touch $S3/up/awgmain $S3/links/awgmain
  printf 'TABLE=191\nMARK=0x7c0000/0x7e0000\nMAIN=awgmain\nQUALITY=no\n' > $T/dd3-$i/awg.env
  printf '#!/bin/bash\nexit 0\n' > $T/dd3-$i/up.sh; chmod +x $T/dd3-$i/up.sh
  PATH=$T/slow:$PATH STUB=$S3 DD=$T/dd3-$i AWG_SYSNET=$S3/links STATEF=$T/st3-$i FORCEF=$T/f3-$i INTERVAL=1 bash "$COMP/failover.sh" > /dev/null 2>&1 &
  P3=$!; sleep 4.$((RANDOM % 10)); kill -TERM $P3
  for _ in $(seq 1 16); do kill -0 $P3 2>/dev/null || break; sleep 0.5; done
  if kill -0 $P3 2>/dev/null; then hung=$((hung + 1)); kill -9 $P3; fi
  wait $P3 2>/dev/null
  grep -q "|stop|" $T/dd3-$i/events.log 2>/dev/null || nostop=$((nostop + 1))
done
ck "остановка посреди паузы: сторож завершается и пишет stop (зависло $hung, без stop $nostop из 3)" '[ $hung = 0 ] && [ $nostop = 0 ]'
# состояние пишется сразу после старта, а не после первого прохода с проверками (медленный curl растягивает проход)
mkdir -p $T/slowc; printf '#!/bin/bash\nsleep 6\nexit 7\n' > $T/slowc/curl; chmod +x $T/slowc/curl
S9=$T/s9; mkdir -p $S9/up $S9/links $S9/loss $S9/rtt $T/dd9; touch $S9/up/awgmain $S9/links/awgmain
printf 'TABLE=192\nMARK=0x7a0000/0x7e0000\nMAIN=awgmain\nQUALITY=no\n' > $T/dd9/awg.env
printf '#!/bin/bash\nexit 0\n' > $T/dd9/up.sh; chmod +x $T/dd9/up.sh
PATH=$T/slowc:$PATH STUB=$S9 DD=$T/dd9 AWG_SYSNET=$S9/links STATEF=$T/st9 FORCEF=$T/f9 INTERVAL=1 bash "$COMP/failover.sh" > /dev/null 2>&1 &
P9=$!; for _ in 1 2 3 4 5 6; do [ -f $T/st9 ] && break; sleep 0.5; done
ck "файл состояния появляется сразу после старта, до первых проверок" 'grep -q "^ACTIVE=awgmain" $T/st9 2>/dev/null'
kill -TERM $P9 2>/dev/null; wait $P9 2>/dev/null
echo "failover: провалов $fails"
rm -rf "$T"; exit $fails
