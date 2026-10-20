#!/bin/bash
# up.sh — поднимает туннели AmneziaWG из конфигов в /data/awg
#   up.sh            все туннели: MAIN, BACKUP и TUNNELS_EXTRA (из awg.env)
#   up.sh awgmain    один туннель (интерфейс пересоздаётся; так применяют новый конфиг)
#   up.sh --conf-of ИМЯ   имя файла конфига туннеля (для сторожа)
# IPv6 (#23): при LEAK_V6=route IPv6-адрес из Address тоже назначается, AllowedIPs = 0.0.0.0/0, ::/0.
# VLESS/Reality (#42): туннели из XRAY_TUNNELS — процесс Xray (служба awg-xray-ИМЯ, вход tun), конфиг xray/ИМЯ.json.
# Конфиги: main.conf — основной, backup.conf (или client.conf) — запасной, <имя>.conf — дополнительные.
DD=${DD:-/data/awg}
cd "$DD" || exit 1
[ -r awg.env ] && . ./awg.env
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNNELS_EXTRA=${TUNNELS_EXTRA:-}; LEAK_V6=${LEAK_V6:-block}; XRAY_TUNNELS=${XRAY_TUNNELS:-}
umask 077

is_xray(){ case " $XRAY_TUNNELS " in *" $1 "*) return 0;; esac; return 1; }

conf_of(){
  if is_xray "$1"; then case " $TUNNELS_EXTRA " in *" $1 "*) echo "xray/$1.json";; esac
  elif [ "$1" = "$MAIN" ]; then echo main.conf
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then
    if [ -f backup.conf ] || [ ! -f client.conf ]; then echo backup.conf; else echo client.conf; fi
  else
    case " $TUNNELS_EXTRA " in *" $1 "*) echo "$1.conf";; esac
  fi
}

# Endpoint с именем хоста заменяем на IPv4: awg собран статически, и разрешение имён внутри него
# зависит от библиотек роутера. Имя разрешает сам роутер (getent), как и wg-quick при запуске.
resolve_endpoint(){  # resolve_endpoint ФАЙЛ ИНТЕРФЕЙС
  local f=$1 ep host port ip cache=$DD/.endpoint-$2
  ep=$(awk -F'=' 'tolower($1) ~ /^[ \t]*endpoint[ \t]*$/ {gsub(/[ \t\r]/,"",$2); print $2; exit}' "$f")
  [ -n "$ep" ] || return 0
  host=${ep%:*}; port=${ep##*:}
  case "$host" in \[*|*[!0-9.]*) ;; *) return 0;; esac        # уже IPv4
  case "$host" in \[*) return 0;; esac                         # IPv6 — оставляем как есть
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -n "$ip" ]; then
    echo "$host $ip" > "$cache"
  elif [ -s "$cache" ] && [ "$(cut -d' ' -f1 "$cache")" = "$host" ]; then
    # DNS сейчас недоступен (например, весь DNS роутера идёт через туннель, а туннеля ещё нет): берём прошлый адрес
    ip=$(cut -d' ' -f2 "$cache"); echo "ВНИМАНИЕ: $host не разрешается, беру последний известный адрес $ip"
  else
    echo "ВНИМАНИЕ: не удалось разрешить $host, оставляю имя в Endpoint"; return 0
  fi
  sed -i -E "s|^([[:space:]]*[Ee][Nn][Dd][Pp][Oo][Ii][Nn][Tt][[:space:]]*=[[:space:]]*).*|\1$ip:$port|" "$f"
  echo "Endpoint $host → $ip"
}

jval(){ sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\).*/\1/p" "$2" | head -1; }   # jval КЛЮЧ ФАЙЛ — простое поле из .info

