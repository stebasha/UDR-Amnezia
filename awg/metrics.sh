#!/bin/bash
# awg-metrics: экспорт метрик в формате Prometheus.
# Каждые 15 с пишет файл $DD/metrics/metrics (ссылка на /run/awg-metrics: в памяти, не на флеш-памяти). Если задан METRICS_PORT в awg.env, отдаёт его по HTTP
# (python3 -m http.server на адресе LAN-моста, путь /metrics) — для Prometheus / Grafana Agent / VictoriaMetrics.
# Без METRICS_PORT только пишет файл: подходит для node_exporter --collector.textfile (скопируйте/слинкуйте файл).
# Порт слушает только LAN-адрес роутера; доступ из интернета UniFi закрывает по умолчанию, но не открывайте его вручную.
DD=${DD:-/data/awg}
AWG=$DD/awg
# файл переписывается каждые 15 с: держим его в памяти (/run), а не на флеш-памяти /data — $DD/metrics ссылка туда
OUTD=${AWG_METRICS_DIR:-${AWG_RUN:-/run}/awg-metrics}
STATEF=${STATEF:-/run/awg-state}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TABLE=${TABLE:-0}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
mkdir -p "$OUTD"; chmod 755 "$OUTD"
if [ "$OUTD" != "$DD/metrics" ] && [ ! -L "$DD/metrics" ]; then          # прежняя папка на /data → ссылка
  rm -f "$DD/metrics/metrics" "$DD/metrics/metrics.tmp" 2>/dev/null; rmdir "$DD/metrics" 2>/dev/null
  [ -e "$DD/metrics" ] || ln -s "$OUTD" "$DD/metrics"
fi

collect(){
  local t a ts rx tx act l r n now line; local -A HS=() EVC=() SV=()
  # shellcheck source=/dev/null
  [ -r "$STATEF" ] && . "$STATEF"
  act=${ACTIVE:-}
  printf -v now '%(%s)T' -1
  # одним вызовом: handshake всех туннелей, счётчики событий, активность служб (раз в 15 с — без лишних процессов)
  while read -r t _ ts; do [[ $ts =~ ^[0-9]+$ ]] || continue; [ -z "${HS[$t]:-}" ] || [ "$ts" -gt "${HS[$t]}" ] && HS[$t]=$ts; done \
    < <($AWG show all latest-handshakes 2>/dev/null)
  # счётчики событий пересчитываются, только когда журнал событий изменился (обычно — раз в часы, а не каждые 15 с)
  local evsz; evsz=$(stat -c '%s.%Y' "$DD/events.log" 2>/dev/null)
  if [ "$evsz" != "${EV_STAMP:-}" ]; then
    EV_COUNTS=$(awk -F'|' '{c[$2]++} END{for (k in c) print k, c[k]}' "$DD/events.log" 2>/dev/null); EV_STAMP=$evsz
  fi
  while read -r n a; do [ -n "$n" ] && EVC[$n]=$a; done <<< "$EV_COUNTS"
  local svcs=(awg-failover) u i=0
  for u in awg-subnets awg-self awg-guard awg-notify awg-bot; do [ -f "/etc/systemd/system/$u.service" ] && svcs+=("$u"); done
  while read -r line; do SV[${svcs[$i]}]=$line; i=$((i + 1)); done < <(systemctl is-active "${svcs[@]}" 2>/dev/null)
  echo "# HELP awg_tunnel_up 1 если handshake свежее 180 с"
  echo "# TYPE awg_tunnel_up gauge"
  for t in $TUNS; do
    ts=${HS[$t]:-0}
    if [ "$ts" = 0 ]; then a=-1; else a=$(( now - ts )); fi
    echo "awg_handshake_age_seconds{tunnel=\"$t\"} $a"
    [ "$a" -ge 0 ] && [ "$a" -lt 180 ] && echo "awg_tunnel_up{tunnel=\"$t\"} 1" || echo "awg_tunnel_up{tunnel=\"$t\"} 0"
    rx=0; tx=0; { read -r rx < "/sys/class/net/$t/statistics/rx_bytes"; read -r tx < "/sys/class/net/$t/statistics/tx_bytes"; } 2>/dev/null
    echo "awg_rx_bytes_total{tunnel=\"$t\"} ${rx:-0}"
    echo "awg_tx_bytes_total{tunnel=\"$t\"} ${tx:-0}"
    echo "awg_active{tunnel=\"$t\"} $([ "$t" = "$act" ] && echo 1 || echo 0)"
    eval "l=\${LOSS_$t:-}; r=\${RTT_$t:-}"
    [ -n "$l" ] && echo "awg_probe_loss_percent{tunnel=\"$t\"} $l"
    [ -n "$r" ] && echo "awg_probe_rtt_ms{tunnel=\"$t\"} $r"
  done
  echo "awg_forced $([ -n "$FORCED" ] && echo 1 || echo 0)"
  for n in switch return degrade both force; do echo "awg_events_total{type=\"$n\"} ${EVC[$n]:-0}"; done
  for u in "${svcs[@]}"; do echo "awg_service_up{service=\"$u\"} $([ "${SV[$u]:-}" = active ] && echo 1 || echo 0)"; done
  echo "awg_data_free_bytes $(( $(df -Pk "$DD" 2>/dev/null | awk 'NR==2{print $4}') * 1024 ))"
  echo "awg_state_updated_seconds_ago $(( now - ${UPDATED:-0} ))"
  echo "awg_scrape_timestamp_seconds $now"
}

serve(){
  [ -n "$METRICS_PORT" ] || return 0
  command -v python3 >/dev/null || { echo "нет python3: HTTP-экспорт недоступен, файл $OUTD/metrics обновляется"; return 0; }
  local ip; ip=$(ip -4 -br addr show br0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  [ -n "$ip" ] || { echo "не найден адрес br0: HTTP-экспорт не запущен"; return 0; }
  ( cd "$OUTD" && exec python3 -m http.server "$METRICS_PORT" --bind "$ip" >/dev/null 2>&1 ) &
  SRV=$!
  echo "метрики: http://$ip:$METRICS_PORT/metrics"
}

if [ "$1" = once ]; then collect; exit 0; fi
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; exit 0' INT TERM
serve
while :; do
  collect > "$OUTD/metrics.tmp" 2>/dev/null && mv "$OUTD/metrics.tmp" "$OUTD/metrics"
  sleep 15 & wait $!
done
