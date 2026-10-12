#!/bin/bash
# failover.sh — сторож: держит AWG-туннель в таблице PBR UniFi и переключает каналы.
#   failover.sh                основной цикл (запускает systemd: awg-failover.service)
#   failover.sh cleanup        убрать свои маршруты из таблицы PBR
#   failover.sh dedup          убрать дубликаты правил iptables для туннелей awg* (накапливались у версий без -w)
#   failover.sh forget ИМЯ     убрать все правила iptables для интерфейса ИМЯ (туннель удалён из схемы)
# Туннели по приоритету: MAIN, BACKUP, затем TUNNELS_EXTRA из awg.env. Активен один, остальные на подхвате:
#  - падение активного (FAIL_MAX проверок подряд) → переход на первый живой по приоритету;
#  - возврат на более приоритетный: он должен быть жив и «здоров» RECOVER_SEC секунд подряд;
#  - качество (QUALITY=yes): потери/задержка активного хуже порога QUALITY_FAILS проб подряд → переход на здоровый;
#  - ручное управление: /run/awg-force (awgctl switch / awgctl auto);
#  - события пишутся в events.log (epoch|тип|текст), состояние — в /run/awg-state.
# Параметры: /data/awg/awg.env (создаёт awg-detect.sh).

# iptables всегда с ожиданием блокировки xtables. Без -w iptables 1.8.7 (legacy) при занятой блокировке
# (её постоянно берут UniFi и другие службы) сразу завершается с ошибкой, и проверка «есть ли правило»
# ошибочно отвечает «нет» — так копились дубликаты правил.
iptables(){ command iptables -w 10 "$@"; }
# ensure ТАБЛИЦА -I|-A ПРАВИЛО…: добавить правило, только если iptables -C ответил «такого правила нет» (код 1).
# Любой другой код (блокировка не освободилась, ошибка) — ничего не делаем: попробуем на следующем круге.
ensure(){ local t=$1 op=$2; shift 2; iptables -t "$t" -C "$@" 2>/dev/null; [ $? -eq 1 ] && iptables -t "$t" "$op" "$@"; return 0; }

DD=${DD:-/data/awg}
RS_ENV=$RECOVER_SEC                # RECOVER_SEC из окружения важнее awg.env (для тестов)
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -n "$RS_ENV" ] && RECOVER_SEC=$RS_ENV

# правила iptables одного туннеля (их же убирает forget). Записаны так, как их печатает «iptables -S»:
# тогда наличие правила проверяется по одному снимку таблицы, без отдельного вызова iptables на каждое правило.
fw_rules(){  # fw_rules ИНТЕРФЕЙС → строки «таблица|правило»
  echo "nat|POSTROUTING -o $1 -j MASQUERADE"
  echo "mangle|FORWARD -o $1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
  echo "mangle|FORWARD -i $1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
  echo "filter|FORWARD -o $1 -j ACCEPT"
  echo "filter|FORWARD -i $1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
}

