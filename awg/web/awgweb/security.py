# -*- coding: utf-8 -*-
"""Безопасность (1.10): разбор того, что роутер открыл в интернет и кто туда стучится, с понятными советами.
Только чтение: проброс портов, что принимает WAN, счётчики правил UniFi, SSH, UPnP, IPS/honeypot, журнал входов,
текущие соединения с WAN. Настройки UniFi не меняются: что поменять там — в советах. Своя защита входящих
(sec.sh: только из разрешённых стран, ловушки для сканеров, блокировка подбора) — по желанию, настройки SEC_*."""
from .vless import *  # noqa: F401,F403  (всё из предыдущих модулей)
import ipaddress as _ip

SEC_LOG = os.path.join(DD, "sec", "bans.log")
EVE_F = os.environ.get("AWG_EVE", "/run/ips/eve_alert.json")
AUTH_LOG = os.environ.get("AWG_AUTHLOG", "/var/log/auth.log")
SSHD_CONF = os.environ.get("AWG_SSHD", "/etc/ssh/sshd_config")
HONEY_F = os.environ.get("AWG_HONEY", "/run/utm/honeypot.conf")
_SEC_CACHE = {"t": 0, "v": None}
# что обычно стоит за портом: (название, вид). Вид: admin — вход в управление (опасно открывать всем),
# login — вход по паролю (подбор), mail — приём почты (нужен всем), web — сайт / Let's Encrypt, media — Plex и т. п.
PORT_KIND = {
    22: ("SSH", "admin"), 23: ("Telnet", "admin"), 3389: ("RDP (удалённый рабочий стол)", "admin"), 5900: ("VNC", "admin"),
    5000: ("Synology DSM (HTTP)", "admin"), 5001: ("Synology DSM (HTTPS)", "admin"), 8080: ("веб-панель", "admin"),
    8443: ("веб-панель (HTTPS)", "admin"), 8123: ("Home Assistant", "admin"), 9000: ("веб-панель", "admin"),
    10000: ("Webmin", "admin"), 445: ("SMB (общие папки)", "admin"), 139: ("NetBIOS", "admin"), 21: ("FTP", "login"),
    3306: ("MySQL", "admin"), 5432: ("PostgreSQL", "admin"), 6379: ("Redis", "admin"), 27017: ("MongoDB", "admin"),
    25: ("SMTP — приём почты", "mail"), 465: ("SMTP с паролем (SSL)", "login"), 587: ("SMTP с паролем", "login"),
    993: ("IMAP (SSL)", "login"), 143: ("IMAP", "login"), 995: ("POP3 (SSL)", "login"), 110: ("POP3", "login"),
    80: ("HTTP", "web"), 443: ("HTTPS", "web"), 32400: ("Plex", "media"), 8096: ("Jellyfin", "media"),
    1194: ("OpenVPN", "vpn"), 51820: ("WireGuard", "vpn"), 1701: ("L2TP", "vpn"), 500: ("IPsec", "vpn"), 4500: ("IPsec", "vpn"),
}


def _private(ip):
    """Частный, служебный или CGNAT-адрес (100.64.0.0/10) — не «из интернета»."""
    try:
        a = _ip.ip_address(ip)
    except ValueError:
        return True
    return a.is_private or a.is_loopback or a.is_link_local or a in _ip.ip_network("100.64.0.0/10")


def _kind(port, to_port=None):
    """Служба за пробросом: сначала по порту в сети (44300 → 5001 — это DSM), потом по порту WAN."""
    return PORT_KIND.get(to_port) or PORT_KIND.get(port) or ("", "")


