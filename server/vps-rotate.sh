#!/bin/bash
# vps-rotate.sh: на VPS, от root. Меняет ключ сервера и ключ клиента-роутера в /etc/amnezia/server.conf.
# Окружение: CLIENT_ADDR=10.0.1.2/32  NEW_CLIENT_PUB=<новый публичный ключ роутера>  [CONF=/etc/amnezia/server.conf]
# Печатает: NEW_SERVER_PUB=<новый публичный ключ сервера>. Перед изменением кладёт копию server.conf.pre-rotate-<время>.
# Откат: ROLLBACK=<файл копии> bash vps-rotate.sh
CONF=${CONF:-/etc/amnezia/server.conf}
SVC=${SVC:-awg-server}
if [ -n "$ROLLBACK" ]; then
  [ -f "$ROLLBACK" ] || { echo "ERROR нет файла $ROLLBACK"; exit 1; }
  cp -p "$ROLLBACK" "$CONF" && systemctl restart "$SVC" && echo "ROLLED_BACK"; exit $?
fi
: "${CLIENT_ADDR:?}" "${NEW_CLIENT_PUB:?}"
[ -f "$CONF" ] || { echo "ERROR нет $CONF"; exit 1; }
command -v awg >/dev/null || { echo "ERROR нет команды awg"; exit 1; }
umask 077
BK="$CONF.pre-rotate-$(date +%s)"
NK=$(awg genkey) || { echo "ERROR genkey"; exit 1; }
NP=$(printf '%s' "$NK" | awg pubkey) || { echo "ERROR pubkey"; exit 1; }
cp -p "$CONF" "$BK"
awk -v RS= -v ORS='\n\n' -v addr="$CLIENT_ADDR" -v np="$NEW_CLIENT_PUB" -v nk="$NK" '
  /^\[Interface\]/ { sub(/PrivateKey *= *[A-Za-z0-9+\/=]+/, "PrivateKey = " nk); print; ik++; next }
  /^\[Peer\]/ && index($0, "AllowedIPs = " addr) { sub(/PublicKey *= *[A-Za-z0-9+\/=]+/, "PublicKey = " np); print; pk++; next }
  { print }
  END { if (ik != 1 || pk != 1) exit 3 }' "$CONF" > "$CONF.new"
rc=$?
if [ $rc -ne 0 ]; then rm -f "$CONF.new"; echo "ERROR не удалось однозначно найти [Interface] и [Peer] с AllowedIPs = $CLIENT_ADDR (код $rc), файл не изменён"; exit 3; fi
mv "$CONF.new" "$CONF"; chmod 600 "$CONF"
systemctl restart "$SVC" || { echo "ERROR сервис не перезапустился"; cp -p "$BK" "$CONF"; systemctl restart "$SVC"; exit 4; }
echo "BACKUP_FILE=$BK"
echo "NEW_SERVER_PUB=$NP"