# Удалить лишние копии одинаковых правил, где участвует интерфейс awg* или цепочка AWG_*. Одна копия остаётся.
dedup(){
  local t line n k removed=0 lines
  # пока чистим, awg-guard и awg-self не пересобирают свои цепочки (общие замки); после — пусть сверятся заново
  if command -v flock >/dev/null && { exec 7>"${AWG_RUN:-/run}/awg-guard.lock" 8>"${AWG_RUN:-/run}/awg-self.lock"; } 2>/dev/null; then flock -w 30 7; flock -w 30 8; fi
  for t in nat mangle filter; do
    lines=$(iptables -t "$t" -S 2>/dev/null) || continue          # нет ответа (блокировка) — пропускаем таблицу
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in *\"*|*\'*) continue;; esac                # правила с кавычками не трогаем
      n=$(printf '%s\n' "$lines" | grep -c -x -F -- "$line")
      for ((k=1; k<n; k++)); do
        # shellcheck disable=SC2086
        iptables -t "$t" -D ${line#-A } 2>/dev/null && removed=$((removed+1))
      done
    done < <(printf '%s\n' "$lines" | grep '^-A ' | grep -E -- '(-[io] awg[a-z0-9]*( |$))|AWG_' | sort | uniq -d)
  done
  [ "$removed" -gt 0 ] && rm -f /tmp/awg-guard.hash /tmp/awg-self.hash
  { exec 7>&- 8>&-; } 2>/dev/null
  echo "$removed"
}

forget(){  # убрать правила интерфейса (все копии)
  local i=$1 l t r
  [ -n "$i" ] || return 1
  while IFS='|' read -r t r; do
    # shellcheck disable=SC2086
    for _ in 1 2 3 4 5 6 7 8 9 10; do iptables -t "$t" -D $r 2>/dev/null || break; done
  done < <(fw_rules "$i")
  for _ in 1 2 3 4 5 6 7 8 9 10; do iptables -t mangle -D POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || break; done
  iptables -t mangle -S PREROUTING 2>/dev/null | grep -E -- "^-A PREROUTING -i $i -p tcp .*TCPMSS --set-mss" | sed 's/^-A /-D /' | while read -r r; do
    # shellcheck disable=SC2086
    iptables -t mangle $r 2>/dev/null
  done
  return 0
}

case "$1" in
  dedup)  n=$(dedup); echo "убрано дубликатов: $n"; exit 0;;
  forget) forget "$2"; exit $?;;
esac

TABLE=${TABLE:?нет TABLE в awg.env: запустите awg-detect.sh}
MARK=${MARK:?нет MARK в awg.env: запустите awg-detect.sh}
PRIO=${PRIO:-32504}
MAIN=${MAIN:-awgmain}
BACKUP=${BACKUP:-}
RECOVER_SEC=${RECOVER_SEC:-600}           # сколько более приоритетный канал должен проработать без сбоев до возврата
QUALITY=${QUALITY:-yes}
QUALITY_LOSS=${QUALITY_LOSS:-40}          # % потерь, с которых канал считается деградировавшим
QUALITY_RTT=${QUALITY_RTT:-0}             # мс; 0 — задержку не учитывать
QUALITY_FAILS=${QUALITY_FAILS:-3}         # столько проб подряд
QUALITY_INTERVAL=${QUALITY_INTERVAL:-30}  # секунд между пробами
MIN_DWELL=${MIN_DWELL:-120}               # после любого переключения не переключаться по качеству столько секунд
TARGETS=${TARGETS:-"1.1.1.1 8.8.8.8 9.9.9.9"}   # независимые узлы: канал жив, если ответил хотя бы один
METRIC=5                                  # метрика активного туннеля в таблице PBR
INTERVAL=${INTERVAL:-5}                   # секунд между проверками
FAIL_MAX=${FAIL_MAX:-3}                   # сбоев подряд до переключения
SIM=${SIM:-/tmp/awg-sim-down}             # флаг имитации падения основного канала
FORCEF=${FORCEF:-/run/awg-force}
STATEF=${STATEF:-/run/awg-state}
EVF=$DD/events.log
LOGF=$DD/failover.log

