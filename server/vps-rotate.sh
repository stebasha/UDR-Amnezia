#!/bin/bash
# vps-rotate.sh: на VPS, от root. Согласованная смена на сервере AmneziaWG: ключи и/или параметры обфускации.
# Окружение (одно или оба):
#   CLIENT_ADDR=10.0.1.2/32 NEW_CLIENT_PUB=<новый публичный ключ роутера>  — новый ключ сервера и ключ клиента-роутера
#   OBF_FILE=/root/awg-obf.txt  — заменить Jc, Jmin, Jmax, S1, S2, H1–H4 в [Interface] (9 строк «Ключ = число»)
#   [CONF=/etc/amnezia/server.conf]
# Печатает: BACKUP_FILE=<копия до изменения>, NEW_SERVER_PUB=<ключ> (если меняли ключи).
# Откат: ROLLBACK=<файл копии> bash vps-rotate.sh
CONF=${CONF:-/etc/amnezia/server.conf}
SVC=${SVC:-awg-server}
OBFK="Jc Jmin Jmax S1 S2 H1 H2 H3 H4"
if [ -n "$ROLLBACK" ]; then
  [ -f "$ROLLBACK" ] || { echo "ERROR нет файла $ROLLBACK"; exit 1; }
  cp -p "$ROLLBACK" "$CONF" && systemctl restart "$SVC" && echo "ROLLED_BACK"; exit $?
fi
[ -n "$NEW_CLIENT_PUB" ] || [ -n "$OBF_FILE" ] || { echo "ERROR задайте NEW_CLIENT_PUB и CLIENT_ADDR и/или OBF_FILE"; exit 1; }
[ -f "$CONF" ] || { echo "ERROR нет $CONF"; exit 1; }
command -v awg >/dev/null || { echo "ERROR нет команды awg"; exit 1; }
umask 077
BK="$CONF.pre-rotate-$(date +%s)"
cp -p "$CONF" "$BK"
cp -p "$CONF" "$CONF.new"

if [ -n "$OBF_FILE" ]; then
  [ -f "$OBF_FILE" ] || { rm -f "$CONF.new"; echo "ERROR нет $OBF_FILE"; exit 1; }
  for k in $OBFK; do
    grep -qE "^[[:space:]]*${k}[[:space:]]*=[[:space:]]*[0-9]{1,10}[[:space:]]*$" "$OBF_FILE" || { rm -f "$CONF.new"; echo "ERROR в $OBF_FILE нет числа $k"; exit 2; }
  done
  awk -v obf="$OBF_FILE" -v keys="$OBFK" '
    BEGIN { while ((getline l < obf) > 0) { k = l; sub(/=.*/, "", k); gsub(/[ \t\r]/, "", k); v = l; sub(/^[^=]*=/, "", v); gsub(/[ \t\r]/, "", v); m[k] = v } }
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[[:space:]]/, "", sec) }
    sec == "[interface]" { k = $0; sub(/=.*/, "", k); gsub(/[ \t\r]/, "", k); if (index(" " keys " ", " " k " ") && (k in m)) { print k " = " m[k]; done[k] = 1; next } }
    { print }
    END { n = split(keys, a, " "); for (i = 1; i <= n; i++) if (!(a[i] in done)) exit 6 }' "$CONF.new" > "$CONF.obf"
  rc=$?
  if [ $rc -ne 0 ]; then rm -f "$CONF.new" "$CONF.obf"; echo "ERROR в [Interface] сервера нет всех параметров Jc..H4 (код $rc), файл не изменён"; exit 6; fi
  mv "$CONF.obf" "$CONF.new"
fi

NP=""
if [ -n "$NEW_CLIENT_PUB" ]; then
  : "${CLIENT_ADDR:?}"
  NK=$(awg genkey) || { rm -f "$CONF.new"; echo "ERROR genkey"; exit 1; }
  NP=$(printf '%s' "$NK" | awg pubkey) || { rm -f "$CONF.new"; echo "ERROR pubkey"; exit 1; }
  awk -v RS= -v ORS='\n\n' -v addr="$CLIENT_ADDR" -v np="$NEW_CLIENT_PUB" -v nk="$NK" '
    /^\[Interface\]/ { sub(/PrivateKey *= *[A-Za-z0-9+\/=]+/, "PrivateKey = " nk); print; ik++; next }
    /^\[Peer\]/ && index($0, "AllowedIPs = " addr) { sub(/PublicKey *= *[A-Za-z0-9+\/=]+/, "PublicKey = " np); print; pk++; next }
    { print }
    END { if (ik != 1 || pk != 1) exit 3 }' "$CONF.new" > "$CONF.keys"
  rc=$?
  if [ $rc -ne 0 ]; then rm -f "$CONF.new" "$CONF.keys"; echo "ERROR не удалось однозначно найти [Interface] и [Peer] с AllowedIPs = $CLIENT_ADDR (код $rc), файл не изменён"; exit 3; fi
  mv "$CONF.keys" "$CONF.new"
fi

mv "$CONF.new" "$CONF"; chmod 600 "$CONF"
systemctl restart "$SVC" || { echo "ERROR сервис не перезапустился"; cp -p "$BK" "$CONF"; systemctl restart "$SVC"; exit 4; }
echo "BACKUP_FILE=$BK"
[ -n "$NP" ] && echo "NEW_SERVER_PUB=$NP"
exit 0
