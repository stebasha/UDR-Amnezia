#!/bin/bash
# awg-diagnose: поиск причины неисправности. Только чтение, ничего не меняет.
#   diagnose.sh              проверить всю цепочку и назвать первую причину
#   diagnose.sh ТУННЕЛЬ      только этот туннель (awgmain, awgbackup, awgalt1…)
# Проверки идут по слоям, как ходит пакет: WAN → сервер туннеля → handshake → интернет и DNS через туннель
# → таблица и метка PBR → NAT/FORWARD → MTU → kill switch → IPv6 → службы. Первая найденная причина — в итоге,
# с безопасной командой исправления. Код возврата: 0 — причин не найдено, 1 — найдена хотя бы одна.
iptables(){ command iptables -w 10 "$@"; }
DD=${DD:-/data/awg}
AWG=${AWG:-$DD/awg}
STATEF=${STATEF:-/run/awg-state}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-}; MARK=${MARK:-}; MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; RAIL_IF=${RAIL_IF:-}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
[ -n "$1" ] && TUNS=$1
TARGETS=${TARGETS:-"1.1.1.1 8.8.8.8 9.9.9.9"}
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; Y=; B=; D=; N=; fi

CAUSES=()     # «причина|что сделать»
ok(){ echo "  ${G}✔${N} $*"; }
no(){ echo "  ${R}✖${N} $1"; CAUSES+=("$1|$2"); }
wa(){ echo "  ${Y}▲${N} $1"; [ -n "$2" ] && echo "      ${D}$2${N}"; }
inf(){ echo "  ${D}· $*${N}"; }
sec(){ echo; echo "${B}$*${N}"; }
dev_of(){ awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
hs_age(){ local ts; ts=$("$AWG" show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
conf_of(){ case "$1" in "$MAIN") echo main.conf;; "$BACKUP") [ -f "$DD/backup.conf" ] && echo backup.conf || echo client.conf;; *) echo "$1.conf";; esac; }
https_ok(){  # https_ok [интерфейс] → печатает число ответивших узлов из TARGETS
  local n=0 t c
  for t in $TARGETS; do
    c=$(curl -sk -o /dev/null --connect-timeout 3 -m 5 ${1:+--interface "$1"} -w '%{http_code}' "https://$t/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && n=$((n+1))
  done
  echo $n
}
doh_ok(){ curl -s -m 6 ${1:+--interface "$1"} -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=example.com&type=A' 2>/dev/null | grep -q '"Status":0'; }
extip(){ local ip u; for u in https://api.ipify.org https://ifconfig.me; do ip=$(curl -4 -s -m 6 ${1:+--interface "$1"} "$u" 2>/dev/null); [[ $ip =~ ^[0-9.]+$ ]] && { echo "$ip"; return; }; done; }
ntargets=$(echo $TARGETS | wc -w)

echo "${B}Диагностика AmneziaWG · $(hostname) · $(date '+%F %T')${N}"

# ---------------------------------------------------------------- 0. установка
sec "0. Установка"
if [ -z "$TABLE" ] || [ -z "$MARK" ]; then no "в $DD/awg.env нет TABLE/MARK: параметры PBR не определены" "$DD/install.sh → Компоненты → Туннели → Заново определить PBR"
else ok "awg.env: таблица $TABLE, метка $MARK, рельса ${RAIL_IF:-?}, туннели: $TUNS"; fi
if "$AWG" --version >/dev/null 2>&1 && "$DD/amneziawg-go" --version >/dev/null 2>&1; then ok "бинарники запускаются: $("$AWG" --version 2>&1 | head -1 | awk '{print $1, $2}')"
else no "бинарники amneziawg-go/awg не запускаются" "$DD/install.sh → Компоненты → Туннели → Обновить бинарники"; fi
if systemctl is-active --quiet awg-failover 2>/dev/null; then ok "сторож awg-failover работает"
else no "сторож awg-failover не работает: маршрута в туннель нет, трафик PBR стоит" "systemctl restart awg-failover; journalctl -u awg-failover -n 30"; fi
if [ -r "$STATEF" ]; then u=$(. "$STATEF"; echo "$UPDATED"); a=$(( $(date +%s) - ${u:-0} ))
  [ "$a" -le 60 ] && ok "состояние сторожа свежее (${a} с)" || wa "состояние сторожа не обновлялось ${a} с" "сторож завис или долго ждёт ответа туннелей: journalctl -u awg-failover -n 30"
fi

# ---------------------------------------------------------------- 1. WAN
sec "1. Интернет у провайдера (WAN)"
WAN=${WANIF:-$(ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep -v -E '^(awg|wg|lo|wgclt)' | head -n1)}
wip=$(ip -4 -o addr show dev "$WAN" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$wip" ] && ok "WAN $WAN: адрес $wip" || no "у WAN-интерфейса ${WAN:-?} нет адреса IPv4" "проверьте подключение к провайдеру в UniFi (Internet)"
n=$(https_ok "$WAN")
if [ "$n" -gt 0 ]; then ok "HTTPS напрямую через WAN: ответили $n из $ntargets узлов"; WAN_OK=1
else no "через WAN интернет не открывается: проблема у провайдера или на роутере, туннели тут ни при чём" "проверьте кабель и статус Internet в UniFi; ping -I $WAN 1.1.1.1"; WAN_OK=0; fi
if getent ahostsv4 github.com >/dev/null 2>&1; then ok "DNS роутера работает (github.com разрешается)"
else no "DNS самого роутера не отвечает: имена серверов туннелей не разрешатся" "проверьте DNS в UniFi (Settings → Internet → DNS); nslookup github.com"; fi
DIRECT_IP=$(extip "$WAN"); [ -n "$DIRECT_IP" ] && inf "внешний адрес напрямую: $DIRECT_IP"

# ---------------------------------------------------------------- 2. туннели
for t in $TUNS; do
  sec "2. Туннель $t"
  cf=$DD/$(conf_of "$t")
  if [ ! -f "$cf" ]; then no "$t: нет конфига $cf" "$DD/install.sh → Компоненты → Туннели"; continue; fi
  ep=$(awk -F'=' 'tolower($1) ~ /^[ \t]*endpoint[ \t]*$/ {gsub(/[ \t\r]/,"",$2); print $2; exit}' "$cf"); host=${ep%:*}; port=${ep##*:}
  epip=$("$AWG" show "$t" endpoints 2>/dev/null | awk 'NR==1{print $2}' | sed -E 's/:[0-9]+$//')
  if [ -z "$epip" ]; then
    case "$host" in *[!0-9.]*) epip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}');; *) epip=$host;; esac
  fi
  [ -n "$epip" ] && ok "сервер $host:$port → $epip" || { no "$t: имя сервера $host не разрешается" "nslookup $host; проверьте Endpoint в $cf"; continue; }
  if ! ip link show "$t" >/dev/null 2>&1; then no "$t: интерфейса нет — туннель не поднят" "$DD/up.sh $t (смотрите текст ошибки)"; continue; fi
  ok "интерфейс $t существует, MTU $(cat /sys/class/net/$t/mtu 2>/dev/null)"
  via=$(ip -4 route get "$epip" 2>/dev/null | dev_of)
  case "$via" in
    awg*) no "$t: пакеты к своему же серверу $epip идут через туннель $via (петля)" "проверьте маршруты: ip route get $epip; в правилах PBR UniFi исключите адрес сервера";;
    "")   no "$t: нет маршрута до сервера $epip" "ip route get $epip";;
    *)    ok "к серверу пакеты идут через $via";;
  esac
  hs=$(hs_age "$t")
  if [ "$hs" -lt 0 ]; then
    if [ "${WAN_OK:-0}" = 0 ]; then no "$t: handshake не было — но и WAN не работает (см. раздел 1)" "сначала интернет у провайдера"
    else no "$t: handshake ни разу не прошёл — сервер не отвечает" "порт закрыт у хостера, неверный ключ или параметры обфускации, DPI. Подробно: $DD/install.sh → Диагностика → tcpdump на WAN"; fi
    continue
  elif [ "$hs" -gt 180 ]; then
    no "$t: последний handshake $hs с назад (норма — меньше 3 минут)" "соединение с сервером потеряно: $DD/awg show $t; tcpdump -ni $WAN udp and host $epip"
  else ok "handshake $hs с назад"; fi
  n=$(https_ok "$t")
  if [ "$n" -eq 0 ]; then
    rx=$("$AWG" show "$t" transfer 2>/dev/null | awk '{print $2; exit}')
    no "$t: handshake есть, но интернет через туннель не открывается (принято байт: ${rx:-0})" "у провайдера VPN кончилась подписка или лимит; у своего VPS — нет NAT/ip_forward (audit-server.sh). Если обмен рвётся через 5–8 с — DPI"
    continue
  fi
  [ "$n" -lt "$ntargets" ] && wa "HTTPS через туннель: ответили $n из $ntargets узлов" "часть узлов недоступна через этот туннель; канал считается живым" || ok "HTTPS через туннель: ответили все $n узла"
  if doh_ok "$t"; then ok "DNS через туннель работает (DoH 1.1.1.1)"
  else wa "DNS-запрос через туннель (DoH 1.1.1.1) не прошёл" "сайты по адресам открываются, а DNS-сервер недоступен через туннель: возможна блокировка DoH у сервера VPN"; fi
  tip=$(extip "$t")
  if [ -n "$tip" ] && [ -n "$DIRECT_IP" ] && [ "$tip" = "$DIRECT_IP" ]; then no "$t: внешний адрес через туннель совпадает с прямым ($tip) — трафик идёт мимо туннеля" "ip route get 1.1.1.1 oif $t; проверьте AllowedIPs в $cf"
  elif [ -n "$tip" ]; then ok "внешний адрес через туннель: $tip"; fi
  m=$(cat /sys/class/net/$t/mtu 2>/dev/null)
  if [ -n "$m" ]; then
    if ping -I "$t" -M do -c 2 -W 2 -s $((m-28)) 1.1.1.1 >/dev/null 2>&1; then ok "пакет размером MTU ($m) проходит без фрагментации"
    elif ping -I "$t" -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then no "$t: большие пакеты (MTU $m) не проходят, маленькие проходят — сайты будут «висеть» на загрузке" "$DD/mtu.sh $t (подбор), затем $DD/mtu.sh $t --apply"
    else inf "ICMP через туннель не ходит: MTU проверить нельзя"; fi
  fi
