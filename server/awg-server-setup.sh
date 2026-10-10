#!/bin/bash
# awg-server-setup.sh — сервер AmneziaWG на VPS (от root, после awg-server-build.sh).
# Создаёт ключи, параметры обфускации, /etc/amnezia/server.conf, конфиг клиента для роутера
# и службу awg-server (автозапуск, NAT, ip_forward).
#   VPS_IP=203.0.113.10 ./awg-server-setup.sh
# Необязательно: PORT=51823 SUBNET=10.0.1 MTU=1380
#   OBF_FILE=/root/obf.txt — взять Jc/Jmin/Jmax/S1/S2/H1-H4 из файла (например, из конфига,
#   который точно проходит через вашего провайдера); иначе параметры генерируются случайно.
set -e
PORT=${PORT:-51823}
SUBNET=${SUBNET:-10.0.1}
MTU=${MTU:-1380}
ETC=/etc/amnezia
OUT=/root/awgbuild
[ -d /data/unifi-core ] && { echo "Это роутер UniFi. Скрипт запускается на VPS."; exit 1; }
command -v awg >/dev/null && command -v amneziawg-go >/dev/null || { echo "Сначала awg-server-build.sh"; exit 1; }
umask 077; mkdir -p $ETC $OUT

if [ -e $ETC/server.conf ]; then
  echo "$ETC/server.conf уже есть: ключи не трогаю, переустанавливаю только автозапуск."
else
  VPS_IP=${VPS_IP:?задайте внешний IP сервера: VPS_IP=203.0.113.10 $0}
  if ss -ulpn | grep -q ":$PORT "; then echo "UDP-порт $PORT занят, выберите другой: PORT=... $0"; exit 1; fi
  if [ -n "$OBF_FILE" ]; then
    OBF=$(grep -E '^[[:space:]]*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=' "$OBF_FILE" | sed 's/^[[:space:]]*//')
    [ "$(echo "$OBF" | wc -l)" = 9 ] || { echo "В $OBF_FILE нужно ровно 9 строк Jc..H4"; exit 1; }
  else
    rnd(){ shuf -i "$1"-"$2" -n 1; }
    JC=$(rnd 4 8); JMIN=$(rnd 40 80); JMAX=$((JMIN + $(rnd 60 200)))
    S1=$(rnd 15 150); S2=$(rnd 15 150)
    while [ $((S1+56)) -eq $S2 ] || [ $S1 -eq $S2 ]; do S2=$(rnd 15 150); done
    mapfile -t HH < <(shuf -i 5-2147483647 -n 4)
    OBF=$(printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s' \
      $JC $JMIN $JMAX $S1 $S2 ${HH[0]} ${HH[1]} ${HH[2]} ${HH[3]})
  fi
  SK=$(awg genkey); SP=$(echo "$SK" | awg pubkey)
  CK=$(awg genkey); CP=$(echo "$CK" | awg pubkey)
  cat > $ETC/server.conf <<CONF
[Interface]
PrivateKey = $SK
ListenPort = $PORT
$OBF

[Peer]
PublicKey = $CP
AllowedIPs = $SUBNET.2/32
CONF
  cat > $OUT/client.conf <<CONF
[Interface]
PrivateKey = $CK
Address = $SUBNET.2/32
MTU = $MTU
$OBF

[Peer]
PublicKey = $SP
AllowedIPs = 0.0.0.0/0
Endpoint = $VPS_IP:$PORT
PersistentKeepalive = 25
CONF
  chmod 600 $ETC/server.conf $OUT/client.conf
  echo "Созданы $ETC/server.conf и $OUT/client.conf"
fi

cat > /usr/local/bin/awg-up.sh <<UP
#!/bin/bash
ip link show awg0 >/dev/null 2>&1 && exit 0
amneziawg-go awg0
for k in 1 2 3 4 5 6 7 8 9 10; do ip link show awg0 >/dev/null 2>&1 && break; sleep 0.3; done
awg setconf awg0 $ETC/server.conf
ip addr add $SUBNET.1/24 dev awg0
ip link set awg0 up mtu $MTU
IFACE=\$(ip -4 route show default | awk '{print \$5; exit}')
iptables -t nat -C POSTROUTING -s $SUBNET.0/24 -o \$IFACE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $SUBNET.0/24 -o \$IFACE -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o awg0 -j ACCEPT
UP
chmod 755 /usr/local/bin/awg-up.sh

cat > /etc/systemd/system/awg-server.service <<'UNIT'
[Unit]
Description=AmneziaWG server awg0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/awg-up.sh
ExecStop=/sbin/ip link del awg0

[Install]
WantedBy=multi-user.target
UNIT

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf
sysctl -q -p /etc/sysctl.d/99-awg.conf
P=$(awk -F'=' '/^ListenPort/{gsub(/ /,"",$2); print $2}' $ETC/server.conf)
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "$P/udp"; fi
systemctl daemon-reload
ip link show awg0 >/dev/null 2>&1 && ip link del awg0
systemctl enable --now awg-server
echo
awg show awg0 | head -4 || true
ss -ulpn | grep ":$P " || echo "ВНИМАНИЕ: UDP $P пока не слушается: journalctl -u awg-server -n 20"
echo
echo "Конфиг для роутера: $OUT/client.conf (перенесите на роутер как /data/awg/backup.conf или main.conf)"
echo "Не забудьте открыть UDP $P в файрволе хостера, если он есть."
