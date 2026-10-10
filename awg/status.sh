#!/bin/bash
# awgs — панель состояния AmneziaWG failover (только чтение)
#   awgs        полная панель    awgs -s   кратко    awgs -i   с внешними IP туннелей
DD=${DD:-/data/awg}
AWG=${AWG:-$DD/awg}
LOG=$DD/failover.log
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-0}; MARK=${MARK:-0x0/0x0}; RAIL_IF=${RAIL_IF:-wgclt1}; WANIF=${WANIF:-eth3}
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; IFACES="$MAIN${BACKUP:+ $BACKUP}"
MODE=full; WANT_IP=0
for a in "$@"; do case $a in
  -s) MODE=short;;
  -i) WANT_IP=1;;
  -h|--help) echo "awgs [-s кратко] [-i внешние IP через туннели]"; exit 0;;
esac; done

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else G=; R=; Y=; C=; B=; D=; N=; fi

W=78
if [ "$AWGS_ASCII" = 1 ]; then LN='-'; else LN='━'; fi
rep(){ local s='' k; for ((k=0;k<$2;k++)); do s+=$1; done; printf '%s' "$s"; }
hdr(){ local t=" $1 "; echo "${D}$(rep "$LN" 2)${N}${B}${t}${N}${D}$(rep "$LN" $((W-${#t}-2)))${N}"; }
hum(){ awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++} if(i==1) printf("%d %s",b,u[i]); else printf("%.1f %s",b,u[i])}'; }
mbit(){ awk -v b="${1:-0}" 'BEGIN{printf("%.2f",b*8/1000000)}'; }
age_s(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
age_f(){ local s=$1; if [ "$s" -lt 0 ]; then echo never; elif [ "$s" -lt 120 ]; then echo "${s}s"; elif [ "$s" -lt 7200 ]; then echo "$((s/60))m$((s%60))s"; elif [ "$s" -lt 172800 ]; then echo "$((s/3600))h$(((s%3600)/60))m"; else echo "$((s/86400))d"; fi; }
st_of(){ local a=$1; if [ "$a" -lt 0 ]; then echo DOWN; elif [ "$a" -lt 180 ]; then echo UP; elif [ "$a" -lt 900 ]; then echo IDLE; else echo STALE; fi; }
col_of(){ case $1 in UP) printf '%s' "$G";; IDLE) printf '%s' "$Y";; *) printf '%s' "$R";; esac; }
rd(){ cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || echo 0; }

declare -A r0 t0 r1 t1
for i in $IFACES; do r0[$i]=$(rd $i rx_bytes); t0[$i]=$(rd $i tx_bytes); done
sleep 1
for i in $IFACES; do r1[$i]=$(rd $i rx_bytes); t1[$i]=$(rd $i tx_bytes); done

rt=$(ip route show table "$TABLE" 2>/dev/null)
active=$(echo "$rt" | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev" && $(i+1) ~ /^awg/){print $(i+1); exit}}')
svc=$(systemctl is-active awg-failover 2>/dev/null)
a_main=$(age_s "$MAIN"); a_bak=-1; [ -n "$BACKUP" ] && a_bak=$(age_s "$BACKUP")
s_main=$(st_of $a_main); s_bak=$(st_of $a_bak)

alerts=(); level=0
add(){ alerts+=("$2|$1"); [ "$2" -gt "$level" ] && level=$2; }
[ "$TABLE" = 0 ] && add "Нет $DD/awg.env: запустите awg-detect.sh" 2
[ "$svc" != active ] && add "Сторож awg-failover не запущен (systemctl start awg-failover)" 2
[ -z "$active" ] && add "В таблице PBR $TABLE нет маршрута на AWG-туннель: трафик по PBR не проходит" 2
[ -n "$BACKUP" ] && [ "$active" = "$BACKUP" ] && add "Работает ЗАПАСНОЙ канал, основной: $s_main" 1
[ "$active" = "$MAIN" ] && [ "$s_main" != UP ] && add "Основной канал: handshake $s_main ($(age_f $a_main))" 1
[ -n "$BACKUP" ] && [ "$s_bak" != UP ] && add "Запасной канал: $s_bak, защиты от падения основного нет" 1
[ -e /tmp/awg-sim-down ] && add "Включён флаг имитации падения /tmp/awg-sim-down (rm /tmp/awg-sim-down)" 1
ip rule show 2>/dev/null | grep -q "fwmark ${MARK%%/*}" || add "Нет PBR-правила fwmark ${MARK%%/*}" 2
for f in main.conf backup.conf client.conf telegram.env awg.env; do
  [ -e "$DD/$f" ] && [ "$(stat -c %a "$DD/$f" 2>/dev/null)" != 600 ] && add "Права $DD/$f не 600 (chmod 600 $DD/$f)" 1
done
du_pct=$(df /data 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
[ -n "$du_pct" ] && [ "$du_pct" -ge 90 ] && add "Раздел /data заполнен на ${du_pct}%" 1

case $level in
  0) badge="${G}${B}● HEALTHY${N}";;
  1) badge="${Y}${B}▲ DEGRADED${N}";;
  *) badge="${R}${B}✖ CRITICAL${N}";;