def _iptl(table, chain):
    """iptables -L ЦЕПОЧКА -v -n -x → [(пакеты, цель, протокол, источник, назначение, остальное)]."""
    rc, out = run(["iptables", "-w", "5", "-t", table, "-L", chain, "-v", "-n", "-x"], timeout=15)
    rows = []
    if rc != 0:
        return None
    for l in out.splitlines()[2:]:
        p = l.split(None, 9)
        if len(p) < 9 or not p[0].isdigit():
            continue
        rows.append({"pkts": int(p[0]), "target": p[2], "proto": p[3], "src": p[7], "dst": p[8], "x": p[9] if len(p) > 9 else ""})
    return rows


def _set_members(name):
    rc, out = run(["ipset", "list", name], timeout=10)
    if rc != 0:
        return []
    m, on = [], False
    for l in out.splitlines():
        if l.startswith("Members:"):
            on = True
            continue
        if on and l.strip():
            m.append(l.split())
    return m


def _set_count(name):
    rc, out = run(["ipset", "list", "-t", name], timeout=10)
    x = re.search(r"Number of entries: (\d+)", out or "")
    return int(x.group(1)) if rc == 0 and x else 0


def sec_forwards():
    """Проброс портов с WAN (DNAT в правилах UniFi): порт WAN → адрес:порт в сети, пакетов с перезапуска правил."""
    rc, out = run(["iptables", "-w", "5", "-t", "nat", "-S"], timeout=15)
    chains = sorted({x for x in re.findall(r"^-A (\S+) .*-j DNAT", out or "", re.M) if x.startswith("UBIOS_")} or ({"UBIOS_PREROUTING_USER_HOOK"} if rc == 0 else set()))
    fw = {}
    for ch in chains:
        for r in _iptl("nat", ch) or []:
            if r["target"] != "DNAT":
                continue
            m = re.search(r"dpts?:(\d+)(?::(\d+))?", r["x"])
            to = re.search(r"to:(\d+\.\d+\.\d+\.\d+)(?::(\d+))?", r["x"])
            if not m or not to:
                continue
            port = int(m.group(1))
            key = (r["proto"], port, to.group(1), int(to.group(2) or port))
            restricted = r["src"] not in ("0.0.0.0/0", "") or bool(re.search(r"match-set \S+ src", r["x"]))
            x = fw.setdefault(key, {"proto": r["proto"], "port": port, "port_end": int(m.group(2) or port), "to": to.group(1),
                                    "to_port": int(to.group(2) or port), "pkts": 0, "restricted": False})
            x["pkts"] += r["pkts"]
            x["restricted"] = x["restricted"] or restricted
    res = []
    for x in sorted(fw.values(), key=lambda v: (v["port"], v["proto"])):
        name, kind = _kind(x["port"], x["to_port"])
        x.update(service=name, kind=kind)
        res.append(x)
    return res


def sec_wan_local():
    """Что принимает сам роутер с WAN (правила UniFi WAN_LOCAL): службы, счётчики, отбрасывания."""
    rows = _iptl("filter", "UBIOS_WAN_LOCAL_USER")
    if rows is None:
        return None
    acc, drop, invalid = [], 0, 0
    for r in rows:
        if r["target"] == "DROP":
            if "INVALID" in r["x"]:
                invalid += r["pkts"]
            elif "match-set" not in r["x"] and "dpt" not in r["x"]:
                drop += r["pkts"]
            continue
        if r["target"] != "ACCEPT" or "RELATED,ESTABLISHED" in r["x"]:
            continue
        sets = re.findall(r"match-set (\S+) (src|dst)", r["x"])
        dports = [m for m in re.findall(r"dpts?:(\S+)", r["x"])]
        sports = [m for m in re.findall(r"spts?:(\S+)", r["x"])]
        for s, d in sets:
            ports = [m[0] for m in _set_members(s) if re.match(r"^\d+$", m[0])]
            if "port" in s and d == "dst":
                dports += ports
            elif "port" in s and d == "src":
                sports += ports
        kind = "console" if any("console" in s for s, _ in sets) else "wireguard" if any("wireguard" in s for s, _ in sets) else "user"
        acc.append({"kind": kind, "proto": r["proto"], "dports": sorted(set(dports)), "sports": sorted(set(sports)), "pkts": r["pkts"],
                    "sets": [s for s, _ in sets]})
    return {"accept": acc, "drop": drop, "invalid": invalid}


