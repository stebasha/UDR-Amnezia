#!/bin/bash
# routes.sh — маршруты (#22): разные туннели для разных устройств и доменов.
# Какие устройства и домены куда идут, задаётся в UniFi: правила Policy-Based Routes на разные профили VPN Client
# («рельсы» wgclt1, wgclt2, …). Основной маршрут — рельса из awg.env (MAIN, BACKUP, TUNNELS_EXTRA). Каждый
# дополнительный — своя рельса, своя таблица и метка PBR, своя цепочка туннелей по приоритету и свой сторож
# (служба awg-failover-ID) с переключением, kill switch и ручным выбором.
#   routes.sh rails                         профили VPN Client с правилами PBR: приоритет метка таблица профиль занят
#   routes.sh list                          маршруты: ID профиль таблица туннели активный служба метка-названия
#   routes.sh add ID ПРОФИЛЬ "Т1 Т2…" [НАЗВАНИЕ] [--only]   новый маршрут; --only — его туннели не нужны основному
#   routes.sh set ID "Т1 Т2…" [НАЗВАНИЕ] [--only]           изменить туннели (сторож маршрута перезапускается)
#   routes.sh remove ID                     убрать маршрут: трафик профиля вернётся в сам профиль UniFi
#   routes.sh switch ID ТУННЕЛЬ|auto        ручной выбор канала маршрута / вернуть автоматику
# Туннели — из уже поднятых набором (MAIN, BACKUP, TUNNELS_EXTRA). Один туннель может служить нескольким маршрутам.
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
SYSD=${SYSD:-/etc/systemd/system}
RD=$DD/route.d
STATEB=${STATEF:-/run/awg-state}
FORCEB=${FORCEF:-/run/awg-force}
umask 077
# shellcheck disable=SC1091
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNNELS_EXTRA=${TUNNELS_EXTRA:-}; RAIL_IF=${RAIL_IF:-}; ROUTE_ONLY=${ROUTE_ONLY:-}

