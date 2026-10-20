# -*- coding: utf-8 -*-
"""VLESS/Reality через Xray (#42): подписка по ссылке (как Happ / v2rayN / INCY) — список серверов с автообновлением,
выбор страны или сервера, проверка задержки. Туннель VLESS — обычный участник цепочки переключения и маршрутов (#22):
интерфейс TUN создаёт Xray (вход tun), маршрутизирует и держит kill switch сторож, как у AmneziaWG.

Xray ставится только из официальных релизов XTLS/Xray-core со сверкой SHA256 (xray.sh). В браузер не уходят UUID
серверов и адреса подписок целиком (в адресе подписки обычно токен)."""
from .xui import *  # noqa: F401,F403  (всё из предыдущих модулей)
import base64
import socket
import threading

VL_DB_F = os.path.join(XD, "vless.json")         # {"subs": {ID: {...}}, "tunnels": {ИМЯ: {...}}}, 600 (UUID, адреса подписок)
XRAY_BIN = os.path.join(XD, "xray")
XRAY_LOG = os.path.join(XD, "xray.log")
SUB_ID_RE = re.compile(r"^s[0-9]{1,3}$")
SRV_ID_RE = re.compile(r"^[0-9a-f]{10}$")
UUID_RE = re.compile(r"^[0-9A-Za-z-]{8,64}$")
VL_SAFE = re.compile(r'^[^\x00-\x1f\x7f"\\]{0,300}$')
SUB_URL_RE = re.compile(r"^https://[A-Za-z0-9.-]{1,253}(:\d{1,5})?(/[^\s\x00-\x1f\x7f\"'<>\\]*)?$")
VL_NETS = {"tcp": "tcp", "raw": "tcp", "ws": "ws", "grpc": "grpc", "xhttp": "xhttp", "splithttp": "xhttp", "httpupgrade": "httpupgrade"}
VL_SECS = ("none", "tls", "reality")
VL_FLOWS = ("", "xtls-rprx-vision", "xtls-rprx-vision-udp443")
SUB_UA = "v2rayN/7.10.5"            # подписки отдают список vless:// клиентам v2rayN; другим — иногда страницу или другой формат
SUB_MAX_AGE = 86400
VL_MTU = 1400
VL_NET_BASE = "198.19"              # адрес интерфейса TUN: 198.19.N.1/32 (RFC 2544 — в домашних сетях не встречается)
COUNTRIES = {   # названия в подписках → код страны (флаг-эмодзи разбирается отдельно)
    "FI": ("finland", "финлянд", "helsinki", "хельсинк"), "NL": ("netherlands", "нидерланд", "голланд", "amsterdam", "амстердам"),
    "DE": ("germany", "герман", "frankfurt", "франкфурт", "berlin"), "SE": ("sweden", "швец", "stockholm"),
    "US": ("united states", "usa", "сша", "америк", "new york", "los angeles"), "GB": ("united kingdom", "britain", "англи", "великобрит", "london", "лондон"),
    "FR": ("france", "франц", "paris", "париж"), "PL": ("poland", "польш", "warsaw", "варшав"), "LV": ("latvia", "латви", "riga", "рига"),
    "EE": ("estonia", "эстон", "tallinn", "таллин"), "LT": ("lithuania", "литв", "vilnius"), "TR": ("turkey", "türkiye", "турци", "istanbul", "стамбул"),
    "KZ": ("kazakhstan", "казахстан", "almaty", "алматы"), "JP": ("japan", "япони", "tokyo", "токио"), "SG": ("singapore", "сингапур"),
    "CH": ("switzerland", "швейцар", "zurich"), "AT": ("austria", "австри", "vienna", "вена"), "CZ": ("czech", "чехи", "prague", "праг"),
    "ES": ("spain", "испани", "madrid"), "IT": ("italy", "итали", "milan"), "MD": ("moldova", "молдов"), "RS": ("serbia", "серби", "belgrade"),
    "HK": ("hong kong", "гонконг"), "CA": ("canada", "канад", "toronto"), "NO": ("norway", "норвег", "oslo"), "DK": ("denmark", "дани"),
    "RO": ("romania", "румын", "bucharest"), "BG": ("bulgaria", "болгар", "sofia"), "HU": ("hungary", "венгри", "budapest"),
    "AM": ("armenia", "армени", "yerevan", "ереван"), "GE": ("georgia", "грузи", "tbilisi", "тбилиси"), "AE": ("emirates", "uae", "оаэ", "эмират", "dubai", "дубай"),
    "IL": ("israel", "израил"), "IN": ("india", "инди"), "KR": ("korea", "коре", "seoul"), "TW": ("taiwan", "тайван"), "AU": ("australia", "австрали"),
    "BR": ("brazil", "бразил"), "RU": ("russia", "росси", "moscow", "москв"), "UA": ("ukraine", "украин"), "BY": ("belarus", "белорус", "беларус"),
    "IE": ("ireland", "ирланд"), "BE": ("belgium", "бельги"), "PT": ("portugal", "португал"), "GR": ("greece", "греци"), "CY": ("cyprus", "кипр"),
}
_VL_JOB = {"t": None}


