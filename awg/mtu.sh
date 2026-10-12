#!/bin/bash
# awg-mtu: подбор MTU туннеля. Меряет максимальный размер пакета без фрагментации на пути роутер → сервер
# (DF-ping через WAN) и вычитает накладные расходы AmneziaWG (IPv4 20 + UDP 8 + WireGuard 32 = 60 байт, плюс S4 из конфига).
#   mtu.sh [туннель]            только показать рекомендацию
#   mtu.sh [туннель] --apply    записать MTU в конфиг и перезапустить туннель (с резервной копией конфига)
# ICMP на пути должен проходить. Если нет — скрипт скажет об этом и ничего не изменит.
DD=${DD:-/data/awg}
AWG=$DD/awg
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; WANIF=${WANIF:-}
TUNS="$MAIN${BACKUP:+ $BACKUP}${TUNNELS_EXTRA:+ $TUNNELS_EXTRA}"
APPLY=0; ONE=""
for a in "$@"; do case "$a" in --apply) APPLY=1;; -h|--help) sed -n '2,8p' "$0"; exit 0;; *) ONE=$a;; esac; done
[ -n "$ONE" ] && TUNS=$ONE

conf_for(){ case "$1" in "$MAIN") echo main.conf;; "${BACKUP:-awgbackup}") [ -f "$DD/backup.conf" ] && echo backup.conf || echo client.conf;; *) echo "$1.conf";; esac; }
wan_if(){ [ -n "$WANIF" ] && { echo "$WANIF"; return; }; ip -4 route show table all 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | grep -v -E '^(awg|wg|lo|wgclt)' | head -n1; }
WAN=$(wan_if)
df_ping(){ ping -I "$WAN" -M do -c 1 -W 2 -s "$1" "$2" >/dev/null 2>&1; }   # 0 — пакет с payload $1 дошёл без фрагментации

# максимальный payload, проходящий до цели, бинарным поиском
maxpayload(){
  local tgt=$1 lo=56 hi=1472 mid
  df_ping $lo "$tgt" || return 1
  df_ping $hi "$tgt" && { echo $hi; return 0; }
  while [ $((hi - lo)) -gt 1 ]; do mid=$(( (lo + hi) / 2 )); if df_ping $mid "$tgt"; then lo=$mid; else hi=$mid; fi; done
  echo $lo
}

rc=0
for t in $TUNS; do
  echo "== $t =="
  cf=$DD/$(conf_for "$t")
  [ -f "$cf" ] || { echo "  нет конфига $cf"; rc=1; continue; }
  ep=$(awk -F' *= *' 'tolower($1)=="endpoint"{print $2; exit}' "$cf" | tr -d ' \r'); ep=${ep%:*}; ep=${ep#[}; ep=${ep%]}
  case "$ep" in *[!0-9.]*) ep=$(getent ahostsv4 "$ep" 2>/dev/null | awk 'NR==1{print $1}');; esac
  cur=$(awk -F' *= *' 'tolower($1)=="mtu"{print $2; exit}' "$cf" | tr -d ' \r'); cur=${cur:-$(cat /sys/class/net/$t/mtu 2>/dev/null)}
  s4=$(awk -F' *= *' '$1=="S4"{print $2; exit}' "$cf" | tr -d ' \r'); [[ $s4 =~ ^[0-9]+$ ]] || s4=0
  echo "  WAN: ${WAN:-?}, сервер: ${ep:-?}, текущий MTU: ${cur:-?}, S4: $s4"
  tgt=$ep; mp=""
  [ -n "$tgt" ] && mp=$(maxpayload "$tgt")
  if [ -z "$mp" ]; then
    echo "  сервер не отвечает на ICMP, меряю путь до 1.1.1.1 (приближение)"
    tgt=1.1.1.1; mp=$(maxpayload "$tgt")
  fi
  if [ -z "$mp" ]; then echo "  ICMP через WAN не проходит: подобрать MTU автоматически нельзя. Оставьте 1380 или задайте вручную (1280–1420)."; rc=1; continue; fi
  pm=$((mp + 28)); rec=$((pm - 60 - s4)); [ $rec -lt 1280 ] && rec=1280; [ $rec -gt 1420 ] && rec=1420
  echo "  путь до $tgt без фрагментации: $pm байт → рекомендуемый MTU туннеля: $rec"
  if [ -n "$cur" ] && [ "$cur" -le "$rec" ] && [ $((rec - cur)) -le 8 ]; then echo "  текущий MTU ($cur) подходит."; continue; fi
  [ -n "$cur" ] && [ "$cur" -gt "$rec" ] && echo "  ВНИМАНИЕ: текущий MTU ($cur) больше рекомендуемого: возможны зависания больших загрузок."
  if [ $APPLY = 1 ]; then
    cp -p "$cf" "$cf.pre-mtu.$(date +%s)"
    if grep -qiE '^[[:space:]]*MTU[[:space:]]*=' "$cf"; then sed -i -E "s/^[[:space:]]*[Mm][Tt][Uu][[:space:]]*=.*/MTU = $rec/" "$cf"
    else sed -i -E "0,/^[[:space:]]*Address[[:space:]]*=.*/s//&\nMTU = $rec/" "$cf"; fi
    chmod 600 "$cf"
    "$DD/up.sh" "$t" >/dev/null 2>&1 && echo "  записано MTU = $rec, туннель перезапущен" || { echo "  туннель не поднялся: восстанавливаю конфиг"; cp -p "$(ls -t "$cf".pre-mtu.* | head -n1)" "$cf"; "$DD/up.sh" "$t" >/dev/null 2>&1; rc=1; }
  else echo "  применить: $0 $t --apply"; fi
done
exit $rc
