#!/bin/bash
# awg-build-router.sh — сборка amneziawg-go и awg для UniFi Dream Router 7 (linux/arm64) из официальных исходников:
#   https://github.com/amnezia-vpn/amneziawg-go      (userspace-реализация, Go)
#   https://github.com/amnezia-vpn/amneziawg-tools   (утилита awg, C)
# Где запускать: ваш VPS или любой компьютер с Ubuntu/Debian (x86_64 или arm64, в том числе WSL), от root.
# На самом роутере не запускать: компилятора там нет.
#   bash awg-build-router.sh
#   AWG_GO_REF=v3.1.20260828 AWG_TOOLS_REF=v3.1.20260812 bash awg-build-router.sh   (другие теги)
# Результат: /root/awgbuild/router/{amneziawg-go,awg,SHA256SUMS,BUILDINFO}. Оба файла статические.
# Перенос на роутер:  scp /root/awgbuild/router/* root@IP_РОУТЕРА:/tmp/awgbin/
# затем на роутере: /data/awg/install.sh → бинарники → «Папка на роутере» → /tmp/awgbin
set -euo pipefail
AWG_GO_REF=${AWG_GO_REF:-v3.1.20260828}
AWG_TOOLS_REF=${AWG_TOOLS_REF:-v3.1.20260812}
GO_FALLBACK=${GO_FALLBACK:-1.25.12}
OUT=${OUT:-/root/awgbuild/router}
SRC=${SRC:-/root/awgbuild/src-router}
[ -d /data/unifi-core ] && { echo "Это роутер UniFi: собирайте на VPS или компьютере с Ubuntu/Debian"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root (sudo -i)"; exit 1; }
HOSTARCH=$(uname -m)
case "$HOSTARCH" in x86_64|aarch64) ;; *) echo "архитектура $HOSTARCH не поддерживается этим скриптом"; exit 1;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
PK="git make gcc libc6-dev curl ca-certificates"
[ "$HOSTARCH" = x86_64 ] && PK="$PK gcc-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu"
# shellcheck disable=SC2086
apt-get install -y -q $PK

ensure_go(){
  export PATH=$PATH:/snap/bin:/usr/local/go/bin
  command -v go >/dev/null 2>&1 && return 0
  if command -v snap >/dev/null 2>&1 && snap install go --classic; then return 0; fi
  local ga; case "$HOSTARCH" in x86_64) ga=amd64;; aarch64) ga=arm64;; esac
  curl -fL "https://go.dev/dl/go${GO_FALLBACK}.linux-$ga.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
}
ensure_go
export GOTOOLCHAIN=auto

rm -rf "$OUT"                           # старые файлы не должны попасть на роутер, если сборка не удастся
mkdir -p "$SRC" "$OUT"; cd "$SRC"
rm -rf amneziawg-go amneziawg-tools
git -c advice.detachedHead=false clone -q --depth 1 --branch "$AWG_GO_REF" https://github.com/amnezia-vpn/amneziawg-go
git -c advice.detachedHead=false clone -q --depth 1 --branch "$AWG_TOOLS_REF" https://github.com/amnezia-vpn/amneziawg-tools
GO_COMMIT=$(git -C amneziawg-go rev-parse HEAD); TOOLS_COMMIT=$(git -C amneziawg-tools rev-parse HEAD)
printf 'package main\n\nconst Version = "%s"\n' "$AWG_GO_REF" > amneziawg-go/version.go

echo "== amneziawg-go ($AWG_GO_REF) → linux/arm64, статически (CGO_ENABLED=0)"
( cd amneziawg-go && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags '-s -w' -o "$OUT/amneziawg-go" . )

echo "== awg ($AWG_TOOLS_REF) → linux/arm64, статически"
cd amneziawg-tools/src
make -s clean >/dev/null 2>&1 || true
if [ "$HOSTARCH" = x86_64 ]; then
  make -s CC=aarch64-linux-gnu-gcc LDFLAGS=-static 2>&1 | grep -v "getaddrinfo" || true
  STRIP=aarch64-linux-gnu-strip
else
  make -s LDFLAGS=-static 2>&1 | grep -v "getaddrinfo" || true
  STRIP=strip
fi
[ -x wg ] || { echo "ОШИБКА: awg не собрался"; exit 1; }
install -m 755 wg "$OUT/awg"
command -v "$STRIP" >/dev/null && "$STRIP" "$OUT/awg" || true

# проверка: ELF для AArch64 (e_machine = 0xB7)
for f in amneziawg-go awg; do
  m=$(od -An -t x1 -j 18 -N 2 "$OUT/$f" | tr -d ' \n')
  [ "$m" = b700 ] || { echo "ОШИБКА: $f собран не под AArch64 (e_machine=$m)"; exit 1; }
done
cd "$OUT"
sha256sum amneziawg-go awg > SHA256SUMS
cat > BUILDINFO <<INFO
amneziawg-go   https://github.com/amnezia-vpn/amneziawg-go   $AWG_GO_REF ($GO_COMMIT)
amneziawg-tools https://github.com/amnezia-vpn/amneziawg-tools $AWG_TOOLS_REF ($TOOLS_COMMIT)
built: $(date -u '+%F %T') UTC on $(. /etc/os-release; echo "$PRETTY_NAME") $HOSTARCH, $(go version | awk '{print $3}')
INFO
echo
cat SHA256SUMS; echo; cat BUILDINFO
echo
echo "Готово: $OUT (amneziawg-go, awg, SHA256SUMS, BUILDINFO)"
echo "Перенос на роутер: scp $OUT/* root@IP_РОУТЕРА:/tmp/awgbin/"