def sec_ssh():
    c = read_file(SSHD_CONF)
    g = lambda k, d: (re.findall(r"^\s*%s\s+(\S+)" % k, c, re.M | re.I) or [d if c else ""])[0].lower()   # нет файла — не судим
    fails, oks = {}, {}
    text = ""
    try:
        with open(AUTH_LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 3000000))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        pass
    for l in text.splitlines():
        m = re.search(r"(?:Failed \S+|Invalid user \S*|authentication failure).*?(?:from|rhost=)\s*(\d+\.\d+\.\d+\.\d+)", l)
        if m:
            fails[m.group(1)] = fails.get(m.group(1), 0) + 1
            continue
        m = re.search(r"Accepted \S+ for \S+ from (\d+\.\d+\.\d+\.\d+)", l)
        if m:
            oks[m.group(1)] = oks.get(m.group(1), 0) + 1
    top = sorted(fails.items(), key=lambda x: -x[1])[:10]
    return {"password": g("PasswordAuthentication", "yes"), "root": g("PermitRootLogin", "prohibit-password"),
            "fails": [{"ip": ip, "n": n, "wan": not _private(ip)} for ip, n in top], "fails_wan": sum(n for ip, n in fails.items() if not _private(ip)),
            "ok_wan": sorted(ip for ip in oks if not _private(ip))[:10], "log": bool(text)}


