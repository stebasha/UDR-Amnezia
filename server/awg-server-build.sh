#!/bin/bash
# awg-server-build.sh — сборка amneziawg-go и awg на VPS (Ubuntu/Debian, x86_64 или arm64), от root.
# Только официальные исходники AmneziaVPN:
#   https://github.com/amnezia-vpn/amneziawg-go      (userspace-реализация, Go)
#   https://github.com/amnezia-vpn/amneziawg-tools   (утилита awg, C)
# Версии задаются тегами и совпадают с теми, что собираются для роутера (awg-build-router.sh):
#   AWG_GO_REF=v3.1.20260828 AWG_TOOLS_REF=v3.1.20260812 bash awg-server-build.sh
# Устанавливает /usr/local/bin/amneziawg-go и /usr/local/bin/awg; прежние сохраняются как *.prev,
# теги сборки — в /usr/local/share/amnezia-build.txt.
#   RESTART=1 — перезапустить awg-server на новых файлах;  ROLLBACK_BINS=1 bash awg-server-build.sh — вернуть *.prev
set -euo pipefail
BIN=${BIN:-/usr/local/bin}
INFO=${INFO:-/usr/local/share/amnezia-build.txt}
if [ "${ROLLBACK_BINS:-}" = 1 ]; then
  [ -f "$BIN/amneziawg-go.prev" ] && [ -f "$BIN/awg.prev" ] || { echo "ERROR нет $BIN/*.prev"; exit 1; }
  cp -p "$BIN/amneziawg-go.prev" "$BIN/amneziawg-go"; cp -p "$BIN/awg.prev" "$BIN/awg"
  [ -f "$INFO.prev" ] && cp -p "$INFO.prev" "$INFO"
  systemctl restart awg-server 2>/dev/null || true
  echo "ROLLED_BACK"; exit 0
fi
AWG_GO_REF=${AWG_GO_REF:-v3.1.20260828}
AWG_TOOLS_REF=${AWG_TOOLS_REF:-v3.1.20260812}
GO_FALLBACK=${GO_FALLBACK:-1.25.12}     # версия Go с go.dev, если нет snap (дальше GOTOOLCHAIN=auto скачает нужную)
SRC=${SRC:-/root/awgbuild/src}
[ -d /data/unifi-core ] && { echo "Это роутер UniFi. Скрипт запускается на VPS."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git make gcc libc6-dev curl ca-certificates

ensure_go(){
  export PATH=$PATH:/snap/bin:/usr/local/go/bin
  command -v go >/dev/null 2>&1 && return 0
  if command -v snap >/dev/null 2>&1 && snap install go --classic; then return 0; fi
  local ga; case "$(uname -m)" in x86_64) ga=amd64;; aarch64) ga=arm64;; *) echo "неизвестная архитектура $(uname -m)"; exit 1;; esac
  curl -fL "https://go.dev/dl/go${GO_FALLBACK}.linux-$ga.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
}
ensure_go
export GOTOOLCHAIN=auto   # если исходникам нужна более новая версия Go, она скачается сама (с go.dev)

mkdir -p "$SRC"; cd "$SRC"
rm -rf amneziawg-go amneziawg-tools
git -c advice.detachedHead=false clone -q --depth 1 --branch "$AWG_GO_REF" https://github.com/amnezia-vpn/amneziawg-go
git -c advice.detachedHead=false clone -q --depth 1 --branch "$AWG_TOOLS_REF" https://github.com/amnezia-vpn/amneziawg-tools
printf 'package main\n\nconst Version = "%s"\n' "$AWG_GO_REF" > amneziawg-go/version.go
# сначала собрать всё во временную папку: при ошибке сборки работающие файлы не трогаются
( cd amneziawg-go && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$SRC/amneziawg-go.bin" . )
( cd amneziawg-tools/src && make -s clean >/dev/null 2>&1 || true; make -s && cp wg "$SRC/awg.bin" )
"$SRC/amneziawg-go.bin" --version >/dev/null && "$SRC/awg.bin" --version >/dev/null
mkdir -p "$(dirname "$INFO")"
if [ -f "$BIN/amneziawg-go" ] && [ -f "$BIN/awg" ]; then
  cp -p "$BIN/amneziawg-go" "$BIN/amneziawg-go.prev"; cp -p "$BIN/awg" "$BIN/awg.prev"
  [ -f "$INFO" ] && cp -p "$INFO" "$INFO.prev"
fi
install -m 755 "$SRC/amneziawg-go.bin" "$BIN/amneziawg-go"; install -m 755 "$SRC/awg.bin" "$BIN/awg"
rm -f "$SRC/amneziawg-go.bin" "$SRC/awg.bin"
printf 'amneziawg-go %s\namneziawg-tools %s\nbuilt %s\n' "$AWG_GO_REF" "$AWG_TOOLS_REF" "$(date -u '+%F %T')" > "$INFO"
[ "${RESTART:-}" = 1 ] && systemctl restart awg-server
echo
"$BIN/amneziawg-go" --version | head -1
"$BIN/awg" --version
echo "собрано из amnezia-vpn/amneziawg-go@$AWG_GO_REF и amnezia-vpn/amneziawg-tools@$AWG_TOOLS_REF"
echo "BUILT_OK"
