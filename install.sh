#!/bin/bash
# ============================================================================
#  AmneziaWG для UniFi Dream Router 7 — установщик и мастер настройки
#
#  Первый запуск на роутере (SSH, root):
#    bash <(curl -fsSL https://raw.githubusercontent.com/stebasha/UDR-Amnezia/main/install.sh)
#  или из клона репозитория:   bash install.sh
#  Повторно (меню обслуживания): /data/awg/install.sh
#
#  Ключи: --update          обновить скрипты из репозитория (конфиги сохраняются; при сбое — автоматический откат)
#         --web             включить или перенастроить веб-панель управления
#         --restore         вернуть службы после обновления прошивки
#         --status          панель состояния
#         --selftest [--full]  самопроверка (--full: ещё и проверка переключения и kill switch)
#         --dry-run         показать, что есть на роутере и что сделает мастер (ничего не меняет)
#         --verify          сверить файлы установки с манифестом
#         --self-update     обновить сам install.sh (проверка sha256)
#         --bins-check      сравнить amneziawg-go и awg с последними официальными релизами amnezia-vpn
#         --bins-update [ПАПКА]   обновить их: сборка на своём VPS или готовые файлы с SHA256SUMS; без handshake — откат
#         --channel stable|beta|ВЕТКА   сменить канал обновлений и обновиться: stable — релизы (по умолчанию),
#                           beta — ветка main, ВЕТКА — своя ветка (можно вместе с --update)
#         --record ФАЙЛ     записать ответы мастера (секреты и конфиги не записываются)
#         --answers ФАЙЛ    повторить мастер по записанным ответам
#         --rotate-keys [туннель]   сменить ключи туннеля до своего VPS
#         --harden-vps      защита своего VPS (обновления, fail2ban, вход по ключам)
#         --uninstall       удалить
#         --help
# ============================================================================
INSTALLER_VERSION=1.6.1
# Канал обновлений (#8), запоминается в $DD/.channel (install.sh --update и панель обновляются оттуда же):
#   stable — последний релиз GitHub: архив с SHA256SUMS, сумма проверяется (по умолчанию);
#   beta   — ветка main (то, что уже влито, но ещё не выпущено релизом);
#   branch — своя ветка AWG_BRANCH (для проверки изменений до слияния).
# Явные AWG_CHANNEL / AWG_BRANCH в окружении важнее файла; AWG_BRANCH=main без AWG_CHANNEL — это beta.
_ch_f="${DD:-/data/awg}/.channel"; _ch_repo=""; _ch_chan=""; _ch_br=""
if [ -r "$_ch_f" ]; then
  _ch_repo=$(sed -n 's/^AWG_REPO=//p' "$_ch_f" | head -n1)
  _ch_chan=$(sed -n 's/^AWG_CHANNEL=//p' "$_ch_f" | head -n1)
  _ch_br=$(sed -n 's/^AWG_BRANCH=//p' "$_ch_f" | head -n1)
fi
AWG_REPO=${AWG_REPO:-${_ch_repo:-stebasha/UDR-Amnezia}}      # GitHub: владелец/репозиторий со скриптами (awg/, server/)
if [ -n "${AWG_CHANNEL:-}" ]; then :
elif [ -n "${AWG_BRANCH:-}" ]; then [ "$AWG_BRANCH" = main ] && AWG_CHANNEL=beta || AWG_CHANNEL=branch
elif [ -n "$_ch_chan" ]; then AWG_CHANNEL=$_ch_chan
elif [ -n "$_ch_br" ] && [ "$_ch_br" != main ]; then AWG_CHANNEL=branch      # .channel до 1.5: своя ветка
else AWG_CHANNEL=stable; fi
case "$AWG_CHANNEL" in stable|beta|branch) ;; *) AWG_CHANNEL=stable;; esac
AWG_BRANCH=${AWG_BRANCH:-${_ch_br:-main}}
[ "$AWG_CHANNEL" = beta ] || [ "$AWG_CHANNEL" = stable ] && AWG_BRANCH=main   # ветка нужна только каналу branch (#35)
AWG_REF=${AWG_REF:-}; AWG_REF_KIND=${AWG_REF_KIND:-}   # тег релиза или ветка: вычисляет resolve_ref
# Бинарники AmneziaWG собираются только из официальных исходников AmneziaVPN (теги можно поменять здесь):
#   https://github.com/amnezia-vpn/amneziawg-go  и  https://github.com/amnezia-vpn/amneziawg-tools
AWG_GO_REF=${AWG_GO_REF:-v3.1.20260828}
AWG_TOOLS_REF=${AWG_TOOLS_REF:-v3.1.20260812}
DD=${DD:-/data/awg}
SYSD=${SYSD:-/etc/systemd/system}
BOOT_D=${BOOT_D:-/data/on_boot.d}
BASHRC=${BASHRC:-/root/.bashrc}
WORK=${WORK:-/tmp/awg-install}
ILOG=$DD/install.log
MAIN=awgmain
BACKUP_NAME=awgbackup
RECORD_FILE=""; ANS_FILE=""
# iptables всегда с ожиданием блокировки xtables: без -w iptables 1.8.7 (legacy) при занятой блокировке сразу падает,
# и проверка «есть ли правило» ошибочно отвечает «нет» → дубликаты правил.
iptables(){ command iptables -w 10 "$@"; }
ip6tables(){ command ip6tables -w 10 "$@"; }

