#!/bin/bash
# Тесты установщика на заглушках: без root и без роутера. Запуск: bash tests/t_installer.sh [путь/к/install.sh]
H=$(cd "$(dirname "$0")" && pwd)
INST=${1:-$H/../install.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd SYSD=$T/sys BOOT_D=$T/boot WORK=$T/work NO_COLOR=1 AWG_LIB=1 BASHRC=$T/bashrc AWG_BINDIR=$T/bin
mkdir -p "$DD" "$SYSD" "$AWG_BINDIR"
echo "чужой файл" > "$AWG_BINDIR/awgs"
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
t "awgctl и awg-selftest доступны без алиасов (ссылки)" '[ "$(readlink "$AWG_BINDIR/awgctl")" = "$DD/awgctl.sh" ] && [ "$(readlink "$AWG_BINDIR/awg-selftest")" = "$DD/selftest.sh" ]'
t "чужой файл с тем же именем не тронут" '[ ! -L "$AWG_BINDIR/awgs" ] && grep -q "чужой" "$AWG_BINDIR/awgs"'
t "install.sh скопирован в DD" '[ -x "$DD/install.sh" ]'
t "скрипты для VPS скопированы (#13)" '[ -x "$DD/vps.sh" ] && [ -f "$DD/server/vps-rotate.sh" ] && [ -f "$DD/server/audit-server.sh" ] && [ -f "$DD/server/awg-server-build.sh" ] && [ "$(stat -c %a "$DD/server")" = 700 ]'

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

# --- 1.5 (#8): каналы обновлений
chan(){  # chan [ПЕРЕМЕННЫЕ…] -- содержимое .channel → «канал ветка»
  local d; d=$(mktemp -d "$T/ch.XXXX"); printf '%b' "$1" > "$d/.channel"; shift
  env -i PATH="$PATH" HOME="$HOME" DD="$d" AWG_LIB=1 NO_COLOR=1 "$@" bash -c '. "$0"; echo "$AWG_CHANNEL $AWG_BRANCH"' "$INST"
}
t "канал: без .channel — stable" '[ "$(chan "")" = "stable main" ]'
t "канал: старый .channel с main — stable" '[ "$(chan "AWG_REPO=a/b\nAWG_BRANCH=main\n")" = "stable main" ]'
t "канал: старый .channel со своей веткой — branch" '[ "$(chan "AWG_REPO=a/b\nAWG_BRANCH=release/1.5\n")" = "branch release/1.5" ]'
t "канал: записанный beta" '[ "$(chan "AWG_CHANNEL=beta\nAWG_BRANCH=main\n")" = "beta main" ]'
t "канал: AWG_BRANCH=main в окружении — beta" '[ "$(chan "AWG_CHANNEL=stable\n" AWG_BRANCH=main)" = "beta main" ]'
t "канал: AWG_CHANNEL в окружении важнее файла" '[ "$(chan "AWG_CHANNEL=beta\n" AWG_CHANNEL=stable)" = "stable main" ]'
t "канал: мусор → stable" '[ "$(chan "AWG_CHANNEL=evil\n")" = "stable main" ]'
# stable: тег из GitHub API, архив релиза со сверкой SHA256SUMS
CS=$T/curlstub; mkdir -p "$CS/srv"
printf 'архив релиза' > "$CS/srv/udr-amnezia-v1.5.0.tar.gz"
( cd "$CS/srv" && sha256sum udr-amnezia-v1.5.0.tar.gz > SHA256SUMS )
cat > "$CS/curl" <<'C'
#!/bin/bash
out=""; url=""; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; http*) url=$1;; esac; shift; done
case "$url" in
  *api.github.com/repos/*/releases/latest) [ -e "$CSRV/norelease" ] && exit 22; printf '{\n  "tag_name": "v1.5.0",\n  "name": "1.5.0"\n}\n';;
  */releases/download/v1.5.0/*) f=$CSRV/${url##*/}; [ -f "$f" ] || exit 22; if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi;;
  */archive/refs/heads/*) [ -n "$out" ] && printf 'ветка' > "$out";;
  *) exit 22;;
esac
C
chmod +x "$CS/curl"
rel(){ ( PATH="$CS:$PATH"; export CSRV=$CS/srv; AWG_REF=""; AWG_CHANNEL=$1; AWG_BRANCH=main; resolve_ref >/dev/null 2>&1; echo "$AWG_REF $AWG_REF_KIND"; fetch_kit_archive "$T/k.tgz" >/dev/null 2>&1 && cat "$T/k.tgz" ); }
t "stable: последний релиз, сумма совпала" '[ "$(rel stable)" = "$(printf "v1.5.0 tag\nархив релиза")" ]'
printf 'подменён' > "$CS/srv/udr-amnezia-v1.5.0.tar.gz"
t "stable: подменённый архив отклонён" '[ "$(rel stable)" = "v1.5.0 tag" ] && [ ! -e "$T/k.tgz" ]'
touch "$CS/srv/norelease"
t "stable: релизов нет — ветка main" '[ "$(rel stable)" = "$(printf "main branch\nветка")" ]'
t "beta: ветка main" '[ "$(rel beta | head -1)" = "main branch" ]'
t "недопустимая ветка отклонена" '( AWG_REF=""; AWG_CHANNEL=branch; AWG_BRANCH="../x"; ! resolve_ref >/dev/null 2>&1 )'
AWG_CHANNEL=beta; AWG_BRANCH=main; write_channel
t "канал записывается с AWG_CHANNEL" 'grep -qx "AWG_CHANNEL=beta" "$DD/.channel" && grep -qx "AWG_BRANCH=main" "$DD/.channel"'

# --- 1.5 (#11): проверка и обновление бинарников из официальных релизов amnezia-vpn
BS=$T/binstub; HS=$T/hs; mkdir -p "$BS" "$HS" "$T/nb"; export HS
cat > "$BS/curl" <<'C'
#!/bin/bash
url=""; for a; do case "$a" in http*) url=$a;; esac; done
[ -e "$HS/offline" ] && exit 6
case "$url" in
  */amnezia-vpn/amneziawg-go/releases/latest) printf '{\n  "url": "x",\n  "tag_name": "v0.2.16",\n  "name": "v0.2.16"\n}\n';;
  */amnezia-vpn/amneziawg-tools/releases/latest) exit 22;;
  */amnezia-vpn/amneziawg-tools/tags*) printf '[\n  {\n    "name": "v1.0.20250706"\n  },\n  {\n    "name": "v1.0.20250901"\n  },\n  {\n    "name": "evil;rm"\n  }\n]\n';;
  *) exit 22;;
