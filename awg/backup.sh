#!/bin/bash
# awg-backup: резервная копия настроек (конфиги с ключами, awg.env, telegram.env, юниты, скрипты) в один зашифрованный файл.
#   backup.sh create [-o ФАЙЛ] [--with-bins] [--plain] [--pass-file Ф]
#   backup.sh list
#   backup.sh restore ФАЙЛ [--pass-file Ф]
#   backup.sh verify  ФАЙЛ [--pass-file Ф]
# Шифрование: openssl AES-256-CBC, PBKDF2 200000 итераций. Пароль: запрос в терминале, либо переменная AWG_BACKUP_PASS,
# либо файл (--pass-file). Без пароля копия не читается: храните пароль отдельно от файла.
# Копии лежат в /data/awg/backups (хранятся последние 7), скопируйте файл на компьютер: scp root@РОУТЕР:/data/awg/backups/ФАЙЛ .
DD=${DD:-/data/awg}
BK=$DD/backups
umask 077
cmd=${1:-help}; shift
OUT=""; PLAIN=0; BINS=0; PF=""; FILE=""
while [ $# -gt 0 ]; do case "$1" in
  -o) OUT=$2; shift;; --plain) PLAIN=1;; --with-bins) BINS=1;; --pass-file) PF=$2; shift;;
  *) FILE=$1;; esac; shift; done

getpass(){  # getpass [повтор]
  if [ -n "$PF" ]; then AWG_BACKUP_PASS=$(head -n1 "$PF"); export AWG_BACKUP_PASS; return 0; fi
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

list_files(){  # относительные пути, входящие в копию
  ( cd "$DD" || exit 1
    ls -1 awg.env *.conf telegram.env rail.conf *.service *.sh VERSION motd.orig events.log .panel .audit .installer .manifest 2>/dev/null
    [ $BINS = 1 ] && ls -1 awg amneziawg-go 2>/dev/null )
}

case "$cmd" in
  create)
    mkdir -p "$BK"; chmod 700 "$BK"
    ts=$(date +%Y%m%d-%H%M%S); tmp=$(mktemp "$DD/.bk.XXXXXX")
    ( cd "$DD" && tar czf "$tmp" $(list_files | tr '\n' ' ') ) || { rm -f "$tmp"; echo "не удалось собрать архив"; exit 1; }
    if [ $PLAIN = 1 ]; then
      f=${OUT:-$BK/awg-$ts.tgz}; mv "$tmp" "$f"; chmod 600 "$f"
      echo "ВНИМАНИЕ: копия НЕ зашифрована и содержит ключи: $f"
    else
      have_ssl || { rm -f "$tmp"; echo "нет openssl: зашифровать нельзя. Используйте --plain (небезопасно) или установите openssl."; exit 1; }
      getpass twice || { rm -f "$tmp"; exit 1; }
      f=${OUT:-$BK/awg-$ts.tgz.enc}
      encrypt "$tmp" "$f" || { rm -f "$tmp" "$f"; echo "ошибка шифрования"; exit 1; }
      rm -f "$tmp"; chmod 600 "$f"
      echo "копия создана и зашифрована: $f ($(du -h "$f" | cut -f1))"
    fi
    # хранить последние 7 копий в стандартной папке
    ls -1t "$BK"/awg-*.tgz* 2>/dev/null | tail -n +8 | while read -r o; do rm -f "$o"; done
    echo "скопируйте на компьютер: scp root@$(hostname):$f ."
    ;;
  list)
    ls -lh "$BK" 2>/dev/null | sed 1d || echo "копий нет"
    ;;
  verify|restore)
    [ -f "$FILE" ] || { [ -f "$BK/$FILE" ] && FILE=$BK/$FILE; }
    [ -f "$FILE" ] || { echo "нет файла копии: укажите путь"; exit 1; }
    tmp=$(mktemp "$DD/.bk.XXXXXX")
    case "$FILE" in
      *.enc) have_ssl || { echo "нет openssl"; rm -f "$tmp"; exit 1; }
             getpass || { rm -f "$tmp"; exit 1; }
             decrypt "$FILE" "$tmp" || { rm -f "$tmp"; echo "не удалось расшифровать (неверный пароль или файл повреждён)"; exit 1; };;
      *) cp "$FILE" "$tmp";;
    esac
    tar tzf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; echo "архив повреждён или пароль неверный"; exit 1; }
    echo "содержимое копии:"; tar tzf "$tmp" | sed 's/^/  /'
    if [ "$cmd" = verify ]; then rm -f "$tmp"; echo "копия читается, пароль верный"; exit 0; fi
    mkdir -p "$BK"; pre=$BK/pre-restore-$(date +%Y%m%d-%H%M%S).tgz
    ( cd "$DD" && tar czf "$pre" $(list_files | tr '\n' ' ') 2>/dev/null ); chmod 600 "$pre"
    echo "текущие настройки сохранены: $pre"
    tar xzf "$tmp" -C "$DD" && rm -f "$tmp" || { rm -f "$tmp"; echo "ошибка распаковки"; exit 1; }
    chmod 600 "$DD"/*.conf "$DD/awg.env" "$DD/telegram.env" 2>/dev/null
    echo "восстановлено в $DD. Дальше: $DD/install.sh --restore (вернёт службы и правила)"
    ;;
  *) sed -n '2,10p' "$0";;
esac