# ---------------------------------------------------------------- вывод ----
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else G='' R='' Y='' C='' B='' D='' N=''; fi
say(){ printf '%s\n' "$*"; }
ilog(){ [ -d "$DD" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ILOG" 2>/dev/null; return 0; }
ok(){ say "  ${G}✔${N} $*"; ilog "OK   $*"; }
warn(){ say "  ${Y}▲${N} $*"; ilog "WARN $*"; }
err(){ say "  ${R}✖${N} $*"; ilog "ERR  $*"; }
info(){ say "  ${D}·${N} $*"; }
hint(){ say "    ${D}$*${N}"; }
title(){ say; say "${B}${C}━━ $* ${N}"; ilog "==== $*"; }
die(){ err "$*"; exit 1; }


# ---------------------------------------------------------------- ввод -----
# Ввод идёт через дескриптор 3: терминал, либо файл ответов (--answers). --record пишет ответы в файл.
# Секреты в запись не попадают: вместо них строка «#secret» (при повторе значение берётся из переменной AWG_SECRET),
# вставленные конфиги — «#paste» (при повторе берётся файл из AWG_CONF_FILE).
TTY_IN=${AWG_TTY:-/dev/tty}
open_tty(){
  if [ "${AWG_YES:-}" = 1 ]; then     # без терминала (обновление из панели): любой вопрос прерывает работу
    exec 3</dev/null
  elif [ -n "$ANS_FILE" ]; then
    [ -r "$ANS_FILE" ] || { echo "Нет файла ответов: $ANS_FILE"; exit 1; }
    exec 3<"$ANS_FILE"
  else
    { exec 3<"$TTY_IN"; } 2>/dev/null || { echo "Нужен интерактивный терминал: запустите установщик в SSH-сессии."; exit 1; }
  fi
  [ -n "$RECORD_FILE" ] && ( umask 077; : > "$RECORD_FILE" )
  return 0
}
rec(){ [ -n "$RECORD_FILE" ] && printf '%s\n' "$1" >> "$RECORD_FILE"; return 0; }
rd(){ local __rd_l; IFS= read -r -u 3 __rd_l || return 1; rec "$__rd_l"; printf -v "$1" '%s' "$__rd_l"; }
ask(){   # ask ПЕРЕМЕННАЯ "вопрос" [по умолчанию]
  local __ask_v=$1 __ask_p=$2 __ask_d=$3 __ask_a
  printf '%s' "  ${B}?${N} $__ask_p${__ask_d:+ ${D}[$__ask_d]${N}}: "
  rd __ask_a || { say; die "Ввод закрыт, установка прервана."; }
  __ask_a=${__ask_a%$'\r'}; __ask_a=${__ask_a#"${__ask_a%%[![:space:]]*}"}; __ask_a=${__ask_a%"${__ask_a##*[![:space:]]}"}
  [ -z "$__ask_a" ] && __ask_a=$__ask_d
  [ -n "$ANS_FILE" ] && say "$__ask_a"
  printf -v "$__ask_v" '%s' "$__ask_a"
}
yn(){    # yn "вопрос" [Y|N] → 0 да, 1 нет
  local a d=${2:-Y} h
  if [ "$d" = Y ]; then h="Да/нет"; else h="да/Нет"; fi
  while :; do
    ask a "$1 ($h)" ""
    [ -z "$a" ] && { [ "$d" = Y ]; return; }
    case "$a" in y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0;; n|N|no|No|NO|н|Н|нет|Нет|НЕТ) return 1;; esac
    warn "Ответьте «да» или «нет» (Enter — вариант по умолчанию)."
  done
}
choose(){  # choose ПЕРЕМЕННАЯ "заголовок" "вариант" ... → номер варианта
  local __ch_v=$1 __ch_t=$2 __ch_i=1 __ch_a __ch_o; shift 2
  say; say "  ${B}$__ch_t${N}"
  for __ch_o in "$@"; do say "    ${C}$__ch_i)${N} $__ch_o"; __ch_i=$((__ch_i+1)); done
  while :; do
    ask __ch_a "Номер" "1"
    if [[ "$__ch_a" =~ ^[0-9]+$ ]] && [ "$__ch_a" -ge 1 ] && [ "$__ch_a" -le $# ]; then printf -v "$__ch_v" '%s' "$__ch_a"; return 0; fi
    warn "Введите число от 1 до $#."
  done
}
pause(){ local _; ask _ "${1:-Нажмите Enter, чтобы продолжить}" ""; }
read_secret(){ # read_secret ПЕРЕМЕННАЯ "вопрос" — без эха
  local __rs_v=$1 __rs_a
  printf '%s' "  ${B}?${N} $2: "
  if [ -n "$ANS_FILE" ]; then
    IFS= read -r -u 3 __rs_a || { say; die "Ввод закрыт."; }
    if [ "$__rs_a" = "#secret" ]; then [ -n "$AWG_SECRET" ] || die "в файле ответов секрет, а переменная AWG_SECRET пуста"; __rs_a=$AWG_SECRET; fi
    say "(скрыто)"
  else
    IFS= read -rs -u 3 __rs_a || { say; die "Ввод закрыт."; }
    say; rec "#secret"
  fi
  printf -v "$__rs_v" '%s' "${__rs_a%$'\r'}"
}
read_paste(){ # read_paste ФАЙЛ — многострочный ввод до строки END или Ctrl+D
  local f=$1 l
  ( umask 077; : > "$f" )
  [ -n "$ANS_FILE" ] || say "    ${D}Вставьте текст целиком. Затем на новой строке напишите ${N}${B}END${N}${D} и нажмите Enter (или Ctrl+D).${N}"
  while IFS= read -r -u 3 l; do
    l=${l%$'\r'}
    [ "$l" = END ] && break
    if [ -n "$ANS_FILE" ] && [ "$l" = "#paste" ]; then
      [ -r "$AWG_CONF_FILE" ] || die "в файле ответов «#paste», а AWG_CONF_FILE не указывает на файл"
      tr -d '\r' < "$AWG_CONF_FILE" >> "$f"; continue
    fi
    printf '%s\n' "$l" >> "$f"
  done
  [ -n "$RECORD_FILE" ] && printf '#paste\nEND\n' >> "$RECORD_FILE"
  return 0
}


# ---------------------------------------------------------------- утилиты --
is_ipv4(){ local -a o; local x; [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; IFS=. read -r -a o <<< "$1"; for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done; }
conf_get(){ awk -v k="$2" 'BEGIN{k=tolower(k)} { line=$0; sub(/\r$/,"",line); split(line,a,"="); key=a[1]; gsub(/[ \t]/,"",key) } tolower(key)==k { sub(/^[^=]*=[ \t]*/,"",line); print line; exit }' "$1"; }
resolve(){
  is_ipv4 "$1" && { echo "$1"; return; }
  local r; r=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}')
  [ -z "$r" ] && command -v python3 >/dev/null && r=$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$1" 2>/dev/null)
  echo "$r"
}
env_set(){  # env_set КЛЮЧ ЗНАЧЕНИЕ  в awg.env
  local k=$1 v=$2 f=$DD/awg.env
  mkdir -p "$DD"; [ -f "$f" ] || ( umask 077; : > "$f" )
  if grep -q "^$k=" "$f"; then
    awk -v k="$k" -v v="$v" 'index($0, k"=")==1 {print k"="v; next} {print}' "$f" > "$f.t" && mv "$f.t" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
  chmod 600 "$f"
}
env_get(){ [ -r "$DD/awg.env" ] && ( . "$DD/awg.env" 2>/dev/null; eval "printf '%s' \"\${$1}\"" ); }
hs_age(){ local ts; ts=$("$DD/awg" show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
tun_ip(){ local ip u; for u in https://ifconfig.me https://api.ipify.org; do ip=$(curl -4 -s -m 8 --interface "$1" "$u" 2>/dev/null); is_ipv4 "$ip" && { echo "$ip"; return 0; }; done; return 1; }
lan_ip(){ local i; i=$(ip -4 -br addr show br0 2>/dev/null | awk '{print $3}' | cut -d/ -f1); echo "${i:-IP_РОУТЕРА}"; }
wan_if(){ local w; w=$(env_get WANIF); [ -z "$w" ] && w=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'); case "$w" in ""|awg*|wg*) w=eth3;; esac; echo "$w"; }
svc_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }

cleanup_on_exit(){
  [ -n "$SIM_SET" ] && rm -f /tmp/awg-sim-down
  [ -n "$VPS_IP" ] && ssh -O exit -o "ControlPath=/tmp/awg-ssh-%r@%h:%p" -p "${VPS_SSHPORT:-22}" "${VPS_USER:-root}@$VPS_IP" >/dev/null 2>&1
  rm -rf "$WORK" 2>/dev/null
}
on_int(){
  say; warn "Прервано пользователем."
  info "Уже сделанное остаётся на месте. Повторный запуск продолжит с нужного шага: $DD/install.sh"
  info "Полное удаление: $DD/install.sh --uninstall"
  exit 130
}
trap cleanup_on_exit EXIT
trap on_int INT

# ============================================================ проверки =====
need_root(){ [ "$(id -u)" = 0 ] || die "Запустите под root (на UDR7 вы и так root после ssh root@…)."; }

preflight(){
  title "Проверка роутера"
  need_root
  local arch model fw net dfree c miss=()
  arch=$(uname -m)
  [ "$arch" = aarch64 ] && ok "архитектура $arch" || die "архитектура $arch: бинарники собраны под aarch64 (UDR7). На этом устройстве установка невозможна."
  if [ -d /data/unifi-core ] || [ -d /data/unifi ]; then ok "UniFi OS обнаружена"; else
    warn "Это не похоже на консоль UniFi (нет /data/unifi-core)."
    yn "Всё равно продолжить?" N || exit 1
  fi
  model=$(ubnt-device-info model 2>/dev/null || awk -F= '/^shortname=|^name=/{print $2; exit}' /proc/ubnthal/system.info 2>/dev/null)
  fw=$(ubnt-device-info firmware 2>/dev/null)
  net=$(dpkg-query -W -f='${Version}' unifi 2>/dev/null)
  info "модель: ${model:-?} · UniFi OS: ${fw:-?} · Network: ${net:-?} (проверено на UDR7, UniFi OS 5.1.33, Network 10.6.106)"
  if [ -n "$model" ] && ! echo "$model" | grep -qiE 'udr7|dream router 7|UDR'; then
    warn "Гайд проверялся на UDR7. На других консолях UniFi может работать, но не проверено."
    yn "Продолжить?" Y || exit 1
  fi
  if [ -c /dev/net/tun ]; then ok "/dev/net/tun есть"; else
    warn "/dev/net/tun нет, пробую загрузить модуль tun"
    modprobe tun 2>/dev/null; mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
    [ -c /dev/net/tun ] && ok "/dev/net/tun создан" || die "без /dev/net/tun userspace-туннель не создать."
  fi
  for c in curl ip iptables ipset awk sed tar systemctl sha256sum timeout; do command -v "$c" >/dev/null || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] && ok "нужные команды на месте" || die "нет команд: ${miss[*]}. Это нестандартная прошивка."
  for c in tcpdump python3 ssh scp; do command -v "$c" >/dev/null || warn "нет $c: часть диагностики и настройка VPS по SSH будут недоступны"; done
  mkdir -p "$DD" && chmod 700 "$DD"
  dfree=$(df -Pm /data 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$dfree" ] && [ "$dfree" -lt 50 ]; then die "на /data свободно ${dfree} МБ, нужно хотя бы 50."; fi
  ok "место на /data: ${dfree:-?} МБ свободно"
  if curl -fsS -m 10 -o /dev/null https://github.com 2>/dev/null; then ok "доступ к github.com есть"; else
    warn "github.com недоступен с роутера. Скачивание скриптов и бинарников не получится."
    hint "Проверьте интернет на WAN и DNS роутера. Можно положить файлы вручную: скрипты в папку рядом с install.sh, бинарники в /data/awg."
  fi
  if svc_active ntp 2>/dev/null || [ "$(date +%Y)" -ge 2025 ]; then :; else warn "часы роутера показывают $(date): handshake может не пройти, проверьте время"; fi
  legacy_check
}

legacy_check(){
  local found=0
  # остатки от экспериментов и чужих установщиков
  if [ -d /data/awg-native ]; then
    found=1; warn "найдены остатки установщика AmneziaWG-Unifi-DreamMachine (/data/awg-native). Он патчит веб-интерфейс UniFi и с этим гайдом не нужен."
    if yn "Удалить его штатным деинсталлятором?" Y; then sh /data/awg-native/uninstall.sh --purge && ok "удалено" || err "деинсталлятор завершился с ошибкой, удалите вручную"; fi
  fi
  if ip link show wgbackup >/dev/null 2>&1 || [ -f /etc/wireguard/wgbackup.conf ]; then
    found=1; warn "найден старый туннель wgbackup (обычный WireGuard)"
    if yn "Остановить и удалить его (файл конфига сохраню в $DD/legacy/)?" Y; then
      mkdir -p "$DD/legacy"; chmod 700 "$DD/legacy"
      [ -f /etc/wireguard/wgbackup.conf ] && mv /etc/wireguard/wgbackup.conf "$DD/legacy/"
      ip link del wgbackup 2>/dev/null; ok "wgbackup убран"
    fi
  fi
  local u
  for u in awg-backup wg-quick@wgbackup; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$u"; then
      found=1; warn "найдена старая служба $u"
      yn "Отключить и удалить?" Y && { systemctl disable --now "$u" 2>/dev/null; rm -f "$SYSD/$u.service"; systemctl daemon-reload; ok "$u убрана"; }
    fi
  done
  if ip rule show | awk -F: '$1==85||$1==90||$1==100' | grep -q 'lookup 300'; then
    found=1; warn "найдены тестовые правила ip rule (приоритет 85/90/100 → таблица 300)"
    yn "Удалить?" Y && { for p in 85 90 100; do while ip rule del priority $p 2>/dev/null; do :; done; done; ip route flush table 300 2>/dev/null; ok "удалены"; }
  fi
  if iptables -S OUTPUT 2>/dev/null | grep -qE -- '-o wgclt[0-9]+ -p icmp -j DROP'; then
    found=1; warn "в OUTPUT остался тестовый DROP для icmp"
    yn "Удалить?" Y && { iptables -S OUTPUT | grep -E -- '-o wgclt[0-9]+ -p icmp -j DROP' | sed 's/^-A/-D/' | while read -r r; do iptables $r; done; ok "удалён"; }
  fi
  local n; n=$(ps -eo pid,args | grep -F "$DD/failover.sh" | grep -v -e cleanup -e grep -c)
  if [ "$n" -gt 0 ] && ! svc_active awg-failover; then
    found=1; warn "сторож failover.sh запущен вручную (не службой)"
    yn "Остановить его?" Y && { pkill -f "${DD}/failover[.]sh"; [ -x "$DD/failover.sh" ] && "$DD/failover.sh" cleanup; ok "остановлен"; }
  fi
  [ $found = 0 ] && ok "остатков старых установок не найдено"
}

# ============================================================ скрипты =====
KIT=""
KIT_FILES="awg/up.sh awg/failover.sh awg/awg-detect.sh awg/status.sh awg/audit.sh awg/notify.sh awg/awg-notify.sh awg/awg-restore.sh
 awg/awg-uninstall.sh awg/subnets.sh awg/self.sh awg/guard.sh awg/awgctl.sh awg/selftest.sh awg/mtu.sh awg/backup.sh awg/bot.sh awg/metrics.sh
 awg/awg-failover.service awg/awg-notify.service awg/awg-motd.service awg/awg-subnets.service awg/awg-self.service awg/awg-guard.service
 awg/awg-bot.service awg/awg-metrics.service awg/diagnose.sh awg/report.sh awg/domain-check.sh awg/awg-web.service
 awg/drift.sh awg/vps.sh awg/routes.sh awg/obfs-tune.sh awg/lists.sh awg/bot.py awg/ha.py awg/awg-ha.service awg/awg-backup.service awg/web/panel.py awg/web/awgweb/__init__.py awg/web/awgweb/account.py awg/web/awgweb/api.py awg/web/awgweb/backups.py awg/web/awgweb/clients.py awg/web/awgweb/configs.py awg/web/awgweb/core.py awg/web/awgweb/data.py awg/web/awgweb/importer.py awg/web/awgweb/server.py awg/web/awgweb/settings.py awg/web/awgweb/speed.py awg/web/awgweb/tools.py awg/web/awgweb/tunnels.py awg/web/awgweb/update.py awg/web/awgweb/vps.py awg/web/awgweb/webconf.py awg/web/awgweb/xui.py
 awg/web/static/lang-en.js awg/web/static/index.html awg/web/static/app.js awg/web/static/app.css awg/web/static/favicon.svg
 server/awg-server-build.sh server/awg-build-router.sh server/awg-server-setup.sh server/audit-server.sh server/vps-rotate.sh server/vps-harden.sh"
kit_ok(){ local f; for f in $KIT_FILES; do [ -f "$1/$f" ] || return 1; done; }
kit_missing(){ local f; for f in $KIT_FILES; do [ -f "$1/$f" ] || printf '%s ' "$f"; done; }
get_kit(){
  [ -n "$KIT" ] && return 0
  title "Скрипты установки"
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
  if [ -n "$here" ] && kit_ok "$here"; then KIT=$here; ok "беру скрипты из папки $KIT"; kit_verify; return; fi
  local a p
  while :; do
    mkdir -p "$WORK"; rm -rf "$WORK/kit"; mkdir -p "$WORK/kit"
    resolve_ref || { err "не удалось определить версию для скачивания"; AWG_REF=""; }
    info "скачиваю $AWG_REPO: $(ref_label)…"
    if [ -n "$AWG_REF" ] && fetch_kit_archive "$WORK/kit.tgz" && tar xzf "$WORK/kit.tgz" -C "$WORK/kit" 2>/dev/null; then
      p=$(find "$WORK/kit" -path '*/awg/failover.sh' | head -1)
      if [ -n "$p" ] && kit_ok "$(dirname "$(dirname "$p")")"; then KIT=$(dirname "$(dirname "$p")"); ok "скрипты скачаны"; kit_verify; return; fi
      err "в архиве нет нужных файлов: $(kit_missing "$(dirname "$(dirname "${p:-$WORK/kit/x/awg/x}")")")"
    else
      err "не удалось скачать https://github.com/$AWG_REPO"
      hint "Репозиторий задаёт переменная AWG_REPO в начале install.sh (сейчас: $AWG_REPO)."
    fi
    choose a "Что делать?" "Повторить" "Указать папку с репозиторием на роутере" "Указать другой репозиторий (владелец/имя)" "Выйти"
    case $a in
      2) ask p "Путь к папке (в ней должны быть awg/ и server/)" ""; kit_ok "$p" && { KIT=$p; ok "беру скрипты из $KIT"; kit_verify; return; }; err "в $p нет нужных файлов";;
      3) ask AWG_REPO "Репозиторий" "$AWG_REPO"; ask AWG_BRANCH "Ветка" "$AWG_BRANCH"; AWG_CHANNEL=branch; AWG_REF="";;
      4) exit 1;;
    esac
  done
}
# ---- канал обновлений: тег релиза (stable) или ветка (beta/branch)
valid_ref(){ [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_./-]{0,99}$ ]] && [[ $1 != *..* ]]; }
resolve_ref(){
  [ -n "$AWG_REF" ] && return 0
  case "$AWG_CHANNEL" in
    stable)
      AWG_REF=$(curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AWG_REPO/releases/latest" 2>/dev/null \
        | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
      if [ -n "$AWG_REF" ] && valid_ref "$AWG_REF"; then AWG_REF_KIND=tag
      else warn "релиз в $AWG_REPO не найден (или GitHub API недоступен) — беру ветку main"; AWG_REF=main; AWG_REF_KIND=branch; fi;;
    beta)   AWG_REF=main; AWG_REF_KIND=branch;;
    branch) AWG_REF=$AWG_BRANCH; AWG_REF_KIND=branch;;
  esac
  valid_ref "$AWG_REF" || { err "недопустимое имя ветки или тега: $AWG_REF"; AWG_REF=""; return 1; }
}
ref_label(){ case "$AWG_REF_KIND" in tag) echo "релиз $AWG_REF (канал stable)";; *) echo "ветка $AWG_REF (канал $AWG_CHANNEL)";; esac; }
fetch_kit_archive(){  # fetch_kit_archive ФАЙЛ — релиз: архив + SHA256SUMS со сверкой; ветка: архив GitHub
  local out=$1 base name want have
  if [ "$AWG_REF_KIND" = tag ]; then
    base="https://github.com/$AWG_REPO/releases/download/$AWG_REF"; name="udr-amnezia-$AWG_REF.tar.gz"
    curl -fsSL -m 120 "$base/$name" -o "$out" || { err "нет архива $name в релизе $AWG_REF"; return 1; }
    want=$(curl -fsSL -m 30 "$base/SHA256SUMS" 2>/dev/null | awk -v n="$name" '$2==n || $2=="*"n {print $1; exit}')
    have=$(sha256sum "$out" | cut -d' ' -f1)
    [ -n "$want" ] || { err "в релизе $AWG_REF нет SHA256SUMS для $name: архив не устанавливаю"; rm -f "$out"; return 1; }
    [ "$want" = "$have" ] || { err "контрольная сумма архива НЕ совпала (ожидалась $want, получена $have): не устанавливаю"; rm -f "$out"; return 1; }
    ok "контрольная сумма архива релиза совпала"
  else
    curl -fsSL -m 120 "https://github.com/$AWG_REPO/archive/refs/heads/$AWG_REF.tar.gz" -o "$out"
  fi
}
write_channel(){
  case "$AWG_REPO$AWG_BRANCH" in *[!A-Za-z0-9_./-]*) return 0;; esac
  printf 'AWG_REPO=%s\nAWG_CHANNEL=%s\nAWG_BRANCH=%s\n' "$AWG_REPO" "$AWG_CHANNEL" "$AWG_BRANCH" > "$DD/.channel"
}
kit_verify(){
  local f bad=0
  for f in "$KIT"/awg/*.sh "$KIT"/server/*.sh; do bash -n "$f" 2>/dev/null || { err "синтаксическая ошибка в $f"; bad=1; }; done
  if command -v python3 >/dev/null && [ -f "$KIT/awg/web/panel.py" ]; then
    for f in "$KIT/awg/web/panel.py" "$KIT"/awg/web/awgweb/*.py; do
      [ -f "$f" ] || continue
      python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null || { err "синтаксическая ошибка в ${f#"$KIT"/}"; bad=1; }
    done
  fi
  [ $bad = 0 ] && ok "скрипты прошли проверку синтаксиса" || die "скрипты повреждены, скачайте заново."
  [ -f "$KIT/VERSION" ] && info "версия набора: $(cat "$KIT/VERSION")"
}

put(){  # put ИСТОЧНИК ЦЕЛЬ — заменить файл целиком (через .new и mv): запущенные bash-скрипты продолжают читать старую копию
  cp "$1" "$2.new" && mv -f "$2.new" "$2"
}
install_files(){
  mkdir -p "$DD"; chmod 700 "$DD"
  local f
  for f in "$KIT"/awg/*; do [ -f "$f" ] && put "$f" "$DD/$(basename "$f")"; done
  # веб-панель: код и страница заменяются, пользователи, сертификат и настройки панели (web/*.json, *.pem, web.conf) остаются
  if [ -d "$KIT/awg/web" ]; then
    mkdir -p "$DD/web/static"; chmod 700 "$DD/web"
    put "$KIT/awg/web/panel.py" "$DD/web/panel.py"; chmod 700 "$DD/web/panel.py"
    # код панели по модулям (#18): web/awgweb/*.py
    if [ -d "$KIT/awg/web/awgweb" ]; then
      mkdir -p "$DD/web/awgweb"; chmod 700 "$DD/web/awgweb"
      for f in "$KIT"/awg/web/awgweb/*.py; do [ -f "$f" ] && put "$f" "$DD/web/awgweb/$(basename "$f")"; done
      chmod 600 "$DD"/web/awgweb/*.py; rm -rf "$DD/web/awgweb/__pycache__"
    fi
    for f in "$KIT"/awg/web/static/*; do [ -f "$f" ] && put "$f" "$DD/web/static/$(basename "$f")"; done
    chmod 644 "$DD"/web/static/*
  fi
  # скрипты для своего VPS: панель и vps.sh передают их на сервер (#13)
  if [ -d "$KIT/server" ]; then
    mkdir -p "$DD/server"; chmod 700 "$DD/server"
    for f in vps-rotate.sh audit-server.sh awg-server-build.sh awg-server-setup.sh awg-build-router.sh; do [ -f "$KIT/server/$f" ] && put "$KIT/server/$f" "$DD/server/$f"; done
  fi
  chmod 755 "$DD"/*.sh; chmod 700 "$DD/notify.sh" "$DD/awg-notify.sh" "$DD/bot.sh"
  chmod 644 "$DD"/*.service
  # юниты в репозитории ссылаются на /data/awg; при другой папке (тесты) поправить пути
  [ "$DD" = /data/awg ] || sed -i "s#/data/awg/#$DD/#g" "$DD"/*.service
  if [ -f "$KIT/install.sh" ]; then [ "$KIT/install.sh" -ef "$DD/install.sh" ] || put "$KIT/install.sh" "$DD/install.sh"
  elif [ -f "$0" ] && [ "$(basename "$0")" = install.sh ] && ! [ "$0" -ef "$DD/install.sh" ]; then put "$0" "$DD/install.sh"; fi
  [ -f "$DD/install.sh" ] && chmod 755 "$DD/install.sh"
  [ -f "$KIT/VERSION" ] && put "$KIT/VERSION" "$DD/VERSION"
  write_channel
  ensure_aliases
  write_manifest
  touch "$DD/.installer"
  ok "скрипты установлены в $DD (набор $(cat "$DD/VERSION" 2>/dev/null || echo "$INSTALLER_VERSION"))"
}
ensure_aliases(){
  local a
  for a in "awgctl=$DD/awgctl.sh" "awg-selftest=$DD/selftest.sh"; do
    grep -q "alias ${a%%=*}=" $BASHRC 2>/dev/null || echo "alias ${a%%=*}='${a#*=}'" >> $BASHRC
  done
  ensure_links
}

# ============================================================ бинарники ===
bins_ok(){ [ -x "$DD/awg" ] && [ -x "$DD/amneziawg-go" ] && "$DD/awg" --version >/dev/null 2>&1 && "$DD/amneziawg-go" --version >/dev/null 2>&1; }
bins_install_from(){  # bins_install_from ПАПКА — найти amneziawg-go и awg, сверить SHA256SUMS (если есть), установить
  local src=$1 fa fb v sums
  fa=$(find "$src" -maxdepth 3 -type f -name amneziawg-go 2>/dev/null | head -1); fb=$(find "$src" -maxdepth 3 -type f -name awg 2>/dev/null | head -1)
  if [ -z "$fa" ] || [ -z "$fb" ]; then err "не нашёл файлы amneziawg-go и awg в $src"; return 1; fi
  [ "$(dirname "$fa")" = "$(dirname "$fb")" ] || { err "amneziawg-go и awg лежат в разных папках ($fa, $fb): положите их вместе"; return 1; }
  sums=$(dirname "$fa")/SHA256SUMS
  if [ -f "$sums" ]; then
    local wa wb
    wa=$(awk '$2=="amneziawg-go" || $2=="*amneziawg-go" {print $1; exit}' "$sums"); wb=$(awk '$2=="awg" || $2=="*awg" {print $1; exit}' "$sums")
    if [ -z "$wa" ] || [ -z "$wb" ]; then err "в SHA256SUMS нет строк для обоих файлов (amneziawg-go и awg)"; return 1; fi
    if [ "$(sha256sum "$fa" | cut -d' ' -f1)" = "${wa,,}" ] && [ "$(sha256sum "$fb" | cut -d' ' -f1)" = "${wb,,}" ]; then ok "контрольные суммы обоих файлов совпали с SHA256SUMS"
    else err "контрольные суммы НЕ совпали с SHA256SUMS: файлы повреждены при переносе или подменены"; return 1; fi
  else
    warn "рядом с файлами нет SHA256SUMS: целостность проверить нечем"
  fi
  [ -f "$(dirname "$fa")/BUILDINFO" ] && sed 's/^/      /' "$(dirname "$fa")/BUILDINFO"
  [ -x "$DD/awg" ] && { cp -p "$DD/awg" "$DD/awg.prev"; cp -p "$DD/amneziawg-go" "$DD/amneziawg-go.prev"; } 2>/dev/null
  cp "$fa" "$DD/amneziawg-go.new" && cp "$fb" "$DD/awg.new" && chmod 755 "$DD/amneziawg-go.new" "$DD/awg.new" || { err "не удалось скопировать в $DD"; return 1; }
  if ! "$DD/awg.new" --version >/dev/null 2>&1 || ! "$DD/amneziawg-go.new" --version >/dev/null 2>&1; then
    v=$("$DD/awg.new" --version 2>&1 | head -1)
    err "бинарник не запускается на роутере: ${v:-нет вывода}"
    echo "$v" | grep -qi 'exec format' && hint "Файлы собраны не под aarch64. Нужна сборка linux/arm64 (server/awg-build-router.sh)."
    rm -f "$DD/amneziawg-go.new" "$DD/awg.new"; return 1
  fi
  mv -f "$DD/amneziawg-go.new" "$DD/amneziawg-go"; mv -f "$DD/awg.new" "$DD/awg"
  bins_note "$(dirname "$fa")/BUILDINFO"
  ok "установлены: $("$DD/awg" --version 2>&1 | head -1); $("$DD/amneziawg-go" --version 2>&1 | head -1)"
  info "sha256: $(sha256sum "$DD/amneziawg-go" | cut -c1-16)… (amneziawg-go), $(sha256sum "$DD/awg" | cut -c1-16)… (awg)"
  [ -f "$DD/awg.prev" ] && hint "прежние версии сохранены: $DD/awg.prev, $DD/amneziawg-go.prev"
  return 0
}
bins_build_on_vps(){  # сборка из официальных исходников на своём VPS по SSH и перенос на роутер
  local t=$1
  command -v ssh >/dev/null && command -v scp >/dev/null || { err "на роутере нет ssh/scp"; return 1; }
  vps_connect || return 1
  vput "$KIT/server/awg-build-router.sh" || { err "не удалось передать скрипт на VPS"; return 1; }
  title "Сборка amneziawg-go $AWG_GO_REF и awg $AWG_TOOLS_REF на VPS (3–7 минут)"
  vssh "AWG_GO_REF=$AWG_GO_REF AWG_TOOLS_REF=$AWG_TOOLS_REF bash /root/awg-build-router.sh" 2>&1 | sed 's/^/    │ /'
  [ "${PIPESTATUS[0]}" = 0 ] && vssh 'test -s /root/awgbuild/router/awg && test -s /root/awgbuild/router/amneziawg-go' || {
    err "сборка не удалась"; hint "Частые причины: мало места или памяти на VPS (нужно ~1 ГБ), нет доступа к github.com, go.dev или proxy.golang.org."; return 1; }
  local f; for f in amneziawg-go awg SHA256SUMS BUILDINFO; do vget "/root/awgbuild/router/$f" "$t/$f" || { err "не удалось забрать $f с VPS"; return 1; }; done
  ok "файлы перенесены с VPS"
}
bins_manual_help(){
  local base; resolve_ref || return 1; base="https://raw.githubusercontent.com/$AWG_REPO/$AWG_REF/server"
  say "  На любом компьютере или сервере с Ubuntu/Debian (x86_64 или arm64, подойдёт и WSL), под root:"
  say "${C}    curl -fsSL $base/awg-build-router.sh -o awg-build-router.sh"
  say "    AWG_GO_REF=$AWG_GO_REF AWG_TOOLS_REF=$AWG_TOOLS_REF bash awg-build-router.sh"
  say "    ssh root@$(lan_ip) mkdir -p /tmp/awgbin && scp /root/awgbuild/router/* root@$(lan_ip):/tmp/awgbin/${N}"
  say "  Скрипт клонирует только github.com/amnezia-vpn/amneziawg-go и amneziawg-tools, собирает статические файлы под arm64"
  say "  и пишет SHA256SUMS; установщик сверит суммы. Затем выберите пункт «Папка на роутере» → /tmp/awgbin."
}
# ---- проверка и обновление бинарников из официальных релизов amnezia-vpn (#11)
bins_note(){  # запомнить теги сборки (из BUILDINFO) вместе с суммами файлов: --version не всегда показывает тег релиза
  local bi=$1 tg tt
  rm -f "$DD/.binsver"
  [ -f "$bi" ] || return 0
  tg=$(awk '$1=="amneziawg-go" {print $3; exit}' "$bi"); tt=$(awk '$1=="amneziawg-tools" {print $3; exit}' "$bi")
  [[ $tg =~ ^v[0-9][0-9.]*$ ]] && [[ $tt =~ ^v[0-9][0-9.]*$ ]] || return 0
  printf 'amneziawg-go %s %s\nawg %s %s\n' "$tg" "$(sha256sum "$DD/amneziawg-go" | cut -d' ' -f1)" "$tt" "$(sha256sum "$DD/awg" | cut -d' ' -f1)" > "$DD/.binsver"
}
bins_ver(){  # bins_ver amneziawg-go|awg — тег установленной сборки: из .binsver, если сумма файла совпала, иначе из --version
  local v sum
  if [ -f "$DD/.binsver" ]; then
    read -r v sum < <(awk -v n="$1" '$1==n {print $2, $3; exit}' "$DD/.binsver")
    [ -n "$sum" ] && [ "$sum" = "$(sha256sum "$DD/$1" 2>/dev/null | cut -d' ' -f1)" ] && { echo "$v"; return; }
  fi
  # первая строка: «amneziawg-tools v3.1.20260812 - …» или у старых сборок «amneziawg-go 0.0.20250522» (без v)
  "$DD/$1" --version 2>&1 | head -n1 | grep -oE 'v?[0-9]+(\.[0-9]+)+' | head -n1 | sed 's/^v*/v/'
}
bins_latest(){  # bins_latest amneziawg-go|amneziawg-tools — последний релиз (или самый свежий тег) в github.com/amnezia-vpn
  local r=$1 tag
  tag=$(curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/amnezia-vpn/$r/releases/latest" 2>/dev/null \
    | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
  [ -n "$tag" ] || tag=$(curl -fsSL -m 20 "https://api.github.com/repos/amnezia-vpn/$r/tags?per_page=30" 2>/dev/null \
    | sed -n 's/^ *"name": *"\(v[0-9][0-9.]*\)".*/\1/p' | sort -V | tail -n1)
  [[ $tag =~ ^v[0-9][0-9.]*$ ]] && echo "$tag"
}
do_bins_check(){  # код 0 — актуально, 10 — есть новее, 1 — не удалось узнать
  local ig it lg lt rc=0
  ig=$(bins_ver amneziawg-go); it=$(bins_ver awg)
  lg=$(bins_latest amneziawg-go); lt=$(bins_latest amneziawg-tools)
  if [ -z "$lg" ] || [ -z "$lt" ]; then err "не удалось узнать последние версии на github.com/amnezia-vpn"; return 1; fi
  for x in "amneziawg-go|${ig:-нет}|$lg" "awg (amneziawg-tools)|${it:-нет}|$lt"; do
    IFS='|' read -r n i l <<< "$x"
    if [ "$i" = нет ]; then warn "$n: версию установленного файла определить не удалось (последний релиз $l)"
    elif [ "$i" = "$l" ]; then ok "$n: $i — последняя версия"
    elif [ "$(printf '%s\n%s\n' "$i" "$l" | sort -V | tail -n1)" = "$l" ]; then warn "$n: установлена $i, есть $l"; rc=10
    else info "$n: установлена $i (новее последнего релиза $l)"; fi
  done
  [ $rc = 10 ] && hint "обновить: $DD/install.sh --bins-update (сборка на вашем VPS) или --bins-update ПАПКА (готовые файлы с SHA256SUMS)"
  return $rc
}
tun_hs_age(){ local ts; ts=$("$DD/awg" show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
bins_live(){ local t a; for t in $(list_tunnels); do a=$(tun_hs_age "$t"); [ "$a" -ge 0 ] 2>/dev/null && [ "$a" -le 180 ] && printf ' %s' "$t"; done; }
bins_apply(){  # bins_apply "ТУННЕЛИ" — пересоздать туннели на новых бинарниках; если туннель из списка (был handshake) его не получил — вернуть *.prev
  local before=$1 t a bad="" i
  info "перезапускаю туннели на новых бинарниках (несколько секунд без PBR-трафика, kill-switch держит, утечки нет)…"
  for t in $(list_tunnels); do "$DD/up.sh" "$t" >/dev/null 2>&1 || bad="$bad $t"; done
  systemctl restart awg-failover 2>/dev/null     # вернёт маршруты и начнёт проверки, а они вызывают handshake
  [ -n "$bad" ] && err "не поднялись:$bad"
  for i in $(seq 1 "${BINS_WAIT:-30}"); do
    bad=""; for t in $before; do a=$(tun_hs_age "$t"); { [ "$a" -ge 0 ] && [ "$a" -le 180 ]; } 2>/dev/null || bad="$bad $t"; done
    [ -z "$bad" ] && break; sleep 2
  done
  if [ -n "$bad" ]; then
    err "на новых бинарниках нет handshake:$bad — возвращаю прежние"
    if [ -f "$DD/awg.prev" ] && [ -f "$DD/amneziawg-go.prev" ]; then
      cp -p "$DD/awg.prev" "$DD/awg" && cp -p "$DD/amneziawg-go.prev" "$DD/amneziawg-go"
      for t in $(list_tunnels); do "$DD/up.sh" "$t" >/dev/null 2>&1; done
      systemctl restart awg-failover 2>/dev/null
      ok "вернул прежние: $("$DD/awg" --version 2>&1 | head -1)"
    else
      err "прежних файлов (*.prev) нет, откатить нечем"
    fi
    return 1
  fi
  ok "туннели работают на новых бинарниках:${before:- (handshake до обновления не было ни у одного туннеля)}"
}
do_bins_update(){  # do_bins_update [ПАПКА] — из папки с SHA256SUMS или сборкой на своём VPS
  local src=${1:-} t=$WORK/bin lg lt before
  title "Обновление бинарников AmneziaWG"
  before=$(bins_live)
  if [ -z "$src" ]; then
    lg=$(bins_latest amneziawg-go); lt=$(bins_latest amneziawg-tools)
    [ -z "$lg" ] || [ -z "$lt" ] && die "не удалось узнать последние версии на github.com/amnezia-vpn"
    AWG_GO_REF=$lg; AWG_TOOLS_REF=$lt
    rm -rf "$t"; mkdir -p "$t"
    get_kit; bins_build_on_vps "$t" || die "сборка на VPS не удалась; можно собрать вручную и указать папку: --bins-update ПАПКА"
    src=$t
  fi
  bins_install_from "$src" || die "бинарники не установлены"
  bins_apply "$before" || die "обновление отменено, работают прежние бинарники"
  write_manifest
}
step_bins(){
  title "Бинарники AmneziaWG (amneziawg-go и awg)"
  if bins_ok; then
    ok "уже установлены: $("$DD/awg" --version 2>&1 | head -1); $("$DD/amneziawg-go" --version 2>&1 | head -1)"
    yn "Оставить их?" Y && return 0
  fi
  say "  ${D}Бинарники берутся только из официальных исходников AmneziaVPN (github.com/amnezia-vpn): их собирают на вашем VPS${N}"
  say "  ${D}или компьютере (компилятора на роутере нет). Либо укажите свой источник: ссылку на файлы и их SHA-256 или папку.${N}"
  local a url sum t=$WORK/bin
  while :; do
    choose a "Откуда взять бинарники под aarch64?" \
      "Собрать из официальных исходников на моём VPS по SSH (рекомендуется, если VPS есть)" \
      "Собрать на своём компьютере или сервере — показать команды" \
      "Папка на роутере, где уже лежат amneziawg-go и awg (например /tmp/awgbin)" \
      "Свой источник: URL архива .tar.gz или прямые ссылки на два файла + SHA-256" \
      "Выйти"
    rm -rf "$t"; mkdir -p "$t"
    case $a in
      1) bins_build_on_vps "$t" && bins_install_from "$t" && { rm -rf "$t"; return 0; };;
      2) bins_manual_help; pause "Когда файлы будут в /tmp/awgbin на роутере, нажмите Enter"
         bins_install_from /tmp/awgbin && return 0;;
      3) ask url "Папка" "/tmp/awgbin"; bins_install_from "$url" && return 0;;
      4) ask url "URL архива .tar.gz (или ссылка на amneziawg-go)" ""
         [ -n "$url" ] || continue
         case "$url" in https://*) ;; *) err "нужна ссылка https://"; continue;; esac
         if [[ "$url" == *.tar.gz || "$url" == *.tgz ]]; then
           ask sum "SHA-256 архива (64 символа; пусто — без проверки, не рекомендуется)" ""
           curl -fL -m 300 "$url" -o "$t/b.tgz" || { err "скачать не удалось"; continue; }
           if [ -n "$sum" ]; then
             [ "$(sha256sum "$t/b.tgz" | cut -d' ' -f1)" = "${sum,,}" ] && ok "SHA-256 архива совпал" || { err "SHA-256 архива не совпал: файл не устанавливаю"; continue; }
           else yn "Ставить без проверки SHA-256?" N || continue; fi
           mkdir -p "$t/x"; tar xzf "$t/b.tgz" -C "$t/x" 2>/dev/null || { err "это не архив tar.gz"; continue; }
           bins_install_from "$t/x" && { rm -rf "$t"; return 0; }
         else
           local u2 s1 s2
           ask u2 "Ссылка на awg" ""
           ask s1 "SHA-256 amneziawg-go" ""; ask s2 "SHA-256 awg" ""
           [[ "${s1,,}" =~ ^[0-9a-f]{64}$ && "${s2,,}" =~ ^[0-9a-f]{64}$ ]] || { err "для прямых ссылок нужны обе суммы SHA-256 (64 шестнадцатеричных символа)"; continue; }
           curl -fL -m 300 "$url" -o "$t/amneziawg-go" && curl -fL -m 300 "$u2" -o "$t/awg" || { err "скачать не удалось"; continue; }
           printf '%s  amneziawg-go\n%s  awg\n' "${s1,,}" "${s2,,}" > "$t/SHA256SUMS"
           bins_install_from "$t" && { rm -rf "$t"; return 0; }
         fi;;
      5) exit 1;;
    esac
  done
}

