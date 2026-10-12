#!/bin/bash
# awg-restore.sh: вернуть службы и удобства после обновления прошивки UniFi (она может очистить /etc и /root).
#   awg-restore.sh              восстановить всё
#   awg-restore.sh --if-needed  только если чего-то не хватает (для автозапуска из on_boot.d)
D=${DD:-/data/awg}
SYSD=${SYSD:-/etc/systemd/system}
BASHRC=${BASHRC:-/root/.bashrc}
ALL="awg-failover awg-notify awg-motd awg-subnets awg-self awg-guard awg-bot awg-metrics"
# что включено у пользователя: список ведёт установщик (/data/awg/.units); если его нет — всё, чьи файлы есть
if [ -s "$D/.units" ]; then UNITS=$(cat "$D/.units"); else UNITS=""; for u in $ALL; do [ -f "$D/$u.service" ] && UNITS="$UNITS $u"; done; fi
need=0
for u in $UNITS; do [ -f "$SYSD/$u.service" ] || need=1; done
grep -q AWGS_SHOWN $BASHRC 2>/dev/null || { [ -f "$D/.panel" ] && need=1; }
if [ "$1" = --if-needed ] && [ $need = 0 ]; then exit 0; fi

for u in $UNITS; do [ -f "$D/$u.service" ] && cp "$D/$u.service" "$SYSD/"; done
systemctl daemon-reload
for u in $UNITS; do [ -f "$D/$u.service" ] && systemctl enable --now "$u" >/dev/null 2>&1 && echo "служба $u восстановлена"; done
if ! grep -q AWGS_SHOWN $BASHRC 2>/dev/null; then
  cat >> $BASHRC <<'RC'
alias awgs='/data/awg/status.sh'
alias awg-audit='/data/awg/audit.sh'
alias awgctl='/data/awg/awgctl.sh'
alias awg-selftest='/data/awg/selftest.sh'
alias awg-setup='/data/awg/install.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
fi
for a in awgctl awg-selftest awg-setup; do grep -q "alias $a=" $BASHRC 2>/dev/null || case $a in
  awgctl) echo "alias awgctl='/data/awg/awgctl.sh'" >> $BASHRC;;
  awg-selftest) echo "alias awg-selftest='/data/awg/selftest.sh'" >> $BASHRC;;
  awg-setup) echo "alias awg-setup='/data/awg/install.sh'" >> $BASHRC;;
esac; done
[ -f "$D/motd.orig" ] && [ -f "$D/awg-motd.service" ] && : > /etc/motd 2>/dev/null
echo "готово; проверьте: awgctl selftest"
