#!/bin/bash
# iptables с ожиданием блокировки xtables: без -w чтение правил при занятой блокировке падает и даёт ложные FAIL/WARN
iptables(){ command iptables -w 10 "$@"; }
ip6tables(){ command ip6tables -w 10 "$@"; }
# awg-selftest: самопроверка всей схемы «от и до». Только чтение, кроме флага --full.
#   selftest.sh          быстрая проверка (около 20–40 с)
#   selftest.sh --full   плюс динамическая проверка kill switch: на доли секунды убирает маршрут в туннель
#                        и проверяет, что трафик PBR не пойдёт в WAN (затем маршрут возвращается).
# Код возврата: 0 — FAIL нет, 1 — есть FAIL.
DD=${DD:-/data/awg}
AWG=$DD/awg
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-0}; MARK=${MARK:-0x0/0x0}; MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; WANIF=${WANIF:-}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
FULL=0; [ "$1" = --full ] && FULL=1
ok=0; warn=0; bad=0
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
P(){ echo "  ${G}OK${N}    $1"; ok=$((ok+1)); }
W(){ echo "  ${Y}WARN${N}  $1"; [ -n "$2" ] && echo "        что делать: $2"; warn=$((warn+1)); }
F(){ echo "  ${R}FAIL${N}  $1"; [ -n "$2" ] && echo "        что делать: $2"; bad=$((bad+1)); }
I(){ echo "  ${B}INFO${N}  $1"; }
sec(){ echo; echo "${B}== $1 ==${N}"; }
age_s(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
extip(){ local ip u; for u in https://api.ipify.org https://ifconfig.me; do ip=$(curl -4 -s -m 7 ${1:+--interface $1} "$u" 2>/dev/null); [[ $ip =~ ^[0-9.]+$ ]] && { echo "$ip"; return; }; done; }
unit_present(){ [ -f "${SYSD:-/etc/systemd/system}/$1.service" ] || [ -f "$DD/$1.service" ]; }
wan_if(){ [ -n "$WANIF" ] && { echo "$WANIF"; return; }; ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep -v -E '^(awg|wg|lo|wgclt)' | head -n1; }
WAN=$(wan_if)

sec "Службы"
for u in awg-failover awg-subnets awg-self awg-guard awg-notify awg-bot awg-metrics; do
  if [ "$u" = awg-failover ] || unit_present $u; then
    if systemctl is-active --quiet $u 2>/dev/null; then P "$u: active"; else
      if [ "$u" = awg-failover ]; then F "$u не запущен" "systemctl start $u; journalctl -u $u -n 20"; else W "$u установлен, но не запущен" "systemctl start $u; journalctl -u $u -n 20"; fi
    fi
    if [ "$u" = awg-failover ] || unit_present $u; then systemctl is-enabled --quiet $u 2>/dev/null || W "$u: нет автозапуска" "systemctl enable $u"; fi
  fi
done
[ -e /tmp/awg-sim-down ] && W "включён флаг имитации падения /tmp/awg-sim-down" "rm /tmp/awg-sim-down"
if [ -s /run/awg-force ]; then W "канал выбран вручную: $(cat /run/awg-force)" "awgctl auto"; fi

sec "Туннели"
declare -A TIP
for t in $TUNS; do
  if ! ip link show "$t" >/dev/null 2>&1; then F "$t: интерфейса нет" "$DD/up.sh $t"; continue; fi
  a=$(age_s "$t")
  if [ "$a" -ge 0 ] && [ "$a" -lt 180 ]; then P "$t: handshake ${a} с назад"; else W "$t: handshake давно или не было ($a)" "ping -I $t -c 3 1.1.1.1; $AWG show $t"; fi
  m=$(cat /sys/class/net/$t/mtu 2>/dev/null); [ -n "$m" ] && I "$t: MTU $m"
  TIP[$t]=$(extip "$t")
  [ -n "${TIP[$t]}" ] && P "$t: интернет работает, внешний IP ${TIP[$t]}" || F "$t: через туннель нет интернета" "$DD/install.sh → Диагностика"
done
DIRECT_IP=$(extip "$WAN")
[ -n "$DIRECT_IP" ] && I "напрямую через WAN${WAN:+ ($WAN)}: $DIRECT_IP"
for t in $TUNS; do
  [ -n "${TIP[$t]}" ] && [ -n "$DIRECT_IP" ] && [ "${TIP[$t]}" = "$DIRECT_IP" ] && F "$t: внешний IP туннеля совпадает с прямым ($DIRECT_IP): трафик идёт мимо туннеля" "проверьте curl --interface $t и маршруты: ip route get 1.1.1.1 oif $t"
done

sec "PBR и kill switch"
# UniFi мог пересоздать профиль-«рельсу» с другой меткой/таблицей; сторож тогда держит устаревшее правило
dr=$(ip -4 rule show | awk -v r="${RAIL_IF:-wgclt1}" -v want="$MARK ${TABLE}.${RAIL_IF:-wgclt1}" '/fwmark/ && $0 ~ ("lookup [0-9]+\\." r "[[:space:]]*$") {for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1)} if (m" "t != want) {print m, t; exit}}')
[ -n "$dr" ] && F "правило PBR профиля ${RAIL_IF:-wgclt1} теперь «$dr», а в awg.env MARK=$MARK TABLE=$TABLE: устройства под PBR идут не туда" "$DD/install.sh → Компоненты → Туннели → Заново определить PBR"
n=$(ip rule show 2>/dev/null | grep -c "fwmark ${MARK%%/*}")
[ "$n" = 1 ] && P "правило PBR fwmark ${MARK%%/*}: одно" || W "правил fwmark ${MARK%%/*}: $n (ожидается 1)" "ip rule show; $DD/install.sh → Компоненты → PBR"
tb=$(ip route show table "$TABLE" 2>/dev/null)
ac=$(echo "$tb" | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev" && $(i+1) ~ /^awg/){print $(i+1); exit}}')
[ -n "$ac" ] && P "в таблице $TABLE активный туннель: $ac" || F "в таблице $TABLE нет маршрута на туннель" "systemctl restart awg-failover"
echo "$tb" | grep -q -E "blackhole|dev wgclt" && P "kill switch: в таблице есть blackhole/рельса, при падении туннелей трафик не утечёт" || W "kill switch: нет blackhole в таблице $TABLE" "systemctl restart awg-failover"
if [ $FULL = 1 ] && [ -n "$ac" ]; then
  ip route del default dev "$ac" table "$TABLE" 2>/dev/null
  r=$(ip route get 1.1.1.1 mark "${MARK%%/*}" 2>&1 | head -n1)
  ip route replace default dev "$ac" metric 5 table "$TABLE" 2>/dev/null
  dv=$(echo "$r" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  case "$dv" in
    "$WAN"|ppp*|eth*) F "kill switch ПРОВАЛЕН: при падении туннеля трафик PBR ушёл бы в $dv" "ip route show table $TABLE; systemctl restart awg-failover";;
    *) P "kill switch работает: при падении туннеля маршрут для PBR → ${dv:-blackhole/ошибка}";;
  esac
elif [ $FULL = 0 ]; then I "динамическая проверка kill switch: selftest.sh --full"; fi
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && P "ip_forward = 1" || F "ip_forward не 1" "sysctl -w net.ipv4.ip_forward=1"

sec "Дубликаты правил"
dup=0
for tb in nat mangle filter; do
  d=$(iptables -t $tb -S 2>/dev/null | grep '^-A ' | grep -E -- '(-[io] awg[a-z0-9]*( |$))|AWG_' | sort | uniq -d | wc -l)
  dup=$((dup + d))
done
[ "$dup" = 0 ] && P "дубликатов правил iptables для туннелей нет" || W "повторяющихся правил iptables: $dup (каждый пакет проходит их все — со временем падают скорость и запас CPU)" "$DD/failover.sh dedup (или awgctl dedup)"
r=$(ip -4 rule show 2>/dev/null | sort | uniq -d | wc -l)
[ "$r" = 0 ] && P "дубликатов ip rule нет" || W "повторяющихся ip rule: $r" "ip rule show | sort | uniq -d; лишние: ip rule del priority <N> from <подсеть>"

sec "NAT и MTU"
for t in $TUNS; do
  c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o $t -j MASQUERADE")
  [ "$c" = 1 ] && P "NAT MASQUERADE на $t: 1 правило" || W "NAT MASQUERADE на $t: $c (ожидается 1)" "systemctl restart awg-failover (сторож расставит правила)"
  m=$(cat /sys/class/net/$t/mtu 2>/dev/null)
  if [ -n "$m" ] && ip link show "$t" >/dev/null 2>&1; then
    if ping -I "$t" -M do -c 2 -W 2 -s $((m-28)) 1.1.1.1 >/dev/null 2>&1; then P "$t: пакет размером MTU ($m) проходит без фрагментации"
    elif ping -I "$t" -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then W "$t: пакеты размером MTU $m не проходят, а маленькие проходят" "$DD/mtu.sh $t (подбор MTU)"
    else I "$t: ICMP через туннель не отвечает, проверка MTU пропущена"; fi
  fi
done

sec "Утечки"
if [ "${LEAK_GUARD:-yes}" = yes ]; then
  if [ -x "$DD/guard.sh" ]; then
    out=$("$DD/guard.sh" check 2>&1); echo "$out" | grep -q '^FAIL' && F "защита от утечек (awg-guard) не применена" "systemctl restart awg-guard; $DD/guard.sh check" || P "защита от утечек (awg-guard) применена"
    while IFS= read -r l; do W "${l#WARN   }"; done < <(echo "$out" | grep '^WARN')
  else W "защита от утечек не установлена" "$DD/install.sh → Компоненты → Маршрутизация и защита"; fi
else I "защита от утечек выключена (LEAK_GUARD=no)"; fi
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  [ "${LEAK_V6:-block}" = block ] && P "у роутера есть глобальный IPv6; помеченный PBR-трафик и IPv6 клиентов VPN-сервера в WAN не выпускаются" || W "у роутера есть глобальный IPv6, а защита IPv6 выключена (LEAK_V6=${LEAK_V6})" "LEAK_V6=block в awg.env, systemctl restart awg-guard"
else I "глобального IPv6 у роутера нет — утечки по IPv6 исключены"; fi
# DNS: чей адрес видит внешний резолвер
r=""
if command -v dig >/dev/null; then r=$(dig +short +time=4 +tries=1 TXT o-o.myaddr.l.google.com 2>/dev/null | tr -d '"' | head -n1)
elif command -v nslookup >/dev/null; then r=$(nslookup -type=TXT o-o.myaddr.l.google.com 2>/dev/null | sed -n 's/.*text = "\(.*\)"/\1/p' | head -n1); fi
if [ -n "$r" ]; then
  if [ -n "$DIRECT_IP" ] && [ "$r" = "$DIRECT_IP" ]; then
    [ "${DNS_ALL_TUNNEL:-no}" = yes ] && W "DNS роутера уходит напрямую ($r), хотя DNS_ALL_TUNNEL=yes" "systemctl restart awg-self; $DD/self.sh check" || I "DNS-запросы роутера (имена сайтов) видит провайдер: резолвер приходит с адреса $r. Чтобы скрыть: DNS_ALL_TUNNEL=yes в awg.env"
  else I "внешний DNS-резолвер видит роутер как $r"; fi
else I "внешний адрес DNS-резолвера определить не удалось (нет dig/nslookup или нет ответа)"; fi

if [ -n "${EXTRA_SUBNETS// /}" ]; then
  sec "Клиенты VPN-сервера"
  if [ -x "$DD/subnets.sh" ]; then while IFS= read -r l; do case "$l" in OK*) P "${l#OK    }";; WARN*) W "${l#WARN   }";; FAIL*) F "${l#FAIL   }";; esac; done < <("$DD/subnets.sh" check 2>&1); fi