# ============================================================ конфиги =====
check_conf(){ # check_conf ФАЙЛ → CONF_EP CONF_ADDR CONF_AWG; 0 = годен
  local f=$1 bad=0
  CONF_EP=; CONF_ADDR=; CONF_AWG=0
  [ -s "$f" ] || { err "файл пустой"; return 1; }
  grep -qiE '^[[:space:]]*\[Interface\]' "$f" || { err "нет секции [Interface]"; bad=1; }
  grep -qiE '^[[:space:]]*\[Peer\]' "$f" || { err "нет секции [Peer]"; bad=1; }
  [ -n "$(conf_get "$f" PrivateKey)" ] || { err "нет строки PrivateKey"; bad=1; }
  [ -n "$(conf_get "$f" PublicKey)" ] || { err "нет строки PublicKey (ключ сервера)"; bad=1; }
  CONF_EP=$(conf_get "$f" Endpoint | tr -d ' \t'); [ -n "$CONF_EP" ] || { err "нет строки Endpoint"; bad=1; }
  CONF_ADDR=$(conf_get "$f" Address | tr ',' '\n' | tr -d ' \t' | grep -m1 '\.')
  [ -n "$CONF_ADDR" ] || { err "нет IPv4-адреса в строке Address"; bad=1; }
  grep -qiE '^[[:space:]]*Jc[[:space:]]*=' "$f" && CONF_AWG=1
  return $bad
}
conf_summary(){ check_conf "$1" >/dev/null 2>&1; info "сервер ${CONF_EP:-?}, адрес ${CONF_ADDR:-?}, $( [ "$CONF_AWG" = 1 ] && echo 'AmneziaWG (обфускация есть)' || echo 'обычный WireGuard без обфускации')"; }

get_conf(){  # get_conf ИМЯ_ФАЙЛА "описание" [new] — кладёт конфиг в $DD/ИМЯ; new — не предлагать текущий (замена)
  local name=$1 what=$2 dest=$DD/$1 a p tmp=$DD/.incoming.conf
  if [ -s "$dest" ] && [ "$3" != new ]; then
    info "уже есть $dest:"; conf_summary "$dest"
    yn "Использовать его?" Y && return 0
  fi
  while :; do
    choose a "Как передать $what?" \
      "Вставить текст конфига в терминал" \
      "Указать путь к файлу на роутере (например, загруженному через scp)" \
      "Выйти"
    case $a in
      1) read_paste "$tmp";;
      2) ask p "Путь к файлу" "/tmp/${name}"; [ -f "$p" ] || { err "файла $p нет"; hint "С компьютера: scp файл.conf root@$(lan_ip):/tmp/"; continue; }; ( umask 077; tr -d '\r' < "$p" > "$tmp" );;
      3) exit 1;;
    esac
    if check_conf "$tmp"; then
      if [ "$CONF_AWG" = 0 ]; then
        warn "это обычный WireGuard без параметров обфускации (Jc, S1, H1…)."
        hint "Если провайдер режет WireGuard, туннель будет обрываться через 5–8 секунд. Нужен конфиг AmneziaWG."
        yn "Всё равно использовать?" N || { rm -f "$tmp"; continue; }
      fi
      mv "$tmp" "$dest"; chmod 600 "$dest"
      ok "сохранён $dest"; conf_summary "$dest"
      return 0
    fi
    rm -f "$tmp"
    hint "Нужен полный конфиг: [Interface] с PrivateKey и Address, [Peer] с PublicKey и Endpoint."
  done
}

# ============================================================ туннели =====

bring_up_and_test(){  # bring_up_and_test ИНТЕРФЕЙС "описание" — 0 если работает
  local ifc=$1 what=$2 a out
  while :; do
    info "поднимаю $ifc…"
    out=$("$DD/up.sh" "$ifc" 2>&1); say "$out" | sed 's/^/    /'
    if echo "$out" | grep -q 'ОШИБКА'; then
      if echo "$out" | grep -qiE 'unrecognized|invalid|unknown'; then
        warn "утилита awg не поняла строку конфига: бинарник старее, чем параметры в конфиге."
        hint "Решения: свежая сборка amneziawg (см. гайд, «Сборка бинарников»), или конфиг без новых параметров (S3, S4, I1…)."
      fi
    else
      info "проверяю выход в интернет через $ifc…"
      if TUN_IP=$(tun_ip "$ifc"); then
        ok "$what работает: внешний IP $TUN_IP, handshake $(hs_age "$ifc") с назад"; return 0
      fi
      err "через $ifc интернет не открывается"
      diag_tunnel "$ifc"
    fi
    choose a "Что делать?" "Проверить ещё раз" "Заменить конфиг" "Продолжить без рабочего туннеля (не рекомендуется)" "Выйти"
    case $a in
      2) local cf; cf=$(conf_of "$ifc"); get_conf "$cf" "$what" new;;
      3) warn "продолжаю с нерабочим $ifc"; return 1;;
      4) exit 1;;
    esac
  done
}

diag_tunnel(){  # diag_tunnel ИНТЕРФЕЙС [порт_на_своём_VPS]
  local ifc=$1 srvport=$2 cf host port epip cap out in hs rx wan sin=-1 sout=-1
  cf=$(conf_of "$ifc")
  check_conf "$DD/$cf" >/dev/null 2>&1
  host=${CONF_EP%:*}; host=${host#[}; host=${host%]}; port=${CONF_EP##*:}
  title "Диагностика $ifc"
  epip=$(resolve "$host")
  if [ -z "$epip" ]; then err "не удалось получить IP для $host"; hint "Проверьте Endpoint в конфиге и DNS роутера: nslookup $host"; return; fi
  wan=$(wan_if)
  info "сервер $epip:$port, WAN $wan"
  hs=$(hs_age "$ifc"); rx=$("$DD/awg" show "$ifc" transfer 2>/dev/null | awk '{print $2; exit}')
  info "handshake: $( [ "$hs" -ge 0 ] && echo "${hs} с назад" || echo нет ), принято байт: ${rx:-0}"
  if ! command -v tcpdump >/dev/null; then warn "tcpdump нет, подробная диагностика невозможна"; return; fi
  info "12 секунд слушаю WAN и шлю пробный трафик через туннель…"
  mkdir -p "$WORK"; rm -f "$WORK/srvcap.txt"
  if [ -n "$srvport" ] && [ -n "$VPS_IP" ]; then
    ( vssh "timeout 13 tcpdump -lni any -c 40 udp port $srvport 2>/dev/null" > "$WORK/srvcap.txt" 2>/dev/null ) &
  fi
  ( sleep 2; for k in 1 2 3 4; do curl -s -m 2 --interface "$ifc" https://1.1.1.1 >/dev/null 2>&1; done ) &
  cap=$(timeout 12 tcpdump -lni "$wan" -c 60 "udp and host $epip" 2>/dev/null)
  wait
  out=$(printf '%s\n' "$cap" | grep -c "> $epip\.$port:")
  in=$(printf '%s\n' "$cap" | grep -c " $epip\.$port > ")
  info "роутер → сервер: $out пакетов, сервер → роутер: $in"
  if [ -n "$srvport" ] && [ -f "$WORK/srvcap.txt" ]; then
    sin=$(grep -c " > [0-9.]*\.$srvport:" "$WORK/srvcap.txt"); sout=$(grep -c "\.$srvport > " "$WORK/srvcap.txt")
    info "на сервере: пришло $sin, отправлено $sout"
  fi
  say "  ${B}Вывод:${N}"
  if [ "$out" = 0 ]; then
    err "роутер не отправляет пакеты на сервер."
    hint "Проверьте: ip link show $ifc; ip route get $epip. Если интерфейса нет — ошибка при подъёме, см. вывод up.sh выше."
  elif [ "$sin" = 0 ]; then
    err "пакеты уходят с роутера, но до сервера не доходят."
    hint "Откройте UDP $srvport в файрволе хостера (панель VPS) и в ufw: ufw allow $srvport/udp. Проверьте внешний IP сервера."
  elif [ "$sin" -gt 0 ] 2>/dev/null && [ "$sout" = 0 ]; then
    err "сервер получает пакеты, но не отвечает."
    hint "Ключи или параметры обфускации на сервере не совпадают с конфигом. Пересоздайте сервер (мастер предложит это в меню VPS)."
  elif [ "$in" = 0 ]; then
    err "сервер не отвечает (или ответы теряются по дороге)."
    hint "Свой VPS: закрыт порт у хостера, не запущена служба awg-server, неверные ключи."
    hint "VPN-провайдер: конфиг отозван, истёк срок, не тот ключ. Запросите новый конфиг."
  elif [ "$hs" -lt 0 ]; then
    err "сервер отвечает, но handshake не завершается."
    hint "Не совпадают параметры обфускации (Jc/Jmin/Jmax/S1/S2/H1–H4) или ключи сервера и клиента."
  else
    warn "handshake есть, а HTTPS через туннель не проходит."
    hint "Свой VPS: проверьте NAT и ip_forward (audit-server.sh). Провайдер: лимит трафика или срок подписки."
    hint "Если обмен идёт несколько секунд и обрывается в обе стороны — похоже на DPI: нужен AmneziaWG, а не WireGuard."
  fi
}

# ============================================================ VPS по SSH ==
VPS_IP=; VPS_USER=root; VPS_SSHPORT=22; AWG_PORT=51823
CTL="/tmp/awg-ssh-%r@%h:%p"
RKEY=$DD/ssh/id_ed25519      # ключ роутера для входа на свой VPS (лежит в /data: переживает обновление прошивки)
ssh_opts(){
  local k=(); [ -f "$RKEY" ] && k=(-o "IdentityFile=$RKEY")
  SSHO=(-n -p "$VPS_SSHPORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o "ControlPath=$CTL" "${k[@]}")
  SCPO=(-P "$VPS_SSHPORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o "ControlPath=$CTL" "${k[@]}")
}
router_key_to_vps(){  # создать ключ роутера (если нет) и добавить его на VPS в authorized_keys
  command -v ssh-keygen >/dev/null || { warn "на роутере нет ssh-keygen: ключ роутера создать нельзя"; return 1; }
  if [ ! -f "$RKEY" ]; then
    mkdir -p "$DD/ssh"; chmod 700 "$DD/ssh"
    ssh-keygen -q -t ed25519 -N "" -C "udr-awg@$(hostname)" -f "$RKEY" || { err "ssh-keygen не сработал"; return 1; }
  fi
  local pub; pub=$(cat "$RKEY.pub")
  vssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys; }" \
    && ok "ключ роутера добавлен на VPS: установщик будет входить без пароля ($RKEY)" || { err "не удалось добавить ключ на VPS"; return 1; }
  ssh_opts
}
ssh_master(){  # одно подключение с паролем на весь сеанс
  ssh -O check -p "$VPS_SSHPORT" -o "ControlPath=$CTL" "$VPS_USER@$VPS_IP" >/dev/null 2>&1 && return 0
  local k=(); [ -f "$RKEY" ] && k=(-o "IdentityFile=$RKEY")
  ssh -fN -p "$VPS_SSHPORT" "${k[@]}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=yes -o "ControlPath=$CTL" -o ControlPersist=900 "$VPS_USER@$VPS_IP"
}
vssh(){ ssh "${SSHO[@]}" "$VPS_USER@$VPS_IP" "$@"; }
vput(){ scp -q "${SCPO[@]}" "$@" "$VPS_USER@$VPS_IP:/root/"; }
vget(){ scp -q "${SCPO[@]}" "$VPS_USER@$VPS_IP:$1" "$2"; }

vps_connect(){
  local a r
  mkdir -p "$WORK"
  while :; do
    ask VPS_IP "Внешний IP вашего VPS" "${VPS_IP:-$(env_get VPS_IP)}"
    is_ipv4 "$VPS_IP" || { warn "это не IPv4-адрес"; VPS_IP=; continue; }
    ask VPS_SSHPORT "SSH-порт" "${VPS_SSHPORT:-22}"
    ask VPS_USER "Пользователь (нужен root)" "${VPS_USER:-root}"
    ssh_opts
    info "подключаюсь… (пароль VPS, если спросят, вводится один раз за сеанс)"
    ssh_master 2>"$WORK/ssh.err" || true
    r=$(vssh 'echo CONNECTED; uname -m; . /etc/os-release 2>/dev/null; echo "$ID $VERSION_ID"; id -u; command -v apt-get >/dev/null && echo APT' 2>>"$WORK/ssh.err")
    if echo "$r" | grep -qx CONNECTED; then
      local arch os uid; r=$(echo "$r" | sed -n '/^CONNECTED$/,$p')
      arch=$(echo "$r" | sed -n '2p'); os=$(echo "$r" | sed -n '3p'); uid=$(echo "$r" | sed -n '4p')
      ok "SSH работает: $os, $arch"
      [ "$uid" = 0 ] || { err "пользователь не root: сборке нужен root (apt, systemd)"; hint "Войдите как root или включите root-доступ на VPS."; continue; }
      echo "$r" | grep -q APT || { err "на сервере нет apt: скрипты рассчитаны на Ubuntu/Debian"; yn "Попробовать всё равно?" N || continue; }
      case "$arch" in x86_64|aarch64) ;; *) warn "архитектура $arch не проверялась";; esac
      echo "$os" | grep -qE '^(ubuntu|debian)' || warn "проверено на Ubuntu 22.04/24.04"
      return 0
    fi
    err "не удалось подключиться по SSH"
    r="$r $(cat "$WORK/ssh.err" 2>/dev/null)"
    echo "$r" | grep -v '^$' | tail -n 3 | sed 's/^/    /'
    if echo "$r" | grep -qi 'Permission denied'; then hint "Неверный пароль/ключ или вход root по паролю запрещён (PermitRootLogin)."
    elif echo "$r" | grep -qiE 'timed out|No route|refused'; then hint "Проверьте IP и порт SSH, файрвол хостера."
    elif echo "$r" | grep -qi 'host key'; then hint "Ключ сервера изменился (переустановка VPS?). Удалите старую запись: ssh-keygen -R $VPS_IP"; fi
    choose a "Что делать?" "Ввести данные заново" "Настроить VPS вручную" "Выйти"
    case $a in 2) return 1;; 3) exit 1;; esac
  done
}