TUNS=("$MAIN"); [ -n "$BACKUP" ] && TUNS+=("$BACKUP")
for t in ${TUNNELS_EXTRA:-}; do TUNS+=("$t"); done
N=${#TUNS[@]}

log(){
  local m; m="$(date '+%F %T') $*"
  echo "$m"; logger -t awg-failover "$*" 2>/dev/null; echo "$m" >> "$LOGF"
  if [ "$(wc -l < "$LOGF")" -gt 1000 ]; then tail -n 500 "$LOGF" > "$LOGF.tmp" && mv "$LOGF.tmp" "$LOGF"; fi
}
ev(){ echo "$(date +%s)|$1|$2" >> "$EVF"; if [ "$(wc -l < "$EVF")" -gt 3000 ]; then tail -n 2000 "$EVF" > "$EVF.tmp" && mv "$EVF.tmp" "$EVF"; fi; }

# Канал жив, если через него открывается HTTPS хотя бы к одному из независимых узлов TARGETS
# (отказ одного сайта канал не роняет). Если HTTPS не прошёл ни к одному — пробуем ping (ICMP у части
# операторов не ходит, поэтому он вторым). Канал мёртв, только если не ответил никто.
check(){
  [ "$1" = "$MAIN" ] && [ -e "$SIM" ] && return 1
  local t c
  for t in $TARGETS; do
    c=$(curl -sk -o /dev/null --connect-timeout 3 -m 5 --interface "$1" -w '%{http_code}' "https://$t/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && return 0
  done
  for t in $TARGETS; do ping -I "$1" -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0; done
  return 1
}
# DNS через туннель (DoH-запрос к 1.1.1.1): handshake и HTTPS есть, а DNS нет — частая «тихая» поломка. Для diagnose и метрик.
declare -A DNSOK
dns_probe(){
  local r; r=$(curl -s -m 5 --interface "$1" -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=example.com&type=A' 2>/dev/null)
  case "$r" in *'"Status":0'*) DNSOK[$1]=1;; *) DNSOK[$1]=0;; esac
}

# Проба качества: заполняет QLOSS (потери %) и QRTT (RTT мс). Возвращает 0, если канал деградировал.
# Сначала ICMP (5 пингов до 1.1.1.1). Если ICMP через канал не ходит (часто у VPN-провайдеров), меряем TCP:
# время установки соединения :443 до трёх независимых узлов, «потеря» — неудавшееся соединение.
declare -A ICMP_SEEN QLOSS QRTT QMETH
probe_tcp(){
  local i=$1 t c ok=0 n=0 sum=0
  for t in $TARGETS; do
    n=$((n+1))
    c=$(curl -sk -o /dev/null --connect-timeout 2 -m 3 --interface "$i" -w '%{time_connect}' "https://$t/" 2>/dev/null)
    case "$c" in ""|0|0.000000|0,000000) continue;; esac
    ok=$((ok+1)); sum=$(( sum + $(awk -v x="$c" 'BEGIN{printf "%d", x*1000+0.5}') ))
  done
  [ $n -gt 0 ] || n=1
  QLOSS[$i]=$(( (n-ok)*100/n )); QRTT[$i]=0; [ $ok -gt 0 ] && QRTT[$i]=$(( sum/ok )); QMETH[$i]=tcp
}
probe(){
  local i=$1 out l r
  if [ "${ICMP_SEEN[$i]:-0}" != 1 ] || [ "${QMETH[$i]:-icmp}" = icmp ]; then
    out=$(ping -I "$i" -c 5 -i 0.3 -W 1 -q 1.1.1.1 2>/dev/null)
    l=$(echo "$out" | awk '/packet loss/{for(k=1;k<=NF;k++) if($k ~ /%/){gsub("%","",$k); print int($k); exit}}')
    r=$(echo "$out" | awk -F'=' '/min\/avg\/max/{split($2,a,"/"); printf "%d", a[2]+0.5; exit}')
    [ -z "$l" ] && l=100
    [ "$l" -lt 100 ] && ICMP_SEEN[$i]=1
  fi
  if [ "${ICMP_SEEN[$i]:-0}" = 1 ]; then
    QLOSS[$i]=$l; QRTT[$i]=${r:-0}; QMETH[$i]=icmp
  else
    probe_tcp "$i"; l=${QLOSS[$i]}
  fi
  [ "${QLOSS[$i]}" -ge "$QUALITY_LOSS" ] && return 0
  [ "$QUALITY_RTT" -gt 0 ] && [ "${QRTT[$i]}" -ge "$QUALITY_RTT" ] && return 0
  return 1
}

