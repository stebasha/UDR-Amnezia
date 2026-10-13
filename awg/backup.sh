#!/bin/bash
# awg-backup: резервная копия настроек (конфиги с ключами, awg.env, telegram.env, юниты, скрипты) в один зашифрованный файл.
#   backup.sh create [-o ФАЙЛ] [--with-bins] [--plain] [--pass-file Ф]
#   backup.sh list
#   backup.sh restore ФАЙЛ [--pass-file Ф]
#   backup.sh verify  ФАЙЛ [--pass-file Ф]
#   backup.sh auto        копия по расписанию (#12): пароль из backup.pass, проверка расшифровкой, отправка на VPS и/или в Telegram
#   backup.sh ship ФАЙЛ   отправить готовую копию туда же, куда автокопию
#   backup.sh vps-test    проверить вход на VPS ключом роутера и запись в папку копий
#   backup.sh timer       включить/выключить расписание по BK_AUTO (no|daily|weekly) в backup.env
# Шифрование: openssl AES-256-CBC, PBKDF2 200000 итераций. Пароль: запрос в терминале, либо переменная AWG_BACKUP_PASS,
# либо файл (--pass-file). Без пароля копия не читается: храните пароль отдельно от файла.
# Копии лежат в /data/awg/backups (хранятся последние BK_KEEP, по умолчанию 7), скопируйте файл на компьютер:
#   scp root@РОУТЕР:/data/awg/backups/ФАЙЛ .
# Автокопия: настройки в backup.env (панель: «Резервные копии → Автокопия»), пароль в backup.pass (600).
DD=${DD:-/data/awg}
BK=$DD/backups
RKEY=${RKEY:-$DD/ssh/id_ed25519}
umask 077
cmd=${1:-help}; shift
OUT=""; PLAIN=0; BINS=0; PF=""; FILE=""
while [ $# -gt 0 ]; do case "$1" in
  -o) OUT=$2; shift;; --plain) PLAIN=1;; --with-bins) BINS=1;; --pass-file) PF=$2; shift;;
  *) FILE=$1;; esac; shift; done

# настройки автокопии
BK_AUTO=no; BK_KEEP=7; BK_VPS=no; BK_VPS_HOST=""; BK_VPS_PORT=22; BK_VPS_USER=root; BK_VPS_DIR=/root/udr-backups; BK_VPS_KEEP=14; BK_TG=no
# shellcheck disable=SC1091
[ -r "$DD/backup.env" ] && . "$DD/backup.env"
[ -n "$BK_VPS_HOST" ] || BK_VPS_HOST=$( { [ -r "$DD/awg.env" ] && . "$DD/awg.env"; } 2>/dev/null; echo "${VPS_IP:-}")
[[ $BK_KEEP =~ ^[0-9]+$ ]] && [ "$BK_KEEP" -ge 1 ] || BK_KEEP=7
[[ $BK_VPS_KEEP =~ ^[0-9]+$ ]] && [ "$BK_VPS_KEEP" -ge 1 ] || BK_VPS_KEEP=14

getpass(){  # getpass [повтор]
  if [ -n "$PF" ]; then AWG_BACKUP_PASS=$(head -n1 "$PF"); export AWG_BACKUP_PASS; [ -n "$AWG_BACKUP_PASS" ] && return 0; echo "пустой файл пароля $PF"; return 1; fi
  [ -n "$AWG_BACKUP_PASS" ] && return 0
  local a b
  [ -r /dev/tty ] || { echo "нужен пароль: задайте AWG_BACKUP_PASS или --pass-file"; return 1; }
  read -rsp "Пароль для копии: " a < /dev/tty; echo
  if [ "$1" = twice ]; then read -rsp "Повторите пароль: " b < /dev/tty; echo; [ "$a" = "$b" ] || { echo "пароли не совпадают"; return 1; }; fi
  [ -n "$a" ] || { echo "пустой пароль не допускается"; return 1; }
  AWG_BACKUP_PASS=$a; export AWG_BACKUP_PASS
}
have_ssl(){ command -v openssl >/dev/null; }
encrypt(){ openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -md sha256 -pass env:AWG_BACKUP_PASS -in "$1" -out "$2"; }
decrypt(){ openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -pass env:AWG_BACKUP_PASS -in "$1" -out "$2" 2>/dev/null; }

