#!/bin/bash
# shellcheck disable=SC2034,SC1090  # переменные используются в строках для eval (проверки t/ck), источники — заглушки
# Проверки встроенных юнитов и деинсталлятора на заглушках. Запуск: bash tests/t_misc.sh <папка с выложенными скриптами>
H=$(cd "$(dirname "$0")" && pwd)
COMP=$(cd "${1:?укажите папку с выложенными скриптами}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export AWG_RUN=$T/run; mkdir -p "$AWG_RUN"
export STUB=$T/stub; mkdir -p "$STUB"
export PATH="$H/stubs2:$H/stubs3:$PATH"
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }

# --- служебные юниты
for u in awg-failover awg-notify awg-motd awg-self awg-guard awg-bot awg-metrics awg-subnets; do
  ck "юнит $u выложен" '[ -f "$COMP/$u.service" ]'
done
ck "сторож: пауза только при загрузке роутера" 'grep -q "/proc/uptime)\" -lt 300 ] && sleep" "$COMP/failover.sh" && ! grep -q "^ExecStartPre=.*sleep" "$COMP/awg-failover.service"'
ck "awg-failover: cleanup при остановке" 'grep -q "^ExecStopPost=.*failover.sh cleanup" "$COMP/awg-failover.service"'


# --- iptables всегда с -w (иначе при занятой блокировке проверка -C даёт ложное «правила нет» и копятся дубликаты)
for f in "$COMP"/*.sh; do
  if grep -q -E '(^|[^a-z_-])ip6?tables +-' "$f"; then
    ck "$(basename "$f"): обёртка iptables -w" 'grep -q "command iptables -w" "$f"'
  fi
done
ck "install.sh: обёртка iptables -w" 'grep -q "^iptables(){ command iptables -w" "$H/../install.sh"'
ck "нигде нет вызова command iptables без -w" '! grep -h "command ip6\?tables" "$COMP"/*.sh "$H/../install.sh" | grep -v -E -e " -w [0-9]+ " -e "command -v" | grep -q .'
for f in "$COMP"/*.sh "$H/../install.sh"; do
  if grep -q -E '(^|[^a-z_-])ip6tables +-' "$f"; then
    ck "$(basename "$f"): обёртка ip6tables -w" 'grep -q "command ip6tables -w" "$f"'
  fi
done
# «-C … || добавить» запрещено: при занятой блокировке -C падает с кодом 4, и правило добавилось бы второй раз
ck "нет шаблона «iptables -C … || iptables -A/-I»" '! grep -n -E "iptables[^|]* -C [^|]*\|\| *iptables" "$COMP"/*.sh "$H/../install.sh"'

# --- selftest: выключенные службы не считаются «упавшими» (копии юнитов в DD лежат всегда)
S=$T/st; mkdir -p "$S/dd" "$S/sys" "$S/run"
cp "$COMP"/*.sh "$COMP"/*.service "$S/dd/" 2>/dev/null; cp "$H/stubs5/awg" "$S/dd/awg"
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nWANIF=eth3\n' > "$S/dd/awg.env"; echo awg-self > "$S/dd/.units"
out=$(PATH="$H/stubs5:$PATH" DD=$S/dd SYSD=$S/sys AWG_RUN=$S/run NO_COLOR=1 timeout 120 bash "$S/dd/selftest.sh" 2>&1)
ck "selftest: выключенные guard/subnets/metrics не в WARN" '! echo "$out" | grep -qE "awg-(guard|subnets|metrics) (установлен|: нет)"'
ck "selftest: включённая по .units служба проверяется" 'echo "$out" | grep -q "awg-self установлен, но не запущен"'
ck "selftest: без LEAK_GUARD защита считается выключенной, не FAIL" 'echo "$out" | grep -q "awg-guard) выключена" && ! echo "$out" | grep -q "не применена"'
echo 'LEAK_GUARD=yes' >> "$S/dd/awg.env"
out=$(PATH="$H/stubs5:$PATH" DD=$S/dd SYSD=$S/sys AWG_RUN=$S/run NO_COLOR=1 timeout 120 bash "$S/dd/selftest.sh" 2>&1)
ck "selftest: LEAK_GUARD=yes без службы → WARN с подсказкой" 'echo "$out" | grep -q "WARN  LEAK_GUARD=yes, но служба awg-guard не включена"'
ck "selftest: автокопия выключена — проверок нет" '! echo "$out" | grep -q автокопи'
# автокопия (#12): таймер и итог последнего запуска
printf 'BK_AUTO="weekly"\n' > "$S/dd/backup.env"; chmod 600 "$S/dd/backup.env"; mkdir -p "$S/dd/backups"; touch "$S/sys/awg-backup.timer"
printf '%s|FAIL||VPS: Permission denied\n' "$(date +%s)" > "$S/dd/backups/auto.status"
out=$(PATH="$H/stubs5:$PATH" DD=$S/dd SYSD=$S/sys AWG_RUN=$S/run NO_COLOR=1 timeout 120 bash "$S/dd/selftest.sh" 2>&1)
ck "selftest: неудачная автокопия → WARN с причиной" 'echo "$out" | grep -q "OK    автокопия по расписанию включена" && echo "$out" | grep -q "WARN  последняя автокопия не удалась: VPS: Permission denied"'
printf '%s|OK|awg-auto-1.tgz.enc|ok\n' "$(( $(date +%s) - 10 * 86400 ))" > "$S/dd/backups/auto.status"; rm -f "$S/sys/awg-backup.timer"
out=$(PATH="$H/stubs5:$PATH" DD=$S/dd SYSD=$S/sys AWG_RUN=$S/run NO_COLOR=1 timeout 120 bash "$S/dd/selftest.sh" 2>&1)
ck "selftest: старая автокопия и нет таймера → WARN" 'echo "$out" | grep -q "старше 8 дн" && echo "$out" | grep -q "таймера нет"'

# --- статистика: «auto» не заканчивает время на запасном, ручной выбор основного — заканчивает
S2=$T/stats; mkdir -p "$S2"; n=$(date +%s)
printf '%s|force|ручное переключение на awgbackup\n%s|auto|возврат к автоматическому выбору\n%s|return|возврат на awgmain\n%s|force|ручное переключение на awgbackup\n%s|force|ручное переключение на awgmain\n' \
  $((n-3600)) $((n-3590)) $((n-3000)) $((n-1000)) $((n-940)) > "$S2/events.log"
out=$(DD=$S2 MAIN=awgmain bash "$COMP/awgctl.sh" stats 1)
ck "stats: auto не обрывает время на запасном, выбор основного — обрывает (10м + 1м)" 'echo "$out" | grep -q "не на основном канале : 11м 00с"'

# --- awgctl ping: ICMP режется → auto переходит на TCP; TCP-замер считает задержку и потери
P=$T/pingstub; mkdir -p "$P"
printf '#!/bin/bash\necho "10 packets transmitted, 0 received, 100%%%% packet loss"\nexit 1\n' > "$P/ping"
printf '#!/bin/bash\nfor a; do case "$a" in *bad.example*) printf 0.000000; exit 28;; esac; done\nprintf 0.042000\n' > "$P/curl"
chmod +x "$P/ping" "$P/curl"
out=$(PATH="$P:$PATH" COUNT=3 DD=$T/nodd bash "$COMP/awgctl.sh" ping auto awgmain 1.1.1.1); rc=$?
ck "ping auto: без ICMP — TCP, 42 мс, код 0" '[ $rc = 0 ] && echo "$out" | grep -q "меряю по TCP" && echo "$out" | grep -q "мин/сред/макс: 42/42/42 мс"'
out=$(PATH="$P:$PATH" COUNT=2 DD=$T/nodd bash "$COMP/awgctl.sh" ping tcp eth3 bad.example); rc=$?
ck "ping tcp: нет соединения — потери 100%, код 1" '[ $rc = 1 ] && echo "$out" | grep -q "потери: 100%"'
out=$(DD=$T/nodd bash "$COMP/awgctl.sh" ping tcp eth3 1.1.1.1 99999); rc=$?
ck "ping: неверный порт отклонён" '[ $rc = 2 ]'

# --- смена прошивки UniFi (#9): первый запуск запоминает, смена — восстановление, событие, самопроверка
F=$T/fw; mkdir -p "$F/dd" "$F/sys" "$F/bin"
cp "$COMP/awg-restore.sh" "$F/dd/"; printf '#!/bin/bash\necho "Итог: OK: 29   WARN: 0   FAIL: 0"\n' > "$F/dd/selftest.sh"; chmod +x "$F/dd/"*.sh
printf '#!/bin/bash\necho "${FWVER:-5.0.10}"\n' > "$F/bin/ubnt-device-info"
printf '#!/bin/bash\n[ "$3" = unifi ] && { printf "10.0.1"; exit 0; }; exit 1\n' > "$F/bin/dpkg-query"
printf '#!/bin/bash\nexit 0\n' > "$F/bin/systemctl"; chmod +x "$F/bin/"*
fw(){ PATH="$F/bin:$PATH" DD=$F/dd SYSD=$F/sys BASHRC=$F/bashrc AWG_BINDIR=$F/nobin FW_SETTLE=0 "$@" bash "$F/dd/awg-restore.sh" --fw-check; }
out=$(fw); rc=$?
ck "прошивка: первый запуск — только запомнить" '[ $rc = 0 ] && [ "$(cat "$F/dd/.fwver")" = "os=5.0.10 net=10.0.1" ] && [ ! -s "$F/dd/events.log" ]'
out=$(fw); ck "прошивка: без смены — ничего" '[ -z "$out" ] && [ ! -s "$F/dd/events.log" ]'
out=$(fw env FWVER=5.1.2)
ck "прошивка: смена → восстановление, событие с самопроверкой" 'echo "$out" | grep -q "сменилась прошивка" && grep -q "|firmware|прошивка: os=5.0.10 net=10.0.1 → os=5.1.2 net=10.0.1; службы восстановлены; самопроверка: OK: 29" "$F/dd/events.log" && [ "$(cat "$F/dd/.fwver")" = "os=5.1.2 net=10.0.1" ]'
# два запуска сразу (сторож и on_boot.d после прошивки): восстановление и событие — один раз
fw env FWVER=5.2.0 FW_SETTLE=1 >/dev/null & fw env FWVER=5.2.0 FW_SETTLE=1 >/dev/null; wait
ck "прошивка: два запуска одновременно — одно событие" '[ "$(grep -c "→ os=5.2.0" "$F/dd/events.log")" = 1 ]'
# автокопия (#12): прошивка стёрла таймер — on_boot.d (--if-needed) возвращает его по backup.env
cp "$COMP/backup.sh" "$COMP/awg-backup.service" "$F/dd/"; printf 'BK_AUTO="daily"\n' > "$F/dd/backup.env"; touch "$F/bashrc"
out=$(PATH="$F/bin:$PATH" DD=$F/dd SYSD=$F/sys BASHRC=$F/bashrc AWG_BINDIR=$F/nobin bash "$F/dd/awg-restore.sh" --if-needed 2>&1)
ck "восстановление: таймер автокопии возвращён" 'grep -q "^OnCalendar=\*-\*-\* 04:20" "$F/sys/awg-backup.timer" && [ -f "$F/sys/awg-backup.service" ]'

# --- деинсталлятор
mkdir -p "$T/dd" "$T/sys" "$T/boot"
cp "$COMP"/*.sh "$COMP"/*.service "$T/dd/" 2>/dev/null
export BASHRC=$T/bashrc; printf 'alias awgs=x\nalias foo=bar\n' > "$BASHRC"
export AWG_BINDIR=$T/bin; mkdir -p "$AWG_BINDIR"; ln -s "$T/dd/awgctl.sh" "$AWG_BINDIR/awgctl"; echo x > "$AWG_BINDIR/awg-selftest"
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\n' > "$T/dd/awg.env"
cp "$T/dd/awg-failover.service" "$T/sys/"; touch "$T/boot/10-awg-restore.sh"
out=$(DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot bash "$T/dd/awg-uninstall.sh" 2>&1); rc=$?
ck "uninstall: код возврата 0" '[ $rc = 0 ]'
ck "uninstall: юнит убран" '[ ! -f "$T/sys/awg-failover.service" ]'
ck "uninstall: файл on_boot.d убран" '[ ! -f "$T/boot/10-awg-restore.sh" ]'
ck "uninstall: без --purge папка осталась" '[ -f "$T/dd/awg.env" ]'
ck "uninstall: алиасы убраны, чужие строки целы" '! grep -q awgs "$BASHRC" && grep -q foo "$BASHRC"'
ck "uninstall: ссылка awgctl убрана, чужой файл цел" '[ ! -e "$AWG_BINDIR/awgctl" ] && [ -f "$AWG_BINDIR/awg-selftest" ]'
out=$(DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot bash "$T/dd/awg-uninstall.sh" --purge 2>&1)
ck "uninstall --purge: папка удалена" '[ ! -d "$T/dd" ]'
# бот: chat id из ответа getUpdates при любом форматировании JSON (в т. ч. с переводами строк)
BJ=$(mktemp)
printf '{"ok":true,"result":[{"update_id":7,\n"message":{"message_id":5,"from":{"id":130181984},\n"chat": {"id": 130181984,"type":"private"},"text":"/status"}}]}' > "$BJ"
ck "бот: chat id разбирается (python3)" '[ "$(bash -c "source <(sed -n \"/^parse()/,/^}/p\" $COMP/bot.sh); parse < $BJ")" = "7|130181984|/status|message" ]'
ck "бот: chat id разбирается без python3" '[ "$(bash -c "command(){ [ \"\$2\" = python3 ] && return 1; builtin command \"\$@\"; }; source <(sed -n \"/^parse()/,/^}/p\" $COMP/bot.sh); parse < $BJ")" = "7|130181984|/status|message" ]'
rm -f "$BJ"
# метрики (1.7.1): один вызов awg/systemctl/awk на сбор, вывод — как раньше
MD=$T/mdd; mkdir -p "$MD" "$STUB/hs" "$STUB/svc"; echo 30 > "$STUB/hs/awgmain"; touch "$STUB/svc/awg-failover"
printf 'MAIN=awgmain\nBACKUP=awgbackup\nTABLE=178\n' > "$MD/awg.env"; ln -sf "$H/stubs5/awg" "$MD/awg"
printf 'ACTIVE=awgmain\nFORCED=\nUPDATED=1\nLOSS_awgmain=0\nRTT_awgmain=41\n' > "$T/mstate"
printf '1|switch|a\n2|switch|b\n3|return|c\n' > "$MD/events.log"
mo=$(DD=$MD STATEF=$T/mstate PATH="$H/stubs5:$PATH" bash "$COMP/metrics.sh" once)
ck "метрики: handshake, активный канал, события, служба" 'echo "$mo" | grep -qx "awg_handshake_age_seconds{tunnel=\"awgmain\"} 30" && echo "$mo" | grep -qx "awg_tunnel_up{tunnel=\"awgbackup\"} 0" && echo "$mo" | grep -qx "awg_active{tunnel=\"awgmain\"} 1" && echo "$mo" | grep -qx "awg_events_total{type=\"switch\"} 2" && echo "$mo" | grep -qx "awg_service_up{service=\"awg-failover\"} 1"'
# отчёт для issue (report.sh): ключи, токены, имя сервера и публичные адреса скрыты
mk=$(printf 'PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5cHI=\nEndpoint = vpn.example.org:51820\nTG_TOKEN="123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"\nVPS_HOST="vpn.example.org"\nendpoint: 95.31.7.8:51820\n' \
  | bash -c 'source <(sed -n "/^mask(){/,/^}/p" "$1"); mask' _ "$COMP/report.sh")
ck "report: ключ, токен, имя сервера, адрес VPS и публичный IP скрыты" '! echo "$mk" | grep -qE "cHJpdmF0|vpn\.example|AAAAAAAA|95\.31\.7\.8" && echo "$mk" | grep -q "Endpoint = <узел>:51820"'
echo "misc: провалов $fails"; [ $fails = 0 ]
