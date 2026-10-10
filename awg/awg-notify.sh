#!/bin/bash
# awg-notify.sh — уведомления в Telegram о работе failover.
#   awg-notify.sh          демон (запускает systemd: awg-notify.service)
#   awg-notify.sh report   отправить суточный отчёт сейчас
#   awg-notify.sh test     тестовое сообщение со снимком состояния
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
AWG=$DD/awg
LOGF=$DD/failover.log
EV=$DD/notify.events          # epoch|тип (switch / return / both)
ST=$DD/notify.state           # счётчики трафика на момент прошлого отчёта
LASTREP=$DD/notify.lastreport
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -r "$DD/telegram.env" ] && . "$DD/telegram.env"
TABLE=${TABLE:-0}; MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNS="$MAIN${BACKUP:+ $BACKUP}"
REPORT_TIME=${REPORT_TIME:-0900}   # время суточного отчёта ЧЧММ по часам роутера (можно задать в telegram.env)
H=$(hostname)

# ---------- утилиты ----------
esc()  { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
trunc(){ cut -c1-"$1" | iconv -c -f UTF-8 -t UTF-8; }   # обрезка без битых символов
send() { "$DD/notify.sh" --html "$1" >/dev/null 2>&1; }
hum()  { awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," "); i=1; while(b>=1024&&i<5){b/=1024;i++}; f=(i==1?"%d %s":"%.1f %s"); printf f, b, u[i]}'; }
cnt()  { cat "/sys/class/net/$1/statistics/$2_bytes" 2>/dev/null || echo 0; }
hs_age() {
  local ts
  ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi
}
fa() {
  local a=$1
  if   [ "$a" -lt 0 ];    then echo "нет"
  elif [ "$a" -lt 120 ];  then echo "${a}с назад"
  elif [ "$a" -lt 7200 ]; then echo "$((a/60))м назад"
  else echo "$((a/3600))ч назад"; fi
}
fd() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dч %02dм' $((s/3600)) $((s%3600/60)); else printf '%dм %02dс' $((s/60)) $((s%60)); fi
}
active() {
  local r
  r=$(ip route show table "$TABLE" 2>/dev/null | awk '$1=="default" && /dev awg/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  echo "${r:-none}"
}
extip() {
  local ip u
  [ "$1" = none ] && { echo "-"; return; }
  for u in https://api.ipify.org https://ifconfig.me; do
    ip=$(curl -4 -s -m 6 --interface "$1" "$u" 2>/dev/null)
    [[ "$ip" =~ ^[0-9.]+$ ]] && { echo "$ip"; return; }
  done
  echo "-"
}
health() {   # $1=active $2=возраст handshake основного $3=запасного
  if ! systemctl is-active --quiet awg-failover; then echo "CRITICAL: сторож awg-failover не работает"
  elif [ "$1" = none ]; then echo "CRITICAL: нет AWG-маршрута в таблице PBR"
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then echo "DEGRADED: работаем на запасном канале"
  elif [ -n "$BACKUP" ] && { [ "$3" -lt 0 ] || [ "$3" -gt 300 ]; }; then echo "DEGRADED: запасной канал не отвечает"
  else echo "HEALTHY"; fi
}
snapshot() {
  local a t; a=$(active)
  echo "Активный канал : $a"
  for t in $TUNS; do printf '%-14s : handshake %s\n' "$t" "$(fa "$(hs_age "$t")")"; done
  echo "Внешний IP     : $(extip "$a")"
  echo "Время роутера  : $(date '+%F %T')"
}

# ---------- статистика ----------
evcount() { awk -F'|' -v w=$(( $(date +%s) - 86400 )) -v t="$1" '$2==t && $1>=w {n++} END{print n+0}' "$EV" 2>/dev/null || echo 0; }
backup_secs() {
  awk -F'|' -v now="$(date +%s)" 'BEGIN{w=now-86400; s=0; on=0; st=0}
    $2=="switch" { if(!on){on=1; st=($1<w?w:$1)} }
    $2=="return" { if(on){on=0; e=$1; if(e>st) s+=e-st} }
    END{ if(on) s+=now-st; print s+0 }' "$EV" 2>/dev/null || echo 0
}
delta() {
  local cur base
  cur=$(cnt "$1" "$2")
  base=$(awk -v i="$1" -v d="$2" '$1==i{print (d=="rx"?$2:$3)}' "$ST" 2>/dev/null)
  base=${base:-0}
  [ "$cur" -lt "$base" ] && base=0     # интерфейс пересоздавался
  echo $((cur - base))
}
save_base() { local i; for i in $TUNS; do echo "$i $(cnt "$i" rx) $(cnt "$i" tx)"; done > "$ST"; }

# ---------- суточный отчёт ----------
report() {
  local a m b ip up body journal evs t i
  a=$(active); m=$(hs_age "$MAIN"); b=-1; [ -n "$BACKUP" ] && b=$(hs_age "$BACKUP"); ip=$(extip "$a")
  up=$(awk '{s=int($1); printf "%dд %dч %dм", s/86400, s%86400/3600, s%3600/60}' /proc/uptime)
  evs=$(grep -E 'ПЕРЕКЛЮЧЕНИЕ|ВОЗВРАТ|ВОССТАНОВЛЕН|не отвечает' "$LOGF" 2>/dev/null | tail -5 | trunc 110)
  journal=$(tail -n 8 "$LOGF" 2>/dev/null | trunc 110)
  body=$(
    printf 'Состояние : %s\n' "$(health "$a" "$m" "$b")"
    printf 'Активный  : %s (внешний IP %s)\n' "$a" "$ip"
    printf 'Аптайм    : %s\n\n' "$up"
    printf '%-10s %-10s %-10s %s\n' Tunnel RX-24h TX-24h handshake
    for i in $TUNS; do
      printf '%-10s %-10s %-10s %s\n' "$i" "$(hum "$(delta "$i" rx)")" "$(hum "$(delta "$i" tx)")" "$(fa "$(hs_age "$i")")"
    done
    printf '\nСобытия за 24 ч:\n'
    if [ -n "$BACKUP" ]; then
      printf '  переключений на запасной: %s\n' "$(evcount switch)"
      printf '  возвратов на основной: %s\n' "$(evcount return)"
      printf '  время на запасном: %s\n' "$(fd "$(backup_secs)")"
    fi
    printf '  канал(ы) не отвечали: %s раз\n' "$(evcount both)"
    printf '\nПоследние события:\n'
    if [ -n "$evs" ]; then echo "$evs" | sed 's/^/  /'; else echo "  нет"; fi
    printf '\nЖурнал failover (последние 8 строк):\n'
    if [ -n "$journal" ]; then echo "$journal" | sed 's/^/  /'; else echo "  пусто"; fi
    printf '\nСистема:\n'
    printf '  нагрузка: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
    printf '  RAM: %s\n' "$(free -m | awk '/^Mem:/{print $3"/"$2" MB"}')"
    t=/sys/class/thermal/thermal_zone0/temp
    [ -r $t ] && printf '  температура: %s°C\n' $(( $(cat $t) / 1000 ))
    printf '  /data: %s\n' "$(df -h "$DD" | awk 'NR==2{print $5" занято, свободно "$4}')"
    printf '  службы: failover=%s notify=%s\n' "$(systemctl is-active awg-failover)" "$(systemctl is-active awg-notify)"
    printf '  процессов amneziawg-go: %s\n' "$(pgrep -c amneziawg-go)"
    printf '  сбоев доставки в Telegram за 24 ч: %s\n' "$(awk -v s="$(date -d '24 hours ago' '+%F %T')" '($1" "$2)>=s && /не удалось/{n++} END{print n+0}' "$DD/notify.log" 2>/dev/null)"
  )
  send "<b>📊 Суточный отчёт</b> · $H · $(date '+%F')"$'\n'"<pre>$(printf '%s' "$body" | esc)</pre>"
  save_base
  [ -f "$EV" ] && tail -n 500 "$EV" > "$EV.t" && mv "$EV.t" "$EV"
}

# ---------- реакция на строку журнала сторожа ----------
last_both=0
on_line() {
  local l="$1" now title extra lastsw
  now=$(date +%s)
  case "$l" in
    *ПЕРЕКЛЮЧЕНИЕ*)
      echo "$now|switch" >> "$EV"
      title="⚠️ Переключение на запасной канал"
      extra="Основной канал не проходит проверку. PBR-трафик идёт через $BACKUP." ;;
    *ВОЗВРАТ*|*"возврат на"*)
      lastsw=$(awk -F'|' '$2=="switch"{t=$1} END{print t}' "$EV" 2>/dev/null)
      echo "$now|return" >> "$EV"
      title="✅ Возврат на основной канал"
      extra="PBR-трафик снова через $MAIN."
      [ -n "$lastsw" ] && extra="$extra На запасном проработали: $(fd $((now - lastsw)))." ;;
    *"оба канала не отвечают"*|*"единственный канал"*)
      [ $((now - last_both)) -lt 300 ] && return
      last_both=$now
      echo "$now|both" >> "$EV"
      title="🛑 Нет рабочего канала"
      extra="PBR-трафик заблокирован (утечки в WAN нет)." ;;
    *ВОССТАНОВЛЕН*)
      title="✅ Канал восстановлен"
      extra="PBR-трафик снова идёт через $MAIN." ;;
    *) return ;;
  esac
  sleep 4   # даём маршрутам устояться
  send "<b>${title}</b> · $H"$'\n'"$(printf '%s' "$extra" | esc)"$'\n'"<pre>$(snapshot | esc)</pre>"$'\n'"<code>$(printf '%s' "$l" | trunc 200 | esc)</code>"
}