obf_from_main(){  # пишет 9 строк Jc..H4 из main.conf в файл, если параметры подходят для AWG 1.x
  local f=$DD/main.conf out=$1 h k ok=1
  [ -s "$f" ] || return 1
  for k in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do [ -n "$(conf_get "$f" $k)" ] || return 1; done
  for k in H1 H2 H3 H4; do h=$(conf_get "$f" $k | tr -d ' '); [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -gt 4 ] || ok=0; done
  [ $ok = 1 ] || return 1
  for k in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do printf '%s = %s\n' $k "$(conf_get "$f" $k | tr -d ' ')"; done > "$out"
}

vps_setup(){  # vps_setup ИМЯ_КОНФИГА(main.conf|backup.conf) — 0 если конфиг получен
  local cfg=$1 a st exists=0 client=0 obf=""
  vps_connect || return 1
  st=$(vssh 'test -e /etc/amnezia/server.conf && echo SERVER; test -e /root/awgbuild/client.conf && echo CLIENT; command -v awg >/dev/null && command -v amneziawg-go >/dev/null && echo BUILT; systemctl is-active awg-server 2>/dev/null')
  echo "$st" | grep -q SERVER && exists=1
  echo "$st" | grep -q CLIENT && client=1
  local regen=0
  if [ $exists = 1 ]; then
    warn "на VPS уже есть сервер AmneziaWG (/etc/amnezia/server.conf)"
    if [ $client = 1 ]; then
      choose a "Что сделать?" "Использовать существующий сервер и его client.conf" "Пересоздать ключи (старые клиенты этого сервера перестанут подключаться)" "Отмена"
      case $a in 2) regen=1;; 3) return 1;; esac
    else
      hint "client.conf на сервере уже удалён, без него к этому серверу не подключиться."
      choose a "Что сделать?" "Пересоздать ключи (старые клиенты перестанут подключаться)" "Отмена"
      [ "$a" = 1 ] && regen=1 || return 1
    fi
  fi
  if [ $exists = 0 ] || [ $regen = 1 ]; then
    ask AWG_PORT "UDP-порт сервера AmneziaWG" "$AWG_PORT"
    [[ "$AWG_PORT" =~ ^[0-9]+$ ]] && [ "$AWG_PORT" -ge 1024 ] && [ "$AWG_PORT" -le 65535 ] || { warn "порт должен быть 1024–65535, беру 51823"; AWG_PORT=51823; }
    mkdir -p "$WORK"
    if obf_from_main "$WORK/obf.txt"; then
      choose a "Параметры обфускации (Jc, S1, H1…) для сервера:" "Взять из основного конфига: они уже проходят через вашего провайдера" "Сгенерировать случайные"
      [ "$a" = 1 ] && obf=1
    else
      choose a "Параметры обфускации (Jc, S1, H1…) для сервера:" "Сгенерировать случайные (рекомендуется)" "Вставить 9 строк Jc…H4 из проверенного конфига"
      if [ "$a" = 2 ]; then read_paste "$WORK/obf.txt"; grep -cE '^[[:space:]]*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=' "$WORK/obf.txt" | grep -qx 9 && obf=1 || warn "нужно ровно 9 строк Jc…H4, беру случайные"; fi
    fi
  fi
  info "копирую серверные скрипты на VPS…"
  vput "$KIT/server/awg-server-build.sh" "$KIT/server/awg-server-setup.sh" "$KIT/server/audit-server.sh" || { err "scp не сработал"; return 1; }
  vssh 'chmod 700 /root/awg-server-build.sh /root/awg-server-setup.sh /root/audit-server.sh'
  if echo "$st" | grep -q BUILT && yn "amneziawg уже собран на VPS. Пропустить сборку?" Y; then :; else
    title "Сборка amneziawg на VPS (3–5 минут)"
    while :; do
      vssh "AWG_GO_REF=$AWG_GO_REF AWG_TOOLS_REF=$AWG_TOOLS_REF bash /root/awg-server-build.sh" 2>&1 | sed 's/^/    │ /'
      vssh 'command -v awg >/dev/null && command -v amneziawg-go >/dev/null' && break
      err "сборка не удалась"
      hint "Частые причины: нет места на диске VPS, нет доступа к github.com или proxy.golang.org."
      choose a "Что делать?" "Повторить" "Отмена"
      [ "$a" = 2 ] && return 1
    done
    ok "сборка на VPS готова"
  fi
  if [ $regen = 1 ]; then vssh 'systemctl stop awg-server 2>/dev/null; mv /etc/amnezia/server.conf /root/server.conf.old.$(date +%s)'; ok "старый ключ сервера сохранён в /root/server.conf.old.*"; fi
  if [ $exists = 0 ] || [ $regen = 1 ]; then
    [ -n "$obf" ] && vput "$WORK/obf.txt" && vssh 'chmod 600 /root/obf.txt'
    title "Настройка сервера на VPS"
    vssh "VPS_IP=$VPS_IP PORT=$AWG_PORT ${obf:+OBF_FILE=/root/obf.txt} bash /root/awg-server-setup.sh" 2>&1 | sed 's/^/    │ /'
    vssh 'rm -f /root/obf.txt'
  else
    AWG_PORT=$(vssh "awk -F'=' '/^ListenPort/{gsub(/ /,\"\",\$2); print \$2}' /etc/amnezia/server.conf")
    vssh 'systemctl is-active --quiet awg-server || systemctl restart awg-server'
  fi
  ( umask 077; vget /root/awgbuild/client.conf "$DD/.incoming.conf" ) || { err "не удалось забрать client.conf с VPS"; return 1; }
  if check_conf "$DD/.incoming.conf"; then mv "$DD/.incoming.conf" "$DD/$cfg"; chmod 600 "$DD/$cfg"; ok "конфиг сервера сохранён в $DD/$cfg"; else err "полученный client.conf некорректен"; return 1; fi
  vssh 'shred -u /root/awgbuild/client.conf 2>/dev/null || rm -f /root/awgbuild/client.conf' && info "копия client.conf на VPS удалена"
  env_set VPS_IP "$VPS_IP"
  warn "если у хостера есть свой файрвол (Security Groups, «Сетевой экран»), откройте в нём входящий UDP $AWG_PORT"
  return 0
}

vps_manual(){
  local cfg=$1 base; resolve_ref || return 1; base="https://raw.githubusercontent.com/$AWG_REPO/$AWG_REF/server"
  title "Ручная настройка VPS"
  say "  Выполните на VPS под root:"
  say "${C}    curl -fsSL $base/awg-server-build.sh -o /root/awg-server-build.sh"
  say "    curl -fsSL $base/awg-server-setup.sh -o /root/awg-server-setup.sh"
  say "    bash /root/awg-server-build.sh"
  say "    VPS_IP=<внешний IP VPS> bash /root/awg-server-setup.sh${N}"
  say "  Затем перенесите /root/awgbuild/client.conf на роутер:"
  say "${C}    scp root@<IP VPS>:/root/awgbuild/client.conf $DD/$cfg${N}"
  say "  и откройте UDP 51823 в файрволе хостера."
  pause "Когда конфиг будет на роутере или под рукой, нажмите Enter"
  get_conf "$cfg" "конфиг вашего VPS"
}

step_vps(){  # step_vps main.conf|backup.conf
  local cfg=$1 a
  if [ -s "$DD/$cfg" ]; then info "уже есть $DD/$cfg:"; conf_summary "$DD/$cfg"; yn "Использовать его?" Y && return 0; fi
  while :; do
    choose a "Сервер AmneziaWG на вашем VPS:" \
      "Настроить VPS автоматически по SSH с роутера (сборка, ключи, автозапуск)" \
      "Сервер уже настроен, у меня есть client.conf — передам его" \
      "Показать команды для ручной настройки VPS" \
      "Выйти"
    case $a in
      1) if ! command -v ssh >/dev/null || ! command -v scp >/dev/null; then err "на роутере нет ssh/scp"; continue; fi
         vps_setup "$cfg" && return 0;;
      2) get_conf "$cfg" "client.conf вашего VPS"; return 0;;
      3) vps_manual "$cfg"; return 0;;
      4) exit 1;;
    esac
  done
}

