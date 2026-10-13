#!/bin/bash
# Автокопия вне роутера (#12) на заглушках: VPS — локальная папка (ssh/scp выполняются здесь), Telegram — запись вызовов curl.
# Запуск: bash tests/t_backup.sh <папка со скриптами awg>
H=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${1:-$H/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd SYSD=$T/sys STUB=$T/stub
mkdir -p "$DD/ssh" "$SYSD" "$STUB" "$T/bin" "$T/vps"
cp "$SRC/backup.sh" "$SRC/awg-backup.service" "$DD/"; chmod 755 "$DD/backup.sh"
printf 'MAIN=awgmain\nBACKUP=awgbackup\nVPS_IP=203.0.113.9\n' > "$DD/awg.env"
printf '[Interface]\nPrivateKey = cHJpdmF0ZQ==\n' > "$DD/main.conf"
printf 'TG_TOKEN="123:abc"\nTG_CHAT="111 222"\nTG_VIEWERS="333"\n' > "$DD/telegram.env"
echo "ключ" > "$DD/ssh/id_ed25519"
printf '#!/bin/bash\necho "$*" >> "%s/notify.log"\n' "$T" > "$DD/notify.sh"; chmod 755 "$DD/notify.sh"
# ssh: последняя строка аргументов — команда, выполняется здесь же; scp: копирует в «удалённый» путь (он локальный)
cat > "$T/bin/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$STUB/ssh.log"
[ -e "$STUB/sshfail" ] && { echo "root@vps: Permission denied (publickey)." >&2; exit 255; }
exec bash -c "${@: -1}"
S
cat > "$T/bin/scp" <<'S'
#!/bin/bash
echo "scp $*" >> "$STUB/ssh.log"
[ -e "$STUB/sshfail" ] && { echo "Permission denied" >&2; exit 1; }
src=${@: -2:1}; dst=${@: -1}; dst=${dst#*:}
cp "$src" "$dst" && { [ -e "$STUB/corrupt" ] && echo "x" >> "$dst"; true; }
S
cat > "$T/bin/curl" <<'S'
#!/bin/bash
cfg=$(cat); echo "curl $* | $cfg" >> "$STUB/curl.log"
[ -e "$STUB/tgfail" ] && { printf 000; exit 7; }
printf 200
S
printf '#!/bin/bash\necho "systemctl $*" >> "%s/systemctl.log"; exit 0\n' "$STUB" > "$T/bin/systemctl"
chmod 755 "$T"/bin/*
export PATH="$T/bin:$PATH"
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
B="$DD/backup.sh"
conf(){ printf 'BK_AUTO="%s"\nBK_KEEP="%s"\nBK_VPS="%s"\nBK_VPS_HOST="%s"\nBK_VPS_PORT="22"\nBK_VPS_USER="root"\nBK_VPS_DIR="%s"\nBK_VPS_KEEP="%s"\nBK_TG="%s"\n' "$@" > "$DD/backup.env"; }
last(){ tail -n1 "$DD/backups/auto.status" | cut -d'|' -f2; }

# --- без пароля: ошибка, событие и уведомление
conf daily 7 yes "" "$T/vps/bk" 14 yes
ck "без пароля автокопия не создаётся" '! "$B" auto >/dev/null 2>&1 && [ "$(last)" = FAIL ] && ! ls "$DD"/backups/awg-*.enc >/dev/null 2>&1'
ck "сбой — в журнале событий и в Telegram" 'grep -q "|backup|автокопия НЕ удалась: не задан пароль" "$DD/events.log" && grep -q "не удалась" "$T/notify.log"'

# --- полный путь: копия, проверка, VPS, Telegram
echo "пароль-автокопии" > "$DD/backup.pass"; chmod 600 "$DD/backup.pass"
"$B" auto > "$T/o1" 2>&1; rc=$?
f=$(ls "$DD"/backups/awg-auto-*.tgz.enc 2>/dev/null | head -n1)
ck "автокопия: код 0, файл зашифрован" '[ $rc = 0 ] && [ -n "$f" ] && ! grep -q PrivateKey "$f"' ; [ $rc = 0 ] || cat "$T/o1"
ck "проверка расшифровкой выполнена" 'grep -q "проверка: копия расшифровывается" "$T/o1"'
ck "VPS по умолчанию — VPS_IP из awg.env, вход ключом без пароля" 'grep -q "root@203.0.113.9" "$STUB/ssh.log" && grep -q "BatchMode=yes" "$STUB/ssh.log" && grep -q -- "-i $DD/ssh/id_ed25519" "$STUB/ssh.log"'
ck "на VPS тот же файл, без .part" '[ "$(sha256sum < "$T/vps/bk/$(basename "$f")")" = "$(sha256sum < "$f")" ] && ! ls "$T"/vps/bk/*.part >/dev/null 2>&1'
ck "папка на VPS закрыта (700)" '[ "$(stat -c %a "$T/vps/bk")" = 700 ]'
ck "Telegram: документ обоим администраторам, не зрителю" '[ "$(grep -c sendDocument "$STUB/curl.log")" = 2 ] && grep -q "chat_id=111" "$STUB/curl.log" && grep -q "chat_id=222" "$STUB/curl.log" && ! grep -q "chat_id=333" "$STUB/curl.log"'
ck "Telegram: токен не в аргументах curl" '! sed "s/|.*//" "$STUB/curl.log" | grep -q "123:abc" && grep -q "bot123:abc/sendDocument" "$STUB/curl.log"'
ck "итог OK в истории и событие" '[ "$(last)" = OK ] && grep -q "|backup|автокопия: awg-auto-" "$DD/events.log"'
tmp=$T/x.tgz
ck "копия открывается паролем автокопии, в ней настройки, но не пароль" '"$B" verify "$f" --pass-file "$DD/backup.pass" >/dev/null 2>&1 && AWG_BACKUP_PASS="пароль-автокопии" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -pass env:AWG_BACKUP_PASS -in "$f" -out "$tmp" 2>/dev/null && tar tzf "$tmp" | grep -qx awg.env && tar tzf "$tmp" | grep -qx backup.env && ! tar tzf "$tmp" | grep -q backup.pass'
ck "чужой пароль не подходит" '! AWG_BACKUP_PASS=другой "$B" verify "$f" >/dev/null 2>&1'

# --- хранение последних N: на VPS и на роутере
for i in 1 2 3; do touch -d "-$i day" "$T/vps/bk/awg-old$i.tgz.enc" "$DD/backups/awg-old$i.tgz.enc"; done
conf weekly 2 yes "" "$T/vps/bk" 2 no
rm -f "$STUB/curl.log"
"$B" auto >/dev/null 2>&1
ck "VPS: хранятся последние 2" '[ "$(ls "$T"/vps/bk/awg-*.tgz.enc | wc -l)" = 2 ] && [ ! -e "$T/vps/bk/awg-old3.tgz.enc" ]'
ck "роутер: хранятся последние 2" '[ "$(ls "$DD"/backups/awg-*.tgz* | wc -l)" = 2 ]'
ck "Telegram выключен — не отправляется" '[ ! -s "$STUB/curl.log" ]'

# --- сбои отправки
touch "$STUB/sshfail"; : > "$T/notify.log"
ck "VPS недоступен: код 1, FAIL, уведомление, копия на роутере осталась" '! "$B" auto >/dev/null 2>&1 && [ "$(last)" = FAIL ] && grep -q "Permission denied" "$DD/backups/auto.status" && grep -q "не удалась" "$T/notify.log" && ls "$DD"/backups/awg-auto-*.enc >/dev/null 2>&1'
ck "vps-test: понятная причина и подсказка" '"$B" vps-test > "$T/o2" 2>&1; [ $? = 1 ] && grep -q "ключа роутера нет на VPS" "$T/o2"'
rm -f "$STUB/sshfail"; touch "$STUB/corrupt"; sleep 1
ck "сумма на VPS не совпала: FAIL, недокачанный файл убран" '! "$B" auto > "$T/o3" 2>&1 && grep -q "контрольная сумма на сервере не совпала" "$T/o3" && ! ls "$T"/vps/bk/*.part >/dev/null 2>&1'
rm -f "$STUB/corrupt"
ck "vps-test: работает" '"$B" vps-test | grep -q "доступна для записи"'

# --- недопустимые настройки не доходят до ssh
: > "$STUB/ssh.log"
conf daily 7 yes "" "/root/../etc" 14 no
ck "папка с .. отклонена" '! "$B" ship "$f" >/dev/null 2>&1 && [ ! -s "$STUB/ssh.log" ]'
conf daily 7 yes 'vps;reboot' "$T/vps/bk" 14 no
ck "адрес с ; отклонён" '! "$B" ship "$f" >/dev/null 2>&1 && [ ! -s "$STUB/ssh.log" ]'

# --- расписание
conf weekly 7 no "" "$T/vps/bk" 14 no
"$B" timer >/dev/null
ck "timer: еженедельно, юниты в systemd" 'grep -q "^OnCalendar=Sun " "$SYSD/awg-backup.timer" && grep -q "^Persistent=true" "$SYSD/awg-backup.timer" && [ -f "$SYSD/awg-backup.service" ] && grep -q "enable --now awg-backup.timer" "$STUB/systemctl.log"'
conf no 7 no "" "$T/vps/bk" 14 no
"$B" timer >/dev/null
ck "timer: выключено — юниты убраны" '[ ! -e "$SYSD/awg-backup.timer" ] && [ ! -e "$SYSD/awg-backup.service" ]'
echo "== backup: ошибок $fails"
[ $fails = 0 ]
