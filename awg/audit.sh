#!/bin/bash
# awg-audit — проверка установки на роутере: службы, туннели, правила, файлы. Только чтение.
DD=${DD:-/data/awg}
AWG=${AWG:-$DD/awg}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-0}; MARK=${MARK:-0x0/0x0}; RAIL_IF=${RAIL_IF:-wgclt1}
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNS="$MAIN${BACKUP:+ $BACKUP}"
NT=$(echo $TUNS | wc -w)
ok=0; warn=0; bad=0
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
P(){ echo "  ${G}OK${N}    $1"; ok=$((ok+1)); }
W(){ echo "  ${Y}WARN${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; warn=$((warn+1)); }
F(){ echo "  ${R}FAIL${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; bad=$((bad+1)); }
sec(){ echo; echo "${B}== $1 ==${N}"; }
age_s(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }

sec "Параметры"
if [ "$TABLE" = 0 ]; then F "нет $DD/awg.env" "$DD/awg-detect.sh"
else P "awg.env: таблица $TABLE, метка $MARK, рельса $RAIL_IF, туннели: $TUNS"; fi
for b in amneziawg-go awg; do [ -x "$DD/$b" ] && P "бинарник $b на месте" || F "нет $DD/$b" "часть 1, шаг 1.1"; done

sec "Службы и процессы"
st=$(systemctl is-active awg-failover 2>/dev/null); en=$(systemctl is-enabled awg-failover 2>/dev/null)
[ "$st" = active ] && P "awg-failover: active" || F "awg-failover: ${st:-нет}" "systemctl start awg-failover"
[ "$en" = enabled ] && P "awg-failover: автозапуск включён" || W "awg-failover: автозапуск ${en:-нет}" "systemctl enable awg-failover"
for u in awg-failover awg-notify awg-motd; do
  [ -f "$DD/$u.service" ] || continue
  [ $u = awg-notify ] && [ ! -f "$DD/telegram.env" ] && continue   # Telegram не настраивался
  [ $u = awg-motd ] && [ ! -f "$DD/motd.orig" ] && continue        # баннер не отключался
  cmp -s "/etc/systemd/system/$u.service" "$DD/$u.service" && P "$u.service совпадает с копией в $DD" \
    || W "$u.service в /etc отличается от копии в $DD или отсутствует" "cp $DD/$u.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now $u"
done
n=$(ps -eo pid,ppid,args | awk '/failover\.sh/ && !/awk/ && !/cleanup/ {p[$1]=$2; a[$1]=1} END{for(i in p) if(!(p[i] in a)) n++; print n+0}')
if [ "$st" = active ]; then [ "$n" = 1 ] && P "экземпляров failover.sh: 1" || W "экземпляров failover.sh: $n (нужен 1)" "systemctl stop awg-failover; pkill -f '/data/awg/failover[.]sh'; systemctl start awg-failover"
else [ "$n" = 0 ] && P "ручных экземпляров failover.sh нет" || W "failover.sh запущен вручную при остановленной службе" "pkill -f '/data/awg/failover[.]sh'; $DD/failover.sh cleanup"; fi
c=$(pgrep -c amneziawg-go 2>/dev/null); [ "${c:-0}" = "$NT" ] && P "процессов amneziawg-go: $NT" || W "процессов amneziawg-go: ${c:-0} (нужно $NT)" "pgrep -a amneziawg-go; лишний интерфейс: ip link del <имя>"
if [ -f "$DD/telegram.env" ]; then
  [ "$(systemctl is-active awg-notify 2>/dev/null)" = active ] && P "awg-notify: active" || W "awg-notify не запущен" "systemctl enable --now awg-notify"
fi

sec "Туннели"
for i in $TUNS; do ip link show "$i" >/dev/null 2>&1 && P "$i существует" || F "$i отсутствует" "$DD/up.sh $i"; done
for i in $TUNS; do
  a=$(age_s "$i")
  if [ "$a" -ge 0 ] && [ "$a" -lt 180 ]; then P "$i: handshake ${a}с назад"
  else W "$i: handshake давно или не было ($a)" "curl -s --interface $i https://ifconfig.me; $DD/awg show $i"; fi
done
ip link show "$RAIL_IF" >/dev/null 2>&1 && P "$RAIL_IF на месте (рельса PBR)" || W "$RAIL_IF отсутствует: UniFi мог убрать PBR-обвязку" "проверьте профиль VPN Client в UniFi, затем $DD/awg-detect.sh"

sec "Маршрутизация"
n=$(ip rule show | grep -c "fwmark ${MARK%%/*}")
[ "$n" = 1 ] && P "правило PBR fwmark ${MARK%%/*}: одно" || W "правил fwmark ${MARK%%/*}: $n (нужно 1)" "ip rule show"
t=$(ip route show table "$TABLE" 2>/dev/null)
echo "        таблица $TABLE:"; echo "$t" | sed 's/^/          /'
c=$(echo "$t" | grep -c 'dev awg')
[ "$c" = 1 ] && P "в таблице PBR ровно один AWG-маршрут" || { [ "$c" = 0 ] && F "в таблице PBR нет AWG-маршрута" "systemctl restart awg-failover" || W "AWG-маршрутов в таблице: $c (нужен 1)" "systemctl restart awg-failover"; }
echo "$t" | grep -q blackhole && P "blackhole на месте: при падении туннелей утечки в WAN нет" || W "в таблице нет blackhole" "systemctl restart awg-failover"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && P "ip_forward = 1" || F "ip_forward не 1" "sysctl -w net.ipv4.ip_forward=1"
for s in $EXTRA_SUBNETS; do
  ipset test UBIOS4local_network "$s" >/dev/null 2>&1 && P "подсеть $s в ipset UBIOS4local_network" || W "подсети $s нет в ipset" "сторож добавит её сам через 5 с; если нет — systemctl restart awg-failover"
done

sec "iptables"
for i in $TUNS; do
  c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o $i -j MASQUERADE")
  [ "$c" = 1 ] && P "NAT MASQUERADE на $i: 1" || W "NAT MASQUERADE на $i: $c (нужно 1)" "iptables -t nat -D POSTROUTING -o $i -j MASQUERADE  (до одного правила)"
done
d1=$(iptables -S FORWARD 2>/dev/null | sort | uniq -d); d2=$(iptables -t mangle -S FORWARD 2>/dev/null | sort | uniq -d)
[ -z "$d1$d2" ] && P "дублей в FORWARD (filter/mangle) нет" || W "дубли в FORWARD: $(echo "$d1$d2" | wc -l) строк" "iptables -S FORWARD | sort | uniq -d; удалите лишнюю копию: iptables -D ..."
iptables -S OUTPUT 2>/dev/null | grep -q -E 'icmp.*(DROP|REJECT)' && W "в OUTPUT есть DROP для icmp (остаток теста?)" "iptables -S OUTPUT"

sec "Файлы"
for f in main.conf ${BACKUP:+backup.conf} awg.env; do
  [ "$f" = backup.conf ] && [ ! -e "$DD/backup.conf" ] && [ -e "$DD/client.conf" ] && f=client.conf
  [ -e "$DD/$f" ] || { F "нет $DD/$f"; continue; }
  [ "$(stat -c %a "$DD/$f")" = 600 ] && P "$f: права 600" || W "$f: права $(stat -c %a "$DD/$f")" "chmod 600 $DD/$f"
done
[ -e "$DD/telegram.env" ] && { [ "$(stat -c %a "$DD/telegram.env")" = 600 ] && P "telegram.env: права 600" || W "telegram.env: права не 600" "chmod 600 $DD/telegram.env"; }
for f in /tmp/awg-src.tar.gz /tmp/awgx /tmp/awg-sim-down /tmp/rail.conf; do
  [ -e "$f" ] && W "остаток: $f" "rm -rf $f"
done
ls /run/*.awg.conf /run/*.raw >/dev/null 2>&1 && W "в /run остались временные конфиги с ключами" "rm -f /run/*.awg.conf /run/*.raw"
k=$(grep -E -c '[A-Za-z0-9+/]{43}=' /root/.bash_history 2>/dev/null)
[ "${k:-0}" = 0 ] && P "в .bash_history нет строк, похожих на ключи" || W ".bash_history: строк, похожих на ключи: $k" "history -c; : > /root/.bash_history"
if [ -f "$DD/.panel" ] || { [ -x "$DD/status.sh" ] && [ ! -f "$DD/.installer" ]; }; then
  grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null && P "панель при входе по SSH настроена" || W "status.sh есть, но в /root/.bashrc нет показа панели" "часть 8, шаг 8.2"
fi

sec "Итог"
echo "  ${G}OK: $ok${N}   ${Y}WARN: $warn${N}   ${R}FAIL: $bad${N}"
echo "  Скрипт ничего не меняет. Команды fix выполняйте по одной, прочитав вывод."