done

# ---------------------------------------------------------------- 3. PBR
if [ -n "$TABLE" ] && [ -n "$MARK" ]; then
  sec "3. Policy-Based Routes UniFi"
  if [ -n "$RAIL_IF" ]; then
    ur=$(ip -4 rule show | awk -v r="$RAIL_IF" '/fwmark/ && $0 ~ ("lookup [0-9]+\\." r "[[:space:]]*$") && !/proto 99/ {for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1)} print m, t}')
    if [ -z "$ur" ]; then no "в UniFi нет правила PBR для профиля $RAIL_IF: профиль выключен, удалён или на него не ссылается ни одно правило" "UniFi → Settings → Routing → Policy-Based Routes; затем $DD/install.sh → Заново определить PBR"
    elif ! echo "$ur" | grep -qx -F "$MARK ${TABLE}.$RAIL_IF"; then no "UniFi сменил правило PBR профиля $RAIL_IF: сейчас «$(echo "$ur" | head -n1)», в awg.env MARK=$MARK TABLE=$TABLE" "$DD/install.sh → Компоненты → Туннели → Заново определить PBR"
    else ok "правило UniFi: метка $MARK → таблица $TABLE.$RAIL_IF"; fi
  fi
  tb=$(ip -4 route show table "$TABLE" 2>/dev/null)
  ac=$(echo "$tb" | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev" && $(i+1) ~ /^awg/){print $(i+1); exit}}')
  if [ -n "$ac" ]; then ok "в таблице $TABLE активный туннель: $ac"
    st=$(hs_age "$ac"); [ "$st" -lt 0 ] || [ "$st" -gt 180 ] && no "активный в таблице туннель $ac не работает, а сторож его держит" "journalctl -u awg-failover -n 30; awgctl status"
  else no "в таблице $TABLE нет маршрута на туннель: устройства под PBR без интернета (утечки нет)" "systemctl restart awg-failover"; fi
  echo "$tb" | grep -q blackhole && ok "kill switch: blackhole в таблице $TABLE" || no "в таблице $TABLE нет blackhole: при падении туннеля трафик PBR может уйти мимо" "systemctl restart awg-failover"
  [ -r "$STATEF" ] && fo=$(. "$STATEF"; echo "$FORCED") && [ -n "$fo" ] && wa "канал выбран вручную: $fo" "вернуть автоматический выбор: awgctl auto"
  [ -e /tmp/awg-sim-down ] && no "включена имитация падения основного канала (/tmp/awg-sim-down)" "rm /tmp/awg-sim-down"

  # ---------------------------------------------------------------- 4. NAT, FORWARD
  sec "4. NAT и пересылка"
  for t in $TUNS; do
    c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -x -- "-A POSTROUTING -o $t -j MASQUERADE")
    case "$c" in 1) ok "NAT на $t";; 0) no "нет NAT на $t: ответы из интернета не вернутся" "systemctl restart awg-failover";; *) wa "NAT на $t: $c копий" "awgctl dedup";; esac
  done
  [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && ok "ip_forward включён" || no "ip_forward выключен: роутер не пересылает пакеты" "sysctl -w net.ipv4.ip_forward=1"
  d=0; for tb2 in nat mangle filter; do d=$((d + $(iptables -t $tb2 -S 2>/dev/null | grep '^-A ' | grep -E -- '(-[io] awg[a-z0-9]*( |$))|AWG_' | sort | uniq -d | wc -l))); done
  [ "$d" = 0 ] && ok "дубликатов правил нет" || wa "повторяющихся правил iptables: $d" "awgctl dedup"
  if [ "${LEAK_GUARD:-no}" = yes ]; then
    iptables -S FORWARD 2>/dev/null | grep '^-A' | head -n1 | grep -q -- '-j AWG_GUARD' && ok "защита от утечек (awg-guard) стоит первой в FORWARD" \
      || no "защита от утечек включена, но её цепочка не первая в FORWARD" "systemctl restart awg-guard; $DD/guard.sh check"
  fi

  # ---------------------------------------------------------------- 5. IPv6
  sec "5. IPv6"
  if ip -6 route show default 2>/dev/null | grep -q . && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    if [ "${LEAK_GUARD:-no}" = yes ] && [ "${LEAK_V6:-block}" = block ]; then ok "у WAN есть IPv6; помеченный PBR-трафик по IPv6 в WAN не выпускается"
    else wa "у WAN есть IPv6, а блокировки IPv6 для трафика под PBR нет: сайты с IPv6 могут открываться мимо туннеля" "включите awg-guard с LEAK_V6=block или отключите IPv6 в сетях с такими устройствами"; fi
  else ok "IPv6 в интернет у роутера нет — утечки по IPv6 исключены"; fi
fi

# ---------------------------------------------------------------- 6. службы
sec "6. Дополнительные службы"
any=0
for u in awg-subnets awg-self awg-guard awg-notify awg-bot awg-metrics; do
  [ -f "/etc/systemd/system/$u.service" ] || continue; any=1
  systemctl is-active --quiet "$u" && ok "$u работает" || no "$u установлена, но не работает" "systemctl restart $u; journalctl -u $u -n 20"
done
[ $any = 0 ] && inf "дополнительные службы не включены"
for c in subnets self; do
  [ -x "$DD/$c.sh" ] && systemctl is-active --quiet "awg-$c" 2>/dev/null || continue
  "$DD/$c.sh" check 2>/dev/null | grep '^FAIL' | sed 's/^FAIL *//' | while IFS= read -r l; do echo "  ${R}✖${N} awg-$c: $l"; done
  "$DD/$c.sh" check 2>/dev/null | grep -q '^FAIL' && CAUSES+=("awg-$c: проверка не пройдена (подробно: $DD/$c.sh check)|$DD/$c.sh check")
done

# ---------------------------------------------------------------- итог
echo
if [ ${#CAUSES[@]} -eq 0 ]; then
  echo "${G}${B}Итог: причин неисправности не найдено.${N}"
  echo "${D}Если конкретный сайт не работает: awgctl domain ИМЯ_САЙТА. Полная проверка: awgctl selftest${N}"
  exit 0
fi
c=${CAUSES[0]}
echo "${R}${B}Итог: ${c%%|*}${N}"
echo "  Что сделать: ${c#*|}"
if [ ${#CAUSES[@]} -gt 1 ]; then
  echo "  Ещё найдено (часто это следствия первой причины):"
  for c in "${CAUSES[@]:1}"; do echo "   • ${c%%|*}"; done
fi
exit 1
