# -*- coding: utf-8 -*-
"""Основа: пути, утилиты, проверка ввода, службы, пользователи и вход, токены, ограничения, здоровье роутера."""

import base64
import collections
import fcntl
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

VERSION = "1.10.0"
DD = os.environ.get("DD", "/data/awg")
WEBD = os.environ.get("AWG_WEBD", os.path.join(DD, "web"))
STATIC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static")
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
        # своя группа процессов: по истечении срока завершаются и потомки (curl, ping), а не только сама команда
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, start_new_session=True,
                             stdin=subprocess.PIPE if inp is not None else subprocess.DEVNULL)
    except OSError as ex:
        return 127, str(ex)
    try:
        out = p.communicate(inp.encode() if isinstance(inp, str) else inp, timeout=timeout)[0]
        return p.returncode, ANSI.sub("", out.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        stop_group(p)
        try:
            p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return 124, "превышено время ожидания (%d с)" % timeout


def stop_group(p, grace=3):
    """Завершить команду вместе с потомками: сначала TERM (скрипт успеет вернуть конфиг туннеля — у mtu.sh, подбора
    обфускации обработчики на TERM), через grace секунд — KILL всей группе."""
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except OSError:
        p.terminate()
    try:
        p.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(p.pid, signal.SIGKILL)       # потомки (curl, ping) могли остаться и после выхода самой команды
    except OSError:
        pass


def up_tunnel(t, timeout=60, wait=30):
    """Поднять (перезапустить) туннель через up.sh под тем же замком, что берут сторож и подбор параметров
    (/run/awg-up-ИМЯ.lock): иначе два up.sh одновременно мешают друг другу (ip link add/del)."""
    try:
        f = open(os.path.join(RUN, "awg-up-%s.lock" % t), "w")
    except OSError:
        return run([os.path.join(DD, "up.sh"), t], timeout=timeout)
    with f:
        end = time.time() + wait
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.time() > end:
                    return 1, "туннель %s сейчас перезапускает другая служба — повторите позже" % t
                time.sleep(0.3)
        return run([os.path.join(DD, "up.sh"), t], timeout=timeout)


def url_origin(u):
    """(схема, узел, порт) адреса: сохранённый секрет (токен, заголовок) идёт только туда же, куда шёл раньше."""
    try:
        x = urllib.parse.urlparse(str(u or ""))
        return (x.scheme.lower(), (x.hostname or "").lower(), x.port or {"https": 443, "http": 80}.get(x.scheme.lower()))
    except ValueError:
        return ("", "", None)


def keep_secret(old_url, new_url, what):
    """Прежний секрет можно оставить, только если адрес ведёт туда же (схема, узел, порт). Иначе — ввести заново:
    смена адреса с сохранённым токеном отправила бы его на новый узел (украденная сессия панели → чужой сервер)."""
    if url_origin(old_url) != url_origin(new_url):
        raise ValueError("адрес сменился: введите %s заново (прежний на другой узел не отправляется)" % what)


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


_ENVC = {}


def env():
    """awg.env как словарь. Разбирается заново только при изменении текста (сборщик читает его каждые 2 с,
    обзор — по несколько раз за запрос). Возвращается копия: вызывающий может её менять."""
    text = read_file(os.path.join(DD, "awg.env"))
    c = _ENVC.get("v")
    if not c or c[0] != text:
        c = (text, parse_env_text(text))
        _ENVC["v"] = c
    return dict(c[1])


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
    """Строка KEY=значение для файлов, которые читает bash (source). Значение с символами, которые bash раскрыл бы
    внутри кавычек, не записывается никогда — даже если проверка конкретной настройки что-то пропустила."""
    v = str(v)
    if not re.match(r"^[A-Z_][A-Z0-9_]*$", str(k)) or re.search(r'["$`\\\x00-\x08\x0a-\x1f\x7f]', v):
        raise ValueError("недопустимое значение для %s" % k)
    if not re.match(r"^[A-Za-z0-9_./:@%+,=-]+$", v):       # пусто, пробелы, ; & | < > ( ) * ? и т. п. — только в кавычках
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
    if is_xray(t):
        return chk_age(t)
    rc, out = run([os.path.join(DD, "awg"), "show", t, "latest-handshakes"], timeout=5)
    try:
        ts = int(out.split()[1])
    except (IndexError, ValueError):
        return -1
    return -1 if ts == 0 else max(0, now() - ts)


XD = os.path.join(DD, "xray")      # VLESS через Xray (#42): бинарник, подписки, конфиги туннелей


def xray_tunnels(e=None):
    """Туннели VLESS (Xray, #42) — из XRAY_TUNNELS в awg.env. У них нет конфига AmneziaWG и handshake."""
    return [x for x in (e or env()).get("XRAY_TUNNELS", "").split() if NAME_RE.match(x)]


def is_xray(t, e=None):
    return t in xray_tunnels(e)


def wg_only(t):
    """Действие только для туннелей AmneziaWG (конфиг, история, подбор обфускации, MTU)."""
    if is_xray(t):
        raise ValueError("%s — туннель VLESS: его сервер и параметры — в «Туннели → VLESS», конфига AmneziaWG у него нет" % t)
    return t


def chk_age(t):
    """VLESS (#42): вместо handshake — возраст последней успешной проверки сторожем (файл awg-chk-ИМЯ в /run). → сек | -1"""
    try:
        ts = int(read_file(os.path.join(RUN, "awg-chk-" + t)).strip() or 0)
    except ValueError:
        return -1
    return max(0, now() - ts) if ts else -1


def hs_all():
    """Возраст handshake всех туннелей одним вызовом awg (у интерфейса с несколькими peer — самый свежий). → {имя: сек | -1}
    У туннелей VLESS (#42) — возраст последней успешной проверки сторожем."""
    out = run([os.path.join(DD, "awg"), "show", "all", "latest-handshakes"], timeout=5)[1]
    res = {t: chk_age(t) for t in xray_tunnels()}
    for line in out.splitlines():
        p = line.split()
        if len(p) < 3 or not p[2].isdigit():
            continue
        ts = int(p[2])
        age = -1 if ts == 0 else max(0, now() - ts)
        if p[0] not in res or (age >= 0 and (res[p[0]] < 0 or age < res[p[0]])):
            res[p[0]] = age
    return res


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


def svc_states(units):
    """Активность нескольких служб одним вызовом systemctl (по строке на службу, в том же порядке). → {служба: bool}"""
    units = list(units)
    out = run(["systemctl", "is-active"] + units, timeout=8)[1].split()
    if len(out) != len(units):          # непривычный ответ — по одной, как раньше
        return {u: svc_active(u) for u in units}
    return {u: out[i] == "active" for i, u in enumerate(units)}


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


AUDIT_MAX = int(os.environ.get("AWG_AUDIT_MAX", 512 * 1024))


def audit_text():
    """Журнал действий: предыдущий файл (после ротации) и текущий."""
    return read_file(AUDIT_F + ".1") + read_file(AUDIT_F)


def audit(user, ip, action, detail=""):
    line = "%s %s %s %s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), ip, user or "-", action,
                                  json.dumps(detail, ensure_ascii=False) if detail else "")
    try:
        os.makedirs(WEBD, exist_ok=True)
        with open(AUDIT_F, "a", encoding="utf-8") as f:
            f.write(line)
        os.chmod(AUDIT_F, 0o600)
        if os.path.getsize(AUDIT_F) > AUDIT_MAX:     # ротация (#21): прежний журнал целиком в audit.log.1
            os.replace(AUDIT_F, AUDIT_F + ".1")
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


