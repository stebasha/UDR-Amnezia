#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# Маршруты (#22) на заглушках: профили PBR UniFi (ip rule), службы (systemctl), awg.env и .units.
# Запуск: bash tests/t_routes.sh <папка awg>
SRC=$(cd "${1:-$(dirname "$0")/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd SYSD=$T/sysd STATEF=$T/run/awg-state FORCEF=$T/run/awg-force ROUTE_SETTLE=0
mkdir -p "$DD" "$SYSD" "$T/run" "$T/bin"
cp "$SRC/routes.sh" "$DD/"; chmod 755 "$DD/routes.sh"
printf '#!/bin/bash\necho "failover $*" >> "%s/failover.log"\n' "$T" > "$DD/failover.sh"; chmod 755 "$DD/failover.sh"
cat > "$T/bin/ip" <<'S'
#!/bin/bash
[ "$1 $2 $3" = "-4 rule show" ] && printf '32504:\tfrom all fwmark 0x6a0000/0x7e0000 lookup 178.wgclt1\n32505:\tfrom all fwmark 0x6c0000/0x7e0000 lookup 179.wgclt2\n32506:\tfrom all fwmark 0x6e0000/0x7e0000 lookup 180.wgclt3\n'
exit 0
S
printf '#!/bin/bash\necho "systemctl $*" >> "%s/systemctl.log"\n[ "$1" = is-active ] && echo active\nexit 0\n' "$T" > "$T/bin/systemctl"
chmod 755 "$T"/bin/*; export PATH="$T/bin:$PATH"
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nRAIL_IF=wgclt1\nMAIN=awgmain\nBACKUP=awgbackup\nTUNNELS_EXTRA="awgus awgde"\n' > "$DD/awg.env"
R=$DD/routes.sh; fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }

ck "rails: профили с правилами PBR, основной помечен" '"$R" rails > $T/o; grep -q "^32505	0x6c0000/0x7e0000	179	wgclt2	-" $T/o && grep -q "wgclt1	main" $T/o'
ck "add: профиль основного маршрута — отказ" '! "$R" add r2 wgclt1 "awgus" > $T/o && grep -q "основной маршрут" $T/o'
ck "add: неизвестный туннель — отказ" '! "$R" add r2 wgclt2 "awgus awgxx" > $T/o && grep -q "awgxx нет в наборе" $T/o'
ck "add: профиль без правила PBR — отказ" '! "$R" add r2 wgclt9 "awgus" > $T/o && grep -q "нет правила PBR" $T/o'
ck "add: опасный ID и название — отказ" '! "$R" add "a;b" wgclt2 "awgus" >/dev/null && ! "$R" add main wgclt2 "awgus" >/dev/null && ! "$R" add r2 wgclt2 "awgus" "x\$(id)" >/dev/null && ! "$R" add r2 wgclt2 "awgus" "$(printf '"'"'a\nB=1'"'"')" >/dev/null'
"$R" add r2 wgclt2 "awgus awgbackup" "США" > $T/o; rc=$?
ck "add: маршрут r2 — файл 600, таблица и метка профиля" '[ $rc = 0 ] && grep -qx "TABLE=\"179\"" $DD/route.d/r2.env && grep -qx "MARK=\"0x6c0000/0x7e0000\"" $DD/route.d/r2.env && grep -qx "TUNNELS=\"awgus awgbackup\"" $DD/route.d/r2.env && [ "$(stat -c %a $DD/route.d/r2.env)" = 600 ]'
ck "add: служба awg-failover-r2 — юнит, автозапуск, список служб" 'grep -q "ExecStart=$DD/failover.sh --route r2" $SYSD/awg-failover-r2.service && grep -q "enable awg-failover-r2" $T/systemctl.log && grep -qx awg-failover-r2 $DD/.units'
ck "add: событие" 'grep -q "|route|маршрут r2 (wgclt2, таблица 179): awgus awgbackup — США" $DD/events.log'
ck "add: профиль уже занят — отказ" '! "$R" add r3 wgclt2 "awgde" > $T/o && grep -q "занят маршрутом r2" $T/o'
ck "list: маршрут, служба, название" '"$R" list | grep -q "^r2	wgclt2	179	awgus awgbackup	-	active	-	США"'
: > $T/systemctl.log
"$R" set r2 "awgus awgde" "" --only > $T/o
ck "set --only: туннели маршрута не нужны основному (кроме основного туннеля), основной перезапущен" 'grep -q "^ROUTE_ONLY=\"awgus awgde\"" $DD/awg.env && grep -q "restart awg-failover$" $T/systemctl.log && grep -q "restart awg-failover-r2" $T/systemctl.log'
ck "switch: ручной выбор и автоматика" '"$R" switch r2 awgde >/dev/null && [ "$(cat $T/run/awg-force-r2)" = awgde ] && "$R" switch r2 auto >/dev/null && [ ! -e $T/run/awg-force-r2 ] && ! "$R" switch r2 awgmain >/dev/null'
: > $T/systemctl.log
"$R" remove r2 > $T/o
ck "remove: служба и файлы убраны, своя таблица очищена целиком, исключения сняты" '[ ! -e $SYSD/awg-failover-r2.service ] && [ ! -e $DD/route.d/r2.env ] && ! grep -qx awg-failover-r2 $DD/.units && grep -q "failover --route r2 cleanup all" $T/failover.log && grep -q "^ROUTE_ONLY=\"\"" $DD/awg.env && grep -q "disable --now awg-failover-r2" $T/systemctl.log'
echo "== routes: ошибок $fails"
[ $fails = 0 ]