list_files(){  # относительные пути, входящие в копию (пароль автокопии backup.pass не входит)
  ( cd "$DD" || exit 1
    ls -1 awg.env *.conf telegram.env hooks.env ha.env backup.env rail.conf *.service *.sh VERSION motd.orig events.log .panel .audit .installer .manifest .units 2>/dev/null
    ls -1 web/users.json web/web.conf web/labels.json web/cert.pem web/key.pem web/tokens.json 2>/dev/null
    [ $BINS = 1 ] && ls -1 awg amneziawg-go 2>/dev/null )
}
prune(){ ls -1t "$BK"/awg-*.tgz* 2>/dev/null | tail -n +$((BK_KEEP + 1)) | while read -r o; do rm -f "$o"; done; }

make_copy(){  # make_copy ПОВТОР_ПАРОЛЯ(twice|"") — собрать копию, путь в $f
  mkdir -p "$BK"; chmod 700 "$BK"
  local ts tmp; ts=$(date +%Y%m%d-%H%M%S); tmp=$(mktemp "$DD/.bk.XXXXXX")
  # shellcheck disable=SC2046
  ( cd "$DD" && tar czf "$tmp" $(list_files | tr '\n' ' ') ) || { rm -f "$tmp"; echo "не удалось собрать архив"; return 1; }
  if [ $PLAIN = 1 ]; then
    f=${OUT:-$BK/awg-$ts.tgz}; mv "$tmp" "$f"; chmod 600 "$f"
    echo "ВНИМАНИЕ: копия НЕ зашифрована и содержит ключи: $f"
  else
    have_ssl || { rm -f "$tmp"; echo "нет openssl: зашифровать нельзя. Используйте --plain (небезопасно) или установите openssl."; return 1; }
    getpass "$1" || { rm -f "$tmp"; return 1; }
    f=${OUT:-$BK/awg-${PREFIX:-}$ts.tgz.enc}
    encrypt "$tmp" "$f" || { rm -f "$tmp" "$f"; echo "ошибка шифрования"; return 1; }
    rm -f "$tmp"; chmod 600 "$f"
    echo "копия создана и зашифрована: $f ($(du -h "$f" | cut -f1))"
  fi
  prune
}

open_copy(){  # open_copy ФАЙЛ ВЫХОД — расшифровать (если .enc) и проверить, что это архив tar.gz
  case "$1" in
    *.enc) have_ssl || { echo "нет openssl"; return 1; }
           getpass || return 1
           decrypt "$1" "$2" || { echo "не удалось расшифровать (неверный пароль или файл повреждён)"; return 1; };;
    *) cp "$1" "$2";;
  esac
  tar tzf "$2" >/dev/null 2>&1 || { echo "архив повреждён или пароль неверный"; return 1; }
}