def sec_ips():
    rc, out = run(["pgrep", "-af", "suricata"], timeout=5)
    prof = re.search(r"suricata_ubios_(\w+)\.yaml", out or "")
    st = {"running": rc == 0 and "suricata" in (out or ""), "profile": prof.group(1) if prof else "", "file": os.path.exists(EVE_F),
          "alerts": 0, "sig": [], "src": [], "ports": [], "blocked": 0, "first": 0, "last": 0}
    if not st["file"]:
        return st
    try:
        with open(EVE_F, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4000000))
            lines = f.read().decode("utf-8", "replace").splitlines()[1:]
    except OSError:
        return st
    sig, src, ports = {}, {}, {}
    for l in lines:
        try:
            j = json.loads(l)
        except ValueError:
            continue
        a = j.get("alert") or {}
        if j.get("event_type") != "alert" or not a:
            continue
        st["alerts"] += 1
        k = (a.get("signature") or "?")[:120], (a.get("category") or "")[:60]
        sig[k] = sig.get(k, 0) + 1
        ip = str(j.get("src_ip", ""))
        if ip and not _private(ip):
            src[ip] = src.get(ip, 0) + 1
        p = j.get("dest_port")
        if p:
            ports[p] = ports.get(p, 0) + 1
        if str(a.get("action", "")).lower() in ("blocked", "drop"):
            st["blocked"] += 1
        ts = str(j.get("timestamp", ""))[:19]
        try:
            t = int(time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%S")))
            st["first"] = min(st["first"] or t, t)
            st["last"] = max(st["last"], t)
        except ValueError:
            pass
    st["sig"] = [{"sig": k[0], "cat": k[1], "n": n} for k, n in sorted(sig.items(), key=lambda x: -x[1])[:10]]
    st["src"] = [{"ip": k, "n": n} for k, n in sorted(src.items(), key=lambda x: -x[1])[:10]]
    st["ports"] = [{"port": k, "n": n} for k, n in sorted(ports.items(), key=lambda x: -x[1])[:10]]
    return st


def sec_conns(wanip):
    """Кто сейчас подключён к WAN снаружи: по портам и адресам (снимок таблицы соединений)."""
    if not wanip:
        return {"total": 0, "ports": [], "src": []}
    rc, out = run(["conntrack", "-L", "-d", wanip], timeout=15)
    ports, src, total = {}, {}, 0
    for l in (out or "").splitlines()[:30000]:
        s = re.search(r"\bsrc=(\d+\.\d+\.\d+\.\d+)", l)
        d = re.search(r"\bdport=(\d+)", l)
        if not s or _private(s.group(1)) or s.group(1) == wanip:
            continue
        total += 1
        if d:
            ports[int(d.group(1))] = ports.get(int(d.group(1)), 0) + 1
        src[s.group(1)] = src.get(s.group(1), 0) + 1
    return {"total": total, "ports": [{"port": k, "n": n} for k, n in sorted(ports.items(), key=lambda x: -x[1])[:10]],
            "src": [{"ip": k, "n": n} for k, n in sorted(src.items(), key=lambda x: -x[1])[:10]]}


def sec_protect(e):
    on = e.get("SEC_PROTECT", "no") == "yes"
    st = {"on": on, "geo_allow": e.get("SEC_GEO_ALLOW", ""), "geo_ports": e.get("SEC_GEO_PORTS", ""),
          "trap": e.get("SEC_TRAP", DEFAULTS["SEC_TRAP"]), "rate": e.get("SEC_RATE", DEFAULTS["SEC_RATE"]),
          "rules": 0, "geo_set": 0, "geo_drop": 0, "trap_n": 0, "rate_n": 0, "ban_drop": 0, "banned": [], "recent": []}
    if not on:
        return st
    for ch in ("AWG_SEC_IN", "AWG_SEC_FWD"):
        for r in _iptl("filter", ch) or []:
            st["rules"] += 1
            if r["target"] == "DROP" and "AWG_SEC_GEO" in r["x"]:
                st["geo_drop"] += r["pkts"]
            elif r["target"] == "DROP" and "AWG_SEC_BAN" in r["x"]:
                st["ban_drop"] += r["pkts"]
    st["geo_set"] = _set_count("AWG_SEC_GEO")
    st["log"] = read_file(os.path.join(DD, "sec", "apply.log"))[-1500:]
    ban = []
    for s, why in (("AWG_SEC_TRAP", "trap"), ("AWG_SEC_RATE", "rate")):
        m = _set_members(s)
        st[why + "_n"] = len(m)
        for x in m:
            d = dict(zip(x[1::2], x[2::2]))
            ban.append({"ip": x[0], "why": why, "left": int(d.get("timeout", 0) or 0), "pkts": int(d.get("packets", 0) or 0)})
    st["banned"] = sorted(ban, key=lambda b: -b["pkts"])[:30]
    rec = []
    for l in read_file(SEC_LOG).splitlines()[-200:]:
        p = l.split("|")
        if len(p) == 3 and p[0].isdigit():
            rec.append({"t": int(p[0]), "why": p[1], "ip": p[2]})
    st["recent"] = rec[::-1][:50]
    st["day"] = sum(1 for r in rec if now() - r["t"] < 86400)
    return st


def sec_collect():
    e = env()
    wan = wan_if(e)
    rc, out = run(["ip", "-4", "-o", "addr", "show", "dev", wan], timeout=5) if wan else (1, "")
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out or "")
    wanip = m.group(1) if m else ""
    try:
        up = int(float(read_file(os.path.join(PROC, "uptime")).split()[0]))
    except (ValueError, IndexError):
        up = 0
    upnp = run(["pgrep", "-x", "miniupnpd"], timeout=5)[0] == 0
    return {"t": now(), "wan": wan, "wanip": wanip, "cgnat": bool(wanip) and _private(wanip), "uptime": up,
            "forwards": sec_forwards(), "local": sec_wan_local(), "ssh": sec_ssh(), "upnp": upnp, "ips": sec_ips(),
            "honeypot": os.path.exists(HONEY_F), "conns": sec_conns(wanip), "protect": sec_protect(e)}


