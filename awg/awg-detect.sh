#!/bin/bash
# awg-detect.sh — находит PBR-обвязку UniFi (таблица, метка, профиль-«рельса»)
# и записывает её в /data/awg/awg.env.
#   awg-detect.sh            если профиль VPN Client один
#   awg-detect.sh wgclt2     если профилей несколько: укажите нужный
# Систему не меняет. Обновляет в awg.env только TABLE, MARK, PRIO, RAIL_IF (и WANIF, если его не было); остальное сохраняется.
DD=${DD:-/data/awg}
mkdir -p "$DD"
[ -r "$DD/awg.env" ] && . "$DD/awg.env"

# Правило PBR профиля UniFi выглядит так:
#   32504:  from all fwmark 0x6a0000/0x7e0000 lookup 178.wgclt1
rules=$(ip -4 rule show | awk '
  /fwmark/ && /lookup [0-9]+\.[a-z]+clt[0-9]+/ {
    prio=$1; sub(":","",prio); m=""; t=""
    for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1) }
    split(t,a,"."); print prio, m, a[1], a[2]
  }')

if [ -z "$rules" ]; then
  echo "ОШИБКА: правило PBR для VPN Client не найдено."
  echo "Проверьте: профиль VPN Client создан и включён, и на него ссылается"
  echo "хотя бы одно правило Policy-Based Route. Затем запустите скрипт снова."
  exit 1
fi

n=$(echo "$rules" | wc -l)
echo "Найдено PBR-правил VPN Client: $n"
echo "$rules" | awk '{printf "  приоритет %s, метка %s, таблица %s, профиль %s\n",$1,$2,$3,$4}'

if [ -n "$1" ]; then
  line=$(echo "$rules" | awk -v w="$1" '$4==w{print; exit}')
  [ -z "$line" ] && { echo "ОШИБКА: профиль $1 в правилах не найден"; exit 3; }
elif [ "$n" -gt 1 ]; then
  echo "Профилей несколько. Запустите: $0 <профиль>, например: $0 $(echo "$rules" | awk 'NR==1{print $4}')"
  exit 2
else
  line=$rules
fi
read -r PRIO_D MARK_D TABLE_D RAIL_D <<< "$line"

WAN_D=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
case "$WAN_D" in ""|awg*|wg*) WAN_D=eth3 ;; esac

umask 077
# Ключи обновляются на месте: остальные настройки awg.env (туннели, подсети, домены, awg-self, guard, Telegram…) не трогаются.
F=$DD/awg.env
[ -f "$F" ] || printf '# Параметры AWG. После ручной правки: systemctl restart awg-failover\n' > "$F"
setk(){  # setk КЛЮЧ ЗНАЧЕНИЕ [только_если_нет]
  if grep -q "^$1=" "$F"; then
    [ -n "$3" ] && return 0
    awk -v k="$1" -v v="$2" 'index($0, k"=")==1 {print k"="v; next} {print}' "$F" > "$F.t" && mv "$F.t" "$F"
  else
    printf '%s=%s\n' "$1" "$2" >> "$F"
  fi
}
setk TABLE "$TABLE_D"
setk MARK "$MARK_D"
setk PRIO "$PRIO_D"
setk RAIL_IF "$RAIL_D"
setk WANIF "${WANIF:-$WAN_D}"
setk MAIN "${MAIN:-awgmain}" keep
setk BACKUP "${BACKUP-}" keep
setk VPS_IP "${VPS_IP-}" keep
setk RECOVER_SEC "${RECOVER_SEC:-600}" keep
setk EXTRA_SUBNETS "\"${EXTRA_SUBNETS-}\"" keep
chmod 600 "$F"
echo
echo "Записано в $DD/awg.env:"
sed 's/^/  /' "$DD/awg.env"
