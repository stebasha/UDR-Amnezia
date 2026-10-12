#!/bin/bash
# тест failover v2 на заглушках. Запуск: bash tests/t_failover.sh <путь к comp>
COMP=${1:-comp}; HERE=$(cd "$(dirname "$0")" && pwd); COMP=$(cd "$COMP" && pwd)
T=$(mktemp -d); export STUB=$T/stub DD=$T/dd
export AWG_RUN=$T/run; mkdir -p "$AWG_RUN"
mkdir -p $STUB/{up,links,loss,rtt} $DD
export PATH=$HERE/stubs:$PATH
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
echo "failover: провалов $fails"
rm -rf "$T"; exit $fails
