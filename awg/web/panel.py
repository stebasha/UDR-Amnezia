#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""awg-web — веб-панель управления AmneziaWG на UniFi Dream Router.

Только стандартная библиотека Python (3.7+): работает на роутере без pip и без интернета.

    panel.py serve                 запустить панель (служба awg-web)
    panel.py passwd ИМЯ            создать пользователя или сменить пароль (спросит дважды; --stdin — из потока)
    panel.py users                 список пользователей
    panel.py deluser ИМЯ           удалить пользователя
    panel.py totp-off ИМЯ          выключить второй фактор (если потерян телефон)
    panel.py cert                  создать самоподписанный сертификат HTTPS
    panel.py check                 проверить настройки и выйти

Безопасность: слушает только адрес LAN роутера (WEB_BIND), принимает запросы только из частных сетей (WEB_ALLOW),
HTTPS с самоподписанным сертификатом, пароли — PBKDF2-SHA256, сессии в памяти (HttpOnly, SameSite=Strict),
защита от CSRF (заголовок X-CSRF + проверка Origin), ограничение попыток входа, журнал действий, команды
выполняются только из списка разрешённых с проверкой параметров, ключи из конфигов в браузер не отдаются.
"""
import base64
import collections
import getpass
import hashlib
import hmac
import html
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import zlib

VERSION = "1.4.3"
DD = os.environ.get("DD", "/data/awg")
WEBD = os.environ.get("AWG_WEBD", os.path.join(DD, "web"))
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
SYSD = os.environ.get("SYSD", "/etc/systemd/system")
RUN = os.environ.get("AWG_RUN", "/run")
STATEF = os.environ.get("STATEF", os.path.join(RUN, "awg-state"))
FORCEF = os.environ.get("FORCEF", os.path.join(RUN, "awg-force"))
USERS_F = os.path.join(WEBD, "users.json")
CONF_F = os.path.join(WEBD, "web.conf")
LABELS_F = os.path.join(WEBD, "labels.json")
AUDIT_F = os.path.join(WEBD, "audit.log")
HIST_F = os.path.join(WEBD, "history.json")
CERT_F = os.path.join(WEBD, "cert.pem")
KEY_F = os.path.join(WEBD, "key.pem")
SIM_F = "/tmp/awg-sim-down"
SYSNET = os.environ.get("AWG_SYSNET", "/sys/class/net")

SERVICES = ["awg-failover", "awg-subnets", "awg-self", "awg-guard", "awg-notify", "awg-bot", "awg-metrics", "awg-ha"]
SERVICE_INFO = {
    "awg-failover": "Сторож: маршрут в туннель, переключение каналов, kill switch",
    "awg-subnets": "Клиенты VPN-сервера роутера через туннель",
    "awg-self": "Трафик самого роутера и unifi.ui.com через туннель, домены для dnsmasq",
    "awg-guard": "Защита от утечек, домены через туннель и исключения",
    "awg-notify": "Уведомления в Telegram",
    "awg-bot": "Команды Telegram-бота",
    "awg-metrics": "Метрики Prometheus",
    "awg-ha": "Home Assistant: состояние и управление через MQTT",
}
LOCK = threading.Lock()          # запись awg.env, служб, конфигов
ANSI = re.compile(r"\x1b\[[0-9;]*m")
NAME_RE = re.compile(r"^awg[a-z0-9]{1,10}$")
USER_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")


# ======================================================================= утилиты
def now():
    return int(time.time())


def read_file(p, default=""):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def write_secure(p, text, mode=0o600):
    """Записать файл атомарно (через .tmp и rename) с правами mode."""
    d = os.path.dirname(p)
    os.makedirs(d, exist_ok=True)
    tmp = p + ".tmp%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, p)


def run(cmd, timeout=60, env=None, inp=None):
    """Выполнить команду (список аргументов, без shell). → (код, вывод без цветов)."""
    e = dict(os.environ)
    e.update({"NO_COLOR": "1", "LC_ALL": "C.UTF-8", "DD": DD})
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, env=e,
                           input=inp.encode() if isinstance(inp, str) else inp)
        return p.returncode, ANSI.sub("", p.stdout.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        return 124, "превышено время ожидания (%d с)" % timeout
    except OSError as ex:
        return 127, str(ex)


def parse_env_text(text):
    res = {}
    for line in text.splitlines():
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        res[m.group(1)] = v
    return res


def env():
    return parse_env_text(read_file(os.path.join(DD, "awg.env")))


def env_set(updates):
    """Обновить ключи awg.env на месте, остальные строки не трогать."""
    p = os.path.join(DD, "awg.env")
    lines = read_file(p).splitlines()
    done = set()
    out = []
    for line in lines:
        m = re.match(r"^([A-Z_][A-Z0-9_]*)=", line)
        if m and m.group(1) in updates:
            k = m.group(1)
            out.append(fmt_env(k, updates[k]))
            done.add(k)
        else:
            out.append(line)
    for k, v in updates.items():
        if k not in done:
            out.append(fmt_env(k, v))
    write_secure(p, "\n".join(out) + "\n")


def fmt_env(k, v):
    v = str(v)
    if v == "" or re.search(r"[\s]", v):
        return '%s="%s"' % (k, v)
    return "%s=%s" % (k, v)


def tunnels(e=None):
    e = e or env()
    t = [e.get("MAIN") or "awgmain"]
    if e.get("BACKUP"):
        t.append(e["BACKUP"])
    t += [x for x in e.get("TUNNELS_EXTRA", "").split() if x]
    return t


def conf_path(t, e=None):
    e = e or env()
    if t == (e.get("MAIN") or "awgmain"):
        return os.path.join(DD, "main.conf")
    if t == e.get("BACKUP"):
        b = os.path.join(DD, "backup.conf")
        c = os.path.join(DD, "client.conf")
        return b if os.path.exists(b) or not os.path.exists(c) else c
    return os.path.join(DD, t + ".conf")


def conf_get(text, key):
    for line in text.splitlines():
        if "=" in line and line.split("=", 1)[0].strip().lower() == key.lower():
            return line.split("=", 1)[1].strip()
    return ""


def proto_of(text):
    keys = {line.split("=", 1)[0].strip().lower() for line in text.splitlines() if "=" in line}
    if keys & {"headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "randomtrailers", "disablecookies"}:
        return "AWG 3.x"
    if keys & {"s3", "s4", "i1", "i2"}:
        return "AWG 2.0"
    if keys & {"jc", "s1", "h1"}:
        return "AWG 1.x"
    return "WireGuard"


SECRET_KEYS = ("privatekey", "presharedkey", "headerprotectionkey")
MASK = "<скрыто>"


def mask_conf(text):
    out = []
    for line in text.splitlines():
        k = line.split("=", 1)[0].strip().lower() if "=" in line else ""
        out.append("%s = %s" % (line.split("=", 1)[0].strip(), MASK) if k in SECRET_KEYS else line)
    return "\n".join(out) + "\n"


def unmask_conf(new, old):
    """Строки «Ключ = <скрыто>» берут значение из старого конфига (по порядку появления ключа)."""
    olds = collections.defaultdict(list)
    for line in old.splitlines():
        if "=" in line:
            olds[line.split("=", 1)[0].strip().lower()].append(line.split("=", 1)[1].strip())
    used = collections.Counter()
    out = []
    for line in new.replace("\r", "").splitlines():
        if "=" in line and line.split("=", 1)[1].strip() == MASK:
            k = line.split("=", 1)[0].strip()
            lst = olds.get(k.lower(), [])
            if used[k.lower()] >= len(lst):
                raise ValueError("для «%s» нет прежнего значения: введите ключ полностью" % k)
            out.append("%s = %s" % (k, lst[used[k.lower()]]))
            used[k.lower()] += 1
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def check_conf(text):
    errs = []
    if not re.search(r"(?im)^\s*\[Interface\]", text):
        errs.append("нет секции [Interface]")
    if not re.search(r"(?im)^\s*\[Peer\]", text):
        errs.append("нет секции [Peer]")
    for k, what in (("PrivateKey", "PrivateKey"), ("PublicKey", "PublicKey (ключ сервера)"), ("Endpoint", "Endpoint")):
        if not conf_get(text, k):
            errs.append("нет строки " + what)
    addr = conf_get(text, "Address")
    if not any("." in a for a in addr.split(",")):
        errs.append("нет IPv4-адреса в строке Address")
    if re.search(r"(?im)^\s*(PreUp|PostUp|PreDown|PostDown)\s*=", text):
        errs.append("строки PreUp/PostUp/PreDown/PostDown не допускаются (команды не выполняются)")
    if len(text) > 16384:
        errs.append("слишком большой файл")
    return errs


def hs_age(t):
    rc, out = run([os.path.join(DD, "awg"), "show", t, "latest-handshakes"], timeout=5)
    try:
        ts = int(out.split()[1])
    except (IndexError, ValueError):
        return -1
    return -1 if ts == 0 else max(0, now() - ts)


def awg_show(t, what):
    rc, out = run([os.path.join(DD, "awg"), "show", t, what], timeout=5)
    return out.strip() if rc == 0 else ""


def sysnet(t, k):
    try:
        return int(read_file("%s/%s/statistics/%s" % (SYSNET, t, k), "0").strip() or 0)
    except ValueError:
        return 0


def link_exists(t):
    return run(["ip", "link", "show", t], timeout=5)[0] == 0


def state():
    return parse_env_text(read_file(STATEF))


def svc_active(u):
    return run(["systemctl", "is-active", "--quiet", u], timeout=5)[0] == 0


def svc_installed(u):
    return os.path.exists(os.path.join(SYSD, u + ".service"))


def pbr_table_routes(table):
    if not table:
        return ""
    return run(["ip", "-4", "route", "show", "table", table], timeout=5)[1]


def wan_if(e):
    if e.get("WANIF"):
        return e["WANIF"]
    out = run(["ip", "-4", "route", "show", "table", "all"], timeout=5)[1]
    for line in out.splitlines():
        p = line.split()
        if p and p[0] == "default" and "dev" in p:
            d = p[p.index("dev") + 1]
            if not re.match(r"^(awg|wg|lo|wgclt)", d):
                return d
    return ""


def if_ipv4(dev):
    out = run(["ip", "-4", "-o", "addr", "show", "dev", dev], timeout=5)[1]
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else ""


def audit(user, ip, action, detail=""):
    line = "%s %s %s %s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), ip, user or "-", action,
                                  json.dumps(detail, ensure_ascii=False) if detail else "")
    try:
        os.makedirs(WEBD, exist_ok=True)
        with open(AUDIT_F, "a", encoding="utf-8") as f:
            f.write(line)
        os.chmod(AUDIT_F, 0o600)
        if os.path.getsize(AUDIT_F) > 512 * 1024:
            lines = read_file(AUDIT_F).splitlines()[-2000:]
            write_secure(AUDIT_F, "\n".join(lines) + "\n")
    except OSError:
        pass


def labels():
    try:
        return json.loads(read_file(LABELS_F, "{}"))
    except ValueError:
        return {}


# ======================================================================= проверка ввода
def v_int(lo, hi, allow_empty=False):
    def f(v):
        v = str(v).strip()
        if allow_empty and v == "":
            return ""
        if not re.match(r"^\d{1,6}$", v) or not lo <= int(v) <= hi:
            raise ValueError("число от %d до %d" % (lo, hi))
        return v
    return f


def v_choice(*opts):
    def f(v):
        if v not in opts:
            raise ValueError("одно из: " + ", ".join(opts))
        return v
    return f


def is_ipv4(s):
    try:
        return isinstance(ipaddress.ip_address(s), ipaddress.IPv4Address) and re.match(r"^\d+\.\d+\.\d+\.\d+$", s)
    except ValueError:
        return False


def v_ipv4(v):
    v = str(v).strip()
    if not is_ipv4(v):
        raise ValueError("нужен IPv4-адрес")
    return v


def norm_subnet(x, lo=8, hi=30):
    if not re.match(r"^\d+\.\d+\.\d+\.\d+/\d{1,2}$", x):
        raise ValueError("«%s» — не подсеть вида 192.168.3.0/24" % x)
    n = ipaddress.ip_network(x, strict=False)
    if not lo <= n.prefixlen <= hi:
        raise ValueError("«%s»: маска от /%d до /%d" % (x, lo, hi))
    return str(n)


def v_subnets(v):
    out = []
    for x in str(v).split():
        n = norm_subnet(x)
        if n not in out:
            out.append(n)
    return " ".join(out)


def v_hosts(v):
    out = []
    for x in str(v).split():
        n = norm_subnet(x) if "/" in x else v_ipv4(x)
        if n not in out:
            out.append(n)
    return " ".join(out)


DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$")


def v_domains(v):
    out = []
    for x in str(v).replace(",", " ").split():
        x = x.strip().lower().rstrip(".")
        if x.startswith("http://") or x.startswith("https://"):
            x = urllib.parse.urlparse(x).hostname or ""
        if not DOMAIN_RE.match(x):
            raise ValueError("«%s» — не домен" % x)
        if x not in out:
            out.append(x)
    return " ".join(out)


SETTINGS = {
    # ключ: (проверка, службы для перезапуска, описание)
    "RECOVER_SEC": (v_int(30, 86400), ["awg-failover"], "Возврат на приоритетный канал после, с"),
    "QUALITY": (v_choice("yes", "no"), ["awg-failover"], "Переключение по качеству"),
    "QUALITY_LOSS": (v_int(5, 100), ["awg-failover"], "Порог потерь, %"),
    "QUALITY_RTT": (v_int(0, 5000), ["awg-failover"], "Порог задержки, мс (0 — не учитывать)"),
    "MIN_DWELL": (v_int(0, 3600), ["awg-failover"], "Не переключаться по качеству после смены, с"),
    "EXTRA_SUBNETS": (v_subnets, ["awg-subnets", "awg-guard"], "Подсети VPN-сервера роутера"),
    "TUN_DOMAINS": (v_domains, ["awg-self", "awg-guard"], "Домены через туннель"),
    "TUN_CLIENTS": (v_hosts, ["awg-guard"], "Для каких клиентов (пусто — вся LAN)"),
    "DIRECT_DOMAINS": (v_domains, ["awg-self", "awg-guard"], "Домены напрямую (исключения)"),
    "DIRECT_SUBNETS": (v_subnets, ["awg-guard"], "Подсети напрямую (исключения)"),
    "LEAK_GUARD": (v_choice("yes", "no"), ["awg-guard"], "Защита от утечек"),
    "LEAK_V6": (v_choice("block", "off"), ["awg-guard"], "Блокировать IPv6 под PBR"),
    "UI_FIX": (v_choice("yes", "no"), ["awg-self"], "unifi.ui.com через туннель"),
    "UI_DOMAINS": (v_domains, ["awg-self"], "Домены UniFi"),
    "UI_DNS": (v_ipv4, ["awg-self"], "DNS для доменов UniFi"),
    "DNS_ALL_TUNNEL": (v_choice("yes", "no"), ["awg-self"], "Весь DNS роутера через туннель"),
    "METRICS_PORT": (v_int(1024, 65535, True), ["awg-metrics"], "Порт метрик Prometheus"),
}
DEFAULTS = {"RECOVER_SEC": "600", "QUALITY": "yes", "QUALITY_LOSS": "40", "QUALITY_RTT": "0", "MIN_DWELL": "120",
            "LEAK_GUARD": "no", "LEAK_V6": "block", "UI_FIX": "no", "UI_DOMAINS": "ui.com", "UI_DNS": "9.9.9.9",
            "DNS_ALL_TUNNEL": "no"}


# ======================================================================= службы
def units_list():
    return [x for x in read_file(os.path.join(DD, ".units")).split() if x]


def unit_mark(u, on):
    lst = units_list()
    if on and u not in lst:
        lst.append(u)
    if not on and u in lst:
        lst.remove(u)
    write_secure(os.path.join(DD, ".units"), "".join(x + "\n" for x in lst), 0o644)


def unit_on(u):
    src = os.path.join(DD, u + ".service")
    if not os.path.exists(src):
        raise ValueError("нет файла %s" % src)
    shutil.copyfile(src, os.path.join(SYSD, u + ".service"))
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", u])
    rc, out = run(["systemctl", "restart", u], timeout=30)
    unit_mark(u, True)
    return rc, out


def unit_off(u):
    run(["systemctl", "disable", "--now", u], timeout=30)
    try:
        os.remove(os.path.join(SYSD, u + ".service"))
    except OSError:
        pass
    run(["systemctl", "daemon-reload"])
    unit_mark(u, False)
    rm = {"awg-guard": "guard.sh", "awg-self": "self.sh", "awg-subnets": "subnets.sh"}.get(u)
    if rm and os.path.exists(os.path.join(DD, rm)):
        run([os.path.join(DD, rm), "remove"], timeout=60)


def apply_services(services, e):
    """После смены настроек: включить нужные службы, перезапустить затронутые."""
    msgs = []
    want_on = {
        "awg-subnets": bool(e.get("EXTRA_SUBNETS", "").strip()),
        "awg-self": e.get("UI_FIX") == "yes" or bool((e.get("TUN_DOMAINS", "") + e.get("DIRECT_DOMAINS", "")).strip())
                    or e.get("DNS_ALL_TUNNEL") == "yes",
        "awg-guard": e.get("LEAK_GUARD") == "yes" or bool((e.get("TUN_DOMAINS", "") + e.get("DIRECT_DOMAINS", "")
                                                          + e.get("DIRECT_SUBNETS", "")).strip()),
        "awg-metrics": svc_installed("awg-metrics") or bool(e.get("METRICS_PORT")),
    }
    for u in services:
        on = want_on.get(u, True)
        if on:
            if svc_installed(u):
                rc, out = run(["systemctl", "restart", u], timeout=30)
            else:
                rc, out = unit_on(u)
            msgs.append("%s: %s" % (u, "перезапущена" if rc == 0 else "ошибка: " + out.strip()[:200]))
        elif svc_installed(u):
            unit_off(u)
            msgs.append("%s: выключена (нечего делать)" % u)
    return msgs


# ======================================================================= аутентификация
def load_users():
    try:
        return json.loads(read_file(USERS_F, "{}"))
    except ValueError:
        return {}


def save_users(u):
    write_secure(USERS_F, json.dumps(u, ensure_ascii=False, indent=1))


def hash_pw(pw, salt=None, it=200000):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt), it).hex()
    return {"salt": salt, "iter": it, "hash": h}


def check_pw(rec, pw):
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(rec["salt"]), int(rec["iter"])).hex()
    return hmac.compare_digest(h, rec["hash"])


def pw_problem(pw):
    if len(pw) < 10:
        return "пароль короче 10 символов"
    if len(set(pw)) < 5:
        return "в пароле слишком мало разных символов"
    return ""


def totp_code(secret_b32, t=None, step=30):
    key = base64.b32decode(secret_b32.upper() + "=" * (-len(secret_b32) % 8))
    c = int((t or time.time()) // step)
    d = hmac.new(key, struct.pack(">Q", c), hashlib.sha1).digest()
    o = d[-1] & 15
    return "%06d" % ((struct.unpack(">I", d[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def totp_ok(secret, code):
    code = re.sub(r"\s", "", str(code or ""))
    if not re.match(r"^\d{6}$", code):
        return False
    t = time.time()
    return any(hmac.compare_digest(totp_code(secret, t + k * 30), code) for k in (-1, 0, 1))


class Sessions:
    """Сеансы панели. Хранятся в файле (600), чтобы перезапуск или обновление панели не выкидывали всех.
    В файле только SHA-256 от токена: утечка файла не даёт войти; сам токен живёт лишь в куке браузера."""
    IDLE = 2 * 3600
    ABS = 12 * 3600
    SAVE_EVERY = 60          # отметку «последняя активность» сбрасываем на диск не чаще раза в минуту

    def __init__(self, path=None):
        self.s = {}          # sha256(токен) → сведения о сеансе
        self.lock = threading.Lock()
        self.path = path
        self.saved = 0
        self.load()

    @staticmethod
    def key(tok):
        return hashlib.sha256((tok or "").encode()).hexdigest()

    def alive(self, x, t=None):
        t = t or now()
        return t - x["seen"] <= self.IDLE and t - x["born"] <= self.ABS

    def load(self):
        if not self.path:
            return
        try:
            data = json.loads(read_file(self.path) or "{}")
        except ValueError:
            data = {}
        users = load_users()
        with self.lock:
            self.s = {k: v for k, v in (data.get("sessions") or {}).items()
                      if isinstance(v, dict) and re.match(r"^[0-9a-f]{64}$", k) and v.get("user") in users and self.alive(v)}

    def save(self, force=True):
        """Вызывать под self.lock."""
        if not self.path or (not force and now() - self.saved < self.SAVE_EVERY):
            return
        try:
            write_secure(self.path, json.dumps({"format": 1, "sessions": self.s}), 0o600)
            self.saved = now()
        except OSError as ex:
            sys.stderr.write("сеансы не сохранены: %r\n" % ex)

    def new(self, user, ip, ua=""):
        tok = secrets.token_urlsafe(32)
        with self.lock:
            self.s = {k: v for k, v in self.s.items() if self.alive(v)}
            self.s[self.key(tok)] = {"user": user, "csrf": secrets.token_urlsafe(24), "ip": ip, "born": now(), "seen": now(), "ua": ua[:160]}
            self.save()
        return tok

    def get(self, tok):
        k = self.key(tok)
        with self.lock:
            x = self.s.get(k) if tok else None
            if not x:
                return None
            if not self.alive(x):
                del self.s[k]
                self.save()
                return None
            x["seen"] = now()
            self.save(force=False)
            return x

    def drop(self, tok=None, user=None, keep=None, sid_=None):
        """tok — один сеанс; user — все сеансы пользователя; sid_ — по короткому id; keep — кроме этого токена."""
        kt = self.key(tok) if tok else None
        kk = self.key(keep) if keep else None
        with self.lock:
            for k in list(self.s):
                if k == kt or (user and self.s[k]["user"] == user) or (sid_ and k[:12] == sid_ and k != kk) \
                        or (sid_ == "others" and k != kk):
                    del self.s[k]
            self.save()

    def listing(self, cur):
        kc = self.key(cur) if cur else None
        with self.lock:
            return [{"id": k[:12], "user": v["user"], "ip": v["ip"], "born": v["born"], "seen": v["seen"], "ua": v.get("ua", ""), "me": k == kc}
                    for k, v in self.s.items() if self.alive(v)]


SESS = Sessions(os.path.join(WEBD, "sessions.json"))


class Tokens:
    """Долгоживущие токены API (#6): для Home Assistant, скриптов, мониторинга.
    Роли: read — только GET; admin — всё, кроме учётных данных и опасных действий (см. TOKEN_DENY).
    Хранится только SHA-256 токена (web/tokens.json, 600); сам токен показывается один раз при создании."""
    MAX = 20
    PREFIX = "awg_"

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.t = {}
        self.saved = 0
        try:
            self.t = {k: v for k, v in (json.loads(read_file(path) or "{}").get("tokens") or {}).items()
                      if re.match(r"^[0-9a-f]{12}$", k) and isinstance(v, dict) and re.match(r"^[0-9a-f]{64}$", v.get("hash", ""))}
        except ValueError:
            self.t = {}

    def save(self):
        write_secure(self.path, json.dumps({"format": 1, "tokens": self.t}, ensure_ascii=False), 0o600)
        self.saved = now()

    def create(self, name, role, days, user):
        tok = self.PREFIX + secrets.token_urlsafe(32)
        tid = secrets.token_hex(6)
        with self.lock:
            if len(self.t) >= self.MAX:
                raise ValueError("не больше %d токенов: отзовите ненужные" % self.MAX)
            if any(v["name"] == name for v in self.t.values()):
                raise ValueError("токен с таким названием уже есть")
            self.t[tid] = {"name": name, "role": role, "hash": hashlib.sha256(tok.encode()).hexdigest(), "created": now(),
                           "expires": now() + days * 86400 if days else 0, "last_used": 0, "last_ip": "", "user": user}
            self.save()
        return tid, tok

    def check(self, tok, ip):
        if not tok.startswith(self.PREFIX) or len(tok) > 100:
            return None
        hh = hashlib.sha256(tok.encode()).hexdigest()
        with self.lock:
            for tid, v in self.t.items():
                if hmac.compare_digest(v["hash"], hh):
                    if v["expires"] and now() > v["expires"]:
                        return None
                    v["last_used"], v["last_ip"] = now(), ip
                    if now() - self.saved > 60:
                        self.save()
                    return dict(v, id=tid)
        return None

    def listing(self):
        with self.lock:
            return [dict({k: v[k] for k in ("name", "role", "created", "expires", "last_used", "last_ip", "user")}, id=tid,
                         expired=bool(v["expires"] and now() > v["expires"])) for tid, v in self.t.items()]

    def revoke(self, tid):
        with self.lock:
            if self.t.pop(tid, None) is None:
                raise ApiError(404, "нет такого токена")
            self.save()


TOKENS = Tokens(os.path.join(WEBD, "tokens.json"))
# только для входа по паролю: учётные данные, сеансы, токены, ключи, перезагрузка, настройки самой панели
TOKEN_DENY = {"/api/tokens", "/api/token/create", "/api/token/revoke", "/api/passwd", "/api/user/delete", "/api/users",
              "/api/totp/begin", "/api/totp/enable", "/api/totp/disable", "/api/sessions", "/api/session/revoke",
              "/api/tunnel/export", "/api/system/reboot", "/api/web", "/api/update/run", "/api/update/channel", "/api/settings/import",
              "/api/backup/file", "/api/backup/create", "/api/backup/delete", "/api/backup/verify", "/api/telegram", "/api/ha"}


class Throttle:
    """5 неудачных входов за 10 минут с одного адреса → блокировка на 15 минут."""

    def __init__(self):
        self.fails = collections.defaultdict(collections.deque)
        self.block = {}
        self.lock = threading.Lock()

    def blocked(self, ip):
        with self.lock:
            return self.block.get(ip, 0) > now()

    def fail(self, ip):
        with self.lock:
            q = self.fails[ip]
            q.append(now())
            while q and q[0] < now() - 600:
                q.popleft()
            if len(q) >= 5:
                self.block[ip] = now() + 900
                q.clear()
                return True
        return False

    def ok(self, ip):
        with self.lock:
            self.fails.pop(ip, None)


THR = Throttle()


# ======================================================================= здоровье роутера
PROC = os.environ.get("AWG_PROC", "/proc")
SYSFS = os.environ.get("AWG_SYSFS", "/sys")


def cpu_times():
    try:
        p = read_file(os.path.join(PROC, "stat")).splitlines()[0].split()[1:]
        v = [int(x) for x in p[:8]]
        idle = v[3] + v[4]
        return sum(v), idle
    except (IndexError, ValueError):
        return 0, 0


def cpu_pct_now(delay=0.4):
    a = cpu_times()
    time.sleep(delay)
    b = cpu_times()
    tot = b[0] - a[0]
    return round(100.0 * (tot - (b[1] - a[1])) / tot, 1) if tot > 0 else 0.0


def temps():
    out = []
    base = os.path.join(SYSFS, "class", "thermal")
    try:
        for z in sorted(os.listdir(base)):
            if not z.startswith("thermal_zone"):
                continue
            v = read_file(os.path.join(base, z, "temp")).strip()
            if v.lstrip("-").isdigit():
                c = int(v) / 1000.0 if abs(int(v)) > 1000 else float(v)
                if -40 < c < 150:
                    out.append({"name": read_file(os.path.join(base, z, "type")).strip() or z, "c": round(c, 1)})
    except OSError:
        pass
    hb = os.path.join(SYSFS, "class", "hwmon")
    try:
        for hw in sorted(os.listdir(hb)):
            nm = read_file(os.path.join(hb, hw, "name")).strip() or hw
            for f in sorted(os.listdir(os.path.join(hb, hw))):
                if f.startswith("temp") and f.endswith("_input"):
                    v = read_file(os.path.join(hb, hw, f)).strip()
                    if v.lstrip("-").isdigit() and -40000 < int(v) < 150000:
                        lab = read_file(os.path.join(hb, hw, f.replace("_input", "_label"))).strip()
                        out.append({"name": "%s %s" % (nm, lab or f[:-6]), "c": round(int(v) / 1000.0, 1)})
    except OSError:
        pass
    return out


def fs_usage(path):
    try:
        s = os.statvfs(path)
        tot = s.f_blocks * s.f_frsize
        free = s.f_bavail * s.f_frsize
        if tot <= 0:
            return None
        return {"path": path, "total_mb": tot // 1048576, "free_mb": free // 1048576, "used_pct": round(100.0 * (tot - free) / tot, 1)}
    except OSError:
        return None


def top_procs(n=8):
    out = []
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return [], 0
    for p in pids:
        st = read_file(os.path.join(PROC, p, "status"))
        m = re.search(r"^VmRSS:\s+(\d+)", st, re.M)
        nm = re.search(r"^Name:\s+(.+)$", st, re.M)
        if m and nm:
            cmd = read_file(os.path.join(PROC, p, "cmdline")).replace("\0", " ").strip()
            out.append({"pid": int(p), "name": nm.group(1).strip(), "rss_mb": round(int(m.group(1)) / 1024.0, 1), "cmd": cmd[:120]})
    out.sort(key=lambda x: -x["rss_mb"])
    return out[:n], len(pids)


def read_int(p, default=-1):
    v = read_file(p).strip()
    return int(v) if v.isdigit() else default


def kernel_events():
    """OOM и ошибки ввода-вывода за сутки из журнала ядра (если доступен)."""
    rc, out = run(["journalctl", "-k", "--since", "-24h", "-q", "--no-pager", "-o", "cat"], timeout=10)
    if rc != 0:
        return {"oom": -1, "io": -1, "lines": []}
    oom = [l for l in out.splitlines() if re.search(r"Out of memory|oom-kill|Killed process", l)]
    io = [l for l in out.splitlines() if re.search(r"I/O error|EXT4-fs error|UBIFS error|squashfs error|Buffer I/O", l)]
    return {"oom": len(oom), "io": len(io), "lines": (oom + io)[-6:]}


def system_health(cpu=None, hist=None):
    """Показатели железа и проверки с понятным текстом: что не так и что делать."""
    mi = {}
    for line in read_file(os.path.join(PROC, "meminfo")).splitlines():
        p = line.split()
        if len(p) >= 2 and p[1].isdigit():
            mi[p[0].rstrip(":")] = int(p[1])
    tot, av = mi.get("MemTotal", 0), mi.get("MemAvailable", 0)
    mem = {"total_mb": tot // 1024, "avail_mb": av // 1024, "used_pct": round(100.0 * (tot - av) / tot, 1) if tot else 0,
           "swap_total_mb": mi.get("SwapTotal", 0) // 1024, "swap_used_mb": (mi.get("SwapTotal", 0) - mi.get("SwapFree", 0)) // 1024}
    load = [float(x) for x in read_file(os.path.join(PROC, "loadavg"), "0 0 0").split()[:3]]
    cores = len(re.findall(r"^processor\s*:", read_file(os.path.join(PROC, "cpuinfo")), re.M)) or (os.cpu_count() or 1)
    if cpu is None:
        cpu = cpu_pct_now()
    try:
        up = int(float(read_file(os.path.join(PROC, "uptime"), "0").split()[0]))
    except (ValueError, IndexError):
        up = 0
    ts = temps()
    tmax = max([t["c"] for t in ts] or [0])
    ct_n = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_count"))
    ct_m = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_max"))
    fds = read_file(os.path.join(PROC, "sys/fs/file-nr")).split()
    disks = [d for d in (fs_usage(DD), fs_usage("/"), fs_usage("/tmp"), fs_usage("/var/log")) if d]
    seen, dl = set(), []
    for d in disks:
        k = (d["total_mb"], d["free_mb"])
        if k not in seen:
            seen.add(k)
            dl.append(d)
    procs, nproc = top_procs()
    ke = kernel_events()
    checks = []

    def ck(key, level, text, advice=""):
        checks.append({"key": key, "level": level, "text": text, "advice": advice})
    # диск
    dd = fs_usage(DD)
    if dd:
        if dd["free_mb"] < 200:
            ck("disk", "crit", "На /data осталось %d МБ" % dd["free_mb"], "удалите старые копии: Настройки → Резервные копии; журналы: journalctl --vacuum-size=50M")
        elif dd["free_mb"] < 500 or dd["used_pct"] > 90:
            ck("disk", "warn", "На /data мало места: %d МБ (%s%% занято)" % (dd["free_mb"], dd["used_pct"]), "проверьте старые резервные копии и /data/unifi (бэкапы UniFi)")
        else:
            ck("disk", "ok", "/data: свободно %d МБ" % dd["free_mb"])
    for d in dl:
        if d["path"] in ("/tmp", "/var/log") and d["used_pct"] > 85:
            ck("fs" + d["path"], "warn", "%s заполнен на %s%% (это оперативная память)" % (d["path"], d["used_pct"]), "найти крупные файлы: du -sh %s/* | sort -h | tail" % d["path"])
        if d["path"] == "/" and d["used_pct"] > 95:
            ck("fs" + d["path"], "warn", "Системный раздел заполнен на %s%%" % d["used_pct"], "это раздел UniFi OS: обычно освобождается обновлением прошивки")
    # прогноз заполнения /data
    pts = [p for p in (hist or []) if p.get("data_free")]
    if dd and len(pts) >= 120:
        a, b = pts[0], pts[-1]
        dt = (b["t"] - a["t"]) / 86400.0
        drop = a["data_free"] - b["data_free"]
        if dt > 0.05 and drop > 5:
            days = dd["free_mb"] / (drop / dt)
            if days < 14:
                ck("trend", "warn", "/data заполняется: ~%d МБ в сутки, места хватит примерно на %d дн." % (drop / dt, days), "посмотрите, что растёт: du -sh /data/* | sort -h | tail")
    # память
    if mem["used_pct"] > 95:
        ck("mem", "crit", "Память занята на %s%% (свободно %d МБ)" % (mem["used_pct"], mem["avail_mb"]), "возможны падения служб: перезагрузите роутер в удобное время, проверьте процессы ниже")
    elif mem["used_pct"] > 88:
        ck("mem", "warn", "Память занята на %s%%" % mem["used_pct"], "следите за ростом; крупные процессы — в таблице ниже")
    else:
        ck("mem", "ok", "Память: занято %s%%, свободно %d МБ" % (mem["used_pct"], mem["avail_mb"]))
    # процессор
    recent = [p["cpu"] for p in (hist or [])[-5:] if p.get("cpu") is not None]
    avg5 = sum(recent) / len(recent) if recent else cpu
    if avg5 > 90:
        ck("cpu", "warn", "Процессор загружен на %d%% последние минуты" % avg5, "посмотрите нагрузку: top -o %CPU (IDS/IPS и DPI UniFi сильно грузят процессор)")
    elif load[0] > cores * 2:
        ck("cpu", "warn", "Высокая средняя нагрузка: %.2f при %d ядрах" % (load[0], cores), "кратковременно — нормально; долго — смотрите top")
    else:
        ck("cpu", "ok", "Процессор: %d%%, нагрузка %.2f (ядер: %d)" % (cpu, load[0], cores))
    # температура
    if ts:
        if tmax >= 95:
            ck("temp", "crit", "Температура %d°C" % tmax, "проверьте вентиляцию: роутер может перегреться и перезагрузиться")
        elif tmax >= 85:
            ck("temp", "warn", "Температура высокая: %d°C" % tmax, "уберите от источников тепла, обеспечьте приток воздуха")
        else:
            ck("temp", "ok", "Температура: %d°C" % tmax)
    # conntrack
    if ct_n >= 0 and ct_m > 0:
        pct = 100.0 * ct_n / ct_m
        if pct > 95:
            ck("ct", "crit", "Таблица соединений почти полна: %d из %d" % (ct_n, ct_m), "новые соединения будут отбрасываться: ищите устройство с тысячами соединений (страница «Клиенты»)")
        elif pct > 80:
            ck("ct", "warn", "Таблица соединений заполнена на %d%%" % pct, "проверьте устройства с большим числом соединений (торренты, сканеры)")
        else:
            ck("ct", "ok", "Соединений: %d из %d" % (ct_n, ct_m))
    # ядро
    if ke["oom"] > 0:
        ck("oom", "warn", "За сутки ядро %d раз завершало процессы из-за нехватки памяти" % ke["oom"], "журнал: journalctl -k | grep -i oom")
    if ke["io"] > 0:
        ck("io", "warn", "За сутки ошибок ввода-вывода: %d" % ke["io"], "возможен износ флеш-памяти: сделайте резервную копию")
    if up < 900:
        ck("reboot", "info", "Роутер перезагружался %d мин назад" % (up // 60))
    if time.localtime().tm_year < 2025:
        ck("clock", "crit", "Часы роутера неверны (%s)" % time.strftime("%F"), "handshake туннелей не пройдёт: проверьте NTP в UniFi")
    if len(fds) >= 3 and fds[0].isdigit() and fds[2].isdigit() and int(fds[2]) and int(fds[0]) > 0.8 * int(fds[2]):
        ck("fd", "warn", "Открытых файлов %s из %s" % (fds[0], fds[2]), "")
    level = "crit" if any(c["level"] == "crit" for c in checks) else "warn" if any(c["level"] == "warn" for c in checks) else "ok"
    return {"level": level, "checks": checks, "cpu": cpu, "cores": cores, "load": load, "mem": mem, "uptime": up,
            "temps": ts, "temp_max": tmax, "conntrack": {"count": ct_n, "max": ct_m}, "disks": dl,
            "procs": procs, "nproc": nproc, "kernel": ke, "model": read_file("/proc/device-tree/model").strip("\0\n ") or socket.gethostname(),
            "kernel_ver": os.uname().release, "time": now()}


# ======================================================================= сбор данных
class Sampler(threading.Thread):
    """Каждые 2 с: скорость по туннелям (10 минут в памяти); раз в минуту — точка истории (сутки);
    раз в час — сводка часа (30 дней, #10): средняя скорость, RTT и потери, доля минут со свежим handshake, процессор и память."""
    HOURS = 30 * 24

    def __init__(self):
        super().__init__(daemon=True)
        self.live = collections.defaultdict(lambda: collections.deque(maxlen=300))
        self.prev = {}
        self.hist = {"points": []}
        self.acc = collections.defaultdict(lambda: [0, 0, 0])
        self.lock = threading.Lock()
        self.last_save = now()
        self.cpu_prev = cpu_times()
        self.cpu = 0.0
        self.cpu_acc = [0.0, 0]
        try:
            h = json.loads(read_file(HIST_F, "{}"))
            if isinstance(h.get("points"), list):
                self.hist = h
        except ValueError:
            pass

    def run(self):
        last_min = now() // 60
        while True:
            try:
                self.tick()
                m = now() // 60
                if m != last_min:
                    last_min = m
                    self.minute()
                if now() - self.last_save > 3600:
                    self.save()
            except Exception as ex:  # сбор данных не должен ронять панель
                sys.stderr.write("sampler: %s\n" % ex)
            time.sleep(2)

    def tick(self):
        t0 = time.time()
        c = cpu_times()
        tot = c[0] - self.cpu_prev[0]
        if tot > 0:
            self.cpu = round(100.0 * (tot - (c[1] - self.cpu_prev[1])) / tot, 1)
            self.cpu_acc[0] += self.cpu
            self.cpu_acc[1] += 1
        self.cpu_prev = c
        for t in tunnels():
            rx, tx = sysnet(t, "rx_bytes"), sysnet(t, "tx_bytes")
            p = self.prev.get(t)
            self.prev[t] = (t0, rx, tx)
            if not p or rx < p[1] or tx < p[2]:
                continue
            dt = max(t0 - p[0], 0.5)
            r, w = (rx - p[1]) * 8 / dt, (tx - p[2]) * 8 / dt
            with self.lock:
                self.live[t].append((int(t0), int(r), int(w)))
                a = self.acc[t]
                a[0] += r
                a[1] += w
                a[2] += 1

    def minute(self):
        st = state()
        pt = {"t": now(), "active": st.get("ACTIVE", ""), "tun": {}}
        with self.lock:
            for t in tunnels():
                a = self.acc.pop(t, [0, 0, 0])
                n = a[2] or 1
                pt["tun"][t] = {"rx": int(a[0] / n), "tx": int(a[1] / n), "hs": hs_age(t),
                                "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, ""), "qm": st.get("QMETH_" + t, "")}
            self.hist["points"].append(pt)
            self.hist["points"] = self.hist["points"][-1440:]
            n = self.cpu_acc[1] or 1
            mi = parse_meminfo()
            ct_n = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_count"))
            ct_m = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_max"))
            ts = temps()
            sp = {"t": now(), "cpu": round(self.cpu_acc[0] / n, 1), "mem": round(100.0 * mi["used_mb"] / mi["total_mb"], 1) if mi["total_mb"] else 0,
                  "temp": max([x["c"] for x in ts] or [0]) or None, "ct": round(100.0 * ct_n / ct_m, 1) if ct_m > 0 and ct_n >= 0 else None,
                  "load": float((read_file(os.path.join(PROC, "loadavg"), "0").split() or ["0"])[0]), "data_free": disk_free_mb()}
            self.cpu_acc = [0.0, 0]
            self.hist.setdefault("sys", []).append(sp)
            self.hist["sys"] = self.hist["sys"][-1440:]
            self.roll_hours()

    def roll_hours(self):
        """Под self.lock: свести завершённые часы из минутных точек в hist["hours"] (без повторов)."""
        hours = self.hist.setdefault("hours", [])
        done = hours[-1]["t"] if hours else 0
        cur = now() // 3600 * 3600
        by = collections.OrderedDict()
        for p in self.hist["points"]:
            h = p["t"] // 3600 * 3600
            if done < h < cur:
                by.setdefault(h, {"p": [], "s": []})["p"].append(p)
        for sp in self.hist.get("sys", []):
            h = sp["t"] // 3600 * 3600
            if h in by:
                by[h]["s"].append(sp)
        for h, g in by.items():
            hours.append(hour_summary(h, g["p"], g["s"]))
        if by:
            self.hist["hours"] = hours[-self.HOURS:]
            self.last_save = 0          # сводку часа сохранить сразу

    def save(self):
        self.last_save = now()
        with self.lock:
            try:
                write_secure(HIST_F, json.dumps(self.hist, separators=(",", ":")))
            except OSError:
                pass

    def live_data(self):
        with self.lock:
            return {t: list(q) for t, q in self.live.items()}

    def history(self):
        with self.lock:
            return list(self.hist["points"])

    def sys_history(self):
        with self.lock:
            return list(self.hist.get("sys", []))

    def hours(self, since):
        with self.lock:
            return [h for h in self.hist.get("hours", []) if h["t"] >= since]


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _avg(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def hour_summary(h, pts, sps):
    """Сводка часа: по туннелю средние rx/tx (бит/с), RTT, потери, доля минут со свежим handshake (≤180 с); активный канал."""
    tun = {}
    names = sorted({t for p in pts for t in p.get("tun", {})})
    for t in names:
        xs = [p["tun"][t] for p in pts if t in p.get("tun", {})]
        tun[t] = {"rx": int(sum(x.get("rx", 0) for x in xs) / len(xs)), "tx": int(sum(x.get("tx", 0) for x in xs) / len(xs)),
                  "rtt": _avg([_num(x.get("rtt")) for x in xs]), "loss": _avg([_num(x.get("loss")) for x in xs]),
                  "up": round(100.0 * sum(1 for x in xs if 0 <= (x.get("hs") if isinstance(x.get("hs"), int) else -1) <= 180) / len(xs), 1)}
    act = collections.Counter(p.get("active", "") for p in pts).most_common(1)
    return {"t": h, "n": len(pts), "active": act[0][0] if act else "", "tun": tun,
            "sys": {"cpu": _avg([_num(x.get("cpu")) for x in sps]), "mem": _avg([_num(x.get("mem")) for x in sps]),
                    "temp": max([x["temp"] for x in sps if isinstance(x.get("temp"), (int, float))] or [0]) or None}}


SAMPLER = Sampler()


def events(n=200):
    out = []
    for line in read_file(os.path.join(DD, "events.log")).splitlines()[-n:]:
        p = line.split("|", 2)
        if len(p) == 3 and p[0].isdigit():
            out.append({"t": int(p[0]), "type": p[1], "text": p[2]})
    return out


def stats_from_events(days=7):
    ev = events(3000)
    frm = now() - days * 86400
    cnt = collections.Counter(e["type"] for e in ev if e["t"] >= frm)
    off, on, st = 0, False, 0
    main = env().get("MAIN", "awgmain")
    for e in ev:
        # «auto» канал не меняет (сторож остаётся на запасном до возврата); ручной выбор основного — это возврат
        to_main = e["type"] == "force" and e["text"].split()[-1:] == [main]
        if e["type"] in ("switch", "degrade", "force") and not to_main:
            if not on:
                on, st = True, e["t"]
        elif e["type"] in ("return", "start") or to_main:
            if on:
                off += max(0, e["t"] - max(st, frm)) if e["t"] > frm else 0
                on = False
    if on:
        off += now() - max(st, frm)
    return {"days": days, "switch": cnt["switch"], "degrade": cnt["degrade"], "force": cnt["force"],
            "return": cnt["return"], "both": cnt["both"], "start": cnt["start"],
            "off_main_sec": off, "on_main_pct": round(100 - off * 100.0 / (days * 86400), 2)}


def tunnel_info(t, e, st, active):
    cp = conf_path(t, e)
    text = read_file(cp)
    hs = hs_age(t) if link_exists(t) else -1
    ep = conf_get(text, "Endpoint")
    role = "main" if t == (e.get("MAIN") or "awgmain") else ("backup" if t == e.get("BACKUP") else "extra")
    up = link_exists(t)
    if not up:
        status = "down"
    elif hs < 0 or hs > 180:
        status = "nohs"
    elif t == active:
        status = "active"
    else:
        status = "standby"
    return {
        "name": t, "label": labels().get(t, ""), "role": role, "status": status, "exists": up,
        "handshake": hs, "endpoint": ep, "address": conf_get(text, "Address"),
        "mtu": read_file("%s/%s/mtu" % (SYSNET, t)).strip() or conf_get(text, "MTU"),
        "proto": proto_of(text), "conf": os.path.basename(cp), "conf_mode": oct(os.stat(cp).st_mode & 0o777)[2:] if os.path.exists(cp) else "",
        "rx": sysnet(t, "rx_bytes"), "tx": sysnet(t, "tx_bytes"),
        "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, ""), "dns": st.get("DNS_" + t, ""), "qm": st.get("QMETH_" + t, ""),
        "active": t == active, "forced": st.get("FORCED", "") == t,
    }


def overview():
    e = env()
    st = state()
    table = e.get("TABLE", "")
    tb = pbr_table_routes(table)
    m = re.search(r"^default dev (awg\S+)", tb, re.M)
    active = m.group(1) if m else ""
    tl = [tunnel_info(t, e, st, active) for t in tunnels(e)]
    fo = svc_active("awg-failover")
    services = {u: {"installed": svc_installed(u) or u == "awg-failover", "active": svc_active(u), "info": SERVICE_INFO[u]}
                for u in SERVICES}
    wan = wan_if(e)
    alerts = []
    if not fo:
        alerts.append(["crit", "Сторож awg-failover не работает: маршрута в туннель нет"])
    if table and not active:
        alerts.append(["crit", "В таблице PBR %s нет маршрута на туннель: устройства под PBR без интернета (утечки нет)" % table])
    if active and active != tl[0]["name"]:
        alerts.append(["warn", "Работает запасной канал %s" % active])
    if st.get("FORCED"):
        alerts.append(["warn", "Канал выбран вручную: %s" % st["FORCED"]])
    for x in tl:
        if x["status"] in ("down", "nohs") and x["name"] != active:
            alerts.append(["warn", "Туннель %s: %s" % (x["name"], "интерфейса нет" if x["status"] == "down" else "нет handshake")])
    if os.path.exists(SIM_F):
        alerts.append(["warn", "Включена имитация падения основного канала"])
    if table and "blackhole" not in tb:
        alerts.append(["crit", "В таблице PBR нет blackhole: при падении туннелей трафик может уйти мимо"])
    for u, s in services.items():
        if s["installed"] and u != "awg-failover" and not s["active"]:
            alerts.append(["warn", "Служба %s установлена, но не работает" % u])
    upd = st.get("UPDATED", "")
    if fo and upd.isdigit() and now() - int(upd) > 60:
        alerts.append(["warn", "Состояние сторожа не обновлялось %d с" % (now() - int(upd))])
    bkd = os.path.join(DD, "backups")
    bk = [f for f in (os.listdir(bkd) if os.path.isdir(bkd) else []) if BK_RE.match(f)]
    newest = max([os.stat(os.path.join(bkd, f)).st_mtime for f in bk] or [0])
    if now() - newest > 30 * 86400:
        alerts.append(["info", "Резервной копии нет или ей больше 30 дней (Настройки → Резервные копии)"])
    hl = health_cached()
    for c in hl["checks"]:
        if c["level"] in ("warn", "crit"):
            alerts.append([c["level"], "Роутер: " + c["text"] + (" — " + c["advice"] if c["advice"] else "")])
    level = "crit" if any(a[0] == "crit" for a in alerts) else ("warn" if any(a[0] == "warn" for a in alerts) else "ok")
    try:
        up = int(float(read_file("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        up = 0
    load = read_file("/proc/loadavg").split()[:3]
    mem = parse_meminfo()
    return {
        "host": socket.gethostname(), "version": read_file(os.path.join(DD, "VERSION")).strip() or VERSION, "panel": VERSION,
        "time": now(), "uptime": up, "load": load, "mem": mem, "level": level, "alerts": alerts,
        "active": active, "forced": st.get("FORCED", ""), "tunnels": tl, "services": services,
        "pbr": {"table": table, "mark": e.get("MARK", ""), "rail": e.get("RAIL_IF", ""), "routes": tb.strip().splitlines(),
                "killswitch": "blackhole" in tb, "subnets": e.get("EXTRA_SUBNETS", "")},
        "wan": {"if": wan, "ip": if_ipv4(wan) if wan else ""},
        "stats": stats_from_events(7), "events": events(15)[::-1],
        "features": {"guard": e.get("LEAK_GUARD") == "yes", "self": e.get("UI_FIX") == "yes",
                     "domains": bool(e.get("TUN_DOMAINS", "").strip()), "subnets": bool(e.get("EXTRA_SUBNETS", "").strip()),
                     "quality": e.get("QUALITY", "yes") == "yes"},
        "data_free_mb": disk_free_mb(),
        "sys": {"cpu": SAMPLER.cpu, "cores": hl["cores"], "temp": hl["temp_max"], "mem_pct": hl["mem"]["used_pct"], "level": hl["level"],
                "conntrack": hl["conntrack"]},
    }


def parse_meminfo():
    mi = {}
    for line in read_file("/proc/meminfo").splitlines():
        p = line.split()
        if len(p) >= 2:
            mi[p[0].rstrip(":")] = int(p[1])
    tot = mi.get("MemTotal", 0)
    av = mi.get("MemAvailable", 0)
    return {"total_mb": tot // 1024, "used_mb": (tot - av) // 1024}


def disk_free_mb():
    try:
        s = os.statvfs(DD)
        return s.f_bavail * s.f_frsize // (1024 * 1024)
    except OSError:
        return -1


def curl(args, timeout=10):
    return run(["curl", "-s", "-4", "-m", str(timeout)] + args, timeout=timeout + 3)


def tunnel_test(t):
    res = {"name": t, "handshake": hs_age(t), "https": [], "dns": False, "ip": "", "mtu": ""}
    targets = env().get("TARGETS", "1.1.1.1 8.8.8.8 9.9.9.9").split()
    for tg in targets:
        t0 = time.time()
        rc, out = curl(["-k", "-o", "/dev/null", "--connect-timeout", "3", "-w", "%{http_code}", "--interface", t, "https://%s/" % tg], 5)
        res["https"].append({"target": tg, "ok": out.strip() not in ("", "000"), "ms": int((time.time() - t0) * 1000)})
    rc, out = curl(["--interface", t, "-H", "accept: application/dns-json", "https://1.1.1.1/dns-query?name=example.com&type=A"], 6)
    res["dns"] = '"Status":0' in out
    for u in ("https://api.ipify.org", "https://ifconfig.me"):
        rc, out = curl(["--interface", t, u], 6)
        if is_ipv4(out.strip()):
            res["ip"] = out.strip()
            break
    mtu = read_file("%s/%s/mtu" % (SYSNET, t)).strip()
    if mtu.isdigit():
        rc, out = run(["ping", "-I", t, "-M", "do", "-c", "2", "-W", "2", "-s", str(int(mtu) - 28), "1.1.1.1"], timeout=8)
        res["mtu"] = "ok" if rc == 0 else "fail"
    res["ok"] = any(x["ok"] for x in res["https"])
    return res


# ======================================================================= фоновые задачи
class Jobs:
    def __init__(self):
        self.j = {}
        self.lock = threading.Lock()

    def start(self, kind, cmd, timeout=600, env_extra=None, after=None):
        with self.lock:
            for k, x in self.j.items():
                if x["kind"] == kind and not x["done"]:
                    return k
            jid = secrets.token_hex(6)
            self.j[jid] = {"kind": kind, "out": "", "done": False, "rc": None, "started": now()}
            if len(self.j) > 30:
                for k in sorted(self.j, key=lambda k: self.j[k]["started"])[:10]:
                    if self.j[k]["done"]:
                        del self.j[k]
        threading.Thread(target=self._run, args=(jid, cmd, timeout, env_extra, after), daemon=True).start()
        return jid

    def _run(self, jid, cmd, timeout, env_extra, after):
        x = self.j[jid]
        e = dict(os.environ)
        e.update({"NO_COLOR": "1", "LC_ALL": "C.UTF-8", "DD": DD})
        e.update(env_extra or {})
        try:
            if callable(cmd):
                for chunk in cmd():
                    x["out"] += chunk
                x["rc"] = 0
            else:
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e)
                t_end = time.time() + timeout
                for line in iter(p.stdout.readline, b""):
                    x["out"] += ANSI.sub("", line.decode("utf-8", "replace"))
                    if len(x["out"]) > 400000:
                        x["out"] = x["out"][-300000:]
                    if time.time() > t_end:
                        p.kill()
                        x["out"] += "\n[превышено время ожидания]\n"
                        break
                x["rc"] = p.wait()
            if after:
                x["out"] += after(x) or ""
        except Exception as ex:
            x["out"] += "\nошибка: %s\n" % ex
            x["rc"] = 1
        x["done"] = True

    def get(self, jid):
        return self.j.get(jid)


JOBS = Jobs()


def switch_test_steps():
    """Имитация падения основного канала и проверка, что сторож переключился (затем флаг снимается)."""
    e = env()
    main = e.get("MAIN") or "awgmain"
    if not e.get("BACKUP") and not e.get("TUNNELS_EXTRA"):
        yield "Запасного канала нет: переключаться некуда.\n"
        return
    open(SIM_F, "w").close()
    yield "Флаг имитации падения %s установлен (%s). Жду переключения до 45 с…\n" % (main, SIM_F)
    ok = False
    try:
        for i in range(45):
            time.sleep(1)
            a = state().get("ACTIVE", "")
            if a and a != main:
                yield "Переключение за ~%d с: активен %s.\n" % (i + 1, a)
                ok = True
                break
        if not ok:
            yield "Переключения не произошло: проверьте, что запасной канал отвечает (Туннели → Тест).\n"
    finally:
        try:
            os.remove(SIM_F)
        except OSError:
            pass
        yield "Флаг снят. Возврат на %s — после RECOVER_SEC=%s с стабильной работы (или «Авто» сразу после перезапуска сторожа).\n" % (
            main, e.get("RECOVER_SEC", "600"))


# ======================================================================= HTTP
def conf():
    c = {"WEB_PORT": "4443", "WEB_BIND": "auto", "WEB_TLS": "yes", "WEB_ALLOW": "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8"}
    c.update(parse_env_text(read_file(CONF_F)))
    return c


def lan_ip():
    out = run(["ip", "-4", "-o", "addr", "show", "dev", "br0"], timeout=5)[1]
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else "127.0.0.1"


STATIC_FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
                "/app.js": ("app.js", "application/javascript; charset=utf-8"), "/app.css": ("app.css", "text/css; charset=utf-8"),
                "/favicon.svg": ("favicon.svg", "image/svg+xml"), "/lang-en.js": ("lang-en.js", "application/javascript; charset=utf-8")}
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")


class ApiError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "awg-web"
    timeout = 60

    def version_string(self):
        return "awg-web"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(self.timeout)
        if isinstance(self.request, ssl.SSLSocket):
            self.request.do_handshake()
        super().setup()

    def log_message(self, fmt, *a):  # тихо: журнал действий ведётся отдельно
        pass

    # ---------- ответы
    def send(self, code, body, ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        if self.server.tls:
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def client_ip(self):
        return self.client_address[0]

    def allowed_client(self):
        try:
            ip = ipaddress.ip_address(self.client_ip())
            if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
                ip = ip.ipv4_mapped
            return any(ip in ipaddress.ip_network(n, strict=False) for n in self.server.allow)
        except ValueError:
            return False

    def cookie(self, name):
        for part in (self.headers.get("Cookie") or "").split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                if k == name:
                    return v
        return ""

    def session(self):
        return SESS.get(self.cookie("awgsid"))

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 3 * 1024 * 1024:
            raise ApiError(413, "слишком большой запрос")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            d = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            raise ApiError(400, "неверный JSON")
        if not isinstance(d, dict):
            raise ApiError(400, "ожидается объект JSON")
        return d

    def host_ok(self):
        """Защита от DNS rebinding: в Host только IP-адрес, localhost или имена из WEB_HOSTS."""
        h = (self.headers.get("Host") or "").strip().lower()
        h = h[1:h.index("]")] if h.startswith("[") and "]" in h else h.rsplit(":", 1)[0] if h.count(":") == 1 else h
        if h in ("localhost",) or h in self.server.hosts or h in getattr(self.server, "cert_names", ()):
            return True
        if any(n.startswith("*.") and h.endswith(n[1:]) and h.count(".") == n.count(".") for n in getattr(self.server, "cert_names", ())):
            return True
        try:
            ipaddress.ip_address(h)
            return True
        except ValueError:
            return False

    def same_origin(self):
        o = self.headers.get("Origin")
        if not o:
            return True     # браузеры шлют Origin на POST; без него — не браузер (curl): проверяем CSRF-токен
        host = self.headers.get("Host", "")
        return urllib.parse.urlparse(o).netloc == host

    # ---------- маршрутизация
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.handle_req("GET")

    def do_POST(self):
        self.handle_req("POST")

    def handle_req(self, method):
        if not self.allowed_client():
            return self.send(403, {"error": "доступ разрешён только из локальной сети"})
        if not self.host_ok():
            return self.send(421, {"error": "откройте панель по IP-адресу роутера (или добавьте имя в WEB_HOSTS в %s)" % CONF_F})
        path = urllib.parse.urlparse(self.path).path
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            if method == "GET" and path in STATIC_FILES:
                fn, ct = STATIC_FILES[path]
                data = read_file(os.path.join(STATIC, fn)) if not fn.endswith(".png") else b""
                if fn == "app.js":   # версия страницы: открытая до обновления вкладка увидит расхождение и перезагрузится
                    data = data.replace("__AWG_PAGE_VERSION__", VERSION)
                return self.send(200, data, ct)
            if not path.startswith("/api/"):
                return self.send(404, {"error": "нет такой страницы"})
            if path == "/api/login" and method == "POST":
                if not self.same_origin():
                    return self.send(403, {"error": "запрос с чужой страницы"})
                return self.login()
            if path == "/api/session" and method == "GET":
                s = self.session()
                if not s:
                    return self.send(401, {"error": "нужен вход", "setup": not load_users()})
                return self.send(200, {"user": s["user"], "csrf": s["csrf"], "version": VERSION})
            s = self.session()
            tk = None
            if not s:
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    return self.send(401, {"error": "нужен вход"})
                ip = self.client_ip()
                if THR.blocked(ip):
                    return self.send(429, {"error": "слишком много неудачных попыток: подождите 15 минут"})
                tk = TOKENS.check(auth[7:].strip(), ip)
                if not tk:
                    THR.fail(ip)
                    audit("", ip, "token-fail")
                    return self.send(401, {"error": "токен неверен, отозван или истёк"})
                if path in TOKEN_DENY or any(path.startswith(x + "/") for x in TOKEN_DENY):
                    return self.send(403, {"error": "это действие доступно только после входа по паролю"})
                if tk["role"] != "admin" and method != "GET":
                    return self.send(403, {"error": "токен только для чтения"})
            if method == "POST":
                _OV["v"] = None          # после действия обзор собирается заново
                # CSRF нужен браузеру с кукой; запрос с токеном куки не несёт, подделать его со страницы нельзя
                if s and (not self.same_origin() or not hmac.compare_digest(self.headers.get("X-CSRF", ""), s["csrf"])):
                    return self.send(403, {"error": "проверка CSRF не пройдена: обновите страницу"})
            self.user = s["user"] if s else "token:" + tk["name"]
            fn = ROUTES.get((method, path))
            if fn:
                if method == "POST":
                    return self.send(200, fn(self, self.body()))
                return self.send(200, fn(self, q))
            for (m, prefix), f in PREFIX_ROUTES.items():
                if m == method and path.startswith(prefix):
                    return f(self, path[len(prefix):], q)
            return self.send(404, {"error": "нет такого метода API"})
        except ApiError as ex:
            return self.send(ex.code, {"error": ex.msg})
        except ValueError as ex:
            return self.send(400, {"error": str(ex)})
        except Exception as ex:
            sys.stderr.write("ошибка %s %s: %r\n" % (method, path, ex))
            return self.send(500, {"error": "внутренняя ошибка: %s" % ex})

    def act(self, action, detail=""):
        audit(getattr(self, "user", ""), self.client_ip(), action, detail)

    # ---------- вход
    def login(self):
        ip = self.client_ip()
        if THR.blocked(ip):
            return self.send(429, {"error": "слишком много неудачных попыток: подождите 15 минут"})
        d = self.body()
        users = load_users()
        u = str(d.get("user", ""))
        rec = users.get(u)
        ok = bool(rec) and check_pw(rec, str(d.get("password", "")))
        if ok and rec.get("totp"):
            if not d.get("totp"):
                return self.send(200, {"need_totp": True})
            ok = totp_ok(rec["totp"], d.get("totp"))
        if not ok:
            time.sleep(1)
            locked = THR.fail(ip)
            audit(u, ip, "login-fail")
            return self.send(401, {"error": "неверное имя, пароль или код" + (" — вход заблокирован на 15 минут" if locked else "")})
        THR.ok(ip)
        tok = SESS.new(u, ip, self.headers.get("User-Agent", ""))
        audit(u, ip, "login")
        ck = "awgsid=%s; HttpOnly; SameSite=Strict; Path=/%s" % (tok, "; Secure" if self.server.tls else "")
        return self.send(200, {"user": u, "csrf": SESS.get(tok)["csrf"], "version": VERSION}, headers={"Set-Cookie": ck})


# ======================================================================= API
def api_logout(h, d):
    SESS.drop(tok=h.cookie("awgsid"))
    h.act("logout")
    return {"ok": True}


_HL = {"t": 0.0, "v": None}
_HL_LOCK = threading.Lock()


def health_cached(maxage=30):
    with _HL_LOCK:
        if _HL["v"] is None or time.time() - _HL["t"] > maxage:
            _HL["v"] = system_health(cpu=SAMPLER.cpu if SAMPLER.is_alive() else None, hist=SAMPLER.sys_history())
            _HL["t"] = time.time()
        return _HL["v"]


def api_health(h, q):
    r = dict(health_cached(5))
    r["history"] = SAMPLER.sys_history()
    return r


_OV = {"t": 0.0, "v": None}
_OV_LOCK = threading.Lock()


def api_overview(h, q):
    with _OV_LOCK:          # несколько вкладок не умножают нагрузку на роутер
        if _OV["v"] is None or time.time() - _OV["t"] > 2:
            _OV["v"] = overview()
            _OV["t"] = time.time()
        return _OV["v"]


def api_live(h, q):
    return {"live": SAMPLER.live_data(), "time": now()}


RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400}


def api_history(h, q):
    rg = (q.get("range") or ["24h"])[0]
    if rg not in RANGES:
        raise ValueError("период: 24h, 7d или 30d")
    if rg == "24h":
        return {"range": rg, "points": SAMPLER.history()}
    return {"range": rg, "hours": SAMPLER.hours(now() - RANGES[rg])}


def get_history_csv(h, rest, q):
    rg = (q.get("range") or ["24h"])[0]
    if rg not in RANGES:
        return h.send(400, {"error": "период: 24h, 7d или 30d"})
    rows = ["time,tunnel,active,rx_bps,tx_bps,rtt_ms,loss_pct,handshake_ok_pct"]
    if rg == "24h":
        for p in SAMPLER.history():
            for t, x in sorted(p.get("tun", {}).items()):
                hs = x.get("hs") if isinstance(x.get("hs"), int) else -1
                rows.append("%s,%s,%d,%d,%d,%s,%s,%d" % (time.strftime("%F %T", time.localtime(p["t"])), t, p.get("active") == t,
                                                          x.get("rx", 0), x.get("tx", 0), x.get("rtt", ""), x.get("loss", ""), 100 if 0 <= hs <= 180 else 0))
    else:
        for p in SAMPLER.hours(now() - RANGES[rg]):
            for t, x in sorted(p["tun"].items()):
                rows.append("%s,%s,%d,%d,%d,%s,%s,%s" % (time.strftime("%F %H:00", time.localtime(p["t"])), t, p.get("active") == t, x["rx"], x["tx"],
                                                          "" if x["rtt"] is None else x["rtt"], "" if x["loss"] is None else x["loss"], x["up"]))
    h.act("history-csv", rg)
    fn = "udr-amnezia-history-%s-%s.csv" % (rg, time.strftime("%Y%m%d-%H%M"))
    return h.send(200, "\n".join(rows) + "\n", "text/csv; charset=utf-8", {"Content-Disposition": 'attachment; filename="%s"' % fn})


def api_events(h, q):
    n = int((q.get("n") or ["300"])[0]) if (q.get("n") or ["x"])[0].isdigit() else 300
    return {"events": events(min(n, 3000))[::-1], "stats7": stats_from_events(7), "stats30": stats_from_events(30)}


def get_tunnel(name):
    if name not in tunnels():
        raise ApiError(404, "нет туннеля «%s»" % name)
    return name


def api_tunnel_switch(h, d):
    t = get_tunnel(str(d.get("name", "")))
    write_secure(FORCEF, t + "\n", 0o644)
    h.act("switch", t)
    for _ in range(60):          # круг сторожа с проверками качества бывает дольше 10 с
        time.sleep(0.5)
        if state().get("ACTIVE") == t:
            return {"ok": True, "msg": "активен %s (выбран вручную). Вернуть автоматику: «Авто»" % t}
        if not read_file(FORCEF).strip():
            return {"ok": False, "msg": "сторож отклонил переключение: канал %s не отвечает" % t}
    st = state().get("ACTIVE", "?")
    return {"ok": False, "msg": "не переключилось за 30 с (сейчас %s): канал %s не отвечает или сторож не запущен" % (st, t)}


def api_tunnel_auto(h, d):
    try:
        os.remove(FORCEF)
    except OSError:
        pass
    h.act("auto")
    return {"ok": True, "msg": "автоматический выбор канала включён"}


def api_tunnel_test(h, d):
    t = get_tunnel(str(d.get("name", "")))
    h.act("test", t)
    return tunnel_test(t)


def api_tunnel_restart(h, d):
    t = get_tunnel(str(d.get("name", "")))
    h.act("restart-tunnel", t)
    with LOCK:
        rc, out = run([os.path.join(DD, "up.sh"), t], timeout=60)
    return {"ok": rc == 0, "msg": out.strip()}


def api_tunnel_label(h, d):
    t = get_tunnel(str(d.get("name", "")))
    lab = str(d.get("label", "")).strip()[:40]
    if re.search(r"[<>\"'&\x00-\x1f]", lab):
        raise ValueError("недопустимые символы в названии")
    with LOCK:
        ls = labels()
        if lab:
            ls[t] = lab
        else:
            ls.pop(t, None)
        write_secure(LABELS_F, json.dumps(ls, ensure_ascii=False))
    h.act("label", {t: lab})
    return {"ok": True}


def api_tunnel_conf_get(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
    return {"name": t, "text": mask_conf(read_file(conf_path(t))), "path": conf_path(t)}


def api_tunnel_add(h, d):
    name = str(d.get("name", "")).strip()
    if not NAME_RE.match(name):
        raise ValueError("имя: awg и 1–10 строчных латинских букв или цифр, например awgalt1")
    e = env()
    if name in tunnels(e) or link_exists(name):
        raise ValueError("туннель %s уже есть" % name)
    cp = os.path.join(DD, name + ".conf")
    with LOCK:
        text = str(d.get("text", "")).replace("\r", "")
        errs = conf_validate(text)
        if errs:
            raise ValueError("конфиг не принят: " + "; ".join(errs))
        write_secure(cp, text)
        rev_save(name, text, "добавлен")
        extra = (e.get("TUNNELS_EXTRA", "") + " " + name).split()
        env_set({"TUNNELS_EXTRA": " ".join(extra)})
        rc, out = run([os.path.join(DD, "up.sh"), name], timeout=60)
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
    if d.get("label"):
        api_tunnel_label(h, {"name": name, "label": d.get("label")})
    h.act("tunnel-add", name)
    return {"ok": rc == 0, "msg": out.strip()}


def api_tunnel_remove(h, d):
    t = get_tunnel(str(d.get("name", "")))
    e = env()
    if t not in e.get("TUNNELS_EXTRA", "").split():
        raise ValueError("удалять из панели можно только дополнительные туннели; основной и запасной — через установщик")
    with LOCK:
        env_set({"TUNNELS_EXTRA": " ".join(x for x in e.get("TUNNELS_EXTRA", "").split() if x != t)})
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
        run(["ip", "link", "del", t], timeout=10)
        run([os.path.join(DD, "failover.sh"), "forget", t], timeout=60)
    h.act("tunnel-remove", t)
    return {"ok": True, "msg": "%s убран вместе с его правилами; конфиг %s.conf оставлен" % (t, t)}


def api_settings_get(h, q):
    e = env()
    vals = {k: e.get(k, DEFAULTS.get(k, "")) for k in SETTINGS}
    return {"values": vals, "labels": {k: v[2] for k, v in SETTINGS.items()},
            "pbr": {k: e.get(k, "") for k in ("TABLE", "MARK", "PRIO", "RAIL_IF", "WANIF", "MAIN", "BACKUP", "TUNNELS_EXTRA", "VPS_IP")}}


def api_settings_set(h, d):
    vals = d.get("values") or {}
    if not isinstance(vals, dict) or not vals:
        raise ValueError("нет изменений")
    upd = {}
    errs = []
    for k, v in vals.items():
        if k not in SETTINGS:
            errs.append("%s: этот параметр из панели не меняется" % k)
            continue
        try:
            upd[k] = SETTINGS[k][0](v)
        except ValueError as ex:
            errs.append("%s: %s" % (SETTINGS[k][2], ex))
    if errs:
        raise ValueError("; ".join(errs))
    e = env()
    changed = {k: v for k, v in upd.items() if e.get(k, DEFAULTS.get(k, "")) != v}
    if not changed:
        return {"ok": True, "msg": "изменений нет"}
    with LOCK:
        env_set(changed)
        e = env()
        svcs = []
        for k in changed:
            for u in SETTINGS[k][1]:
                if u not in svcs:
                    svcs.append(u)
        msgs = apply_services(svcs, e)
    h.act("settings", changed)
    return {"ok": True, "msg": "сохранено: %s\n%s" % (", ".join(changed), "\n".join(msgs))}


def api_services(h, q):
    return {"services": {u: {"installed": svc_installed(u) or u == "awg-failover", "active": svc_active(u),
                             "enabled": u in units_list(), "info": SERVICE_INFO[u],
                             "available": os.path.exists(os.path.join(DD, u + ".service"))} for u in SERVICES}}


def api_service(h, d):
    u = str(d.get("name", ""))
    a = str(d.get("action", ""))
    if u not in SERVICES or a not in ("restart", "enable", "disable"):
        raise ValueError("недопустимая служба или действие")
    if u == "awg-failover" and a == "disable":
        raise ValueError("сторож из панели не выключается: без него PBR-трафик стоит. Если нужно — systemctl stop awg-failover")
    if u in ("awg-notify", "awg-bot") and a != "disable" and not os.path.exists(os.path.join(DD, "telegram.env")):
        raise ValueError("сначала настройте Telegram (Настройки → Telegram)")
    if u == "awg-ha" and a != "disable" and not os.path.exists(HA_F):
        raise ValueError("сначала настройте брокер MQTT (Настройки → Home Assistant)")
    with LOCK:
        if a == "restart":
            rc, out = run(["systemctl", "restart", u], timeout=60)
        elif a == "enable":
            rc, out = unit_on(u)
        else:
            unit_off(u)
            if u == "awg-guard":    # как в установщике: иначе следующее сохранение настроек включит защиту обратно
                env_set({"LEAK_GUARD": "no"})
            rc, out = 0, ""
    h.act("service-" + a, u)
    return {"ok": rc == 0, "msg": "%s: %s %s" % (u, {"restart": "перезапущена", "enable": "включена", "disable": "выключена"}[a], out.strip()[:300])}


TOOLS = {
    "diagnose": (["diagnose.sh"], 300, "Диагностика"),
    "selftest": (["selftest.sh"], 300, "Самопроверка"),
    "selftest-full": (["selftest.sh", "--full"], 300, "Самопроверка с kill switch"),
    "audit": (["audit.sh"], 120, "Аудит"),
    "dedup": (["failover.sh", "dedup"], 120, "Очистка дубликатов"),
    "mtu": (["mtu.sh"], 300, "Подбор MTU"),
    "report": (["report.sh"], 300, "Отчёт"),
    "guard-check": (["guard.sh", "check"], 60, "Проверка защиты"),
    "self-check": (["self.sh", "check"], 120, "Проверка awg-self"),
    "subnets-check": (["subnets.sh", "check"], 60, "Проверка подсетей"),
    "self-reconnect": (["self.sh", "reconnect"], 60, "Переподключение трафика роутера"),
    "drift": (["drift.sh"], 120, "Сверка с эталоном"),
    "drift-repair": (["drift.sh", "repair"], 180, "Восстановление правил"),
    "drift-save": (["drift.sh", "save"], 60, "Новый эталон"),
}


def api_tool(h, d):
    k = str(d.get("tool", ""))
    if k == "switch-test":
        h.act("tool", k)
        return {"job": JOBS.start(k, switch_test_steps)}
    if k == "domain-check":
        dom = v_domains(str(d.get("domain", "")))
        if not dom or " " in dom:
            raise ValueError("укажите один домен")
        h.act("tool", {k: dom})
        return {"job": JOBS.start(k + dom, [os.path.join(DD, "domain-check.sh"), dom], 120)}
    if k == "speedtest":
        mb = int(d.get("mb", 10)) if str(d.get("mb", "10")).isdigit() else 10
        if mb not in (5, 10, 25, 50, 100):
            raise ValueError("объём: 5, 10, 25, 50 или 100 МБ")
        e = env()
        which = str(d.get("iface", "all"))
        lst = tunnels(e) + [wan_if(e) or "eth3"] if which == "all" else ([wan_if(e)] if which == "wan" else [get_tunnel(which)])
        lst = [i for i in lst if i and link_exists(i)]
        if not lst:
            raise ValueError("нет работающих интерфейсов для замера")
        h.act("tool", {k: lst})
        return {"job": JOBS.start(k, lambda: speed_steps(lst, mb), 600)}
    if k == "mtu-apply":
        t = get_tunnel(str(d.get("name", "")))
        h.act("tool", {k: t})
        return {"job": JOBS.start(k, [os.path.join(DD, "mtu.sh"), t, "--apply"], 300)}
    if k not in TOOLS:
        raise ValueError("нет такого инструмента")
    cmd, to, _ = TOOLS[k]
    if not os.path.exists(os.path.join(DD, cmd[0])):
        raise ValueError("скрипт %s не установлен: обновите набор (install.sh --update)" % cmd[0])
    h.act("tool", k)
    return {"job": JOBS.start(k, [os.path.join(DD, cmd[0])] + cmd[1:], to)}


def api_job(h, q):
    j = JOBS.get((q.get("id") or [""])[0])
    if not j:
        raise ApiError(404, "нет такой задачи")
    off = int((q.get("from") or ["0"])[0]) if (q.get("from") or ["x"])[0].isdigit() else 0
    return {"out": j["out"][off:], "len": len(j["out"]), "done": j["done"], "rc": j["rc"], "kind": j["kind"]}


LOGS = {"failover": "failover.log", "notify": "notify.log", "bot": "bot.log", "install": "install.log", "restore": "restore.log", "update": "update.log"}


def api_logs(h, q):
    k = (q.get("kind") or ["failover"])[0]
    n = min(int((q.get("n") or ["300"])[0]) if (q.get("n") or ["x"])[0].isdigit() else 300, 3000)
    if k == "journal":
        rc, out = run(["journalctl", "-u", "awg-*", "-n", str(n), "--no-pager", "-o", "short-iso"], timeout=20)
        return {"text": out}
    if k == "audit":
        return {"text": "\n".join(read_file(AUDIT_F).splitlines()[-n:])}
    if k not in LOGS:
        raise ValueError("нет такого журнала")
    return {"text": "\n".join(read_file(os.path.join(DD, LOGS[k])).splitlines()[-n:])}



# ======================================================================= Home Assistant (#5)
HA_F = os.path.join(DD, "ha.env")
HOST_OR_IP_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")


def api_ha_get(h, q):
    c = parse_env_text(read_file(HA_F))
    return {"host": c.get("MQTT_HOST", ""), "port": c.get("MQTT_PORT", "1883"), "user": c.get("MQTT_USER", ""),
            "pass_set": bool(c.get("MQTT_PASS")), "tls": c.get("MQTT_TLS", "no"), "prefix": c.get("HA_PREFIX", "homeassistant"),
            "interval": c.get("HA_INTERVAL", "30"), "allow_reboot": c.get("HA_ALLOW_REBOOT", "no") == "yes",
            "enabled": svc_installed("awg-ha"), "active": svc_active("awg-ha"),
            "log": "\n".join(read_file(os.path.join(DD, "ha.log")).splitlines()[-15:])}


def api_ha_set(h, d):
    old = parse_env_text(read_file(HA_F))
    host = str(d.get("host", "")).strip()
    if not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес брокера: имя или IP")
    port = str(d.get("port", "1883")).strip()
    if not re.match(r"^\d{1,5}$", port) or not 1 <= int(port) <= 65535:
        raise ValueError("порт: 1–65535")
    user = str(d.get("user", "")).strip()
    if not re.match(r"^[\w.@-]{0,64}$", user):
        raise ValueError("логин: буквы, цифры, . @ - _ (до 64)")
    pw = str(d.get("pass", ""))
    if pw == "":
        pw = old.get("MQTT_PASS", "")       # пусто — прежний пароль (в браузер он не передаётся)
    if len(pw) > 128 or re.search(r"[\x00-\x1f\"'`$\\]", pw):
        raise ValueError("пароль: до 128 символов, без кавычек, $, \\ и управляющих символов")
    tls = str(d.get("tls", "no"))
    if tls not in ("no", "yes", "insecure"):
        raise ValueError("TLS: no, yes или insecure")
    prefix = str(d.get("prefix", "homeassistant")).strip() or "homeassistant"
    if not re.match(r"^[a-z0-9_/-]{1,40}$", prefix):
        raise ValueError("префикс discovery: латиница, цифры, _ - /")
    interval = str(d.get("interval", "30")).strip()
    if not re.match(r"^\d{2,3}$", interval) or not 10 <= int(interval) <= 600:
        raise ValueError("период: 10–600 с")
    reboot = "yes" if d.get("allow_reboot") else "no"
    text = "".join('%s="%s"\n' % kv for kv in (("MQTT_HOST", host), ("MQTT_PORT", port), ("MQTT_USER", user), ("MQTT_PASS", pw),
                                               ("MQTT_TLS", tls), ("HA_PREFIX", prefix), ("HA_INTERVAL", interval), ("HA_ALLOW_REBOOT", reboot)))
    with LOCK:
        write_secure(HA_F, text, 0o600)
        if d.get("enabled", True):
            rc, out = unit_on("awg-ha") if not svc_installed("awg-ha") else run(["systemctl", "restart", "awg-ha"], timeout=30)
        else:
            unit_off("awg-ha")
            rc, out = 0, ""
    h.act("ha-set", {"host": host, "port": port, "tls": tls, "reboot": reboot, "enabled": bool(d.get("enabled", True))})
    return {"ok": rc == 0, "msg": "настройки Home Assistant сохранены" + ("" if rc == 0 else ": " + out.strip()[:200])}


def api_ha_test(h, d):
    h.act("ha-test")
    rc, out = run(["python3", os.path.join(DD, "ha.py"), "test"], timeout=40)
    return {"ok": rc == 0, "msg": out.strip()[-600:] or "нет ответа"}


def api_tg_get(h, q):
    t = parse_env_text(read_file(os.path.join(DD, "telegram.env")))
    tok = t.get("TG_TOKEN", "")
    return {"configured": bool(tok), "token": (tok.split(":")[0] + ":…" + tok[-4:]) if tok else "",
            "chat": " ".join(re.findall(r"-?\d+", t.get("TG_CHAT", ""))), "viewers": " ".join(re.findall(r"-?\d+", t.get("TG_VIEWERS", ""))),
            "muted": [l.split()[0] for l in read_file(os.path.join(DD, "bot.mute")).splitlines() if len(l.split()) == 2 and l.split()[1].isdigit() and int(l.split()[1]) > now()],
            "report_time": t.get("REPORT_TIME", "0900"), "no_wan": t.get("TG_NO_WAN", "0") == "1",
            "notify": svc_active("awg-notify"), "bot": svc_active("awg-bot")}


def api_tg_set(h, d):
    p = os.path.join(DD, "telegram.env")
    t = parse_env_text(read_file(p))
    tok = str(d.get("token", "")).strip()
    if tok:
        if not re.match(r"^\d{5,}:[A-Za-z0-9_-]{30,}$", tok):
            raise ValueError("это не похоже на токен бота вида 123456789:AA…")
        t["TG_TOKEN"] = tok
    if not t.get("TG_TOKEN"):
        raise ValueError("нужен токен бота")
    def chats(v, what, need):
        lst = []
        for x in re.split(r"[\s,;]+", str(v or "").strip()):
            if not x:
                continue
            if not re.match(r"^-?\d{1,20}$", x):
                raise ValueError("%s: «%s» — не chat id (число, у групп — с минусом)" % (what, x))
            if x not in lst:
                lst.append(x)
        if need and not lst:
            raise ValueError("нужен хотя бы один chat id администратора")
        if len(lst) > 10:
            raise ValueError("%s: не больше 10" % what)
        return lst
    admins = chats(d.get("chat", t.get("TG_CHAT", "")), "администраторы", True)
    viewers = [x for x in chats(d.get("viewers", t.get("TG_VIEWERS", "")), "только просмотр", False) if x not in admins]
    chat = " ".join(admins)
    rt = str(d.get("report_time", t.get("REPORT_TIME", "0900"))).strip().replace(":", "")
    if not re.match(r"^([01]\d|2[0-3])[0-5]\d$", rt):
        raise ValueError("время отчёта: ЧЧММ, например 0900")
    lines = ["TG_TOKEN=%s" % t["TG_TOKEN"], 'TG_CHAT="%s"' % chat, 'TG_VIEWERS="%s"' % " ".join(viewers), "REPORT_TIME=%s" % rt]
    if d.get("no_wan"):
        lines.append("TG_NO_WAN=1")
    with LOCK:
        write_secure(p, "\n".join(lines) + "\n")
        msgs = []
        if d.get("enable_notify", True):
            rc, out = unit_on("awg-notify")
            msgs.append("awg-notify: " + ("работает" if rc == 0 else out.strip()[:200]))
        if d.get("enable_bot"):
            rc, out = unit_on("awg-bot")
            msgs.append("awg-bot: " + ("работает" if rc == 0 else out.strip()[:200]))
        elif svc_installed("awg-bot"):
            unit_off("awg-bot")
            msgs.append("awg-bot: выключен")
    h.act("telegram-set", {"chat": chat, "viewers": viewers, "report_time": rt})
    return {"ok": True, "msg": "сохранено\n" + "\n".join(msgs)}


def api_tg_test(h, d):
    h.act("telegram-test")
    rc, out = run([os.path.join(DD, "awg-notify.sh"), "test"], timeout=60)
    return {"ok": "отправлено" in out, "msg": out.strip() or "нет ответа"}


BK_RE = re.compile(r"^[A-Za-z0-9._-]{1,80}\.(tgz|tgz\.enc)$")


def api_backups(h, q):
    d = os.path.join(DD, "backups")
    lst = []
    if os.path.isdir(d):
        for f in sorted(os.listdir(d), reverse=True):
            if BK_RE.match(f):
                st = os.stat(os.path.join(d, f))
                lst.append({"name": f, "size": st.st_size, "time": int(st.st_mtime), "enc": f.endswith(".enc")})
    return {"backups": lst}


def api_backup_create(h, d):
    pw = str(d.get("password", ""))
    if len(pw) < 8:
        raise ValueError("пароль копии — не короче 8 символов (храните его отдельно)")
    h.act("backup-create")
    rc, out = run([os.path.join(DD, "backup.sh"), "create"], timeout=120, env={"AWG_BACKUP_PASS": pw})
    return {"ok": rc == 0, "msg": out.strip()}


def api_backup_delete(h, d):
    f = str(d.get("name", ""))
    if not BK_RE.match(f):
        raise ValueError("недопустимое имя")
    try:
        os.remove(os.path.join(DD, "backups", f))
    except OSError as ex:
        raise ValueError(str(ex))
    h.act("backup-delete", f)
    return {"ok": True}


def get_backup_file(h, rest, q):
    f = (q.get("name") or [""])[0]
    if not BK_RE.match(f) or not os.path.exists(os.path.join(DD, "backups", f)):
        return h.send(404, {"error": "нет такой копии"})
    with open(os.path.join(DD, "backups", f), "rb") as fh:
        data = fh.read()
    h.act("backup-download", f)
    return h.send(200, data, "application/octet-stream", {"Content-Disposition": 'attachment; filename="%s"' % f})


def get_report_file(h, rest, q):
    f = (q.get("name") or [""])[0]
    if not re.match(r"^awg-report-\d{8}-\d{6}\.txt$", f) or not os.path.exists(os.path.join("/tmp", f)):
        return h.send(404, {"error": "нет такого отчёта"})
    h.act("report-download", f)
    return h.send(200, read_file(os.path.join("/tmp", f)), "text/plain; charset=utf-8",
                  {"Content-Disposition": 'attachment; filename="%s"' % f})


def api_users(h, q):
    u = load_users()
    return {"users": [{"name": k, "totp": bool(v.get("totp")), "me": k == h.user} for k, v in sorted(u.items())]}


def api_passwd(h, d):
    users = load_users()
    me = users.get(h.user)
    if not me or not check_pw(me, str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    target = str(d.get("user") or h.user)
    if not USER_RE.match(target):
        raise ValueError("имя: латиница, цифры, _.- до 32 символов")
    pw = str(d.get("password", ""))
    pr = pw_problem(pw)
    if pr:
        raise ValueError(pr)
    with LOCK:
        users = load_users()
        existed = target in users
        rec = users.get(target, {})
        rec.update(hash_pw(pw))
        users[target] = rec
        save_users(users)
    if target != h.user:
        SESS.drop(user=target)
    h.act("passwd", target)
    return {"ok": True, "msg": "пользователь %s %s" % (target, "— пароль изменён" if existed else "создан")}


def api_user_delete(h, d):
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    t = str(d.get("user", ""))
    if t == h.user:
        raise ValueError("себя удалить нельзя")
    if t not in users:
        raise ValueError("нет такого пользователя")
    with LOCK:
        users.pop(t)
        save_users(users)
    SESS.drop(user=t)
    h.act("user-delete", t)
    return {"ok": True}


def api_totp_begin(h, d):
    sec = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    uri = "otpauth://totp/UDR-Amnezia:%s?secret=%s&issuer=UDR-Amnezia" % (urllib.parse.quote(h.user), sec)
    return {"secret": sec, "uri": uri}


def api_totp_enable(h, d):
    sec = str(d.get("secret", ""))
    if not re.match(r"^[A-Z2-7]{16,64}$", sec):
        raise ValueError("неверный секрет")
    if not totp_ok(sec, d.get("code")):
        raise ValueError("код не подошёл: проверьте время на телефоне и введите новый код")
    with LOCK:
        users = load_users()
        users[h.user]["totp"] = sec
        save_users(users)
    h.act("totp-enable")
    return {"ok": True}


def api_totp_disable(h, d):
    users = load_users()
    if not check_pw(users[h.user], str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    with LOCK:
        users[h.user].pop("totp", None)
        save_users(users)
    h.act("totp-disable")
    return {"ok": True}


def api_system(h, q):
    def ver(cmd):
        return run(cmd, timeout=5)[1].strip().splitlines()[0] if run(cmd, timeout=5)[0] == 0 else "?"
    inst = read_file(os.path.join(DD, "install.sh"))
    m = re.search(r"^INSTALLER_VERSION=(\S+)", inst, re.M)
    return {"version": read_file(os.path.join(DD, "VERSION")).strip(), "installer": m.group(1) if m else "?",
            "panel": VERSION, "awg": ver([os.path.join(DD, "awg"), "--version"]),
            "amneziawg_go": ver([os.path.join(DD, "amneziawg-go"), "--version"]),
            "python": sys.version.split()[0], "host": socket.gethostname(), "web": {k: v for k, v in conf().items()},
            "tls": h.server.tls, "data_free_mb": disk_free_mb(), "channel": channel()[1], "branch": channel()[2]}



# ======================================================================= конфиги: поля, проверка, ревизии
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


def _ints(lo, hi):
    def f(v):
        if not re.match(r"^\d{1,10}$", v) or not lo <= int(v) <= hi:
            raise ValueError("целое от %d до %d" % (lo, hi))
    return f


def _key(v):
    if not KEY_RE.match(v):
        raise ValueError("ключ WireGuard: 44 символа base64, оканчивается на «=»")


def _addrs(v):
    parts = [x.strip() for x in v.split(",") if x.strip()]
    if not parts:
        raise ValueError("пусто")
    for x in parts:
        try:
            ipaddress.ip_interface(x)
        except ValueError:
            raise ValueError("«%s» — не адрес вида 10.8.1.2/32" % x)
    if not any(":" not in x for x in parts):
        raise ValueError("нужен хотя бы один IPv4-адрес")


def _ips(v):
    for x in [x.strip() for x in v.split(",") if x.strip()]:
        try:
            ipaddress.ip_address(x)
        except ValueError:
            if not HOST_RE.match(x):
                raise ValueError("«%s» — не IP-адрес" % x)


def _cidrs(v):
    parts = [x.strip() for x in v.split(",") if x.strip()]
    if not parts:
        raise ValueError("пусто")
    for x in parts:
        try:
            ipaddress.ip_network(x, strict=False)
        except ValueError:
            raise ValueError("«%s» — не сеть вида 0.0.0.0/0" % x)


def _endpoint(v):
    m = re.match(r"^\[([0-9A-Fa-f:.]+)\]:(\d{1,5})$", v) or re.match(r"^([^:\[\]]+):(\d{1,5})$", v)
    if not m or not 1 <= int(m.group(2)) <= 65535:
        raise ValueError("нужно АДРЕС:ПОРТ, например 203.0.113.10:51820")
    host = m.group(1)
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not HOST_RE.match(host):
            raise ValueError("«%s» — не адрес и не имя сервера" % host)


def _hrange(v):
    m = re.match(r"^(\d{1,10})(?:-(\d{1,10}))?$", v)
    if not m or int(m.group(1)) > 4294967295 or (m.group(2) and (int(m.group(2)) > 4294967295 or int(m.group(2)) < int(m.group(1)))):
        raise ValueError("число 0–4294967295 или диапазон «от-до»")


def _itag(v):
    if len(v) > 4096 or not re.match(r"^(\s*<[^<>\r\n]{1,1000}>)+\s*$", v):
        raise ValueError("последовательность тегов вида <b 0x…><r 16>")


def _onoff(v):
    if v.lower() not in ("on", "off", "true", "false", "1", "0", "yes", "no"):
        raise ValueError("on или off")


def _b64(v):
    if not re.match(r"^[A-Za-z0-9+/]{16,128}={0,2}$", v):
        raise ValueError("ключ в base64")


def _mtu(v):
    _ints(1000, 1500)(v)


# раздел, ключ, проверка, обязателен, подсказка
CONF_FIELDS = [
    ("Interface", "PrivateKey", _key, True, "закрытый ключ роутера"),
    ("Interface", "Address", _addrs, True, "адрес в туннеле, например 10.8.1.2/32"),
    ("Interface", "DNS", _ips, False, "не применяется на роутере (DNS задаёт UniFi), только для справки"),
    ("Interface", "MTU", _mtu, False, "пусто — по умолчанию 1376"),
    ("Interface", "Jc", _ints(0, 128), False, "число мусорных пакетов перед handshake"),
    ("Interface", "Jmin", _ints(0, 1280), False, "мин. размер мусорного пакета"),
    ("Interface", "Jmax", _ints(0, 1280), False, "макс. размер мусорного пакета"),
    ("Interface", "S1", _ints(0, 1500), False, "добавка к пакету инициации"),
    ("Interface", "S2", _ints(0, 1500), False, "добавка к пакету ответа"),
    ("Interface", "S3", _ints(0, 1500), False, "AWG 2.0: добавка к cookie"),
    ("Interface", "S4", _ints(0, 1500), False, "AWG 2.0: добавка к данным"),
    ("Interface", "H1", _hrange, False, "заголовок инициации"),
    ("Interface", "H2", _hrange, False, "заголовок ответа"),
    ("Interface", "H3", _hrange, False, "заголовок cookie"),
    ("Interface", "H4", _hrange, False, "заголовок данных"),
    ("Interface", "I1", _itag, False, "AWG 2.0: имитация протокола"),
    ("Interface", "I2", _itag, False, ""),
    ("Interface", "I3", _itag, False, ""),
    ("Interface", "I4", _itag, False, ""),
    ("Interface", "I5", _itag, False, ""),
    ("Interface", "HeaderProtectionKey", _b64, False, "AWG 3.x: ключ защиты заголовков"),
    ("Interface", "ContentPaddingAddition", _hrange, False, "AWG 3.x: добавка к данным, «от-до»"),
    ("Interface", "RekeyAfterTime", _hrange, False, "AWG 3.x: смена ключей через, с"),
    ("Interface", "RekeyTimeout", _hrange, False, "AWG 3.x: таймаут смены ключей, с"),
    ("Interface", "RejectAfterTime", _hrange, False, "AWG 3.x: отклонять старый ключ через, с"),
    ("Interface", "KeepaliveTimeout", _hrange, False, "AWG 3.x: таймаут keepalive, с"),
    ("Interface", "MaxHandshakeAttempts", _hrange, False, "AWG 3.x: попыток handshake"),
    ("Interface", "RandomTrailers", _onoff, False, "AWG 3.x: случайные хвосты пакетов"),
    ("Interface", "DisableCookies", _onoff, False, "AWG 3.x: без cookie-ответов"),
    ("Peer", "PublicKey", _key, True, "открытый ключ сервера"),
    ("Peer", "PresharedKey", _key, False, "общий ключ (если есть)"),
    ("Peer", "Endpoint", _endpoint, True, "адрес и порт сервера"),
    ("Peer", "AllowedIPs", _cidrs, True, "обычно 0.0.0.0/0"),
    ("Peer", "PersistentKeepalive", _ints(0, 65535), False, "секунд; 25 — держать NAT открытым"),
]
FIELD_BY_KEY = {(s, k.lower()): (s, k, f, req, hint) for s, k, f, req, hint in CONF_FIELDS}
SECRET_FIELDS = {"privatekey", "presharedkey", "headerprotectionkey"}


def conf_sections(text):
    """[(имя раздела или '', [строки])] — порядок и комментарии сохраняются."""
    out = [("", [])]
    for line in text.replace("\r", "").split("\n"):
        m = re.match(r"^\s*\[([A-Za-z]+)\]\s*$", line)
        if m:
            out.append((m.group(1), [line]))
        else:
            out[-1][1].append(line)
    return out


def conf_join(secs):
    text = "\n".join("\n".join(lines) for _, lines in secs if lines)
    return text.strip("\n") + "\n"


def conf_fields(text, masked=True):
    res = {"Interface": {}, "Peer": {}}
    other = []
    seen = set()
    peers = 0
    for name, lines in conf_sections(text):
        if name == "Peer":
            peers += 1
            if peers > 1:
                continue
        for line in lines:
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            fk = FIELD_BY_KEY.get((name, k.lower()))
            if fk and (name, fk[1]) not in seen:
                seen.add((name, fk[1]))
                res[name][fk[1]] = (MASK if masked and v else v) if k.lower() in SECRET_FIELDS else v
            elif name in ("Interface", "Peer"):
                other.append("%s.%s" % (name, k))
    return {"fields": res, "other": other, "peers": peers}


def conf_apply_fields(text, fields):
    """Записать поля в текст конфига: меняются только переданные ключи, остальные строки остаются."""
    secs = conf_sections(text)
    for sec in ("Interface", "Peer"):
        upd = fields.get(sec) or {}
        if not isinstance(upd, dict):
            raise ValueError("неверный формат полей")
        idx = next((i for i, (n, _) in enumerate(secs) if n == sec), None)
        if idx is None:
            secs.append((sec, ["[%s]" % sec]))
            idx = len(secs) - 1
        lines = secs[idx][1]
        for key, val in upd.items():
            fk = FIELD_BY_KEY.get((sec, str(key).lower()))
            if not fk:
                raise ValueError("неизвестное поле %s.%s" % (sec, key))
            key = fk[1]
            val = str(val if val is not None else "").strip()
            if "\n" in val or "\r" in val:
                raise ValueError("%s: перевод строки недопустим" % key)
            if key.lower() in SECRET_FIELDS and val == MASK:
                continue                       # секрет не меняется
            pos = next((i for i, l in enumerate(lines) if "=" in l and l.split("=", 1)[0].strip().lower() == key.lower()), None)
            if val == "":
                if pos is not None:
                    del lines[pos]
                continue
            if pos is not None:
                lines[pos] = "%s = %s" % (key, val)
            else:
                last = max([i for i, l in enumerate(lines) if l.strip()] or [0])
                lines.insert(last + 1, "%s = %s" % (key, val))
    return conf_join(secs)


def conf_validate(text):
    """Базовая проверка + значения известных ключей. → список ошибок."""
    errs = check_conf(text)
    vals = {}
    peers = 0
    for name, lines in conf_sections(text):
        if name == "Peer":
            peers += 1
        for line in lines:
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            fk = FIELD_BY_KEY.get((name, k.strip().lower()))
            if not fk:
                continue
            v = v.strip()
            if name == "Interface" or peers == 1:
                vals[fk[1]] = v
            if v == "" or (k.strip().lower() in SECRET_FIELDS and v == MASK):
                continue
            try:
                fk[2](v)
            except ValueError as ex:
                errs.append("%s: %s" % (fk[1], ex))
    if vals.get("Jmin", "").isdigit() and vals.get("Jmax", "").isdigit() and int(vals["Jmin"]) > int(vals["Jmax"]):
        errs.append("Jmin больше Jmax")
    if peers > 1:
        errs.append("в конфиге несколько [Peer]: для туннеля на роутере нужен один сервер")
    return errs


HISTD = os.path.join(DD, "history")
REV_RE = re.compile(r"^\d{8}-\d{6}(-\d+)?\.conf$")


def rev_key(f):
    m = re.match(r"^(\d{8}-\d{6})(?:-(\d+))?\.conf$", f)
    return (m.group(1), int(m.group(2) or 0)) if m else (f, 0)


def rev_dir(t):
    return os.path.join(HISTD, t)


def rev_save(t, text, why=""):
    """Сохранить версию конфига в историю (до 15 штук на туннель, права 600)."""
    if not text.strip():
        return ""
    d = rev_dir(t)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(HISTD, 0o700)
    lst = sorted((f for f in os.listdir(d) if REV_RE.match(f)), key=rev_key)
    if lst and read_file(os.path.join(d, lst[-1])) == text:
        return lst[-1]
    base = time.strftime("%Y%m%d-%H%M%S")
    name = base + ".conf"
    i = 1
    while os.path.exists(os.path.join(d, name)):
        name = "%s-%d.conf" % (base, i)
        i += 1
    write_secure(os.path.join(d, name), text)
    if why:
        write_secure(os.path.join(d, name + ".why"), why[:200])
    for old in lst[:-14]:
        for f in (old, old + ".why"):
            try:
                os.remove(os.path.join(d, f))
            except OSError:
                pass
    return name


def rev_list(t):
    d = rev_dir(t)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted((f for f in os.listdir(d) if REV_RE.match(f)), key=rev_key, reverse=True):
        p = os.path.join(d, f)
        out.append({"id": f, "time": int(os.stat(p).st_mtime), "why": read_file(p + ".why").strip(),
                    "summary": summary_of(read_file(p))})
    return out


def summary_of(text):
    f = conf_fields(text)["fields"]
    return {"endpoint": f["Peer"].get("Endpoint", ""), "address": f["Interface"].get("Address", ""), "proto": proto_of(text),
            "mtu": f["Interface"].get("MTU", "")}


def apply_conf_text(h, t, text, why):
    """Проверить, сохранить (с версией в истории), перезапустить туннель; при ошибке вернуть прежний. → ответ API."""
    cp = conf_path(t)
    with LOCK:
        old = read_file(cp)
        text = unmask_conf(text, old) if MASK in text else text.replace("\r", "")
        errs = conf_validate(text)
        if errs:
            raise ValueError("конфиг не принят: " + "; ".join(errs))
        if old.strip() == text.strip():
            return {"ok": True, "msg": "изменений нет", "unchanged": True}
        if old:
            rev_save(t, old, "до: " + why)
            write_secure(cp + ".prev", old)
        write_secure(cp, text)
        rc, out = run([os.path.join(DD, "up.sh"), t], timeout=60)
        if rc != 0 and old:
            write_secure(cp, old)
            run([os.path.join(DD, "up.sh"), t], timeout=60)
            h.act("conf-set-failed", {t: why})
            return {"ok": False, "msg": "туннель с новым конфигом не поднялся, возвращён прежний:\n" + out.strip()}
        rev_save(t, text, why)
        if svc_active("awg-self"):
            run(["systemctl", "restart", "awg-self"], timeout=30)   # адрес сервера туннеля — в исключениях awg-self
    h.act("conf-set", {t: why})
    hs = -1
    for _ in range(8):
        time.sleep(1)
        hs = hs_age(t)
        if 0 <= hs < 30:
            break
    return {"ok": True, "msg": out.strip() + ("\nhandshake: %d с назад" % hs if hs >= 0 else
                                               "\nhandshake пока нет: проверьте через несколько секунд (Тест)"), "handshake": hs}


# ======================================================================= импорт (.conf, vpn://, JSON Amnezia)
IMPORTS = {}
IMPORTS_LOCK = threading.Lock()


def _find_conf(o, depth=0):
    if depth > 6:
        return None
    if isinstance(o, str):
        s = o.strip()
        if s.startswith("{"):
            try:
                return _find_conf(json.loads(s), depth + 1)
            except ValueError:
                return None
        if "[Interface]" in s and "[Peer]" in s:
            return s
        return None
    if isinstance(o, dict):
        for k in ("config", "last_config"):
            if k in o:
                r = _find_conf(o[k], depth + 1)
                if r:
                    return r
        for v in o.values():
            r = _find_conf(v, depth + 1)
            if r:
                return r
    if isinstance(o, list):
        for v in o:
            r = _find_conf(v, depth + 1)
            if r:
                return r
    return None


def decode_import(data):
    """Текст конфига из .conf, ссылки vpn:// (AmneziaVPN) или JSON. → (текст, источник, предупреждения)."""
    s = str(data or "").strip().lstrip("﻿")
    warns = []
    if not s:
        raise ValueError("пусто: вставьте конфиг, ссылку vpn:// или выберите файл")
    if len(s) > 200000:
        raise ValueError("слишком большой текст")
    src = "conf"
    obj = None
    if s.lower().startswith("vpn://"):
        src = "vpn://"
        b = re.sub(r"\s", "", s[6:])
        b += "=" * (-len(b) % 4)
        try:
            raw = base64.urlsafe_b64decode(b)
        except (ValueError, TypeError):
            raise ValueError("ссылка vpn:// повреждена (не base64)")
        js = None
        for cand in (raw[4:], raw):
            try:
                js = zlib.decompress(cand)
                break
            except zlib.error:
                continue
        if js is None:
            js = raw
        try:
            obj = json.loads(js.decode("utf-8"))
        except ValueError:
            raise ValueError("ссылка vpn:// не распознана: внутри не JSON AmneziaVPN")
    elif s.startswith("{"):
        src = "json"
        try:
            obj = json.loads(s)
        except ValueError:
            raise ValueError("неверный JSON")
    if obj is not None:
        text = _find_conf(obj)
        if not text:
            raise ValueError("в ссылке нет конфига AmneziaWG/WireGuard (возможно, это ключ для другого протокола — OpenVPN, XRay)")
        dns = [obj.get("dns1"), obj.get("dns2")] if isinstance(obj, dict) else [None, None]
        text = text.replace("$PRIMARY_DNS", dns[0] or "1.1.1.1").replace("$SECONDARY_DNS", dns[1] or "1.0.0.1")
        if isinstance(obj, dict) and obj.get("description"):
            warns.append("название в AmneziaVPN: %s" % str(obj.get("description"))[:60])
    else:
        text = s
    text = text.replace("\r", "").strip() + "\n"
    if re.search(r"\$[A-Z_]{3,}", text):
        warns.append("в конфиге остались подстановки вида $ИМЯ: проверьте строки")
    return text, src, warns


def import_put(user, text):
    tok = secrets.token_urlsafe(18)
    with IMPORTS_LOCK:
        for k in [k for k, v in IMPORTS.items() if now() - v["t"] > 900]:
            del IMPORTS[k]
        IMPORTS[tok] = {"t": now(), "user": user, "text": text}
    return tok


def import_get(user, tok):
    with IMPORTS_LOCK:
        x = IMPORTS.get(str(tok or ""))
        if not x or x["user"] != user or now() - x["t"] > 900:
            raise ValueError("загруженный конфиг устарел: загрузите его снова")
        return x["text"]


def api_import_parse(h, d):
    text, src, warns = decode_import(d.get("data", ""))
    errs = conf_validate(text)
    f = conf_fields(text)
    if f["peers"] == 0:
        errs.append("нет раздела [Peer]")
    e = env()
    ep = f["fields"]["Peer"].get("Endpoint", "")
    for t in tunnels(e):
        if ep and conf_get(read_file(conf_path(t, e)), "Endpoint") == ep:
            warns.append("этот сервер (%s) уже используется туннелем %s" % (ep.rsplit(":", 1)[0], t))
    tok = import_put(h.user, text) if not errs else ""
    h.act("import-parse", src)
    return {"ok": not errs, "token": tok, "source": src, "errors": errs, "warnings": warns, "text": mask_conf(text),
            "fields": f["fields"], "proto": proto_of(text), "other": f["other"]}


def api_import_apply(h, d):
    text = import_get(h.user, d.get("token"))
    target = str(d.get("target", ""))
    if target == "new":
        return api_tunnel_add(h, {"name": d.get("name"), "label": d.get("label"), "text": text})
    t = get_tunnel(target)
    r = apply_conf_text(h, t, text, "импорт")
    if d.get("label"):
        api_tunnel_label(h, {"name": t, "label": d.get("label")})
    return r


# ======================================================================= API: туннели (поля, история, экспорт, порядок)
def api_tunnel_fields_get(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
    text = read_file(conf_path(t))
    f = conf_fields(text)
    return {"name": t, "fields": f["fields"], "other": f["other"], "peers": f["peers"], "proto": proto_of(text),
            "schema": [{"sec": s, "key": k, "req": r, "hint": hint, "secret": k.lower() in SECRET_FIELDS} for s, k, _, r, hint in CONF_FIELDS],
            "text": mask_conf(text), "path": conf_path(t), "revisions": len(rev_list(t))}


def preview_text(t, d):
    old = read_file(conf_path(t))
    if "fields" in d:
        new = conf_apply_fields(old, d.get("fields") or {})
    else:
        new = str(d.get("text", "")).replace("\r", "")
        new = unmask_conf(new, old) if MASK in new else new
    return old, new


def api_tunnel_preview(h, d):
    t = get_tunnel(str(d.get("name", "")))
    old, new = preview_text(t, d)
    return {"errors": conf_validate(new), "old": mask_conf(old), "new": mask_conf(new), "changed": old.strip() != new.strip()}


def api_tunnel_conf_set(h, d):
    t = get_tunnel(str(d.get("name", "")))
    old, new = preview_text(t, d)
    return apply_conf_text(h, t, new, "форма" if "fields" in d else "редактор")


def api_tunnel_revisions(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
    cur = read_file(conf_path(t))
    lst = rev_list(t)
    seen = False
    for r in lst:   # новые сверху: «текущая» — только самая свежая совпадающая, остальные совпадения — «как текущая»
        same = read_file(os.path.join(rev_dir(t), r["id"])).strip() == cur.strip()
        r["current"] = same and not seen
        r["same"] = same and seen
        seen = seen or same
    return {"name": t, "revisions": lst}


def api_tunnel_revision(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
    rid = (q.get("id") or [""])[0]
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return {"name": t, "id": rid, "text": mask_conf(read_file(os.path.join(rev_dir(t), rid))), "current": mask_conf(read_file(conf_path(t)))}


def api_tunnel_revision_restore(h, d):
    t = get_tunnel(str(d.get("name", "")))
    rid = str(d.get("id", ""))
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return apply_conf_text(h, t, read_file(os.path.join(rev_dir(t), rid)), "возврат версии " + rid[:15])


def api_tunnel_export(h, d):
    t = get_tunnel(str(d.get("name", "")))
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act("export-denied", t)
        raise ApiError(403, "текущий пароль неверен")
    h.act("conf-export", t)
    return {"name": t, "filename": t + ".conf", "text": read_file(conf_path(t))}


def api_tunnel_order(h, d):
    e = env()
    cur = e.get("TUNNELS_EXTRA", "").split()
    new = [str(x) for x in (d.get("extra") or [])]
    if sorted(new) != sorted(cur):
        raise ValueError("порядок должен содержать те же дополнительные туннели")
    with LOCK:
        env_set({"TUNNELS_EXTRA": " ".join(new)})
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
    h.act("tunnel-order", new)
    return {"ok": True, "msg": "порядок сохранён, сторож перезапущен"}


# ======================================================================= скорость
SPEED_F = os.path.join(WEBD, "speed.json")
SPEED_URL = os.environ.get("AWG_SPEED_URL", "https://speed.cloudflare.com")


def speed_hist():
    try:
        x = json.loads(read_file(SPEED_F, "[]"))
        return x if isinstance(x, list) else []
    except ValueError:
        return []


def speed_steps(ifaces, mb):
    """Замер скорости: задержка (TCP-подключение), загрузка и отдача через указанный интерфейс."""
    res = []
    for i in ifaces:
        yield "== %s\n" % i
        r = {"t": now(), "iface": i, "mb": mb}
        rc, out = curl(["-o", "/dev/null", "--interface", i, "-w", "%{time_connect}", SPEED_URL + "/__down?bytes=0"], 8)
        try:
            r["ping_ms"] = int(float(out.strip() or 0) * 1000)
        except ValueError:
            r["ping_ms"] = 0
        yield "задержка (TCP-подключение): %s мс\n" % (r["ping_ms"] or "—")
        rc, out = curl(["-o", "/dev/null", "--interface", i, "-w", "%{speed_download} %{size_download}",
                        "%s/__down?bytes=%d" % (SPEED_URL, mb * 1000000)], 40)
        p = out.split()
        r["down_bps"] = int(float(p[0]) * 8) if rc == 0 and p else 0
        yield "загрузка: %s\n" % (fmt_bps(r["down_bps"]) if r["down_bps"] else "не удалось (код %d)" % rc)
        up_mb = max(1, mb // 4)
        rc, out = run(["sh", "-c", 'head -c %d /dev/zero | curl -s -4 -m 40 --interface "$1" -o /dev/null -w "%%{speed_upload}" '
                       '--data-binary @- "$2"' % (up_mb * 1000000), "sh", i, SPEED_URL + "/__up"], timeout=45)
        try:
            r["up_bps"] = int(float(out.strip().split()[-1]) * 8) if rc == 0 else 0
        except (ValueError, IndexError):
            r["up_bps"] = 0
        yield "отдача: %s\n\n" % (fmt_bps(r["up_bps"]) if r["up_bps"] else "не удалось (код %d)" % rc)
        res.append(r)
    with LOCK:
        hist = (speed_hist() + res)[-60:]
        write_secure(SPEED_F, json.dumps(hist), 0o600)
    yield "Сохранено в историю замеров.\n"


def fmt_bps(b):
    b = float(b)
    for u, k in (("Гбит/с", 1e9), ("Мбит/с", 1e6), ("Кбит/с", 1e3)):
        if b >= k:
            return "%.1f %s" % (b / k, u)
    return "%d бит/с" % b


def api_speed(h, q):
    return {"history": speed_hist()[::-1]}


# ======================================================================= клиенты в туннеле (conntrack)
LEASE_FILES = [os.environ.get("AWG_LEASES", "/run/dnsmasq.leases"), "/run/dnsmasq.leases", "/run/dnsmasq.dhcp.leases", "/var/run/dnsmasq.leases", "/tmp/dnsmasq.leases",
               "/data/udapi-config/dnsmasq.lease", "/var/lib/misc/dnsmasq.leases"]


def leases():
    names = {}
    files = list(LEASE_FILES)
    try:
        files += ["/run/" + f for f in os.listdir("/run") if f.startswith("dnsmasq") and f.endswith("leases")]
    except OSError:
        pass
    for f in files:
        for line in read_file(f).splitlines():
            p = line.split()
            if len(p) >= 4 and is_ipv4(p[2]):
                names[p[2]] = {"mac": p[1], "name": "" if p[3] == "*" else p[3]}
    out = run(["ip", "-4", "neigh", "show"], timeout=5)[1]
    for line in out.splitlines():
        p = line.split()
        if p and is_ipv4(p[0]) and "lladdr" in p:
            names.setdefault(p[0], {"mac": p[p.index("lladdr") + 1], "name": ""})
    return names


def conntrack_lines():
    rc, out = run(["conntrack", "-L", "-f", "ipv4"], timeout=15)
    if rc == 0 and "src=" in out:
        return out.splitlines()
    return read_file("/proc/net/nf_conntrack").splitlines()


def parse_mark(m):
    try:
        if "/" in m:
            v, k = m.split("/", 1)
            return int(v, 0), int(k, 0)
        return int(m, 0), 0xFFFFFFFF
    except ValueError:
        return None, None


def clients():
    e = env()
    mv, mk = parse_mark(e.get("MARK", ""))
    taddr = {}
    for t in tunnels(e):
        a = if_ipv4(t)
        if a:
            taddr[a] = t
    own = set(taddr) | {lan_ip()}
    names = leases()
    cl = {}
    total = 0
    for line in conntrack_lines()[:60000]:
        if "src=" not in line:
            continue
        kv = re.findall(r"(\w+)=(\S+)", line)
        srcs = [v for k, v in kv if k == "src"]
        dsts = [v for k, v in kv if k == "dst"]
        bts = [int(v) for k, v in kv if k == "bytes" and v.isdigit()]
        mark = next((v for k, v in kv if k == "mark"), "0")
        if len(srcs) < 2 or len(dsts) < 2:
            continue
        src, dst, rdst = srcs[0], dsts[0], dsts[1]
        try:
            ip = ipaddress.ip_address(src)
        except ValueError:
            continue
        if not ip.is_private or src in own:
            continue
        tun = taddr.get(rdst, "")
        try:
            mm = int(mark)
        except ValueError:
            mm = 0
        marked = mv is not None and mk and (mm & mk) == (mv & mk) and mv != 0
        if not tun and not marked:
            continue
        total += 1
        c = cl.setdefault(src, {"ip": src, "conns": 0, "bytes": 0, "tunnels": collections.Counter(), "dst": collections.Counter()})
        c["conns"] += 1
        c["bytes"] += sum(bts)
        c["tunnels"][tun or "PBR"] += 1
        c["dst"][dst] += 1
    out = []
    for ip, c in cl.items():
        n = names.get(ip, {})
        out.append({"ip": ip, "name": n.get("name", ""), "mac": n.get("mac", ""), "conns": c["conns"], "bytes": c["bytes"],
                    "tunnel": c["tunnels"].most_common(1)[0][0], "top": [d for d, _ in c["dst"].most_common(3)]})
    out.sort(key=lambda x: (-x["conns"], x["ip"]))
    return {"clients": out, "total": total, "mark": e.get("MARK", "")}


_CL = {"t": 0.0, "v": None}
_CL_LOCK = threading.Lock()


def api_clients(h, q):
    with _CL_LOCK:
        if _CL["v"] is None or time.time() - _CL["t"] > 5:
            _CL["v"] = clients()
            _CL["t"] = time.time()
        return _CL["v"]


# ======================================================================= сеансы
def sid(tok):
    return Sessions.key(tok)[:12]


def api_sessions(h, q):
    return {"sessions": sorted(SESS.listing(h.cookie("awgsid")), key=lambda x: -x["seen"])}


def api_session_revoke(h, d):
    x = str(d.get("id", ""))
    if x != "others" and not re.match(r"^[0-9a-f]{12}$", x):
        raise ValueError("нет такого сеанса")
    SESS.drop(sid_=x, keep=h.cookie("awgsid"))
    h.act("session-revoke", x)
    return {"ok": True}


def api_tokens(h, q):
    return {"tokens": sorted(TOKENS.listing(), key=lambda x: -x["created"])}


def api_token_create(h, d):
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act("token-create-denied")
        raise ApiError(403, "текущий пароль неверен")
    name = str(d.get("name", "")).strip()
    if not re.match(r"^[\w .:-]{1,40}$", name):
        raise ValueError("название: 1–40 символов (буквы, цифры, пробел, . : - _)")
    role = str(d.get("role", ""))
    if role not in ("read", "admin"):
        raise ValueError("роль: read или admin")
    days = d.get("days", 0)
    if not isinstance(days, int) or not 0 <= days <= 3650:
        raise ValueError("срок: 0 (бессрочно) – 3650 дней")
    tid, tok = TOKENS.create(name, role, days, h.user)
    h.act("token-create", {"id": tid, "name": name, "role": role, "days": days})
    return {"id": tid, "token": tok, "msg": "токен создан: скопируйте его сейчас, повторно он не показывается"}


def api_token_revoke(h, d):
    tid = str(d.get("id", ""))
    if not re.match(r"^[0-9a-f]{12}$", tid):
        raise ValueError("нет такого токена")
    TOKENS.revoke(tid)
    h.act("token-revoke", tid)
    return {"ok": True}


# ======================================================================= сертификат
UNIFI_CORE = os.environ.get("AWG_UNIFI_CORE", "/data/unifi-core/config")


def cert_info(path):
    """Субъект, издатель, срок, имена из сертификата (без внешних модулей)."""
    try:
        d = ssl._ssl._test_decode_cert(path)
    except Exception:
        return None
    sub = dict(x[0] for x in d.get("subject", ()) if x)
    iss = dict(x[0] for x in d.get("issuer", ()) if x)
    try:
        exp = int(ssl.cert_time_to_seconds(d.get("notAfter", "")))
    except (ValueError, TypeError):
        exp = 0
    sans = [v for k, v in d.get("subjectAltName", ()) if k in ("DNS", "IP Address")]
    return {"subject": sub.get("commonName", ""), "issuer": iss.get("organizationName") or iss.get("commonName", ""),
            "expires": exp, "names": sans, "self_signed": d.get("subject") == d.get("issuer"), "path": path}


def unifi_cert_candidates():
    """Сертификат веб-интерфейса UniFi OS: из конфигов nginx/unifi-core, затем стандартные имена, затем поиск."""
    cands = []
    for f in sorted(globr(os.path.join(UNIFI_CORE, "http"), ".conf")):
        txt = read_file(f)
        c = re.search(r"^\s*ssl_certificate\s+([^;\s]+)\s*;", txt, re.M)
        k = re.search(r"^\s*ssl_certificate_key\s+([^;\s]+)\s*;", txt, re.M)
        if c and k:
            cands.append((c.group(1), k.group(1)))
    y = read_file(os.path.join(UNIFI_CORE, "overrides", "local.yaml"))
    c = re.search(r"(/\S+\.(?:crt|pem))", y)
    k = re.search(r"(/\S+\.key)", y)
    if c and k:
        cands.append((c.group(1).strip("'\""), k.group(1).strip("'\"")))
    cands.append((os.path.join(UNIFI_CORE, "unifi-core.crt"), os.path.join(UNIFI_CORE, "unifi-core.key")))
    for crt in sorted(globr(UNIFI_CORE, ".crt", depth=3)):
        key = crt[:-4] + ".key"
        if os.path.exists(key):
            cands.append((crt, key))
    seen, out = set(), []
    for c, k in cands:
        if (c, k) in seen or not (os.path.isfile(c) and os.path.isfile(k)):
            continue
        seen.add((c, k))
        out.append((c, k))
    # предпочтение: не самоподписанный, с самым поздним сроком
    def score(ck):
        i = cert_info(ck[0]) or {}
        return (0 if i.get("self_signed", True) else 1, i.get("expires", 0))
    return sorted(out, key=score, reverse=True)


def globr(d, ext, depth=1):
    out = []
    try:
        for f in os.listdir(d):
            p = os.path.join(d, f)
            if os.path.isfile(p) and f.endswith(ext):
                out.append(p)
            elif os.path.isdir(p) and depth > 1:
                out += globr(p, ext, depth - 1)
    except OSError:
        pass
    return out


def pick_cert(c):
    """→ (crt, key, режим, предупреждение)."""
    mode = c.get("WEB_CERT", "auto")
    if mode not in ("auto", "unifi", "self"):
        k = c.get("WEB_KEY", "")
        if os.path.isfile(mode) and os.path.isfile(k):
            return mode, k, "file", ""
        return CERT_F, KEY_F, "self", "файлы WEB_CERT/WEB_KEY не найдены, используется самоподписанный"
    if mode in ("auto", "unifi"):
        for crt, key in unifi_cert_candidates():
            i = cert_info(crt) or {}
            if mode == "unifi" or not i.get("self_signed", True):
                return crt, key, "unifi", ""
        if mode == "unifi":
            return CERT_F, KEY_F, "self", "сертификат UniFi не найден, используется самоподписанный"
    return CERT_F, KEY_F, "self", ""


class CertWatch(threading.Thread):
    """Следит за файлами сертификата и перечитывает их без перезапуска (продление в UniFi подхватывается само)."""

    def __init__(self, ctx, crt, key):
        super().__init__(daemon=True)
        self.ctx, self.crt, self.key = ctx, crt, key
        self.mt = self.mtimes()

    def mtimes(self):
        try:
            return (os.stat(self.crt).st_mtime, os.stat(self.key).st_mtime)
        except OSError:
            return None

    def run(self):
        while True:
            time.sleep(int(os.environ.get("AWG_CERT_POLL", "60")))
            m = self.mtimes()
            if m and m != self.mt:
                time.sleep(3)           # дождаться записи обоих файлов
                try:
                    self.ctx.load_cert_chain(self.crt, self.key)
                    self.mt = self.mtimes()
                    sys.stderr.write("сертификат перечитан: %s\n" % self.crt)
                except (ssl.SSLError, OSError) as ex:
                    sys.stderr.write("сертификат не перечитан: %s\n" % ex)


# ======================================================================= настройки панели
def api_web_get(h, q):
    c = conf()
    info = h.server.cert_info or {}
    return {"port": c["WEB_PORT"], "bind": c["WEB_BIND"], "tls": c["WEB_TLS"], "allow": c["WEB_ALLOW"], "hosts": c.get("WEB_HOSTS", ""),
            "cert_mode": c.get("WEB_CERT", "auto"), "cert": info, "cert_used": h.server.cert_mode, "cert_warn": h.server.cert_warn,
            "unifi_certs": [dict(cert_info(cr) or {}, key=k) for cr, k in unifi_cert_candidates()[:5]], "lan": lan_ip()}


def port_busy(p):
    out = run(["ss", "-ltnH"], timeout=5)[1]
    return any(re.search(r"[:.]%d$" % p, line.split()[3]) for line in out.splitlines() if len(line.split()) > 3)


UNIFI_PORTS = {22, 53, 80, 443, 8080, 8443, 8444, 8880, 8843, 6789, 3478, 10001, 5514, 11443, 1900, 5671, 5656, 9543, 9090}


def api_web_set(h, d):
    c = conf()
    upd = {}
    p = str(d.get("port", c["WEB_PORT"])).strip()
    if not re.match(r"^\d{4,5}$", p) or not 1024 <= int(p) <= 65535 or int(p) in UNIFI_PORTS:
        raise ValueError("порт 1024–65535, не занятый службами UniFi (8443, 8080, 8880 и др.)")
    if p != c["WEB_PORT"] and port_busy(int(p)):
        raise ValueError("порт %s уже занят другой программой" % p)
    upd["WEB_PORT"] = p
    cm = str(d.get("cert_mode", c.get("WEB_CERT", "auto")))
    if cm not in ("auto", "unifi", "self"):
        raise ValueError("сертификат: auto, unifi или self")
    upd["WEB_CERT"] = cm
    hosts = v_domains(d.get("hosts", c.get("WEB_HOSTS", ""))) if str(d.get("hosts", "")).strip() else ""
    upd["WEB_HOSTS"] = hosts
    allow = str(d.get("allow", c["WEB_ALLOW"])).split()
    for n in allow:
        net = ipaddress.ip_network(n, strict=False)
        if not net.is_private and not net.is_loopback:
            raise ValueError("«%s»: разрешать можно только частные сети (панель не для интернета)" % n)
    if not allow:
        raise ValueError("нужна хотя бы одна сеть")
    upd["WEB_ALLOW"] = " ".join(allow)
    with LOCK:
        lines = read_file(CONF_F).splitlines()
        done = set()
        out = []
        for line in lines:
            m = re.match(r"^\s*([A-Z_]+)=", line)
            if m and m.group(1) in upd:
                out.append(fmt_env(m.group(1), upd[m.group(1)]))
                done.add(m.group(1))
            else:
                out.append(line)
        out += [fmt_env(k, v) for k, v in upd.items() if k not in done]
        write_secure(CONF_F, "\n".join(out) + "\n")
    h.act("web-settings", upd)
    threading.Thread(target=lambda: (time.sleep(1.5), run(["systemctl", "--no-block", "restart", "awg-web"], timeout=10)), daemon=True).start()
    scheme = "https" if c["WEB_TLS"] == "yes" else "http"
    return {"ok": True, "msg": "сохранено, панель перезапускается", "url": "%s://%s:%s/" % (scheme, h.headers.get("Host", "").rsplit(":", 1)[0] or lan_ip(), p)}


# ======================================================================= обновление из панели
UPD_LOG = os.path.join(DD, "update.log")


REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_./-]{0,99}$")


def channel():
    """(репозиторий, канал, ветка) — как в install.sh: stable по умолчанию, старый .channel с веткой не main → branch."""
    c = parse_env_text(read_file(os.path.join(DD, ".channel")))
    inst = read_file(os.path.join(DD, "install.sh"))
    m = re.search(r"AWG_REPO:-\$\{_ch_repo:-([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\}\}|^AWG_REPO=\$\{AWG_REPO:-([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\}", inst, re.M)
    repo = c.get("AWG_REPO") or (m and (m.group(1) or m.group(2))) or "stebasha/UDR-Amnezia"
    br = c.get("AWG_BRANCH") or "main"
    ch = c.get("AWG_CHANNEL") or ("branch" if br != "main" else "stable")
    if ch not in ("stable", "beta", "branch"):
        ch = "stable"
    if ch == "beta":
        br = "main"
    return repo, ch, br


def resolve_ref(repo, ch, br):
    """→ (ref, kind): тег последнего релиза для stable (нет релизов — main), иначе ветка."""
    if ch == "stable":
        rc, out = curl(["-f", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/%s/releases/latest" % repo], 20)
        try:
            data = json.loads(out) if rc == 0 else {}
        except ValueError:
            data = {}
        tag = str(data.get("tag_name", "")) if isinstance(data, dict) else ""
        if tag and REF_RE.match(tag) and ".." not in tag:
            return tag, "tag"
        return "main", "branch"
    ref = "main" if ch == "beta" else br
    if not REF_RE.match(ref) or ".." in ref:
        raise ValueError("недопустимое имя ветки: %s" % ref)
    return ref, "branch"


def api_update_check(h, d):
    repo, ch, br = channel()
    ref, kind = resolve_ref(repo, ch, br)
    rc, out = curl(["-f", "https://raw.githubusercontent.com/%s/%s/VERSION" % (repo, ref)], 15)
    cur = read_file(os.path.join(DD, "VERSION")).strip()
    new = out.strip() if rc == 0 and re.match(r"^[0-9][0-9A-Za-z.\-]{0,20}$", out.strip()) else ""
    rc2, chg = curl(["-f", "https://raw.githubusercontent.com/%s/%s/CHANGELOG.md" % (repo, ref)], 15)
    notes = ""
    if rc2 == 0 and new:
        m = re.search(r"^## %s\s*(?:\(.*?\))?\s*\n(.*?)(?=^## )" % re.escape(new), chg + "\n## ", re.M | re.S)
        notes = (m.group(1).strip() if m else "")[:6000]
    env_ = "AWG_CHANNEL=%s" % ch + (" AWG_BRANCH=%s" % br if ch == "branch" else "")
    return {"current": cur, "latest": new, "repo": repo, "channel": ch, "branch": br, "ref": ref, "kind": kind,
            "update": bool(new) and new != cur, "notes": notes, "running": update_running(),
            "cmd": "%s bash <(curl -fsSL https://raw.githubusercontent.com/%s/%s/install.sh) --update" % (env_, repo, ref)}


BINS_CACHE = {"t": 0, "latest": {}}
TAG_RE = re.compile(r"^v[0-9][0-9.]{0,30}$")


def bins_installed(name):
    """Тег установленной сборки: из .binsver (если сумма файла совпала), иначе из --version (#11)."""
    path = os.path.join(DD, name)
    for line in read_file(os.path.join(DD, ".binsver")).splitlines():
        p = line.split()
        if len(p) == 3 and p[0] == name and TAG_RE.match(p[1]):
            try:
                with open(path, "rb") as f:
                    if hashlib.sha256(f.read()).hexdigest() == p[2]:
                        return p[1]
            except OSError:
                pass
    rc, out = run([path, "--version"], timeout=5)
    m = re.search(r"v[0-9][0-9.]*", out or "")
    return m.group(0) if rc == 0 and m else ""


def bins_latest(repo):
    rc, out = curl(["-f", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/amnezia-vpn/%s/releases/latest" % repo], 20)
    try:
        x = json.loads(out) if rc == 0 else None
        tag = x.get("tag_name", "") if isinstance(x, dict) else ""
    except ValueError:
        tag = ""
    if not TAG_RE.match(tag or ""):
        rc, out = curl(["-f", "https://api.github.com/repos/amnezia-vpn/%s/tags?per_page=30" % repo], 20)
        try:
            x = json.loads(out) if rc == 0 else []
        except ValueError:
            x = []
        tags = [t.get("name", "") for t in x if isinstance(t, dict) and TAG_RE.match(t.get("name", ""))] if isinstance(x, list) else []
        tag = max(tags, key=vkey) if tags else ""
    return tag if TAG_RE.match(tag or "") else ""


def vkey(v):
    return tuple(int(x) for x in re.findall(r"[0-9]+", v))


def api_bins_check(h, d):
    """Сравнить amneziawg-go и awg с последними официальными релизами amnezia-vpn (#11). Ответ GitHub кешируется на час."""
    now = time.time()
    if d.get("force") or now - BINS_CACHE["t"] > 3600 or not all(BINS_CACHE["latest"].values()):
        BINS_CACHE["latest"] = {"amneziawg-go": bins_latest("amneziawg-go"), "awg": bins_latest("amneziawg-tools")}
        BINS_CACHE["t"] = now
    items, upd = [], False
    for name, src in (("amneziawg-go", "amneziawg-go"), ("awg", "amneziawg-tools")):
        cur, new = bins_installed(name), BINS_CACHE["latest"][name]
        st = "unknown" if not new else "nover" if not cur else "ok" if vkey(cur) >= vkey(new) else "update"
        upd = upd or st == "update"
        items.append({"name": name, "repo": "amnezia-vpn/" + src, "installed": cur, "latest": new, "state": st})
    return {"items": items, "update": upd, "checked": int(BINS_CACHE["t"]),
            "cmd": "%s/install.sh --bins-update" % DD}


def api_update_channel(h, d):
    ch = str(d.get("channel", ""))
    repo, cur, br = channel()
    if ch == "branch":
        br = str(d.get("branch", "")).strip()
        if not REF_RE.match(br) or ".." in br:
            raise ValueError("недопустимое имя ветки")
    elif ch not in ("stable", "beta"):
        raise ValueError("канал: stable, beta или своя ветка")
    if ch == "beta":
        br = "main"
    write_secure(os.path.join(DD, ".channel"), "AWG_REPO=%s\nAWG_CHANNEL=%s\nAWG_BRANCH=%s\n" % (repo, ch, br), 0o644)
    h.act("update-channel", {"channel": ch, "branch": br})
    return {"ok": True, "channel": ch, "branch": br, "msg": "канал обновлений: %s" % (ch if ch != "branch" else "ветка " + br)}


def update_running():
    return run(["systemctl", "is-active", "--quiet", "awg-update"], timeout=5)[0] == 0


def api_update_run(h, d):
    if update_running():
        raise ValueError("обновление уже идёт")
    repo, ch, br = channel()
    ref, kind = resolve_ref(repo, ch, br)
    write_secure(UPD_LOG, "%s обновление запущено из панели (%s, канал %s, %s %s)\n" % (time.strftime("%F %T"), repo, ch,
                 "релиз" if kind == "tag" else "ветка", ref), 0o600)
    # установщик берётся из той же версии, что и скрипты; AWG_REF фиксирует проверенный релиз (новый, вышедший между
    # проверкой и запуском, не подхватится незаметно)
    script = ('cd /; export AWG_YES=1 AWG_REPO="$1" AWG_CHANNEL="$2" AWG_BRANCH="$3" AWG_REF="$4" AWG_REF_KIND="$5"; '
              'f=$(mktemp); if curl -fsSL -m 120 "https://raw.githubusercontent.com/$1/$4/install.sh" -o "$f" && bash -n "$f"; then '
              'bash "$f" --update; rc=$?; else echo "не удалось скачать install.sh"; rc=1; fi; rm -f "$f"; echo "[код $rc]"; exit $rc')
    rc, out = run(["systemd-run", "--unit=awg-update", "--collect", "--quiet", "-p", "StandardOutput=append:" + UPD_LOG,
                   "-p", "StandardError=append:" + UPD_LOG, "/bin/bash", "-c", script, "awg-update", repo, ch, br, ref, kind], timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить обновление: " + out.strip()[:300])
    h.act("update-run", ref)
    return {"ok": True, "msg": "обновление запущено; панель перезапустится, страница переподключится сама"}


REBOOT_DELAY = 5


def api_system_reboot(h, d):
    """Перезагрузка роутера целиком (UniFi тоже). Только с паролем текущего пользователя; не во время обновления."""
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act("reboot-denied")
        raise ApiError(403, "текущий пароль неверен")
    if update_running():
        raise ValueError("идёт обновление набора: дождитесь его окончания, потом перезагружайте")
    rb = shutil.which("reboot") or "/sbin/reboot"
    rc, out = run(["systemd-run", "--unit=awg-reboot", "--collect", "--quiet", "--on-active=%d" % REBOOT_DELAY, rb], timeout=15)
    if rc != 0:
        raise ValueError("не удалось запланировать перезагрузку: " + out.strip()[:300])
    h.act("reboot", "через %d с" % REBOOT_DELAY)
    try:
        with open(os.path.join(DD, "events.log"), "a", encoding="utf-8") as f:
            f.write("%d|reboot|перезагрузка роутера из панели (%s)\n" % (now(), h.user))
    except OSError:
        pass
    if os.path.exists(os.path.join(DD, "telegram.env")) and os.access(os.path.join(DD, "notify.sh"), os.X_OK):
        run([os.path.join(DD, "notify.sh"), "--html", "🔁 <b>Перезагрузка роутера</b> · %s\nиз веб-панели, пользователь %s"
             % (html.escape(socket.gethostname()), html.escape(h.user))], timeout=8)
    return {"ok": True, "delay": REBOOT_DELAY,
            "msg": "роутер перезагрузится через %d с; интернет и UniFi вернутся через 2–4 минуты" % REBOOT_DELAY}


def api_update_log(h, q):
    t = read_file(UPD_LOG)
    return {"text": t[-60000:], "running": update_running(), "version": read_file(os.path.join(DD, "VERSION")).strip()}


# ======================================================================= резервные копии: проверка; экспорт настроек
def api_backup_verify(h, d):
    f = str(d.get("name", ""))
    if not BK_RE.match(f) or not os.path.exists(os.path.join(DD, "backups", f)):
        raise ApiError(404, "нет такой копии")
    pw = str(d.get("password", ""))
    if f.endswith(".enc") and not pw:
        raise ValueError("нужен пароль копии")
    h.act("backup-verify", f)
    rc, out = run([os.path.join(DD, "backup.sh"), "verify", os.path.join(DD, "backups", f)], timeout=120, env={"AWG_BACKUP_PASS": pw})
    return {"ok": rc == 0, "msg": out.strip()}


EXPORT_KEYS = list(SETTINGS)


def api_settings_export(h, q):
    e = env()
    h.act("settings-export")
    return {"format": "udr-amnezia-settings", "version": read_file(os.path.join(DD, "VERSION")).strip(), "time": now(),
            "settings": {k: e.get(k, DEFAULTS.get(k, "")) for k in EXPORT_KEYS}, "labels": labels(),
            "note": "без ключей, токенов и паролей; туннели переносятся отдельно (конфиги)"}


def api_settings_import(h, d):
    x = d.get("data") or {}
    if not isinstance(x, dict) or x.get("format") != "udr-amnezia-settings":
        raise ValueError("это не файл настроек UDR-Amnezia")
    vals = {k: v for k, v in (x.get("settings") or {}).items() if k in SETTINGS}
    r = api_settings_set(h, {"values": vals}) if vals else {"ok": True, "msg": "настроек нет"}
    labs = x.get("labels") or {}
    if isinstance(labs, dict):
        for t, lab in labs.items():
            if t in tunnels():
                try:
                    api_tunnel_label(h, {"name": t, "label": lab})
                except ValueError:
                    pass
    return r


# ======================================================================= ping / traceroute
def api_net_tool(h, d):
    kind = str(d.get("kind", ""))
    host = str(d.get("host", "")).strip()
    iface = str(d.get("iface", ""))
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not DOMAIN_RE.match(host):
            raise ValueError("укажите IP-адрес или имя хоста")
    e = env()
    if iface not in tunnels(e) + ["wan"]:
        raise ValueError("интерфейс: туннель или wan")
    dev = wan_if(e) if iface == "wan" else iface
    if kind == "ping":
        mode = str(d.get("mode", "auto"))
        if mode not in ("auto", "icmp", "tcp"):
            raise ValueError("способ: auto, icmp или tcp")
        # auto: ICMP, а если ни одного ответа (его часто режут провайдер или сервер туннеля) — время TCP-подключения
        cmd = [os.path.join(DD, "awgctl.sh"), "ping", mode, dev, host]
    elif kind == "trace":
        tr = shutil.which("traceroute") or shutil.which("tracepath")
        if not tr:
            raise ValueError("на роутере нет traceroute")
        cmd = [tr, "-i", dev, "-n", "-w", "2", "-q", "1", "-m", "20", host] if tr.endswith("traceroute") else [tr, "-n", host]
    else:
        raise ValueError("ping или trace")
    h.act("net-" + kind, {"host": host, "iface": dev})
    return {"job": JOBS.start(kind + host + dev, cmd, 90)}


ROUTES = {
    ("POST", "/api/logout"): api_logout,
    ("GET", "/api/overview"): api_overview,
    ("GET", "/api/live"): api_live,
    ("GET", "/api/history"): api_history,
    ("GET", "/api/events"): api_events,
    ("POST", "/api/tunnel/switch"): api_tunnel_switch,
    ("POST", "/api/tunnel/auto"): api_tunnel_auto,
    ("POST", "/api/tunnel/test"): api_tunnel_test,
    ("POST", "/api/tunnel/restart"): api_tunnel_restart,
    ("POST", "/api/tunnel/label"): api_tunnel_label,
    ("GET", "/api/tunnel/conf"): api_tunnel_conf_get,
    ("POST", "/api/tunnel/conf"): api_tunnel_conf_set,
    ("GET", "/api/tunnel/fields"): api_tunnel_fields_get,
    ("POST", "/api/tunnel/preview"): api_tunnel_preview,
    ("GET", "/api/tunnel/revisions"): api_tunnel_revisions,
    ("GET", "/api/tunnel/revision"): api_tunnel_revision,
    ("POST", "/api/tunnel/revision/restore"): api_tunnel_revision_restore,
    ("POST", "/api/tunnel/export"): api_tunnel_export,
    ("POST", "/api/tunnel/order"): api_tunnel_order,
    ("POST", "/api/import/parse"): api_import_parse,
    ("POST", "/api/import/apply"): api_import_apply,
    ("GET", "/api/speed"): api_speed,
    ("GET", "/api/health"): api_health,
    ("GET", "/api/clients"): api_clients,
    ("GET", "/api/sessions"): api_sessions,
    ("POST", "/api/session/revoke"): api_session_revoke,
    ("GET", "/api/web"): api_web_get,
    ("POST", "/api/web"): api_web_set,
    ("POST", "/api/update/run"): api_update_run,
    ("GET", "/api/update/log"): api_update_log,
    ("POST", "/api/backup/verify"): api_backup_verify,
    ("GET", "/api/settings/export"): api_settings_export,
    ("POST", "/api/settings/import"): api_settings_import,
    ("POST", "/api/net"): api_net_tool,
    ("POST", "/api/tunnel/add"): api_tunnel_add,
    ("POST", "/api/tunnel/remove"): api_tunnel_remove,
    ("GET", "/api/settings"): api_settings_get,
    ("POST", "/api/settings"): api_settings_set,
    ("GET", "/api/services"): api_services,
    ("POST", "/api/service"): api_service,
    ("POST", "/api/tool"): api_tool,
    ("GET", "/api/job"): api_job,
    ("GET", "/api/logs"): api_logs,
    ("GET", "/api/telegram"): api_tg_get,
    ("POST", "/api/telegram"): api_tg_set,
    ("POST", "/api/telegram/test"): api_tg_test,
    ("GET", "/api/backups"): api_backups,
    ("POST", "/api/backup/create"): api_backup_create,
    ("POST", "/api/backup/delete"): api_backup_delete,
    ("GET", "/api/users"): api_users,
    ("POST", "/api/passwd"): api_passwd,
    ("POST", "/api/user/delete"): api_user_delete,
    ("POST", "/api/totp/begin"): api_totp_begin,
    ("POST", "/api/totp/enable"): api_totp_enable,
    ("POST", "/api/totp/disable"): api_totp_disable,
    ("GET", "/api/system"): api_system,
    ("POST", "/api/update/check"): api_update_check,
    ("POST", "/api/bins/check"): api_bins_check,
    ("POST", "/api/update/channel"): api_update_channel,
    ("GET", "/api/ha"): api_ha_get,
    ("POST", "/api/ha"): api_ha_set,
    ("POST", "/api/ha/test"): api_ha_test,
    ("POST", "/api/system/reboot"): api_system_reboot,
    ("GET", "/api/tokens"): api_tokens,
    ("POST", "/api/token/create"): api_token_create,
    ("POST", "/api/token/revoke"): api_token_revoke,
}
def get_log_file(h, rest, q):
    k = (q.get("kind") or [""])[0]
    if k == "journal":
        text = run(["journalctl", "-u", "awg-*", "-n", "20000", "--no-pager", "-o", "short-iso"], timeout=30)[1]
    elif k == "audit":
        text = read_file(AUDIT_F)
    elif k == "events":
        text = "\n".join("%s  %-8s %s" % (time.strftime("%F %T", time.localtime(e["t"])), e["type"], e["text"]) for e in events(3000))
    elif k in LOGS:
        text = read_file(os.path.join(DD, LOGS[k]))
    else:
        return h.send(404, {"error": "нет такого журнала"})
    h.act("log-download", k)
    fn = "awg-%s-%s.log" % (k, time.strftime("%Y%m%d-%H%M%S"))
    return h.send(200, text, "text/plain; charset=utf-8", {"Content-Disposition": 'attachment; filename="%s"' % fn})


PREFIX_ROUTES = {("GET", "/api/history.csv"): get_history_csv, ("GET", "/api/backup/file"): get_backup_file, ("GET", "/api/report/file"): get_report_file,
                 ("GET", "/api/logs/file"): get_log_file}


# ======================================================================= сервер
class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):  # обрывы TLS и соединений не печатаем
        pass


def make_cert(ip=None):
    ip = ip or lan_ip()
    os.makedirs(WEBD, exist_ok=True)
    base = ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
            "-subj", "/CN=UDR-Amnezia panel", "-keyout", KEY_F, "-out", CERT_F]
    rc, out = run(base + ["-addext", "subjectAltName=IP:%s,DNS:localhost" % ip], timeout=60)
    if rc != 0:
        rc, out = run(base, timeout=60)
    if rc == 0:
        os.chmod(KEY_F, 0o600)
    return rc, out


def serve():
    c = conf()
    bind = c["WEB_BIND"]
    if bind == "auto":
        # после перезагрузки br0 может получить адрес позже службы: ждём до 3 минут, а не слушаем localhost
        for _ in range(90):
            bind = lan_ip()
            if bind != "127.0.0.1":
                break
            time.sleep(2)
    port = int(c["WEB_PORT"])
    httpd = Server((bind, port), Handler)
    httpd.allow = c["WEB_ALLOW"].split()
    httpd.hosts = [x.lower() for x in c.get("WEB_HOSTS", "").split()]
    httpd.tls = False
    httpd.cert_info, httpd.cert_mode, httpd.cert_warn, httpd.cert_names = None, "", "", ()
    if c["WEB_TLS"] == "yes":
        crt, key, mode, warn = pick_cert(c)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        if mode != "self":
            try:
                ctx.load_cert_chain(crt, key)
            except (ssl.SSLError, OSError) as ex:
                warn = "сертификат %s не подошёл (%s), используется самоподписанный" % (crt, ex)
                crt, key, mode = CERT_F, KEY_F, "self"
        if mode == "self" and not (os.path.exists(CERT_F) and os.path.exists(KEY_F)):
            make_cert(bind if bind != "0.0.0.0" else None)
        if os.path.exists(crt) and os.path.exists(key):
            if mode == "self":
                ctx.load_cert_chain(crt, key)
            httpd.cert_info, httpd.cert_mode, httpd.cert_warn = cert_info(crt), mode, warn
            httpd.cert_names = tuple(n.lower() for n in (httpd.cert_info or {}).get("names", []) if not n[0].isdigit())
            if warn:
                sys.stderr.write(warn + "\n")
            CertWatch(ctx, crt, key).start()
            # рукопожатие TLS — в потоке запроса, а не в accept(): медленный клиент не блокирует панель
            httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
            httpd.tls = True
        else:
            sys.stderr.write("нет сертификата и openssl: панель работает по HTTP (только в LAN)\n")
    SAMPLER.start()

    def stop(*_):
        SAMPLER.save()
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("awg-web %s: %s://%s:%d/ (пользователей: %d)" % (VERSION, "https" if httpd.tls else "http", bind, port, len(load_users())), flush=True)
    httpd.serve_forever()


def cli():
    a = sys.argv[1:] or ["serve"]
    cmd = a[0]
    if cmd == "serve":
        return serve()
    if cmd == "passwd":
        if len(a) < 2 or not USER_RE.match(a[1]):
            sys.exit("использование: panel.py passwd ИМЯ  (латиница, цифры, _.-)")
        if "--stdin" in a:
            pw = sys.stdin.readline().rstrip("\n")
        else:
            pw = getpass.getpass("Пароль для %s: " % a[1])
            if getpass.getpass("Повторите: ") != pw:
                sys.exit("пароли не совпадают")
        pr = pw_problem(pw)
        if pr:
            sys.exit(pr)
        u = load_users()
        rec = u.get(a[1], {})
        rec.update(hash_pw(pw))
        u[a[1]] = rec
        save_users(u)
        print("пароль пользователя %s сохранён" % a[1])
        return
    if cmd == "users":
        for k, v in sorted(load_users().items()):
            print(k, "(2FA)" if v.get("totp") else "")
        return
    if cmd == "deluser" and len(a) > 1:
        u = load_users()
        u.pop(a[1], None)
        save_users(u)
        print("удалён", a[1])
        return
    if cmd == "totp-off" and len(a) > 1:
        u = load_users()
        if a[1] in u:
            u[a[1]].pop("totp", None)
            save_users(u)
        print("второй фактор для %s выключен" % a[1])
        return
    if cmd == "cert":
        rc, out = make_cert()
        print(out.strip() or ("сертификат: %s" % CERT_F))
        sys.exit(rc)
    if cmd == "check":
        c = conf()
        print("порт %s, адрес %s, TLS %s, пользователей %d" % (c["WEB_PORT"], c["WEB_BIND"], c["WEB_TLS"], len(load_users())))
        return
    print(__doc__)


if __name__ == "__main__":
    cli()
