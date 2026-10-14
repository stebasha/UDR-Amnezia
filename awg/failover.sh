#!/bin/bash
# failover.sh — сторож: держит AWG-туннель в таблице PBR UniFi и переключает каналы.
#   failover.sh                основной цикл (запускает systemd: awg-failover.service)
#   failover.sh cleanup        убрать свои маршруты из таблицы PBR
#   failover.sh dedup          убрать дубликаты правил iptables для туннелей awg* (накапливались у версий без -w)
#   failover.sh forget ИМЯ     убрать все правила iptables для интерфейса ИМЯ (туннель удалён из схемы)
#   failover.sh --route ID …   то же для дополнительного маршрута (#22): свой профиль VPN Client UniFi (рельса), своя
#                              таблица и метка PBR, своя цепочка туннелей — из route.d/ID.env (служба awg-failover-ID)
# IPv6 через туннель (#23, LEAK_V6=route, по желанию): IPv6 с меткой PBR — в таблицу PBR IPv6 на активный туннель,
# если у туннеля есть IPv6-адрес; иначе unreachable (устройство сразу переходит на IPv4). NAT66 на туннеле.
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
LEAK_V6=${LEAK_V6:-block}

# дополнительный маршрут (#22): своя рельса UniFi, таблица, метка и цепочка туннелей; состояние и ручной выбор — свои
ROUTE=""
if [ "${1:-}" = --route ]; then
  ROUTE=${2:-}; shift 2 || shift
  [[ $ROUTE =~ ^[a-z][a-z0-9]{0,11}$ ]] && [ -r "$DD/route.d/$ROUTE.env" ] || { echo "ОШИБКА: нет маршрута ${ROUTE:-?} ($DD/route.d/ID.env)"; exit 1; }
  TABLE=""; MARK=""; PRIO=""; RAIL_IF=""; TUNNELS=""
  # shellcheck disable=SC1090
  . "$DD/route.d/$ROUTE.env"
  read -r MAIN BACKUP TUNNELS_EXTRA <<< "$TUNNELS"
  [ -n "$MAIN" ] || { echo "ОШИБКА: в маршруте $ROUTE нет туннелей (TUNNELS)"; exit 1; }
  ROUTE_ONLY=""
  STATEF=${STATEF:-/run/awg-state}-$ROUTE; FORCEF=${FORCEF:-/run/awg-force}-$ROUTE; SIM=${SIM:-/tmp/awg-sim-down}-$ROUTE
  AWG_NO_FWCHECK=1
fi

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

# те же правила для IPv6 через туннель (#23): NAT66, MSS, FORWARD
ip6tables(){ command ip6tables -w 10 "$@"; }

