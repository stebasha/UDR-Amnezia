#!/bin/bash
# awg-server-build.sh — сборка amneziawg-go и awg на VPS (Ubuntu 22.04/24.04, x86_64), от root.
# Исходники берутся из того же архива, что и бинарники для роутера: версии протокола совпадут.
set -e
SRC_URL=${SRC_URL:-https://github.com/DjGreeZ/AmneziaWG-Unifi-DreamMachine/raw/main/AmneziaWG-UniFi-v0.2.1-source.tar.gz}
apt-get update -q
apt-get install -y -q git make gcc curl
# Go: snap (Ubuntu) или официальный архив go.dev (Debian и системы без snap)
if ! command -v go >/dev/null 2>&1 && [ ! -x /snap/bin/go ] && [ ! -x /usr/local/go/bin/go ]; then
  if ! { command -v snap >/dev/null 2>&1 && snap install go --classic; }; then
    case "$(uname -m)" in x86_64) GA=amd64;; aarch64) GA=arm64;; *) echo "неизвестная архитектура $(uname -m)"; exit 1;; esac
    curl -fL "https://go.dev/dl/go1.23.4.linux-$GA.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
  fi
fi
export PATH=$PATH:/snap/bin:/usr/local/go/bin
export GOTOOLCHAIN=auto   # если исходникам нужна более новая версия Go, она скачается сама
mkdir -p /root/awgbuild && cd /root/awgbuild
rm -rf go tools source
curl -fL "$SRC_URL" -o src.tar.gz
tar xzf src.tar.gz
mkdir -p go tools
tar xzf source/awg-go.tar.gz -C go
tar xzf source/awg-tools.tar.gz -C tools
( cd go/amneziawg-go-*/ && go build -o /usr/local/bin/amneziawg-go . )
( cd tools/amneziawg-tools-*/src && make && install -m 755 wg /usr/local/bin/awg )
echo
amneziawg-go --version | head -1
awg --version
