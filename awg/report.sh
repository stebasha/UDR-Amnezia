#!/bin/bash
# awg-report: обезличенный отчёт для issue на GitHub или для помощи со стороны.
#   report.sh            отчёт в /tmp/awg-report-ДАТА.txt (ключи, токены и публичные IP скрыты)
#   report.sh --stdout   вывести на экран
# Что попадает: версии (UniFi OS, Network, установщик, бинарники), awg.env (без секретов), конфиги туннелей
# без ключей, ip rule, таблица PBR, правила iptables с awg/AWG/UBIOS_PREROUTING_PBR, последние события и журналы,
# итог diagnose и selftest. Что не попадает: PrivateKey, PublicKey, PresharedKey, HeaderProtectionKey, токен Telegram,
# chat id; публичные IPv4 заменяются на «x.x.x.N» (последний октет оставлен для различения).
iptables(){ command iptables -w 10 "$@"; }
DD=${DD:-/data/awg}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
OUT=/tmp/awg-report-$(date +%Y%m%d-%H%M%S).txt
[ "$1" = --stdout ] && OUT=/dev/stdout

# скрыть секреты и публичные адреса
mask(){
  sed -E \
    -e 's/((PrivateKey|PublicKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1<скрыто>/I' \
    -e 's/(TG_TOKEN|TG_CHAT|AWG_BACKUP_PASS)=.*/\1=<скрыто>/' \
    -e 's#[A-Za-z0-9+/]{42,43}=#<ключ>#g' \
    -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{30,}/<токен>/g' \
  | awk '{
      line=$0; out=""
      while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        ip=substr(line, RSTART, RLENGTH); split(ip, o, ".")
        priv = (o[1]==10) || (o[1]==127) || (o[1]==0) || (o[1]==192 && o[2]==168) || (o[1]==172 && o[2]>=16 && o[2]<=31) \
               || (o[1]==100 && o[2]>=64 && o[2]<=127) || (o[1]==169 && o[2]==254) || (o[1]>=224) \
               || ip=="1.1.1.1" || ip=="8.8.8.8" || ip=="9.9.9.9" || (o[1]==192 && o[2]==0 && o[3]==2) \
               || (o[1]==198 && o[2]==51 && o[3]==100) || (o[1]==203 && o[2]==0 && o[3]==113)
        out = out substr(line, 1, RSTART-1) (priv ? ip : "x.x.x." o[4]); line = substr(line, RSTART+RLENGTH)
      }
      print out line }'
}
s(){ echo; echo "===== $* ====="; }

{
  echo "AmneziaWG report · $(date '+%F %T %Z')"
  s "Версии"
  echo "модель: $(ubnt-device-info model 2>/dev/null || echo ?)"
  echo "UniFi OS: $(ubnt-device-info firmware 2>/dev/null || echo ?)"
  echo "Network: $(for pk in unifi unifi-native unifi-network; do v=$(dpkg-query -W -f='${Version}' "$pk" 2>/dev/null) && [ -n "$v" ] && { echo "$v ($pk)"; break; }; done)"
  echo "ядро: $(uname -r) $(uname -m)"
  echo "набор: $(cat "$DD/VERSION" 2>/dev/null || echo ?), установщик: $(sed -n 's/^INSTALLER_VERSION=//p' "$DD/install.sh" 2>/dev/null | head -n1)"
  echo "awg: $("$DD/awg" --version 2>&1 | head -1)"
  echo "amneziawg-go: $("$DD/amneziawg-go" --version 2>&1 | head -1)"
  echo "iptables: $("$(type -P iptables)" --version 2>&1)"
  echo "аптайм: $(uptime -p 2>/dev/null)"
  s "awg.env"
  grep -v -E '^[[:space:]]*#' "$DD/awg.env" 2>/dev/null
  s "Конфиги туннелей (без ключей)"
  for f in "$DD"/main.conf "$DD"/backup.conf "$DD"/client.conf $(for t in ${TUNNELS_EXTRA:-}; do echo "$DD/$t.conf"; done); do
    [ -f "$f" ] || continue; echo "--- $(basename "$f") (права $(stat -c %a "$f"))"; cat "$f"
  done
  s "Службы"
  for u in awg-failover awg-subnets awg-self awg-guard awg-notify awg-bot awg-metrics awg-motd; do
    [ -f "/etc/systemd/system/$u.service" ] && echo "$u: $(systemctl is-active $u 2>/dev/null) / $(systemctl is-enabled $u 2>/dev/null)"
  done
  s "Состояние сторожа"; cat /run/awg-state 2>/dev/null
  s "Туннели"
  for t in ${MAIN:-awgmain} ${BACKUP:-} ${TUNNELS_EXTRA:-}; do "$DD/awg" show "$t" 2>&1 | grep -v -i 'private key' ; done
  ip -br link 2>/dev/null | grep -E '^(awg|wg)'
  s "ip rule"; ip -4 rule show
  s "Таблица PBR ${TABLE:-?}"; [ -n "$TABLE" ] && ip -4 route show table "$TABLE"
  s "iptables (относящиеся к AWG и PBR)"
  for tb in nat mangle filter; do echo "-- $tb"; iptables -t $tb -S 2>/dev/null | grep -E -- 'awg|AWG|UBIOS_PREROUTING_PBR|-P ' ; done
  echo "-- ip6tables filter"; command ip6tables -w 10 -S 2>/dev/null | grep -E -- 'AWG|-P '
  s "Наборы ipset AWG"; for x in AWG_UI AWG_DOM AWG_DOM6 AWG_DIRECT; do ipset list -t "$x" 2>/dev/null | grep -E 'Name|Header|Number of entries'; done
  s "События (последние 40)"; tail -n 40 "$DD/events.log" 2>/dev/null
  s "Журнал сторожа (последние 60)"; tail -n 60 "$DD/failover.log" 2>/dev/null
  s "journalctl awg-* (последние 60)"; journalctl -u 'awg-*' -n 60 --no-pager 2>/dev/null
  s "diagnose"; NO_COLOR=1 "$DD/diagnose.sh" 2>&1
  s "selftest"; NO_COLOR=1 "$DD/selftest.sh" 2>&1
} 2>&1 | mask > "$OUT"
[ "$OUT" = /dev/stdout ] && exit 0
chmod 600 "$OUT"
echo "отчёт: $OUT ($(wc -l < "$OUT") строк)"
echo "Ключи, токены и публичные адреса скрыты, но просмотрите файл перед публикацией: less $OUT"
echo "Скачать на компьютер: scp root@$(ip -4 -br addr show br0 2>/dev/null | awk '{print $3}' | cut -d/ -f1):$OUT ."
