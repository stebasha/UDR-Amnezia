#!/bin/bash
# audit-server.sh — проверка VPS с сервером AmneziaWG. Только чтение.
[ -d /data/unifi-core ] && { echo "Это роутер UniFi: запускайте на VPS"; exit 1; }
ok=0; warn=0; bad=0
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
P(){ echo "  ${G}OK${N}    $1"; ok=$((ok+1)); }
W(){ echo "  ${Y}WARN${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; warn=$((warn+1)); }
F(){ echo "  ${R}FAIL${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; bad=$((bad+1)); }
sec(){ echo; echo "${B}== $1 ==${N}"; }
CONF=/etc/amnezia/server.conf
PORT=$(awk -F'=' '/^ListenPort/{gsub(/ /,"",$2); print $2}' $CONF 2>/dev/null)

sec "AmneziaWG (awg0)"
ip link show awg0 >/dev/null 2>&1 && P "awg0 поднят" || F "awg0 отсутствует" "systemctl restart awg-server; journalctl -u awg-server -n 20"
en=$(systemctl is-enabled awg-server 2>/dev/null)
[ "$en" = enabled ] && P "awg-server: автозапуск включён" || F "awg-server: ${en:-не найден}" "awg-server-setup.sh"
c=$(pgrep -c amneziawg-go 2>/dev/null); [ "${c:-0}" = 1 ] && P "процессов amneziawg-go: 1" || W "процессов amneziawg-go: ${c:-0} (нужен 1)" "pgrep -a amneziawg-go"
if ip link show awg0 >/dev/null 2>&1; then
  np=$(awg show awg0 peers 2>/dev/null | wc -l); [ "$np" -ge 1 ] && P "peer на awg0: $np" || W "на awg0 нет peer" "awg show awg0"
  ts=$(awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -n "$ts" ] && [ "$ts" != 0 ]; then P "handshake роутера: $(( $(date +%s) - ts ))с назад"; else W "handshake с роутера не было" "проверьте туннель на роутере"; fi
fi
[ "$(stat -c %a $CONF 2>/dev/null)" = 600 ] && P "$CONF: права 600" || W "$CONF: нет файла или права не 600" "chmod 600 $CONF"
[ -n "$PORT" ] && { ss -ulpn 2>/dev/null | grep ":$PORT " | grep -q amneziawg-go && P "UDP $PORT слушает amneziawg-go" || F "UDP $PORT не слушается amneziawg-go" "ss -ulpn | grep :$PORT"; }

sec "Маршрутизация и NAT"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && P "ip_forward = 1" || F "ip_forward не 1" "sysctl -w net.ipv4.ip_forward=1"
ls /etc/sysctl.d/*awg* /etc/sysctl.d/*wg* >/dev/null 2>&1 && P "ip_forward закреплён в /etc/sysctl.d" || W "ip_forward не закреплён" "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf"
SUB=$(ip -4 -br addr show awg0 2>/dev/null | awk '{print $3}' | cut -d. -f1-3)
if [ -n "$SUB" ]; then
  c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-s $SUB.0/24")
  [ "$c" = 1 ] && P "NAT для $SUB.0/24: 1 правило" || W "NAT для $SUB.0/24: $c (нужно 1)" "iptables -t nat -S POSTROUTING"
fi
c=$(iptables -S FORWARD 2>/dev/null | grep -c -E -- '(-i|-o) awg0 -j ACCEPT')
[ "$c" = 2 ] && P "FORWARD для awg0: 2 правила" || W "FORWARD для awg0: $c (нужно 2)" "iptables -S FORWARD | grep awg0"

sec "Файрвол"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw status | grep -q "^$PORT/udp" && P "ufw: $PORT/udp открыт" || F "ufw: $PORT/udp не открыт" "ufw allow $PORT/udp"
else
  echo "        ufw не активен: его правила не применяются"
fi
echo "        Файрвол в панели хостера скрипт не видит: UDP $PORT должен быть открыт и там."

sec "Файлы с ключами"
for f in /root/awgbuild/client.conf /root/awgbuild/server.conf; do
  [ -e "$f" ] && W "остаток: $f (после переноса на роутер не нужен)" "shred -u $f"
done
k=$(grep -E -c '[A-Za-z0-9+/]{43}=' /root/.bash_history 2>/dev/null)
[ "${k:-0}" = 0 ] && P "в .bash_history нет строк, похожих на ключи" || W ".bash_history: строк, похожих на ключи: $k" "history -c; : > /root/.bash_history"

sec "Итог"
echo "  ${G}OK: $ok${N}   ${Y}WARN: $warn${N}   ${R}FAIL: $bad${N}"
echo "  Скрипт ничего не меняет."
