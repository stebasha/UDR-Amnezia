#!/bin/bash
# iptables всегда с ожиданием блокировки xtables: без -w iptables 1.8.7 (legacy) при занятой блокировке сразу падает,
# и проверка «есть ли правило» ошибочно отвечает «нет» → дубликаты и ложные предупреждения в check.
iptables(){ command iptables -w 10 "$@"; }
# awg-self: собственный трафик роутера UDR7 через AmneziaWG + рабочий unifi.ui.com из РФ + DNS-домены через туннель.
# Основа — awg-ui-fix.sh; адреса туннелей определяются автоматически (раньше было жёстко 10.8.1.x).
#
# 1) Зеркало PBR: соединения самого роутера идут по тем же Traffic Routes UniFi, что и LAN
#    (правила UniFi без Kill Switch, цепочка UBIOS_PREROUTING_PBR).
# 2) UI-модуль (UI_FIX=yes в awg.env) — то, что раньше делалось руками в UniFi:
#    - dnsmasq спрашивает домены UI_DOMAINS (ui.com) у резолвера UI_DNS (9.9.9.9), остальной DNS не трогается;
#    - запросы роутера к UI_DNS идут через AWG (geo-DNS Ubiquiti иначе отдаёт заглушку «Access Prohibited», HTTP 451);
#    - адреса UI_DOMAINS, которые резолвит dnsmasq, попадают в ipset AWG_UI, и соединения консоли с облаком
#      Ubiquiti тоже идут через AWG.
#
#   self.sh run        служба (awg-self.service): каждые 5 с сверяет правила
#   self.sh apply      один проход
#   self.sh reconnect  оборвать текущие соединения роутера к адресам из PBR, чтобы они переподключились через AWG
#   self.sh remove     убрать всё, что ставит эта служба (вкл. файл dnsmasq)
#   self.sh check      проверка: OK / WARN / FAIL
#   self.sh status     цепочка со счётчиками
DD=${DD:-/data/awg}
CH=AWG_SELF
UISET=AWG_UI
DOMSET=AWG_DOM        # адреса TUN_DOMAINS (клиенты LAN → туннель), наполняет dnsmasq
DIRSET=AWG_DIRECT     # адреса DIRECT_DOMAINS (исключения: напрямую), наполняет dnsmasq
UIFILE=zz-awg-ui.conf
HASHF=/tmp/awg-self.hash
RESTF=/tmp/awg-self.dnsmasq-restart
PRIV="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4"
SLOWF=${AWG_RUN:-/run}/awg-self.slow     # кэш редко меняющегося: адреса серверов туннелей, DNS-апстримы, подсети WAN
SLOW_TTL=${SLOW_TTL:-60}
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
# Проход службы повторяется каждые 5 с. В нём — один снимок таблицы mangle (правила UniFi PBR, переход в нашу цепочку,
# MSS) и разбор средствами bash; редко меняющееся — из кэша раз в SLOW_TTL с (сразу, если поменялся конфиг туннеля).
epoch(){ printf -v "$1" '%(%s)T' -1; }