def v_countries(v):
    out = []
    for x in str(v).replace(",", " ").replace(";", " ").split():
        x = x.strip().lower()
        if not re.match(r"^[a-z]{2}$", x):
            raise ValueError("«%s» — не код страны (две латинские буквы: ru, cn, by, kz)" % x)
        if x not in out:
            out.append(x)
    return " ".join(out)


def v_ports(v):
    out = []
    for x in str(v).replace(",", " ").split():
        if not re.match(r"^\d{1,5}$", x) or not 1 <= int(x) <= 65535:
            raise ValueError("«%s» — не порт (1–65535)" % x[:20])
        if x not in out:
            out.append(x)
    return " ".join(out)


def v_https_urls(v):
    out = []
    for x in str(v).split():
        u = urllib.parse.urlparse(x)
        if u.scheme != "https" or not u.hostname or not DOMAIN_RE.match(u.hostname) or any(c in x for c in "\"'`$;|&<>"):
            raise ValueError("«%s» — нужен адрес https://" % x[:80])
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
    "CHECK_RX_MIN": (v_int(0, 104857600), ["awg-failover"], "Трафик из туннеля за проход, при котором проверка не нужна, байт"),
    "CHECK_MAX_AGE": (v_int(10, 3600), ["awg-failover"], "Настоящая проверка канала не реже, с"),
    "RECHECK_AFTER": (v_int(0, 3600), ["awg-failover"], "Недоступный приоритетный канал проверять реже через, с"),
    "RECHECK_SLOW": (v_int(5, 600), ["awg-failover"], "Тогда проверять раз в, с"),
    "RECHECK_MAX": (v_int(5, 3600), ["awg-failover"], "После 10 минут — раз в, с"),
    "EXTRA_SUBNETS": (v_subnets, ["awg-subnets", "awg-guard"], "Подсети VPN-сервера роутера"),
    "TUN_DOMAINS": (v_domains, ["awg-self", "awg-guard"], "Сайты через туннель (даже из выбранных стран)"),
    "TUN_CLIENTS": (v_hosts, ["awg-guard"], "Для кого сайты через туннель без PBR (пусто — LAN и клиенты VPN-сервера)"),
    "DIRECT_DOMAINS": (v_domains, ["awg-self", "awg-guard"], "Сайты напрямую (даже иностранные)"),
    "DIRECT_SUBNETS": (v_subnets, ["awg-guard"], "Подсети напрямую (исключения)"),
    "LEAK_GUARD": (v_choice("yes", "no"), ["awg-guard"], "Защита от утечек"),
    "LEAK_V6": (v_choice("block", "off", "route"), ["awg-guard", "awg-failover"], "IPv6 устройств под PBR"),
    "LISTS_MODE": (v_choice("off", "blocked", "geoip"), ["awg-guard"], "Что идёт через туннель"),
    "GEO_COUNTRIES": (v_countries, ["awg-guard"], "Страны напрямую (GeoIP)"),
    "LIST_URLS": (v_https_urls, ["awg-guard"], "Источники списков заблокированного"),
    "DNS_INTERCEPT": (v_choice("yes", "no"), ["awg-guard"], "Перехват DNS устройств"),
    "DNS_CLIENTS": (v_hosts, ["awg-guard"], "Для каких клиентов (пусто — вся LAN)"),
    "DNS_BLOCK_DOT": (v_choice("yes", "no"), ["awg-guard"], "Запретить DNS-over-TLS и DNS по IPv6 мимо роутера"),
    "TRAFFIC_ACCT": (v_choice("yes", "no"), [], "Учёт трафика по устройствам"),
    "AUTO_TUNE": (v_choice("yes", "no"), [], "Автоподбор обфускации при деградации"),
    "UI_FIX": (v_choice("yes", "no"), ["awg-self"], "unifi.ui.com через туннель"),
    "UI_DOMAINS": (v_domains, ["awg-self"], "Домены UniFi"),
    "UI_DNS": (v_ipv4, ["awg-self"], "DNS для доменов UniFi"),
    "DNS_ALL_TUNNEL": (v_choice("yes", "no"), ["awg-self"], "Весь DNS роутера через туннель"),
    "METRICS_PORT": (v_int(1024, 65535, True), ["awg-metrics"], "Порт метрик Prometheus"),
    "SEC_PROTECT": (v_choice("yes", "no"), ["awg-guard"], "Защита входящих из интернета"),
    "SEC_GEO_ALLOW": (v_countries, ["awg-guard"], "Разрешённые страны"),
    "SEC_GEO_PORTS": (v_ports, ["awg-guard"], "Порты только из разрешённых стран"),
    "SEC_TRAP": (v_choice("yes", "no"), ["awg-guard"], "Блокировать сканеры (порты-ловушки)"),
    "SEC_TRAP_PORTS": (v_ports, ["awg-guard"], "Порты-ловушки"),
    "SEC_RATE": (v_int(0, 6000), ["awg-guard"], "Блокировать подбор паролей: новых соединений в минуту больше"),
    "SEC_BAN_HOURS": (v_int(1, 720), ["awg-guard"], "Блокировка на, ч"),
    "SEC_ALLOW_IPS": (v_hosts, ["awg-guard"], "Адреса, которые не блокируются никогда"),
}
DEFAULTS = {"RECOVER_SEC": "600", "QUALITY": "yes", "QUALITY_LOSS": "40", "QUALITY_RTT": "0", "MIN_DWELL": "120",
            "CHECK_RX_MIN": "65536", "CHECK_MAX_AGE": "60", "RECHECK_AFTER": "120", "RECHECK_SLOW": "30", "RECHECK_MAX": "60",
            "LEAK_GUARD": "no", "LEAK_V6": "block", "UI_FIX": "no", "UI_DOMAINS": "ui.com", "UI_DNS": "9.9.9.9",
            "DNS_ALL_TUNNEL": "no", "LISTS_MODE": "off", "DNS_INTERCEPT": "no", "DNS_BLOCK_DOT": "no", "TRAFFIC_ACCT": "no", "AUTO_TUNE": "no",
            "SEC_PROTECT": "no", "SEC_TRAP": "yes", "SEC_RATE": "30", "SEC_BAN_HOURS": "24",
            "SEC_TRAP_PORTS": "23 135 139 445 1433 2323 3306 3389 5432 5900 6379 7547 8291 9200 27017"}


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
                                                          + e.get("DIRECT_SUBNETS", "")).strip())
                     or e.get("LISTS_MODE", "off") != "off" or e.get("DNS_INTERCEPT") == "yes" or e.get("SEC_PROTECT") == "yes",
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
            if u == "awg-failover":              # сторожа дополнительных маршрутов (#22) — с теми же настройками
                for r in units_list():
                    if r.startswith("awg-failover-"):
                        rc, out = run(["systemctl", "restart", r], timeout=30)
                        msgs.append("%s: %s" % (r, "перезапущена" if rc == 0 else "ошибка: " + out.strip()[:200]))
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


