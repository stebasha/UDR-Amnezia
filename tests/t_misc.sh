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

# --- деинсталлятор
mkdir -p "$T/dd" "$T/sys" "$T/boot"
cp "$COMP"/*.sh "$COMP"/*.service "$T/dd/" 2>/dev/null
export BASHRC=$T/bashrc; printf 'alias awgs=x\nalias foo=bar\n' > "$BASHRC"
printf 'TABLE=178\nMARK=0x6a0000/0x7e0000\nMAIN=awgmain\nBACKUP=awgbackup\n' > "$T/dd/awg.env"
cp "$T/dd/awg-failover.service" "$T/sys/"; touch "$T/boot/10-awg-restore.sh"
out=$(DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot bash "$T/dd/awg-uninstall.sh" 2>&1); rc=$?
ck "uninstall: код возврата 0" '[ $rc = 0 ]'
ck "uninstall: юнит убран" '[ ! -f "$T/sys/awg-failover.service" ]'
ck "uninstall: файл on_boot.d убран" '[ ! -f "$T/boot/10-awg-restore.sh" ]'
ck "uninstall: без --purge папка осталась" '[ -f "$T/dd/awg.env" ]'
ck "uninstall: алиасы убраны, чужие строки целы" '! grep -q awgs "$BASHRC" && grep -q foo "$BASHRC"'
out=$(DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot bash "$T/dd/awg-uninstall.sh" --purge 2>&1)
ck "uninstall --purge: папка удалена" '[ ! -d "$T/dd" ]'
echo "misc: провалов $fails"; [ $fails = 0 ]