forget(){  # убрать правила интерфейса (все копии)
  local i=$1 l t r
  [ -n "$i" ] || return 1
  while IFS='|' read -r t r; do
    # shellcheck disable=SC2086
    for _ in 1 2 3 4 5 6 7 8 9 10; do iptables -t "$t" -D $r 2>/dev/null || break; done
    # shellcheck disable=SC2086
    if command -v ip6tables >/dev/null; then for _ in 1 2 3 4 5 6 7 8 9 10; do ip6tables -t "$t" -D $r 2>/dev/null || break; done; fi
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
RECHECK_AFTER=${RECHECK_AFTER:-120}       # более приоритетный канал не отвечает столько секунд — проверять его реже:
RECHECK_SLOW=${RECHECK_SLOW:-30}          #   раз в столько секунд,
RECHECK_MAX=${RECHECK_MAX:-60}            #   а после 10 минут — раз в столько
FAIL_MAX=${FAIL_MAX:-3}                   # сбоев подряд до переключения
SIM=${SIM:-/tmp/awg-sim-down}             # флаг имитации падения основного канала
FORCEF=${FORCEF:-/run/awg-force}
STATEF=${STATEF:-/run/awg-state}
EVF=$DD/events.log
LOGF=$DD/failover${ROUTE:+-$ROUTE}.log

# туннели только для дополнительных маршрутов (ROUTE_ONLY, #22) основной маршрут не использует; основной туннель — всегда
TUNS=("$MAIN")
for t in $BACKUP ${TUNNELS_EXTRA:-}; do case " ${ROUTE_ONLY:-} " in *" $t "*) continue;; esac; TUNS+=("$t"); done
N=${#TUNS[@]}
V6=0; [ "$LEAK_V6" = route ] && command -v ip6tables >/dev/null && V6=1
RT=${ROUTE:+маршрут $ROUTE: }   # приставка к событиям и журналу дополнительного маршрута
SYSNET=${AWG_SYSNET:-/sys/class/net}
RUNDIR=${AWG_RUN:-/run}
CHECK_RX_MIN=${CHECK_RX_MIN:-65536}      # байт из туннеля за проход: трафик идёт — канал жив без отдельной проверки HTTPS
CHECK_MAX_AGE=${CHECK_MAX_AGE:-60}       # но настоящая проверка — не реже раза в столько секунд
# Проход сторожа повторяется каждые 5 с (и у каждого маршрута свой сторож), поэтому в цикле — только встроенные
# средства bash там, где можно: время — printf %(%s)T, интерфейс — /sys/class/net, сравнения — шаблоны, пауза — read -t.
epoch(){ printf -v "$1" '%(%s)T' -1; }
link_up(){ [ -e "$SYSNET/$1" ]; }

log(){
  local m; m="$(date '+%F %T') $RT$*"
  echo "$m"; logger -t awg-failover "$*" 2>/dev/null; echo "$m" >> "$LOGF"
  if [ "$(wc -l < "$LOGF")" -gt 1000 ]; then tail -n 500 "$LOGF" > "$LOGF.tmp" && mv "$LOGF.tmp" "$LOGF"; fi
}
ev(){ local t; epoch t; echo "$t|$1|$RT$2" >> "$EVF"; if [ "$(wc -l < "$EVF")" -gt 3000 ]; then tail -n 2000 "$EVF" > "$EVF.tmp" && mv "$EVF.tmp" "$EVF"; fi; }

# Канал жив, если через него открывается HTTPS хотя бы к одному из независимых узлов TARGETS
# (отказ одного сайта канал не роняет). Если HTTPS не прошёл ни к одному — пробуем ping (ICMP у части
# операторов не ходит, поэтому он вторым). Канал мёртв, только если не ответил никто.
declare -A RXL CHKT
check(){
  [ "$1" = "$MAIN" ] && [ -e "$SIM" ] && return 1
  local t c rx now
  # из туннеля за проход пришло ≥ CHECK_RX_MIN байт (это не keepalive: тот ~100 байт) — сервер отвечает, канал жив;
  # без такого трафика или раз в CHECK_MAX_AGE — настоящая проверка HTTPS. Падение канала обрывает трафик —
  # и следующий же проход идёт к HTTPS, так что переключение не запаздывает.
  if [ "${CHECK_RX_MIN:-0}" -gt 0 ]; then
    rx=""; { read -r rx < "$SYSNET/$1/statistics/rx_bytes"; } 2>/dev/null; epoch now
    if [[ $rx =~ ^[0-9]+$ ]] && [ -n "${RXL[$1]:-}" ] && [ $((rx - RXL[$1])) -ge "$CHECK_RX_MIN" ] && [ $((now - ${CHKT[$1]:-0})) -lt "$CHECK_MAX_AGE" ]; then
      RXL[$1]=$rx; return 0
    fi
    [[ $rx =~ ^[0-9]+$ ]] && RXL[$1]=$rx
  fi
  # сторожа дополнительных маршрутов проверяют те же туннели: успешная проверка другого сторожа в этом же проходе
  # (не старше INTERVAL) засчитывается и здесь — без второго запроса HTTPS через тот же туннель. Сбой не делится:
  # его каждый сторож перепроверяет сам.
  local okf="$RUNDIR/awg-chk-$1" ts=""
  { read -r ts < "$okf"; } 2>/dev/null; epoch now
  if [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -ge 0 ] && [ $((now - ts)) -lt "$INTERVAL" ]; then CHKT[$1]=$now; return 0; fi
  for t in $TARGETS; do
    c=$(curl -sk -o /dev/null --connect-timeout 3 -m 5 --interface "$1" -w '%{http_code}' "https://$t/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && { chk_ok "$1"; return 0; }
  done
  for t in $TARGETS; do ping -I "$1" -c 1 -W 2 "$t" >/dev/null 2>&1 && { chk_ok "$1"; return 0; }; done
  return 1
}
chk_ok(){ epoch "CHKT[$1]"; printf '%s\n' "${CHKT[$1]}" > "$RUNDIR/awg-chk-$1" 2>/dev/null; }
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
declare -A ICMP_OFF ICMP_MISS
probe(){
  local i=$1 out l r now
  epoch now
  # ICMP через этот туннель не ходит, а TCP ходит — 5 пингов (~2,5 с) каждую пробу не тратим полчаса
  if [ "${ICMP_SEEN[$i]:-0}" != 1 ] && [ "$now" -lt "${ICMP_OFF[$i]:-0}" ]; then
    probe_tcp "$i"
  else
    out=$(ping -I "$i" -c 5 -i 0.3 -W 1 -q 1.1.1.1 2>/dev/null)
    l=$(echo "$out" | awk '/packet loss/{for(k=1;k<=NF;k++) if($k ~ /%/){gsub("%","",$k); print int($k); exit}}')
    r=$(echo "$out" | awk -F'=' '/min\/avg\/max/{split($2,a,"/"); printf "%d", a[2]+0.5; exit}')
    [ -z "$l" ] && l=100
    [ "$l" -lt 100 ] && ICMP_SEEN[$i]=1
  fi
  if [ "${ICMP_SEEN[$i]:-0}" = 1 ]; then
    QLOSS[$i]=$l; QRTT[$i]=${r:-0}; QMETH[$i]=icmp
    # ICMP раньше ходил, а теперь не ходит совсем — сначала TCP: оператор мог закрыть ICMP, а канал жив
    if [ "$l" = 100 ]; then
      probe_tcp "$i"
      if [ "${QLOSS[$i]}" -lt 100 ]; then
        # дважды подряд: ICMP нет, TCP есть — оператор закрыл ICMP; один раз — мог просто ожить канал между пробами
        ICMP_MISS[$i]=$(( ${ICMP_MISS[$i]:-0} + 1 ))
        [ "${ICMP_MISS[$i]}" -ge 2 ] && { ICMP_SEEN[$i]=0; ICMP_OFF[$i]=$((now + 1800)); ICMP_MISS[$i]=0; }
      else QLOSS[$i]=100; QRTT[$i]=0; QMETH[$i]=icmp; fi      # не отвечает ничего — канал лежит, метод остаётся ICMP
    else ICMP_MISS[$i]=0
    fi
  elif [ "$now" -ge "${ICMP_OFF[$i]:-0}" ]; then
    probe_tcp "$i"; l=${QLOSS[$i]}
    if [ "${QLOSS[$i]}" -lt 100 ]; then
      ICMP_MISS[$i]=$(( ${ICMP_MISS[$i]:-0} + 1 ))
      [ "${ICMP_MISS[$i]}" -ge 2 ] && { ICMP_OFF[$i]=$((now + 1800)); ICMP_MISS[$i]=0; }
    fi
  fi
  [ "${QLOSS[$i]}" -ge "$QUALITY_LOSS" ] && return 0
  [ "$QUALITY_RTT" -gt 0 ] && [ "${QRTT[$i]}" -ge "$QUALITY_RTT" ] && return 0
  return 1
}

declare -A FWR
prepare(){
  # Каждая таблица читается один раз за проход (3 вызова iptables вместо ~25): меньше спора за блокировку xtables
  # с UniFi. Если снимок не получен — в этот проход ничего не меняем. Правило, которого нет в снимке,
  # перепроверяется точным «iptables -C» и добавляется, только если его действительно нет.
  local i t r rules
  declare -A S
  # только нужные цепочки, а не таблицы целиком (у UniFi в mangle и filter сотни правил)
  S[nat]=$'\n'$(iptables -t nat -S POSTROUTING 2>/dev/null)$'\n' || return 0
  S[mangle]=$'\n'$(iptables -t mangle -S FORWARD 2>/dev/null)$'\n' || return 0
  S[filter]=$'\n'$(iptables -t filter -S FORWARD 2>/dev/null)$'\n' || return 0
  for i in "${TUNS[@]}"; do
    [ -n "${FWR[$i]:-}" ] || FWR[$i]=$(fw_rules "$i")
    while IFS='|' read -r t r; do
      [[ ${S[$t]} == *$'\n'"-A $r"$'\n'* ]] && continue
      # shellcheck disable=SC2086
      ensure "$t" -I $r
    done <<< "${FWR[$i]}"
  done
  # правило PBR (если UniFi его потерял) добавляем со своей меткой proto 99: так удаление отличит его от правила UniFi
  rules=$(ip rule show 2>/dev/null)
  [[ $rules == *"fwmark $MARK"* ]] || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" proto 99 2>/dev/null \
    || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"
  [ "$V6" = 1 ] && prepare6
  return 0
}
prepare6(){  # IPv6 через туннель (#23): правило PBR IPv6 и NAT66/MSS/FORWARD для каждого туннеля
  local i t r S6
  ip -6 rule show 2>/dev/null | grep -q "fwmark $MARK" || ip -6 rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" proto 99 2>/dev/null
  for t in nat mangle filter; do
    if [ "$t" = nat ]; then S6=$(ip6tables -t nat -S POSTROUTING 2>/dev/null) || continue
    else S6=$(ip6tables -t "$t" -S FORWARD 2>/dev/null) || continue; fi
    for i in "${TUNS[@]}"; do
      while IFS='|' read -r tt r; do
        [ "$tt" = "$t" ] || continue
        grep -q -x -F -- "-A $r" <<< "$S6" && continue
        # shellcheck disable=SC2086
        { ip6tables -t "$t" -C $r 2>/dev/null; [ $? -eq 1 ] && ip6tables -t "$t" -I $r 2>/dev/null; }
      done < <(fw_rules "$i")
    done
  done
}
has_v6(){ ip -6 -o addr show dev "$1" scope global 2>/dev/null | grep -q inet6; }
v6_sync(){  # при включённом IPv6 через туннель: туннель с IPv6 в конфиге, но без адреса на интерфейсе — поднять заново
  local i cf
  for i in "${TUNS[@]}"; do
    cf=$("$DD/up.sh" --conf-of "$i" 2>/dev/null); [ -n "$cf" ] && [ -f "$DD/$cf" ] || continue
    grep -i -E '^[[:space:]]*Address[[:space:]]*=' "$DD/$cf" | grep -q ':' || continue
    link_up "$i" && ! has_v6 "$i" && { log "$i: IPv6 через туннель — поднимаю заново с IPv6-адресом"; up_once "$i" force; }
  done
  return 0
}
v6_off(){  # IPv6 через туннель выключен: убрать свои правило и маршруты IPv6 (правила UniFi не трогаем — только proto 99)
  ip -6 rule show 2>/dev/null | grep "fwmark $MARK" | grep -q "proto 99" && ip -6 rule del fwmark "$MARK" lookup "$TABLE" priority "$PRIO" proto 99 2>/dev/null
  local j
  for j in "${TUNS[@]}"; do ip -6 route del default dev "$j" table "$TABLE" 2>/dev/null; done
  ip -6 route del unreachable default metric 200 table "$TABLE" 2>/dev/null   # маршруты UniFi в таблице не трогаем
  return 0
}

declare -A NEXT_TRY
ensure_tunnels(){
  local i now; epoch now
  for i in "${TUNS[@]}"; do
    link_up "$i" && continue
    [ "${NEXT_TRY[$i]:-0}" -gt "$now" ] && continue
    NEXT_TRY[$i]=$((now + 30))
    log "$i отсутствует, поднимаю"
    up_once "$i" || log "$i: не удалось поднять (проверьте: $DD/up.sh $i)"
  done
}
# поднять туннель один раз, даже если его одновременно поднимает сторож другого маршрута (#22); force — пересоздать
up_once(){
  if command -v flock >/dev/null; then
    ( flock -w 30 9 || exit 1; [ "${2:-}" != force ] && link_up "$1" && exit 0; "$DD/up.sh" "$1" >/dev/null 2>&1 ) 9>"${AWG_RUN:-/run}/awg-up-$1.lock"
  else "$DD/up.sh" "$1" >/dev/null 2>&1; fi
}

route_ok(){  # таблица PBR уже такая, как нужно: маршрут в $1 (метрика METRIC), blackhole, и никаких других туннелей
  local cur j l ok_a=0 ok_b=0
  cur=$(ip -4 route show table "$TABLE" 2>/dev/null) || return 1
  while IFS= read -r l; do
    case "$l" in
      "default dev $1 "*"metric $METRIC"|"default dev $1 "*"metric $METRIC "*) ok_a=1;;   # не «metric 50» при METRIC=5
      "blackhole default"*"metric 200"*) ok_b=1;;
      "default dev "*) for j in "${TUNS[@]}"; do [[ $l == "default dev $j "* ]] && return 1; done;;
    esac
  done <<< "$cur"
  [ $ok_a = 1 ] && [ $ok_b = 1 ]
}
set_active(){
  local a=${TUNS[$1]} j
  # интерфейса ещё нет (старт до up.sh): маршрут не ставим, остаётся blackhole; цикл поставит его, когда туннель поднимется
  # в обычном проходе таблица уже верная — одно чтение вместо трёх изменений
  if ! { link_up "$a" && route_ok "$a"; }; then
    link_up "$a" && ip route replace default dev "$a" metric $METRIC table "$TABLE"
    for j in "${TUNS[@]}"; do [ "$j" != "$a" ] && ip route del default dev "$j" table "$TABLE" 2>/dev/null; done
    ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
  fi
  if [ "$V6" = 1 ]; then
    if link_up "$a" && has_v6 "$a"; then ip -6 route replace default dev "$a" metric $METRIC table "$TABLE" 2>/dev/null
    else ip -6 route del default metric $METRIC table "$TABLE" 2>/dev/null; fi
    for j in "${TUNS[@]}"; do [ "$j" != "$a" ] && ip -6 route del default dev "$j" table "$TABLE" 2>/dev/null; done
    # у активного туннеля нет IPv6: отказ сразу (устройства переходят на IPv4), а не тишина и не WAN
    ip -6 route replace unreachable default metric 200 table "$TABLE" 2>/dev/null
  fi
}