_DUMMY = {}


def dummy_pw():
    """Запись с паролем, который никто не знает, — та же стоимость проверки, что у настоящей (считается один раз)."""
    if not _DUMMY:
        _DUMMY.update(hash_pw(secrets.token_hex(16)))
    return _DUMMY


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
    IDLE = 2 * 3600          # по умолчанию; настраивается в web.conf: WEB_SESSION_IDLE (минуты), WEB_SESSION_MAX (часы) — #21
    ABS = 12 * 3600
    SAVE_EVERY = 60          # отметку «последняя активность» сбрасываем на диск не чаще раза в минуту
    _lim = (0, None)

    def limits(self):
        t = now()
        if t - self._lim[0] > 5:
            c = parse_env_text(read_file(CONF_F))
            idle, mx = c.get("WEB_SESSION_IDLE", ""), c.get("WEB_SESSION_MAX", "")
            idle = int(idle) * 60 if idle.isdigit() and 5 <= int(idle) <= 1440 else self.IDLE
            mx = int(mx) * 3600 if mx.isdigit() and 1 <= int(mx) <= 720 else self.ABS
            self._lim = (t, (idle, max(mx, idle)))
        return self._lim[1]

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
        idle, mx = self.limits()
        return t - x["seen"] <= idle and t - x["born"] <= mx

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
            self.s[self.key(tok)] = {"user": user, "csrf": secrets.token_urlsafe(24), "ip": ip, "born": now(), "seen": now(), "ua": ua[:160],
                                     "pw": self.pw_mark(user)}
            self.save()
        return tok

    @staticmethod
    def pw_mark(user):
        """Отпечаток пароля пользователя (или None, если его нет): смена пароля или удаление — в том числе из командной
        строки (panel.py passwd / deluser), мимо панели — завершает его сеансы."""
        rec = load_users().get(user)
        return hashlib.sha256(str(rec.get("hash", "")).encode()).hexdigest()[:16] if isinstance(rec, dict) else None

    def get(self, tok):
        k = self.key(tok)
        with self.lock:
            x = self.s.get(k) if tok else None
            if not x:
                return None
            m = self.pw_mark(x["user"])
            if m is None or ("pw" in x and x["pw"] != m):
                del self.s[k]
                self.save()
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
              "/api/backup/file", "/api/backup/create", "/api/backup/delete", "/api/backup/verify", "/api/telegram", "/api/ha",
              "/api/backup/auto", "/api/backup/auto/run", "/api/backup/auto/test", "/api/hooks", "/api/hooks/test",
              "/api/vps", "/api/vps/test", "/api/vps/status", "/api/vps/versions", "/api/vps/run", "/api/vps/job",
              "/api/xui", "/api/xui/test", "/api/xui/create", "/api/xui/remove", "/api/xui/panel/remove", "/api/xui/inbounds",
              "/api/xui/import", "/api/xui/link", "/api/xui/sync", "/api/vps/del", "/api/route/save", "/api/route/remove",
              "/api/tune/run", "/api/tune/apply",
              # куда идёт трафик: конфиг туннеля (Endpoint, ключи), новый туннель, откат конфига — только при входе по паролю.
              # Иначе утёкший токен (из Home Assistant, скрипта) мог бы направить трафик устройств под PBR на чужой сервер.
              "/api/tunnel/conf", "/api/tunnel/add", "/api/import/apply", "/api/tunnel/revision/restore"}


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