def vl_db():
    try:
        d = json.loads(read_file(VL_DB_F) or "{}")
    except ValueError:
        d = {}
    if not isinstance(d, dict):
        d = {}
    d.setdefault("subs", {})
    d.setdefault("tunnels", {})
    return d


def vl_db_save(d):
    os.makedirs(XD, mode=0o700, exist_ok=True)
    write_secure(VL_DB_F, json.dumps(d, ensure_ascii=False, indent=1))


def country_of(remark):
    """Код страны по флагу-эмодзи (пара региональных индикаторов) или по названию в имени сервера; не нашли — пусто."""
    r = str(remark or "")
    ri = [ord(c) - 0x1F1E6 for c in r if 0x1F1E6 <= ord(c) <= 0x1F1FF]
    if len(ri) >= 2:
        return chr(65 + ri[0]) + chr(65 + ri[1])
    low = r.lower()
    for cc, names in COUNTRIES.items():
        if any(n in low for n in names):
            return cc
    m = re.search(r"(?:^|[\s\[\(|_-])([A-Z]{2})(?=$|[\s\]\)|_\d-])", r)
    return m.group(1) if m and m.group(1) in COUNTRIES else ""


def _q(qs, k, default=""):
    v = (qs.get(k) or [default])[0]
    v = urllib.parse.unquote(str(v)).strip()
    if not VL_SAFE.match(v):
        raise ValueError("недопустимое значение %s" % k)
    return v


def parse_vless(link):
    """vless://UUID@адрес:порт?security=reality&pbk=…&sni=…&type=tcp&flow=…#имя → описание сервера (или ValueError)."""
    link = str(link).strip()
    if not link.lower().startswith("vless://") or len(link) > 4000:
        raise ValueError("не ссылка vless://")
    u = urllib.parse.urlsplit(link)
    uid = urllib.parse.unquote(u.username or "")
    if not UUID_RE.match(uid):
        raise ValueError("нет UUID")
    host = (u.hostname or "").strip("[]")
    try:
        port = u.port
    except ValueError:
        port = None
    if not host or not HOST_OR_IP_RE.match(host) or not port or not 1 <= port <= 65535:
        raise ValueError("нет адреса или порта сервера")
    qs = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    sec = _q(qs, "security", "none").lower() or "none"
    net = VL_NETS.get(_q(qs, "type", "tcp").lower() or "tcp")
    flow = _q(qs, "flow").lower()
    if sec not in VL_SECS:
        raise ValueError("защита %s не поддерживается" % sec)
    if not net:
        raise ValueError("транспорт %s не поддерживается" % _q(qs, "type"))
    if flow not in VL_FLOWS:
        raise ValueError("flow %s не поддерживается" % flow)
    s = {"uuid": uid, "host": host, "port": port, "security": sec, "type": net, "flow": flow,
         "sni": _q(qs, "sni") or _q(qs, "serverName") or _q(qs, "peer"), "fp": _q(qs, "fp") or "chrome",
         "pbk": _q(qs, "pbk"), "sid": _q(qs, "sid"), "spx": _q(qs, "spx"), "alpn": _q(qs, "alpn"),
         "hosthdr": _q(qs, "host"), "path": _q(qs, "path"), "service": _q(qs, "serviceName"), "mode": _q(qs, "mode"),
         "remark": urllib.parse.unquote(u.fragment or "").strip()[:80]}
    if not VL_SAFE.match(s["remark"]):
        s["remark"] = re.sub(r'[\x00-\x1f\x7f"\\]', "", s["remark"])
    if sec == "reality" and not re.match(r"^[A-Za-z0-9_-]{40,50}$", s["pbk"]):
        raise ValueError("Reality без открытого ключа (pbk)")
    if s["sid"] and not re.match(r"^[0-9a-fA-F]{0,16}$", s["sid"]):
        raise ValueError("Reality: неверный shortId (sid)")
    s["country"] = country_of(s["remark"])
    key = "|".join(str(s[k]) for k in ("uuid", "host", "port", "security", "type", "sni", "pbk", "sid", "path", "service"))
    s["id"] = hashlib.sha1(key.encode()).hexdigest()[:10]
    return s


