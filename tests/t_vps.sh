#!/bin/bash
# Управление своим VPS (#13) на заглушках: «VPS» — локальные папки, ssh/scp выполняются здесь же.
# Поддельный awg считает handshake только при согласованных ключах и параметрах S1–H4 на обеих сторонах,
# поэтому откат проверяется по-настоящему. Запуск: bash tests/t_vps.sh <папка awg> [папка server]
H=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${1:-$H/../awg}" && pwd); SSRC=$(cd "${2:-$SRC/../server}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd STUB=$T/stub VROOT=$T/vroot VSHARE=$T/vshare VBIN=$T/vbin SRVCONF=$T/vps/server.conf
mkdir -p "$DD/ssh" "$DD/server" "$STUB" "$VROOT" "$VSHARE" "$VBIN" "$T/vps" "$T/bin"
cp "$SRC/vps.sh" "$DD/"; cp "$SSRC/vps-rotate.sh" "$SSRC/audit-server.sh" "$SSRC/awg-server-build.sh" "$DD/server/"; chmod 755 "$DD/vps.sh"
echo key > "$DD/ssh/id_ed25519"; echo "ssh-ed25519 AAAA udr" > "$DD/ssh/id_ed25519.pub"

cat > "$T/awg" <<'A'
#!/bin/bash
pub(){ printf '%s' "$1" | sha256sum | head -c 43; echo =; }
get(){ awk -v s="[$2]" -v k="$3" '/^[[:space:]]*\[/ {sec=tolower($0); gsub(/[[:space:]]/,"",sec)} sec==tolower(s) { l=$0; kk=l; sub(/=.*/,"",kk); gsub(/[ \t]/,"",kk); if (kk==k) { sub(/^[^=]*=[ \t]*/,"",l); print l; exit } }' "$1"; }
case "$1" in
  genkey) head -c 32 /dev/urandom | base64;;
  pubkey) pub "$(cat)";;
  --version) echo "awg v1.0.20250901";;
  show)
    rc=$STUB/applied.$2; sc=$SRVCONF; ok=1
    [ -f "$rc" ] || { echo "peer 0"; exit 0; }
    [ "$(pub "$(get "$sc" interface PrivateKey)")" = "$(get "$rc" peer PublicKey)" ] || ok=0
    [ "$(pub "$(get "$rc" interface PrivateKey)")" = "$(get "$sc" peer PublicKey)" ] || ok=0
    for k in S1 S2 H1 H2 H3 H4; do [ "$(get "$rc" interface $k)" = "$(get "$sc" interface $k)" ] || ok=0; done
    [ -e "$STUB/broken" ] && ok=0
    if [ $ok = 1 ]; then echo "peer $(date +%s)"; else echo "peer 0"; fi;;
esac
A
chmod 755 "$T/awg"; cp "$T/awg" "$DD/awg"; cp "$T/awg" "$VBIN/awg"
printf '#!/bin/bash\necho "$*" >> "%s/vps-systemctl.log"\n' "$STUB" > "$VBIN/systemctl"
printf '#!/bin/bash\ncp "$DD/$( [ "$1" = awgbackup ] && echo backup.conf || echo "$1.conf")" "%s/applied.$1" 2>/dev/null\n' "$STUB" > "$DD/up.sh"
cat > "$T/bin/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$STUB/ssh.log"
[ -e "$STUB/sshfail" ] && { echo "root@vps: Permission denied (publickey)." >&2; exit 255; }
c="${@: -1}"; c=${c//\/root\//$VROOT/}; c=${c//\/usr\/local\/share\//$VSHARE/}
case "$c" in
  *ROLLBACK_BINS=1*) rm -f "$STUB/broken"; echo ROLLED_BACK; exit 0;;
  *"bash $VROOT/awg-server-build.sh"*) eval "$(echo "$c" | grep -o 'AWG_GO_REF=[^ ]* AWG_TOOLS_REF=[^ ]*')"
     printf 'amneziawg-go %s\namneziawg-tools %s\n' "$AWG_GO_REF" "$AWG_TOOLS_REF" > "$VSHARE/amnezia-build.txt"
     [ -e "$STUB/buildbreak" ] && touch "$STUB/broken"; [ -e "$STUB/buildfail" ] && { echo "go: build failed"; exit 1; }
     echo "собрано"; echo BUILT_OK; exit 0;;
esac
PATH=$VBIN:$PATH CONF=$SRVCONF exec bash -c "$c"
S
cat > "$T/bin/scp" <<'S'
#!/bin/bash
echo "scp $*" >> "$STUB/ssh.log"
[ -e "$STUB/sshfail" ] && exit 1
d=${@: -1}; d=${d#*:}; d=${d//\/root\//$VROOT/}; d=${d/#\/root/$VROOT}
n=$#; for ((i=1; i<n; i++)); do a=${!i}; case "$a" in -*|"") continue;; esac; [ -f "$a" ] && cp "$a" "$d"; done
S
cat > "$T/bin/curl" <<'S'
#!/bin/bash
u=""; for a; do case "$a" in http*) u=$a;; esac; done
case "$u" in
  */amneziawg-go/releases/latest) echo '  "tag_name": "v0.2.16",';;
  */amneziawg-tools/releases/latest) echo '  "tag_name": "v1.0.20250901",';;
  *) exit 0;;