class Rate:
    """Ограничение частоты API с одного адреса (#21): скользящее окно 60 с, отдельно все запросы и изменения (POST).
    Лимиты — WEB_RATE и WEB_RATE_POST в web.conf (запросов в минуту), читаются при запуске панели."""

    def __init__(self):
        c = parse_env_text(read_file(CONF_F))
        self.lim = int(c["WEB_RATE"]) if c.get("WEB_RATE", "").isdigit() and int(c["WEB_RATE"]) >= 10 else 1200
        self.lim_post = int(c["WEB_RATE_POST"]) if c.get("WEB_RATE_POST", "").isdigit() and int(c["WEB_RATE_POST"]) >= 5 else 240
        self.q = {}
        self.lock = threading.Lock()

    def allow(self, ip, post):
        t = time.time()
        with self.lock:
            a, b = self.q.setdefault(ip, (collections.deque(), collections.deque()))
            for d in (a, b):
                while d and d[0] < t - 60:
                    d.popleft()
            if len(a) >= self.lim or (post and len(b) >= self.lim_post):
                return int(61 - (t - (b[0] if post and len(b) >= self.lim_post else a[0])))
            a.append(t)
            if post:
                b.append(t)
            if len(self.q) > 1000:          # память: забыть адреса без запросов за минуту
                for k in [k for k, (x, _) in self.q.items() if not x]:
                    self.q.pop(k, None)
        return 0


