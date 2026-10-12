#!/bin/bash
# awg-uninstall.sh — полностью убрать установку с роутера.
#   awg-uninstall.sh          остановить и убрать службы, маршруты, правила, интерфейсы
#   awg-uninstall.sh --purge  то же + удалить /data/awg (конфиги с ключами тоже!)
# Профиль VPN Client («рельсу») и правила Policy-Based Routes в UniFi скрипт не трогает: их удаляют в интерфейсе.
iptables(){ command iptables -w 10 "$@"; }
ip6tables(){ command ip6tables -w 10 "$@"; }
D=${DD:-/data/awg}
SYSD=${SYSD:-/etc/systemd/system}
BOOT_D=${BOOT_D:-/data/on_boot.d}
BASHRC=${BASHRC:-/root/.bashrc}
[ -r "$D/awg.env" ] && . "$D/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}

# 1. службы — сначала остановить: иначе их 5-секундный цикл вернёт правила, пока мы их убираем
for u in awg-web awg-bot awg-metrics awg-guard awg-self awg-subnets awg-notify awg-failover awg-motd; do
  [ -f "$SYSD/$u.service" ] || systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "^$u" || continue
  systemctl disable --now "$u" >/dev/null 2>&1; rm -f "$SYSD/$u.service"; echo "служба $u удалена"
done
systemctl daemon-reload 2>/dev/null
pkill -f "$D/(failover|self|guard|subnets|bot|metrics|awg-notify)[.]sh" 2>/dev/null

# 2. модули со своими правилами (цепочки AWG_*, ip rule подсетей, файл dnsmasq), маршруты и blackhole в таблице PBR
for s in guard self subnets; do [ -x "$D/$s.sh" ] && "$D/$s.sh" remove >/dev/null 2>&1; done
[ -x "$D/failover.sh" ] && "$D/failover.sh" cleanup all >/dev/null 2>&1

# 3. все правила iptables, где участвует интерфейс awg* (NAT, MSS, FORWARD), все копии
for t in nat:POSTROUTING mangle:FORWARD mangle:POSTROUTING mangle:PREROUTING filter:FORWARD; do
  tb=${t%%:*}; ch=${t#*:}
  iptables -t "$tb" -S "$ch" 2>/dev/null | grep -E -- '-[io] awg[a-z0-9]*( |$)' | sed 's/^-A/-D/' | while read -r r; do
    # shellcheck disable=SC2086
    iptables -t "$tb" $r 2>/dev/null
  done
done
for s in AWG_UI AWG_DOM AWG_DIRECT; do ipset destroy "$s" 2>/dev/null; done
# подсети, которые старые версии добавляли в набор локальных сетей UniFi
for s in $EXTRA_SUBNETS; do ipset del UBIOS4local_network "$s" 2>/dev/null; done

# 4. туннели
for i in $(ip -br link 2>/dev/null | awk '$1 ~ /^awg/ {sub(/@.*/,"",$1); print $1}'); do ip link del "$i" 2>/dev/null && echo "туннель $i удалён"; done
pkill -x amneziawg-go 2>/dev/null

# 5. правило PBR, которое добавил сам сторож (метка proto 99; правило UniFi не трогаем)
ip -4 rule show 2>/dev/null | awk '/ proto 99/ {sub(":","",$1); print $1}' | while read -r p; do ip -4 rule del priority "$p" proto 99 2>/dev/null; done
# ip rule подсетей VPN-сервера (если subnets.sh уже нет)
for p in 6100 6101; do for _ in 1 2 3 4 5 6 7 8; do ip rule del priority $p 2>/dev/null || break; done; done

# 6. панель, команды, баннер, автовосстановление
if [ -f $BASHRC ]; then
  sed -i -e '/AWGS_SHOWN/d' -e '/alias awgs=/d' -e '/alias awg-audit=/d' -e '/alias awgctl=/d' -e '/alias awg-selftest=/d' -e '/alias awg-setup=/d' $BASHRC
fi
rm -f /root/.hushlogin "$BOOT_D/10-awg-restore.sh"
[ -f "$D/motd.orig" ] && cp -a "$D/motd.orig" /etc/motd
rm -f /tmp/awg-sim-down /run/awg-force /run/awg-state /run/awg-*.lock /tmp/awg-self.* /tmp/awg-guard.hash 2>/dev/null

if [ "$1" = --purge ]; then rm -rf "$D"; echo "Удалено всё, включая $D"; else echo "Службы и правила убраны. Файлы остались в $D (полностью: $0 --purge)"; fi
echo "Профиль VPN Client и правила Policy-Based Routes удалите в интерфейсе UniFi сами, если они больше не нужны."
