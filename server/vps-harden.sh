#!/bin/bash
# vps-harden.sh: на VPS, от root. Защита сервера. Режимы (HARDEN_MODE): report (по умолчанию) | apply.
# apply управляется переменными: DO_UPGRADES=1 DO_FAIL2BAN=1 DO_SSH_KEYS_ONLY=1, SSH_PORT=22, AWG_PORT=51823.
# Ничего не делает сверх выбранного. ufw НЕ включается (включённый ufw с политикой FORWARD=DROP ломает NAT туннеля);
# если ufw уже активен — добавляются разрешения для SSH и порта AWG.
SSH_PORT=${SSH_PORT:-22}; AWG_PORT=${AWG_PORT:-51823}
MODE=${HARDEN_MODE:-report}
DROP=/etc/ssh/sshd_config.d/00-awg-hardening.conf
keys_count(){ local n=0 f; for f in /root/.ssh/authorized_keys; do [ -s "$f" ] && n=$(grep -c -E '^(ssh-|ecdsa-|sk-)' "$f"); done; echo "${n:-0}"; }
pkg(){ dpkg -s "$1" >/dev/null 2>&1 && echo yes || echo no; }

report(){
  echo "OS=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
  echo "UNATTENDED_UPGRADES=$(pkg unattended-upgrades)"
  echo "FAIL2BAN=$(pkg fail2ban) ACTIVE=$(systemctl is-active fail2ban 2>/dev/null)"
  if command -v ufw >/dev/null; then echo "UFW=$(ufw status 2>/dev/null | head -n1 | awk '{print $2}')"; echo "UFW_FORWARD=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d= -f2)"; else echo "UFW=absent"; fi
  echo "SSH_PASSWORD_AUTH=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
  echo "SSH_ROOT_LOGIN=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')"
  echo "AUTHORIZED_KEYS=$(keys_count)"
  echo "SSHD_INCLUDE_DIR=$(grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config.d' /etc/ssh/sshd_config 2>/dev/null && echo yes || echo no)"
  echo "AWG_SERVER=$(systemctl is-active awg-server 2>/dev/null)"
}

apply(){
  export DEBIAN_FRONTEND=noninteractive
  if [ "$DO_UPGRADES" = 1 ]; then
    if apt-get install -y unattended-upgrades >/dev/null 2>&1; then
      printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
      echo "OK автоматические обновления безопасности включены"
    else echo "FAIL не удалось установить unattended-upgrades"; fi
  fi
  if [ "$DO_FAIL2BAN" = 1 ]; then
    if apt-get install -y fail2ban >/dev/null 2>&1; then
      mkdir -p /etc/fail2ban/jail.d
      printf '[sshd]\nenabled = true\nport = %s\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' "$SSH_PORT" > /etc/fail2ban/jail.d/awg.local
      systemctl enable --now fail2ban >/dev/null 2>&1 && systemctl restart fail2ban && echo "OK fail2ban включён (SSH-порт $SSH_PORT: 5 попыток за 10 минут → бан на час)" || echo "FAIL fail2ban не запустился"
    else echo "FAIL не удалось установить fail2ban"; fi
  fi
  if command -v ufw >/dev/null && [ "$(ufw status 2>/dev/null | head -n1 | awk '{print $2}')" = active ]; then
    ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1; ufw allow "$AWG_PORT/udp" >/dev/null 2>&1; echo "OK ufw активен: разрешены $SSH_PORT/tcp и $AWG_PORT/udp"
  fi
  if [ "$DO_SSH_KEYS_ONLY" = 1 ]; then
    if [ "$(keys_count)" -lt 1 ]; then echo "FAIL нет ни одного ключа в /root/.ssh/authorized_keys: вход по паролю не отключаю"
    elif ! grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config.d' /etc/ssh/sshd_config; then echo "FAIL в sshd_config нет Include для sshd_config.d: отключение пароля вручную (PasswordAuthentication no)"
    else
      mkdir -p /etc/ssh/sshd_config.d
      printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nKbdInteractiveAuthentication no\n' > "$DROP"
      if sshd -t 2>/dev/null && [ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')" = no ]; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
        echo "OK вход по паролю отключён (файл $DROP). Откат: rm $DROP && systemctl reload ssh"
      else rm -f "$DROP"; echo "FAIL конфигурация sshd не прошла проверку или значение не применилось: изменений нет"; fi
    fi
  fi
}
case "$MODE" in apply) apply;; *) report;; esac