load(){
  TABLE=""; MARK=""; MAIN=awgmain; BACKUP=""; WANIF=""; VPS_IP=""; TUNNELS_EXTRA=""
  UI_FIX=yes; UI_DOMAINS="ui.com"; UI_DNS=9.9.9.9
  TUN_DOMAINS=""; DIRECT_DOMAINS=""; DNS_ALL_TUNNEL=no
  [ -r "$DD/awg.env" ] && . "$DD/awg.env"
  [ -n "$WANIF" ] || WANIF=$(detect_wan)
  [ -n "$WANIF" ] || WANIF=ppp0
  MASK=${MARK#*/}; [ "$MASK" = "$MARK" ] && MASK=0xffffffff
  valid_ipv4 "$UI_DNS" || UI_DNS=""
}
detect_wan(){  # интерфейс WAN: первый default-маршрут в любой таблице не через туннель
  ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep -v -E '^(awg|wg|lo|wgclt)' | head -n1
}
# адреса самих туннелей: ответные пакеты соединений, ушедших через AWG, имеют dst=<адрес туннеля> (после MASQUERADE)
via_re(){
  local i a re=""
  for i in $MAIN $BACKUP $TUNNELS_EXTRA; do
    for a in $(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do re="$re${re:+|}${a//./\\.}"; done
  done
  [ -n "$re" ] && echo "dst=($re)( |\$)" || echo "dst=NO_TUNNEL_ADDRESS"
}
via_awg(){ grep -q -E "$(via_re)"; }
conf_on(){ ui_on || [ -n "$TUN_DOMAINS$DIRECT_DOMAINS" ]; }
ui_on(){ [ "$UI_FIX" = yes ] && [ -n "$UI_DOMAINS" ] && [ -n "$UI_DNS" ]; }
# добавить правило, только если iptables -C ответил «такого правила нет» (код 1); при другой ошибке — в следующий раз
ensure(){ local t=$1; shift; iptables -t "$t" -C "$@" 2>/dev/null; [ $? -eq 1 ] && iptables -t "$t" -A "$@"; return 0; }
valid_domain(){ [ ${#1} -le 253 ] && [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
valid_ipv4(){ local IFS=. o x; [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; read -ra o <<< "$1"; for x in "${o[@]}"; do [ "$x" -le 255 ] || return 1; done; }
domains(){ local d; for d in "$@"; do valid_domain "$d" && echo "$d" || log "пропускаю «$d»: не похоже на домен"; done; }
wanip(){ ip -4 -o addr show dev "$WANIF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
proc_of(){ ss -tnp state established dst "$1" 2>/dev/null | awk 'NR==2{print $NF}' | grep -oE '"[^"]+"' | head -n1; }
log(){ logger -t awg-self "$*" 2>/dev/null; }

# адреса серверов туннелей — их никогда не заворачиваем в туннель (иначе handshake туннеля уйдёт в другой туннель).
# Берём и из работающих интерфейсов, и из всех конфигов: туннель, который сейчас пересоздаётся, тоже нужно исключить.
EPF=${AWG_RUN:-/run}/awg-self.endpoints
endpoints(){
  local f ep h c
  {
    "$DD/awg" show all endpoints 2>/dev/null | awk '{print $3}'; wg show all endpoints 2>/dev/null | awk '{print $3}'; echo "$VPS_IP"
    cat "$EPF" 2>/dev/null
    for f in "$DD"/main.conf "$DD"/backup.conf "$DD"/client.conf $(for t in $TUNNELS_EXTRA; do echo "$DD/$t.conf"; done); do
      [ -r "$f" ] || continue
      ep=$(awk -F'=' 'tolower($1) ~ /^[ \t]*endpoint[ \t]*$/ {gsub(/[ \t\r]/,"",$2); print $2; exit}' "$f"); h=${ep%:*}
      if valid_ipv4 "$h"; then echo "$h"
      elif [ -n "$h" ]; then
        # адрес, который запомнил up.sh при подъёме туннеля; DNS спрашиваем, только если его нет (и не дольше 3 с)
        c=$(awk -v h="$h" '$1==h {print $2}' "$DD"/.endpoint-* 2>/dev/null | head -n1)
        if [ -n "$c" ]; then echo "$c"; else timeout 3 getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u; fi
      fi
    done
  } | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' | grep -E '^[0-9.]+$' | sort -u > "$EPF.t" && mv -f "$EPF.t" "$EPF"
  cat "$EPF"
}

# адреса, через которые роутер резолвит ВСЁ остальное (dnscrypt-proxy / DoH UniFi и server= в dnsmasq).
# Их никогда не заворачиваем в туннель, даже если IP случайно попал в списки PBR (общие CDN-адреса Cloudflare и т.п.):
# иначе через AWG уйдёт весь DNS роутера. Список запоминается, чтобы не зависеть от момента проверки.
UPF=/tmp/awg-self.upstreams
upstreams(){
  local pid conf
  # список копится (DoH-серверы меняются), но раз в сутки начинается заново, чтобы не держать устаревшие адреса
  if [ ! -f "$UPF.since" ] || [ $(( $(date +%s) - $(cat "$UPF.since" 2>/dev/null || echo 0) )) -gt 86400 ]; then date +%s > "$UPF.since"; : > "$UPF"; fi
  {
    cat "$UPF" 2>/dev/null
    ss -tunp state established 2>/dev/null | awk '/"dnscrypt-proxy"/{print $5}'
    if pid=$(dnsmasq_pid); then
      conf=$(tr '\0' '\n' < /proc/$pid/cmdline | sed -n 's/^--conf-file=//p')
      grep -hE '^server=[0-9]' "$conf" "$(conf_dir "$pid")"/* 2>/dev/null | grep -v "$UIFILE" | cut -d= -f2 | cut -d'#' -f1 | cut -d@ -f1
    fi
  } | sed -E 's/^\[::ffff://; s/\]?:[0-9]+$//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -v -E '^(127\.|10\.|192\.168\.|0\.)' | grep -v -x -F "${UI_DNS:-none}" | sort -u > "$UPF.tmp"
  mv -f "$UPF.tmp" "$UPF"; cat "$UPF"
}
unstick(){  # перевести текущие соединения роутера к адресу обратно на WAN (они могли уйти в AWG до исключения)
  [ "$DNS_ALL_TUNNEL" = yes ] && return 0
  local wip; wip=$(wanip)
  [ -n "$wip" ] && conntrack -L -s "$wip" -d "$1" 2>/dev/null | via_awg || return 0
  ss -K dst "$1" >/dev/null 2>&1; conntrack -D -s "$wip" -d "$1" >/dev/null 2>&1
  log "DNS-апстрим $1 возвращён на $WANIF"
}

unstick_ep(){  # handshake туннеля к серверу $1 ушёл в другой туннель (до исключения адреса): сбросить запись conntrack
  command -v conntrack >/dev/null || return 0
  local i a n=0
  # собственный UDP роутера, ушедший в туннель, имеет источником адрес туннеля; соединения клиентов LAN не трогаем
  for i in $MAIN $BACKUP $TUNNELS_EXTRA; do
    for a in $(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
      conntrack -L -p udp -s "$a" -d "$1" 2>/dev/null | grep -q . && { conntrack -D -p udp -s "$a" -d "$1" >/dev/null 2>&1; n=1; }
    done
  done
  [ $n = 1 ] && log "handshake к серверу туннеля $1 шёл через другой туннель: записи сброшены"
  return 0
}

# правила маркировки UniFi PBR без условия «источник = локальная сеть»
want(){
  iptables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null | grep -- ' -j MARK ' \
    | sed -E -e 's/^-A UBIOS_PREROUTING_PBR //' \
             -e 's/-m set --match-set UBIOS_local_network(v6)? src //' \
             -e 's/-m comment --comment [^ ]+ //' \
    | grep -v -E -- '--mac-source|(^| )-i |--match-set [^ ]+ src|(^| )-s ' | awk '!seen[$0]++'
}

hook(){  # переход в нашу цепочку должен быть ПЕРВЫМ в mangle OUTPUT (до UBIOS_OUTPUT_JUMP) и ровно одним
  local o n k
  o=$(iptables -t mangle -S OUTPUT 2>/dev/null) || return 0       # нет ответа (блокировка) — проверим в следующий раз
  n=$(printf '%s\n' "$o" | grep -c -x -- "-A OUTPUT -j $CH")
  [ "$n" = 1 ] && [ "$(printf '%s\n' "$o" | grep '^-A OUTPUT' | head -n1)" = "-A OUTPUT -j $CH" ] && return 0
  for ((k=0; k<n; k++)); do iptables -t mangle -D OUTPUT -j $CH 2>/dev/null || return 0; done
  iptables -t mangle -I OUTPUT 1 -j $CH
}

mss(){  # MSS для соединений самого роутера через туннель
  local i m r
  for i in $MAIN $BACKUP $TUNNELS_EXTRA; do
    m=$(cat /sys/class/net/$i/mtu 2>/dev/null) || continue
    ensure mangle POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    # после смены MTU правило со старым значением MSS больше не нужно
    iptables -t mangle -S PREROUTING 2>/dev/null | grep -E -- "^-A PREROUTING -i $i -p tcp .*--set-mss [0-9]+" | grep -v -- "--set-mss $((m-40))\$" \
      | sed 's/^-A /-D /' | while read -r r; do iptables -t mangle $r 2>/dev/null; done
    ensure mangle PREROUTING  -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40))
  done
}

# ---------- dnsmasq (UI-модуль) ----------
dnsmasq_pid(){  # основной dnsmasq UniFi (тот, что с --conf-dir: DNS + DHCP для LAN)
  local p
  p=$(cat /run/dnsmasq-main.pid 2>/dev/null)
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then echo "$p"; return 0; fi
  for p in $(pidof dnsmasq); do
    tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -q -- '^--conf-dir=' && { echo "$p"; return 0; }
  done
  return 1
}
conf_dir(){ tr '\0' '\n' < /proc/$1/cmdline 2>/dev/null | sed -n 's/^--conf-dir=//p' | cut -d, -f1 | head -n1; }
pstart(){  # время старта процесса, epoch
  local st bt hz
  st=$(awk '{print $22}' /proc/$1/stat 2>/dev/null); bt=$(awk '/^btime/{print $2}' /proc/stat); hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  [ -n "$st" ] && echo $(( bt + st / hz ))
}
ui_conf(){
  local d
  echo "# awg-self: файл создаёт /data/awg/self.sh, не редактировать."
  if ui_on; then
    echo "# домены UniFi резолвятся через $UI_DNS (через AWG)"
    # shellcheck disable=SC2086
    for d in $(domains $UI_DOMAINS); do echo "server=/$d/$UI_DNS"; echo "ipset=/$d/$UISET"; done
  fi
  # домены, которые клиенты LAN открывают через туннель / напрямую (правила маркировки ставит guard.sh).
  # Каждое имя проверяется: строка с ошибкой в файле dnsmasq оставила бы всю LAN без DNS.
  # shellcheck disable=SC2086
  for d in $(domains $TUN_DOMAINS); do echo "ipset=/$d/$DOMSET,${DOMSET}6"; done   # A → AWG_DOM, AAAA → AWG_DOM6 (guard отклоняет IPv6)
  # shellcheck disable=SC2086
  for d in $(domains $DIRECT_DOMAINS); do echo "ipset=/$d/$DIRSET"; done
}
restart_dnsmasq(){  # UniFi сам перезапускает dnsmasq; если нет — запускаем той же командой
  local pid=$1 cmd i np
  local last; last=$(cat $RESTF 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -lt 60 ] && return 0          # не чаще раза в минуту
  date +%s > $RESTF
  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
  log "перезапуск dnsmasq ($pid), чтобы подхватить $UIFILE"
  kill "$pid" 2>/dev/null
  for i in $(seq 1 15); do
    sleep 1; np=$(dnsmasq_pid) && [ "$np" != "$pid" ] && return 0
  done
  log "UniFi не поднял dnsmasq за 15 с — запускаю сам: $cmd"
  setsid $cmd </dev/null >/dev/null 2>&1 9>&- &
  sleep 2
}
ui_dns(){  # держит файл в conf-dir dnsmasq и следит, что dnsmasq его загрузил
  local pid dir f st mt
  pid=$(dnsmasq_pid) || { log "не найден dnsmasq с --conf-dir — UI-модуль пропущен"; return 0; }
  dir=$(conf_dir "$pid"); [ -d "$dir" ] || return 0
  f="$dir/$UIFILE"
  if ! conf_on; then
    [ -f "$f" ] && { rm -f "$f"; restart_dnsmasq "$pid"; }
    return 0
  fi
  if [ "$(cat "$f" 2>/dev/null)" != "$(ui_conf)" ]; then
    # файл с ошибкой не даст dnsmasq запуститься (вся LAN без DNS и DHCP): сначала проверка
    local t="$dir/.$UIFILE.tmp"          # имя с точкой: dnsmasq не читает такие файлы из conf-dir
    ui_conf > "$t"
    if command -v dnsmasq >/dev/null && ! dnsmasq --test --conf-file="$t" >/dev/null 2>&1; then
      log "dnsmasq отверг сгенерированный файл, оставляю прежний: $(dnsmasq --test --conf-file="$t" 2>&1 | head -n1)"; rm -f "$t"; return 0
    fi
    mv -f "$t" "$f"
  fi
  st=$(pstart "$pid"); mt=$(stat -c %Y "$f")
  [ -n "$st" ] && [ "$st" -lt "$mt" ] && restart_dnsmasq "$pid"   # dnsmasq старше файла → не видел его
  return 0
}

# команда сборки цепочки. Код 4 = блокировка xtables не освободилась: цепочку не подменяем, повтор через 5 с.
# Другие ошибки (правило UniFi, которое нельзя повторить для роутера) пропускаются, как раньше.
B(){ "$@" 2>/dev/null; [ $? -eq 4 ] && BERR=1; return 0; }
build(){  # собрать цепочку целиком в ${CH}_NEW и подменить: рабочая цепочка ни на миг не бывает пустой
  local w=$1 ep=$2 up=$3 T=${CH}_NEW O=${CH}_OLD n r
  BERR=0
  while iptables -t mangle -D OUTPUT -j $O 2>/dev/null; do :; done
  iptables -t mangle -F $O 2>/dev/null; iptables -t mangle -X $O 2>/dev/null
  iptables -t mangle -N $T 2>/dev/null; B iptables -t mangle -F $T
  B iptables -t mangle -A $T -m mark ! --mark "0x0/$MASK" -j RETURN
  # ответы на входящие соединения (WireGuard Server роутера, проброшенные службы, SSH) всегда уходят тем же путём, что пришли
  B iptables -t mangle -A $T -m conntrack --ctdir REPLY -j RETURN
  # служебный трафик WAN: DHCP, широковещание и подсеть провайдера на WAN-интерфейсе
  B iptables -t mangle -A $T -p udp --dport 67:68 -j RETURN
  B iptables -t mangle -A $T -d 255.255.255.255/32 -j RETURN
  for n in $(ip -4 route show dev "$WANIF" scope link 2>/dev/null | awk '$1 ~ /^[0-9.]+\/[0-9]+$/ {print $1}'); do B iptables -t mangle -A $T -d "$n" -j RETURN; done
  for n in $PRIV $ep; do B iptables -t mangle -A $T -d "$n" -j RETURN; done
  for n in $up; do   # общий DNS роутера: по умолчанию мимо туннеля; DNS_ALL_TUNNEL=yes — весь DNS роутера через AWG
    [ "$DNS_ALL_TUNNEL" = yes ] && B iptables -t mangle -A $T -d "$n" -j MARK --set-xmark "$MARK"
    B iptables -t mangle -A $T -d "$n" -j RETURN
  done
  if ui_on; then
    B iptables -t mangle -A $T -d "$UI_DNS" -j MARK --set-xmark "$MARK"
    B iptables -t mangle -A $T -d "$UI_DNS" -j RETURN
    B iptables -t mangle -A $T -m set --match-set $UISET dst -j MARK --set-xmark "$MARK"
    B iptables -t mangle -A $T -m set --match-set $UISET dst -j RETURN
  fi
  while read -r r; do  # как у UniFi: первое совпадение ставит метку и выходит
    [ -n "$r" ] || continue
    B iptables -t mangle -A $T $r && B iptables -t mangle -A $T ${r% -j MARK*} -j RETURN
  done <<< "$w"
  if [ "$BERR" != 0 ]; then              # что-то не применилось (блокировка xtables): рабочую цепочку не трогаем, повтор через 5 с
    iptables -t mangle -F $T 2>/dev/null; iptables -t mangle -X $T 2>/dev/null; return 1
  fi
  iptables -t mangle -S $CH >/dev/null 2>&1 && iptables -t mangle -E $CH $O
  iptables -t mangle -E $T $CH
  hook                                                   # переход на новую цепочку — первым
  while iptables -t mangle -D OUTPUT -j $O 2>/dev/null; do :; done
  iptables -t mangle -F $O 2>/dev/null; iptables -t mangle -X $O 2>/dev/null
}

# ---------- быстрый проход службы ----------
want_from(){  # want_from СНИМОК_mangle → W: то же, что want(), без внешних процессов
  local l r; local -A seen=()
  W=""
  while IFS= read -r l; do
    [[ $l == "-A UBIOS_PREROUTING_PBR "* && $l == *" -j MARK "* ]] || continue
    r=${l#-A UBIOS_PREROUTING_PBR }
    r=${r//-m set --match-set UBIOS_local_network src /}
    r=${r//-m set --match-set UBIOS_local_networkv6 src /}
    [[ $r =~ ^(.*)-m\ comment\ --comment\ [^\ ]+\ (.*)$ ]] && r="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    [[ $r == *--mac-source* || $r == "-i "* || $r == *" -i "* || $r == "-s "* || $r == *" -s "* ]] && continue
    [[ $r =~ --match-set\ [^\ ]+\ src ]] && continue
    [ -n "${seen[$r]:-}" ] && continue
    seen[$r]=1; W+="$r"$'\n'
  done <<< "$1"
  W=${W%$'\n'}
}
lines_of(){  # lines_of ФАЙЛ ПЕРЕМЕННАЯ — содержимое файла без завершающих переводов строк (как $(cat), но без cat)
  local l v=""
  if [ -r "$1" ]; then while IFS= read -r l || [ -n "$l" ]; do v+="$l"$'\n'; done < "$1"; fi
  while [[ $v == *$'\n' ]]; do v=${v%$'\n'}; done
  printf -v "$2" '%s' "$v"
}
slow_inputs(){  # → EP UP WS
  local now ts="" f stale=0
  epoch now
  { read -r ts < "$SLOWF.ts"; } 2>/dev/null
  { [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt "$SLOW_TTL" ]; } || stale=1
  [ -f "$EPF" ] && [ -f "$UPF" ] || stale=1
  if [ $stale = 0 ]; then
    for f in "$DD"/*.conf "$DD"/.endpoint-* "$DD/awg.env"; do [ "$f" -nt "$SLOWF.ts" ] && { stale=1; break; }; done
  fi
  if [ $stale = 1 ]; then
    EP=$(endpoints); UP=$(upstreams)
    WS=$(ip -4 route show dev "$WANIF" scope link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    printf '%s\n' "$WS" > "$SLOWF.ws"; printf '%s\n' "$now" > "$SLOWF.ts"
  else
    lines_of "$EPF" EP; lines_of "$UPF" UP; lines_of "$SLOWF.ws" WS
  fi
}
hook_from(){  # hook_from СНИМОК — переход в $CH первым в mangle OUTPUT и ровно один; без iptables, если так и есть
  local l first="" n=0 k
  while IFS= read -r l; do
    [[ $l == "-A OUTPUT "* ]] || continue
    [ -z "$first" ] && first=$l
    [ "$l" = "-A OUTPUT -j $CH" ] && n=$((n + 1))
  done <<< "$1"
  [ "$n" = 1 ] && [ "$first" = "-A OUTPUT -j $CH" ] && return 0
  for ((k=0; k<n; k++)); do iptables -t mangle -D OUTPUT -j $CH 2>/dev/null || return 0; done
  iptables -t mangle -I OUTPUT 1 -j $CH
}
mss_from(){  # mss_from СНИМОК — как mss(), но по снимку: iptables только если правило надо добавить или убрать
  local i m l want have
  for i in $MAIN $BACKUP $TUNNELS_EXTRA; do
    m=""; { read -r m < "/sys/class/net/$i/mtu"; } 2>/dev/null; [[ $m =~ ^[0-9]+$ ]] || continue
    [[ $'\n'$1$'\n' == *$'\n'"-A POSTROUTING -o $i -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"$'\n'* ]] \
      || ensure mangle POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    want="-A PREROUTING -i $i -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40))"; have=0
    while IFS= read -r l; do
      [[ $l == "-A PREROUTING -i $i -p tcp "*"--set-mss "* ]] || continue
      [ "$l" = "$want" ] && { have=1; continue; }
      # shellcheck disable=SC2086
      iptables -t mangle ${l/#-A /-D } 2>/dev/null          # MSS от прежнего MTU
    done <<< "$1"
    [ $have = 1 ] || ensure mangle PREROUTING -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40))
  done
}
dnsmasq_pid_v(){  # dnsmasq_pid_v ПЕРЕМЕННАЯ — как dnsmasq_pid, без cat/tr/grep в обычном случае
  local p="" a
  { read -r p < /run/dnsmasq-main.pid; } 2>/dev/null
  if [[ $p =~ ^[0-9]+$ ]] && [ -d "/proc/$p" ]; then printf -v "$1" '%s' "$p"; return 0; fi
  p=$(dnsmasq_pid) || return 1
  printf -v "$1" '%s' "$p"
}
conf_dir_v(){  # conf_dir_v ПЕРЕМЕННАЯ PID — каталог --conf-dir из командной строки dnsmasq
  local -a args=(); local a
  mapfile -d '' -t args < "/proc/$2/cmdline" 2>/dev/null
  for a in "${args[@]}"; do [[ $a == --conf-dir=* ]] && { a=${a#--conf-dir=}; printf -v "$1" '%s' "${a%%,*}"; return 0; }; done
  printf -v "$1" '%s' ""
}
pstart_v(){  # pstart_v ПЕРЕМЕННАЯ PID — время старта процесса (epoch) из /proc без awk
  local line rest k v bt=""; local -a f=()
  { IFS= read -r line < "/proc/$2/stat"; } 2>/dev/null || return 1
  rest=${line##*) }; read -ra f <<< "$rest"            # поля после «(имя)»: f[0] — поле 3, starttime (22) — f[19]
  while read -r k v; do [ "$k" = btime ] && { bt=$v; break; }; done < /proc/stat
  [[ ${f[19]:-} =~ ^[0-9]+$ ]] && [ -n "$bt" ] || return 1
  printf -v "$1" '%s' "$(( bt + f[19] / HZ ))"
}
bad_once(){  # о неверном имени — в журнал один раз, а не каждые 5 с (проход идёт в подоболочке: помним в файле)
  local bf=${AWG_RUN:-/run}/awg-self.bad l
  { while IFS= read -r l; do [ "$l" = "$1" ] && return 0; done < "$bf"; } 2>/dev/null
  printf '%s\n' "$1" >> "$bf" 2>/dev/null; log "пропускаю «$1»: не похоже на домен"
}
ui_conf_v(){  # ui_conf_v ПЕРЕМЕННАЯ — текст файла dnsmasq, как ui_conf
  local d o="# awg-self: файл создаёт /data/awg/self.sh, не редактировать."$'\n'
  if ui_on; then
    o+="# домены UniFi резолвятся через $UI_DNS (через AWG)"$'\n'
    for d in $UI_DOMAINS; do valid_domain "$d" || { bad_once "$d"; continue; }; o+="server=/$d/$UI_DNS"$'\n'"ipset=/$d/$UISET"$'\n'; done
  fi
  for d in $TUN_DOMAINS; do valid_domain "$d" || { bad_once "$d"; continue; }; o+="ipset=/$d/$DOMSET,${DOMSET}6"$'\n'; done
  for d in $DIRECT_DOMAINS; do valid_domain "$d" || { bad_once "$d"; continue; }; o+="ipset=/$d/$DIRSET"$'\n'; done
  printf -v "$1" '%s' "$o"
}
ui_dns_fast(){  # как ui_dns: файл в conf-dir dnsmasq; сверка «загрузил ли dnsmasq» — после записи, смены dnsmasq или раз в минуту
  local pid dir f st mt cur uc wrote=0 spid="" sts=0 now
  dnsmasq_pid_v pid || { log "не найден dnsmasq с --conf-dir — UI-модуль пропущен"; return 0; }
  conf_dir_v dir "$pid"; [ -d "$dir" ] || return 0
  f="$dir/$UIFILE"
  if ! conf_on; then
    [ -f "$f" ] && { rm -f "$f"; restart_dnsmasq "$pid"; }
    return 0
  fi
  ui_conf_v uc; lines_of "$f" cur
  if [ "$cur" != "${uc%$'\n'}" ]; then
    local t="$dir/.$UIFILE.tmp"          # имя с точкой: dnsmasq не читает такие файлы из conf-dir
    printf '%s' "$uc" > "$t"
    if command -v dnsmasq >/dev/null && ! dnsmasq --test --conf-file="$t" >/dev/null 2>&1; then
      log "dnsmasq отверг сгенерированный файл, оставляю прежний: $(dnsmasq --test --conf-file="$t" 2>&1 | head -n1)"; rm -f "$t"; return 0
    fi
    mv -f "$t" "$f"; wrote=1
  fi
  epoch now
  { read -r spid sts < "$RESTF.seen"; } 2>/dev/null
  if [ $wrote = 1 ] || [ "$spid" != "$pid" ] || [ $((now - ${sts:-0})) -ge 60 ]; then
    printf '%s %s\n' "$pid" "$now" > "$RESTF.seen"
    pstart_v st "$pid" || st=""; mt=$(stat -c %Y "$f")
    [ -n "$st" ] && [ "$st" -lt "$mt" ] && restart_dnsmasq "$pid"   # dnsmasq старше файла → не видел его
  fi
  return 0
}
legacy_once(){ [ -e /tmp/awg-self.legacy-checked ] && return 0; legacy; : > /tmp/awg-self.legacy-checked; }

apply(){  # один проход за раз (служба, ручной apply, установщик); блокировка снимается по выходу из подоболочки
  if command -v flock >/dev/null; then ( flock -w 30 9 || exit 0; apply_body ) 9>"${AWG_RUN:-/run}/awg-self.lock"; else apply_body; fi
  return 0
}

apply_body(){
  load
  [ -n "$TABLE" ] && [ -n "$MARK" ] || { echo "нет TABLE/MARK в awg.env"; return 0; }
  local mg W EP UP WS h old="" ip
  mg=$(iptables -t mangle -S 2>/dev/null) || return 0          # блокировка xtables не освободилась — в следующий проход
  want_from "$mg"
  slow_inputs
  printf -v h 'v11\n%s\n%s\n%s\n%s %s %s %s %s %s %s %s' "$W" "$EP" "$UP" "$UI_FIX" "$UI_DNS" "$UI_DOMAINS" "$DNS_ALL_TUNNEL" "$WANIF" "$MARK" "$WS" "$TUN_DOMAINS $DIRECT_DOMAINS"
  { IFS= read -r -d '' old < "$HASHF"; } 2>/dev/null
  if [ "$old" != "$h" ] || [[ $'\n'$mg$'\n' != *$'\n'"-N $CH"$'\n'* ]]; then
    ui_on && ipset create $UISET hash:ip family inet -exist
    [ -n "$TUN_DOMAINS" ] && { ipset create $DOMSET hash:ip family inet timeout 43200 -exist; ipset create ${DOMSET}6 hash:ip family inet6 timeout 43200 -exist; }
    [ -n "$DIRECT_DOMAINS" ] && ipset create $DIRSET hash:ip family inet timeout 43200 -exist
    if build "$W" "$EP" "$UP"; then
      printf '%s' "$h" > $HASHF
      for ip in $UP; do unstick "$ip"; done
      for ip in $EP; do unstick_ep "$ip"; done
    else rm -f $HASHF; fi
    mg=$(iptables -t mangle -S 2>/dev/null) || return 0          # цепочка пересобрана — сверка по свежему снимку
  fi
  legacy_once
  hook_from "$mg"
  mss_from "$mg"
  ui_dns_fast
  return 0
}

legacy(){  # убрать «весь DNS роутера через AWG» из промежуточной версии
  iptables -t mangle -S AWG_SELF_DNS >/dev/null 2>&1 || return 0
  local ip wip; wip=$(wanip)
  iptables -t mangle -F AWG_SELF_DNS; iptables -t mangle -X AWG_SELF_DNS 2>/dev/null
  for ip in $(cut -s -d' ' -f2- /tmp/awg-self.dns 2>/dev/null); do
    ss -K dst "$ip" >/dev/null 2>&1; [ -n "$wip" ] && conntrack -D -s "$wip" -d "$ip" >/dev/null 2>&1
  done
  rm -f /tmp/awg-self.dns /tmp/awg-self.dnsips
}

# ---------- проверки ----------
inset(){  # адрес в наборе? (UBIOS_* — list:set, проверяем участников)
  local s=$1 d=$2 m
  if ipset list -t "$s" 2>/dev/null | grep -q 'Type: list:set'; then
    for m in $(ipset list "$s" 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2); do
      ipset test "$m" "$d" >/dev/null 2>&1 && return 0
    done
    return 1
  fi
  ipset test "$s" "$d" >/dev/null 2>&1
}
chain_sets(){ iptables -t mangle -S $CH 2>/dev/null | awk '/-j MARK/{for(i=1;i<=NF;i++) if($i=="--match-set") print $(i+1)}' | sort -u; }
in_pbr(){  # уйдёт ли соединение роутера к адресу в AWG
  local s
  iptables -t mangle -S $CH 2>/dev/null | grep -q -- "-d $1/32 -j MARK" && return 0
  iptables -t mangle -S $CH 2>/dev/null | grep -q -- "-d $1/32 -j RETURN" && return 1   # исключён (VPS, DNS роутера)
  for s in $(chain_sets); do inset "$s" "$1" && return 0; done
  return 1
}

reconnect(){
  load
  local wip d n=0
  wip=$(wanip)
  [ -n "$wip" ] || { echo "не найден адрес на $WANIF"; return 1; }
  for d in $(conntrack -L -s "$wip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/){print substr($i,5); break}}' | sort -u); do
    iptables -t mangle -C $CH -d "$d" -j RETURN 2>/dev/null && ! iptables -t mangle -C $CH -d "$d" -j MARK --set-xmark "$MARK" 2>/dev/null && continue
    conntrack -L -s "$wip" -d "$d" 2>/dev/null | via_awg && continue   # уже через AWG
    if in_pbr "$d" && ip route get "$d" mark "${MARK%/*}" 2>/dev/null | grep -q 'dev awg'; then
      ss -K dst "$d" >/dev/null 2>&1
      conntrack -D -s "$wip" -d "$d" >/dev/null 2>&1
      echo "переподключение: $d"; n=$((n+1))
    fi
  done
  echo "оборвано направлений: $n"
}

remove(){
  load
  local i m pid dir
  for c in $CH ${CH}_OLD ${CH}_NEW; do
    while iptables -t mangle -D OUTPUT -j $c 2>/dev/null; do :; done
    iptables -t mangle -F $c 2>/dev/null; iptables -t mangle -X $c 2>/dev/null
  done
  for i in $MAIN $BACKUP $TUNNELS_EXTRA; do
    iptables -t mangle -D POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    m=$(cat /sys/class/net/$i/mtu 2>/dev/null) && iptables -t mangle -D PREROUTING -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40)) 2>/dev/null
  done
  legacy
  if pid=$(dnsmasq_pid); then
    dir=$(conf_dir "$pid")
    if [ -f "$dir/$UIFILE" ]; then rm -f "$dir/$UIFILE"; rm -f $RESTF; restart_dnsmasq "$pid"; fi
  fi
  ipset destroy $UISET 2>/dev/null
  rm -f $HASHF $UPF
}

check(){
  load
  local rc=0 n wip ok d c fw ips pid dir st mt up
  if [ "$(iptables -t mangle -S OUTPUT | grep '^-A OUTPUT' | head -n1)" = "-A OUTPUT -j $CH" ]; then echo "OK     цепочка $CH стоит первой в mangle OUTPUT"
  else echo "FAIL   переход в $CH не первый в mangle OUTPUT (служба awg-self запущена?)"; rc=1; fi
  # считаем только «корневые» процессы: подоболочки (циклы, конвейеры) самой службы — не копии
  local roots="" p pp
  for p in $(pgrep -f 'self\.sh run' 2>/dev/null); do
    pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    tr '\0' ' ' < "/proc/$pp/cmdline" 2>/dev/null | grep -q 'self\.sh run' || roots="$roots $p"
  done
  n=$(echo $roots | wc -w)
  [ "$n" -gt 1 ] && { echo "WARN   запущено $n копий «self.sh run» — должна быть одна (служба awg-self):$roots"; }
  local exp; exp=$(want | grep -c .); ui_on && exp=$((exp + 2)); [ "$DNS_ALL_TUNNEL" = yes ] && { c=$(grep -c . "$UPF" 2>/dev/null); exp=$((exp + ${c:-0})); }
  [ "$(iptables -t mangle -S $CH 2>/dev/null | grep -c -- ' -j MARK ')" -gt "$exp" ] && echo "WARN   в $CH есть лишние правила (выполните $DD/self.sh apply)"
  n=$(want | grep -c .)
  echo "INFO   правил PBR UniFi (без Kill Switch), повторённых для роутера: $n"
  iptables -t mangle -S AWG_SELF_DNS >/dev/null 2>&1 && echo "WARN   осталась цепочка AWG_SELF_DNS от старой версии (выполните apply)"
  echo "INFO   таблица $TABLE: $(ip route show table "$TABLE" | head -n1)"
  local u ubad=""; wip=$(wanip)
  for u in $(cat $UPF 2>/dev/null); do conntrack -L -s "$wip" -d "$u" 2>/dev/null | via_awg && ubad="$ubad $u"; done
  if [ -n "$ubad" ]; then echo "FAIL   общий DNS роутера идёт через AWG:$ubad (должен идти через $WANIF)"; rc=1
  else echo "OK     общий DNS роутера ($(cat $UPF 2>/dev/null | tr '\n' ' '| sed 's/ $//')) идёт мимо туннеля, через $WANIF"; fi

  if ui_on; then
    pid=$(dnsmasq_pid); dir=$(conf_dir "$pid")
    if [ -f "$dir/$UIFILE" ]; then
      st=$(pstart "$pid"); mt=$(stat -c %Y "$dir/$UIFILE")
      if [ "$st" -ge "$mt" ]; then echo "OK     dnsmasq загрузил $dir/$UIFILE: $UI_DOMAINS → $UI_DNS"
      else echo "FAIL   dnsmasq запущен раньше, чем появился $UIFILE (служба перезапустит его в течение минуты)"; rc=1; fi
    else echo "FAIL   нет $dir/$UIFILE (служба awg-self запущена?)"; rc=1; fi
    up=$(grep -rhE '^server=[0-9]' "$(dirname "$(tr '\0' '\n' < /proc/$pid/cmdline | sed -n 's/^--conf-file=//p')")" "$dir" 2>/dev/null | cut -d= -f2 | cut -d'#' -f1 | sort -u | tr '\n' ' ')
    echo " $up " | grep -q " $UI_DNS " && { echo "FAIL   $UI_DNS — это общий DNS роутера: через туннель уйдёт весь DNS. Задайте другой UI_DNS"; rc=1; }
    if in_pbr "$UI_DNS"; then echo "OK     запросы к $UI_DNS идут через AWG ($(ip route get "$UI_DNS" mark "${MARK%/*}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'))"
    else echo "FAIL   запросы к $UI_DNS не маркируются"; rc=1; fi
    echo "INFO   адресов облака в $UISET: $(ipset list $UISET 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | grep -c .)"
  else
    echo "INFO   UI-модуль выключен (UI_FIX=$UI_FIX)"
    fw=$(grep -rhoE 'server=/([a-z0-9.-]*/)*ui\.com/[^/]*/?[0-9.]+' /run/dnsmasq.dns.conf.d /run/dnsmasq.dhcp.conf.d 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    [ -n "$fw" ] && echo "INFO   есть Forward Domain ui.com из UniFi → $fw"
  fi

  if [ -n "$TUN_DOMAINS" ]; then
    ipset list -n 2>/dev/null | grep -qx $DOMSET && echo "OK     домены через туннель ($TUN_DOMAINS): набор $DOMSET есть, адресов: $(ipset list $DOMSET 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | grep -c .)" || { echo "FAIL   домены через туннель заданы, но набор $DOMSET не создан"; rc=1; }
  fi
  if [ -n "$DIRECT_DOMAINS" ]; then
    ipset list -n 2>/dev/null | grep -qx $DIRSET && echo "OK     домены-исключения ($DIRECT_DOMAINS): набор $DIRSET есть, адресов: $(ipset list $DIRSET 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | grep -c .)" || { echo "FAIL   домены-исключения заданы, но набор $DIRSET не создан"; rc=1; }
  fi
  [ "$DNS_ALL_TUNNEL" = yes ] && echo "INFO   DNS_ALL_TUNNEL=yes: весь DNS роутера идёт через туннель"
  if ui_on; then
    ips=$(getent ahostsv4 unifi.ui.com 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -z "$ips" ]; then echo "FAIL   unifi.ui.com не резолвится"; rc=1
    else  # заглушка определяется по ответу (451), а не по списку адресов: Ubiquiti меняет её IP
      local bad="" ip c2
      for ip in $ips; do
        c2=$(curl -s -o /dev/null -m 8 --resolve "unifi.ui.com:443:$ip" -w '%{http_code}' https://unifi.ui.com/ 2>/dev/null)
        [ "$c2" = 451 ] && bad="$bad $ip"
      done
      if [ -n "$bad" ]; then echo "FAIL   unifi.ui.com →$bad — заглушка 451 (geo-DNS); кэш? killall -HUP dnsmasq"; rc=1
      else echo "OK     unifi.ui.com → $ips(не заглушка)"; fi
    fi
  fi

  wip=$(wanip)
  ok=$(conntrack -L -s "$wip" 2>/dev/null | grep -c -E "$(via_re)")
  echo "INFO   соединений роутера через AWG сейчас: $ok"
  for d in $(ss -tn state established 2>/dev/null | awk 'NR>1{print $4}' | sed -E 's/^\[::ffff://; s/\]?:[0-9]+$//' | grep -E '^[0-9.]+$' | grep -v -E '^(192\.168|127\.|10\.)' | sort -u); do
    c=$(conntrack -L -s "$wip" -d "$d" 2>/dev/null | head -n1)
    if grep -qx -F "$d" "$UPF" 2>/dev/null && ! echo "$c" | via_awg; then echo "INFO   $d → DNS-апстрим роутера, идёт мимо туннеля через $WANIF — так и задумано"
    elif echo "$c" | via_awg; then echo "OK     $d → через AWG ($(proc_of "$d"))"
    elif [ -n "$c" ]; then
      if in_pbr "$d"; then echo "WARN   $d → должно идти через AWG, но идёт напрямую через $WANIF ($(proc_of "$d")): старое соединение, нужен reconnect"
      else echo "INFO   $d → не в списках, напрямую через $WANIF ($(proc_of "$d")) — так и задумано"; fi
    fi
  done
  return $rc
}

case "${1:-run}" in
  run)       STOP=""; trap 'STOP=1' TERM INT; exec {SLEEPFD}<> <(:)    # сигнал — флажок (см. failover.sh)
             while [ -z "$STOP" ]; do apply; [ -z "$STOP" ] && read -r -t 5 -u "$SLEEPFD" _ 2>/dev/null; done; exit 0;;
  apply)     rm -f "$HASHF" "$SLOWF.ts" /tmp/awg-self.legacy-checked; apply;;   # ручной запуск всегда пересобирает цепочку
  reconnect) reconnect;;
  remove)    remove;;
  check)     check;;
  status)    iptables -t mangle -L $CH -v -n --line-numbers; iptables -t mangle -S OUTPUT; ipset list $UISET 2>/dev/null | head -20;;
  *)         echo "использование: $0 [run|apply|reconnect|remove|check|status]"; exit 1;;
esac