RATE = Rate()


def need_pw(h, d, what):
    """Опасные действия — только с паролем текущего пользователя (как перезагрузка), #21."""
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act(what + "-denied")
        raise ApiError(403, "текущий пароль неверен")


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


_KE = {"t": 0.0, "v": None}


def kernel_events():
    """OOM и ошибки ввода-вывода за сутки из журнала ядра (если доступен). Журнал за сутки читается не чаще раза
    в 5 минут: бот проверяет здоровье каждую минуту, панель — при каждом открытии страницы."""
    if _KE["v"] is not None and time.time() - _KE["t"] < 300:
        return _KE["v"]
    _KE["v"], _KE["t"] = _kernel_events(), time.time()
    return _KE["v"]


def _kernel_events():
    rc, out = run(["journalctl", "-k", "--since", "-24h", "-q", "--no-pager", "-o", "cat"], timeout=10)
    if rc != 0:
        return {"oom": -1, "io": -1, "lines": []}
    # одно завершение — одна строка «Killed process» (вокруг неё ядро пишет ещё 2–3 строки про OOM: их не считаем).
    # «Memory cgroup out of memory» — служба упёрлась в свой собственный лимит (так бывает у UniFi Network, Java):
    # это не нехватка памяти роутера, другие процессы не затронуты.
    kills = []
    for l in out.splitlines():
        m = re.search(r"(Memory cgroup out of memory|Out of memory)[^:]*: Killed process \d+ \(([^)]*)\)", l)
        if m:
            kills.append({"cg": m.group(1).startswith("Memory cgroup"), "name": m.group(2), "line": l})
    io = [l for l in out.splitlines() if re.search(r"I/O error|EXT4-fs error|UBIFS error|squashfs error|Buffer I/O", l)]
    return {"oom": len(kills), "oom_sys": sum(not k["cg"] for k in kills),
            "oom_cg": collections.Counter(k["name"] for k in kills if k["cg"]),
            "oom_sys_names": collections.Counter(k["name"] for k in kills if not k["cg"]),
            "io": len(io), "lines": ([k["line"] for k in kills] + io)[-6:]}


