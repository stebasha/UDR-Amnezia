#!/bin/bash
# vps.sh — управление своим VPS (сервер запасного канала) с роутера по SSH ключом роутера (#13).
#   vps.sh test                  вход по ключу без пароля
#   vps.sh tunnels               туннели, ведущие на этот VPS
#   vps.sh status                состояние сервера (audit-server.sh, только чтение), версии AmneziaWG, нагрузка, место
#   vps.sh versions              версии amneziawg-go и awg на VPS и последние релизы amnezia-vpn (код 10 — есть новее)
#   vps.sh update                собрать последние релизы на VPS и перезапустить сервер; нет handshake — откат на *.prev
#   vps.sh rotate-keys [ТУННЕЛЬ] новые ключи сервера и роутера одновременно; нет handshake — откат на обеих сторонах
#   vps.sh obfs [ТУННЕЛЬ]        новые параметры обфускации (Jc, Jmin, Jmax, S1, S2, H1–H4) на обеих сторонах, с откатом
# Адрес — VPS_IP из awg.env (или VPS_HOST в vps.env), VPS_PORT и VPS_USER — в vps.env. Ключ роутера — ssh/id_ed25519
# (создаёт установщик при настройке VPS). Туннель к VPS определяется по Endpoint = адрес VPS.
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
RKEY=${RKEY:-$DD/ssh/id_ed25519}
SRV=${SRV:-$DD/server}
VPS_WAIT=${VPS_WAIT:-25}
umask 077
# shellcheck disable=SC1091
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNNELS_EXTRA=${TUNNELS_EXTRA:-}
VPS_HOST=""; VPS_PORT=22; VPS_USER=root
# shellcheck disable=SC1091
[ -r "$DD/vps.env" ] && . "$DD/vps.env"
VPS_HOST=${VPS_HOST:-${VPS_IP:-}}

say(){ printf '%s\n' "$*"; }
die(){ say "ОШИБКА: $*"; exit 1; }
event(){ echo "$(date +%s)|vps|$1" >> "$DD/events.log"; }
notify(){ if { [ -r "$DD/telegram.env" ] || [ -r "$DD/hooks.env" ]; } && [ -x "$DD/notify.sh" ]; then "$DD/notify.sh" "$1" >/dev/null 2>&1; fi; return 0; }