prepare(){
  # Каждая таблица читается один раз за проход (3 вызова iptables вместо ~25): меньше спора за блокировку xtables
  # с UniFi. Если снимок не получен — в этот проход ничего не меняем. Правило, которого нет в снимке,
  # перепроверяется точным «iptables -C» и добавляется, только если его действительно нет.
  local i t r
  declare -A S
  for t in nat mangle filter; do S[$t]=$(iptables -t "$t" -S 2>/dev/null) || return 0; done
  for i in "${TUNS[@]}"; do
    while IFS='|' read -r t r; do
      grep -q -x -F -- "-A $r" <<< "${S[$t]}" && continue
      # shellcheck disable=SC2086
      ensure "$t" -I $r
    done < <(fw_rules "$i")
  done
  # правило PBR (если UniFi его потерял) добавляем со своей меткой proto 99: так удаление отличит его от правила UniFi
  ip rule show | grep -q "fwmark $MARK" || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" proto 99 2>/dev/null \
    || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"
}

declare -A NEXT_TRY
ensure_tunnels(){
  local i now; now=$(date +%s)
  for i in "${TUNS[@]}"; do
    ip link show "$i" >/dev/null 2>&1 && continue
    [ "${NEXT_TRY[$i]:-0}" -gt "$now" ] && continue
    NEXT_TRY[$i]=$((now + 30))
    log "$i отсутствует, поднимаю"
    "$DD/up.sh" "$i" >/dev/null 2>&1 || log "$i: не удалось поднять (проверьте: $DD/up.sh $i)"
  done
}

set_active(){
  local a=${TUNS[$1]} j
  ip route replace default dev "$a" metric $METRIC table "$TABLE"
  for j in "${TUNS[@]}"; do [ "$j" != "$a" ] && ip route del default dev "$j" table "$TABLE" 2>/dev/null; done
  ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
}

cleanup(){  # cleanup [all] — убрать маршруты туннелей; blackhole остаётся (kill switch на время перезапуска), all — и его
  local j
  for j in "${TUNS[@]}"; do ip route del default dev "$j" table "$TABLE" 2>/dev/null; done
  [ "$1" = all ] && ip route del blackhole default metric 200 table "$TABLE" 2>/dev/null
  return 0
}

write_state(){
  local i
  {
    echo "ACTIVE=${TUNS[$idx]}"
    echo "FORCED=$forced"
    echo "UPDATED=$(date +%s)"
    echo "TUNNELS=\"${TUNS[*]}\""
    for i in "${TUNS[@]}"; do echo "LOSS_$i=${QLOSS[$i]:-}"; echo "RTT_$i=${QRTT[$i]:-}"; echo "QMETH_$i=${QMETH[$i]:-}"; echo "DNS_$i=${DNSOK[$i]:-}"; done
  } > "$STATEF.tmp" && mv "$STATEF.tmp" "$STATEF"
}