vps_audit(){ [ -n "$VPS_IP" ] && [ ${#SSHO[@]} -gt 0 ] && { title "Аудит VPS"; vssh 'bash /root/audit-server.sh' 2>&1 | sed 's/^/    /'; }; }

# ============================================================ PBR ==========
pbr_drift(){  # 0, если у профиля-рельсы есть правило PBR с другой меткой или таблицей, чем в awg.env
  local r m t; r=$(env_get RAIL_IF); m=$(env_get MARK); t=$(env_get TABLE)
  [ -n "$r" ] || return 1
  ip -4 rule show | awk -v r="$r" -v want="$m $t.$r" '/fwmark/ && $0 ~ ("lookup [0-9]+\\." r "[[:space:]]*$") {for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1)} if (m" "t != want) {f=1}} END{exit !f}'
}
pbr_rules(){ ip -4 rule show | awk '/fwmark/ && /lookup [0-9]+\.[a-z]+clt[0-9]+/ { prio=$1; sub(":","",prio); m=""; t=""; for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1) } split(t,a,"."); print prio, m, a[1], a[2] }'; }
make_rail(){
  [ -s "$DD/rail.conf" ] && return 0
  local rk rp; rk=$("$DD/awg" genkey); rp=$("$DD/awg" genkey | "$DD/awg" pubkey)
  ( umask 077; printf '[Interface]\nPrivateKey = %s\nAddress = 10.255.255.2/32\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 192.0.2.1:51820\n' "$rk" "$rp" > "$DD/rail.conf" )
}
step_rail(){
  title "Профиль-«рельса» и правило PBR в UniFi"
  local rules n a rail ifs
  while :; do
    rules=$(pbr_rules); n=$(printf '%s' "$rules" | grep -c .)
    if [ "$n" -ge 1 ]; then
      ok "найдено PBR-правил VPN Client: $n"
      printf '%s\n' "$rules" | awk '{printf "      профиль %s: таблица %s, метка %s, приоритет %s\n",$4,$3,$2,$1}'
      if [ "$n" = 1 ]; then
        rail=$(printf '%s' "$rules" | awk '{print $4}')
        yn "Использовать профиль $rail как рельсу?" Y || { pause "Создайте нужный профиль и правило, затем нажмите Enter"; continue; }
      else
        ifs=$(printf '%s\n' "$rules" | awk '{print $4}')
        # shellcheck disable=SC2086
        choose a "Какой профиль использовать как рельсу для AWG?" $ifs
        rail=$(printf '%s\n' "$ifs" | sed -n "${a}p")
      fi
      local oldt; oldt=$(env_get TABLE)
      "$DD/awg-detect.sh" "$rail" | sed 's/^/    /'
      if [ -n "$oldt" ] && [ "$oldt" != "$(env_get TABLE)" ]; then     # таблица сменилась: в старой не оставлять наших маршрутов
        ip route del blackhole default metric 200 table "$oldt" 2>/dev/null
        for x in $(list_tunnels); do ip route del default dev "$x" table "$oldt" 2>/dev/null; done
        info "маршруты AWG из прежней таблицы $oldt убраны"
      fi
      [ -n "$(env_get TABLE)" ] && { ok "параметры PBR записаны в $DD/awg.env"; return 0; }
      err "awg-detect.sh не смог записать параметры"; continue
    fi
    warn "правило PBR для VPN Client не найдено"
    ip -br link 2>/dev/null | grep -qE '^wgclt[0-9]' && hint "Профиль VPN Client есть ($(ip -br link | awk '/^wgclt/{print $1}' | paste -sd' ')), но на него не ссылается ни одно правило Policy-Based Route."
    make_rail
    say
    say "  ${B}Что сделать в веб-интерфейсе UniFi:${N}"
    say "  1. Скачайте фиктивный конфиг рельсы на компьютер (команда для ПК):"
    say "       ${C}scp root@$(lan_ip):$DD/rail.conf .${N}"
    say "     или скопируйте текст ниже в файл rail.conf."
    say "  2. Settings → VPN → VPN Client → Create New → WireGuard, имя AWG-rail, Upload File → rail.conf → Save."
    say "     Профиль останется «не подключён» — это нормально. ${B}Не выключайте и не удаляйте его.${N}"
    say "  3. Settings → Routing → Policy-Based Routes (в старых версиях Traffic Routes) → Create:"
    say "     Interface/VPN = AWG-rail, Source = ${B}одно тестовое устройство${N}, Destination = Any, Kill Switch = On."
    say "     ${Y}Это устройство будет без интернета, пока мастер не запустит сторожа (следующий шаг).${N}"
    say; say "${D}----- rail.conf -----${N}"; cat "$DD/rail.conf"; say "${D}---------------------${N}"
    choose a "Когда профиль и правило созданы:" "Проверить снова" "У меня уже есть обычный WireGuard-профиль — использовать его (просто создайте правило PBR)" "Выйти, продолжу позже (повторный запуск: $DD/install.sh)"
    [ "$a" = 3 ] && exit 0
  done
}

# ============================================================ сторож ======

step_watchdog(){
  title "Сторож и автозапуск"
  local t i a
  svc_active awg-failover && systemctl stop awg-failover
  cp "$DD/awg-failover.service" "$SYSD/"
  systemctl daemon-reload
  systemctl enable awg-failover >/dev/null 2>&1
  systemctl restart awg-failover
  unit_mark awg-failover
  t=$(env_get TABLE)
  info "жду, пока сторож положит маршрут в таблицу $t…"
  for i in $(seq 1 45); do
    ip route show table "$t" 2>/dev/null | grep -q "dev $MAIN .*metric 5\|dev $BACKUP_NAME .*metric 5" && ip route show table "$t" | grep -q blackhole && break
    sleep 1
  done
  if ip route show table "$t" | grep -q 'metric 5' && ip route show table "$t" | grep -q blackhole; then
    ok "таблица PBR $t:"; ip route show table "$t" | sed 's/^/      /'
    ok "служба awg-failover запущена и включена в автозапуск"
    tail -n 2 "$DD/failover.log" 2>/dev/null | sed 's/^/      /'
    [ -n "$(env_get EXTRA_SUBNETS)" ] && { svc_active awg-subnets && ok "подсети VPN-сервера ($(env_get EXTRA_SUBNETS)) обслуживает awg-subnets" || warn "подсети заданы, но служба awg-subnets не запущена: $DD/install.sh → Компоненты → Клиенты VPN-сервера"; }
    return 0
  fi
  err "маршрут в таблице $t не появился"
  systemctl status awg-failover --no-pager 2>&1 | head -n 8 | sed 's/^/    /'
  journalctl -u awg-failover -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  hint "Частые причины: нет awg.env (запустите шаг PBR заново), туннель не поднимается (см. диагностику)."
  choose a "Что делать?" "Попробовать ещё раз" "Продолжить" "Выйти"
  case $a in 1) step_watchdog; return;; 3) exit 1;; esac
}

test_switch(){
  title "Проверка переключения на запасной канал"
  local t i; t=$(env_get TABLE)
  info "имитирую падение основного канала (флаг /tmp/awg-sim-down)…"
  touch /tmp/awg-sim-down; SIM_SET=1
  for i in $(seq 1 40); do grep -q 'ПЕРЕКЛЮЧЕНИЕ' <(tail -n 3 "$DD/failover.log" 2>/dev/null) && break; sleep 1; done
  if ip route show table "$t" | grep -q "dev $BACKUP_NAME .*metric 5"; then
    ok "переключение сработало за ~${i} с: PBR-трафик идёт через $BACKUP_NAME"
  else
    err "переключения не произошло"; tail -n 5 "$DD/failover.log" | sed 's/^/    /'
    hint "Запасной канал должен отвечать: curl --interface $BACKUP_NAME https://ifconfig.me"
  fi
  rm -f /tmp/awg-sim-down; SIM_SET=""
  if yn "Вернуть основной канал сразу (перезапуск сторожа, ~5 с без PBR-трафика), а не ждать $(env_get RECOVER_SEC) с?" Y; then
    systemctl restart awg-failover; sleep 6
    ip route show table "$t" | grep -q "dev $MAIN .*metric 5" && ok "снова работает основной канал" || warn "основной ещё не вернулся, смотрите tail -f $DD/failover.log"
  else
    info "сторож вернётся на основной сам после $(env_get RECOVER_SEC) с стабильной работы"
  fi
}


# ============================================================ подсети VPN-сервера ==
# Что делает эта часть. Для каждой подсети из EXTRA_SUBNETS (awg.env) служба awg-subnets держит три вещи:
#   1) ip rule  from <подсеть> lookup main suppress_prefixlength 0   (приоритет 6100)
#        адреса, до которых есть обычный маршрут (роутер, LAN, другие VPN-подсети), остаются локальными;
#   2) ip rule  from <подсеть> lookup <ТАБЛИЦА PBR>                  (приоритет 6101)
#        всё остальное (интернет) уходит в таблицу PBR, где лежит маршрут сторожа на AWG-туннель;
#   3) маршрут  <подсеть> dev <интерфейс VPN-сервера> в таблице PBR
#        устройства LAN под PBR по-прежнему достают клиентов VPN-сервера.
# NAT (MASQUERADE на туннеле) и FORWARD уже делает сторож для любых источников.
# Правила привязаны к подсети, а не к метке UniFi: от настроек Policy-Based Routes они не зависят.
# UniFi при перепровижнинге может стереть правила, поэтому служба сверяет их каждые 5 секунд.
net_of(){  # 192.168.3.5/24 → 192.168.3.0/24
  local ip=${1%/*} p=${1#*/} a b c d n m
  IFS=. read -r a b c d <<< "$ip"
  n=$(( (a<<24)|(b<<16)|(c<<8)|d )); m=$(( (0xFFFFFFFF << (32-p)) & 0xFFFFFFFF ))
  n=$(( n & m ))
  printf '%d.%d.%d.%d/%d' $((n>>24&255)) $((n>>16&255)) $((n>>8&255)) $((n&255)) "$p"
}
norm_subnet(){  # печатает подсеть в виде адрес_сети/маска или возвращает 1
  local x=$1
  [[ $x =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || return 1
  is_ipv4 "${x%/*}" || return 1
  [ "${x#*/}" -ge 8 ] && [ "${x#*/}" -le 30 ] || return 1
  net_of "$x"
}
lan_conflict(){  # 0, если подсеть совпадает с подсетью LAN/WAN-интерфейса
  local net=$1
  ip -4 -br addr 2>/dev/null | awk '$1~/^(eth|br|switch)/ && $3 ~ /\// {print $3}' | while read -r x; do
    [ "$(net_of "$x")" = "$net" ] && { echo hit; break; }
  done | grep -q hit
}
subnet_candidates(){  # «интерфейс подсеть» для интерфейсов, похожих на VPN-серверы роутера
  local ifc adr n p
  ip -4 -br addr 2>/dev/null | awk '$1!~/^(lo|eth|br|awg|wgclt|ifb|switch|sit|ip6|gre|tun)/ && $3 ~ /\// {print $1, $3}' | while read -r ifc adr; do
    p=${adr#*/}; [ "$p" -le 30 ] 2>/dev/null || continue
    n=$(net_of "$adr") && printf '%s %s\n' "${ifc%@*}" "$n"
  done
}

legacy_subnet_check(){  # старые самодельные решения, которые делают то же самое
  local f u s
  for f in awg-keep.sh wgsrv-pbr.sh; do
    [ -f "$DD/$f" ] && warn "найден $DD/$f: скрипт другой схемы, он тоже управляет маршрутами подсетей. Две схемы одновременно не используйте."
  done
  if [ -f $SYSD/wgsrv-routing.service ] && { systemctl is-enabled --quiet wgsrv-routing 2>/dev/null || svc_active wgsrv-routing; }; then
    warn "включена ваша служба wgsrv-routing: она направляет подсеть в таблицу профиля UniFi (wgclt) и конфликтует с новой схемой."
    if yn "Отключить её (файл службы останется)?" Y; then
      systemctl disable --now wgsrv-routing >/dev/null 2>&1
      ip -4 rule show | awk '$1=="100:" && /lookup [0-9]+\.wgclt/ {print $3}' | while read -r s; do ip -4 rule del from "$s" priority 100 2>/dev/null; done
      ok "wgsrv-routing отключена"
    fi
  fi
  [ -f $SYSD/wgsrv-pbr.service ] && info "служба wgsrv-pbr добавляет подсеть в ipset UBIOS4local_network. Новой схеме она не нужна и не мешает, оставляю как есть."
}

step_subnets(){
  title "Клиенты VPN-сервера роутера через туннель"
  local cur t s x n cand good=() seen=" " l
  t=$(env_get TABLE)
  [ -n "$t" ] || { err "таблица PBR ещё не определена: сначала шаг «Профиль-рельса и правило PBR»."; return 1; }
  cur=$(env_get EXTRA_SUBNETS)
  say "  ${D}Все устройства из указанной подсети (клиенты WireGuard Server, Teleport…) будут выходить в интернет через AWG-туннель.${N}"
  say "  ${D}Обращения к самому роутеру и к локальным адресам остаются локальными. Правила привязаны к подсети, а не к настройкам PBR в UniFi.${N}"
  legacy_subnet_check
  cand=$(subnet_candidates)
  if [ -n "$cand" ]; then
    info "интерфейсы с подсетями, похожие на VPN-серверы роутера:"
    printf '%s\n' "$cand" | awk '{printf "      %-14s %s\n", $1, $2}'
  else
    hint "Подсеть указана в настройках соответствующего VPN-сервера в UniFi (раздел VPN). Пример: 192.168.3.0/24"
  fi
  ask s "Подсети через пробел (например 192.168.3.0/24), пусто — отключить" "$cur"
  for x in $s; do
    n=$(norm_subnet "$x") || { warn "«$x» не подсеть вида 192.168.3.0/24 (маска от /8 до /30), пропускаю"; continue; }
    [ "$n" != "$x" ] && info "$x → $n (беру адрес сети)"
    case "$seen" in *" $n "*) continue;; esac
    if lan_conflict "$n"; then
      warn "$n совпадает с подсетью LAN/WAN: через туннель пойдут ВСЕ её устройства, а не только клиенты VPN-сервера."
      yn "Всё равно добавить?" N || continue
    fi
    seen="$seen$n "; good+=("$n")
  done
  s="${good[*]}"
  env_set EXTRA_SUBNETS "\"$s\""
  if [ -n "$s" ]; then
    unit_on awg-subnets
    sleep 3
    svc_active awg-subnets && ok "служба awg-subnets запущена, подсети: $s" || { err "awg-subnets не запустилась: journalctl -u awg-subnets -n 20"; return 1; }
    "$DD/subnets.sh" apply
    "$DD/subnets.sh" check | while IFS= read -r l; do
      case "$l" in
        OK*)   ok "$(printf '%s' "${l#OK}" | sed 's/^ *//')";;
        WARN*) warn "$(printf '%s' "${l#WARN}" | sed 's/^ *//')";;
        FAIL*) err "$(printf '%s' "${l#FAIL}" | sed 's/^ *//')";;
        *)     info "$(printf '%s' "${l#INFO}" | sed 's/^ *//')";;
      esac
    done
    hint "Проверка с клиента: подключитесь к VPN-серверу роутера, откройте 2ip.io. Должен быть IP туннеля, а не провайдера."
    hint "Повторная проверка на роутере: $DD/subnets.sh check"
  else
    unit_off awg-subnets
    [ -x "$DD/subnets.sh" ] && "$DD/subnets.sh" remove
    ok "подсети отключены, правила убраны"
  fi
}


# ============================================================ опции =======
step_panel(){
  title "Панель при входе по SSH"
  grep -q AWGS_SHOWN $BASHRC 2>/dev/null || cat >> $BASHRC <<'RC'
alias awgs='/data/awg/status.sh'
alias awgctl='/data/awg/awgctl.sh'
alias awg-selftest='/data/awg/selftest.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
  grep -q "alias awg-setup=" $BASHRC 2>/dev/null || echo "alias awg-setup='/data/awg/install.sh'" >> $BASHRC
  touch "$DD/.panel"
  ok "панель будет появляться при входе по SSH; вручную — команда awgs"
  if [ -s /etc/motd ] && yn "Убрать стандартный баннер UniFi при входе (оригинал сохраню в $DD/motd.orig)?" Y; then
    [ -f "$DD/motd.orig" ] || cp -a /etc/motd "$DD/motd.orig"
    : > /etc/motd; touch /root/.hushlogin
    cp "$DD/awg-motd.service" "$SYSD/"; systemctl daemon-reload; systemctl enable awg-motd >/dev/null 2>&1; unit_mark awg-motd
    ok "баннер убран, после перезагрузки тоже"
  fi
}
step_audit(){
  title "Аудит"
  grep -q "alias awg-audit=" $BASHRC 2>/dev/null || echo "alias awg-audit='/data/awg/audit.sh'" >> $BASHRC
  touch "$DD/.audit"
  ok "команда awg-audit (в новом окне SSH); запускаю сейчас:"
  "$DD/audit.sh" | sed 's/^/  /'
}

tg_api(){  # tg_api МЕТОД [аргументы curl] — запрос к Telegram через туннели, затем WAN
  local m=$1 i r; shift
  for i in $MAIN $(env_get BACKUP) ""; do
    r=$(printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TG_TOKEN" "$m" | curl -4 -s -m 12 ${i:+--interface $i} -K - "$@" 2>/dev/null)
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  done
  return 1
}

# Команды и без интерактивной оболочки (ssh роутер awgctl status, plink, cron): алиасы из .bashrc там не читаются.
# Ссылки в /usr/local/bin; чужой файл с тем же именем не трогаем. После обновления прошивки их вернёт awg-restore.sh.
ensure_links(){
  local a l bd=${AWG_BINDIR:-/usr/local/bin}
  [ -d "$bd" ] && [ -w "$bd" ] || return 0
  for a in "awgctl=$DD/awgctl.sh" "awg-selftest=$DD/selftest.sh" "awgs=$DD/status.sh"; do
    l=$bd/${a%%=*}
    { [ -L "$l" ] || ! [ -e "$l" ]; } && ln -sfn "${a#*=}" "$l" 2>/dev/null
  done
  return 0
}

step_telegram(){
  title "Уведомления в Telegram"
  local a r chat t
  say "  1. В Telegram: @BotFather → /newbot → получите токен. Лучше отдельный бот только для роутера."
  say "  2. Откройте нового бота и нажмите Start."
  if [ -s "$DD/telegram.env" ]; then info "telegram.env уже есть"; yn "Оставить текущий токен и chat id?" Y && { . "$DD/telegram.env"; } fi
  while [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; do
    read_secret TG_TOKEN "Токен бота (ввод не отображается)"
    [[ "$TG_TOKEN" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]] || { err "это не похоже на токен вида 123456789:AA…"; TG_TOKEN=; continue; }
    r=$(tg_api getMe) || { err "Telegram недоступен ни через туннели, ни через WAN"; choose a "Что делать?" "Повторить" "Пропустить Telegram"; [ "$a" = 2 ] && return; TG_TOKEN=; continue; }
    echo "$r" | grep -q '"ok":true' || { err "Telegram отверг токен (неверный или отозван)"; TG_TOKEN=; continue; }
    ok "бот: @$(echo "$r" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)"
    choose a "Chat id:" "Определить автоматически (напишите боту любое сообщение)" "Ввести вручную (узнать у @userinfobot)"
    if [ "$a" = 1 ]; then
      pause "Напишите своему боту сообщение в Telegram, затем нажмите Enter"
      r=$(tg_api getUpdates)
      if echo "$r" | grep -q '"error_code":409'; then
        warn "этот бот уже читается другой программой (409 Conflict) — значит, бот не отдельный. Введите chat id вручную."
      else
        chat=$(echo "$r" | grep -o '"chat":{"id":-\?[0-9]*' | tail -1 | grep -o -- '-\?[0-9]*$')
      fi
      [ -n "$chat" ] && ok "chat id: $chat" || warn "сообщение не найдено"
    fi
    [ -z "$chat" ] && ask chat "Ваш chat id (число)" ""
    [[ "$chat" =~ ^-?[0-9]+$ ]] || { err "chat id — это число"; chat=; TG_TOKEN=; continue; }
    TG_CHAT=$chat
  done
  ask t "Время суточного отчёта ЧЧММ (по часам роутера, сейчас $(date +%H:%M))" "${REPORT_TIME:-0900}"
  [[ "$t" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]] || { warn "формат ЧЧММ, ставлю 0900"; t=0900; }
  ( umask 077; printf 'TG_TOKEN=%s\nTG_CHAT=%s\nREPORT_TIME=%s\n' "$TG_TOKEN" "$TG_CHAT" "$t" > "$DD/telegram.env" )
  yn "Слать напрямую через провайдера, если оба туннеля недоступны (иначе сообщение отложится)?" Y || echo "TG_NO_WAN=1" >> "$DD/telegram.env"
  unset TG_TOKEN
  info "отправляю тестовое сообщение…"
  if "$DD/awg-notify.sh" test | grep -q отправлено; then ok "тест доставлен"; else
    err "тест не доставлен"; tail -n 3 "$DD/notify.log" 2>/dev/null | sed 's/^/    /'
    hint "HTTP 400 — не нажат Start у бота; 401 — неверный токен; 000 — Telegram недоступен."
  fi
  cp "$DD/awg-notify.service" "$SYSD/"; systemctl daemon-reload
  systemctl enable awg-notify >/dev/null 2>&1; systemctl restart awg-notify; unit_mark awg-notify
  svc_active awg-notify && ok "служба awg-notify запущена (события, контроль раз в минуту, отчёт в ${t:0:2}:${t:2:2})" || err "awg-notify не запустилась: journalctl -u awg-notify -n 20"
}

# ============================================================ службы и манифест =====
# Список включённых служб ведём в $DD/.units: по нему awg-restore.sh возвращает службы после обновления прошивки.
unit_mark(){ grep -qx "$1" "$DD/.units" 2>/dev/null || echo "$1" >> "$DD/.units"; }
unit_unmark(){ [ -f "$DD/.units" ] && { grep -vx "$1" "$DD/.units" > "$DD/.units.t"; mv "$DD/.units.t" "$DD/.units"; }; return 0; }
unit_on(){   # включить и запустить службу, запомнить для восстановления
  [ -f "$DD/$1.service" ] || { err "нет $DD/$1.service"; return 1; }
  cp "$DD/$1.service" "$SYSD/$1.service"; systemctl daemon-reload
  systemctl enable "$1" >/dev/null 2>&1; systemctl restart "$1"; unit_mark "$1"
}
unit_off(){ systemctl disable --now "$1" >/dev/null 2>&1; rm -f "$SYSD/$1.service"; systemctl daemon-reload; unit_unmark "$1"; }
show_check(){  # показать вывод проверки вида «OK/WARN/FAIL/INFO текст» (stdin) в стиле установщика
  local l
  while IFS= read -r l; do
    case "$l" in
      OK*)   ok "$(printf '%s' "${l#OK}" | sed 's/^ *//')";;
      WARN*) warn "$(printf '%s' "${l#WARN}" | sed 's/^ *//')";;
      FAIL*) err "$(printf '%s' "${l#FAIL}" | sed 's/^ *//')";;
      INFO*) info "$(printf '%s' "${l#INFO}" | sed 's/^ *//')";;
      *)     [ -n "$l" ] && info "$l";;
    esac
  done
}
conf_of(){ case "$1" in "$MAIN") echo main.conf;; "$BACKUP_NAME") echo backup.conf;; *) echo "$1.conf";; esac; }
valid_domain(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
list_tunnels(){ echo "$MAIN $(env_get BACKUP) $(env_get TUNNELS_EXTRA)" | tr -s ' ' '\n' | grep -v '^$'; }

write_manifest(){
  ( cd "$DD" && sha256sum ./*.sh ./*.service ./server/*.sh ./web/panel.py ./web/awgweb/*.py ./web/static/* 2>/dev/null | sed 's#\./##' > .manifest ); chmod 600 "$DD/.manifest" 2>/dev/null
}
do_verify(){
  title "Проверка файлов установки"
  [ -f "$DD/.manifest" ] || die "нет $DD/.manifest: установка не выполнялась этим установщиком (или версия старее 1.2)."
  local sum f cur bad=0 n=0
  while read -r sum f; do
    n=$((n+1))
    if [ ! -f "$DD/$f" ]; then say "  нет файла $f"; bad=$((bad+1)); continue; fi
    cur=$(sha256sum "$DD/$f" | cut -d' ' -f1)
    if [ "$cur" != "$sum" ]; then say "  изменён $f"; bad=$((bad+1)); fi
    case "$f" in *.sh) bash -n "$DD/$f" 2>/dev/null || { say "  синтаксическая ошибка $f"; bad=$((bad+1)); };; esac
  done < "$DD/.manifest"
  for f in main.conf backup.conf client.conf telegram.env awg.env; do
    [ -e "$DD/$f" ] && [ "$(stat -c %a "$DD/$f")" != 600 ] && { say "  права $f: $(stat -c %a "$DD/$f") (нужно 600)"; bad=$((bad+1)); }
  done
  if [ $bad = 0 ]; then ok "все $n файлов совпадают с манифестом, синтаксис в порядке"; else
    warn "расхождений: $bad. Если вы правили файлы сами — это нормально; «$DD/install.sh --update» вернёт файлы из набора."
    return 1
  fi
}
do_selfupdate(){
  title "Обновление самого установщика"
  [ -n "$AWG_REPO" ] || die "не задан репозиторий (переменная AWG_REPO в начале install.sh)."
  local base tmp="$WORK/install.new" want have newv
  resolve_ref || die "не удалось определить версию для скачивания"
  base="https://raw.githubusercontent.com/$AWG_REPO/$AWG_REF"
  mkdir -p "$WORK"
  curl -fsSL -m 60 "$base/install.sh" -o "$tmp" || die "не удалось скачать $base/install.sh"
  bash -n "$tmp" || die "скачанный файл не проходит проверку синтаксиса"
  newv=$(sed -n 's/^INSTALLER_VERSION=//p' "$tmp" | head -n1)
  info "сейчас: $INSTALLER_VERSION, в репозитории: ${newv:-?}"
  have=$(sha256sum "$tmp" | cut -d' ' -f1)
  want=$(curl -fsSL -m 30 "$base/install.sh.sha256" 2>/dev/null | awk '{print $1; exit}')
  if [ -n "$want" ]; then
    [ "$want" = "$have" ] && ok "контрольная сумма sha256 совпала" || die "контрольная сумма НЕ совпала (ожидалась $want, получена $have): файл не устанавливаю."
  else
    warn "файла install.sh.sha256 в репозитории нет: целостность проверить нечем."
    yn "Установить без проверки контрольной суммы?" N || return 1
  fi
  [ "$newv" = "$INSTALLER_VERSION" ] && ! yn "Версия та же. Всё равно заменить?" N && return 0
  chmod 755 "$tmp" && mv -f "$tmp" "$DD/install.sh" && ok "установщик обновлён: $DD/install.sh (${newv:-?})"
  write_manifest
  hint "Чтобы обновить и скрипты управления: $DD/install.sh --update"
}

# ============================================================ предпросмотр =====
plan(){
  title "Предпросмотр: что есть на роутере и что сделает мастер (ничего не меняется)"
  local arch model fw c miss=() dfree n t u
  arch=$(uname -m); [ "$arch" = aarch64 ] && ok "архитектура $arch" || err "архитектура $arch: бинарники только под aarch64"
  model=$(ubnt-device-info model 2>/dev/null); fw=$(ubnt-device-info firmware 2>/dev/null)
  info "модель: ${model:-?}, UniFi OS: ${fw:-?}"
  [ -c /dev/net/tun ] && ok "/dev/net/tun есть" || warn "/dev/net/tun нет (мастер попробует создать)"
  for c in curl ip iptables ipset awk sed tar systemctl sha256sum timeout; do command -v "$c" >/dev/null || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] && ok "обязательные команды на месте" || err "нет команд: ${miss[*]}"
  for c in conntrack ss pidof openssl python3 tcpdump ssh ip6tables dig; do command -v "$c" >/dev/null && info "есть $c" || info "нет $c (нужен для отдельных функций)"; done
  dfree=$(df -Pm /data 2>/dev/null | awk 'NR==2{print $4}'); info "место на /data: ${dfree:-?} МБ"
  curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null && ok "github.com доступен" || warn "github.com недоступен с роутера"
  say; say "  ${B}Текущая установка${N}"
  if [ -f "$DD/awg.env" ]; then
    info "найдена: $DD (версия набора $(cat "$DD/VERSION" 2>/dev/null || echo ?)), туннели: $(list_tunnels | tr '\n' ' ')"
    for u in awg-failover awg-subnets awg-self awg-guard awg-notify awg-bot awg-metrics awg-ha; do
      [ -f "$SYSD/$u.service" ] && info "служба $u: $(systemctl is-active $u 2>/dev/null)"
    done
    n=$(pbr_rules | grep -c .); info "PBR-правил VPN Client: $n; таблица $(env_get TABLE), метка $(env_get MARK)"
    [ -n "$(env_get EXTRA_SUBNETS)" ] && info "подсети VPN-сервера: $(env_get EXTRA_SUBNETS)"
  else info "установки нет: мастер начнёт с нуля"; fi
  say; say "  ${B}Что сделает мастер${N}"
  say "   1. проверит роутер; выберет сценарий A (туннель провайдера), B (свой VPS) или C (основной + запасной)"
  say "   2. возьмёт скрипты (из папки или GitHub), установит бинарники AmneziaWG и ваши конфиги в $DD (права 600)"
  say "   3. при необходимости настроит VPS по SSH (сборка, ключи, автозапуск)"
  say "   4. определит таблицу и метку PBR (профиль-«рельса» создаёте вы в UniFi)"
  say "   5. запустит сторожа awg-failover (маршрут в таблицу PBR, kill switch, NAT) и проверит переключение"
  say "   6. по вашему выбору: подсети VPN-сервера, качество канала, защита от утечек, awg-self, домены, MTU, панель, аудит, Telegram, бот, метрики"
  say "   7. запустит самопроверку"
  say "  ${D}Мастер задаёт вопросы по ходу. Ответы можно записать (--record ФАЙЛ) и повторить на другом роутере (--answers ФАЙЛ).${N}"
}

# ============================================================ новые шаги =====
need_pbr(){ [ -n "$(env_get TABLE)" ] && [ -n "$(env_get MARK)" ] || { err "не определены таблица и метка PBR: сначала шаг «Профиль-рельса и правило PBR» (Компоненты → Туннели → Заново определить PBR)."; return 1; }; }

step_quality(){
  title "Переключение по качеству канала"
  local n q l r
  n=$(list_tunnels | grep -c .)
  if [ "$n" -lt 2 ]; then info "туннель один: переключаться некуда. Пункт пригодится после добавления запасного или дополнительного туннеля."; return 0; fi
  say "  ${D}Сторож раз в 30 с меряет потери и задержку активного канала (ping через туннель). Если 3 пробы подряд хуже порога и есть здоровый канал,${N}"
  say "  ${D}сторож переключается на него. Возврат на приоритетный канал — после RECOVER_SEC стабильной работы. Если ICMP через туннель не ходит, качество не оценивается.${N}"
  if yn "Включить переключение по качеству?" Y; then q=yes; else q=no; fi
  env_set QUALITY "$q"
  if [ "$q" = yes ]; then
    ask l "Порог потерь, % (с него канал считается плохим)" "$(env_get QUALITY_LOSS)"; [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" -ge 5 ] && [ "$l" -le 100 ] || l=40
    ask r "Порог задержки, мс (0 — задержку не учитывать)" "$(env_get QUALITY_RTT)"; [[ "$r" =~ ^[0-9]+$ ]] || r=0
    env_set QUALITY_LOSS "$l"; env_set QUALITY_RTT "$r"
  fi
  systemctl restart awg-failover; sleep 3
  ok "качество: $q$( [ "$q" = yes ] && echo ", потери ≥ ${l}%$( [ "$r" -gt 0 ] && echo ", RTT ≥ ${r} мс")")"
  hint "Состояние: awgctl status; события: awgctl events"
}

step_extra_tunnel(){
  title "Дополнительный туннель"
  need_pbr || return 1
  local name cur a
  cur=$(env_get TUNNELS_EXTRA)
  say "  ${D}Третий и далее туннели идут по приоритету после основного и запасного. Конфиг сохраняется как $DD/<имя>.conf.${N}"
  say "  ${D}Панель awgs, awg-audit, уведомления, awgctl status и метрики показывают все туннели.${N}"
  ask name "Имя интерфейса (awg + латиница/цифры)" "awgalt$(( $(echo "$cur" | wc -w) + 1 ))"
  [[ "$name" =~ ^awg[a-z0-9]{1,10}$ ]] || { err "имя должно начинаться с awg, затем 1–10 строчных латинских букв или цифр"; return 1; }
  case " $(list_tunnels | tr '\n' ' ') " in *" $name "*) err "туннель $name уже есть"; return 1;; esac
  get_conf "$name.conf" "конфиг дополнительного туннеля" || return 1
  env_set TUNNELS_EXTRA "\"${cur:+$cur }$name\""          # up.sh поднимает только туннели из awg.env
  if ! bring_up_and_test "$name" "дополнительный туннель"; then
    if yn "Туннель не работает. Всё равно оставить его в списке (сторож не будет на него переключаться, пока он не отвечает)?" N; then :
    else env_set TUNNELS_EXTRA "\"$cur\""; ip link del "$name" 2>/dev/null; "$DD/failover.sh" forget "$name"; info "не добавлен (конфиг $DD/$name.conf оставлен)"; return 1; fi
  fi
  svc_active awg-failover && { systemctl restart awg-failover; sleep 3; }
  ok "добавлен $name. Порядок приоритета: $(list_tunnels | tr '\n' ' ')"
}
remove_extra_tunnel(){
  local cur t a opts=()
  cur=$(env_get TUNNELS_EXTRA); [ -n "$cur" ] || { info "дополнительных туннелей нет"; return 0; }
  for t in $cur; do opts+=("$t"); done
  choose a "Какой туннель убрать?" "${opts[@]}" "Отмена"
  [ "$a" -gt ${#opts[@]} ] && return 0
  t=${opts[$((a-1))]}
  env_set TUNNELS_EXTRA "\"$(echo " $cur " | sed "s/ $t / /" | xargs)\""
  svc_active awg-failover && { systemctl restart awg-failover; sleep 3; }
  ip link del "$t" 2>/dev/null; "$DD/failover.sh" forget "$t"
  ok "$t убран вместе с его правилами iptables (конфиг $DD/$t.conf оставлен)"
}

step_guard(){
  title "Защита от утечек (awg-guard)"
  need_pbr || return 1
  local v6
  say "  ${D}Основная защита — blackhole в таблице PBR: при падении туннелей трафик не уходит в WAN. awg-guard добавляет вторую линию:${N}"
  say "  ${D}пакеты с меткой PBR не выпускаются в WAN, даже если UniFi сотрёт маршруты. IPv6 помеченного трафика и IPv6 клиентов VPN-сервера блокируется.${N}"
  if yn "Включить защиту от утечек?" Y; then
    env_set LEAK_GUARD yes
    if yn "Блокировать IPv6 для трафика под PBR и клиентов VPN-сервера?" Y; then v6=block; else v6=off; fi
    env_set LEAK_V6 "$v6"
  else env_set LEAK_GUARD no; env_set LEAK_V6 off; fi
  unit_on awg-guard; sleep 7
  "$DD/guard.sh" check | show_check
  hint "Проверка: $DD/guard.sh check; полная самопроверка: awgctl selftest"
}

step_self(){
  title "Трафик самого роутера и unifi.ui.com через туннель (awg-self)"
  need_pbr || return 1
  local c d dns all miss=()
  say "  ${D}1) Соединения самого роутера повторяют ваши Traffic Routes UniFi (правила без Kill Switch), как и клиенты LAN.${N}"
  say "  ${D}2) Исправление unifi.ui.com из РФ: домены ui.com резолвятся через DNS-сервер по туннелю (иначе geo-DNS отдаёт заглушку 451),${N}"
  say "  ${D}   а связь консоли с облаком Ubiquiti идёт через туннель. Остальной DNS не меняется.${N}"
  for c in ipset iptables conntrack ss curl pidof; do command -v "$c" >/dev/null || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] || { err "нет команд: ${miss[*]}"; return 1; }
  if yn "Включить исправление unifi.ui.com?" Y; then
    env_set UI_FIX yes
    ask d "Домены через DNS туннеля" "$(env_get UI_DOMAINS)"
    local x okd=""; for x in $d; do valid_domain "$x" && okd="$okd $x" || warn "«$x» не домен, пропускаю"; done; d=${okd# }; [ -n "$d" ] || d=ui.com
    ask dns "DNS-сервер для этих доменов (запросы к нему идут через туннель)" "$(env_get UI_DNS)"; is_ipv4 "$dns" || dns=9.9.9.9
    env_set UI_DOMAINS "\"$d\""; env_set UI_DNS "$dns"
  else env_set UI_FIX no; fi
  if yn "Весь DNS роутера пускать через туннель (скрывает от провайдера имена сайтов; эксперимент)?" N; then all=yes; else all=no; fi
  env_set DNS_ALL_TUNNEL "$all"
  svc_active awg-failover || warn "awg-failover не запущен: маршрута в туннель может не быть"
  unit_on awg-self
  info "жду применения правил и перезапуска dnsmasq (до 15 с)…"; sleep 15
  "$DD/self.sh" reconnect | sed 's/^/    /'
  sleep 5
  "$DD/self.sh" check | show_check
  hint "Если в UniFi вручную создан Forward Domain ui.com или PBR для 9.9.9.9 — их можно удалить: служба делает то же самое сама."
  hint "Повторная проверка: $DD/self.sh check"
}
disable_self(){ unit_off awg-self; [ -x "$DD/self.sh" ] && "$DD/self.sh" remove; ok "awg-self выключен, правила и файл dnsmasq убраны"; }

step_domains(){
  title "Домены через туннель и исключения"
  need_pbr || return 1
  local td tc dd ds x n good
  say "  ${D}Домены через туннель: клиенты LAN открывают эти сайты через AWG, остальное — как обычно (удобно для сервисов, закрытых по региону).${N}"
  say "  ${D}Исключения: клиенты под PBR ходят на эти домены/подсети напрямую (банки, госсервисы, локальные ресурсы).${N}"
  say "  ${D}Работает, пока клиенты спрашивают DNS у роутера: адреса доменов собирает dnsmasq. Браузерный DoH/«безопасный DNS» и частный DNS на телефоне это ломают.${N}"
  if ! svc_active awg-self; then
    info "для этого нужна служба awg-self (она подключает списки к dnsmasq)"
    yn "Включить awg-self без исправления ui.com?" Y || return 0
    grep -q '^UI_FIX=' "$DD/awg.env" || { env_set UI_FIX no; env_set UI_DOMAINS '"ui.com"'; env_set UI_DNS 9.9.9.9; }
    unit_on awg-self
  fi
  ask td "Домены ЧЕРЕЗ ТУННЕЛЬ через пробел (пусто — нет)" "$(env_get TUN_DOMAINS)"
  good=""; for x in $td; do valid_domain "$x" && good="$good $x" || warn "«$x» не домен, пропускаю"; done; td=${good# }
  if [ -n "$td" ]; then
    ask tc "Какие клиенты (IP или подсети через пробел; пусто — вся LAN)" "$(env_get TUN_CLIENTS)"
    good=""
    for x in $tc; do
      if [[ $x == */* ]]; then n=$(norm_subnet "$x") && good="$good $n" || warn "«$x» не подсеть (маска /8–/30), пропускаю"
      else is_ipv4 "$x" && good="$good $x" || warn "«$x» не адрес, пропускаю"; fi
    done
    tc=${good# }
  else tc=""; fi
  ask dd "Домены-ИСКЛЮЧЕНИЯ (напрямую) через пробел (пусто — нет)" "$(env_get DIRECT_DOMAINS)"
  good=""; for x in $dd; do valid_domain "$x" && good="$good $x" || warn "«$x» не домен, пропускаю"; done; dd=${good# }
  ask ds "Подсети-ИСКЛЮЧЕНИЯ через пробел, например 10.99.0.0/16 (пусто — нет)" "$(env_get DIRECT_SUBNETS)"
  good=""; for x in $ds; do n=$(norm_subnet "$x") && good="$good $n" || warn "«$x» не подсеть (маска /8–/30), пропускаю"; done; ds=${good# }
  env_set TUN_DOMAINS "\"$td\""; env_set TUN_CLIENTS "\"$tc\""; env_set DIRECT_DOMAINS "\"$dd\""; env_set DIRECT_SUBNETS "\"$ds\""
  grep -q '^LEAK_GUARD=' "$DD/awg.env" || env_set LEAK_GUARD yes
  unit_on awg-guard; systemctl restart awg-self
  info "жду применения правил и перезапуска dnsmasq (до 15 с)…"; sleep 15
  "$DD/guard.sh" check | grep -E '^(OK|WARN|FAIL|INFO)' | show_check
  [ -n "$td" ] && hint "Проверка с клиента: откройте один из доменов ($td) и посмотрите внешний IP на 2ip.io в том же браузере."
  hint "Адреса появляются после DNS-запроса клиента: сразу после включения откройте сайт заново или очистите DNS-кэш устройства."
}

step_bot(){
  title "Команды и оповещения в Telegram (awg-bot)"
  [ -s "$DD/telegram.env" ] || { warn "сначала настройте Telegram (Компоненты → Сервисы → Telegram): бот использует тот же токен и chat id."; return 1; }
  say "  ${D}Бот с кнопками: состояние, каналы и переключение (с подтверждением), события, статистика, проверки, роутер, клиенты, тишина уведомлений.${N}"
  say "  ${D}Отвечает только своим чатам: TG_CHAT — администраторы, TG_VIEWERS — только просмотр (добавляются в веб-панели: Настройки → Telegram).${N}"
  say "  ${D}Дополнительно шлёт: проблемы роутера (место, память, процессор, температура), остановка служб, пропавшая подсеть VPN-сервера, недельный отчёт.${N}"
  say "  ${D}Бот читает сообщения (getUpdates): токен не должен использоваться ещё какой-либо программой, иначе Telegram вернёт 409.${N}"
  yn "Включить бота?" Y || return 0
  unit_on awg-bot; sleep 3
  svc_active awg-bot && ok "служба awg-bot запущена (первые 25 с после старта бот молчит). Напишите боту /help" || err "awg-bot не запустилась: journalctl -u awg-bot -n 20"
}

step_metrics(){
  title "Экспорт метрик (Prometheus)"
  local p ip
  say "  ${D}Каждые 15 с обновляется файл $DD/metrics/metrics (туннели, handshake, трафик, потери/RTT, события, службы).${N}"
  say "  ${D}По желанию он отдаётся по HTTP на LAN-адресе роутера (нужен python3). Из интернета порт недоступен, не открывайте его.${N}"
  ask p "Порт HTTP (пусто — только файл)" "$(env_get METRICS_PORT)"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || p=""
  env_set METRICS_PORT "$p"
  unit_on awg-metrics; sleep 3
  ip=$(lan_ip)
  svc_active awg-metrics && ok "awg-metrics запущена${p:+: http://$ip:$p/metrics}" || err "awg-metrics не запустилась: journalctl -u awg-metrics -n 20"
  [ -z "$p" ] && hint "Файл: $DD/metrics/metrics (для node_exporter textfile)"
}

web_url(){
  local p b t
  p=$(sed -n 's/^WEB_PORT=//p' "$DD/web/web.conf" 2>/dev/null); b=$(sed -n 's/^WEB_BIND=//p' "$DD/web/web.conf" 2>/dev/null)
  t=$(sed -n 's/^WEB_TLS=//p' "$DD/web/web.conf" 2>/dev/null)
  [ -z "$b" ] || [ "$b" = auto ] && b=$(lan_ip)
  echo "$([ "${t:-yes}" = no ] && echo http || echo https)://$b:${p:-4443}/"
}
port_busy(){ ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }
step_web(){
  title "Веб-панель управления"
  command -v python3 >/dev/null || { err "на роутере нет python3: панель не запустится. Проверьте: python3 --version"; return 1; }
  [ -f "$DD/web/panel.py" ] || { get_kit; install_files; }
  say "  ${D}Панель в стиле UniFi: состояние каналов, схема, графики, туннели (тест, переключение, конфиги), домены и исключения,${N}"
  say "  ${D}инструменты (диагностика, MTU, проверка домена), журналы, Telegram, службы, резервные копии, пользователи и 2FA.${N}"
  say "  ${D}Слушает только LAN-адрес роутера ($(lan_ip)), HTTPS с самоподписанным сертификатом; из интернета недоступна.${N}"
  local p cur u pw pw2
  cur=$(sed -n 's/^WEB_PORT=//p' "$DD/web/web.conf" 2>/dev/null)
  while :; do
    ask p "Порт панели" "${cur:-4443}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then err "порт — число 1024–65535"; continue; fi
    case $p in 8443|8080|8880|8843|6789|3478|10001|5514|11443|1900|8444|5671|5656|9543) err "порт $p занят службами UniFi, выберите другой"; continue;; esac
    if port_busy "$p" && ! { svc_active awg-web && [ "$p" = "$cur" ]; }; then err "порт $p уже занят: $(ss -ltnpH 2>/dev/null | grep -E "[:.]$p " | head -1 | awk '{print $NF}')"; continue; fi
    break
  done
  mkdir -p "$DD/web"; chmod 700 "$DD/web"
  if [ -f "$DD/web/web.conf" ]; then
    if grep -q '^WEB_PORT=' "$DD/web/web.conf"; then sed -i "s/^WEB_PORT=.*/WEB_PORT=$p/" "$DD/web/web.conf"; else echo "WEB_PORT=$p" >> "$DD/web/web.conf"; fi
  else
    printf '# настройки веб-панели (после изменения: systemctl restart awg-web)\nWEB_PORT=%s\nWEB_BIND=auto\nWEB_TLS=yes\nWEB_ALLOW="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8"\n# WEB_HOSTS="udr.local"   имена, по которым открывается панель (кроме IP)\n' "$p" > "$DD/web/web.conf"
  fi
  chmod 600 "$DD/web/web.conf"
  if [ -s "$DD/web/users.json" ] && [ "$(python3 "$DD/web/panel.py" users 2>/dev/null | wc -l)" -gt 0 ]; then
    info "пользователи панели: $(python3 "$DD/web/panel.py" users | awk '{print $1}' | tr '\n' ' ')"
    yn "Сменить пароль?" N && python3 "$DD/web/panel.py" passwd "$(python3 "$DD/web/panel.py" users | awk 'NR==1{print $1}')"
  else
    ask u "Имя администратора" "admin"
    while :; do
      read -rsp "  Пароль (не короче 10 символов): " pw < /dev/tty; echo
      read -rsp "  Повторите: " pw2 < /dev/tty; echo
      [ "$pw" = "$pw2" ] || { err "пароли не совпадают"; continue; }
      printf '%s\n' "$pw" | python3 "$DD/web/panel.py" passwd "$u" --stdin && break
    done
    pw=""; pw2=""
  fi
  if [ ! -s "$DD/web/cert.pem" ]; then python3 "$DD/web/panel.py" cert >/dev/null 2>&1 && ok "сертификат HTTPS создан (самоподписанный: браузер предупредит один раз)"; fi
  unit_on awg-web; sleep 3
  if svc_active awg-web; then ok "панель запущена: ${B}$(web_url)${N}"; hint "Браузер покажет предупреждение о сертификате: это ваш самоподписанный, нажмите «Дополнительно → Перейти»."
  else err "awg-web не запустилась: journalctl -u awg-web -n 20"; fi
}

step_mtu(){
  title "Подбор MTU"
  command -v ping >/dev/null || { err "нет ping"; return 1; }
  say "  ${D}Меряется максимальный пакет без фрагментации до сервера через WAN (DF-ping) и вычитаются накладные расходы AmneziaWG. Нужен ICMP на пути.${N}"
  "$DD/mtu.sh" 2>&1 | sed 's/^/    /'
  yn "Применить рекомендованные значения (конфиги сохраняются в *.pre-mtu.*, туннели перезапустятся)?" N || return 0
  "$DD/mtu.sh" --apply 2>&1 | sed 's/^/    /'
  svc_active awg-failover && { sleep 5; systemctl restart awg-failover; }
}

step_boot_hook(){
  title "Автовосстановление после обновления прошивки"
  say "  ${D}После обновления прошивки UniFi может стереть /etc (юниты служб) и /root (панель). Восстановить вручную: $DD/install.sh --restore.${N}"
  say "  ${D}Чтобы это делалось само, нужен запуск скриптов при загрузке. UniFi OS из коробки такой возможности не даёт; её дают сторонние решения${N}"
  say "  ${D}(on-boot-script из проекта unifi-utilities/unifios-utilities, «udm-boot»), читающие /data/on_boot.d. Для UDR7 с UniFi OS 5 это НЕ проверено.${N}"
  mkdir -p "$BOOT_D"
  cat > "$BOOT_D/10-awg-restore.sh" <<EOF
#!/bin/sh
# Возврат служб AmneziaWG после обновления прошивки (создан install.sh). Ничего не делает, если всё на месте.
sleep 30
exec $DD/awg-restore.sh --if-needed >> $DD/restore.log 2>&1
EOF
  chmod 755 "$BOOT_D/10-awg-restore.sh"
  ok "создан $BOOT_D/10-awg-restore.sh (сработает, если на роутере есть обработчик on_boot.d)"
  if [ -x /usr/bin/udm-boot ] || systemctl list-unit-files 2>/dev/null | grep -q '^udm-boot'; then ok "обработчик on_boot.d найден (udm-boot)"; else
    warn "обработчика on_boot.d на роутере не найдено: файл создан, но сам по себе не запустится."
    hint "Варианты: установить on-boot-script (github.com/unifi-utilities/unifios-utilities) либо после обновления прошивки выполнять $DD/install.sh --restore."
  fi
  touch "$DD/.boothook"
}

do_backup_menu(){
  local a f
  while :; do
    choose a "Резервные копии настроек (шифруются паролем, openssl AES-256):" "Создать копию" "Список копий" "Проверить копию (пароль и целостность)" "Восстановить из копии" "Создать незашифрованную копию (небезопасно)" "Назад"
    case $a in
      1) "$DD/backup.sh" create;;
      2) "$DD/backup.sh" list;;
      3) ask f "Файл копии (имя из списка или путь)" ""; [ -n "$f" ] && "$DD/backup.sh" verify "$f";;
      4) ask f "Файл копии (имя из списка или путь)" ""; [ -n "$f" ] && { warn "Текущие настройки будут заменены (их копия сохранится в $DD/backups/pre-restore-*)."; yn "Продолжить?" N && "$DD/backup.sh" restore "$f" && yn "Сразу восстановить службы и правила (install.sh --restore)?" Y && do_restore; };;
      5) warn "Копия будет содержать ключи в открытом виде."; yn "Всё равно создать?" N && "$DD/backup.sh" create --plain;;
      6) return;;
    esac
  done
}