valid(){
  [ -n "$VPS_HOST" ] || die "адрес VPS не задан (VPS_IP в awg.env или «VPS» в панели)"
  [[ $VPS_HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$ ]] || die "неверный адрес VPS: $VPS_HOST"
  [[ $VPS_PORT =~ ^[0-9]{1,5}$ ]] || die "неверный порт SSH: $VPS_PORT"
  [[ $VPS_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "неверный пользователь: $VPS_USER"
  [ -f "$RKEY" ] || die "нет ключа роутера $RKEY: запустите установщик → VPS (он создаст ключ и добавит его на сервер)"
  mkdir -p "$DD/ssh"; chmod 700 "$DD/ssh"
  SSHO=(-p "$VPS_PORT" -i "$RKEY" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$DD/ssh/known_hosts")
  SCPO=(-q -P "$VPS_PORT" -i "$RKEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$DD/ssh/known_hosts")
}
vrun(){ ssh "${SSHO[@]}" "$VPS_USER@$VPS_HOST" "$@" < /dev/null; }
vput(){ scp "${SCPO[@]}" "$@" "$VPS_USER@$VPS_HOST:/root/"; }
need_script(){ [ -f "$SRV/$1" ] || die "нет $SRV/$1: обновите набор (install.sh --update)"; }

conf_of(){
  if [ "$1" = "$MAIN" ]; then echo main.conf
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then
    if [ -f "$DD/backup.conf" ] || [ ! -f "$DD/client.conf" ]; then echo backup.conf; else echo client.conf; fi
  else case " $TUNNELS_EXTRA " in *" $1 "*) echo "$1.conf";; esac; fi
}
conf_get(){ awk -v k="$2" 'BEGIN{k=tolower(k)} { line=$0; sub(/\r$/,"",line); split(line,a,"="); key=a[1]; gsub(/[ \t]/,"",key) } tolower(key)==k { sub(/^[^=]*=[ \t]*/,"",line); print line; exit }' "$1"; }
hs_age(){ local ts; ts=$("$DD/awg" show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
vps_tunnels(){  # туннели, у которых Endpoint — этот VPS (имя или адрес, в т. ч. разрешённый up.sh)
  local t cf ep host ip
  for t in $MAIN $BACKUP $TUNNELS_EXTRA; do
    cf=$DD/$(conf_of "$t"); [ -f "$cf" ] || continue
    ep=$(conf_get "$cf" Endpoint | tr -d ' \r'); host=${ep%:*}
    ip=$(awk '{print $2}' "$DD/.endpoint-$t" 2>/dev/null)
    if [ "$host" = "$VPS_HOST" ] || [ "$ip" = "$VPS_HOST" ] || { [ -n "${VPS_IP:-}" ] && [ "$host" = "$VPS_IP" ]; }; then echo "$t"; fi
  done
}
pick(){  # pick [ТУННЕЛЬ] → $T, $CF
  local l; l=$(vps_tunnels)
  [ -n "$l" ] || die "нет туннеля с Endpoint = $VPS_HOST: менять можно только свой сервер, не сервер провайдера"
  if [ -n "$1" ]; then echo "$l" | grep -qx "$1" || die "$1 — не туннель к $VPS_HOST (подходят: $(echo "$l" | tr '\n' ' '))"; T=$1
  else [ "$(echo "$l" | wc -l)" = 1 ] || die "к VPS ведут несколько туннелей ($(echo "$l" | tr '\n' ' ')): укажите какой"; T=$l; fi
  CF=$DD/$(conf_of "$T")
}
fresh(){ local a; a=$(hs_age "$1"); [ "$a" -ge 0 ] && [ "$a" -lt "${2:-20}" ]; }
wait_hs(){  # wait_hs ТУННЕЛЬ — handshake свежее 20 с за VPS_WAIT секунд и интернет через туннель
  local i
  for i in $(seq 1 "$VPS_WAIT"); do fresh "$1" && break; sleep 1; done
  fresh "$1" 30 || return 1
  curl -4 -s -m 8 -o /dev/null --interface "$1" https://1.1.1.1/ 2>/dev/null || curl -4 -s -m 8 -o /dev/null --interface "$1" https://api.ipify.org 2>/dev/null
}
set_obf(){  # set_obf КОНФИГ ФАЙЛ_С_ПАРАМЕТРАМИ — заменить Jc..H4 в [Interface]
  awk -v obf="$2" '
    BEGIN { while ((getline l < obf) > 0) { k = l; sub(/=.*/, "", k); gsub(/[ \t\r]/, "", k); v = l; sub(/^[^=]*=/, "", v); gsub(/[ \t\r]/, "", v); m[k] = v } }
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[[:space:]]/, "", sec) }
    sec == "[interface]" { k = $0; sub(/=.*/, "", k); gsub(/[ \t\r]/, "", k); if (k in m) { print k " = " m[k]; next } }
    { print }' "$1" > "$1.new" && mv "$1.new" "$1" && chmod 600 "$1"
}
set_keys(){  # set_keys КОНФИГ PrivateKey_РОУТЕРА PublicKey_СЕРВЕРА
  awk -v k="$2" -v p="$3" '
    /^[[:space:]]*\[/ { sec=tolower($0); gsub(/[[:space:]]/,"",sec) }
    sec=="[interface]" && /^[[:space:]]*PrivateKey[[:space:]]*=/ { print "PrivateKey = " k; next }
    sec=="[peer]" && /^[[:space:]]*PublicKey[[:space:]]*=/ { print "PublicKey = " p; next }
    { print }' "$1" > "$1.new" && mv "$1.new" "$1" && chmod 600 "$1"
}
gen_obf(){  # как awg-server-setup.sh: Jc 4–8, Jmin 40–80, Jmax больше Jmin, S1/S2 15–150 (S1+56 ≠ S2), H1–H4 разные > 4
  local jc jmin jmax s1 s2 h
  jc=$(shuf -i 4-8 -n 1); jmin=$(shuf -i 40-80 -n 1); jmax=$((jmin + $(shuf -i 60-200 -n 1)))
  s1=$(shuf -i 15-150 -n 1); s2=$(shuf -i 15-150 -n 1)
  while [ $((s1 + 56)) -eq "$s2" ] || [ "$s1" -eq "$s2" ]; do s2=$(shuf -i 15-150 -n 1); done
  mapfile -t h < <(shuf -i 5-2147483647 -n 4)
  printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$jc" "$jmin" "$jmax" "$s1" "$s2" "${h[0]}" "${h[1]}" "${h[2]}" "${h[3]}"
}

# согласованная смена: VPS (vps-rotate.sh) → роутер → проверка → при неудаче откат обеих сторон
coordinated(){  # coordinated ОПИСАНИЕ ПЕРЕМЕННЫЕ_ДЛЯ_VPS ФУНКЦИЯ_ДЛЯ_РОУТЕРА
  local what=$1 renv=$2 apply=$3 pre out bk sp
  pre="$CF.pre-vps-$(date +%s)"; cp -p "$CF" "$pre"
  say "· копия конфига роутера: $pre"
  vput "$SRV/vps-rotate.sh" || die "не удалось передать vps-rotate.sh на VPS"
  [ -n "${OBFL:-}" ] && { vput "$OBFL" || die "не удалось передать параметры на VPS"; }
  out=$(vrun "$renv bash /root/vps-rotate.sh" 2>&1)
  if echo "$out" | grep -q '^ERROR' || ! echo "$out" | grep -q '^BACKUP_FILE='; then
    vrun 'rm -f /root/vps-rotate.sh /root/awg-obf.txt' >/dev/null 2>&1; rm -f "$pre"
    die "VPS: $(echo "$out" | grep '^ERROR' | head -n1 | sed 's/^ERROR //')${out:+ }$(echo "$out" | grep -v '^ERROR' | tail -n1); ничего не изменено"
  fi
  bk=$(echo "$out" | sed -n 's/^BACKUP_FILE=//p'); sp=$(echo "$out" | sed -n 's/^NEW_SERVER_PUB=//p')
  say "· VPS: изменено, сервер перезапущен (копия $bk)"
  "$apply" "$sp"
  say "· роутер: конфиг $T обновлён, туннель пересоздан; жду handshake (до ${VPS_WAIT} с)…"
  "$DD/up.sh" "$T" >/dev/null 2>&1
  if wait_hs "$T"; then
    say "✔ $what: туннель $T работает (handshake есть, интернет через него открывается)"
    vrun 'rm -f /root/vps-rotate.sh /root/awg-obf.txt' >/dev/null 2>&1
    say "  прежний конфиг роутера: $pre (со старым ключом — удалите: shred -u $pre); на VPS: $bk"
    event "$what: $T — готово"; notify "🔑 $what · $(hostname): туннель $T работает на новых значениях"
    return 0
  fi
  say "✘ $what: туннель $T не заработал — откатываю обе стороны"
  cp -p "$pre" "$CF"
  out=$(vrun "ROLLBACK=$bk bash /root/vps-rotate.sh" 2>&1); echo "$out" | grep -q ROLLED_BACK && say "· VPS: возвращена копия $bk" || say "· VPS: откат не подтвердился: $(echo "$out" | tail -n1)"
  "$DD/up.sh" "$T" >/dev/null 2>&1
  vrun 'rm -f /root/vps-rotate.sh /root/awg-obf.txt' >/dev/null 2>&1
  if wait_hs "$T"; then say "· откат выполнен: $T работает на прежних значениях"; else say "· после отката $T не отвечает: смотрите «Диагностика» и awgctl selftest"; fi
  event "$what: $T — не заработало, откат"; notify "⚠️ $what · $(hostname): туннель $T не заработал, выполнен откат"
  return 1
}
apply_keys(){ set_keys "$CF" "$NK" "$1"; }
apply_obf(){ set_obf "$CF" "$OBFL"; }

latest(){  # latest amneziawg-go|amneziawg-tools — последний релиз или самый свежий тег в github.com/amnezia-vpn
  local tag
  tag=$(curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/amnezia-vpn/$1/releases/latest" 2>/dev/null | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
  [ -n "$tag" ] || tag=$(curl -fsSL -m 20 "https://api.github.com/repos/amnezia-vpn/$1/tags?per_page=30" 2>/dev/null | sed -n 's/^ *"name": *"\(v[0-9][0-9.]*\)".*/\1/p' | sort -V | tail -n1)
  [[ $tag =~ ^v[0-9][0-9.]*$ ]] && echo "$tag"
}
remote_versions(){  # → «go TAG» и «tools TAG» (из amnezia-build.txt или --version)
  vrun 'f=/usr/local/share/amnezia-build.txt; if [ -f $f ]; then awk "/^amneziawg-go /{print \"go\", \$2} /^amneziawg-tools /{print \"tools\", \$2}" $f; else
    echo "go $(amneziawg-go --version 2>&1 | grep -o "v[0-9][0-9.]*" | head -n1)"; echo "tools $(awg --version 2>&1 | grep -o "v[0-9][0-9.]*" | head -n1)"; fi' 2>/dev/null
}

cmd=${1:-help}; shift
case "$cmd" in
  tunnels) vps_tunnels;;
  test)
    valid
    r=$(vrun 'echo CONNECTED; uname -m; . /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"; systemctl is-active awg-server 2>/dev/null' 2>&1)
    if echo "$r" | grep -qx CONNECTED; then
      say "✔ вход на $VPS_USER@$VPS_HOST:$VPS_PORT ключом роутера работает: $(echo "$r" | sed -n '3p'), $(echo "$r" | sed -n '2p'); awg-server: $(echo "$r" | sed -n '4p')"
    else
      say "✘ не удалось войти на $VPS_USER@$VPS_HOST:$VPS_PORT: $(echo "$r" | tail -n 1)"
      echo "$r" | grep -qi 'permission denied' && say "  ключа роутера нет на VPS: запустите install.sh → VPS один раз или добавьте $RKEY.pub в ~/.ssh/authorized_keys"
      exit 1
    fi;;
  status)
    valid; need_script audit-server.sh
    vput "$SRV/audit-server.sh" || die "не удалось передать audit-server.sh"
    vrun 'NO_COLOR=1 bash /root/audit-server.sh; rm -f /root/audit-server.sh; echo; echo "== Сервер =="; echo "  $(. /etc/os-release; echo "$PRETTY_NAME"), $(uname -m)"
      echo "  работает: $(uptime -p 2>/dev/null || uptime)"; echo "  нагрузка: $(cut -d" " -f1-3 /proc/loadavg)"
      echo "  память: $(free -m | awk "/^Mem/{print \$3\" из \"\$2\" МБ\"}")"; echo "  диск /: $(df -h / | awk "NR==2{print \$3\" из \"\$2\", свободно \"\$4}")"
      [ -f /usr/local/share/amnezia-build.txt ] && sed "s/^/  /" /usr/local/share/amnezia-build.txt' 2>&1;;
  versions)
    valid
    rv=$(remote_versions); go=$(echo "$rv" | awk '$1=="go"{print $2}'); tl=$(echo "$rv" | awk '$1=="tools"{print $2}')
    lg=$(latest amneziawg-go); lt=$(latest amneziawg-tools)
    [ -n "$rv" ] || die "не удалось войти на VPS"
    [ -n "$lg" ] && [ -n "$lt" ] || die "не удалось узнать последние релизы на github.com/amnezia-vpn"
    rc=0
    for x in "amneziawg-go|${go:-?}|$lg" "awg (amneziawg-tools)|${tl:-?}|$lt"; do
      IFS='|' read -r n i l <<< "$x"
      if [ "$i" = "$l" ]; then say "✔ $n: $i — последняя"
      elif [ "$i" = "?" ] || [ "$(printf '%s\n%s\n' "$i" "$l" | sort -V | tail -n1)" = "$l" ]; then say "↑ $n: на VPS $i, есть $l"; rc=10
      else say "· $n: на VPS $i (новее релиза $l)"; fi
    done
    exit $rc;;
  update)
    valid; need_script awg-server-build.sh
    lg=$(latest amneziawg-go); lt=$(latest amneziawg-tools)
    [ -n "$lg" ] && [ -n "$lt" ] || die "не удалось узнать последние релизы на github.com/amnezia-vpn"
    live=""; for t in $(vps_tunnels); do fresh "$t" 180 && live="$live $t"; done
    say "· сборка amneziawg-go $lg и awg $lt на VPS из исходников amnezia-vpn (3–7 минут)…"
    vput "$SRV/awg-server-build.sh" || die "не удалось передать awg-server-build.sh"
    out=$(vrun "AWG_GO_REF=$lg AWG_TOOLS_REF=$lt RESTART=1 bash /root/awg-server-build.sh" 2>&1)
    echo "$out" | tail -n 6 | sed 's/^/    │ /'
    echo "$out" | grep -qx BUILT_OK || { vrun 'rm -f /root/awg-server-build.sh' >/dev/null 2>&1; event "обновление AmneziaWG на VPS не удалось (сборка)"; die "сборка на VPS не удалась; сервер работает на прежних файлах"; }
    say "· сервер перезапущен на новых файлах; проверяю туннели:${live:- (handshake до обновления не было ни у одного)}"
    bad=""; for t in $live; do wait_hs "$t" || bad="$bad $t"; done
    if [ -n "$bad" ]; then
      say "✘ нет handshake:$bad — возвращаю прежние файлы на VPS"
      vrun 'ROLLBACK_BINS=1 bash /root/awg-server-build.sh' 2>&1 | tail -n1 | sed 's/^/    │ /'
      for t in $live; do wait_hs "$t" >/dev/null; done
      vrun 'rm -f /root/awg-server-build.sh' >/dev/null 2>&1
      event "обновление AmneziaWG на VPS: нет handshake, откат"; notify "⚠️ Обновление AmneziaWG на VPS · $(hostname): туннели не заработали, выполнен откат"
      exit 1
    fi
    vrun 'rm -f /root/awg-server-build.sh' >/dev/null 2>&1
    say "✔ на VPS amneziawg-go $lg и awg $lt"
    event "AmneziaWG на VPS обновлён: amneziawg-go $lg, awg $lt"; notify "⬆️ AmneziaWG на VPS обновлён · $(hostname): amneziawg-go $lg, awg $lt"
    exit 0;;
  rotate-keys)
    valid; need_script vps-rotate.sh; pick "${1:-}"
    addr=$(conf_get "$CF" Address | tr ',' '\n' | tr -d ' \t\r' | grep -m1 '\.')
    [ -n "$addr" ] || die "в $CF нет IPv4 в Address"
    case "$addr" in */*) ;; *) addr=$addr/32;; esac
    NK=$("$DD/awg" genkey) && NP=$(printf '%s' "$NK" | "$DD/awg" pubkey) || die "не удалось создать ключи"
    say "· смена ключей туннеля $T ($addr): $T будет недоступен 10–30 с, kill switch держит PBR-трафик"
    OBFL=""; coordinated "смена ключей" "CLIENT_ADDR=$addr NEW_CLIENT_PUB=$NP" apply_keys; rc=$?
    unset NK; exit $rc;;
  obfs)
    valid; need_script vps-rotate.sh; pick "${1:-}"
    for k in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
      v=$(conf_get "$CF" "$k" | tr -d ' \r'); [[ $v =~ ^[0-9]+$ ]] || die "в $CF нет числового $k (AWG 2.0 с диапазонами H — меняйте вручную)"
    done
    tmpd=$(mktemp -d "$DD/.obf.XXXXXX"); OBFL=$tmpd/awg-obf.txt; gen_obf > "$OBFL"
    say "· новые параметры обфускации для $T: $(tr '\n' ' ' < "$OBFL")"
    coordinated "смена обфускации" "OBF_FILE=/root/awg-obf.txt" apply_obf; rc=$?
    rm -rf "$tmpd"; exit $rc;;
  *) sed -n '2,12p' "$0";;
esac