tun_addr(){ ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
index_of(){ local k; for k in "${!TUNS[@]}"; do [ "${TUNS[$k]}" = "$1" ] && { echo "$k"; return 0; }; done; return 1; }

[ "$1" = cleanup ] && { cleanup "$2"; exit 0; }
trap 'cleanup; log "остановка: маршруты туннелей убраны, blackhole оставлен (трафик PBR блокируется)"; ev stop "сторож остановлен"; rm -f "$STATEF"; exit 0' INT TERM

# kill switch сразу, ещё до паузы и проверок: пока маршрута в туннель нет, трафик PBR не уйдёт в WAN
ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
# после загрузки роутера даём UniFi 30 с собрать свои правила и таблицы
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && sleep "${BOOT_WAIT:-30}"

n=$(dedup); [ "${n:-0}" -gt 0 ] && log "убрано дубликатов правил iptables: $n"

idx=0; fails=0; both_flag=0; forced=""; qbad=0; last_q=0; last_sw=0
declare -A OKS QOK
for k in "${!TUNS[@]}"; do OKS[$k]=0; QOK[$k]=1; done
# сторож начинает с основного канала: записи conntrack, заNATенные на другие туннели (например, на запасной до перезапуска), сбросить
set_active 0
if command -v conntrack >/dev/null; then
  for k in "${!TUNS[@]}"; do [ "$k" = 0 ] && continue; a=$(tun_addr "${TUNS[$k]}"); [ -n "$a" ] && conntrack -D -q "$a" >/dev/null 2>&1; done
fi
log "старт: основной $MAIN, запасной ${BACKUP:-нет}${TUNNELS_EXTRA:+, дополнительные $TUNNELS_EXTRA}, таблица $TABLE, возврат через ${RECOVER_SEC}с, качество: $QUALITY"
ev start "основной $MAIN, всего туннелей $N"

switch_to(){  # switch_to индекс тип сообщение
  local old=${TUNS[$idx]} oa
  # соединения, заNATенные на адрес прежнего туннеля, иначе так и пойдут в новый туннель со старым адресом и умрут
  # (UDP с постоянным портом — VoIP, игры, WireGuard клиентов — не восстановились бы сами)
  local prev=$idx
  idx=$1; fails=0; qbad=0; both_flag=0; last_sw=$(date +%s)
  set_active "$idx"                      # сначала маршрут на новый туннель, потом сброс записей: иначе они тут же создадутся заново
  if [ "$idx" != "$prev" ] && command -v conntrack >/dev/null; then
    oa=$(tun_addr "$old"); [ -n "$oa" ] && conntrack -D -q "$oa" >/dev/null 2>&1
  fi
  for k in "${!TUNS[@]}"; do OKS[$k]=0; done
  ev "$2" "$3"
}

while true; do
  ensure_tunnels
  prepare
  now=$(date +%s)

  # ---- ручное управление ----
  if [ -s "$FORCEF" ]; then
    f=$(head -n1 "$FORCEF" | tr -d ' \r')
    if fidx=$(index_of "$f"); then
      if [ "$forced" != "$f" ]; then
        if [ "$fidx" = "$idx" ] || check "$f"; then
          [ "$fidx" != "$idx" ] && log "ПЕРЕКЛЮЧЕНИЕ вручную на $f"
          forced=$f; switch_to "$fidx" force "ручное переключение на $f"
        else
          log "ручное переключение на $f отклонено: канал не отвечает"; ev refused "канал $f не отвечает"; rm -f "$FORCEF"
        fi
      fi
    else
      log "ручное переключение: нет туннеля «$f»"; rm -f "$FORCEF"
    fi
  else
    [ -n "$forced" ] && { forced=""; log "автоматический режим восстановлен"; ev auto "возврат к автоматическому выбору"; }
  fi

  active=${TUNS[$idx]}
  if check "$active"; then
    [ $both_flag -eq 1 ] && log "ВОССТАНОВЛЕН канал $active, трафик по PBR снова идёт"
    fails=0; both_flag=0
  else
    fails=$((fails+1))
  fi

  if [ $fails -ge $FAIL_MAX ]; then
    if [ -n "$forced" ]; then
      log "канал $forced (выбран вручную) не отвечает: возвращаю автоматический режим"; rm -f "$FORCEF"; forced=""
    fi
    cand=-1
    for k in "${!TUNS[@]}"; do [ "$k" = "$idx" ] && continue; check "${TUNS[$k]}" && { cand=$k; break; }; done
    if [ $cand -ge 0 ]; then
      if [ $cand -eq 0 ]; then log "канал $active не отвечает, основной жив: возврат на ${TUNS[0]}"; switch_to $cand return "$active не отвечает, возврат на ${TUNS[0]}"
      else log "ПЕРЕКЛЮЧЕНИЕ на запасной канал ${TUNS[$cand]}"; switch_to $cand switch "$active не отвечает, переход на ${TUNS[$cand]}"; fi
    elif [ $both_flag -eq 0 ]; then
      both_flag=1
      if [ "$N" -gt 1 ]; then log "оба канала не отвечают, остаюсь на $active (трафик по PBR блокируется)"
      else log "единственный канал $active не отвечает (трафик по PBR блокируется)"; fi
      ev both "все каналы не отвечают"
    fi
  elif [ -z "$forced" ] && [ "$idx" -gt 0 ]; then
    # ---- возврат на более приоритетный ----
    for ((k=0; k<idx; k++)); do
      t=${TUNS[$k]}
      if check "$t" && [ "${QOK[$k]}" = 1 ]; then
        [ "${OKS[$k]}" = 0 ] && { OKS[$k]=$now; log "$t снова отвечает, жду ${RECOVER_SEC}с без сбоев"; }
        if [ $(( now - ${OKS[$k]} )) -ge "$RECOVER_SEC" ]; then
          if [ "$k" -eq 0 ]; then log "ВОЗВРАТ на основной канал $t"; else log "возврат на более приоритетный канал $t"; fi
          switch_to "$k" return "возврат на $t"; break
        fi
      else
        [ "${OKS[$k]}" != 0 ] && log "$t снова сбоит, отсчёт возврата сброшен"
        OKS[$k]=0
      fi
    done
  fi

  # ---- DNS через активный туннель, раз в минуту (только наблюдение: канал из-за DNS не переключаем) ----
  if [ $fails -eq 0 ] && [ $(( now - ${last_dns:-0} )) -ge 60 ]; then last_dns=$now; dns_probe "${TUNS[$idx]}"; fi

  # ---- качество ----
  if [ "$QUALITY" = yes ] && [ "$N" -gt 1 ] && [ -z "$forced" ] && [ $fails -eq 0 ] && [ $(( now - last_q )) -ge "$QUALITY_INTERVAL" ]; then
    last_q=$now
    active=${TUNS[$idx]}
    if probe "$active"; then qbad=$((qbad+1)); else qbad=0; fi
    for ((k=0; k<idx; k++)); do probe "${TUNS[$k]}" && QOK[$k]=0 || QOK[$k]=1; done
    if [ $qbad -ge "$QUALITY_FAILS" ] && [ $(( now - last_sw )) -ge "$MIN_DWELL" ]; then
      for k in "${!TUNS[@]}"; do
        [ "$k" = "$idx" ] && continue
        t=${TUNS[$k]}
        if check "$t" && ! probe "$t"; then
          log "ДЕГРАДАЦИЯ $active (потери ${QLOSS[$active]}%, RTT ${QRTT[$active]} мс): ПЕРЕКЛЮЧЕНИЕ на $t"
          switch_to "$k" degrade "$active: потери ${QLOSS[$active]}%, RTT ${QRTT[$active]} мс; переход на $t"
          break
        fi
      done
      [ $qbad -ge "$QUALITY_FAILS" ] && qbad=0
    fi
  fi

  set_active "$idx"
  # UniFi пересоздал профиль-«рельсу» с другой меткой или таблицей: сторож работает со старыми — предупредить один раз
  if [ -n "$RAIL_IF" ] && [ $(( now - ${last_drift:-0} )) -ge 60 ]; then
    last_drift=$now
    # все правила fwmark → <N>.<рельса>; правило, которое добавил сам сторож, совпадает с awg.env и в счёт не идёт
    dr=$(ip -4 rule show | awk -v r="$RAIL_IF" -v want="$MARK ${TABLE}.$RAIL_IF" '/fwmark/ && $0 ~ ("lookup [0-9]+\\." r "[[:space:]]*$") {for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1)} if (m" "t != want) {print m, t; exit}}')
    if [ -n "$dr" ]; then
      [ "$drift_logged" = "$dr" ] || { log "ВНИМАНИЕ: правило PBR профиля $RAIL_IF теперь «$dr», а в awg.env MARK=$MARK TABLE=$TABLE: запустите $DD/install.sh → Компоненты → Туннели → Заново определить PBR"; ev drift "PBR: $dr"; drift_logged=$dr; }
    fi
  fi
  write_state
  sleep "$INTERVAL"
done
