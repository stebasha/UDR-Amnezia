#!/bin/bash
# Тесты установщика на заглушках: без root и без роутера. Запуск: bash tests/t_installer.sh [путь/к/install.sh]
H=$(cd "$(dirname "$0")" && pwd)
INST=${1:-$H/../install.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot WORK=$T/work NO_COLOR=1 AWG_LIB=1 BASHRC=$T/bashrc
mkdir -p "$DD" "$SYSD"
export PATH="$H/stubs3:$PATH"
pass=0; fail=0
t(){ if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
# shellcheck disable=SC1090
. "$INST"
id(){ [ "$1" = -u ] && echo 0 || command id "$@"; }

# --- установка файлов из набора (папка репозитория)
KIT=$(cd "$H/.." && pwd)
t "набор файлов полный" 'kit_ok "$KIT" || { echo "нет: $(kit_missing "$KIT")"; false; }'
install_files >/dev/null 2>&1
t "скрипты скопированы" '[ $(ls "$DD"/*.sh | wc -l) -ge 18 ] && [ -x "$DD/failover.sh" ] && [ -x "$DD/guard.sh" ] && [ -x "$DD/subnets.sh" ]'
t "синтаксис всех скриптов" 'for f in "$DD"/*.sh; do bash -n "$f" || exit 1; done'
t "юниты скопированы, пути под DD" 'grep -q "^ExecStart=$DD/guard.sh run" "$DD/awg-guard.service" && grep -q "^ExecStart=$DD/failover.sh$" "$DD/awg-failover.service"'
t "алиасы в BASHRC" 'grep -q "alias awgctl=" "$BASHRC" && grep -q "alias awg-selftest=" "$BASHRC"'
t "install.sh скопирован в DD" '[ -x "$DD/install.sh" ]'

# --- манифест и проверка
echo 'MAIN=awgmain' > "$DD/awg.env"; chmod 600 "$DD/awg.env"
write_manifest
t "манифест создан" '[ -s "$DD/.manifest" ]'
t "verify: чисто" 'do_verify >/dev/null 2>&1'
echo '# x' >> "$DD/mtu.sh"
t "verify: ловит правку" '! do_verify >/dev/null 2>&1'
install_files >/dev/null 2>&1; write_manifest

# --- юниты
t "unit_on ставит юнит и помечает" 'unit_on awg-guard >/dev/null 2>&1; [ -f "$SYSD/awg-guard.service" ] && grep -qx awg-guard "$DD/.units"'
unit_on awg-metrics >/dev/null 2>&1
t "unit_mark без дублей" 'unit_mark awg-guard; [ "$(grep -c "^awg-guard$" "$DD/.units")" = 1 ]'
t "unit_off убирает" 'unit_off awg-metrics; [ ! -f "$SYSD/awg-metrics.service" ] && ! grep -qx awg-metrics "$DD/.units"'

# --- проверка доменов, подсетей
t "valid_domain ok" 'valid_domain ui.com && valid_domain a-b.example.co.uk'
t "valid_domain отсекает мусор" '! valid_domain "bad domain" && ! valid_domain ";rm" && ! valid_domain localhost'
t "norm_subnet" '[ "$(norm_subnet 192.168.3.7/24)" = 192.168.3.0/24 ] && ! norm_subnet 1.2.3.4/32 && ! norm_subnet x/24'

# --- ответы: запись и повтор
RECORD_FILE=$T/rec
printf 'да\nпривет\n1\nсекрет\n' > "$T/in"
exec 3<"$T/in"
yn "вопрос" Y >/dev/null; ask v "имя" "" >/dev/null; choose c "заг" a b >/dev/null; read_secret s "пароль" >/dev/null
t "запись: секрет не попал" '! grep -q секрет "$T/rec" && grep -q "^#secret$" "$T/rec"'
t "запись: ответы на месте" 'grep -q "^привет$" "$T/rec"'
exec 3<&-
RECORD_FILE=""; ANS_FILE=$T/rec; AWG_SECRET=zzz
exec 3<"$ANS_FILE"
yn "вопрос" N >/dev/null; ask v2 "имя" "" >/dev/null; choose c2 "заг" a b >/dev/null; read_secret s2 "пароль" >/dev/null
t "повтор: ответы подставлены" '[ "$v2" = привет ] && [ "$c2" = 1 ] && [ "$s2" = zzz ]'
exec 3<&-; ANS_FILE=""
printf '#paste\nEND\n' > "$T/in2"; printf '[Interface]\nPrivateKey = k\n' > "$T/c.conf"
ANS_FILE=$T/in2; AWG_CONF_FILE=$T/c.conf; exec 3<"$T/in2"; read_paste "$T/out.conf" >/dev/null; exec 3<&-; ANS_FILE=""
t "повтор: #paste берёт файл" 'grep -q PrivateKey "$T/out.conf"'
t "права вставленного файла 600" '[ "$(stat -c %a "$T/out.conf")" = 600 ]'

# --- step_domains на ответах
echo 'TABLE=178' > "$DD/awg.env"; echo 'MARK=0x6a0000/0x7e0000' >> "$DD/awg.env"
printf 'x\nbank.ru bad_dom\n10.0.0.5 192.168.9.0/24 zz\nbank.ru\n10.99.0.7/16 foo\n' > "$T/in3"
svc_active(){ [ "$1" = awg-self ] || systemctl is-active --quiet "$1" 2>/dev/null; }
sleep(){ :; }
ANS_FILE=$T/in3; exec 3<"$T/in3"
# вопросы: домены через туннель, клиенты, домены-исключения, подсети-исключения
printf 'youtube.com bad_dom\n10.0.0.5 192.168.9.7/24 zz\nbank.ru\n10.99.0.7/16 foo\n' > "$T/in3"; exec 3<"$T/in3"
step_domains >"$T/o3" 2>&1
exec 3<&-; ANS_FILE=""
t "step_domains: домены через туннель" 'grep -q "^TUN_DOMAINS=\"youtube.com\"" "$DD/awg.env"'
t "step_domains: клиенты нормализованы" 'grep -q "^TUN_CLIENTS=\"10.0.0.5 192.168.9.0/24\"" "$DD/awg.env"'
t "step_domains: исключения" 'grep -q "^DIRECT_DOMAINS=\"bank.ru\"" "$DD/awg.env" && grep -q "^DIRECT_SUBNETS=\"10.99.0.0/16\"" "$DD/awg.env"'
t "step_domains: мусор отклонён" 'grep -q "bad_dom" "$T/o3" && grep -q "foo" "$T/o3"'

# --- on_boot
step_boot_hook >/dev/null 2>&1
t "boot hook создан" '[ -x "$BOOT_D/10-awg-restore.sh" ] && grep -q "awg-restore.sh --if-needed" "$BOOT_D/10-awg-restore.sh"'

# --- seed_units для старых установок
rm -f "$DD/.units"; echo x > "$SYSD/awg-failover.service"; echo x > "$SYSD/awg-subnets.service"
seed_units
t "seed_units заполняет по включённым" 'grep -qx awg-failover "$DD/.units" && grep -qx awg-subnets "$DD/.units"'

# --- list_tunnels / conf_of
echo 'BACKUP=awgbackup' >> "$DD/awg.env"; echo 'TUNNELS_EXTRA="awgalt1 awgalt2"' >> "$DD/awg.env"
t "list_tunnels по приоритету" '[ "$(list_tunnels | tr "\n" " ")" = "awgmain awgbackup awgalt1 awgalt2 " ]'
t "conf_of" '[ "$(conf_of awgmain)" = main.conf ] && [ "$(conf_of awgbackup)" = backup.conf ] && [ "$(conf_of awgalt1)" = awgalt1.conf ]'

# --- бинарники: установка из папки с проверкой SHA256SUMS
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "awg v-test"\n' > "$T/bin/awg"; printf '#!/bin/sh\necho "amneziawg-go v-test"\n' > "$T/bin/amneziawg-go"
( cd "$T/bin" && sha256sum amneziawg-go awg > SHA256SUMS )
t "бинарники: ставятся при верных суммах" 'bins_install_from "$T/bin" >/dev/null 2>&1 && "$DD/awg" --version | grep -q v-test'
echo "# подмена" >> "$T/bin/awg"
t "бинарники: отказ при неверной сумме" '! bins_install_from "$T/bin" >/dev/null 2>&1'
t "в установщике нет сторонних источников бинарников" '! grep -q -i "djgreez\|AmneziaWG-Unifi-DreamMachine/raw" "$INST"'
t "ссылки на исходники только amnezia-vpn" '[ -z "$(grep -o "github.com/[A-Za-z0-9_-]*/amneziawg-[a-z]*" "$INST" "$KIT"/server/*.sh | grep -v "github.com/amnezia-vpn/")" ]'

# --- 1.4: веб-панель, канал обновлений, откат
t "веб-панель скопирована" '[ -x "$DD/web/panel.py" ] && [ -f "$DD/web/static/app.js" ] && [ -f "$DD/web/static/index.html" ] && [ "$(stat -c %a "$DD/web")" = 700 ]'
t "канал обновлений записан" 'grep -qx "AWG_BRANCH=$AWG_BRANCH" "$DD/.channel" && grep -qx "AWG_REPO=$AWG_REPO" "$DD/.channel"'
t "манифест включает панель" 'grep -q " web/panel.py$" "$DD/.manifest" && grep -q " web/static/app.js$" "$DD/.manifest"'
echo "свои пользователи" > "$DD/web/users.json"
install_files >/dev/null 2>&1
t "обновление не трогает пользователей панели" 'grep -q "свои пользователи" "$DD/web/users.json"'
( cd "$DD" && tar czf "$T/bk.tgz" --exclude=backups . )
echo "# сломано" >> "$DD/failover.sh"; echo "сломано" > "$DD/web/static/app.js"; echo 9.9.9 > "$DD/VERSION"
echo 'MAIN=awgmain' > "$DD/awg.env.keep"; echo 'MAIN=изменено' > "$DD/awg.env"
update_rollback "$T/bk.tgz" >/dev/null 2>&1
t "откат: скрипты и панель возвращены" '! grep -q "# сломано" "$DD/failover.sh" && ! grep -q "^сломано" "$DD/web/static/app.js" && [ "$(cat "$DD/VERSION")" != 9.9.9 ]'
t "откат: настройки не трогаются" 'grep -q "MAIN=изменено" "$DD/awg.env"'
echo 'MAIN=awgmain' > "$DD/awg.env"
t "проверка после обновления: сторож работает → ок" 'TABLE= update_healthy 0 0 >/dev/null 2>&1'
t "проверка после обновления: панель не встала → откат" '! (sleep(){ :; }; update_healthy 0 1 >/dev/null 2>&1)'
t "неинтерактивный режим не ждёт ввода" '! ( AWG_YES=1; open_tty; ask x "вопрос" "" ) >/dev/null 2>&1'

# --- удаление
ipset(){ :; }
printf 'д\n' >/dev/null
echo "== $pass ok, $fail fail"
[ $fail = 0 ]
