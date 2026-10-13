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
if [[ " $* " == *" PubkeyAuthentication=no "* ]]; then      # вход по паролю: пароль — через SSH_ASKPASS, как у настоящего ssh
  [ "$SSH_ASKPASS_REQUIRE" = force ] && [ -x "$SSH_ASKPASS" ] || exit 255
  [ "$("$SSH_ASKPASS")" = "$(cat "$STUB/vpspass")" ] || { echo "Permission denied (password)." >&2; exit 255; }
  HOME=$VROOT exec bash -c "${@: -1}"
fi
if [ -e "$STUB/needkey" ] && ! grep -qF "$(cat "$DD/ssh/id_ed25519.pub" 2>/dev/null)" "$VROOT/.ssh/authorized_keys" 2>/dev/null; then
  echo "Permission denied (publickey)." >&2; exit 255
fi
c="${@: -1}"; c=${c//\/root\//$VROOT/}; c=${c//\/usr\/local\/share\//$VSHARE/}
case "$c" in
  *ROLLBACK_BINS=1*) rm -f "$STUB/broken"; echo ROLLED_BACK; exit 0;;
  *"bash $VROOT/awg-build-router.sh"*) [ -e "$STUB/rbfail" ] && { echo "go: build failed"; exit 1; }
     mkdir -p "$VROOT/awgbuild/router"; cd "$VROOT/awgbuild/router" || exit 1
     printf '#!/bin/bash\necho "amneziawg-go v0.2.16"\n' > amneziawg-go; printf '#!/bin/bash\necho "awg v1.0.20250901"\n' > awg
     sha256sum amneziawg-go awg > SHA256SUMS; echo "built $c" > BUILDINFO; echo собрано; exit 0;;
  *"bash $VROOT/awg-server-setup.sh"*)    # новый сервер: свой ключ клиента, сервер принимает его
     eval "$(echo "$c" | grep -o 'VPS_IP=[^ ]* PORT=[^ ]*')"; mkdir -p "$VROOT/awgbuild"
     CONF=$SRVCONF; awg(){ "$VBIN/awg" "$@"; }
     ck_=$(awg genkey); cp_=$(printf '%s' "$ck_" | awg pubkey); sp_=$(awk -F' = ' '$1=="PrivateKey"{print $2; exit}' "$CONF" | tr -d '\n' | awg pubkey)
     sed -i "/^\[Peer\]/,\$ s|^PublicKey = .*|PublicKey = $cp_|" "$CONF"
     { printf '[Interface]\nPrivateKey = %s\nAddress = 10.0.1.2/32\nMTU = 1380\n' "$ck_"; grep -E '^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4) =' "$CONF"
       printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = %s:%s\nPersistentKeepalive = 25\n' "$sp_" "$VPS_IP" "$PORT"; } > "$VROOT/awgbuild/client.conf"
     echo "Созданы server.conf и client.conf"; exit 0;;
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
d=${@: -1}
if [[ $d == *:* ]]; then   # на «VPS»
  d=${d#*:}; d=${d//\/root\//$VROOT/}; d=${d/#\/root/$VROOT}
  n=$#; for ((i=1; i<n; i++)); do a=${!i}; case "$a" in -*|"") continue;; esac; [ -f "$a" ] && cp "$a" "$d"; done
else                        # с «VPS»
  s=${@: -2:1}; s=${s#*:}; s=${s//\/root\//$VROOT/}; cp "$s" "$d"
fi
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
hs_t(){ [ "$("$DD/awg" show "$1" latest-handshakes | awk '{print $2}')" != 0 ]; }
ck "исходно handshake есть" 'hs'
ck "туннель к VPS найден, туннель провайдера — нет" '[ "$("$V" tunnels)" = awgbackup ]'
printf 'MAIN=awgmain\nBACKUP=awgbackup\n' > "$DD/awg.env"
ck "адрес VPS не задан — туннелей к VPS нет (на роутере выдавался туннель провайдера)" '[ -z "$("$V" tunnels)" ]'
printf 'MAIN=awgmain\nBACKUP=awgbackup\nVPS_IP=203.0.113.9\n' > "$DD/awg.env"
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

# --- бинарники роутера, собранные на VPS (#29)
cp "$SSRC/awg-build-router.sh" "$DD/server/"
printf '#!/bin/bash\necho "install.sh $*" >> "%s/install.log"; d=$2; ( cd "$d" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "сумма не совпала"; exit 1; }; [ -e "%s/bfail" ] && exit 1; echo "установлены"; exit 0\n' "$STUB" "$STUB" > "$DD/install.sh"; chmod 755 "$DD/install.sh"
"$V" router-bins > "$T/o11" 2>&1; rc=$?
ck "router-bins: сборка на VPS последних релизов, файлы с суммами → install.sh --bins-update" '[ $rc = 0 ] && grep -q "AWG_GO_REF=v0.2.16 AWG_TOOLS_REF=v1.0.20250901 bash" "$STUB/ssh.log" && grep -q "install.sh --bins-update $DD/.bins." "$STUB/install.log" && ! ls -d "$DD"/.bins.* >/dev/null 2>&1 && [ ! -e "$VROOT/awg-build-router.sh" ]'
ck "router-bins: событие" 'grep -q "|vps|бинарники роутера обновлены: amneziawg-go v0.2.16" "$DD/events.log"'
touch "$STUB/rbfail"; : > "$STUB/install.log"
ck "router-bins: сборка упала → роутер не тронут" '! "$V" router-bins > "$T/o12" 2>&1 && grep -q "роутер не тронут" "$T/o12" && [ ! -s "$STUB/install.log" ]'
rm -f "$STUB/rbfail"; touch "$STUB/bfail"
ck "router-bins: установка не удалась → код ошибки и событие" '! "$V" router-bins >/dev/null 2>&1 && grep -q "не удалось, работают прежние" "$DD/events.log"'
rm -f "$STUB/bfail"

# --- проверки ввода
printf 'VPS_HOST="vps;reboot"\n' > "$DD/vps.env"; : > "$STUB/ssh.log"
ck "адрес VPS с ; отклонён до ssh" '! "$V" test >/dev/null && [ ! -s "$STUB/ssh.log" ]'
rm -f "$DD/vps.env" "$DD/ssh/id_ed25519"
ck "нет ключа роутера → понятная ошибка" '"$V" test | grep -q "нет ключа роутера"'
# --- мастер своего VPS (#28): пароль один раз → ключ → сервер → туннель
cp "$SSRC/awg-server-setup.sh" "$DD/server/"; mkdir -p "$DD/web"
cat > "$T/bin/ssh-keygen" <<'K'
#!/bin/bash
f=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
head -c 32 /dev/urandom | base64 > "$f"; echo "ssh-ed25519 AAAA$(head -c 16 /dev/urandom | base64 | tr -d '=+/') udr-awg@test" > "$f.pub"
K
chmod 755 "$T/bin/ssh-keygen"
cat > "$DD/web/panel.py" <<'P'
import os, sys
dd = os.environ["DD"]; name, src = sys.argv[2], sys.argv[3]
open(os.path.join(dd, name + ".conf"), "w").write(open(src).read())
e = open(os.path.join(dd, "awg.env")).read()
open(os.path.join(dd, "awg.env"), "a").write('TUNNELS_EXTRA="%s"\n' % name)
os.system(os.path.join(dd, "up.sh") + " " + name)
print("%s поднят" % name)
P
printf 'MAIN=awgmain\nBACKUP=awgbackup\n' > "$DD/awg.env"; printf 'VPS_HOST="198.51.100.7"\nVPS_PORT="22"\nVPS_USER="root"\n' > "$DD/vps.env"
rm -f "$DD/ssh/id_ed25519" "$DD/ssh/id_ed25519.pub" "$VROOT/awgbuild/client.conf"; touch "$STUB/needkey"; echo 'Vps-Root-Pass' > "$STUB/vpspass"
ck "мастер: без пароля и без ключа на VPS — понятный отказ" '! "$V" setup > "$T/w0" 2>&1 && grep -q "пароль не указан" "$T/w0"'
printf 'wrong' > "$DD/.vpspass-x"; chmod 600 "$DD/.vpspass-x"
ck "мастер: неверный пароль — отказ, файл пароля удалён" '! VPS_PASS_FILE="$DD/.vpspass-x" "$V" setup > "$T/w1" 2>&1 && grep -q "вход по паролю не удался" "$T/w1" && [ ! -e "$DD/.vpspass-x" ]'
printf 'Vps-Root-Pass' > "$DD/.vpspass-y"; chmod 600 "$DD/.vpspass-y"; : > "$STUB/ssh.log"
VPS_PASS_FILE="$DD/.vpspass-y" "$V" setup awgvps 51888 > "$T/w2" 2>&1; rc=$?
ck "мастер: туннель awgvps работает (handshake, интернет)" '[ $rc = 0 ] && grep -q "свой VPS подключён: туннель awgvps работает" "$T/w2" && hs_t awgvps' ; [ $rc = 0 ] || cat "$T/w2"
ck "мастер: ключ роутера создан и лежит на VPS, файл пароля удалён" '[ -f "$DD/ssh/id_ed25519" ] && grep -qF "$(cat "$DD/ssh/id_ed25519.pub")" "$VROOT/.ssh/authorized_keys" && [ ! -e "$DD/.vpspass-y" ]'
ck "мастер: пароль не попал в аргументы ssh, файлы и журнал" '! grep -rq "Vps-Root-Pass" "$STUB/ssh.log" "$T/w2" "$DD"/*.env "$DD"/*.log 2>/dev/null'
ck "мастер: сервер создан на нужном порту и адресе, конфиг клиента на VPS удалён" 'grep -q "Endpoint = 198.51.100.7:51888" "$DD/awgvps.conf" && [ ! -e "$VROOT/awgbuild/client.conf" ] && [ ! -e "$VROOT/awg-server-setup.sh" ]'
ck "мастер: VPS_IP записан, событие" 'grep -qx "VPS_IP=198.51.100.7" "$DD/awg.env" && grep -q "|vps|свой VPS 198.51.100.7 подключён: туннель awgvps" "$DD/events.log"'
ck "мастер: занятое имя туннеля — отказ" '! "$V" setup awgvps > "$T/w3" 2>&1 && grep -q "уже есть" "$T/w3"'
# --- только ключ роутера на уже настроенный VPS
rm -f "$DD/ssh/id_ed25519" "$DD/ssh/id_ed25519.pub" "$VROOT/.ssh/authorized_keys"
ck "addkey: без пароля — отказ" '! "$V" addkey > "$T/k0" 2>&1 && grep -q "укажите пароль VPS" "$T/k0"'
printf 'Vps-Root-Pass' > "$DD/.vpspass-z"
ck "addkey: ключ положен, файл пароля удалён, сервер не тронут" 'cp "$SRVCONF" "$T/srv.k"; VPS_PASS_FILE="$DD/.vpspass-z" "$V" addkey | grep -q "ключ роутера добавлен" && grep -qF "$(cat "$DD/ssh/id_ed25519.pub")" "$VROOT/.ssh/authorized_keys" && [ ! -e "$DD/.vpspass-z" ] && cmp -s "$SRVCONF" "$T/srv.k"'
ck "addkey: повторно — «уже на VPS»" '"$V" addkey | grep -q "уже на VPS"'
rm -f "$STUB/needkey"
echo "== vps: ошибок $fails"
[ $fails = 0 ]
