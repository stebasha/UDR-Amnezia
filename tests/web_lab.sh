#!/bin/bash
# Стенд для веб-панели: поддельный /data/awg, заглушки ip/awg/systemctl/curl и счётчики трафика.
#   tests/web_lab.sh ДИР ПОРТ [--traffic]   → печатает PID панели; стенд в ДИР
# Пользователь admin / пароль Test-pass-123.
set -e
L=$1; PORT=${2:-18443}; R=$(cd "$(dirname "$0")/.." && pwd)
rm -rf "$L"; mkdir -p "$L"/{dd/web,stub/links,stub/hs,stub/svc,stub/up,sys,sysd,run,bin}
DD=$L/dd; STUB=$L/stub
cp "$R"/tests/stubs5/* "$L/bin/"
cp "$R"/awg/*.sh "$DD/"
cp "$R"/tests/stubs5/awg "$DD/awg"; printf "#!/bin/bash\necho amneziawg-go v3.1.20260828\n" > "$DD/amneziawg-go"
cp "$R"/awg/*.service "$DD/" 2>/dev/null || true
cp -r "$R/awg/web/." "$DD/web/"
rm -rf "$DD/web/__pycache__"
# up.sh и прочее, что трогает систему, — заглушки
for f in up.sh mtu.sh backup.sh awg-notify.sh; do printf '#!/bin/bash\necho "%s $*: ок"\n' "$f" > "$DD/$f"; done
cat > "$DD/backup.sh" <<'EOF'
#!/bin/bash
mkdir -p "$DD/backups"; f=$DD/backups/awg-backup-$(date +%Y%m%d-%H%M%S).tgz.enc; head -c 4000 /dev/urandom > "$f"; echo "копия: $f"
EOF
chmod +x "$DD"/*.sh "$DD/awg" "$DD/amneziawg-go" "$L"/bin/*
echo "1.3.0" > "$DD/VERSION"
cat > "$DD/awg.env" <<'EOF'
MAIN=awgmain
BACKUP=awgbackup
TUNNELS_EXTRA="awgalt1"
TABLE=201.wgclt1
MARK=0x6a0000/0x7e0000
PRIO=32503
RAIL_IF=wgclt1
WANIF=eth3
RECOVER_SEC=600
QUALITY=yes
QUALITY_LOSS=40
LEAK_GUARD=yes
TUN_DOMAINS="youtube.com googlevideo.com"
DIRECT_DOMAINS="gosuslugi.ru"
EOF
for t in main backup awgalt1; do
  ep=$( [ $t = main ] && echo 198.51.100.20:51820 || { [ $t = backup ] && echo 203.0.113.77:443 || echo 192.0.2.44:8443; } )
  cat > "$DD/$t.conf" <<EOF
[Interface]
PrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI=
Address = 10.8.1.$((RANDOM%200+2))/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 70
H1 = 123456
$( [ $t = main ] && printf 'S3 = 20\nS4 = 10\nI1 = <b 0x0102>\n' )
[Peer]
PublicKey = c2VydmVyLXNlcnZlci1zZXJ2ZXItc2VydmVyLWtleTE=
PresharedKey = cHNrLXBzay1wc2stcHNrLXBzay1wc2stcHNrLXBzazE=
Endpoint = $ep
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$DD/$t.conf"
done
now=$(date +%s)
{
  echo "$((now-6*86400))|start|основной awgmain, всего туннелей 3"
  echo "$((now-5*86400))|switch|awgmain не отвечает → awgbackup"
  echo "$((now-5*86400+900))|return|awgmain снова стабилен → awgmain"
  echo "$((now-2*86400))|degrade|awgmain: потери 55% → awgbackup"
  echo "$((now-2*86400+1300))|return|awgmain снова стабилен → awgmain"
  echo "$((now-7200))|force|вручную: awgbackup"
  echo "$((now-6900))|auto|возврат к автоматическому выбору"
  echo "$((now-600))|start|основной awgmain, всего туннелей 3"
} > "$DD/events.log"
for t in awgmain awgbackup awgalt1; do
  touch "$STUB/links/$t" "$STUB/up/$t"; mkdir -p "$L/sys/$t/statistics"; echo 1376 > "$L/sys/$t/mtu"
  echo 0 > "$L/sys/$t/statistics/rx_bytes"; echo 0 > "$L/sys/$t/statistics/tx_bytes"
done
rm "$STUB/up/awgalt1"
echo 4 > "$STUB/hs/awgmain"; echo 37 > "$STUB/hs/awgbackup"
printf 'default dev awgmain metric 5\nblackhole default metric 200\n' > "$STUB/table"
for s in awg-failover awg-guard awg-self awg-notify; do touch "$STUB/svc/$s" "$L/sysd/$s.service"; done
printf 'ACTIVE=awgmain\nFORCED=\nUPDATED=%s\nTUNNELS="awgmain awgbackup awgalt1"\nLOSS_awgmain=0\nRTT_awgmain=38\nLOSS_awgbackup=0\nRTT_awgbackup=61\nLOSS_awgalt1=100\nDNS_awgmain=1\nDNS_awgbackup=1\nDNS_awgalt1=0\n' "$now" > "$L/run/awg-state"
printf 'WEB_PORT=%s\nWEB_BIND=127.0.0.1\nWEB_TLS=no\n' "$PORT" > "$DD/web/web.conf"
export DD STUB PATH="$L/bin:$PATH" AWG_RUN="$L/run" SYSD="$L/sysd" AWG_SYSNET="$L/sys" AWG_WEBD="$DD/web"
echo 'Test-pass-123' | python3 "$DD/web/panel.py" passwd admin --stdin >/dev/null
if [ "${3:-}" = --traffic ]; then
  ( a=0; b=0; c=0; d=0; i=0
    while sleep 1; do i=$((i+1))
      a=$((a + 2500000 + (RANDOM*60) + (i%17<4 ? 3000000 : 0))); b=$((b + 300000 + RANDOM*8))
      c=$((c + 20000 + RANDOM)); d=$((d + 8000 + RANDOM/2))
      for kv in awgmain/rx:$a awgmain/tx:$b awgbackup/rx:$c awgbackup/tx:$d; do
        f=$L/sys/${kv%%/*}/statistics/${kv#*/}; f=${f%%:*}_bytes; echo "${kv#*:}" > "$f.t" && mv "$f.t" "$f"
      done
      date +%s > /dev/null; sed -i "s/^UPDATED=.*/UPDATED=$(date +%s)/" "$L/run/awg-state"
    done ) >/dev/null 2>&1 &
  echo $! > "$L/traffic.pid"
fi
python3 "$DD/web/panel.py" serve > "$L/panel.log" 2>&1 &
echo $! > "$L/panel.pid"
for _ in $(seq 50); do /usr/bin/curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
cat "$L/panel.pid"
