#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# Автоподбор обфускации (#33) на заглушках: «провайдер» пропускает только наборы с Jc < 10, скорость тем выше,
# чем меньше Jmax; режим server — через поддельный vps.sh. Запуск: bash tests/t_tune.sh <папка awg>
SRC=$(cd "${1:-$(dirname "$0")/../awg}" && pwd)
T=${KEEP_T:-$(mktemp -d)}; [ -z "$KEEP_T" ] && trap 'rm -rf "$T"' EXIT
export DD=$T/dd STATEF=$T/run/awg-state AWG_RUN=$T/run TUNE_WAIT=2 STUB=$T/stub
mkdir -p "$DD" "$T/run" "$T/bin" "$STUB"
cp "$SRC/obfs-tune.sh" "$DD/"; chmod 755 "$DD/obfs-tune.sh"
printf 'MAIN=awgmain\nBACKUP=awgbackup\n' > "$DD/awg.env"
for t in main backup; do printf '[Interface]\nPrivateKey = k\nAddress = 10.8.1.2/32\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 30\nS2 = 40\nH1 = 1111\nH2 = 2222\nH3 = 3333\nH4 = 4444\n\n[Peer]\nPublicKey = p\nEndpoint = 203.0.113.9:51823\n' > "$DD/$t.conf"; done
cat > "$DD/up.sh" <<'S'
#!/bin/bash
f=$( [ "$2" = awgmain ] && echo main.conf || echo backup.conf ); [ "$1" = --conf-of ] && { echo "$f"; exit 0; }
cp "$DD/$( [ "$1" = awgmain ] && echo main.conf || echo backup.conf )" "$STUB/applied.$1"; date +%s > "$STUB/up.$1"; echo "up $1" >> "$STUB/up.log"
S
cat > "$DD/awg" <<'S'
#!/bin/bash
[ "$1" = show ] || exit 0
jc=$(awk -F' = ' '$1=="Jc"{print $2; exit}' "$STUB/applied.$2" 2>/dev/null)
if [ -n "$jc" ] && [ "$jc" -lt 10 ]; then echo "PUB	$(( $(cat "$STUB/up.$2" 2>/dev/null || date +%s) + 1 ))"; else echo "PUB	0"; fi
S
cat > "$T/bin/curl" <<'S'
#!/bin/bash
i=""; u=""; w=""; while [ $# -gt 0 ]; do case "$1" in --interface) i=$2; shift;; -w) w=$2; shift;; http*) u=$1;; esac; shift; done
jc=$(awk -F' = ' '$1=="Jc"{print $2; exit}' "$STUB/applied.$i" 2>/dev/null); jmax=$(awk -F' = ' '$1=="Jmax"{print $2; exit}' "$STUB/applied.$i" 2>/dev/null)
{ [ -n "$jc" ] && [ "$jc" -lt 10 ]; } || { printf 000; exit 28; }
case "$w" in *speed_download*) echo $(( 100000000 / (jmax + 30) ));; *time_connect*) echo 0.050;; *) printf 200;; esac
S
printf '#!/bin/bash\necho "10 packets transmitted, 10 received, 0%% packet loss, time 1ms"\necho "rtt min/avg/max/mdev = 1.0/20.0/30.0/1.0 ms"\n' > "$T/bin/ping"
cat > "$DD/vps.sh" <<'S'
#!/bin/bash
echo "vps.sh $*" >> "$STUB/vps.log"
[ "$1" = list ] && { printf 'main\t203.0.113.9\t22\troot\t\n'; exit 0; }
[ "$1" = --vps ] && shift 2
case "$1" in
  tunnels) echo awgbackup;;
  obfs) f=""; while [ $# -gt 0 ]; do [ "$1" = --file ] && f=$2; shift; done
        jc=$(awk -F' = ' '$1=="Jc"{print $2}' "$f"); [ "$jc" -ge 8 ] && { echo "✘ не заработало, откат"; exit 1; }
        while IFS=' = ' read -r k v; do sed -i "s/^$k = .*/$k = $v/" "$DD/backup.conf"; done < <(sed 's/ = /=/' "$f" | tr '=' ' ')
        "$DD/up.sh" awgbackup; echo "✔ работает";;
esac
S
chmod 755 "$DD/up.sh" "$DD/awg" "$DD/vps.sh" "$T"/bin/*; export PATH="$T/bin:$PATH"
"$DD/up.sh" awgmain; "$DD/up.sh" awgbackup
echo "ACTIVE=awgmain" > "$STATEF"
TN=$DD/obfs-tune.sh; fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }

ck "активный канал без --active — отказ, конфиг не тронут" '! "$TN" run awgmain client 2 > $T/o && grep -q "активный канал" $T/o && grep -q "^Jc = 4" $DD/main.conf'
ck "неизвестный туннель и режим — отказ" '! "$TN" run awgxx >/dev/null && ! "$TN" run awgbackup turbo >/dev/null && ! "$TN" run awgbackup client 99 >/dev/null'
cp $DD/backup.conf $T/bk0
"$TN" run awgbackup client 6 > $T/r1 2>&1; rc=$?
ck "client: подбор прошёл, текущий + 6 наборов в tune.tsv" '[ $rc = 0 ] && [ "$(grep -vc "^#" $DD/tune.tsv)" = 7 ] && head -n1 $DD/tune.tsv | grep -q "^# awgbackup	client"' || cat $T/r1
ck "client: Jc 10 (набор 5) провайдер режет — «не работает», оценка 0" 'awk -F"\t" "\$1==5" $DD/tune.tsv | grep -q "^5	0	"'
ck "client: рабочие наборы с потерями, задержкой, скоростью и оценкой" 'awk -F"\t" "\$1==1" $DD/tune.tsv | awk -F"\t" "\$2==1 && \$4==0 && \$5==20 && \$6>0 && \$7>0" | grep -q .'
ck "client: лучший — самый быстрый рабочий (Jmax 50)" 'grep -q "лучший набор №1 " $T/r1'
ck "client: в конце исходный конфиг на месте, сервер не трогался" 'cmp -s $DD/backup.conf $T/bk0 && cmp -s $STUB/applied.awgbackup $T/bk0 && [ ! -e $STUB/vps.log ] && [ ! -e $DD/backup.conf.pre-tune ]'
ck "client: S1/S2/H не менялись ни в одном наборе" '! awk -F"\t" "!/^#/ {print \$8}" $DD/tune.tsv | grep -q -E "S1|H1"'
ck "события" 'grep -q "|tune|подбор обфускации awgbackup: начат" $DD/events.log && grep -q "лучший №1" $DD/events.log'
ck "apply: нерабочий набор не ставится" '! "$TN" apply 5 > $T/o && grep -q "не заработал" $T/o && cmp -s $DD/backup.conf $T/bk0'
"$TN" apply 1 > $T/o 2>&1
ck "apply 1: Jc/Jmin/Jmax набора на роутере, туннель работает" '[ $? = 0 ] && grep -q "^Jc = 3" $DD/backup.conf && grep -q "^Jmax = 50" $DD/backup.conf && grep -q "^S1 = 30" $DD/backup.conf'
cp $T/bk0 $DD/backup.conf; "$DD/up.sh" awgbackup
"$TN" run awgbackup server 3 > $T/r2 2>&1; rc=$?
ck "server: через vps.sh obfs --file, без уведомлений и копий" '[ $rc = 0 ] && grep -q "obfs awgbackup --file" $STUB/vps.log && head -n1 $DD/tune.tsv | grep -q "server	[0-9]*	main"' || cat $T/r2
ck "server: S1/S2/H1–H4 в наборах, в конце исходный набор на обеих сторонах" 'awk -F"\t" "\$1==1 {print \$8}" $DD/tune.tsv | grep -q "S1=.*H4=" && grep -q "^S1 = 30" $DD/backup.conf && grep -q "^H4 = 4444" $DD/backup.conf'
printf '[Interface]\nPrivateKey = k\nAddress = 10.8.1.2/32\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 100-200\n\n[Peer]\nPublicKey = p\n' > $DD/backup.conf
ck "server: AWG 2.0/3.x (диапазоны H) — отказ с подсказкой client" '! "$TN" run awgbackup server 2 > $T/o && grep -q "используйте client" $T/o'
# прерванный подбор (остановка, срок задачи) возвращает исходный набор; канал стал активным — подбор прекращается
cp $DD/backup.conf $T/bk1
TUNE_WAIT=3 "$TN" run awgbackup client 6 > $T/r3 2>&1 & TP=$!
sleep 5; kill -TERM $TP; wait $TP 2>/dev/null
ck "прерванный подбор: исходный набор возвращён и применён, копия убрана" 'cmp -s $DD/backup.conf $T/bk1 && cmp -s $STUB/applied.awgbackup $T/bk1 && [ ! -e $DD/backup.conf.pre-tune ] && grep -q "подбор прерван" $T/r3'
"$TN" run awgbackup client 6 > $T/r4 2>&1 & TP=$!
sleep 4; echo "ACTIVE=awgbackup" > "$STATEF"; wait $TP
ck "туннель стал активным посреди подбора: подбор прекращён, исходный набор на месте" 'grep -q "стал активным каналом: подбор прекращён" $T/r4 && cmp -s $DD/backup.conf $T/bk1 && [ "$(grep -vc "^#" $DD/tune.tsv)" -lt 7 ]'
echo "ACTIVE=awgmain" > "$STATEF"
# режим xui (#37): через panel.py xui-obfs (заглушка: Jc ≥ 8 «не заработало», иначе ставит набор в конфиг)
mkdir -p "$DD/web"; cat > "$DD/web/panel.py" <<'S'
#!/usr/bin/env python3
import os, sys, subprocess
dd = os.environ["DD"]; open(os.path.join(os.environ["STUB"], "xui.log"), "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "xui-obfs-check":
    if sys.argv[2] != "awgbackup": print("ОШИБКА: подключение обслуживает не только роутер"); sys.exit(2)
    print("ok"); sys.exit(0)
kv = dict(x.split("=", 1) for x in sys.argv[3].split())
if int(kv["Jc"]) >= 8: print("handshake нет: обе стороны возвращены"); sys.exit(1)
f = os.path.join(dd, "backup.conf"); t = open(f).read().splitlines()
t = [("%s = %s" % (l.split(" = ")[0], kv[l.split(" = ")[0]])) if " = " in l and l.split(" = ")[0] in kv else l for l in t]
open(f, "w").write("\n".join(t) + "\n"); subprocess.call([os.path.join(dd, "up.sh"), "awgbackup"]); print("ок")
S
chmod 755 "$DD/web/panel.py"; cp $T/bk0 $DD/backup.conf; "$DD/up.sh" awgbackup
ck "xui: общее подключение — отказ до подбора" '! "$TN" run awgmain xui 2 --active > $T/o && grep -q "не только роутер" $T/o && grep -q "^Jc = 4" $DD/main.conf'
"$TN" run awgbackup xui 3 > $T/r5 2>&1; rc=$?
ck "xui: подбор через 3x-ui (пробы --trial, H — диапазоны), в конце исходный набор" '[ $rc = 0 ] && grep -q "xui-obfs awgbackup .*H1=[0-9]*-[0-9]* .*--trial" $STUB/xui.log && head -n1 $DD/tune.tsv | grep -q "awgbackup	xui" && grep -q "^Jc = 4" $DD/backup.conf && grep -q "^H1 = 1111" $DD/backup.conf && tail -n1 $STUB/xui.log | grep -q "Jc=4 .*H4=4444 --trial"' || cat $T/r5
n=$(awk -F'\t' '!/^#/ && $2==1 && $1>0 {print $1; exit}' $DD/tune.tsv)
# набор на роутере — по H1: у новых наборов это диапазон, у исходного — число (Jc у нового может случайно совпасть с исходным)
if [ -n "$n" ]; then "$TN" apply "$n" > $T/o 2>&1; arc=$?; ck "xui: apply — без --trial (с историей), набор на роутере" '[ $arc = 0 ] && tail -n1 $STUB/xui.log | grep -vq -- "--trial" && grep -q "^H1 = [0-9]*-[0-9]*$" $DD/backup.conf' || cat $T/o; fi
echo "== tune: ошибок $fails"
[ $fails = 0 ]