esac

echo
echo "${B}${C}AmneziaWG Failover${N}  ${D}$(hostname) · $(date '+%F %T') · $(uptime -p 2>/dev/null)${N}"
hdr "STATUS"
if [ -n "$active" ] && [ "$active" = "$MAIN" ]; then ap="${G}${B}$active${N} (основной)"
elif [ -n "$active" ]; then ap="${Y}${B}$active${N} (ЗАПАСНОЙ)"
else ap="${R}${B}нет${N}"; fi
[ "$svc" = active ] && sv="${G}active${N}" || sv="${R}${svc:-unknown}${N}"
echo " Состояние    : $badge"
echo " Канал PBR    : $ap"
echo " Сторож       : $sv"
lastline=$(grep -E "ПЕРЕКЛЮЧЕНИЕ|ВОЗВРАТ|возврат на" "$LOG" 2>/dev/null | tail -n 1)
if [ -n "$lastline" ]; then
  lts=$(date -d "${lastline:0:19}" +%s 2>/dev/null)
  la=""; [ -n "$lts" ] && la=" ($(age_f $(( $(date +%s) - lts ))) назад)"
  echo " Последняя смена: ${lastline}${la}"
  echo " Переключений в логе: $(grep -c 'ПЕРЕКЛЮЧЕНИЕ' "$LOG" 2>/dev/null)"
fi
if [ -n "$BACKUP" ]; then
  iv=${INTERVAL:-5}; fm=${FAIL_MAX:-3}
  echo " Политика     : проверка каждые ${iv}с, переключение после ${fm} сбоев (~$((iv*fm))с), возврат после ${RECOVER_SEC:-600}с без сбоев"
else
  echo " Политика     : один туннель, проверка каждые ${INTERVAL:-5}с; если он упал, PBR-трафик блокируется (без утечки в WAN)"