def parse_sub(text):
    """Подписка: список ссылок, как есть или в base64. → (серверы VLESS, сколько строк пропущено: другие протоколы, ошибки)."""
    t = str(text or "").strip()
    if t and "://" not in t:
        try:
            t = base64.b64decode(t + "=" * (-len(t) % 4), altchars=b"-_" if ("-" in t or "_" in t) else None).decode("utf-8", "replace")
        except (ValueError, TypeError):
            t = ""
    servers, skipped, seen = [], 0, set()
    for line in t.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            s = parse_vless(line)
        except ValueError:
            skipped += 1
            continue
        if s["id"] not in seen:
            seen.add(s["id"])
            servers.append(s)
    return servers[:500], skipped


def sub_fetch(url):
    """Скачать подписку: напрямую, при неудаче — через активный туннель (curl, только https, не больше 2 МБ)."""
    if not SUB_URL_RE.match(url):
        raise ValueError("адрес подписки: https://…")
    base = ["curl", "-fsL", "--proto", "=https", "--proto-redir", "=https", "-m", "25", "--max-filesize", "2000000", "-A", SUB_UA]
    rc, out = run(base + [url], timeout=35)
    if rc != 0:
        act = state().get("ACTIVE", "")
        if act:
            rc, out = run(base + ["--interface", act, url], timeout=35)
    if rc != 0:
        raise ValueError("подписка не скачалась (curl %d): проверьте адрес" % rc)
    return out


def tcp_ping(host, port, timeout=3.0):
    """Время установки TCP-соединения с роутера (как пойдёт Xray), мс; нет соединения — -1."""
    try:
        ai = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
        t0 = time.time()
        with socket.create_connection(ai[0][4], timeout=timeout):
            return int((time.time() - t0) * 1000 + 0.5)
    except (OSError, IndexError, ValueError):
        return -1


def ping_all(servers):
    """Задержка до всех серверов параллельно (не больше 16 соединений сразу)."""
    lock, it = threading.Lock(), iter(list(servers))

    def worker():
        while True:
            with lock:
                s = next(it, None)
            if s is None:
                return
            s["ping"] = tcp_ping(s["host"], s["port"])
    th = [threading.Thread(target=worker, daemon=True) for _ in range(min(16, len(servers)) or 1)]
    for x in th:
        x.start()
    for x in th:
        x.join(30)
    ts = now()
    for s in servers:
        s.setdefault("ping", -1)
        s["pinged"] = ts
    return servers


def pick(servers, country="", key=""):
    """Сервер туннеля: заданный (key) или самый быстрый в стране (пусто — среди всех); никто не ответил — первый подходящий."""
    if key:
        return next((s for s in servers if s["id"] == key), None)
    c = [s for s in servers if not country or s.get("country") == country]
    ok = sorted((s for s in c if s.get("ping", -1) >= 0), key=lambda s: s["ping"])
    return ok[0] if ok else (c[0] if c else None)


def resolve4(host):
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", host):
        return host
    try:
        return socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0]
    except (OSError, IndexError):
        raise ValueError("адрес сервера %s не разрешается" % host)


