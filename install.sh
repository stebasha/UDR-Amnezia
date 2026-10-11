#!/bin/bash
# ============================================================================
#  AmneziaWG для UniFi Dream Router 7 — установщик и мастер настройки
#
#  Первый запуск на роутере (SSH, root):
#    bash <(curl -fsSL https://raw.githubusercontent.com/OWNER/udr7-amneziawg/main/install.sh)
#  или из клона репозитория:   bash install.sh
#  Повторно (меню обслуживания): /data/awg/install.sh
#
#  Ключи: --update   обновить скрипты из репозитория (конфиги сохраняются)
#         --restore  вернуть автозапуск после обновления прошивки
#         --status   панель состояния
#         --uninstall удалить
#         --help
# ============================================================================
INSTALLER_VERSION=1.1.0
AWG_REPO=${AWG_REPO:-OWNER/udr7-amneziawg}          # ← ваш GitHub: владелец/репозиторий
AWG_BRANCH=${AWG_BRANCH:-main}
BIN_URL_DEFAULT=https://github.com/DjGreeZ/AmneziaWG-Unifi-DreamMachine/raw/main/AmneziaWG-UniFi-v0.2.1-source.tar.gz
DD=${DD:-/data/awg}
WORK=${WORK:-/tmp/awg-install}
ILOG=$DD/install.log
MAIN=awgmain
BACKUP_NAME=awgbackup

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
TTY_IN=${AWG_TTY:-/dev/tty}
open_tty(){ exec 3<"$TTY_IN" 2>/dev/null || { echo "Нужен интерактивный терминал: запустите установщик в SSH-сессии."; exit 1; }; }
rd(){ IFS= read -r -u 3 "$@"; }
ask(){   # ask ПЕРЕМЕННАЯ "вопрос" [по умолчанию]
  local __ask_v=$1 __ask_p=$2 __ask_d=$3 __ask_a
  printf '%s' "  ${B}?${N} $__ask_p${__ask_d:+ ${D}[$__ask_d]${N}}: "
  rd __ask_a || { say; die "Ввод закрыт, установка прервана."; }
  __ask_a=${__ask_a%$'\r'}; __ask_a=${__ask_a#"${__ask_a%%[![:space:]]*}"}; __ask_a=${__ask_a%"${__ask_a##*[![:space:]]}"}
  [ -z "$__ask_a" ] && __ask_a=$__ask_d
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
  IFS= read -rs -u 3 __rs_a || { say; die "Ввод закрыт."; }
  say; printf -v "$__rs_v" '%s' "${__rs_a%$'\r'}"
}
read_paste(){ # read_paste ФАЙЛ — многострочный ввод до строки END или Ctrl+D
  local f=$1 l
  ( umask 077; : > "$f" )
  say "    ${D}Вставьте текст целиком. Затем на новой строке напишите ${N}${B}END${N}${D} и нажмите Enter (или Ctrl+D).${N}"
  while IFS= read -r -u 3 l; do
    l=${l%$'\r'}
    [ "$l" = END ] && break
    printf '%s\n' "$l" >> "$f"
  done
}

# ---------------------------------------------------------------- утилиты --
is_ipv4(){ local IFS=.; local -a o; local x; [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; o=($1); for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done; }
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
      yn "Отключить и удалить?" Y && { systemctl disable --now "$u" 2>/dev/null; rm -f "/etc/systemd/system/$u.service"; systemctl daemon-reload; ok "$u убрана"; }
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
kit_ok(){ local f; for f in awg/up.sh awg/failover.sh awg/awg-detect.sh awg/status.sh awg/audit.sh awg/notify.sh awg/awg-notify.sh awg/awg-restore.sh awg/awg-uninstall.sh awg/awg-failover.service server/awg-server-build.sh server/awg-server-setup.sh; do [ -f "$1/$f" ] || return 1; done; }
get_kit(){
  [ -n "$KIT" ] && return 0
  title "Скрипты установки"
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
  if [ -n "$here" ] && kit_ok "$here"; then KIT=$here; ok "беру скрипты из папки $KIT"; kit_verify; return; fi
  local a p
  while :; do
    mkdir -p "$WORK"; rm -rf "$WORK/kit"; mkdir -p "$WORK/kit"
    info "скачиваю $AWG_REPO ($AWG_BRANCH)…"
    if curl -fsSL -m 120 "https://github.com/$AWG_REPO/archive/refs/heads/$AWG_BRANCH.tar.gz" -o "$WORK/kit.tgz" && tar xzf "$WORK/kit.tgz" -C "$WORK/kit" 2>/dev/null; then
      p=$(find "$WORK/kit" -path '*/awg/failover.sh' | head -1)
      if [ -n "$p" ] && kit_ok "$(dirname "$(dirname "$p")")"; then KIT=$(dirname "$(dirname "$p")"); ok "скрипты скачаны"; kit_verify; return; fi
      err "в архиве нет нужных файлов (awg/…, server/…)"
    else
      err "не удалось скачать https://github.com/$AWG_REPO"
      [ "$AWG_REPO" = OWNER/udr7-amneziawg ] && hint "В установщике не задан репозиторий: переменная AWG_REPO в начале install.sh."
    fi
    choose a "Что делать?" "Повторить" "Указать папку с репозиторием на роутере" "Указать другой репозиторий (владелец/имя)" "Выйти"
    case $a in
      2) ask p "Путь к папке (в ней должны быть awg/ и server/)" ""; kit_ok "$p" && { KIT=$p; ok "беру скрипты из $KIT"; kit_verify; return; }; err "в $p нет нужных файлов";;
      3) ask AWG_REPO "Репозиторий" "$AWG_REPO"; ask AWG_BRANCH "Ветка" "$AWG_BRANCH";;
      4) exit 1;;
    esac
  done
}
kit_verify(){
  local f bad=0
  for f in "$KIT"/awg/*.sh "$KIT"/server/*.sh; do bash -n "$f" 2>/dev/null || { err "синтаксическая ошибка в $f"; bad=1; }; done
  [ $bad = 0 ] && ok "скрипты прошли проверку синтаксиса" || die "скрипты повреждены, скачайте заново."
  [ -f "$KIT/VERSION" ] && info "версия набора: $(cat "$KIT/VERSION")"
}
install_files(){
  mkdir -p "$DD"; chmod 700 "$DD"
  local f
  for f in "$KIT"/awg/*; do cp "$f" "$DD/"; done
  chmod 755 "$DD"/*.sh; chmod 700 "$DD/notify.sh" "$DD/awg-notify.sh"
  [ -f "$KIT/install.sh" ] && { cp "$KIT/install.sh" "$DD/install.sh"; chmod 755 "$DD/install.sh"; }
  [ -f "$KIT/VERSION" ] && cp "$KIT/VERSION" "$DD/VERSION"
  write_subnets_files
  touch "$DD/.installer"
  ok "скрипты установлены в $DD"
}

# ============================================================ бинарники ===
bins_ok(){ [ -x "$DD/awg" ] && [ -x "$DD/amneziawg-go" ] && "$DD/awg" --version >/dev/null 2>&1; }
step_bins(){
  title "Бинарники AmneziaWG (amneziawg-go и awg)"
  if bins_ok; then
    ok "уже установлены: $("$DD/awg" --version 2>&1 | head -1)"
    yn "Оставить их?" Y && return 0
  fi
  local a url src t=$WORK/bin
  while :; do
    choose a "Откуда взять бинарники под aarch64?" \
      "Скачать архив проекта AmneziaWG-Unifi-DreamMachine (проверено, рекомендуется)" \
      "Указать другой URL архива .tar.gz (внутри должны быть amneziawg-go и awg)" \
      "Указать папку на роутере, где уже лежат amneziawg-go и awg" \
      "Выйти"
    rm -rf "$t"; mkdir -p "$t"
    case $a in
      1|2)
        url=$BIN_URL_DEFAULT; [ "$a" = 2 ] && ask url "URL архива" ""
        info "скачиваю $url"
        if ! curl -fL -m 300 "$url" -o "$t/b.tgz"; then err "скачать не удалось"; hint "Проверьте доступ к github.com. Если ссылка устарела, откройте страницу проекта и возьмите актуальный архив …-source.tar.gz."; continue; fi
        tar xzf "$t/b.tgz" -C "$t" 2>/dev/null || { err "это не архив tar.gz"; continue; }
        src=$t;;
      3) ask src "Папка" "/tmp";;
      4) exit 1;;
    esac
    local fa fb
    fa=$(find "$src" -type f -name amneziawg-go 2>/dev/null | head -1); fb=$(find "$src" -type f -name awg 2>/dev/null | head -1)
    if [ -z "$fa" ] || [ -z "$fb" ]; then err "не нашёл файлы amneziawg-go и awg в $src"; continue; fi
    cp "$fa" "$DD/amneziawg-go"; cp "$fb" "$DD/awg"; chmod 755 "$DD/amneziawg-go" "$DD/awg"
    local v; v=$("$DD/awg" --version 2>&1 | head -1)
    if bins_ok; then
      ok "установлены: $v"
      info "sha256: $(sha256sum "$DD/amneziawg-go" | cut -c1-16)… (amneziawg-go), $(sha256sum "$DD/awg" | cut -c1-16)… (awg)"
      rm -rf "$t"; return 0
    fi
    err "бинарник не запускается: $v"
    echo "$v" | grep -qi 'exec format' && hint "Файлы собраны не под aarch64. Нужна сборка linux/arm64."
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

get_conf(){  # get_conf ИМЯ_ФАЙЛА "описание" — кладёт конфиг в $DD/ИМЯ
  local name=$1 what=$2 dest=$DD/$1 a p tmp=$DD/.incoming.conf
  if [ -s "$dest" ]; then
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
      2) local cf; cf=main.conf; [ "$ifc" = "$BACKUP_NAME" ] && cf=backup.conf; rm -f "$DD/$cf"; get_conf "$cf" "$what";;
      3) warn "продолжаю с нерабочим $ifc"; return 1;;
      4) exit 1;;
    esac
  done
}

diag_tunnel(){  # diag_tunnel ИНТЕРФЕЙС [порт_на_своём_VPS]
  local ifc=$1 srvport=$2 cf host port epip cap out in hs rx wan srvcap sin=-1 sout=-1
  cf=main.conf; [ "$ifc" = "$BACKUP_NAME" ] && cf=backup.conf
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
ssh_opts(){
  SSHO=(-n -p "$VPS_SSHPORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o "ControlPath=$CTL")
  SCPO=(-P "$VPS_SSHPORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o "ControlPath=$CTL")
}
ssh_master(){  # одно подключение с паролем на весь сеанс
  ssh -O check -p "$VPS_SSHPORT" -o "ControlPath=$CTL" "$VPS_USER@$VPS_IP" >/dev/null 2>&1 && return 0
  ssh -fN -p "$VPS_SSHPORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=yes -o "ControlPath=$CTL" -o ControlPersist=900 "$VPS_USER@$VPS_IP"
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
      vssh 'bash /root/awg-server-build.sh' 2>&1 | sed 's/^/    │ /'
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
  local cfg=$1 base="https://raw.githubusercontent.com/$AWG_REPO/$AWG_BRANCH/server"
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
      "$DD/awg-detect.sh" "$rail" | sed 's/^/    /'
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
  cp "$DD/awg-failover.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable awg-failover >/dev/null 2>&1
  systemctl restart awg-failover
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
  touch /tmp/awg-sim-down
  for i in $(seq 1 40); do grep -q 'ПЕРЕКЛЮЧЕНИЕ' <(tail -n 3 "$DD/failover.log" 2>/dev/null) && break; sleep 1; done
  if ip route show table "$t" | grep -q "dev $BACKUP_NAME .*metric 5"; then
    ok "переключение сработало за ~${i} с: PBR-трафик идёт через $BACKUP_NAME"
  else
    err "переключения не произошло"; tail -n 5 "$DD/failover.log" | sed 's/^/    /'
    hint "Запасной канал должен отвечать: curl --interface $BACKUP_NAME https://ifconfig.me"
  fi
  rm -f /tmp/awg-sim-down
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

write_subnets_files(){
  mkdir -p "$DD"
  cat > "$DD/subnets.sh" <<'SUBS'
#!/bin/bash
# awg-subnets: подсети VPN-сервера роутера (WireGuard Server, Teleport и т.п.) целиком идут через AWG-туннель.
#   subnets.sh run      служба: каждые 5 с сверяет правила
#   subnets.sh apply    один проход
#   subnets.sh remove   убрать все правила и маршруты этой службы
#   subnets.sh check    проверка: OK / WARN / FAIL
#   subnets.sh status   правила и таблица PBR
DD=${DD:-/data/awg}
P_LOCAL=${SUBNET_PRIO_LOCAL:-6100}
P_PBR=${SUBNET_PRIO_PBR:-6101}
load(){ EXTRA_SUBNETS=""; TABLE=""; [ -r "$DD/awg.env" ] && . "$DD/awg.env"; }
sub_iface(){ ip -4 route show table all to "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
probe_host(){ local a b c d; IFS=. read -r a b c d <<< "${1%/*}"; d=$((d+2)); [ "$d" -gt 254 ] && d=$((d-3)); echo "$a.$b.$c.$d"; }

cleanup(){  # убрать правила для подсетей не из списка и правила, ведущие не в текущую таблицу
  local p src tbl keep s
  ip -4 rule show | awk -v a="$P_LOCAL:" -v b="$P_PBR:" '$1==a || $1==b {print $1, $3, $5}' | while read -r p src tbl; do
    keep=0
    for s in $EXTRA_SUBNETS; do [ "$s" = "$src" ] && keep=1; done
    [ "$p" = "$P_PBR:" ] && [ "${tbl%%.*}" != "$TABLE" ] && keep=0
    if [ $keep = 0 ]; then
      ip -4 rule del from "$src" priority "${p%:}" 2>/dev/null
      [ "$p" = "$P_PBR:" ] && ip -4 route del "$src" table "$TABLE" 2>/dev/null
    fi
  done
}
apply(){
  load
  [ -n "$TABLE" ] && [ "$TABLE" != 0 ] || return 0
  cleanup
  local s i
  for s in $EXTRA_SUBNETS; do
    ip -4 rule add from "$s" lookup main suppress_prefixlength 0 priority "$P_LOCAL" 2>/dev/null
    ip -4 rule add from "$s" lookup "$TABLE" priority "$P_PBR" 2>/dev/null
    i=$(sub_iface "$s")
    [ -n "$i" ] && ip -4 route replace "$s" dev "$i" table "$TABLE" 2>/dev/null
  done
  return 0
}
check(){
  load
  local s i h out dev rc=0
  [ -n "$EXTRA_SUBNETS" ] || { echo "INFO   подсети не заданы"; return 0; }
  for s in $EXTRA_SUBNETS; do
    if ip -4 rule show | grep -q "^$P_LOCAL:.*from $s lookup main suppress_prefixlength 0"; then echo "OK     $s: локальные адреса остаются локальными (правило $P_LOCAL)"
    else echo "FAIL   $s: нет правила $P_LOCAL (служба awg-subnets запущена?)"; rc=1; fi
    if ip -4 rule show | grep -q "^$P_PBR:.*from $s lookup $TABLE"; then echo "OK     $s: интернет-трафик отправляется в таблицу PBR $TABLE (правило $P_PBR)"
    else echo "FAIL   $s: нет правила $P_PBR в таблицу $TABLE"; rc=1; fi
    i=$(sub_iface "$s")
    [ -n "$i" ] || echo "WARN   $s: сейчас нет интерфейса с этой подсетью (VPN-сервер выключен?)"
    h=$(probe_host "$s")
    out=$(ip -4 route get 1.1.1.1 from "$h" ${i:+iif $i} 2>&1 | head -n 1)
    dev=$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$dev" in
      awg*) echo "OK     $s: интернет через $dev"
            iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $dev -j MASQUERADE" || { echo "FAIL   нет NAT MASQUERADE на $dev (сторож не запущен?)"; rc=1; } ;;
      *)    echo "FAIL   $s: интернет идёт через «${dev:-?}», а не через awg-туннель (сторож awg-failover ещё не положил маршрут?)"; rc=1 ;;
    esac
  done
  return $rc
}
case "${1:-run}" in
  run)    trap 'exit 0' TERM INT; while :; do apply; sleep 5 & wait $!; done;;
  apply)  apply;;
  remove) load; EXTRA_SUBNETS=""; cleanup;;
  check)  check;;
  status) load; ip -4 rule show | grep -E "^($P_LOCAL|$P_PBR):"; echo "-- таблица $TABLE:"; ip -4 route show table "$TABLE";;
  *)      echo "использование: $0 [run|apply|remove|check|status]"; exit 1;;
esac
SUBS
  chmod 755 "$DD/subnets.sh"
  cat > "$DD/awg-subnets.service" <<'UNIT'
[Unit]
Description=AWG: route VPN-server subnets (WireGuard Server, Teleport) through the tunnel
After=awg-failover.service network-online.target

[Service]
ExecStart=/data/awg/subnets.sh run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

legacy_subnet_check(){  # старые самодельные решения, которые делают то же самое
  local f u s
  for f in awg-keep.sh wgsrv-pbr.sh; do
    [ -f "$DD/$f" ] && warn "найден $DD/$f: скрипт другой схемы, он тоже управляет маршрутами подсетей. Две схемы одновременно не используйте."
  done
  if [ -f /etc/systemd/system/wgsrv-routing.service ] && { systemctl is-enabled --quiet wgsrv-routing 2>/dev/null || svc_active wgsrv-routing; }; then
    warn "включена ваша служба wgsrv-routing: она направляет подсеть в таблицу профиля UniFi (wgclt) и конфликтует с новой схемой."
    if yn "Отключить её (файл службы останется)?" Y; then
      systemctl disable --now wgsrv-routing >/dev/null 2>&1
      ip -4 rule show | awk '$1=="100:" && /lookup [0-9]+\.wgclt/ {print $3}' | while read -r s; do ip -4 rule del from "$s" priority 100 2>/dev/null; done
      ok "wgsrv-routing отключена"
    fi
  fi
  [ -f /etc/systemd/system/wgsrv-pbr.service ] && info "служба wgsrv-pbr добавляет подсеть в ipset UBIOS4local_network. Новой схеме она не нужна и не мешает, оставляю как есть."
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
  write_subnets_files
  if [ -n "$s" ]; then
    cp "$DD/awg-subnets.service" /etc/systemd/system/awg-subnets.service
    systemctl daemon-reload
    systemctl enable awg-subnets >/dev/null 2>&1
    systemctl restart awg-subnets
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
    [ -x "$DD/subnets.sh" ] && "$DD/subnets.sh" remove
    systemctl disable --now awg-subnets >/dev/null 2>&1
    rm -f /etc/systemd/system/awg-subnets.service; systemctl daemon-reload
    ok "подсети отключены, правила убраны"
  fi
}

# ============================================================ опции =======
step_panel(){
  title "Панель при входе по SSH"
  grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null || cat >> /root/.bashrc <<'RC'
alias awgs='/data/awg/status.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
  grep -q "alias awg-setup=" /root/.bashrc 2>/dev/null || echo "alias awg-setup='/data/awg/install.sh'" >> /root/.bashrc
  touch "$DD/.panel"
  ok "панель будет появляться при входе по SSH; вручную — команда awgs"
  if [ -s /etc/motd ] && yn "Убрать стандартный баннер UniFi при входе (оригинал сохраню в $DD/motd.orig)?" Y; then
    [ -f "$DD/motd.orig" ] || cp -a /etc/motd "$DD/motd.orig"
    : > /etc/motd; touch /root/.hushlogin
    cp "$DD/awg-motd.service" /etc/systemd/system/; systemctl daemon-reload; systemctl enable awg-motd >/dev/null 2>&1
    ok "баннер убран, после перезагрузки тоже"
  fi
}
step_audit(){
  title "Аудит"
  grep -q "alias awg-audit=" /root/.bashrc 2>/dev/null || echo "alias awg-audit='/data/awg/audit.sh'" >> /root/.bashrc
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
  cp "$DD/awg-notify.service" /etc/systemd/system/; systemctl daemon-reload
  systemctl enable awg-notify >/dev/null 2>&1; systemctl restart awg-notify
  svc_active awg-notify && ok "служба awg-notify запущена (события, контроль раз в минуту, отчёт в ${t:0:2}:${t:2:2})" || err "awg-notify не запустилась: journalctl -u awg-notify -n 20"
}

# ============================================================ мастер ======
SCEN=; EXT=0
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
  if [ "$SCEN" = C ]; then env_set BACKUP "$BACKUP_NAME"; else env_set BACKUP ""; ip link del "$BACKUP_NAME" 2>/dev/null; fi
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

  title "Дополнительно"
  yn "Панель состояния при входе по SSH?" Y && step_panel
  yn "Установить аудит awg-audit (проверка на лишние правила и файлы)?" Y && step_audit
  yn "Уведомления в Telegram?" N && step_telegram
  [ -n "$VPS_IP" ] && yn "Запустить аудит VPS?" Y && vps_audit
  summary
}

summary(){
  title "Готово"
  local t; t=$(env_get TABLE)
  say "  Установлено в ${B}$DD${N}. Таблица PBR ${B}$t${N}, туннели: ${B}$MAIN${N}$( [ -n "$(env_get BACKUP)" ] && echo " + ${B}$(env_get BACKUP)${N}")."
  [ -n "$(env_get EXTRA_SUBNETS)" ] && say "  Через туннель идут и клиенты VPN-сервера роутера: ${B}$(env_get EXTRA_SUBNETS)${N} (проверка: $DD/subnets.sh check)."
  [ -x "$DD/status.sh" ] && "$DD/status.sh" -s | sed 's/^/  /'
  say "  ${B}Проверьте сами:${N}"
  say "   • устройство под правилом PBR: на 2ip.io виден IP туннеля;"
  say "   • устройство вне PBR: виден ваш обычный IP;"
  say "   • перезагрузите роутер, когда удобно, и через 2–3 минуты повторите проверку."
  say "  ${B}Дальше:${N} меню обслуживания — ${C}$DD/install.sh${N}; после обновления прошивки — ${C}$DD/install.sh --restore${N}."
  say "  ${D}Конфиги с ключами: $DD/*.conf (права 600). Ключи и токены не отправляйте в чаты. Журнал установки: $ILOG${N}"
  ilog "установка завершена, сценарий $SCEN"
}

# ============================================================ меню =========
do_update(){
  get_kit
  title "Обновление скриптов"
  [ -f "$DD/VERSION" ] && info "сейчас: $(cat "$DD/VERSION"), будет: $(cat "$KIT/VERSION" 2>/dev/null || echo ?)"
  local bk; bk="$DD/backup-$(date +%Y%m%d-%H%M%S).tgz"
  ( umask 077; tar czf "$bk" -C "$DD" --exclude='backup-*.tgz' . 2>/dev/null ) && ok "резервная копия: $bk"
  install_files
  systemctl daemon-reload
  if svc_active awg-failover; then cp "$DD/awg-failover.service" /etc/systemd/system/; systemctl daemon-reload; systemctl restart awg-failover; ok "сторож перезапущен"; fi
  if svc_active awg-notify; then cp "$DD/awg-notify.service" /etc/systemd/system/; systemctl daemon-reload; systemctl restart awg-notify; ok "awg-notify перезапущен"; fi
  if svc_active awg-subnets; then cp "$DD/awg-subnets.service" /etc/systemd/system/; systemctl daemon-reload; systemctl restart awg-subnets; ok "awg-subnets перезапущен"; fi
  [ -x "$DD/audit.sh" ] && "$DD/audit.sh" | tail -n 3
}
do_restore(){
  title "Восстановление после обновления прошивки"
  [ -x "$DD/awg-restore.sh" ] || die "нет $DD/awg-restore.sh — установка не найдена"
  "$DD/awg-restore.sh" | sed 's/^/  /'
  local t; t=$(env_get TABLE)
  if [ -n "$(env_get EXTRA_SUBNETS)" ] && [ -f "$DD/awg-subnets.service" ]; then
    cp "$DD/awg-subnets.service" /etc/systemd/system/; systemctl daemon-reload; systemctl enable --now awg-subnets >/dev/null 2>&1
    ok "служба awg-subnets восстановлена"
  fi
  if ! ip rule show | grep -q "fwmark $(env_get MARK | cut -d/ -f1)"; then
    warn "правило PBR с меткой $(env_get MARK) не найдено: UniFi мог пересоздать профиль"
    yn "Определить таблицу и метку заново?" Y && { step_rail; systemctl restart awg-failover; }
  fi
  sleep 6; ip route show table "$t" | grep -q 'metric 5' && ok "PBR-трафик снова идёт через туннель" || warn "маршрута в таблице $t нет: запустите диагностику ($DD/install.sh → Диагностика)"
}
do_uninstall(){
  title "Удаление"
  warn "Сначала удалите в UniFi правила Policy-Based Routes, ссылающиеся на рельсу: иначе их устройства останутся без интернета."
  yn "Удалить службы, маршруты и правила AWG с роутера?" N || return
  local purge="" v; v=$(env_get VPS_IP 2>/dev/null)
  yn "Удалить и папку $DD с конфигами и ключами?" N && purge=--purge
  if [ -x "$DD/subnets.sh" ]; then
    "$DD/subnets.sh" remove; systemctl disable --now awg-subnets >/dev/null 2>&1
    rm -f /etc/systemd/system/awg-subnets.service; systemctl daemon-reload; ok "правила подсетей VPN-сервера убраны"
  fi
  if [ -x "$DD/awg-uninstall.sh" ]; then "$DD/awg-uninstall.sh" $purge | sed 's/^/  /'; else err "нет $DD/awg-uninstall.sh"; fi
  [ -n "$v" ] && info "На VPS $v сервер остался. Удалить там: systemctl disable --now awg-server; rm -rf /etc/amnezia /etc/systemd/system/awg-server.service /usr/local/bin/awg-up.sh"
  exit 0
}
do_diag(){
  local a i
  while :; do
    choose a "Диагностика:" "Аудит роутера (awg-audit)" "Проверить туннели (внешний IP, handshake)" "Подробная диагностика туннеля (tcpdump на WAN)" "Диагностика своего VPS по SSH (роутер + сервер)" "Журнал сторожа (последние 30 строк)" "Назад"
    case $a in
      1) [ -x "$DD/audit.sh" ] && "$DD/audit.sh" || err "audit.sh не установлен";;
      2) for i in $MAIN $(env_get BACKUP); do if ip=$(tun_ip "$i"); then ok "$i: IP $ip, handshake $(hs_age "$i") с назад"; else err "$i: не работает"; fi; done;;
      3) ask i "Интерфейс" "$MAIN"; diag_tunnel "$i";;
      4) get_kit; vps_connect && {
           AWG_PORT=$(vssh "awk -F'=' '/^ListenPort/{gsub(/ /,\"\",\$2); print \$2}' /etc/amnezia/server.conf" 2>/dev/null)
           i=$BACKUP_NAME; check_conf "$DD/main.conf" >/dev/null 2>&1; [ "${CONF_EP%:*}" = "$VPS_IP" ] && i=$MAIN
           diag_tunnel "$i" "${AWG_PORT:-51823}"; vput "$KIT/server/audit-server.sh" && vps_audit; };;
      5) tail -n 30 "$DD/failover.log" 2>/dev/null | sed 's/^/  /';;
      6) return;;
    esac
  done
}
do_components(){
  local a
  while :; do
    choose a "Компоненты:" "Заменить конфиг основного туннеля" "Добавить/заменить запасной туннель на VPS" "Убрать запасной туннель" "Клиенты VPN-сервера роутера (подсети)" "Время возврата на основной канал" "Панель при входе по SSH" "Аудит" "Telegram" "Заново определить таблицу и метку PBR" "Назад"
    case $a in
      1) rm -f "$DD/main.conf"; get_conf main.conf "новый конфиг основного туннеля"; bring_up_and_test "$MAIN" "основной туннель";;
      2) get_kit; install_files; env_set BACKUP "$BACKUP_NAME"; rm -f "$DD/backup.conf"; step_vps backup.conf; bring_up_and_test "$BACKUP_NAME" "запасной туннель"; step_watchdog; yn "Проверить переключение?" Y && test_switch;;
      3) env_set BACKUP ""; ip link del "$BACKUP_NAME" 2>/dev/null; while iptables -t nat -D POSTROUTING -o "$BACKUP_NAME" -j MASQUERADE 2>/dev/null; do :; done; step_watchdog; ok "работаем на одном туннеле";;
      4) step_subnets;;
      5) ask a "Секунд стабильной работы до возврата" "$(env_get RECOVER_SEC)"; [[ "$a" =~ ^[0-9]+$ ]] && { env_set RECOVER_SEC "$a"; systemctl restart awg-failover; ok "RECOVER_SEC=$a"; };;
      6) step_panel;;
      7) step_audit;;
      8) step_telegram;;
      9) step_rail; systemctl restart awg-failover; ok "сторож перезапущен";;
      10) return;;
    esac
  done
}
main_menu(){
  local a
  while :; do
    title "AmneziaWG для UDR7 · установщик $INSTALLER_VERSION"
    if [ -f "$DD/awg.env" ] && [ -x "$DD/failover.sh" ]; then
      info "установка найдена: $DD, сторож $(systemctl is-active awg-failover 2>/dev/null), туннели: $MAIN $(env_get BACKUP)"
    else
      info "установка не найдена"
    fi
    choose a "Что делаем?" \
      "Полная установка / перенастройка (мастер)" \
      "Обновить скрипты из репозитория (конфиги сохраняются)" \
      "Компоненты: конфиги, запасной канал, подсети, панель, аудит, Telegram" \
      "Диагностика" \
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

case "${1:-}" in --status|--help|-h) ;; *) open_tty;; esac
case "${1:-}" in
  --update)    need_root; do_update;;
  --restore)   need_root; do_restore;;
  --status)    [ -x "$DD/status.sh" ] && exec "$DD/status.sh" || die "панель не установлена";;
  --uninstall) need_root; do_uninstall;;
  --help|-h)   sed -n '2,17p' "$0" 2>/dev/null || echo "install.sh [--update|--restore|--status|--uninstall]";;
  "")          need_root; if [ -f "$DD/awg.env" ] && [ -x "$DD/failover.sh" ]; then main_menu; else wizard; fi;;
  *)           die "неизвестный ключ $1 (см. --help)";;
esac