esac
S
chmod 755 "$T"/bin/* "$VBIN"/* "$DD/up.sh"
export PATH="$T/bin:$PATH" VPS_WAIT=2

# исходные ключи и параметры: сервер и роутер согласованы
R=$("$T/awg" genkey); S=$("$T/awg" genkey); RP=$(printf '%s' "$R" | "$T/awg" pubkey); SP=$(printf '%s' "$S" | "$T/awg" pubkey)
OBF='Jc = 5\nJmin = 50\nJmax = 200\nS1 = 30\nS2 = 40\nH1 = 1111\nH2 = 2222\nH3 = 3333\nH4 = 4444'
printf "[Interface]\nPrivateKey = %s\nListenPort = 51823\n$OBF\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.1.2/32\n" "$S" "$RP" > "$SRVCONF"
printf "[Interface]\nPrivateKey = %s\nAddress = 10.0.1.2/32\nMTU = 1380\n$OBF\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.9:51823\nPersistentKeepalive = 25\n" "$R" "$SP" > "$DD/backup.conf"
printf '[Interface]\nPrivateKey = x\nAddress = 10.8.0.2/32\nH1 = 100-200\n\n[Peer]\nPublicKey = y\nEndpoint = provider.example.net:443\n' > "$DD/main.conf"
printf 'MAIN=awgmain\nBACKUP=awgbackup\nVPS_IP=203.0.113.9\n' > "$DD/awg.env"
chmod 600 "$DD"/*.conf "$SRVCONF"
"$DD/up.sh" awgbackup
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
V="$DD/vps.sh"
hs(){ [ "$("$DD/awg" show awgbackup latest-handshakes | awk '{print $2}')" != 0 ]; }
ck "исходно handshake есть" 'hs'
ck "туннель к VPS найден, туннель провайдера — нет" '[ "$("$V" tunnels)" = awgbackup ]'
ck "test: вход ключом" '"$V" test | grep -q "ключом роутера работает" && grep -q "BatchMode=yes" "$STUB/ssh.log" && grep -q "UserKnownHostsFile=$DD/ssh/known_hosts" "$STUB/ssh.log"'
touch "$STUB/sshfail"
ck "test: нет ключа на VPS → подсказка" '! "$V" test > "$T/o" && grep -q "ключа роутера нет на VPS" "$T/o"'
rm -f "$STUB/sshfail"
ck "туннель провайдера менять нельзя" '! "$V" rotate-keys awgmain > "$T/o" && grep -q "не туннель к" "$T/o"'

# --- смена ключей: успех
cp "$SRVCONF" "$T/srv.0"; cp "$DD/backup.conf" "$T/rt.0"
"$V" rotate-keys > "$T/o1" 2>&1; rc=$?
ck "ключи: код 0, туннель работает" '[ $rc = 0 ] && grep -q "✔ смена ключей" "$T/o1" && hs' ; [ $rc = 0 ] || cat "$T/o1"
ck "ключи: сменились на обеих сторонах" '! grep -q "$R" "$DD/backup.conf" && ! grep -q "$S" "$SRVCONF" && ! grep -q "$RP" "$SRVCONF"'
ck "ключи: копии есть, временные файлы на VPS убраны" 'ls "$DD"/backup.conf.pre-vps-* >/dev/null && ls "$SRVCONF".pre-rotate-* >/dev/null && [ ! -e "$VROOT/vps-rotate.sh" ]'
ck "ключи: права 600, событие" '[ "$(stat -c %a "$DD/backup.conf")" = 600 ] && grep -q "|vps|смена ключей: awgbackup — готово" "$DD/events.log"'

# --- смена ключей: сервер после перезапуска не отвечает → откат обеих сторон
cp "$SRVCONF" "$T/srv.1"; cp "$DD/backup.conf" "$T/rt.1"
touch "$STUB/broken"
"$V" rotate-keys awgbackup > "$T/o2" 2>&1; rc=$?
rm -f "$STUB/broken"
ck "ключи: нет handshake → код 1 и откат" '[ $rc = 1 ] && grep -q "откатываю обе стороны" "$T/o2" && grep -q "VPS: возвращена копия" "$T/o2"'
ck "ключи: после отката обе стороны как до попытки" 'cmp -s "$DD/backup.conf" "$T/rt.1" && cmp -s "$SRVCONF" "$T/srv.1" && hs'

# --- обфускация
"$V" obfs > "$T/o3" 2>&1; rc=$?
get(){ awk -v k="$2" -F' = ' '$1==k{print $2; exit}' "$1"; }
ck "обфускация: код 0, туннель работает" '[ $rc = 0 ] && hs'; [ $rc = 0 ] || cat "$T/o3"
ck "обфускация: S1–H4 новые и одинаковые на обеих сторонах" 'for k in S1 S2 H1 H2 H3 H4 Jc; do [ "$(get "$DD/backup.conf" $k)" = "$(get "$SRVCONF" $k)" ] || exit 1; done; [ "$(get "$SRVCONF" H1)" != 1111 ] && [ "$(get "$SRVCONF" S1)" != 30 ]'
ck "обфускация: ключи не тронуты, файл параметров убран" 'grep -q "$(get "$T/rt.1" PrivateKey)" "$DD/backup.conf" && [ ! -e "$VROOT/awg-obf.txt" ] && ! ls -d "$DD"/.obf.* >/dev/null 2>&1'
ck "обфускация: S1+56 ≠ S2, Jmax > Jmin" 's1=$(get "$SRVCONF" S1); s2=$(get "$SRVCONF" S2); [ $((s1+56)) -ne "$s2" ] && [ "$(get "$SRVCONF" Jmax)" -gt "$(get "$SRVCONF" Jmin)" ]'
printf 'MAIN=awgmain\nBACKUP=awgbackup\nVPS_IP=203.0.113.9\nTUNNELS_EXTRA="awgalt1"\n' > "$DD/awg.env"
sed 's/^H1 = .*/H1 = 5-100/' "$DD/backup.conf" > "$DD/awgalt1.conf"
ck "обфускация: AWG 2.0 (H — диапазон) не трогаем" '! "$V" obfs awgalt1 > "$T/o4" && grep -q "AWG 2.0" "$T/o4"'
ck "несколько туннелей к VPS — нужно указать" '! "$V" rotate-keys > "$T/o5" && grep -q "укажите какой" "$T/o5"'
rm -f "$DD/awgalt1.conf"; printf 'MAIN=awgmain\nBACKUP=awgbackup\nVPS_IP=203.0.113.9\n' > "$DD/awg.env"