def xray_conf(name, s, ip, mtu, wan):
    """Конфиг Xray: вход tun (интерфейс ИМЯ, маршрутов не трогает — их ставит сторож) → выход VLESS. Соединения Xray
    привязаны к WAN: трафик самого туннеля никогда не уходит в туннель."""
    st = {"network": s["type"], "security": s["security"]}
    if s["security"] == "reality":
        st["realitySettings"] = {"serverName": s["sni"], "fingerprint": s["fp"] or "chrome", "publicKey": s["pbk"],
                                 "shortId": s["sid"], "spiderX": s["spx"] or "/"}
    elif s["security"] == "tls":
        tl = {"serverName": s["sni"] or s["host"], "fingerprint": s["fp"] or "chrome"}
        if s["alpn"]:
            tl["alpn"] = [a for a in s["alpn"].split(",") if a]
        st["tlsSettings"] = tl
    if s["type"] == "ws":
        st["wsSettings"] = {"path": s["path"] or "/", "headers": {"Host": s["hosthdr"]} if s["hosthdr"] else {}}
    elif s["type"] == "grpc":
        st["grpcSettings"] = {"serviceName": s["service"], "multiMode": s["mode"] == "multi"}
    elif s["type"] == "xhttp":
        st["xhttpSettings"] = {"path": s["path"] or "/", "host": s["hosthdr"], "mode": s["mode"] or "auto"}
    elif s["type"] == "httpupgrade":
        st["httpupgradeSettings"] = {"path": s["path"] or "/", "host": s["hosthdr"]}
    if wan:
        st["sockopt"] = {"interface": wan}
    user = {"id": s["uuid"], "encryption": "none"}
    if s["flow"]:
        user["flow"] = s["flow"]
    return {"log": {"loglevel": "warning", "access": "none"},
            "inbounds": [{"tag": "tun", "protocol": "tun", "settings": {"name": name, "mtu": mtu, "userLevel": 0}}],
            "outbounds": [{"tag": "vless", "protocol": "vless", "settings": {"vnext": [{"address": ip, "port": s["port"], "users": [user]}]},
                           "streamSettings": st}],
            "routing": {"domainStrategy": "AsIs", "rules": [{"type": "field", "inboundTag": ["tun"], "outboundTag": "vless"}]}}


def vl_addr(name, db):
    """Адрес интерфейса туннеля: 198.19.N.1/32, N — свой у каждого туннеля VLESS."""
    used = {r.get("n") for k, r in db["tunnels"].items() if k != name}
    cur = db["tunnels"].get(name, {}).get("n")
    n = cur if isinstance(cur, int) and cur not in used else next(i for i in range(1, 250) if i not in used)
    return n, "%s.%d.1/32" % (VL_NET_BASE, n)


def tunnel_files(name, s, rec):
    """Записать конфиг Xray (600), открытую часть для панели (.info) и адрес сервера для исключений awg-self (.server)."""
    e = env()
    ip = resolve4(s["host"])
    cfg = xray_conf(name, s, ip, int(rec.get("mtu") or VL_MTU), wan_if(e))
    os.makedirs(XD, mode=0o700, exist_ok=True)
    write_secure(os.path.join(XD, name + ".json"), json.dumps(cfg, indent=1))
    info = {k: s.get(k, "") for k in ("host", "port", "security", "type", "remark", "country")}
    info.update(ip=ip, addr=rec.get("addr", ""), mtu=int(rec.get("mtu") or VL_MTU), server=s["id"], sub=rec.get("sub", ""))
    write_secure(os.path.join(XD, name + ".info"), json.dumps(info, ensure_ascii=False))
    write_secure(os.path.join(XD, name + ".server"), ip + "\n")


def xray_version():
    if not os.path.exists(XRAY_BIN):
        return ""
    rc, out = run([XRAY_BIN, "version"], timeout=10)
    m = re.search(r"Xray (\d+\.\d+\.\d+)", out)
    return m.group(1) if rc == 0 and m else ""


def xray_job_running():
    return run(["systemctl", "is-active", "--quiet", "awg-xray-install"], timeout=5)[0] == 0


def mask_url(u):
    p = urllib.parse.urlsplit(u)
    return "%s://%s/…" % (p.scheme, p.netloc) if p.netloc else ""