# ---- отправка вне роутера (#12)
valid_vps(){
  [[ $BK_VPS_HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$ ]] || { echo "VPS: не задан или неверный адрес (BK_VPS_HOST)"; return 1; }
  [[ $BK_VPS_PORT =~ ^[0-9]{1,5}$ ]] || { echo "VPS: неверный порт"; return 1; }
  [[ $BK_VPS_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "VPS: неверное имя пользователя"; return 1; }
  [[ $BK_VPS_DIR =~ ^/[A-Za-z0-9._/-]{1,200}$ ]] && [[ $BK_VPS_DIR != *..* ]] || { echo "VPS: папка — абсолютный путь из букв, цифр, . _ - /"; return 1; }
  [ -f "$RKEY" ] || { echo "VPS: нет ключа роутера $RKEY (создаётся установщиком при настройке VPS: install.sh → VPS)"; return 1; }
  mkdir -p "$DD/ssh"; chmod 700 "$DD/ssh"
  SSHO=(-p "$BK_VPS_PORT" -i "$RKEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$DD/ssh/known_hosts")
  SCPO=(-q -P "$BK_VPS_PORT" -i "$RKEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$DD/ssh/known_hosts")
}
vrun(){ ssh "${SSHO[@]}" "$BK_VPS_USER@$BK_VPS_HOST" "$@" < /dev/null; }
ship_vps(){  # ship_vps ФАЙЛ
  local n sum r
  valid_vps || return 1
  n=$(basename "$1"); sum=$(sha256sum "$1" | cut -d' ' -f1)
  r=$(vrun "mkdir -p '$BK_VPS_DIR' && chmod 700 '$BK_VPS_DIR'" 2>&1) || { echo "VPS: не удалось войти или создать папку: $(echo "$r" | tail -n 1)"; return 1; }
  r=$(scp "${SCPO[@]}" "$1" "$BK_VPS_USER@$BK_VPS_HOST:$BK_VPS_DIR/$n.part" 2>&1) || { echo "VPS: передача не удалась: $(echo "$r" | tail -n 1)"; return 1; }
  # сверка суммы на той стороне, затем атомарное переименование и хранение последних N
  r=$(vrun "cd '$BK_VPS_DIR' && [ \"\$(sha256sum '$n.part' | cut -d' ' -f1)\" = '$sum' ] && mv -f '$n.part' '$n' && chmod 600 '$n' && echo SAVED; ls -1t awg-*.tgz* 2>/dev/null | grep -v '\\.part\$' | tail -n +$((BK_VPS_KEEP + 1)) | while read -r o; do rm -f \"\$o\"; done; ls -1 awg-*.tgz* 2>/dev/null | grep -vc '\\.part\$'" 2>&1)
  echo "$r" | grep -qx SAVED || { echo "VPS: контрольная сумма на сервере не совпала"; vrun "rm -f '$BK_VPS_DIR/$n.part'" >/dev/null 2>&1; return 1; }
  echo "VPS: $BK_VPS_USER@$BK_VPS_HOST:$BK_VPS_DIR/$n (сумма совпала, копий там: $(echo "$r" | tail -n1))"
}
ship_tg(){  # ship_tg ФАЙЛ — документом администраторам (TG_CHAT); TG_VIEWERS копии не получают
  local c chats=() code i ok=1 ifs=() b
  [ -r "$DD/telegram.env" ] || { echo "Telegram: не настроен (telegram.env)"; return 1; }
  # shellcheck disable=SC1091
  . "$DD/telegram.env"
  for c in $(printf '%s' "${TG_CHAT:-}" | tr ',;' '  '); do c=$(printf '%s' "$c" | tr -cd '0-9-'); [ -n "$c" ] && chats+=("$c"); done
  [ ${#chats[@]} -gt 0 ] && [ -n "${TG_TOKEN:-}" ] || { echo "Telegram: нет токена или администраторов (TG_CHAT)"; return 1; }
  # тем же путём, что и уведомления: основной туннель → запасной → WAN
  ifs=("$( { . "$DD/awg.env"; } 2>/dev/null; echo "${MAIN:-awgmain}")")
  b=$( { . "$DD/awg.env"; } 2>/dev/null; echo "${BACKUP:-}"); [ -n "$b" ] && ifs+=("$b")
  [ "${TG_NO_WAN:-0}" = 1 ] || ifs+=("")
  for c in "${chats[@]}"; do
    for i in "${ifs[@]}"; do
      code=$(printf 'url = "https://api.telegram.org/bot%s/sendDocument"\n' "$TG_TOKEN" | curl -4 -s -m 60 ${i:+--interface "$i"} -o /dev/null -w '%{http_code}' -K - \
        -F "chat_id=$c" -F "document=@$1" -F "caption=💾 Резервная копия UDR-Amnezia · $(hostname) · $(date '+%F %H:%M'). Пароль — ваш пароль автокопии." 2>/dev/null)
      [ "$code" = 200 ] && { ok=0; break; }
    done
    [ "$code" = 200 ] || echo "Telegram: чат $c — HTTP ${code:-000}"
  done
  [ $ok = 0 ] && echo "Telegram: отправлено (${#chats[@]} адм.)" || echo "Telegram: не доставлено"
  return $ok
}
ship(){  # ship ФАЙЛ — куда включено; код 1, если хоть одна отправка не удалась
  local rc=0 any=0
  if [ "$BK_VPS" = yes ]; then any=1; ship_vps "$1" || rc=1; fi
  if [ "$BK_TG" = yes ]; then any=1; ship_tg "$1" || rc=1; fi
  [ $any = 1 ] || echo "отправка вне роутера выключена: копия только в $BK"
  return $rc
}
status(){  # status OK|FAIL ФАЙЛ ТЕКСТ — для панели (последние 30), событие в журнал, при сбое — Telegram
  local st=$1 file=$2 msg; msg=$(printf '%s' "$3" | tr '\n|' '; ' | cut -c1-400)
  mkdir -p "$BK"; printf '%s|%s|%s|%s\n' "$(date +%s)" "$st" "$(basename "${file:-}")" "$msg" >> "$BK/auto.status"
  tail -n 30 "$BK/auto.status" > "$BK/auto.status.t" && mv "$BK/auto.status.t" "$BK/auto.status"
  echo "$(date +%s)|backup|$( [ "$st" = OK ] && echo "автокопия: $msg" || echo "автокопия НЕ удалась: $msg")" >> "$DD/events.log"
  if [ "$st" != OK ] && { [ -r "$DD/telegram.env" ] || [ -r "$DD/hooks.env" ]; } && [ -x "$DD/notify.sh" ]; then
    "$DD/notify.sh" "⚠️ Резервная копия UDR-Amnezia не удалась · $(hostname)
$msg" >/dev/null 2>&1
  fi
}

case "$cmd" in
  create)
    make_copy twice || exit 1
    echo "скопируйте на компьютер: scp root@$(hostname):$f ."
    ;;
  auto)
    exec 8>/tmp/awg-backup.lock; command -v flock >/dev/null && { flock -n 8 || { echo "автокопия уже выполняется"; exit 1; }; }
    [ -s "$DD/backup.pass" ] || { status FAIL "" "не задан пароль автокопии (панель: Резервные копии → Автокопия)"; echo "нет $DD/backup.pass"; exit 1; }
    PF=$DD/backup.pass; PREFIX=auto-; PLAIN=0; OUT=""
    lf=$(mktemp "$DD/.bk.XXXXXX")
    if ! make_copy > "$lf" 2>&1; then log=$(cat "$lf"); rm -f "$lf"; status FAIL "" "$log"; echo "$log"; exit 1; fi
    cat "$lf"; rm -f "$lf"
    # проверка восстановления: расшифровать и прочитать архив, в нём должны быть настройки
    tmp=$(mktemp "$DD/.bk.XXXXXX")
    if ! v=$(open_copy "$f" "$tmp" 2>&1) || ! tar tzf "$tmp" 2>/dev/null | grep -qx awg.env; then
      rm -f "$tmp" "$f"; status FAIL "" "проверка копии не прошла: ${v:-в архиве нет awg.env}"; echo "проверка не прошла"; exit 1
    fi
    n=$(tar tzf "$tmp" | wc -l); rm -f "$tmp"
    echo "проверка: копия расшифровывается, файлов: $n"
    out=$(ship "$f" 2>&1); rc=$?
    echo "$out"
    msg="$(basename "$f"), $(du -h "$f" | cut -f1), файлов $n; $(echo "$out" | tr '\n' ';' | sed 's/;$//')"
    if [ $rc = 0 ]; then status OK "$f" "$msg"; else status FAIL "$f" "$msg"; fi
    exit $rc
    ;;
  ship)
    [ -f "$FILE" ] || { [ -f "$BK/$FILE" ] && FILE=$BK/$FILE; }
    [ -f "$FILE" ] || { echo "нет файла копии: укажите путь"; exit 1; }
    ship "$FILE"
    ;;
  vps-test)
    valid_vps || exit 1
    r=$(vrun "mkdir -p '$BK_VPS_DIR' && chmod 700 '$BK_VPS_DIR' && t=\$(mktemp '$BK_VPS_DIR/.t.XXXXXX') && rm -f \"\$t\" && echo WRITABLE && df -h '$BK_VPS_DIR' | awk 'NR==2{print \$4}' && ls -1 '$BK_VPS_DIR'/awg-*.tgz* 2>/dev/null | wc -l" 2>&1)
    if echo "$r" | grep -qx WRITABLE; then
      echo "VPS: вход ключом роутера работает, папка $BK_VPS_DIR доступна для записи (свободно $(echo "$r" | sed -n '/^WRITABLE$/{n;p}'), копий: $(echo "$r" | tail -n1))"
    else
      echo "VPS: не удалось: $(echo "$r" | tail -n 2 | tr '\n' ' ')"
      echo "$r" | grep -qi 'permission denied' && echo "подсказка: ключа роутера нет на VPS — запустите install.sh → VPS один раз или добавьте $RKEY.pub в ~/.ssh/authorized_keys на VPS"
      exit 1
    fi
    ;;
  timer)   # расписание строится из backup.env: так оно переживает обновление набора и прошивки (awg-restore вызывает timer)
    SYSD=${SYSD:-/etc/systemd/system}
    case "$BK_AUTO" in daily) cal='*-*-* 04:20:00';; weekly) cal='Sun *-*-* 04:20:00';; *) cal="";; esac
    if [ -z "$cal" ]; then
      systemctl disable --now awg-backup.timer >/dev/null 2>&1; rm -f "$SYSD/awg-backup.timer" "$SYSD/awg-backup.service"
      systemctl daemon-reload 2>/dev/null; echo "автокопия по расписанию выключена"; exit 0
    fi
    [ -f "$DD/awg-backup.service" ] || { echo "нет $DD/awg-backup.service"; exit 1; }
    cp "$DD/awg-backup.service" "$SYSD/awg-backup.service"
    printf '[Unit]\nDescription=AWG: резервная копия по расписанию (%s)\n\n[Timer]\nOnCalendar=%s\nRandomizedDelaySec=40min\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$BK_AUTO" "$cal" > "$SYSD/awg-backup.timer"
    chmod 644 "$SYSD/awg-backup.timer" "$SYSD/awg-backup.service"
    systemctl daemon-reload 2>/dev/null; systemctl enable --now awg-backup.timer >/dev/null 2>&1
    echo "автокопия по расписанию: $([ "$BK_AUTO" = daily ] && echo ежедневно || echo еженедельно, в воскресенье) около 04:20–05:00"
    ;;
  list)
    ls -lh "$BK" 2>/dev/null | sed 1d || echo "копий нет"
    ;;
  verify|restore)
    [ -f "$FILE" ] || { [ -f "$BK/$FILE" ] && FILE=$BK/$FILE; }
    [ -f "$FILE" ] || { echo "нет файла копии: укажите путь"; exit 1; }
    tmp=$(mktemp "$DD/.bk.XXXXXX")
    open_copy "$FILE" "$tmp" || { rm -f "$tmp"; exit 1; }
    echo "содержимое копии:"; tar tzf "$tmp" | sed 's/^/  /'
    if [ "$cmd" = verify ]; then rm -f "$tmp"; echo "копия читается, пароль верный"; exit 0; fi
    mkdir -p "$BK"; pre=$BK/pre-restore-$(date +%Y%m%d-%H%M%S).tgz
    # shellcheck disable=SC2046
    ( cd "$DD" && tar czf "$pre" $(list_files | tr '\n' ' ') 2>/dev/null ); chmod 600 "$pre"
    echo "текущие настройки сохранены: $pre"
    tar xzf "$tmp" -C "$DD" && rm -f "$tmp" || { rm -f "$tmp"; echo "ошибка распаковки"; exit 1; }
    chmod 600 "$DD"/*.conf "$DD/awg.env" "$DD/telegram.env" "$DD/hooks.env" "$DD/ha.env" "$DD/backup.env" 2>/dev/null
    echo "восстановлено в $DD. Дальше: $DD/install.sh --restore (вернёт службы и правила)"
    ;;
  *) sed -n '2,16p' "$0";;
esac
