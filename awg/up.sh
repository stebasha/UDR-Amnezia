#!/bin/bash
# up.sh — поднимает туннели AmneziaWG из конфигов в /data/awg
#   up.sh            все туннели: MAIN и, если задан, BACKUP (из awg.env)
#   up.sh awgmain    один туннель (интерфейс пересоздаётся; так применяют новый конфиг)
# Конфиги: main.conf — основной, backup.conf — запасной.
DD=${DD:-/data/awg}
cd "$DD" || exit 1
[ -r awg.env ] && . ./awg.env
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}
umask 077

conf_of(){
  if [ "$1" = "$MAIN" ]; then echo main.conf
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then
    if [ -f backup.conf ] || [ ! -f client.conf ]; then echo backup.conf; else echo client.conf; fi
  fi
}

bring_up(){
  local n=$1 conf raw tmp addr mtu k
  conf=$(conf_of "$n")
  [ -z "$conf" ] && { echo "ОШИБКА: $n не указан в awg.env как MAIN или BACKUP"; return 1; }
  [ -f "$conf" ] || { echo "ОШИБКА: нет файла $DD/$conf"; return 1; }
  raw=/run/$n.raw; tmp=/run/$n.awg.conf
  sed 's/\r$//' "$conf" > "$raw"
  # Address и MTU утилита awg не понимает: берём их сами, из Address только IPv4
  addr=$(awk -F'=' 'tolower($1) ~ /^[ \t]*address[ \t]*$/ {print $2; exit}' "$raw" | tr ',' '\n' | tr -d ' \t' | grep -m1 '\.')
  mtu=$(awk -F'=' 'tolower($1) ~ /^[ \t]*mtu[ \t]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$raw")
  [ -z "$addr" ] && { echo "ОШИБКА: в $conf нет IPv4-адреса в строке Address"; rm -f "$raw"; return 1; }
  case "$addr" in */*) ;; *) addr=$addr/32 ;; esac
  [ -z "$mtu" ] && mtu=1380
  # убираем директивы wg-quick; маршрутизирует сторож, поэтому AllowedIPs = только IPv4 default
  grep -v -i -E '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$raw" \
    | sed -E 's/^[[:space:]]*AllowedIPs[[:space:]]*=.*/AllowedIPs = 0.0.0.0\/0/' > "$tmp"
  rm -f "$raw"

  ip link show "$n" >/dev/null 2>&1 && ip link del "$n"
  ./amneziawg-go "$n" >/dev/null 2>&1
  for k in 1 2 3 4 5 6 7 8 9 10; do ip link show "$n" >/dev/null 2>&1 && break; sleep 0.3; done
  if ! ./awg setconf "$n" "$tmp"; then
    echo "ОШИБКА: awg setconf $n (строка, которую awg не понял, указана выше)"
    ip link del "$n" 2>/dev/null; rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  ip addr add "$addr" dev "$n"
  ip link set "$n" up mtu "$mtu"
  sysctl -qw "net.ipv4.conf.$n.rp_filter=0" 2>/dev/null
  echo "$n поднят: адрес $addr, MTU $mtu, конфиг $conf"
}

if [ -n "$1" ]; then bring_up "$1"; exit $?; fi
rc=0
bring_up "$MAIN" || rc=1
if [ -n "$BACKUP" ]; then bring_up "$BACKUP" || rc=1; fi
exit $rc