def pub_server(s):
    return {k: s.get(k) for k in ("id", "remark", "country", "host", "port", "security", "type", "flow", "ping", "pinged")}


def fetch_servers(url):
    """Скачать и разобрать подписку, замерить задержку (без замка панели: это до полуминуты). → (серверы, пропущено)."""
    servers, skipped = parse_sub(sub_fetch(url))
    if not servers:
        raise ValueError("в ответе нет серверов VLESS (пропущено строк: %d)" % skipped)
    return ping_all(servers), skipped


def retune_tunnels(db, sid, msgs):
    """После обновления подписки: туннель, сервер которого пропал или поменялся, — на тот же сервер или лучший в стране."""
    servers = db["subs"][sid]["servers"]
    for name, rec in db["tunnels"].items():
        if rec.get("sub") != sid or not is_xray(name):
            continue
        cur = next((s for s in servers if s["id"] == rec.get("server")), None)
        if cur and rec.get("mode") == "fixed":
            continue
        if cur:
            continue                       # сервер на месте: ничего не трогаем (без «прыжков» между серверами)
        new = pick(servers, rec.get("country", ""))
        if not new:
            msgs.append("%s: подходящего сервера в подписке нет — оставлен прежний конфиг" % name)
            continue
        try:
            tunnel_files(name, new, rec)
        except ValueError as ex:
            msgs.append("%s: %s" % (name, ex))
            continue
        rec["server"] = new["id"]
        up_tunnel(name)
        msgs.append("%s: сервер сменился на «%s»" % (name, new.get("remark") or new["host"]))


# ======================================================================= API
def api_vless_get(h, q):
    db = vl_db()
    tl = []
    for name, rec in db["tunnels"].items():
        sub = db["subs"].get(rec.get("sub"), {})
        s = next((x for x in sub.get("servers", []) if x["id"] == rec.get("server")), {})
        tl.append({"name": name, "sub": rec.get("sub"), "mode": rec.get("mode", "auto"), "country": rec.get("country", ""),
                   "server": pub_server(s) if s else None, "up": link_exists(name), "check": chk_age(name), "in_env": is_xray(name)})
    return {"xray": {"version": xray_version(), "installed": os.path.exists(XRAY_BIN), "job": xray_job_running(),
                     "log": read_file(XRAY_LOG)[-6000:]},
            "subs": [{"id": k, "label": v.get("label", ""), "url": mask_url(v.get("url", "")), "updated": v.get("updated", 0),
                      "count": len(v.get("servers", [])), "skipped": v.get("skipped", 0), "err": v.get("err", ""),
                      "servers": [pub_server(s) for s in v.get("servers", [])],
                      "countries": sorted({s.get("country") for s in v.get("servers", []) if s.get("country")})}
                     for k, v in sorted(db["subs"].items())],
            "tunnels": tl, "names": [t for t in tunnels(env())]}


def api_vless_sub_set(h, d):
    """Добавить подписку (или сменить адрес / название): скачать, разобрать, замерить задержку."""
    sid = str(d.get("id", "")).strip()
    url = str(d.get("url", "")).strip()
    label = str(d.get("label", "")).strip()[:40]
    if re.search(r"[<>\"'&\x00-\x1f]", label):
        raise ValueError("недопустимые символы в названии")
    if url and not SUB_URL_RE.match(url):
        raise ValueError("адрес подписки: https://…")
    db = vl_db()
    if sid and sid not in db["subs"]:
        raise ValueError("нет такой подписки")
    if not sid and not url:
        raise ValueError("укажите адрес подписки")
    servers, sk = fetch_servers(url or db["subs"][sid]["url"])
    with LOCK:
        db = vl_db()
        if not sid:
            sid = next("s%d" % i for i in range(1, 1000) if "s%d" % i not in db["subs"])
            db["subs"][sid] = {"url": "", "servers": [], "created": now()}
        if sid not in db["subs"]:
            raise ValueError("нет такой подписки")
        sub = db["subs"][sid]
        if url:
            sub["url"] = url
        if label or not sub.get("label"):
            sub["label"] = label or urllib.parse.urlsplit(sub["url"]).hostname or sid
        sub.update(servers=servers, skipped=sk, updated=now(), err="")
        n = len(servers)
        vl_db_save(db)
    h.act("vless-sub", {"id": sid, "servers": n})
    return {"ok": True, "id": sid, "msg": "подписка %s: серверов VLESS %d%s" % (sub["label"], n, (", пропущено строк %d (другие протоколы)" % sk) if sk else "")}


