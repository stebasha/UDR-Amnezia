#!/bin/bash
# awg-metrics: экспорт метрик в формате Prometheus.
# Каждые 15 с пишет файл $DD/metrics/metrics. Если задан METRICS_PORT в awg.env, отдаёт его по HTTP
# (python3 -m http.server на адресе LAN-моста, путь /metrics) — для Prometheus / Grafana Agent / VictoriaMetrics.
# Без METRICS_PORT только пишет файл: подходит для node_exporter --collector.textfile (скопируйте/слинкуйте файл).
# Порт слушает только LAN-адрес роутера; доступ из интернета UniFi закрывает по умолчанию, но не открывайте его вручную.
DD=${DD:-/data/awg}
AWG=$DD/awg
OUTD=$DD/metrics
STATEF=${STATEF:-/run/awg-state}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TABLE=${TABLE:-0}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
mkdir -p "$OUTD"; chmod 755 "$OUTD"

collect(){
  local t a ts rx tx act l r n
  [ -r "$STATEF" ] && . "$STATEF"
  act=${ACTIVE:-}
  echo "# HELP awg_tunnel_up 1 если handshake свежее 180 с"
  echo "# TYPE awg_tunnel_up gauge"
  for t in $TUNS; do
    ts=$($AWG show "$t" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    if [ -z "$ts" ] || [ "$ts" = 0 ]; then a=-1; else a=$(( $(date +%s) - ts )); fi
    echo "awg_handshake_age_seconds{tunnel=\"$t\"} $a"
    [ "$a" -ge 0 ] && [ "$a" -lt 180 ] && echo "awg_tunnel_up{tunnel=\"$t\"} 1" || echo "awg_tunnel_up{tunnel=\"$t\"} 0"
    rx=$(cat /sys/class/net/$t/statistics/rx_bytes 2>/dev/null || echo 0); tx=$(cat /sys/class/net/$t/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "awg_rx_bytes_total{tunnel=\"$t\"} $rx"
    echo "awg_tx_bytes_total{tunnel=\"$t\"} $tx"
    echo "awg_active{tunnel=\"$t\"} $([ "$t" = "$act" ] && echo 1 || echo 0)"
    eval "l=\${LOSS_$t:-}; r=\${RTT_$t:-}"
    [ -n "$l" ] && echo "awg_probe_loss_percent{tunnel=\"$t\"} $l"
    [ -n "$r" ] && echo "awg_probe_rtt_ms{tunnel=\"$t\"} $r"
  done
  echo "awg_forced $([ -n "$FORCED" ] && echo 1 || echo 0)"
  for n in switch return degrade both force; do
    echo "awg_events_total{type=\"$n\"} $(awk -F'|' -v t=$n '$2==t{c++} END{print c+0}' "$DD/events.log" 2>/dev/null)"
  done
  for n in awg-failover awg-subnets awg-self awg-guard awg-notify awg-bot; do
    [ "$n" = awg-failover ] || [ -f "/etc/systemd/system/$n.service" ] && echo "awg_service_up{service=\"$n\"} $(systemctl is-active --quiet $n 2>/dev/null && echo 1 || echo 0)"
  done
  echo "awg_data_free_bytes $(( $(df -Pk "$DD" 2>/dev/null | awk 'NR==2{print $4}') * 1024 ))"
  echo "awg_state_updated_seconds_ago $(( $(date +%s) - ${UPDATED:-0} ))"
  echo "awg_scrape_timestamp_seconds $(date +%s)"
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
