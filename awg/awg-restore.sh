#!/bin/bash
# awg-restore.sh — вернуть автозапуск и панель после обновления прошивки
# (UniFi может очистить /etc/systemd/system и /root/.bashrc; /data при этом сохраняется).
D=/data/awg
cp "$D/awg-failover.service" /etc/systemd/system/
NOTIFY=0; MOTD=0
[ -f "$D/awg-notify.service" ] && [ -f "$D/telegram.env" ] && { NOTIFY=1; cp "$D/awg-notify.service" /etc/systemd/system/; }
[ -f "$D/awg-motd.service" ] && [ -f "$D/motd.orig" ] && { MOTD=1; cp "$D/awg-motd.service" /etc/systemd/system/; }
systemctl daemon-reload
systemctl enable --now awg-failover
[ $NOTIFY = 1 ] && systemctl enable --now awg-notify
[ $MOTD = 1 ] && systemctl enable --now awg-motd
# панель и команды возвращаются, только если соответствующая часть ставилась
# установщик отмечает выбранные компоненты файлами .panel/.audit; при ручной установке по гайду
# признак — наличие самих скриптов
want(){ [ -f "$D/.$1" ] || { [ -x "$D/$2" ] && [ ! -f "$D/.installer" ]; }; }
if want panel status.sh && ! grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null; then
  cat >> /root/.bashrc <<'RC'
alias awgs='/data/awg/status.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
fi
if want audit audit.sh && ! grep -q "alias awg-audit=" /root/.bashrc 2>/dev/null; then
  echo "alias awg-audit='/data/awg/audit.sh'" >> /root/.bashrc
fi
[ -f "$D/motd.orig" ] && touch /root/.hushlogin
[ -x "$D/install.sh" ] && ! grep -q "alias awg-setup=" /root/.bashrc 2>/dev/null && echo "alias awg-setup='/data/awg/install.sh'" >> /root/.bashrc
if [ -x "$D/audit.sh" ]; then echo "Готово. Проверьте: $D/audit.sh"; else echo "Готово. Проверьте: systemctl is-active awg-failover"; fi
