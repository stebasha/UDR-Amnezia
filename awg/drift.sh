#!/bin/bash
# awg-drift: сверка правил и служб с эталоном, снятым после установки или обновления.
#   drift.sh           сравнить (код 0 — совпадает, 1 — есть расхождения, 2 — эталона нет)
#   drift.sh save      записать текущее состояние как эталон ($DD/drift.base)
#   drift.sh repair    перезапустить службы набора (они заново ставят свои правила) и сравнить снова
#   drift.sh show      показать текущий снимок
# Что входит в снимок: ip rule с меткой/таблицей PBR и правила подсетей, таблица PBR (активный туннель обобщён),
# правила iptables/ip6tables, где упоминается awg/AWG или метка PBR, состояние служб из .units, параметры PBR из awg.env.
# Правила UniFi drift.sh не меняет никогда: repair только перезапускает службы набора.
iptables(){ command iptables -w 10 "$@"; }
ip6tables(){ command ip6tables -w 10 "$@"; }
DD=${DD:-/data/awg}
BASE=$DD/drift.base
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-}; MARK=${MARK:-}; PRIO=${PRIO:-}
MV=${MARK%%/*}
MD=""; [ -n "$MV" ] && MD=$(printf '%d' "$MV" 2>/dev/null)

snap(){
  echo "# env"
  echo "env TABLE=$TABLE MARK=$MARK PRIO=$PRIO RAIL_IF=${RAIL_IF:-}"
  echo "# ip rule"
  ip -4 rule show 2>/dev/null | grep -E -- "${MV:-^$}|lookup ${TABLE:-^$}([[:space:]]|$)|^610[01]:" | sed -E 's/[[:space:]]+/ /g; s/ $//' | sed 's/^/rule /'
  echo "# таблица PBR"
  [ -n "$TABLE" ] && ip -4 route show table "$TABLE" 2>/dev/null | sed -E 's/^default dev awg[a-z0-9]+/default dev <активный туннель>/; s/[[:space:]]+/ /g; s/ $//' | sort | sed 's/^/route /'
  echo "# iptables"
  local t
  for t in nat mangle filter; do
    # --set-mss считается из MTU туннеля (MTU−40) и меняется вместе с ним — сравниваем само правило, не число
    iptables -t "$t" -S 2>/dev/null | grep -E -i -- "awg${MV:+|$MV}${MD:+|mark $MD}" | sed -E 's/--set-mss [0-9]+/--set-mss <MTU-40>/' | sed "s/^/ipt $t /"
  done
  ip6tables -t filter -S 2>/dev/null | grep -E -- 'AWG|awg' | sed 's/^/ip6 filter /'
  echo "# службы"
  local u
  for u in $(cat "$DD/.units" 2>/dev/null); do
    [ "$u" = awg-motd ] && continue
    echo "svc $u $(systemctl is-active "$u" 2>/dev/null)"
  done
}

whose(){  # строка правила → «наше» или «UniFi»
  case "$1" in
    *AWG*|*awg*|*"proto 99"*|"svc "*|"route "*) echo "набор";;
    "rule 610"*) echo "набор";;
    *) echo "UniFi";;
  esac
}

compare(){
  [ -s "$BASE" ] || { echo "WARN   эталона нет: снимите его (drift.sh save), когда всё работает"; return 2; }
  local cur rc=0 l n=0
  cur=$(mktemp); snap | grep -v '^#' > "$cur"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "FAIL   пропало ($(whose "$l")): $l"; n=$((n+1)); rc=1
  done < <(grep -v '^#' "$BASE" | sort | comm -23 - <(sort "$cur"))
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    echo "WARN   появилось ($(whose "$l")): $l"; n=$((n+1)); rc=1
  done < <(sort "$cur" | comm -23 - <(grep -v '^#' "$BASE" | sort))
  rm -f "$cur"
  if [ $rc = 0 ]; then
    echo "OK     правила и службы совпадают с эталоном от $(date -r "$BASE" '+%F %T' 2>/dev/null)"
  else
    echo "INFO   расхождений: $n. Эталон от $(date -r "$BASE" '+%F %T' 2>/dev/null)."
    echo "INFO   «набор» — правила и службы UDR-Amnezia: вернуть — drift.sh repair (или кнопка в панели)."
    echo "INFO   «UniFi» — правила UniFi (PBR): если вы меняли правила PBR в UniFi, это нормально — снимите новый эталон (drift.sh save)."
    grep -q '^env ' <(grep -v '^#' "$BASE" | sort | comm -3 - <(snap | grep -v '^#' | sort)) &&
      echo "INFO   изменились параметры PBR в awg.env: проверьте install.sh → Компоненты → Туннели → Заново определить PBR"
  fi
  return $rc
}

case "${1:-}" in
  save)
    ( umask 077; snap > "$BASE.tmp" ) && mv -f "$BASE.tmp" "$BASE"
    echo "OK     эталон записан: $BASE ($(grep -vc '^#' "$BASE") строк)";;
  show) snap;;
  repair)
    echo "Перезапускаю службы набора (правила UniFi не трогаются)…"
    for u in awg-failover awg-subnets awg-self awg-guard; do
      grep -qx "$u" "$DD/.units" 2>/dev/null || [ "$u" = awg-failover ] || continue
      systemctl restart "$u" 2>/dev/null && echo "OK     $u перезапущена" || echo "FAIL   $u не перезапустилась"
    done
    sleep 10
    compare;;
  ""|check) compare;;
  *) sed -n '2,9p' "$0"; exit 2;;
esac