# --- ошибка на VPS до изменений: роутер не трогается
cp "$DD/backup.conf" "$T/rt.2"; sed -i 's/^AllowedIPs = 10.0.1.2\/32/AllowedIPs = 10.0.1.9\/32/' "$SRVCONF"
ck "VPS не нашёл peer: роутер не изменён" '! "$V" rotate-keys > "$T/o6" && grep -q "ничего не изменено" "$T/o6" && cmp -s "$DD/backup.conf" "$T/rt.2"'
sed -i 's/^AllowedIPs = 10.0.1.9\/32/AllowedIPs = 10.0.1.2\/32/' "$SRVCONF"

# --- версии и обновление
printf 'amneziawg-go v0.2.12\namneziawg-tools v1.0.20250901\n' > "$VSHARE/amnezia-build.txt"
"$V" versions > "$T/o7"; rc=$?
ck "versions: есть новее → код 10" '[ $rc = 10 ] && grep -q "amneziawg-go: на VPS v0.2.12, есть v0.2.16" "$T/o7" && grep -q "awg (amneziawg-tools): v1.0.20250901 — последняя" "$T/o7"'
"$V" update > "$T/o8" 2>&1; rc=$?
ck "update: сборка последних релизов, handshake есть" '[ $rc = 0 ] && grep -q "AWG_GO_REF=v0.2.16 AWG_TOOLS_REF=v1.0.20250901 RESTART=1" "$STUB/ssh.log" && grep -q "✔ на VPS amneziawg-go v0.2.16" "$T/o8"'
ck "versions: после обновления актуально" '"$V" versions >/dev/null'
touch "$STUB/buildbreak"
"$V" update > "$T/o9" 2>&1; rc=$?
rm -f "$STUB/buildbreak"
ck "update: нет handshake → откат на прежние файлы" '[ $rc = 1 ] && grep -q "возвращаю прежние файлы" "$T/o9" && grep -q ROLLBACK_BINS=1 "$STUB/ssh.log" && hs'
touch "$STUB/buildfail"
ck "update: сборка упала → сервер не трогается" '! "$V" update > "$T/o10" 2>&1 && grep -q "работает на прежних файлах" "$T/o10"'
rm -f "$STUB/buildfail"

# --- проверки ввода
printf 'VPS_HOST="vps;reboot"\n' > "$DD/vps.env"; : > "$STUB/ssh.log"
ck "адрес VPS с ; отклонён до ssh" '! "$V" test >/dev/null && [ ! -s "$STUB/ssh.log" ]'
rm -f "$DD/vps.env" "$DD/ssh/id_ed25519"
ck "нет ключа роутера → понятная ошибка" '"$V" test | grep -q "нет ключа роутера"'
echo "== vps: ошибок $fails"
[ $fails = 0 ]
