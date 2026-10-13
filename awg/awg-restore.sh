#!/bin/bash
# awg-restore.sh: вернуть службы и удобства после обновления прошивки UniFi (она может очистить /etc и /root).
#   awg-restore.sh              восстановить всё
#   awg-restore.sh --if-needed  только если чего-то не хватает или сменилась прошивка (автозапуск из on_boot.d)
#   awg-restore.sh --fw-check   только если сменилась прошивка UniFi OS или версия Network (запускает сторож при старте)
# Смена прошивки (#9): версии запоминаются в $DD/.fwver; при смене — полное восстановление, самопроверка,
# событие «Прошивка» в журнале и сообщение в Telegram (если настроен).
D=${DD:-/data/awg}
SYSD=${SYSD:-/etc/systemd/system}
BASHRC=${BASHRC:-/root/.bashrc}
ALL="awg-failover awg-notify awg-motd awg-subnets awg-self awg-guard awg-bot awg-metrics awg-ha"
# что включено у пользователя: список ведёт установщик (/data/awg/.units); если его нет — всё, чьи файлы есть
if [ -s "$D/.units" ]; then UNITS=$(cat "$D/.units"); else UNITS=""; for u in $ALL; do [ -f "$D/$u.service" ] && UNITS="$UNITS $u"; done; fi
need=0
for u in $UNITS; do [ -f "$SYSD/$u.service" ] || need=1; done
grep -q AWGS_SHOWN $BASHRC 2>/dev/null || { [ -f "$D/.panel" ] && need=1; }
bk_auto(){ grep -qE '^BK_AUTO="?(daily|weekly)' "$D/backup.env" 2>/dev/null; }
bk_auto && [ ! -f "$SYSD/awg-backup.timer" ] && need=1

fw_now(){
  local os net pk v
  os=$(ubnt-device-info firmware 2>/dev/null | head -n1)
  for pk in unifi unifi-native unifi-network; do v=$(dpkg-query -W -f='${Version}' "$pk" 2>/dev/null) && [ -n "$v" ] && { net=$v; break; }; done
  echo "os=${os:-?} net=${net:-?}"
}
FWF=$D/.fwver; fw_changed=""; fw_cur=""
if [ "$1" = --if-needed ] || [ "$1" = --fw-check ]; then
  fw_cur=$(fw_now); fw_old=$(cat "$FWF" 2>/dev/null)
  if [ "$fw_cur" = "os=? net=?" ]; then :                         # не роутер или версии не читаются — ничего не решаем
  elif [ -z "$fw_old" ]; then echo "$fw_cur" > "$FWF"             # первый запуск: запомнить
  elif [ "$fw_cur" != "$fw_old" ]; then fw_changed="$fw_old → $fw_cur"; need=1; fi
fi
[ "$1" = --fw-check ] && [ -z "$fw_changed" ] && exit 0
if [ "$1" = --if-needed ] && [ $need = 0 ]; then exit 0; fi
[ -n "$fw_changed" ] && echo "сменилась прошивка: $fw_changed — восстанавливаю"

for u in $UNITS; do [ -f "$D/$u.service" ] && cp "$D/$u.service" "$SYSD/"; done
systemctl daemon-reload
for u in $UNITS; do [ -f "$D/$u.service" ] && systemctl enable --now "$u" >/dev/null 2>&1 && echo "служба $u восстановлена"; done
bk_auto && [ -x "$D/backup.sh" ] && SYSD=$SYSD "$D/backup.sh" timer
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
# команды без интерактивной оболочки (ssh роутер awgctl …): ссылки в /usr/local/bin, чужие файлы не трогаем
BD=${AWG_BINDIR:-/usr/local/bin}
if [ -d "$BD" ] && [ -w "$BD" ]; then
  for a in awgctl=awgctl.sh awg-selftest=selftest.sh awgs=status.sh; do
    l=$BD/${a%%=*}; { [ -L "$l" ] || ! [ -e "$l" ]; } && ln -sfn "$D/${a#*=}" "$l" 2>/dev/null
  done
fi
[ -f "$D/motd.orig" ] && [ -f "$D/awg-motd.service" ] && : > /etc/motd 2>/dev/null
if [ -n "$fw_changed" ]; then
  echo "$fw_cur" > "$FWF"
  sleep "${FW_SETTLE:-20}"      # дать сторожу поднять туннели и маршруты
  sum=$(timeout 180 "$D/selftest.sh" 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*m//g' | grep -E '^Итог' | tail -n1)
  sum=${sum#Итог: }
  echo "$(date +%s)|firmware|прошивка: ${fw_changed}; службы восстановлены; самопроверка: ${sum:-не выполнена}" >> "$D/events.log"
  if { [ -r "$D/telegram.env" ] || [ -r "$D/hooks.env" ]; } && [ -x "$D/notify.sh" ]; then
    "$D/notify.sh" --html "🔄 <b>Обновилась прошивка UniFi</b> · $(hostname)
$fw_changed
Службы UDR-Amnezia восстановлены. Самопроверка: ${sum:-не выполнена}" >/dev/null 2>&1
  fi
  echo "самопроверка после смены прошивки: ${sum:-не выполнена}"
fi
echo "готово; проверьте: awgctl selftest"