cleanup(){  # cleanup [all] — убрать маршруты туннелей; blackhole остаётся (kill switch на время перезапуска), all — и его
  local j
  for j in "${TUNS[@]}"; do ip route del default dev "$j" table "$TABLE" 2>/dev/null; ip -6 route del default dev "$j" table "$TABLE" 2>/dev/null; done
  [ "$1" = all ] && { ip route del blackhole default metric 200 table "$TABLE" 2>/dev/null; v6_off; }
  return 0
}

STATE_LAST=""; STATE_T=0
write_state(){
  # файл переписывается (mv — отдельный процесс), только если состояние изменилось или прошло 10 с: UPDATED служит
  # «сердцебиением» для панели, awgctl и метрик (тревога — при возрасте больше 30–60 с)
  local i EPOCH_NOW body; epoch EPOCH_NOW
  body="ACTIVE=${TUNS[$idx]}"$'\n'"FORCED=$forced"$'\n'
  body+="TUNNELS=\"${TUNS[*]}\""$'\n'"ROUTE=$ROUTE"$'\n'"RAIL=${RAIL_IF:-}"$'\n'"TABLE=$TABLE"$'\n'"V6=$V6"$'\n'
  for i in "${TUNS[@]}"; do body+="LOSS_$i=${QLOSS[$i]:-}"$'\n'"RTT_$i=${QRTT[$i]:-}"$'\n'"QMETH_$i=${QMETH[$i]:-}"$'\n'"DNS_$i=${DNSOK[$i]:-}"$'\n'; done
  [ "$body" = "$STATE_LAST" ] && [ $((EPOCH_NOW - STATE_T)) -lt 10 ] && [ -f "$STATEF" ] && return 0
  printf 'UPDATED=%s\n%s' "$EPOCH_NOW" "$body" > "$STATEF.tmp" && mv "$STATEF.tmp" "$STATEF" && { STATE_LAST=$body; STATE_T=$EPOCH_NOW; }
}