fi
if [ -x "$DD/self.sh" ] && systemctl is-active --quiet awg-self 2>/dev/null; then
  sec "Трафик роутера (awg-self)"
  while IFS= read -r l; do case "$l" in OK*) P "${l#OK    }";; WARN*) W "${l#WARN   }";; FAIL*) F "${l#FAIL   }";; esac; done < <("$DD/self.sh" check 2>&1)
fi
if [ -x "$DD/guard.sh" ] && { [ -n "$TUN_DOMAINS" ] || [ -n "$DIRECT_DOMAINS$DIRECT_SUBNETS" ]; }; then
  sec "Домены и исключения"
  while IFS= read -r l; do case "$l" in OK*) P "${l#OK    }";; WARN*) W "${l#WARN   }";; FAIL*) F "${l#FAIL   }";; esac; done < <("$DD/guard.sh" check 2>&1 | grep -E '^(OK|WARN|FAIL)')
fi

sec "Система"
fr=$(df -Pm "$DD" 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$fr" ] && { [ "$fr" -ge 100 ] && P "на /data свободно $fr МБ" || W "на /data свободно только $fr МБ" "почистите $DD/backups и логи"; }
[ "$(date +%Y)" -ge 2025 ] && P "время роутера: $(date '+%F %T')" || W "часы роутера показывают $(date): handshake может не проходить" "проверьте NTP"
for f in main.conf backup.conf client.conf telegram.env awg.env; do
  [ -e "$DD/$f" ] && { [ "$(stat -c %a "$DD/$f")" = 600 ] && P "$f: права 600" || W "$f: права $(stat -c %a "$DD/$f")" "chmod 600 $DD/$f"; }
done
if [ -x "$DD/install.sh" ] && [ -f "$DD/.manifest" ]; then
  v=$("$DD/install.sh" --verify 2>&1 | grep -c -E '^  (изменён|нет файла)')
  [ "${v:-0}" = 0 ] && P "файлы установки совпадают с манифестом" || W "файлов, изменённых или пропавших относительно манифеста: $v" "$DD/install.sh --verify"
fi

echo; echo "${B}Итог:${N} ${G}OK: $ok${N}   ${Y}WARN: $warn${N}   ${R}FAIL: $bad${N}"
[ $bad -eq 0 ]