esac
C
mkbin(){  # mkbin ФАЙЛ ВЕРСИЯ [broken]
  printf '#!/bin/bash\n# %s\ncase "$1" in --version) echo "%s %s";; show) f=$HS/$2; if [ -f "$f" ]; then echo "peer $(cat "$f")"; else echo "peer 0"; fi;; esac\n' "${3:-good}" "$(basename "$1")" "$2" > "$1"; chmod 755 "$1"; }
mkbin "$DD/awg" v1.0.20240213; mkbin "$DD/amneziawg-go" v0.2.12
cat > "$DD/up.sh" <<'U'
#!/bin/bash
if grep -q '^# broken' "$DD/amneziawg-go"; then rm -f "$HS/$1"; else date +%s > "$HS/$1"; fi
U
chmod 755 "$BS/curl" "$DD/up.sh"
printf 'MAIN=awgmain\nBACKUP=awgbackup\n' > "$DD/awg.env"
t "bins: версия из --version" '[ "$(bins_ver amneziawg-go)" = v0.2.12 ] && [ "$(bins_ver awg)" = v1.0.20240213 ]'
t "bins: последний релиз и самый свежий тег без мусора" '[ "$(PATH="$BS:$PATH" bins_latest amneziawg-go)" = v0.2.16 ] && [ "$(PATH="$BS:$PATH" bins_latest amneziawg-tools)" = v1.0.20250901 ]'
t "bins-check: есть новее → код 10" '(PATH="$BS:$PATH"; do_bins_check >/dev/null 2>&1; [ $? = 10 ])'
touch "$HS/offline"
t "bins-check: GitHub недоступен → код 1" '(PATH="$BS:$PATH"; do_bins_check >/dev/null 2>&1; [ $? = 1 ])'
rm -f "$HS/offline"
mkbin "$T/nb/awg" "v1.0.20250901-dirty"; mkbin "$T/nb/amneziawg-go" "0.0.0"
( cd "$T/nb" && sha256sum amneziawg-go awg > SHA256SUMS && printf 'amneziawg-go   https://github.com/amnezia-vpn/amneziawg-go   v0.2.16 (abc)\namneziawg-tools https://github.com/amnezia-vpn/amneziawg-tools v1.0.20250901 (def)\n' > BUILDINFO )
date +%s > "$HS/awgmain"            # до обновления handshake есть только у основного
t "bins: туннели с handshake до обновления" '[ "$(bins_live)" = " awgmain" ]'
t "bins: установка из папки с SHA256SUMS" 'bins_install_from "$T/nb" >/dev/null 2>&1 && [ -f "$DD/awg.prev" ] && grep -q v0.2.12 "$DD/amneziawg-go.prev"'
t "bins: тег сборки из BUILDINFO, а не из --version" '[ "$(bins_ver amneziawg-go)" = v0.2.16 ] && [ "$(bins_ver awg)" = v1.0.20250901 ]'
t "bins-check: после обновления актуально → код 0" '(PATH="$BS:$PATH"; do_bins_check >/dev/null 2>&1)'
t "bins: handshake на новых → без отката" 'BINS_WAIT=3 bins_apply " awgmain" >/dev/null 2>&1 && grep -q v0.2.16 "$DD/.binsver" && ! grep -q "^# broken" "$DD/amneziawg-go"'
mkbin "$T/nb/amneziawg-go" "0.0.1" broken; ( cd "$T/nb" && sha256sum amneziawg-go awg > SHA256SUMS )
bins_install_from "$T/nb" >/dev/null 2>&1
t "bins: нет handshake на новых → откат на прежние" '! BINS_WAIT=3 bins_apply " awgmain" >/dev/null 2>&1 && ! grep -q "^# broken" "$DD/amneziawg-go" && [ -f "$HS/awgmain" ]'
echo "подмена" >> "$T/nb/awg"
t "bins: сумма не совпала → не ставится" '! bins_install_from "$T/nb" >/dev/null 2>&1 && ! grep -q подмена "$DD/awg"'

# --- удаление
ipset(){ :; }
printf 'д\n' >/dev/null
echo "== $pass ok, $fail fail"
[ $fail = 0 ]