tun_addr(){ ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
tun_addr6(){ ip -6 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
# туннель активен у сторожа другого маршрута (#22)? Тогда его соединения не сбрасываем: они чужие и живые
busy_elsewhere(){
  local f base=$STATEF
  [ -n "$ROUTE" ] && base=${STATEF%-"$ROUTE"}
  for f in "$base" "$base"-*; do
    [ "$f" = "$STATEF" ] && continue
    [ -f "$f" ] && grep -qx "ACTIVE=$1" "$f" 2>/dev/null && return 0
  done
  return 1
}
ct_flush(){  # ct_flush ТУННЕЛЬ — сбросить записи conntrack, заNATенные на адрес туннеля
  command -v conntrack >/dev/null || return 0
  busy_elsewhere "$1" && return 0
  local a; a=$(tun_addr "$1"); [ -n "$a" ] && conntrack -D -q "$a" >/dev/null 2>&1
  if [ "$V6" = 1 ]; then a=$(tun_addr6 "$1"); [ -n "$a" ] && conntrack -D -f ipv6 -q "$a" >/dev/null 2>&1; fi
  return 0
}
index_of(){ local k; for k in "${!TUNS[@]}"; do [ "${TUNS[$k]}" = "$1" ] && { echo "$k"; return 0; }; done; return 1; }

[ "$1" = cleanup ] && { cleanup "$2"; exit 0; }
# сигнал только ставит флажок, остановка — в основном цикле. Обработчик, запущенный посреди «read -t» (паузы), bash
# прерывает, когда истекает время паузы: при длинной уборке сторож не завершался (уборка обрывалась после записи в журнал,
# дальше шёл обычный цикл) — systemd ждал 90 с и убивал его
STOP=""
trap 'STOP=1' INT TERM
stop_now(){ cleanup; log "остановка: маршруты туннелей убраны, blackhole оставлен (трафик PBR блокируется)"; ev stop "сторож остановлен"; rm -f "$STATEF"; exit 0; }

# kill switch сразу, ещё до паузы и проверок: пока маршрута в туннель нет, трафик PBR не уйдёт в WAN
ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
# после загрузки роутера даём UniFi 30 с собрать свои правила и таблицы
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && sleep "${BOOT_WAIT:-30}"

n=$(dedup); [ "${n:-0}" -gt 0 ] && log "убрано дубликатов правил iptables: $n"

idx=0; fails=0; both_flag=0; forced=""; qbad=0; last_q=0; last_sw=0
declare -A OKS QOK RDEAD RNEXT
for k in "${!TUNS[@]}"; do OKS[$k]=0; QOK[$k]=1; done
# сначала поднять отсутствующие туннели, потом ставить маршрут (иначе «Cannot find device» в журнале при каждом старте)
ensure_tunnels
# сторож начинает с основного канала: записи conntrack, заNATенные на другие туннели (например, на запасной до перезапуска), сбросить
if [ "$V6" = 1 ]; then v6_sync; else v6_off; fi
set_active 0
for k in "${!TUNS[@]}"; do [ "$k" = 0 ] && continue; ct_flush "${TUNS[$k]}"; done
# прошивка UniFi сменилась? (#9) — восстановление и самопроверка в фоне, сторож не ждёт
[ -x "$DD/awg-restore.sh" ] && [ -z "${AWG_NO_FWCHECK:-}" ] && { setsid "$DD/awg-restore.sh" --fw-check >> "$DD/restore.log" 2>&1 < /dev/null & }
log "старт: туннели ${TUNS[*]}, таблица $TABLE${RAIL_IF:+ (профиль $RAIL_IF)}, возврат через ${RECOVER_SEC}с, качество: $QUALITY$( [ "$V6" = 1 ] && echo ", IPv6 через туннель")"
ev start "основной $MAIN, всего туннелей $N"

switch_to(){  # switch_to индекс тип сообщение
  local old=${TUNS[$idx]}
  # соединения, заNATенные на адрес прежнего туннеля, иначе так и пойдут в новый туннель со старым адресом и умрут
  # (UDP с постоянным портом — VoIP, игры, WireGuard клиентов — не восстановились бы сами)
  local prev=$idx
  idx=$1; fails=0; qbad=0; both_flag=0; epoch last_sw
  set_active "$idx"                      # сначала маршрут на новый туннель, потом сброс записей: иначе они тут же создадутся заново
  [ "$idx" != "$prev" ] && ct_flush "$old"
  for k in "${!TUNS[@]}"; do OKS[$k]=0; RDEAD[$k]=0; RNEXT[$k]=0; done
  ev "$2" "$3"
}

exec {SLEEPFD}<> <(:)     # канал, в который никто не пишет: read -t на нём — просто пауза
while true; do
  [ -n "$STOP" ] && stop_now
  ensure_tunnels
  prepare
  epoch now

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
      [ "${OKS[$k]}" = 0 ] && [ "$now" -lt "${RNEXT[$k]:-0}" ] && continue    # давно лежит — проверяем реже (ниже)
      alive=0; check "$t" && alive=1
      if [ $alive = 1 ] && [ "${QOK[$k]}" = 1 ]; then
        RDEAD[$k]=0; RNEXT[$k]=0
        [ "${OKS[$k]}" = 0 ] && { OKS[$k]=$now; log "$t снова отвечает, жду ${RECOVER_SEC}с без сбоев"; }
        if [ $(( now - ${OKS[$k]} )) -ge "$RECOVER_SEC" ]; then
          if [ "$k" -eq 0 ]; then log "ВОЗВРАТ на основной канал $t"; else log "возврат на более приоритетный канал $t"; fi
          switch_to "$k" return "возврат на $t"; break
        fi
      else
        [ "${OKS[$k]}" != 0 ] && log "$t снова сбоит, отсчёт возврата сброшен"
        OKS[$k]=0
        # канал, который не отвечает больше RECHECK_AFTER секунд, проверяем раз в RECHECK_SLOW, а дольше 10 минут — раз
        # в RECHECK_MAX: проверка мёртвого туннеля — это 3 HTTPS по 3 с и ping, проход растягивался до ~15 с, и сторож
        # медленнее замечал падение работающего (активного) канала. Возврат запаздывает не больше чем на RECHECK_MAX.
        # Отвечает, но с плохим качеством — не «лежит»: проверяется как обычно (иначе проба качества, которая его
        # оправдает, тоже откладывалась бы).
        if [ $alive = 1 ]; then RDEAD[$k]=0; RNEXT[$k]=0
        else
          [ "${RDEAD[$k]:-0}" = 0 ] && RDEAD[$k]=$now
          if [ $((now - RDEAD[$k])) -ge 600 ]; then RNEXT[$k]=$((now + RECHECK_MAX))
          elif [ $((now - RDEAD[$k])) -ge "$RECHECK_AFTER" ]; then RNEXT[$k]=$((now + RECHECK_SLOW)); fi
        fi
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
    for ((k=0; k<idx; k++)); do [ "$now" -lt "${RNEXT[$k]:-0}" ] && continue; probe "${TUNS[$k]}" && QOK[$k]=0 || QOK[$k]=1; done
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
  [ -n "$STOP" ] && stop_now
  read -r -t "$INTERVAL" -u "$SLEEPFD" _ 2>/dev/null   # пауза без внешнего sleep; сигнал TERM прерывает её сразу
done