def api_vless_sub_refresh(h, d):
    """Обновить подписку (одну или все): список серверов, задержка; туннель, чей сервер пропал, — на лучший в стране."""
    msgs = []
    db = vl_db()
    ids = [str(d.get("id"))] if d.get("id") else sorted(db["subs"])
    got = {}
    for sid in ids:
        if sid not in db["subs"]:
            raise ValueError("нет такой подписки")
        try:
            got[sid] = fetch_servers(db["subs"][sid]["url"])
        except ValueError as ex:
            got[sid] = str(ex)
    with LOCK:
        db = vl_db()
        for sid, r in got.items():
            sub = db["subs"].get(sid)
            if sub is None:
                continue
            lab = sub.get("label", sid)
            if isinstance(r, str):          # прежний список остаётся
                sub["err"] = r
                msgs.append("%s: %s" % (lab, r))
                continue
            sub.update(servers=r[0], skipped=r[1], updated=now(), err="")
            msgs.append("%s: серверов %d" % (lab, len(r[0])))
            retune_tunnels(db, sid, msgs)
        vl_db_save(db)
    if h:
        h.act("vless-refresh", ids)
    return {"ok": True, "msg": "; ".join(msgs) or "подписок нет"}


def api_vless_ping(h, d):
    sid = str(d.get("id", ""))
    if sid not in vl_db()["subs"]:
        raise ValueError("нет такой подписки")
    pings = {s["id"]: s["ping"] for s in ping_all([dict(x) for x in vl_db()["subs"][sid]["servers"]])}
    with LOCK:
        db = vl_db()
        servers = db["subs"].get(sid, {}).get("servers", [])
        for s in servers:
            if s["id"] in pings:
                s["ping"], s["pinged"] = pings[s["id"]], now()
        vl_db_save(db)
    ok = [s for s in servers if s.get("ping", -1) >= 0]
    return {"ok": True, "msg": "отвечают %d из %d" % (len(ok), len(servers))}


def api_vless_sub_remove(h, d):
    sid = str(d.get("id", ""))
    with LOCK:
        db = vl_db()
        used = [k for k, r in db["tunnels"].items() if r.get("sub") == sid]
        if used:
            raise ValueError("подписку используют туннели %s: сначала уберите их" % ", ".join(used))
        db["subs"].pop(sid, None)
        vl_db_save(db)
    h.act("vless-sub-remove", sid)
    return {"ok": True}