fi
if [ $WANT_IP = 1 ]; then
  for i in $IFACES; do ( curl -s -m 4 --interface $i https://ifconfig.me > /tmp/awgs.$i 2>/dev/null ) & done; wait
  echo " Внешний IP   : $(for i in $IFACES; do printf '%s=%s  ' $i "$(cat /tmp/awgs.$i 2>/dev/null)"; done)"
  rm -f /tmp/awgs.*
fi

if [ ${#alerts[@]} -gt 0 ]; then
  echo
  hdr "ALERTS"
  for e in "${alerts[@]}"; do
    l=${e%%|*}; m=${e#*|}
    if [ "$l" = 2 ]; then echo " ${R}✖${N} $m"; else echo " ${Y}▲${N} $m"; fi
  done
fi

echo
hdr "TUNNELS"
printf "${B}   %-10s %-7s %-7s %-9s %-22s %10s %10s %8s %8s${N}\n" TUNNEL ROLE STATE HANDSHK ENDPOINT RX TX "DN Mb/s" "UP Mb/s"
for i in $IFACES; do
  if [ "$i" = "$MAIN" ]; then role=main; a=$a_main; s=$s_main; else role=backup; a=$a_bak; s=$s_bak; fi
  mark=" "; [ "$i" = "$active" ] && mark="▶"
  if ! ip link show "$i" >/dev/null 2>&1; then
    printf " %s ${B}%-10s${N} %-7s ${R}%-7s${N}\n" "$mark" "$i" "$role" "NO-IFACE"; continue
  fi
  ep=$($AWG show "$i" endpoints 2>/dev/null | awk 'NR==1{print $2}')
  read -r rx tx < <($AWG show "$i" transfer 2>/dev/null | awk '{r+=$2;t+=$3} END{print r+0, t+0}')
  dr=$(( ${r1[$i]} - ${r0[$i]} )); dt=$(( ${t1[$i]} - ${t0[$i]} ))
  printf " %s ${B}%-10s${N} %-7s $(col_of $s)%-7s${N} %-9s %-22s %10s %10s %8s %8s\n" "$mark" "$i" "$role" "$s" "$(age_f $a)" "${ep:--}" "$(hum $rx)" "$(hum $tx)" "$(mbit $dr)" "$(mbit $dt)"
done
ip link show "$RAIL_IF" >/dev/null 2>&1 && echo " ${D}  $RAIL_IF: профиль-«рельса» UniFi, держит PBR-правило, трафик не несёт${N}"
echo " ${D}▶ активный канал PBR · скорость за 1 с внутри туннеля · UP = handshake < 3 мин${N}"

echo
hdr "SYSTEM"
load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d MiB (%d%%)",$3,$2,$3*100/$2}')
disk=$(df -h /data 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
temp=""; for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && { temp=" · temp $(( $(cat "$z") / 1000 ))°C"; break; }; done
wan=$(ip -4 -br addr show "$WANIF" 2>/dev/null | awk '{print $2, $3}')
echo " Нагрузка : ${load:-?} · RAM ${mem:-?} · /data ${disk:-?}${temp}"
echo " WAN $WANIF : ${wan:-нет данных}"
if systemctl is-enabled awg-notify >/dev/null 2>&1; then echo " Telegram : awg-notify $(systemctl is-active awg-notify 2>/dev/null)"; fi

echo
hdr "EVENTS (last 20)"
if [ -s "$LOG" ]; then ev=$(tail -n 20 "$LOG"); else ev=$(journalctl -t awg-failover -n 20 --no-pager -o short 2>/dev/null | sed -E 's/ [^ ]+ awg-failover(\[[0-9]+\])?:/ /'); fi
[ -z "$ev" ] && ev="(событий пока нет)"
echo "$ev" | sed -e "s/^/ /" -e "s/ПЕРЕКЛЮЧЕНИЕ/${R}&${N}/" -e "s/ВОЗВРАТ/${G}&${N}/" -e "s/ВОССТАНОВЛЕН/${G}&${N}/" -e "s/не отвечает/${Y}&${N}/" -e "s/оба канала/${R}&${N}/"

[ "$MODE" = short ] && { echo; exit 0; }

f(){ printf " ${C}%-48s${N} %s\n" "$1" "$2"; }
echo
hdr "FILES"
f "$DD/awg.env" "параметры: таблица PBR, метка, имена туннелей, возврат"
f "$DD/main.conf" "конфиг основного туннеля ($MAIN), ключи, chmod 600"
[ -n "$BACKUP" ] && f "$DD/backup.conf" "конфиг запасного туннеля ($BACKUP), ключи"
f "$DD/up.sh" "поднять туннели: up.sh [имя туннеля]"
f "$DD/failover.sh" "сторож: проверка, переключение, возврат"
f "$DD/failover.log" "журнал сторожа (~1000 строк)"
f "$DD/status.sh" "эта панель (awgs)"
[ -x "$DD/audit.sh" ] && f "$DD/audit.sh" "аудит (awg-audit)"
f "/etc/systemd/system/awg-*.service" "автозапуск (копии юнитов в $DD)"
[ -x "$DD/awg-restore.sh" ] && f "$DD/awg-restore.sh" "вернуть автозапуск после обновления прошивки"
[ -n "$VPS_IP" ] && f "сервер $VPS_IP: /etc/amnezia/server.conf" "сервер запасного канала (служба awg-server)"

echo
hdr "CHEAT SHEET"
f "awgs | awgs -s | awgs -i" "панель | кратко | с внешними IP"
[ -x "$DD/audit.sh" ] && f "awg-audit" "проверка на лишние правила и файлы (только чтение)"
f "tail -f $DD/failover.log" "события сторожа в реальном времени"
f "ip route show table $TABLE" "активный канал PBR (metric 5)"
f "$DD/awg show $MAIN" "детали туннеля"
f "curl -s --interface $MAIN https://ifconfig.me" "внешний IP через туннель"
[ -n "$BACKUP" ] && f "touch /tmp/awg-sim-down  /  rm /tmp/awg-sim-down" "имитация падения основного / отмена"
f "$DD/up.sh $MAIN" "применить новый main.conf"
f "systemctl restart awg-failover" "перезапуск сторожа (~5 с без PBR-трафика)"
echo