def system_health(cpu=None, hist=None, procs=True):
    """Показатели железа и проверки с понятным текстом: что не так и что делать.
    procs=False — без списка процессов (обход /proc): боту, который проверяет здоровье каждую минуту, он не нужен."""
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
    procs, nproc = top_procs() if procs else ([], 0)
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
    if ke.get("oom_sys", ke["oom"]) > 0:
        names = ", ".join("%s ×%d" % kv for kv in (ke.get("oom_sys_names") or {}).items())
        ck("oom", "warn", "За сутки памяти роутера не хватило %d раз, ядро завершало процессы%s" % (ke.get("oom_sys", ke["oom"]), ": " + names if names else ""),
           "журнал: journalctl -k | grep -i 'Killed process'")
    for name, n in sorted((ke.get("oom_cg") or {}).items()):
        ck("oomcg-" + name, "info", "Процесс %s %d раз упирался в свой лимит памяти и перезапускался" % (name, n),
           "это лимит самой службы (у unifi — приложение UniFi Network), а не нехватка памяти роутера; если часто — перезапустите UniFi Network или обновите прошивку")
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


# ======================================================================= HTTP
def conf():
    c = {"WEB_PORT": "4443", "WEB_BIND": "auto", "WEB_TLS": "yes", "WEB_ALLOW": "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8"}
    c.update(parse_env_text(read_file(CONF_F)))
    return c


def lan_ip():
    out = run(["ip", "-4", "-o", "addr", "show", "dev", "br0"], timeout=5)[1]
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else "127.0.0.1"


class ApiError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg



# ======================================================================= Home Assistant (#5)
HA_F = os.path.join(DD, "ha.env")


HOOKS_F = os.path.join(DD, "hooks.env")


def notify_configured():
    t = parse_env_text(read_file(os.path.join(DD, "telegram.env")))
    k = parse_env_text(read_file(HOOKS_F))
    return bool(t.get("TG_TOKEN") or k.get("HOOK_URL") or k.get("NTFY_URL"))


BK_RE = re.compile(r"^[A-Za-z0-9._-]{1,80}\.(tgz|tgz\.enc)$")