# ---------- VPS: защита и смена ключей ----------
vps_harden(){
  title "Защита VPS"
  vps_connect || return 1
  local st du df2 sk ssh_keys=0 up f2b pwd_auth r k
  vput "$KIT/server/vps-harden.sh" || { err "не удалось передать скрипт на VPS"; return 1; }
  st=$(vssh 'HARDEN_MODE=report bash /root/vps-harden.sh' 2>/dev/null)
  say "  ${B}Состояние сервера${N}"
  printf '%s\n' "$st" | sed 's/^/    /'
  up=$(echo "$st" | sed -n 's/^UNATTENDED_UPGRADES=//p'); f2b=$(echo "$st" | sed -n 's/^FAIL2BAN=\([a-z]*\).*/\1/p')
  pwd_auth=$(echo "$st" | sed -n 's/^SSH_PASSWORD_AUTH=//p'); ssh_keys=$(echo "$st" | sed -n 's/^AUTHORIZED_KEYS=//p')
  du=0; df2=0; sk=0
  [ "$up" = yes ] && info "автообновления безопасности уже включены" || { yn "Включить автоматические обновления безопасности (unattended-upgrades)?" Y && du=1; }
  [ "$f2b" = yes ] && info "fail2ban уже установлен" || { yn "Установить fail2ban (защита SSH от перебора паролей)?" Y && df2=1; }
  if [ "$pwd_auth" = yes ]; then
    if [ ! -f "$RKEY" ] || ! vssh "grep -qF '$(cut -d' ' -f2 "$RKEY.pub" 2>/dev/null)' ~/.ssh/authorized_keys" 2>/dev/null; then
      say "  ${D}После отключения пароля установщик сможет заходить на VPS (диагностика, смена ключей) только по ключу роутера.${N}"
      yn "Добавить ключ роутера на VPS?" Y && router_key_to_vps
    fi
    say "  ${D}Ключ роутера не заменяет ваш собственный: для входа с компьютера нужен ваш ключ в authorized_keys.${N}"
    if [ "${ssh_keys:-0}" -ge 1 ]; then
      say "  ${Y}Отключение входа по паролю.${N} В authorized_keys ключей: $ssh_keys. ${B}Убедитесь, что вход по ключу с вашего компьютера работает${N} (откройте второе окно: ssh -o PasswordAuthentication=no root@$VPS_IP)."
      say "  ${D}Если ключ не подойдёт, войти по SSH будет нельзя (останется консоль в панели хостера). Откат: удалить /etc/ssh/sshd_config.d/00-awg-hardening.conf.${N}"
      ask k "Чтобы отключить вход по паролю, напишите слово ОТКЛЮЧИТЬ (иначе пропуск)" ""
      [ "$k" = ОТКЛЮЧИТЬ ] && sk=1
    else info "вход по паролю включён, но ключей в authorized_keys нет: сначала добавьте свой ключ (ssh-copy-id), потом возвращайтесь сюда"; fi
  else info "вход по паролю уже отключён"; fi
  if [ "$du$df2$sk" = 000 ]; then info "менять нечего"; vssh 'rm -f /root/vps-harden.sh'; return 0; fi
  local ap; ap=$(vssh "awk -F'=' '/^ListenPort/{gsub(/ /,\"\",\$2); print \$2}' /etc/amnezia/server.conf" 2>/dev/null)
  [[ "$ap" =~ ^[0-9]+$ ]] && AWG_PORT=$ap
  r=$(vssh "HARDEN_MODE=apply DO_UPGRADES=$du DO_FAIL2BAN=$df2 DO_SSH_KEYS_ONLY=$sk SSH_PORT=$VPS_SSHPORT AWG_PORT=${AWG_PORT:-51823} bash /root/vps-harden.sh" 2>&1)
  printf '%s\n' "$r" | while IFS= read -r k; do case "$k" in OK*) ok "${k#OK }";; FAIL*) err "${k#FAIL }";; *) [ -n "$k" ] && info "$k";; esac; done
  vssh 'rm -f /root/vps-harden.sh'
  [ "$sk" = 1 ] && hint "Проверьте вход по ключу в НОВОМ окне, пока текущая сессия открыта."
  hint "Аудит сервера: Диагностика → «Диагностика своего VPS по SSH»."
}

