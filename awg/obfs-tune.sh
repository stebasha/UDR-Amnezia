#!/bin/bash
# obfs-tune.sh — автоподбор параметров обфускации AmneziaWG (#33): перебор наборов, проверка, оценка, лучший — по кнопке.
#   obfs-tune.sh run ТУННЕЛЬ [client|server|xui] [N] [--active]
#        client — только параметры роутера, которые сервер не сверяет (Jc, Jmin, Jmax): подходит для любого туннеля,
#                 в том числе провайдера VPN и 3x-ui; сервер не меняется
#        server — согласованно на своём VPS (awg-server) и роутере: Jc, Jmin, Jmax, S1, S2, H1–H4 (через vps.sh obfs)
#        xui    — согласованно на сервере 3x-ui (через API) и роутере: Jc…H4 (#37). Только если в подключении 3x-ui
#                 единственный клиент — роутер: общие подключения не трогаются
#        N      — сколько новых наборов проверить (1–12, по умолчанию 5); первым меряется текущий набор
#        --active — разрешить подбор на активном канале (иначе только на резервном: рабочий трафик не трогается)
#   obfs-tune.sh apply НОМЕР     поставить набор НОМЕР из последнего подбора (с проверкой handshake и откатом)
#   obfs-tune.sh show            результаты последнего подбора (tune.tsv)
# Каждый набор: применить → handshake → интернет → потери и задержка → скорость (5 МБ) → оценка. В конце подбора
# туннель возвращается на исходный набор: ничего не меняется, пока вы сами не выберете «Применить».
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
RES=$DD/tune.tsv
STATEB=${STATEF:-/run/awg-state}
TUNE_WAIT=${TUNE_WAIT:-45}       # handshake после пересоздания: попытки идут раз в 5–8 с, часть может теряться
TUNE_SPEED=${TUNE_SPEED:-yes}
SPEED_URL=${AWG_SPEED_URL:-https://speed.cloudflare.com}
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
umask 077
# shellcheck disable=SC1091
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNNELS_EXTRA=${TUNNELS_EXTRA:-}

say(){ printf '%s\n' "$*"; }
die(){ say "ОШИБКА: $*"; exit 1; }
event(){ echo "$(date +%s)|tune|$1" >> "$DD/events.log"; }
conf_get(){ awk -v k="$2" 'BEGIN{k=tolower(k)} /^[[:space:]]*\[/ {sec=tolower($0); gsub(/[[:space:]]/,"",sec)} sec=="[interface]" { line=$0; sub(/\r$/,"",line); split(line,a,"="); key=a[1]; gsub(/[ \t]/,"",key); if (tolower(key)==k) { sub(/^[^=]*=[ \t]*/,"",line); print line; exit } }' "$1"; }
set_params(){  # set_params КОНФИГ "K=V K=V…" — заменить (или добавить) ключи в [Interface]
  awk -v ps="$2" '
    BEGIN { n = split(ps, a, " "); for (i = 1; i <= n; i++) { split(a[i], kv, "="); m[kv[1]] = kv[2]; ord[i] = kv[1] } }
    /^[[:space:]]*\[/ { if (sec == "[interface]") for (i = 1; i <= n; i++) if (!(ord[i] in done)) print ord[i] " = " m[ord[i]]
                        sec = tolower($0); gsub(/[[:space:]]/, "", sec); print; next }
    sec == "[interface]" { k = $0; sub(/=.*/, "", k); gsub(/[ \t\r]/, "", k); if (k in m) { print k " = " m[k]; done[k] = 1; next } }
    { print }
    END { if (sec == "[interface]") for (i = 1; i <= n; i++) if (!(ord[i] in done)) print ord[i] " = " m[ord[i]] }' "$1" > "$1.new" && cat "$1.new" > "$1" && rm -f "$1.new"
}
hs_age(){ local ts; ts=$("$DD/awg" show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
up_tun(){
  if command -v flock >/dev/null; then ( flock -w 30 9 || exit 1; "$DD/up.sh" "$1" >/dev/null 2>&1 ) 9>"${AWG_RUN:-/run}/awg-up-$1.lock"
  else "$DD/up.sh" "$1" >/dev/null 2>&1; fi
}
is_active(){ local f; for f in "$STATEB" "$STATEB"-*; do [ -f "$f" ] && grep -qx "ACTIVE=$1" "$f" && return 0; done; return 1; }

# measure ТУННЕЛЬ НАЧАЛО → M_OK M_HS M_LOSS M_RTT M_MBPS M_SCORE
measure(){
  local t=$1 t0=$2 i a c ok=0 n=0 sum=0 out
  M_OK=0; M_HS=-1; M_LOSS=100; M_RTT=0; M_MBPS=0; M_SCORE=0
  for i in $(seq 1 "$TUNE_WAIT"); do a=$(hs_age "$t"); [ "$a" -ge 0 ] && [ "$a" -le $(( $(date +%s) - t0 + 1 )) ] && break; sleep 1; done
  a=$(hs_age "$t"); [ "$a" -ge 0 ] && [ "$a" -le $(( $(date +%s) - t0 + 1 )) ] || return 0
  M_HS=$(( $(date +%s) - t0 - a )); [ "$M_HS" -lt 0 ] && M_HS=0; [ "${3:-}" = base ] && M_HS=0   # текущий набор: handshake уже был
  c=$(curl -sk -o /dev/null --connect-timeout 4 -m 8 --interface "$t" -w '%{http_code}' https://1.1.1.1/ 2>/dev/null)
  { [ -n "$c" ] && [ "$c" != 000 ]; } || return 0
  M_OK=1
  out=$(ping -I "$t" -c 10 -i 0.2 -W 1 -q 1.1.1.1 2>/dev/null)
  M_LOSS=$(echo "$out" | awk '/packet loss/{for(k=1;k<=NF;k++) if($k ~ /%/){gsub("%","",$k); print int($k); exit}}'); M_LOSS=${M_LOSS:-100}
  if [ "$M_LOSS" -lt 100 ]; then
    M_RTT=$(echo "$out" | awk -F'=' '/min\/avg\/max/{split($2,a,"/"); printf "%d", a[2]+0.5; exit}'); M_RTT=${M_RTT:-0}
  else   # ICMP через туннель не ходит — время TCP-соединения к трём узлам, по два раза
    for i in 1 2; do for a in $TARGETS; do
      n=$((n+1)); c=$(curl -sk -o /dev/null --connect-timeout 2 -m 3 --interface "$t" -w '%{time_connect}' "https://$a/" 2>/dev/null)
      case "$c" in ""|0|0.000000) continue;; esac
      ok=$((ok+1)); sum=$(( sum + $(awk -v x="$c" 'BEGIN{printf "%d", x*1000+0.5}') ))
    done; done
    M_LOSS=$(( (n-ok)*100/n )); [ $ok -gt 0 ] && M_RTT=$(( sum/ok ))
  fi
  if [ "$TUNE_SPEED" = yes ]; then
    c=$(curl -s -o /dev/null -m 15 --interface "$t" -w '%{speed_download}' "$SPEED_URL/__down?bytes=5000000" 2>/dev/null)
    M_MBPS=$(awk -v b="${c:-0}" 'BEGIN{printf "%.1f", b*8/1000000}')
  fi
  # оценка: рабочий набор — от 1; минус потери, задержка и долгий handshake (дольше 3 с), плюс скорость (до 200 Мбит/с)
  M_SCORE=$(awk -v l="$M_LOSS" -v r="$M_RTT" -v h="$M_HS" -v s="$M_MBPS" 'BEGIN{x=100-l-r/10-(h>3?(h-3)*2:0); if (x<1) x=1; if (s>200) s=200; printf "%d", x+s/2}')
}
gen_client(){  # набор i: сначала знакомые разные по размеру, дальше случайные
  case "$1" in
    1) echo "Jc=3 Jmin=10 Jmax=50";; 2) echo "Jc=4 Jmin=40 Jmax=70";; 3) echo "Jc=6 Jmin=50 Jmax=200";;
    4) echo "Jc=8 Jmin=64 Jmax=512";; 5) echo "Jc=10 Jmin=100 Jmax=1000";;
    *) local jc jmin jmax; jc=$(shuf -i 3-12 -n 1); jmin=$(shuf -i 10-200 -n 1); jmax=$(( jmin + $(shuf -i 20-800 -n 1) )); [ "$jmax" -gt 1280 ] && jmax=1280
       echo "Jc=$jc Jmin=$jmin Jmax=$jmax";;
  esac
}
gen_server(){  # как vps.sh gen_obf: Jc 4–8, Jmin 40–80, Jmax больше Jmin, S1/S2 15–150 (S1+56 ≠ S2), H1–H4 разные > 4
  local jc jmin jmax s1 s2 h
  jc=$(shuf -i 4-8 -n 1); jmin=$(shuf -i 40-80 -n 1); jmax=$((jmin + $(shuf -i 60-200 -n 1)))
  s1=$(shuf -i 15-150 -n 1); s2=$(shuf -i 15-150 -n 1)
  while [ $((s1 + 56)) -eq "$s2" ] || [ "$s1" -eq "$s2" ]; do s2=$(shuf -i 15-150 -n 1); done
  mapfile -t h < <(shuf -i 5-2147483647 -n 4)
  echo "Jc=$jc Jmin=$jmin Jmax=$jmax S1=$s1 S2=$s2 H1=${h[0]} H2=${h[1]} H3=${h[2]} H4=${h[3]}"
}
gen_xui(){  # для 3x-ui (AWG 2.0/3.1): Jc…S2 как у своего VPS, H1–H4 — непересекающиеся диапазоны
  local j hs w i out a b nx
  j=$(gen_server | cut -d' ' -f1-5)
  mapfile -t hs < <(shuf -i 5-2140000000 -n 4 | sort -n)
  out=$j
  for i in 0 1 2 3; do
    a=${hs[$i]}; nx=${hs[$((i + 1))]:-2147483000}; w=$(shuf -i 1000-200000 -n 1)
    b=$((a + w)); [ "$b" -ge "$nx" ] && b=$((nx - 1)); [ "$b" -le "$a" ] && b=$((a + 1))
    out="$out H$((i + 1))=$a-$b"
  done
  echo "$out"
}
cur_params(){  # текущие значения ключей набора из конфига
  local k out=""
  for k in $2; do out="$out $k=$(conf_get "$1" "$k" | tr -d ' \r')"; done
  echo "${out# }"
}
vps_of(){  # свой VPS, сервер (awg-server) которого держит туннель
  local id
  for id in $("$DD/vps.sh" list 2>/dev/null | cut -f1); do
    "$DD/vps.sh" --vps "$id" tunnels 2>/dev/null | grep -qx "$1" && { echo "$id"; return 0; }
  done
  return 1
}
apply_xui(){  # apply_xui ТУННЕЛЬ "K=V…" [--trial] — 3x-ui и роутер, с откатом обеих сторон (panel.py xui-obfs)
  python3 "$DD/web/panel.py" xui-obfs "$1" "$2" ${3:+"$3"} 2>&1 | sed 's/^/    │ /'; return "${PIPESTATUS[0]}"
}
apply_server(){  # apply_server ТУННЕЛЬ VPS "K=V…" — согласованно, с откатом внутри vps.sh
  local f; f=$(mktemp "$DD/.tune.XXXXXX")
  echo "$3" | tr ' ' '\n' | sed 's/=/ = /' > "$f"
  VPS_QUIET=1 VPS_NO_KEEP=1 "$DD/vps.sh" --vps "$2" obfs "$1" --file "$f" 2>&1 | sed 's/^/    │ /'; local rc=${PIPESTATUS[0]}
  rm -f "$f"; return "$rc"
}
try_client(){  # try_client "K=V…" — поставить набор на роутере и замерить; без handshake — ещё одна попытка (потери случаются)
  local t0
  set_params "$CF" "$1"; t0=$(date +%s); up_tun "$T"; measure "$T" "$t0"
  if [ "$M_OK" != 1 ]; then say "    · связи нет — повторяю попытку"; t0=$(date +%s); up_tun "$T"; measure "$T" "$t0"; fi
}
row(){ printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$M_OK" "$M_HS" "$M_LOSS" "$M_RTT" "$M_MBPS" "$M_SCORE" "$2" >> "$RES.new"; }

cmd=${1:-help}; shift
case "$cmd" in
  run)
    T=${1:-}; MODE=${2:-client}; N=${3:-5}; ACT=${4:-}
    [[ $T =~ ^awg[a-z0-9]{1,10}$ ]] || die "имя туннеля: например awgbackup"
    case " $MAIN $BACKUP $TUNNELS_EXTRA " in *" $T "*) ;; *) die "туннеля $T нет в наборе";; esac
    [[ $N =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le 12 ] || die "число наборов: 1–12"
    case "$MODE" in client|server|xui) ;; *) die "режим: client, server или xui";; esac
    [ -z "$ACT" ] || [ "$ACT" = --active ] || die "неизвестный ключ: $ACT"
    if is_active "$T" && [ -z "$ACT" ]; then die "$T сейчас активный канал: подбор прервёт рабочий трафик. Подбирайте на резервном или разрешите явно (--active)"; fi
    CF=$DD/$("$DD/up.sh" --conf-of "$T"); [ -f "$CF" ] || die "нет конфига туннеля $T"
    if [ "$MODE" = server ]; then
      KEYS="Jc Jmin Jmax S1 S2 H1 H2 H3 H4"
      for k in $KEYS; do v=$(conf_get "$CF" "$k" | tr -d ' \r'); [[ $v =~ ^[0-9]+$ ]] || die "в $CF нет числового $k (AWG 2.0/3.x с диапазонами H — режим server не подходит, используйте client)"; done
      VID=$(vps_of "$T") || die "$T не обслуживает awg-server на вашем VPS: режим server только для своего сервера; для 3x-ui — xui, для провайдера — client"
    elif [ "$MODE" = xui ]; then
      KEYS="Jc Jmin Jmax S1 S2 H1 H2 H3 H4"
      out=$(python3 "$DD/web/panel.py" xui-obfs-check "$T" 2>&1) || die "${out#ОШИБКА: }"
    else KEYS="Jc Jmin Jmax"; fi
    exec 8>"${AWG_RUN:-/run}/awg-tune.lock"; command -v flock >/dev/null && { flock -n 8 || die "подбор уже идёт"; }
    BASE=$(cur_params "$CF" "$KEYS")
    printf '# %s\t%s\t%s\t%s\n' "$T" "$MODE" "$(date +%s)" "${VID:-}" > "$RES.new"
    case "$MODE" in server) WHO="роутер и VPS $VID";; xui) WHO="роутер и сервер 3x-ui";; *) WHO="только роутер, сервер не меняется";; esac
    say "· подбор обфускации $T ($WHO): текущий набор и ещё $N"
    event "подбор обфускации $T: начат ($MODE, наборов $N)"
    cp -p "$CF" "$CF.pre-tune"
    # прерванный подбор (остановка службы, срок задачи, Ctrl+C) не оставляет туннель на пробном наборе
    restore_base(){
      trap - EXIT INT TERM
      [ -f "$CF.pre-tune" ] || return 0
      say "· подбор прерван: возвращаю исходный набор"
      if [ "$MODE" = server ]; then apply_server "$T" "$VID" "$BASE" >/dev/null 2>&1 || true
      elif [ "$MODE" = xui ]; then apply_xui "$T" "$BASE" --trial >/dev/null 2>&1 || true
      else cat "$CF.pre-tune" > "$CF"; up_tun "$T"; fi
      rm -f "$CF.pre-tune" "$RES.new"; event "подбор обфускации $T: прерван, исходный набор возвращён"
    }
    trap 'restore_base; exit 1' INT TERM
    trap 'restore_base' EXIT
    say "· 0: текущий набор $BASE"
    if [ "$MODE" != client ]; then measure "$T" "$(( $(date +%s) - 300 ))" base
    else try_client "$BASE"; fi                      # как и остальные: пересоздать и мерить с нуля — сравнение честное
    row 0 "$BASE"
    say "    → $( [ "$M_OK" = 1 ] && echo "работает: потери $M_LOSS%, задержка $M_RTT мс, скорость $M_MBPS Мбит/с, оценка $M_SCORE" || echo "не работает")"
    for i in $(seq 1 "$N"); do
      # основной канал упал, и сторож перевёл трафик на этот туннель — подбор прекращаем, рабочий трафик не трогаем
      if [ -z "$ACT" ] && is_active "$T"; then say "▲ $T стал активным каналом: подбор прекращён"; break; fi
      case "$MODE" in server) P=$(gen_server);; xui) P=$(gen_xui);; *) P=$(gen_client "$i");; esac
      say "· $i: $P"
      t0=$(date +%s)
      if [ "$MODE" = server ]; then
        if apply_server "$T" "$VID" "$P"; then measure "$T" "$t0"; else M_OK=0; M_HS=-1; M_LOSS=100; M_RTT=0; M_MBPS=0; M_SCORE=0; fi
      elif [ "$MODE" = xui ]; then
        if apply_xui "$T" "$P" --trial; then measure "$T" "$t0"; else M_OK=0; M_HS=-1; M_LOSS=100; M_RTT=0; M_MBPS=0; M_SCORE=0; fi
      else
        try_client "$P"
      fi
      row "$i" "$P"
      say "    → $( [ "$M_OK" = 1 ] && echo "работает: handshake за $M_HS с, потери $M_LOSS%, задержка $M_RTT мс, скорость $M_MBPS Мбит/с, оценка $M_SCORE" || echo "не работает")"
    done
    say "· возвращаю исходный набор"
    if [ "$MODE" = server ]; then apply_server "$T" "$VID" "$BASE" >/dev/null || say "▲ исходный набор на VPS не подтвердился: смотрите «Свой VPS → Журнал»"
    elif [ "$MODE" = xui ]; then apply_xui "$T" "$BASE" --trial >/dev/null || say "▲ исходный набор в 3x-ui не подтвердился: проверьте подключение в 3x-ui («Туннели → 3x-ui → Обновить из 3x-ui»)"
    else cat "$CF.pre-tune" > "$CF"; up_tun "$T"; fi
    rm -f "$CF.pre-tune"; trap - EXIT INT TERM
    mv -f "$RES.new" "$RES"; chmod 600 "$RES"
    best=$(awk -F'\t' '!/^#/ && $2==1 {print $7"\t"$1"\t"$8}' "$RES" | sort -s -t"$(printf '\t')" -k1,1nr | head -n1)
    if [ -n "$best" ]; then
      say "✔ лучший набор №$(echo "$best" | cut -f2) (оценка $(echo "$best" | cut -f1)): $(echo "$best" | cut -f3)"
      say "  поставить: obfs-tune.sh apply $(echo "$best" | cut -f2)   (или «Применить» в панели)"
      event "подбор обфускации $T: лучший №$(echo "$best" | cut -f2), оценка $(echo "$best" | cut -f1)"
    else say "✘ ни один набор не заработал"; event "подбор обфускации $T: ни один набор не заработал"; fi
    exit 0;;
  apply)
    n=${1:-}; [[ $n =~ ^[0-9]+$ ]] || die "номер набора из последнего подбора"
    [ -s "$RES" ] || die "подбора ещё не было"
    IFS=$'\t' read -r _ T MODE _ VID < <(head -n1 "$RES" | sed 's/^# //; s/^/x\t/')
    P=$(awk -F'\t' -v n="$n" '!/^#/ && $1==n {print $8}' "$RES"); ok=$(awk -F'\t' -v n="$n" '!/^#/ && $1==n {print $2}' "$RES")
    [ -n "$P" ] || die "в последнем подборе нет набора $n"
    [ "$ok" = 1 ] || die "набор $n при подборе не заработал"
    CF=$DD/$("$DD/up.sh" --conf-of "$T"); [ -f "$CF" ] || die "нет конфига туннеля $T"
    say "· $T: ставлю набор $n: $P"
    if [ "$MODE" = server ]; then
      apply_server "$T" "$VID" "$P" || die "набор $n не заработал — обе стороны возвращены"
    elif [ "$MODE" = xui ]; then
      apply_xui "$T" "$P" || die "набор $n не заработал — обе стороны возвращены"
    else
      cp -p "$CF" "$CF.pre-tune"; set_params "$CF" "$P"; t0=$(date +%s); up_tun "$T"; TUNE_SPEED=no measure "$T" "$t0"
      if [ "$M_OK" != 1 ]; then cat "$CF.pre-tune" > "$CF"; rm -f "$CF.pre-tune"; up_tun "$T"; die "набор $n сейчас не заработал — возвращён прежний"; fi
      rm -f "$CF.pre-tune"
    fi
    event "обфускация $T: поставлен набор $n из подбора"
    say "✔ $T работает на наборе $n";;
  show) [ -s "$RES" ] && cat "$RES" || say "подбора ещё не было";;
  *) sed -n '2,14p' "$0";;
esac