bring_up_xray(){  # туннель VLESS: Xray создаёт интерфейс TUN сам; адрес, MTU и rp_filter — как у AmneziaWG
  local n=$1 cfg="$DD/xray/$1.json" info="$DD/xray/$1.info" addr mtu u="awg-xray-$1"
  [ -x "$DD/xray/xray" ] || { echo "ОШИБКА: Xray не установлен ($DD/xray/xray): «Туннели → VLESS → Установить Xray»"; return 1; }
  [ -f "$cfg" ] || { echo "ОШИБКА: нет файла $cfg"; return 1; }
  addr=$(jval addr "$info"); mtu=$(jval mtu "$info")
  [[ "$addr" =~ ^[0-9.]+/[0-9]+$ ]] || { echo "ОШИБКА: в $info нет адреса туннеля"; return 1; }
  [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1400
  "$DD/xray/xray" run -test -c "$cfg" >/dev/null 2>&1 || { echo "ОШИБКА: Xray не принял конфиг $cfg:"; "$DD/xray/xray" run -test -c "$cfg" 2>&1 | tail -3; return 1; }
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop "$u" >/dev/null 2>&1; systemctl reset-failed "$u" >/dev/null 2>&1
  else
    pkill -f "xray run -c $cfg" 2>/dev/null
  fi
  ip link show "$n" >/dev/null 2>&1 && ip link del "$n"
  # отдельная служба с перезапуском при сбое: Xray не зависит от службы, которая поднимает туннель (как scope у amneziawg-go)
  if [ -z "${AWG_NO_SCOPE:-}" ] && [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1; then
    systemd-run --unit="$u" --collect --quiet --description="Xray VLESS $n" -p Restart=on-failure -p RestartSec=5 \
      -p MemoryMax=192M -p Nice=5 "$DD/xray/xray" run -c "$cfg" >/dev/null 2>&1 || { echo "ОШИБКА: не запустилась служба $u"; return 1; }
  else
    setsid "$DD/xray/xray" run -c "$cfg" >"${AWG_RUN:-/run}/$u.log" 2>&1 < /dev/null &
  fi
  for _ in $(seq 1 30); do ip link show "$n" >/dev/null 2>&1 && break; sleep 0.3; done
  ip link show "$n" >/dev/null 2>&1 || { echo "ОШИБКА: Xray не создал интерфейс $n (журнал: journalctl -u $u)"; return 1; }
  ip addr add "$addr" dev "$n" 2>/dev/null
  ip link set "$n" up mtu "$mtu"
  sysctl -qw "net.ipv4.conf.$n.rp_filter=0" 2>/dev/null
  echo "$n поднят: VLESS через Xray, адрес $addr, MTU $mtu, конфиг xray/$n.json"
}

bring_up(){
  local n=$1 conf raw tmp addr addr6="" mtu allowed="0.0.0.0\/0"
  conf=$(conf_of "$n")
  if [ -n "$conf" ] && is_xray "$n"; then bring_up_xray "$n"; return $?; fi
  [ -z "$conf" ] && { echo "ОШИБКА: $n не указан в awg.env (MAIN, BACKUP или TUNNELS_EXTRA)"; return 1; }
  [ -f "$conf" ] || { echo "ОШИБКА: нет файла $DD/$conf"; return 1; }
  raw=${AWG_RUN:-/run}/$n.raw; tmp=${AWG_RUN:-/run}/$n.awg.conf
  sed 's/\r$//' "$conf" > "$raw"
  # Address и MTU утилита awg не понимает: берём их сами, из Address только IPv4
  addr=$(awk -F'=' 'tolower($1) ~ /^[ \t]*address[ \t]*$/ {print $2; exit}' "$raw" | tr ',' '\n' | tr -d ' \t' | grep -m1 '\.')
  mtu=$(awk -F'=' 'tolower($1) ~ /^[ \t]*mtu[ \t]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$raw")
  [ -z "$addr" ] && { echo "ОШИБКА: в $conf нет IPv4-адреса в строке Address"; rm -f "$raw"; return 1; }
  case "$addr" in */*) ;; *) addr=$addr/32 ;; esac
  [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=1380
  if [ "$LEAK_V6" = route ]; then     # IPv6 через туннель (#23): адрес IPv6 из Address, если сервер его выдал
    addr6=$(awk -F'=' 'tolower($1) ~ /^[ \t]*address[ \t]*$/ {print $2; exit}' "$raw" | tr ',' '\n' | tr -d ' \t' | grep -m1 ':')
    [ -n "$addr6" ] && { case "$addr6" in */*) ;; *) addr6=$addr6/128 ;; esac; allowed="0.0.0.0\/0, ::\/0"; }
  fi
  # убираем директивы wg-quick; маршрутизирует сторож, поэтому AllowedIPs = только default (IPv4, и IPv6 при #23)
  grep -v -i -E '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$raw" \
    | sed -E "s/^[[:space:]]*AllowedIPs[[:space:]]*=.*/AllowedIPs = $allowed/" > "$tmp"
  rm -f "$raw"
  resolve_endpoint "$tmp" "$n"

  ip link show "$n" >/dev/null 2>&1 && ip link del "$n"
  # amneziawg-go — в собственной группе процессов (scope systemd), а не в группе службы, которая поднимает туннель
  # (сторож, панель, маршрут): иначе перезапуск этой службы (смена настроек, обновление) убивал процесс, интерфейс
  # пропадал и туннель лежал, пока сторож не поднимет его заново.
  if { [ -n "${AWG_FORCE_SCOPE:-}" ] || { [ "${EUID:-1}" = 0 ] && [ -d /run/systemd/system ]; }; } && [ -z "${AWG_NO_SCOPE:-}" ] \
     && command -v systemd-run >/dev/null 2>&1; then
    systemd-run --scope --quiet --collect --description="AmneziaWG $n" "$DD/amneziawg-go" "$n" >/dev/null 2>&1 \
      || { ip link show "$n" >/dev/null 2>&1 || ./amneziawg-go "$n" >/dev/null 2>&1; }
  else
    ./amneziawg-go "$n" >/dev/null 2>&1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do ip link show "$n" >/dev/null 2>&1 && break; sleep 0.3; done
  if ! ./awg setconf "$n" "$tmp"; then
    echo "ОШИБКА: awg setconf $n (строка, которую awg не понял, указана выше)"
    ip link del "$n" 2>/dev/null; rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  ip addr add "$addr" dev "$n"
  if [ -n "$addr6" ]; then sysctl -qw "net.ipv6.conf.$n.disable_ipv6=0" 2>/dev/null; ip -6 addr add "$addr6" dev "$n" nodad 2>/dev/null; fi
  ip link set "$n" up mtu "$mtu"
  sysctl -qw "net.ipv4.conf.$n.rp_filter=0" 2>/dev/null
  echo "$n поднят: адрес $addr${addr6:+ и $addr6}, MTU $mtu, конфиг $conf"
}

if [ "$1" = --conf-of ]; then conf_of "$2"; exit 0; fi
if [ -n "$1" ]; then bring_up "$1"; exit $?; fi
rc=0
bring_up "$MAIN" || rc=1
if [ -n "$BACKUP" ]; then bring_up "$BACKUP" || rc=1; fi
for t in $TUNNELS_EXTRA; do bring_up "$t" || rc=1; done
exit $rc