conf_set_keys(){  # conf_set_keys ФАЙЛ НОВЫЙ_PrivateKey_КЛИЕНТА НОВЫЙ_PublicKey_СЕРВЕРА
  awk -v k="$2" -v p="$3" '
    /^[[:space:]]*\[/ { sec=tolower($0); gsub(/[[:space:]]/,"",sec) }
    sec=="[interface]" && /^[[:space:]]*PrivateKey[[:space:]]*=/ { print "PrivateKey = " k; next }
    sec=="[peer]" && /^[[:space:]]*PublicKey[[:space:]]*=/ { print "PublicKey = " p; next }
    { print }' "$1" > "$1.new" && mv "$1.new" "$1" && chmod 600 "$1"
}
do_rotate_keys(){
  title "Смена ключей туннеля до своего VPS"
  local t="$1" cands=() x ep cf addr nk np out sp bk pre i okk=0 a
  if [ -z "$t" ]; then
    for x in $(list_tunnels); do
      cf=$DD/$(conf_of "$x"); [ -f "$cf" ] || continue
      ep=$(conf_get "$cf" Endpoint | tr -d ' \r'); ep=${ep%:*}
      [ -n "$(env_get VPS_IP)" ] && [ "$ep" = "$(env_get VPS_IP)" ] && cands+=("$x")
    done
    if [ ${#cands[@]} -eq 0 ]; then err "не нашёл туннель, у которого Endpoint совпадает с VPS_IP ($(env_get VPS_IP)): ключи сервера провайдера менять нельзя."; return 1; fi
    if [ ${#cands[@]} -eq 1 ]; then t=${cands[0]}; else choose a "Какой туннель?" "${cands[@]}"; t=${cands[$((a-1))]}; fi
  fi
  cf=$DD/$(conf_of "$t"); [ -f "$cf" ] || { err "нет конфига $cf"; return 1; }
  say "  ${D}Будут заменены и ключ клиента (роутера), и ключ сервера. Туннель $t будет недоступен 10–30 секунд (kill switch держит PBR-трафик).${N}"
  say "  ${D}Перед заменой делаются копии (на роутере и на VPS); при неудаче всё откатывается само. Реальный VPS в тестах не проверялся: сделайте это в удобное время.${N}"
  yn "Сменить ключи туннеля $t?" N || return 0
  vps_connect || return 1
  addr=$(conf_get "$cf" Address | tr ',' '\n' | tr -d ' \t\r' | grep -m1 '\.')
  [ -n "$addr" ] || { err "в $cf нет Address"; return 1; }
  nk=$("$DD/awg" genkey) && np=$(printf '%s' "$nk" | "$DD/awg" pubkey) || { err "не удалось сгенерировать ключи"; return 1; }
  pre="$cf.pre-rotate-$(date +%s)"; cp -p "$cf" "$pre"
  vput "$KIT/server/vps-rotate.sh" || { err "не удалось передать скрипт на VPS"; return 1; }
  out=$(vssh "CLIENT_ADDR=$addr NEW_CLIENT_PUB=$np bash /root/vps-rotate.sh" 2>&1)
  if echo "$out" | grep -q '^ERROR'; then err "VPS: $(echo "$out" | grep '^ERROR' | head -n1)"; info "изменений на роутере нет (копия $pre)"; vssh 'rm -f /root/vps-rotate.sh'; return 1; fi
  sp=$(echo "$out" | sed -n 's/^NEW_SERVER_PUB=//p'); bk=$(echo "$out" | sed -n 's/^BACKUP_FILE=//p')
  [ -n "$sp" ] || { err "VPS не вернул новый публичный ключ: $out"; return 1; }
  info "на VPS ключи заменены, сервер перезапущен. Обновляю конфиг на роутере и поднимаю туннель…"
  conf_set_keys "$cf" "$nk" "$sp"
  "$DD/up.sh" "$t" 2>&1 | sed 's/^/    /'
  for i in $(seq 1 25); do [ "$(hs_age "$t")" -ge 0 ] && [ "$(hs_age "$t")" -lt 20 ] && { okk=1; break; }; sleep 1; done
  if [ $okk = 1 ] && tun_ip "$t" >/dev/null; then
    ok "новые ключи работают: handshake есть, интернет через $t открывается"
    info "старый конфиг: $pre (содержит старый ключ: удалите его: shred -u $pre), на VPS: $bk"
    unset nk
  else
    err "туннель с новыми ключами не заработал: откатываю"
    cp -p "$pre" "$cf"; vssh "ROLLBACK=$bk bash /root/vps-rotate.sh" 2>&1 | sed 's/^/    /'
    "$DD/up.sh" "$t" >/dev/null 2>&1; sleep 5
    tun_ip "$t" >/dev/null && ok "откат выполнен, туннель работает на старых ключах" || err "после отката туннель не отвечает: смотрите Диагностика"
  fi
  vssh 'rm -f /root/vps-rotate.sh'
}

# ============================================================ мастер ======
ALL_UNITS="awg-failover awg-subnets awg-self awg-guard awg-notify awg-bot awg-metrics awg-ha awg-web awg-motd"
seed_units(){  # установки до 1.2.0 не вели список служб: заполняем по включённым юнитам
  local u
  [ -s "$DD/.units" ] && return 0
  for u in $ALL_UNITS; do
    [ -f "$SYSD/$u.service" ] && systemctl is-enabled --quiet "$u" 2>/dev/null && unit_mark "$u"
  done
  return 0
}
disable_service(){
  local a u opts=() x
  for x in awg-web awg-bot awg-ha awg-metrics awg-notify awg-guard awg-self awg-subnets; do [ -f "$SYSD/$x.service" ] && opts+=("$x"); done
  [ ${#opts[@]} -gt 0 ] || { info "дополнительных служб не включено"; return 0; }
  choose a "Какую службу выключить?" "${opts[@]}" "Отмена"
  [ "$a" -gt ${#opts[@]} ] && return 0
  u=${opts[$((a-1))]}
  case $u in
    awg-self)    disable_self; env_set UI_FIX no;;
    awg-guard)   unit_off awg-guard; [ -x "$DD/guard.sh" ] && "$DD/guard.sh" remove; env_set LEAK_GUARD no; ok "awg-guard выключен, правила убраны";;
    awg-subnets) unit_off awg-subnets; [ -x "$DD/subnets.sh" ] && "$DD/subnets.sh" remove; ok "awg-subnets выключен, правила убраны (список подсетей в awg.env сохранён)";;
    *)           unit_off "$u"; ok "$u выключен";;
  esac
}

wizard(){
  local a
  preflight
  title "Сценарий"
  choose a "Что настраиваем?" \
    "A — один туннель: у меня есть конфиг AmneziaWG от провайдера" \
    "B — один туннель до моего VPS (сервер настроим)" \
    "C — основной туннель от провайдера + запасной на моём VPS с автопереключением"
  SCEN=$(echo ABC | cut -c"$a")
  ilog "сценарий $SCEN"
  get_kit
  install_files
  step_bins

  env_set MAIN "$MAIN"
  if [ "$SCEN" = C ]; then env_set BACKUP "$BACKUP_NAME"; else env_set BACKUP ""; ip link del "$BACKUP_NAME" 2>/dev/null; "$DD/failover.sh" forget "$BACKUP_NAME" 2>/dev/null; fi
  grep -q '^RECOVER_SEC=' "$DD/awg.env" || env_set RECOVER_SEC 600
  grep -q '^EXTRA_SUBNETS=' "$DD/awg.env" || env_set EXTRA_SUBNETS '""'
  grep -q '^VPS_IP=' "$DD/awg.env" || env_set VPS_IP ""

  title "Основной туннель ($MAIN)"
  say "  ${D}Один конфиг — одно устройство: если этот же конфиг работает где-то ещё, оба канала будут нестабильны.${N}"
  if [ "$SCEN" = B ]; then step_vps main.conf; else get_conf main.conf "конфиг AmneziaWG основного туннеля"; fi
  if ! bring_up_and_test "$MAIN" "основной туннель" && [ "$SCEN" = B ] && [ -n "$VPS_IP" ]; then
    yn "Запустить диагностику с двух сторон (роутер и VPS)?" Y && diag_tunnel "$MAIN" "$AWG_PORT"
  fi

  if [ "$SCEN" = C ]; then
    title "Запасной туннель ($BACKUP_NAME) на вашем VPS"
    step_vps backup.conf
    if ! bring_up_and_test "$BACKUP_NAME" "запасной туннель" && [ -n "$VPS_IP" ]; then
      yn "Запустить диагностику с двух сторон (роутер и VPS)?" Y && diag_tunnel "$BACKUP_NAME" "$AWG_PORT"
    fi
    ask a "Через сколько секунд стабильной работы возвращаться на основной канал" "$(env_get RECOVER_SEC)"
    [[ "$a" =~ ^[0-9]+$ ]] && env_set RECOVER_SEC "$a"
  fi
  [ "$SCEN" = B ] && [ -n "$VPS_IP" ] && env_set VPS_IP "$VPS_IP"

  step_rail

  step_watchdog
  [ "$SCEN" = C ] && yn "Проверить переключение на запасной канал сейчас (~30 с)?" Y && test_switch
  yn "Пускать через туннель и клиентов VPN-сервера самого роутера (WireGuard Server, Teleport)?" N && step_subnets

  title "Расширенные возможности"
  say "  ${D}Каждый пункт можно пропустить и вернуться к нему позже: $DD/install.sh → Компоненты.${N}"
  if yn "Настроить расширенные возможности (защита от утечек, awg-self, домены, качество канала, MTU)?" Y; then
    [ "$SCEN" = C ] && step_quality
    yn "Защита от утечек (awg-guard)?" Y && step_guard
    yn "Трафик самого роутера и исправление unifi.ui.com через туннель (awg-self)?" N && step_self
    yn "Отдельные домены через туннель или напрямую (исключения)?" N && step_domains
    yn "Подобрать MTU туннелей?" N && step_mtu
  fi

  title "Сервисные возможности"
  yn "Панель состояния при входе по SSH?" Y && step_panel
  yn "Установить аудит awg-audit (проверка на лишние правила и файлы)?" Y && step_audit
  yn "Уведомления в Telegram?" N && step_telegram
  [ -s "$DD/telegram.env" ] && yn "Команды и оповещения в Telegram (бот awg-bot)?" N && step_bot
  yn "Экспорт метрик (Prometheus)?" N && step_metrics
  command -v python3 >/dev/null && yn "Веб-панель управления в браузере (LAN, HTTPS, вход по паролю)?" Y && step_web
  yn "Автовосстановление после обновления прошивки (on_boot.d)?" N && step_boot_hook
  [ -n "$VPS_IP" ] && yn "Запустить аудит VPS?" Y && vps_audit
  [ -n "$VPS_IP" ] && yn "Защитить VPS (автообновления, fail2ban, вход по ключам)?" N && vps_harden
  write_manifest
  [ -x "$DD/drift.sh" ] && { sleep 5; "$DD/drift.sh" save >/dev/null 2>&1; }
  if yn "Запустить самопроверку?" Y; then "$DD/selftest.sh" | show_check; fi
  summary
}

summary(){
  title "Готово"
  local t u act=""; t=$(env_get TABLE)
  say "  Установлено в ${B}$DD${N}. Таблица PBR ${B}$t${N}, туннели: ${B}$(list_tunnels | tr '\n' ' ')${N}."
  [ -n "$(env_get EXTRA_SUBNETS)" ] && say "  Через туннель идут и клиенты VPN-сервера роутера: ${B}$(env_get EXTRA_SUBNETS)${N} (проверка: $DD/subnets.sh check)."
  for u in awg-guard awg-self awg-bot awg-ha awg-metrics awg-notify awg-web; do svc_active "$u" && act="$act ${u#awg-}"; done
  [ -n "$act" ] && say "  Включены службы:${B}$act${N}."
  svc_active awg-web && say "  Веб-панель: ${C}$(web_url)${N}"
  [ -x "$DD/status.sh" ] && "$DD/status.sh" -s | sed 's/^/  /'
  say "  ${B}Проверьте сами:${N}"
  say "   • устройство под правилом PBR: на 2ip.io виден IP туннеля;"
  say "   • устройство вне PBR: виден ваш обычный IP;"
  say "   • перезагрузите роутер, когда удобно, и через 2–3 минуты запустите: ${C}awgctl selftest${N} (в новом окне SSH)."
  say "  ${B}Дальше:${N} меню — ${C}$DD/install.sh${N}; состояние — ${C}awgctl status${N}; после обновления прошивки — ${C}$DD/install.sh --restore${N}."
  say "  ${D}Конфиги с ключами: $DD/*.conf (права 600). Ключи и токены не отправляйте в чаты. Журнал установки: $ILOG${N}"
  ilog "установка завершена, сценарий $SCEN"
}

# ============================================================ меню =========
do_update(){
  get_kit
  title "Обновление скриптов"
  [ -f "$DD/VERSION" ] && info "сейчас: $(cat "$DD/VERSION"), будет: $(cat "$KIT/VERSION" 2>/dev/null || echo ?)"
  local bk u pre_route=0 pre_web=0 t; bk="$DD/backup-$(date +%Y%m%d-%H%M%S).tgz"
  ( umask 077; tar czf "$bk" -C "$DD" --exclude='backup-*.tgz' --exclude=backups --exclude=history --exclude=awg --exclude=amneziawg-go . 2>/dev/null ) && ok "резервная копия: $bk"
  ls -1t "$DD"/backup-*.tgz 2>/dev/null | tail -n +4 | while read -r t; do rm -f "$t"; done   # хранить 3 последние
  t=$(env_get TABLE); [ -n "$t" ] && ip -4 route show table "$t" 2>/dev/null | grep -q '^default dev awg' && pre_route=1
  svc_active awg-web && pre_web=1
  seed_units
  install_files
  local n; n=$("$DD/failover.sh" dedup 2>/dev/null | grep -o '[0-9]*$'); [ "${n:-0}" -gt 0 ] && ok "убрано дубликатов правил iptables: $n"
  for u in $(cat "$DD/.units" 2>/dev/null); do [ -f "$DD/$u.service" ] && cp "$DD/$u.service" "$SYSD/$u.service"; done
  systemctl daemon-reload
  for u in $(cat "$DD/.units" 2>/dev/null); do
    [ "$u" = awg-motd ] && continue
    svc_active "$u" && { systemctl restart "$u"; ok "$u перезапущен"; }
  done
  if [ "${AWG_NO_ROLLBACK:-}" != 1 ] && ! update_healthy "$pre_route" "$pre_web"; then
    update_rollback "$bk"
    return 1
  fi
  ok "после обновления всё работает: набор $(cat "$DD/VERSION" 2>/dev/null)"
  [ -x "$DD/drift.sh" ] && "$DD/drift.sh" save >/dev/null 2>&1 && ok "эталон правил обновлён (awgctl drift)"
  if [ "${AWG_YES:-}" != 1 ] && ! [ -f "$SYSD/awg-web.service" ] && command -v python3 >/dev/null; then
    yn "Включить веб-панель управления (браузер, только LAN, вход по паролю)?" Y && step_web
  elif [ -f "$SYSD/awg-web.service" ]; then
    svc_active awg-web && ok "веб-панель: $(web_url)"
  fi
  [ -x "$DD/audit.sh" ] && "$DD/audit.sh" | tail -n 3
  hint "Новые возможности (защита от утечек, awg-self, домены, бот, метрики, MTU…) включаются в меню: Компоненты."
}
do_restore(){
  title "Восстановление после обновления прошивки"
  [ -x "$DD/awg-restore.sh" ] || die "нет $DD/awg-restore.sh — установка не найдена"
  seed_units
  "$DD/awg-restore.sh" | sed 's/^/  /'
  local t; t=$(env_get TABLE)
  if [ -n "$(env_get EXTRA_SUBNETS)" ] && [ -f "$DD/awg-subnets.service" ] && ! svc_active awg-subnets; then
    unit_on awg-subnets && ok "служба awg-subnets восстановлена"
  fi
  if pbr_drift || ! ip rule show | grep -q "fwmark $(env_get MARK | cut -d/ -f1)"; then
    warn "правило PBR UniFi не совпадает с awg.env (метка $(env_get MARK), таблица $(env_get TABLE)): UniFi мог пересоздать профиль"
    yn "Определить таблицу и метку заново?" Y && { step_rail; systemctl restart awg-failover; }
  fi
  sleep 6; ip route show table "$t" | grep -q 'metric 5' && ok "PBR-трафик снова идёт через туннель" || warn "маршрута в таблице $t нет: запустите диагностику ($DD/install.sh → Диагностика)"
}
update_healthy(){  # update_healthy БЫЛ_МАРШРУТ БЫЛА_ПАНЕЛЬ — ждать до 60 с, что сторож, маршрут и панель снова работают
  local i t f bad
  for f in "$DD"/*.sh; do bash -n "$f" 2>/dev/null || { err "после обновления синтаксическая ошибка в $f"; return 1; }; done
  t=$(env_get TABLE)
  for i in $(seq 1 30); do
    bad=""
    svc_active awg-failover || bad="сторож awg-failover не работает"
    [ "$1" = 1 ] && [ -n "$t" ] && ! ip -4 route show table "$t" 2>/dev/null | grep -q '^default dev awg' && bad="${bad:+$bad; }в таблице PBR нет маршрута в туннель"
    [ "$2" = 1 ] && ! svc_active awg-web && bad="${bad:+$bad; }веб-панель не запустилась"
    [ -z "$bad" ] && return 0
    sleep 2
  done
  err "после обновления: $bad"
  return 1
}
update_rollback(){  # вернуть код и службы из копии, сделанной перед обновлением (настройки и конфиги не трогаются)
  local bk=$1 tmp f u
  warn "Откат обновления: возвращаю прежние скрипты и службы из $bk"
  tmp=$(mktemp -d) || return 1
  tar xzf "$bk" -C "$tmp" 2>/dev/null || { err "копия $bk не читается: откат невозможен, смотрите журнал"; rm -rf "$tmp"; return 1; }
  for f in "$tmp"/*.sh "$tmp"/*.service "$tmp"/VERSION; do [ -f "$f" ] && put "$f" "$DD/$(basename "$f")"; done
  if [ -d "$tmp/web" ]; then
    [ -f "$tmp/web/panel.py" ] && put "$tmp/web/panel.py" "$DD/web/panel.py"
    for f in "$tmp"/web/awgweb/*.py; do [ -f "$f" ] && put "$f" "$DD/web/awgweb/$(basename "$f")"; done
    rm -rf "$DD/web/awgweb/__pycache__"
    for f in "$tmp"/web/static/*; do [ -f "$f" ] && put "$f" "$DD/web/static/$(basename "$f")"; done
  fi
  chmod 755 "$DD"/*.sh 2>/dev/null
  rm -rf "$tmp"
  for u in $(cat "$DD/.units" 2>/dev/null); do [ -f "$DD/$u.service" ] && cp "$DD/$u.service" "$SYSD/$u.service"; done
  systemctl daemon-reload
  for u in $(cat "$DD/.units" 2>/dev/null); do [ "$u" = awg-motd ] && continue; systemctl restart "$u" 2>/dev/null; done
  write_manifest
  ilog "обновление откатилось"
  err "обновление откатилось к $(cat "$DD/VERSION" 2>/dev/null). Пришлите вывод выше и $DD/update.log (если обновляли из панели) в issue."
}

do_uninstall(){
  title "Удаление"
  warn "Сначала удалите в UniFi правила Policy-Based Routes, ссылающиеся на рельсу: иначе их устройства останутся без интернета."
  yn "Удалить службы, маршруты и правила AWG с роутера?" N || return
  local purge="" v u s; v=$(env_get VPS_IP 2>/dev/null)
  yn "Удалить и папку $DD с конфигами и ключами?" N && purge=--purge
  for u in awg-web awg-bot awg-ha awg-metrics awg-guard awg-self awg-subnets; do
    [ -f "$SYSD/$u.service" ] && { systemctl disable --now "$u" >/dev/null 2>&1; rm -f "$SYSD/$u.service"; }
  done
  systemctl daemon-reload
  for s in guard self subnets; do [ -x "$DD/$s.sh" ] && "$DD/$s.sh" remove >/dev/null 2>&1; done
  for s in AWG_UI AWG_DOM AWG_DIRECT; do ipset destroy "$s" >/dev/null 2>&1; done
  rm -f "$BOOT_D/10-awg-restore.sh"
  ok "службы awg-web/guard/self/subnets/bot/metrics, их правила, ipset-ы и файл on_boot.d убраны"
  if [ -x "$DD/awg-uninstall.sh" ]; then "$DD/awg-uninstall.sh" $purge | sed 's/^/  /'; else err "нет $DD/awg-uninstall.sh"; fi
  [ -n "$v" ] && info "На VPS $v сервер остался. Удалить там: systemctl disable --now awg-server; rm -rf /etc/amnezia /etc/systemd/system/awg-server.service /usr/local/bin/awg-up.sh"
  exit 0
}
do_diag(){
  local a i
  while :; do
    choose a "Диагностика:" "Самопроверка (selftest)" "Самопроверка с проверкой переключения и kill switch (~1 мин, кратко прервёт трафик)" "Состояние каналов (awgctl status)" "События (awgctl events)" "Аудит роутера (awg-audit)" "Проверить туннели (внешний IP, handshake)" "Подробная диагностика туннеля (tcpdump на WAN)" "Диагностика своего VPS по SSH (роутер + сервер)" "Журнал сторожа (последние 30 строк)" "Назад"
    case $a in
      1) [ -x "$DD/selftest.sh" ] && "$DD/selftest.sh" | show_check || err "selftest.sh не установлен";;
      2) warn "Тест на секунды отключит основной канал и проверит kill switch."; yn "Запустить?" N && "$DD/selftest.sh" --full | show_check;;
      3) "$DD/awgctl.sh" status;;
      4) "$DD/awgctl.sh" events 30;;
      5) [ -x "$DD/audit.sh" ] && "$DD/audit.sh" || err "audit.sh не установлен";;
      6) for i in $(list_tunnels); do if ip=$(tun_ip "$i"); then ok "$i: IP $ip, handshake $(hs_age "$i") с назад"; else err "$i: не работает"; fi; done;;
      7) ask i "Интерфейс" "$MAIN"; diag_tunnel "$i";;
      8) get_kit; vps_connect && {
           AWG_PORT=$(vssh "awk -F'=' '/^ListenPort/{gsub(/ /,\"\",\$2); print \$2}' /etc/amnezia/server.conf" 2>/dev/null)
           i=$BACKUP_NAME; check_conf "$DD/main.conf" >/dev/null 2>&1; [ "${CONF_EP%:*}" = "$VPS_IP" ] && i=$MAIN
           diag_tunnel "$i" "${AWG_PORT:-51823}"; vput "$KIT/server/audit-server.sh" && vps_audit; };;
      9) tail -n 30 "$DD/failover.log" 2>/dev/null | sed 's/^/  /';;
      10) return;;
    esac
  done
}

menu_tunnels(){
  local a
  while :; do
    choose a "Туннели:" "Заменить конфиг основного туннеля" "Добавить/заменить запасной туннель на VPS" "Убрать запасной туннель" "Добавить дополнительный туннель" "Убрать дополнительный туннель" "Время возврата на основной канал" "Переключение по качеству канала" "Заново определить таблицу и метку PBR" "Обновить бинарники AmneziaWG (официальные исходники)" "Назад"
    case $a in
      1) cp -p "$DD/main.conf" "$DD/main.conf.prev" 2>/dev/null; get_conf main.conf "новый конфиг основного туннеля" new && bring_up_and_test "$MAIN" "основной туннель"
         [ -f "$DD/main.conf.prev" ] && hint "прежний конфиг: $DD/main.conf.prev (содержит ключ; удалите, когда новый проверен: shred -u $DD/main.conf.prev)";;
      2) get_kit; install_files; env_set BACKUP "$BACKUP_NAME"; [ -f "$DD/backup.conf" ] && cp -p "$DD/backup.conf" "$DD/backup.conf.prev"; step_vps backup.conf; bring_up_and_test "$BACKUP_NAME" "запасной туннель"; step_watchdog; yn "Проверить переключение?" Y && test_switch;;
      3) env_set BACKUP ""; step_watchdog; ip link del "$BACKUP_NAME" 2>/dev/null; "$DD/failover.sh" forget "$BACKUP_NAME"; ok "работаем без запасного туннеля, его правила убраны";;
      4) step_extra_tunnel;;
      5) remove_extra_tunnel;;
      6) ask a "Секунд стабильной работы до возврата" "$(env_get RECOVER_SEC)"; [[ "$a" =~ ^[0-9]+$ ]] && { env_set RECOVER_SEC "$a"; systemctl restart awg-failover; ok "RECOVER_SEC=$a"; };;
      7) step_quality;;
      8) step_rail; systemctl restart awg-failover; ok "сторож перезапущен";;
      9) get_kit; step_bins && { info "перезапускаю туннели на новых бинарниках (несколько секунд без PBR-трафика, утечки нет)…"
           "$DD/up.sh" 2>&1 | sed 's/^/    /'; systemctl restart awg-failover; sleep 8
           for a in $(list_tunnels); do tun_ip "$a" >/dev/null && ok "$a работает" || err "$a не отвечает: верните прежние файлы (*.prev) или смотрите Диагностика"; done; };;
      10) return;;
    esac
  done
}
menu_routing(){
  local a
  while :; do
    choose a "Маршрутизация и защита:" "Клиенты VPN-сервера роутера (подсети)" "Защита от утечек (awg-guard)" "Трафик роутера и unifi.ui.com через туннель (awg-self)" "Домены через туннель и исключения" "Подбор MTU" "Выключить службу (guard, self, subnets…)" "Назад"
    case $a in
      1) step_subnets;;
      2) step_guard;;
      3) step_self;;
      4) step_domains;;
      5) step_mtu;;
      6) disable_service;;
      7) return;;
    esac
  done
}
menu_services(){
  local a
  while :; do
    choose a "Службы и оповещения:" "Панель при входе по SSH" "Аудит" "Telegram: уведомления" "Telegram: команды и оповещения (бот)" "Метрики Prometheus" "Веб-панель (браузер)" "Выключить службу (веб-панель, бот, метрики…)" "Назад"
    case $a in
      1) step_panel;; 2) step_audit;; 3) step_telegram;; 4) step_bot;; 5) step_metrics;; 6) step_web;; 7) disable_service;; 8) return;;
    esac
  done
}
menu_vps(){
  local a
  while :; do
    choose a "Свой VPS:" "Защита VPS (автообновления, fail2ban, вход по ключам)" "Сменить ключи туннеля" "Аудит VPS" "Назад"
    case $a in
      1) get_kit; vps_harden;;
      2) get_kit; do_rotate_keys;;
      3) get_kit; vps_connect && { vput "$KIT/server/audit-server.sh" && vps_audit; };;
      4) return;;
    esac
  done
}
menu_maint(){
  local a
  while :; do
    choose a "Обслуживание:" "Резервные копии настроек" "Автовосстановление после обновления прошивки (on_boot.d)" "Проверить файлы установки (манифест)" "Обновить сам установщик (install.sh)" "Самопроверка" "Предпросмотр: что есть на роутере" "Назад"
    case $a in
      1) do_backup_menu;;
      2) step_boot_hook;;
      3) do_verify;;
      4) do_selfupdate;;
      5) "$DD/selftest.sh" | show_check;;
      6) plan;;
      7) return;;
    esac
  done
}
do_components(){
  local a
  while :; do
    choose a "Компоненты:" "Туннели (основной, запасной, дополнительные, качество)" "Маршрутизация и защита (подсети, утечки, awg-self, домены, MTU)" "Службы и оповещения (панель, аудит, Telegram, бот, метрики)" "Свой VPS (защита, смена ключей, аудит)" "Обслуживание (копии, автовосстановление, проверка файлов, обновление установщика)" "Назад"
    case $a in
      1) menu_tunnels;; 2) menu_routing;; 3) menu_services;; 4) menu_vps;; 5) menu_maint;; 6) return;;
    esac
  done
}
main_menu(){
  local a
  while :; do
    title "AmneziaWG для UDR7 · установщик $INSTALLER_VERSION"
    if [ -f "$DD/awg.env" ] && [ -x "$DD/failover.sh" ]; then
      info "установка найдена: $DD, сторож $(systemctl is-active awg-failover 2>/dev/null), туннели: $(list_tunnels | tr '\n' ' ')"
    else
      info "установка не найдена"
    fi
    choose a "Что делаем?" \
      "Полная установка / перенастройка (мастер)" \
      "Обновить скрипты из репозитория (конфиги сохраняются)" \
      "Компоненты: туннели, маршрутизация, службы, VPS, обслуживание" \
      "Диагностика и самопроверка" \
      "Восстановить после обновления прошивки" \
      "Панель состояния" \
      "Удалить" \
      "Выход"
    case $a in
      1) wizard; return;;
      2) need_root; do_update;;
      3) need_root; do_components;;
      4) do_diag;;
      5) need_root; do_restore;;
      6) [ -x "$DD/status.sh" ] && "$DD/status.sh" || err "панель не установлена";;
      7) need_root; do_uninstall;;
      8) exit 0;;
    esac
  done
}

# ============================================================ запуск =======
# Весь запуск — внутри функции: bash прочитает её целиком до выполнения, поэтому замена install.sh на диске
# (обновление) не может подсунуть работающему процессу кусок нового файла.
main(){
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --record)  [ $# -ge 2 ] || { echo "--record требует имя файла"; exit 1; }; RECORD_FILE=$2; shift 2;;
      --answers) [ $# -ge 2 ] || { echo "--answers требует имя файла"; exit 1; }; ANS_FILE=$2; shift 2;;
      --channel) [ $# -ge 2 ] || { echo "--channel требует stable, beta или имя ветки"; exit 1; }
                 case "$2" in stable|beta) AWG_CHANNEL=$2; AWG_BRANCH=main;; *) AWG_CHANNEL=branch; AWG_BRANCH=$2;; esac
                 AWG_REF=""; CHANNEL_SET=1; shift 2;;
      *) ARGS+=("$1"); shift;;
    esac
  done
  set -- "${ARGS[@]}"
  [ -n "${CHANNEL_SET:-}" ] && [ $# -eq 0 ] && set -- --update     # install.sh --channel beta — сменить канал и обновиться
  case "${1:-}" in --status|--help|-h|--verify|--dry-run|--plan|--selftest|--bins-check) ;; *) open_tty;; esac
  case "${1:-}" in
    --update)       need_root; do_update;;
    --web)          need_root; [ -f "$DD/awg.env" ] || die "сначала установите набор: запустите install.sh без ключей"; get_kit; install_files; step_web;;
    --restore)      need_root; do_restore;;
    --status)       [ -x "$DD/status.sh" ] && exec "$DD/status.sh" || die "панель не установлена";;
    --selftest)     [ -x "$DD/selftest.sh" ] || die "самопроверка не установлена"; shift; "$DD/selftest.sh" "$@" | show_check;;
    --dry-run|--plan) plan;;
    --verify)       do_verify;;
    --self-update)  need_root; do_selfupdate;;
    --bins-check)   do_bins_check;;
    --bins-update)  need_root; do_bins_update "${2:-}";;
    --rotate-keys)  need_root; get_kit; do_rotate_keys "$2";;
    --harden-vps)   need_root; get_kit; vps_harden;;
    --uninstall)    need_root; do_uninstall;;
    --help|-h)      sed -n '3,/^# =\{20,\}$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || echo "install.sh --help";;
    "")             need_root; if [ -f "$DD/awg.env" ] && [ -x "$DD/failover.sh" ]; then main_menu; else wizard; fi;;
    *)              die "неизвестный ключ $1 (см. --help)";;
  esac
}
[ -n "$AWG_LIB" ] && return 0 2>/dev/null   # для тестов: загрузить только функции
main "$@"; exit $?