def api_vless_tunnel(h, d):
    """Создать туннель VLESS или сменить его сервер: подписка + страна (самый быстрый сервер) или конкретный сервер."""
    need_pw(h, d, "vless-tunnel")
    name = str(d.get("name", "")).strip()
    sid = str(d.get("sub", ""))
    country = str(d.get("country", "")).strip().upper()
    key = str(d.get("server", "")).strip()
    mtu = str(d.get("mtu", "") or VL_MTU).strip()
    if not NAME_RE.match(name):
        raise ValueError("имя: awg и 1–10 строчных латинских букв или цифр, например awgvless")
    if country and not re.match(r"^[A-Z]{2}$", country):
        raise ValueError("страна: двухбуквенный код")
    if key and not SRV_ID_RE.match(key):
        raise ValueError("неверный сервер")
    if not mtu.isdigit() or not 1280 <= int(mtu) <= 1500:
        raise ValueError("MTU: 1280–1500")
    if not os.path.exists(XRAY_BIN):
        raise ValueError("Xray не установлен: «Туннели → VLESS → Установить Xray»")
    e = env()
    new = name not in xray_tunnels(e)
    if new and (name in tunnels(e) or link_exists(name)):
        raise ValueError("имя %s уже занято другим туннелем" % name)
    with LOCK:
        db = vl_db()
        if sid not in db["subs"]:
            raise ValueError("выберите подписку")
        s = pick(db["subs"][sid]["servers"], country, key)
        if not s:
            raise ValueError("в подписке нет сервера%s" % (" страны " + country if country else ""))
        rec = dict(db["tunnels"].get(name, {}), sub=sid, country=country if not key else (s.get("country") or ""),
                   mode="fixed" if key else "auto", server=s["id"], mtu=int(mtu), created=db["tunnels"].get(name, {}).get("created", now()))
        rec["n"], rec["addr"] = vl_addr(name, db)
        tunnel_files(name, s, rec)
        db["tunnels"][name] = rec
        vl_db_save(db)
        if new:
            env_set({"TUNNELS_EXTRA": " ".join((e.get("TUNNELS_EXTRA", "") + " " + name).split()),
                     "XRAY_TUNNELS": " ".join(xray_tunnels(e) + [name])})
            lab = str(d.get("label", "")).strip()[:40] or ("VLESS " + (s.get("country") or ""))
            if not re.search(r"[<>\"'&\x00-\x1f]", lab):
                ls = labels()
                ls[name] = lab.strip()
                write_secure(LABELS_F, json.dumps(ls, ensure_ascii=False))
        rc, out = up_tunnel(name)
        if new and svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
        if svc_active("awg-self"):
            run(["systemctl", "restart", "awg-self"], timeout=30)    # адрес сервера VLESS — в исключениях awg-self
    h.act("vless-tunnel", {"name": name, "sub": sid, "server": s["id"], "new": new})
    if rc != 0:
        return {"ok": False, "msg": "конфиг записан, но туннель не поднялся:\n" + out.strip()[-600:]}
    return {"ok": True, "msg": "%s %s: сервер «%s» (%s:%s)%s" % (name, "добавлен" if new else "переключён", s.get("remark") or "?", s["host"], s["port"],
                                                            ", задержка %d мс" % s["ping"] if s.get("ping", -1) >= 0 else "")}


def api_vless_tunnel_remove(h, d):
    need_pw(h, d, "vless-remove")
    name = str(d.get("name", ""))
    if not is_xray(name):
        raise ValueError("это не туннель VLESS")
    tunnel_remove(name)                 # проверяет, что туннель не в маршруте, и убирает его из сторожа
    with LOCK:
        env_set({"XRAY_TUNNELS": " ".join(x for x in xray_tunnels() if x != name)})
        run(["systemctl", "stop", "awg-xray-" + name], timeout=30)
        run(["ip", "link", "del", name], timeout=10)
        db = vl_db()
        db["tunnels"].pop(name, None)
        vl_db_save(db)
        for ext in (".json", ".info", ".server"):
            try:
                os.remove(os.path.join(XD, name + ext))
            except OSError:
                pass
    h.act("vless-remove", name)
    return {"ok": True, "msg": "%s убран" % name}


def api_vless_xray(h, d):
    """Установить или обновить Xray (официальный релиз XTLS со сверкой SHA256) — отдельной службой, журнал — в панели."""
    need_pw(h, d, "xray-install")
    if xray_job_running():
        raise ValueError("установка уже идёт")
    os.makedirs(XD, mode=0o700, exist_ok=True)
    write_secure(XRAY_LOG, "%s установка Xray — из панели (%s)\n" % (time.strftime("%F %T"), h.user))
    rc, out = run(["systemd-run", "--unit=awg-xray-install", "--collect", "--quiet", "--setenv=DD=" + DD,
                   "-p", "StandardOutput=append:" + XRAY_LOG, "-p", "StandardError=append:" + XRAY_LOG, "/bin/bash", "-c",
                   '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc', os.path.join(DD, "xray.sh"), "install"], timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    h.act("xray-install")
    return {"ok": True, "msg": "установка Xray запущена", "job": True}


def vless_refresh_due():
    """Для awg-guard (раз в час): подписки, обновлённые больше суток назад, — заново. → сообщения."""
    db = vl_db()
    due = [k for k, v in db["subs"].items() if now() - int(v.get("updated") or 0) >= SUB_MAX_AGE]
    msgs = []
    for sid in due:
        try:
            msgs.append(api_vless_sub_refresh(None, {"id": sid})["msg"])
        except ValueError as ex:
            msgs.append(str(ex))
    return msgs