# ---------- фоновый контроль раз в минуту ----------
declare -A BAD ALR
chk() {   # $1=имя $2=1 если плохо $3=тревога $4=восстановление; тревога после 3 плохих проверок подряд
  local n=$1
  if [ "$2" = 1 ]; then
    BAD[$n]=$(( ${BAD[$n]:-0} + 1 ))
    if [ "${BAD[$n]}" -ge 3 ] && [ "${ALR[$n]:-0}" = 0 ]; then
      ALR[$n]=1; send "<b>$3</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
    fi
  else
    BAD[$n]=0
    if [ "${ALR[$n]:-0}" = 1 ]; then
      ALR[$n]=0; send "<b>$4</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
    fi
  fi
}
monitor() {
  local a bad
  while sleep 60; do
    if [ -n "$BACKUP" ]; then
      a=$(hs_age "$BACKUP"); bad=0; { [ "$a" -lt 0 ] || [ "$a" -gt 300 ]; } && bad=1
      chk backup "$bad" "⚠️ Запасной канал потерян: при падении основного переключаться некуда" "✅ Запасной канал восстановлен"
    fi
    a=$(hs_age "$MAIN"); bad=0; { [ "$a" -lt 0 ] || [ "$a" -gt 300 ]; } && bad=1
    chk main "$bad" "⚠️ $MAIN: handshake старше 5 минут" "✅ $MAIN: handshake в норме"
    bad=0; systemctl is-active --quiet awg-failover || bad=1
    chk svc "$bad" "🛑 awg-failover остановлен: автопереключения нет" "✅ awg-failover снова работает"
    if [ $((10#$(date +%H%M))) -ge $((10#$REPORT_TIME)) ] && [ "$(cat "$LASTREP" 2>/dev/null)" != "$(date +%F)" ]; then
      date +%F > "$LASTREP"
      report
    fi
  done
}

daemon() {
  local up t
  [ -f "$ST" ] || save_base
  monitor & MON=$!
  trap 'kill $MON 2>/dev/null' EXIT INT TERM
  sleep 20   # после загрузки даём туннелям подняться
  up=$(awk '{print int($1)}' /proc/uptime)
  if [ "$up" -lt 900 ]; then t="🔄 Роутер загрузился, наблюдатель запущен"; else t="🟢 Наблюдатель awg-notify перезапущен"; fi
  send "<b>$t</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
  tail -n0 -F "$LOGF" 2>/dev/null | while IFS= read -r l; do on_line "$l"; done
}

case "${1:-daemon}" in
  report) report ;;
  test)   if send "<b>✅ Тест уведомлений</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"; then echo "отправлено"; else echo "ошибка, см. $DD/notify.log"; fi ;;
  daemon) daemon ;;
  *)      echo "использование: $0 [daemon|report|test]"; exit 1 ;;
esac
