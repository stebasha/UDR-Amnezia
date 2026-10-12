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

VERSION = "1.3.0"
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

SERVICES = ["awg-failover", "awg-subnets", "awg-self", "awg-guard", "awg-notify", "awg-bot", "awg-metrics"]
SERVICE_INFO = {
    "awg-failover": "Сторож: маршрут в туннель, переключение каналов, kill switch",
    "awg-subnets": "Клиенты VPN-сервера роутера через туннель",
    "awg-self": "Трафик самого роутера и unifi.ui.com через туннель, домены для dnsmasq",
    "awg-guard": "Защита от утечек, домены через туннель и исключения",
    "awg-notify": "Уведомления в Telegram",
    "awg-bot": "Команды Telegram-бота",
    "awg-metrics": "Метрики Prometheus",
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
    if keys & {"s3", "s4", "i1", "i2", "headerprotectionkey"}:
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
    IDLE = 2 * 3600
    ABS = 12 * 3600

    def __init__(self):
        self.s = {}
        self.lock = threading.Lock()

    def new(self, user, ip):
        tok = secrets.token_urlsafe(32)
        with self.lock:
            self.s[tok] = {"user": user, "csrf": secrets.token_urlsafe(24), "ip": ip, "born": now(), "seen": now()}
        return tok

    def get(self, tok):
        with self.lock:
            x = self.s.get(tok or "")
            if not x:
                return None
            if now() - x["seen"] > self.IDLE or now() - x["born"] > self.ABS:
                del self.s[tok]
                return None
            x["seen"] = now()
            return x

    def drop(self, tok=None, user=None):
        with self.lock:
            for k in list(self.s):
                if k == tok or (user and self.s[k]["user"] == user):
                    del self.s[k]


SESS = Sessions()


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


# ======================================================================= сбор данных
class Sampler(threading.Thread):
    """Каждые 2 с: скорость по туннелям (10 минут в памяти); раз в минуту — точка истории (сутки)."""

    def __init__(self):
        super().__init__(daemon=True)
        self.live = collections.defaultdict(lambda: collections.deque(maxlen=300))
        self.prev = {}
        self.hist = {"points": []}
        self.acc = collections.defaultdict(lambda: [0, 0, 0])
        self.lock = threading.Lock()
        self.last_save = now()
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
                                "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, "")}
            self.hist["points"].append(pt)
            self.hist["points"] = self.hist["points"][-1440:]

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
    for e in ev:
        if e["type"] in ("switch", "degrade", "force"):
            if not on:
                on, st = True, e["t"]
        elif e["type"] in ("return", "auto", "start"):
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
        "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, ""), "dns": st.get("DNS_" + t, ""),
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
    level = "crit" if any(a[0] == "crit" for a in alerts) else ("warn" if alerts else "ok")
    try:
        up = int(float(read_file("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        up = 0
    load = read_file("/proc/loadavg").split()[:3]
    mem = parse_meminfo()
    return {
        "host": socket.gethostname(), "version": read_file(os.path.join(DD, "VERSION")).strip() or VERSION,
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
                "/favicon.svg": ("favicon.svg", "image/svg+xml")}
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
        if h in ("localhost",) or h in self.server.hosts:
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
            if not s:
                return self.send(401, {"error": "нужен вход"})
            if method == "POST":
                if not self.same_origin() or not hmac.compare_digest(self.headers.get("X-CSRF", ""), s["csrf"]):
                    return self.send(403, {"error": "проверка CSRF не пройдена: обновите страницу"})
            self.user = s["user"]
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
        tok = SESS.new(u, ip)
        audit(u, ip, "login")
        ck = "awgsid=%s; HttpOnly; SameSite=Strict; Path=/%s" % (tok, "; Secure" if self.server.tls else "")
        return self.send(200, {"user": u, "csrf": SESS.get(tok)["csrf"]}, headers={"Set-Cookie": ck})


# ======================================================================= API
def api_logout(h, d):
    SESS.drop(tok=h.cookie("awgsid"))
    h.act("logout")
    return {"ok": True}


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


def api_history(h, q):
    return {"points": SAMPLER.history()}


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
    for _ in range(20):
        time.sleep(0.5)
        if state().get("ACTIVE") == t:
            return {"ok": True, "msg": "активен %s (выбран вручную). Вернуть автоматику: «Авто»" % t}
    st = state().get("ACTIVE", "?")
    return {"ok": False, "msg": "не переключилось за 10 с (сейчас %s): канал %s не отвечает или сторож не запущен" % (st, t)}


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


def save_conf(t, text, cp):
    old = read_file(cp)
    text = unmask_conf(text, old) if MASK in text else text.replace("\r", "")
    errs = check_conf(text)
    if errs:
        raise ValueError("конфиг не принят: " + "; ".join(errs))
    if old:
        write_secure(cp + ".prev", old)
    write_secure(cp, text)
    return old


def api_tunnel_conf_set(h, d):
    t = get_tunnel(str(d.get("name", "")))
    cp = conf_path(t)
    with LOCK:
        old = save_conf(t, str(d.get("text", "")), cp)
        rc, out = run([os.path.join(DD, "up.sh"), t], timeout=60)
        if rc != 0 and old:
            write_secure(cp, old)
            run([os.path.join(DD, "up.sh"), t], timeout=60)
            h.act("conf-set-failed", t)
            return {"ok": False, "msg": "туннель с новым конфигом не поднялся, возвращён прежний:\n" + out.strip()}
    h.act("conf-set", t)
    time.sleep(4)
    hs = hs_age(t)
    return {"ok": True, "msg": out.strip() + ("\nhandshake: %d с назад" % hs if hs >= 0 else "\nhandshake пока нет: проверьте через несколько секунд (Тест)"),
            "prev": os.path.basename(cp) + ".prev"}


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
        errs = check_conf(text)
        if errs:
            raise ValueError("конфиг не принят: " + "; ".join(errs))
        write_secure(cp, text)
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
    with LOCK:
        if a == "restart":
            rc, out = run(["systemctl", "restart", u], timeout=60)
        elif a == "enable":
            rc, out = unit_on(u)
        else:
            unit_off(u)
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


LOGS = {"failover": "failover.log", "notify": "notify.log", "bot": "bot.log", "install": "install.log", "restore": "restore.log"}


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


def api_tg_get(h, q):
    t = parse_env_text(read_file(os.path.join(DD, "telegram.env")))
    tok = t.get("TG_TOKEN", "")
    return {"configured": bool(tok), "token": (tok.split(":")[0] + ":…" + tok[-4:]) if tok else "", "chat": t.get("TG_CHAT", ""),
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
    chat = str(d.get("chat", t.get("TG_CHAT", ""))).strip()
    if not re.match(r"^-?\d{1,20}$", chat):
        raise ValueError("chat id — число")
    rt = str(d.get("report_time", t.get("REPORT_TIME", "0900"))).strip().replace(":", "")
    if not re.match(r"^([01]\d|2[0-3])[0-5]\d$", rt):
        raise ValueError("время отчёта: ЧЧММ, например 0900")
    lines = ["TG_TOKEN=%s" % t["TG_TOKEN"], "TG_CHAT=%s" % chat, "REPORT_TIME=%s" % rt]
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
    h.act("telegram-set", {"chat": chat, "report_time": rt})
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
            "tls": h.server.tls, "data_free_mb": disk_free_mb()}


def api_update_check(h, d):
    m = re.search(r"^AWG_REPO=\$\{AWG_REPO:-([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\}", read_file(os.path.join(DD, "install.sh")), re.M)
    repo = m.group(1) if m else "stebasha/UDR-Amnezia"
    rc, out = curl(["-f", "https://raw.githubusercontent.com/%s/main/VERSION" % repo], 15)
    cur = read_file(os.path.join(DD, "VERSION")).strip()
    new = out.strip() if rc == 0 and re.match(r"^[0-9][0-9A-Za-z.\-]{0,20}$", out.strip()) else ""
    return {"current": cur, "latest": new, "repo": repo, "update": bool(new) and new != cur,
            "cmd": "bash <(curl -fsSL https://raw.githubusercontent.com/%s/main/install.sh) --update" % repo}


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
}
PREFIX_ROUTES = {("GET", "/api/backup/file"): get_backup_file, ("GET", "/api/report/file"): get_report_file}


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
    bind = lan_ip() if c["WEB_BIND"] == "auto" else c["WEB_BIND"]
    port = int(c["WEB_PORT"])
    httpd = Server((bind, port), Handler)
    httpd.allow = c["WEB_ALLOW"].split()
    httpd.hosts = [x.lower() for x in c.get("WEB_HOSTS", "").split()]
    httpd.tls = False
    if c["WEB_TLS"] == "yes":
        if not (os.path.exists(CERT_F) and os.path.exists(KEY_F)):
            make_cert(bind if bind != "0.0.0.0" else None)
        if os.path.exists(CERT_F) and os.path.exists(KEY_F):
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(CERT_F, KEY_F)
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