say(){ printf '%s\n' "$*"; }
die(){ say "ОШИБКА: $*"; exit 1; }
event(){ echo "$(date +%s)|route|$1" >> "$DD/events.log"; }
all_tunnels(){ echo "$MAIN $BACKUP $TUNNELS_EXTRA" | tr ' ' '\n' | grep . ; }
rails(){  # приоритет метка таблица профиль — как в awg-detect.sh
  ip -4 rule show | awk '
    /fwmark/ && /lookup [0-9]+\.[a-z]+clt[0-9]+/ {
      prio=$1; sub(":","",prio); m=""; t=""
      for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1) }
      split(t,a,"."); print prio, m, a[1], a[2]
    }' | sort -u -k4,4
}
route_ids(){ local f; for f in "$RD"/*.env; do [ -r "$f" ] && basename "$f" .env; done; }
rget(){ sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$RD/$1.env" 2>/dev/null | head -n1; }   # rget ID КЛЮЧ
valid_id(){ [[ $1 =~ ^[a-z][a-z0-9]{0,11}$ ]] && [ "$1" != main ]; }
check_tunnels(){  # check_tunnels "Т1 Т2…" → CT_OUT (нормализованный список) или die
  local t out="" n=0 all; all=" $(all_tunnels | tr '\n' ' ') "
  for t in $1; do
    [[ $t =~ ^awg[a-z0-9]{1,10}$ ]] || die "неверное имя туннеля: $t"
    case "$all" in *" $t "*) ;; *) die "туннеля $t нет в наборе (сначала добавьте его: «Туннели → Добавить»)";; esac
    case " $out " in *" $t "*) die "туннель $t указан дважды";; esac
    out="$out $t"; n=$((n+1))
  done
  [ $n -ge 1 ] && [ $n -le 6 ] || die "туннелей в маршруте: от 1 до 6"
  CT_OUT=${out# }
}
check_label(){ [ ${#1} -le 40 ] && [[ ! $1 =~ [\"\'\`\$\\\<\>\&] ]] || die "недопустимые символы в названии"; }
env_put(){  # env_put КЛЮЧ ЗНАЧЕНИЕ — в awg.env
  local f=$DD/awg.env
  if grep -q "^$1=" "$f" 2>/dev/null; then
    awk -v k="$1" -v v="$2" 'index($0, k"=")==1 {print k"=\""v"\""; next} {print}' "$f" > "$f.t" && cat "$f.t" > "$f" && rm -f "$f.t"
  else printf '%s="%s"\n' "$1" "$2" >> "$f"; fi
}
recompute_only(){  # ROUTE_ONLY = туннели маршрутов с «только для маршрута» (кроме основного туннеля); 0 — изменилось
  local id t new=""
  for id in $(route_ids); do
    [ "$(rget "$id" ONLY)" = yes ] || continue
    for t in $(rget "$id" TUNNELS); do [ "$t" = "$MAIN" ] && continue; case " $new " in *" $t "*) ;; *) new="$new $t";; esac; done
  done
  new=$(echo "$new" | xargs)
  [ "$new" = "$(echo "$ROUTE_ONLY" | xargs)" ] && return 1
  env_put ROUTE_ONLY "$new"; ROUTE_ONLY=$new; return 0
}
unit_text(){
  cat <<U
[Unit]
Description=AmneziaWG failover, route $1 (UniFi PBR $2)
After=network-online.target awg-failover.service
Wants=network-online.target

[Service]
ExecStart=$DD/failover.sh --route $1
ExecStopPost=$DD/failover.sh --route $1 cleanup
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
U
}
units_mark(){ if [ "$2" = on ]; then grep -qx "$1" "$DD/.units" 2>/dev/null || echo "$1" >> "$DD/.units"
              elif [ -f "$DD/.units" ]; then grep -vx "$1" "$DD/.units" > "$DD/.units.t"; cat "$DD/.units.t" > "$DD/.units"; rm -f "$DD/.units.t"; fi; }
drift_save(){ [ -x "$DD/drift.sh" ] && { sleep "${ROUTE_SETTLE:-6}"; "$DD/drift.sh" save >/dev/null 2>&1; }; return 0; }
write_env(){  # write_env ID ПРОФИЛЬ ПРИОРИТЕТ МЕТКА ТАБЛИЦА ТУННЕЛИ НАЗВАНИЕ ONLY
  mkdir -p "$RD"; chmod 700 "$RD"
  printf 'RAIL_IF="%s"\nPRIO="%s"\nMARK="%s"\nTABLE="%s"\nTUNNELS="%s"\nLABEL="%s"\nONLY="%s"\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$RD/$1.env.t"
  chmod 600 "$RD/$1.env.t"; mv -f "$RD/$1.env.t" "$RD/$1.env"
}

cmd=${1:-help}; shift
case "$cmd" in
  rails)
    rails | while read -r p m t r; do
      used=""; [ "$r" = "$RAIL_IF" ] && used=main
      for id in $(route_ids); do [ "$(rget "$id" RAIL_IF)" = "$r" ] && used=$id; done
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$m" "$t" "$r" "${used:--}"
    done;;
  list)
    for id in $(route_ids); do
      act=$(sed -n 's/^ACTIVE=//p' "$STATEB-$id" 2>/dev/null); frc=$(sed -n 's/^FORCED=//p' "$STATEB-$id" 2>/dev/null)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(rget "$id" RAIL_IF)" "$(rget "$id" TABLE)" "$(rget "$id" TUNNELS)" "${act:--}" \
        "$(systemctl is-active "awg-failover-$id" 2>/dev/null || true)" "${frc:--}" "$(rget "$id" LABEL)"
    done;;
  add|set)
    id=${1:-}; valid_id "$id" || die "ID маршрута: латиница с буквы, до 12 знаков, не main"
    if [ "$cmd" = add ]; then
      rail=${2:-}; tuns=${3:-}; label=${4:-}; only=${5:-}
      [ -e "$RD/$id.env" ] && die "маршрут $id уже есть"
      [[ $rail =~ ^[a-z]+clt[0-9]+$ ]] || die "профиль VPN Client: например, wgclt2"
      [ "$rail" = "$RAIL_IF" ] && die "профиль $rail уже ведёт основной маршрут"
      for x in $(route_ids); do [ "$(rget "$x" RAIL_IF)" = "$rail" ] && die "профиль $rail уже занят маршрутом $x"; done
      line=$(rails | awk -v r="$rail" '$4==r{print; exit}')
      [ -n "$line" ] || die "у профиля $rail нет правила PBR: в UniFi создайте профиль VPN Client и хотя бы одно правило Policy-Based Route на него"
      read -r prio mark table _ <<< "$line"
    else
      [ -r "$RD/$id.env" ] || die "нет маршрута $id"
      tuns=${2:-}; label=${3:-$(rget "$id" LABEL)}; only=${4:-}
      rail=$(rget "$id" RAIL_IF); prio=$(rget "$id" PRIO); mark=$(rget "$id" MARK); table=$(rget "$id" TABLE)
    fi
    check_tunnels "$tuns"; tuns=$CT_OUT; check_label "$label"
    [ -n "$only" ] && [ "$only" != --only ] && die "неизвестный ключ: $only"
    write_env "$id" "$rail" "$prio" "$mark" "$table" "$tuns" "$label" "${only:+yes}"
    restart_main=0; recompute_only && restart_main=1
    u=awg-failover-$id
    unit_text "$id" "$rail" > "$DD/$u.service"; chmod 644 "$DD/$u.service"
    cp "$DD/$u.service" "$SYSD/$u.service" 2>/dev/null; systemctl daemon-reload 2>/dev/null
    systemctl enable "$u" >/dev/null 2>&1; systemctl restart "$u" 2>/dev/null; units_mark "$u" on
    [ $restart_main = 1 ] && systemctl restart awg-failover 2>/dev/null
    systemctl restart awg-guard 2>/dev/null || true          # метка нового маршрута — в защиту от утечек
    event "маршрут $id ($rail, таблица $table): $tuns${label:+ — $label}"
    say "✔ маршрут $id: профиль $rail → $tuns (сторож $u)"
    drift_save;;
  remove)
    id=${1:-}; valid_id "$id" && [ -r "$RD/$id.env" ] || die "нет маршрута ${id:-?}"
    u=awg-failover-$id
    systemctl disable --now "$u" >/dev/null 2>&1
    "$DD/failover.sh" --route "$id" cleanup all >/dev/null 2>&1    # и blackhole: трафик профиля снова идёт в сам профиль UniFi
    rm -f "$SYSD/$u.service" "$DD/$u.service" "$RD/$id.env" "$STATEB-$id" "$FORCEB-$id"; systemctl daemon-reload 2>/dev/null
    recompute_only && systemctl restart awg-failover 2>/dev/null
    units_mark "$u" off
    systemctl restart awg-guard 2>/dev/null || true
    event "маршрут $id убран"
    say "✔ маршрут $id убран: трафик его профиля UniFi идёт как без набора"
    drift_save;;
  switch)
    id=${1:-}; t=${2:-}; valid_id "$id" && [ -r "$RD/$id.env" ] || die "нет маршрута ${id:-?}"
    if [ "$t" = auto ]; then rm -f "$FORCEB-$id"; say "маршрут $id: автоматический выбор"; exit 0; fi
    case " $(rget "$id" TUNNELS) " in *" $t "*) ;; *) die "$t — не туннель маршрута $id";; esac
    echo "$t" > "$FORCEB-$id"; say "маршрут $id: выбран $t (сторож переключит, если канал отвечает)";;
  *) sed -n '2,15p' "$0";;
esac
