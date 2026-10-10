#!/bin/bash
# awg-uninstall.sh — полностью убрать установку с роутера.
#   awg-uninstall.sh          остановить и убрать службы, маршруты, правила, интерфейсы
#   awg-uninstall.sh --purge  то же + удалить /data/awg (конфиги с ключами тоже!)
D=/data/awg
[ -r $D/awg.env ] && . $D/awg.env
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}
for u in awg-notify awg-failover awg-motd; do
  systemctl disable --now $u 2>/dev/null
  rm -f /etc/systemd/system/$u.service
done
systemctl daemon-reload
pkill -f "$D/failover[.]sh" 2>/dev/null
[ -x $D/failover.sh ] && $D/failover.sh cleanup 2>/dev/null
for i in $MAIN $BACKUP; do
  while iptables -t nat -D POSTROUTING -o $i -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -o $i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -i $i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
  while iptables -D FORWARD -o $i -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i $i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
  ip link del $i 2>/dev/null
done
for s in $EXTRA_SUBNETS; do ipset del UBIOS4local_network $s 2>/dev/null; done
sed -i '/AWGS_SHOWN/d;/alias awgs=/d;/alias awg-audit=/d;/alias awg-setup=/d' /root/.bashrc 2>/dev/null
rm -f /root/.hushlogin
[ -f $D/motd.orig ] && cp -a $D/motd.orig /etc/motd
if [ "$1" = --purge ]; then rm -rf $D; echo "Удалено всё, включая $D"; else echo "Службы и правила убраны. Файлы остались в $D (полностью: $0 --purge)"; fi
echo "Профиль VPN Client и правила Policy-Based Routes удалите в интерфейсе UniFi сами, если они больше не нужны."