def sec_findings(d):
    """Находки: уровень (crit — исправить, warn — стоит, info — к сведению, ok — хорошо), что, почему, что сделать."""
    F = []
    add = lambda sev, title, text, fix="", where="": F.append({"sev": sev, "title": title, "text": text, "fix": fix, "where": where})
    pr = d["protect"]
    gp = set(pr["geo_ports"].split()) if pr["on"] and pr["geo_allow"] else set()
    days = max(1, d["uptime"] // 86400)
    UF = "UniFi Network → Настройки → Безопасность → Проброс портов"
    for f in d["forwards"]:
        p, svc, kind = f["port"], f["service"] or "порт %d" % f["port"], f["kind"]
        tgt = "%s:%d" % (f["to"], f["to_port"])
        guarded = str(p) in gp or f["restricted"]
        if kind == "admin" and not guarded:
            add("crit", "В интернет открыто управление: %s (порт %d → %s)" % (svc, p, tgt),
                "Вход в управление устройством доступен любому адресу в интернете: такие порты постоянно перебирают боты, а уязвимость в прошивке устройства даёт взлом без пароля.",
                "Лучше закрыть проброс и заходить через VPN-сервер роутера (WireGuard). Если проброс нужен — ограничьте страны: «Защита входящих» ниже, порт %d." % p, UF)
        elif kind == "login" and not guarded:
            add("warn", "Вход по паролю из интернета: %s (порт %d → %s)" % (svc, p, tgt),
                "Сюда подбирают пароли. Нужен, только если подключаетесь не из дома без VPN.",
                "Ограничьте страны (порт %d) и включите блокировку подбора в «Защите входящих»; на самом сервере — блокировку после неудачных входов (Synology: Безопасность → Учётная запись → Автоблокировка)." % p, UF)
        elif kind == "mail":
            add("info", "Приём почты: порт %d → %s" % (p, tgt),
                "Порт 25 должен быть открыт для всех: почта приходит с серверов по всему миру.",
                "Не ограничивайте его по странам. Защита от подбора и спама — на самом почтовом сервере.", "")
            if str(p) in gp:
                add("warn", "Порт 25 ограничен по странам", "Почта от Gmail, Outlook и других зарубежных серверов не дойдёт.", "Уберите 25 из «Порты только из разрешённых стран».", "")
        elif kind == "web" and p == 80:
            add("info", "HTTP открыт: порт 80 → %s" % tgt, "Обычно нужен для сертификатов Let's Encrypt и переадресации на HTTPS.",
                "Не ограничивайте по странам: Let's Encrypt проверяет домен с серверов в разных странах — сертификат перестанет обновляться.", "")
            if "80" in gp:
                add("warn", "Порт 80 ограничен по странам", "Продление сертификата Let's Encrypt может перестать работать.", "Уберите 80 из «Порты только из разрешённых стран».", "")
        elif not guarded and kind not in ("media", "vpn"):
            add("info", "Открыт порт %d → %s%s" % (p, tgt, " (%s)" % f["service"] if f["service"] else ""),
                "Доступен из интернета без ограничений.", "Если пользуетесь только из своей страны — ограничьте страны в «Защите входящих».", UF)
        if f["pkts"] == 0 and days >= 3:
            add("info", "Проброс порта %d не используется" % p, "С перезапуска правил (%d дн.) на него не пришло ни одного пакета." % days,
                "Если он не нужен — удалите: каждый открытый порт — лишняя цель.", UF)
    lc = d["local"]
    if lc:
        for a in lc["accept"]:
            dp = ", ".join(a["dports"]) or "все"
            if a["kind"] == "console":
                add("warn", "Консоль UniFi принимает HTTPS из интернета (порт %s)" % dp,
                    "Пакетов на этот порт с перезапуска правил: %d. Это вход в управление роутером; его постоянно сканируют." % a["pkts"],
                    "Если удалённо заходите через unifi.ui.com или приложение UniFi — прямой вход обычно не нужен: проверьте настройки удалённого доступа консоли. Можно ограничить страны: порт %s в «Защите входящих»." % dp,
                    "UniFi OS → Настройки консоли → Удалённый доступ")
            elif a["kind"] == "wireguard":
                if "51820" in a["dports"]:
                    add("info", "VPN-сервер WireGuard на стандартном порту 51820",
                        "Это нормально: без ключа WireGuard не отвечает, подобрать нельзя. На стандартный порт чаще стучатся сканеры.",
                        "По желанию — другой порт (тогда поменять и в конфигах клиентов).", "UniFi Network → Настройки → VPN → VPN-сервер")
            elif a["sports"]:
                add("warn", "Правило пропускает на роутер пакеты по порту-источнику %s (порт назначения %s)" % (", ".join(a["sports"]), dp),
                    "Порт-источник выбирает отправитель: так сканеры обходят защиту. Пакетов с перезапуска правил: %d." % a["pkts"],
                    "Если правило создано по ошибке — удалите его или уберите условие на порт-источник.", "UniFi Network → Настройки → Безопасность → Правила брандмауэра (Internet Local)")
            elif "22" in a["dports"]:
                add("crit", "SSH роутера открыт из интернета", "Подбор паролей и уязвимости SSH.", "Закройте; для удалённого доступа — VPN-сервер.", "UniFi Network → Правила брандмауэра")
            else:
                add("info", "Роутер принимает из интернета: порт %s (%s)" % (dp, a["proto"]), "Правило пользователя UniFi, пакетов: %d." % a["pkts"], "", "")
        h = max(1, d["uptime"] // 3600)
        if lc["drop"]:
            add("ok", "UniFi отбрасывает непрошеные входящие", "С перезапуска правил отброшено %d пакетов (~%d в час) — обычный фон сканирования интернета." % (lc["drop"], lc["drop"] // h), "", "")
    s = d["ssh"]
    if not s["password"]:
        pass
    elif s["password"] == "yes":
        add("warn", "SSH роутера пускает по паролю", "Вход по ключу надёжнее.", "UniFi OS → Настройки консоли → SSH: вход по ключу; пароль — длинный.", "")
    else:
        add("ok", "SSH: только по ключу", "", "", "")
    if s["fails_wan"]:
        add("crit", "Попытки входа по SSH из интернета: %d" % s["fails_wan"], "Адреса: " + ", ".join(x["ip"] for x in s["fails"] if x["wan"]),
            "SSH роутера не должен быть доступен из интернета: проверьте проброс 22 и правила брандмауэра.", "")
    if s["ok_wan"]:
        add("crit", "Успешный вход по SSH с внешнего адреса", ", ".join(s["ok_wan"]), "Если это были не вы — смените пароли и ключи SSH, проверьте роутер.", "")
    if d["upnp"]:
        add("warn", "Включён UPnP", "Любое устройство в сети может само открыть себе порт из интернета (так делают и вирусы, и камеры).",
            "Выключите, если не нужен для игровых приставок.", "UniFi Network → Настройки → Интернет → UPnP")
    ips = d["ips"]
    if not ips["running"]:
        add("warn", "Система обнаружения угроз (IPS) не работает", "UniFi не проверяет трафик на атаки.", "Включите CyberSecure / Intrusion Prevention.", "UniFi Network → Настройки → CyberSecure")
    else:
        add("ok", "IPS работает" + (" (профиль %s)" % ips["profile"] if ips["profile"] else ""), "", "", "")
        if not ips["file"]:
            add("info", "События угроз на роутере не хранятся", "UniFi передаёт их в своё приложение; разбор здесь недоступен.", "Смотрите: UniFi Network → Insights / CyberSecure → Threats.", "")
        elif ips["alerts"]:
            add("info", "IPS: %d событий" % ips["alerts"], "Чаще всего: " + "; ".join("%s (%d)" % (x["sig"], x["n"]) for x in ips["sig"][:3]),
                "Адреса, которые повторяются, блокирует «Защита входящих» (ловушки и частота).", "")
    if d["honeypot"]:
        add("ok", "Включена приманка (honeypot) UniFi", "", "", "")
    if not pr["on"]:
        add("info", "Своя защита входящих выключена", "Можно включить ниже: только из разрешённых стран на выбранные порты, блокировка сканеров и подбора паролей. Правила UniFi не меняются.", "", "")
    else:
        add("ok", "Защита входящих включена", "Сейчас заблокировано адресов: %d (сканеры %d, подбор %d); за сутки — %d." % (pr["trap_n"] + pr["rate_n"], pr["trap_n"], pr["rate_n"], pr.get("day", 0)), "", "")
        if pr["geo_ports"] and pr["geo_allow"] and pr["geo_set"] == 0:
            last = [l for l in pr.get("log", "").splitlines() if l.startswith(("✘", "▲"))][-2:]
            add("warn", "Ограничение по странам не действует",
                "Адреса стран не загружены — правило не поставлено, чтобы не отбросить всех." + (" Последняя попытка: " + " ".join(last) if last else " Скачивание ещё не запускалось (первая сверка — в течение минуты после включения)."),
                "Нажмите «Скачать адреса стран» ниже. Не помогает — проверьте коды стран (две буквы: ru) и доступ роутера к raw.githubusercontent.com. Повтор — сам, раз в 10 минут.", "")
    if d["cgnat"]:
        add("info", "Внешний адрес — частный (%s)" % d["wanip"], "Провайдер раздаёт адрес через NAT: из интернета к вам напрямую не подключиться, проброс портов не работает.", "", "")
    order = {"crit": 0, "warn": 1, "info": 2, "ok": 3}
    F.sort(key=lambda x: order[x["sev"]])
    score = max(0, 100 - 25 * sum(1 for x in F if x["sev"] == "crit") - 8 * sum(1 for x in F if x["sev"] == "warn"))
    return F, score


def sec_suggest(d):
    """Предложение для «Защиты входящих»: какие порты ограничить странами (вход в управление и по паролю)."""
    ports = []
    for f in d["forwards"]:
        if f["kind"] in ("admin", "login") and not f["restricted"] and str(f["port"]) not in ports:
            ports.append(str(f["port"]))
    for a in (d["local"] or {}).get("accept", []):
        if a["kind"] == "console":
            ports += [p for p in a["dports"] if p not in ports]
    return {"SEC_GEO_PORTS": " ".join(ports), "SEC_TRAP": "yes", "SEC_RATE": "30"}


def api_security(h, q):
    fresh = (q.get("fresh") or [""])[0] == "1"
    if fresh or not _SEC_CACHE["v"] or now() - _SEC_CACHE["t"] > 60:
        d = sec_collect()
        f, score = sec_findings(d)
        _SEC_CACHE.update(t=now(), v={"data": d, "findings": f, "score": score, "suggest": sec_suggest(d)})
    return _SEC_CACHE["v"]


def api_security_geo(h, d):
    """Скачать адреса разрешённых стран сейчас и поставить правила (обычно это делает сверка awg-guard)."""
    rc, out = run([os.path.join(DD, "sec.sh"), "geo"], timeout=180)
    h.act("sec-geo")
    _SEC_CACHE["t"] = 0
    ok = rc == 0 and "только из" in out
    return {"ok": ok, "msg": out.strip()[-800:] or "нет ответа"}


def api_security_unban(h, d):
    ip = str(d.get("ip", ""))
    if not is_ipv4(ip):
        raise ValueError("нужен IPv4-адрес")
    rc, out = run([os.path.join(DD, "sec.sh"), "unban", ip], timeout=15)
    h.act("sec-unban", ip)
    _SEC_CACHE["t"] = 0
    return {"ok": rc == 0, "msg": out.strip()}
