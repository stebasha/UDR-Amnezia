#!/bin/bash
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

# --- статистика: «auto» не заканчивает время на запасном, ручной выбор основного — заканчивает
S2=$T/stats; mkdir -p "$S2"; n=$(date +%s)
printf '%s|force|ручное переключение на awgbackup\n%s|auto|возврат к автоматическому выбору\n%s|return|возврат на awgmain\n%s|force|ручное переключение на awgbackup\n%s|force|ручное переключение на awgmain\n' \
  $((n-3600)) $((n-3590)) $((n-3000)) $((n-1000)) $((n-940)) > "$S2/events.log"
out=$(DD=$S2 MAIN=awgmain bash "$COMP/awgctl.sh" stats 1)
ck "stats: auto не обрывает время на запасном, выбор основного — обрывает (10м + 1м)" 'echo "$out" | grep -q "не на основном канале : 11м 00с"'

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
echo "misc: провалов $fails"; [ $fails = 0 ]
