# -*- coding: utf-8 -*-
"""3x-ui (#30): туннель AmneziaWG 3.1 через API панели 3x-ui по токену.

Роутер создаёт в 3x-ui (≥ 3.8.5) подключение amneziawg с одним клиентом — самим роутером. Ключ клиента создаётся на роутере,
в 3x-ui уходит только открытый; ключи сервера и параметры AWG 3.1 генерирует 3x-ui. Конфиг собирается из ответа API так же,
как это делает сама 3x-ui (internal/sub: amneziaWGConfigText), и добавляется туннелем через общий tunnel_add."""
from .tools import *  # noqa: F401,F403  (всё из предыдущих модулей)
import urllib.error
import urllib.request

XUI_F = os.path.join(DD, "xui.env")
XUI_MAP_F = os.path.join(DD, "xui.json")
XUI_URL_RE = re.compile(r"^https?://[A-Za-z0-9.-]{1,253}(:\d{1,5})?(/[A-Za-z0-9._~%/-]*)?$")
XUI_TOKEN_RE = re.compile(r"^[A-Za-z0-9._~+/=-]{8,512}$")
XUI_SAFE = re.compile(r"^[^\x00-\x1f\x7f]*$")     # значения из ответа 3x-ui попадают в конфиг: без переводов строк


def xui_conf():
    return parse_env_text(read_file(XUI_F))


def xui_map():
    try:
        m = json.loads(read_file(XUI_MAP_F) or "{}")
    except ValueError:
        m = {}
    return m if isinstance(m, dict) else {}


def xui_req(method, path, body=None, c=None, timeout=20):
    """Запрос к API 3x-ui: Bearer-токен, ответ {success, msg, obj} → obj; ошибки — понятным ValueError."""
    c = c or xui_conf()
    if not c.get("XUI_URL") or not c.get("XUI_TOKEN"):
        raise ValueError("3x-ui не настроена: укажите адрес панели и API-токен")
    url = c["XUI_URL"].rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    hdr = {"Authorization": "Bearer " + c["XUI_TOKEN"], "Accept": "application/json"}
    if data is not None:
        hdr["Content-Type"] = "application/json"
    ctx = None
    if url.startswith("https://"):
        ctx = ssl.create_default_context()
        if c.get("XUI_INSECURE") == "yes":
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=hdr), timeout=timeout, context=ctx) as r:
            raw = r.read(4 << 20)
    except urllib.error.HTTPError as ex:
        if ex.code == 401:
            raise ValueError("3x-ui: токен неверен, отключён или истёк (HTTP 401)")
        if ex.code == 403:
            raise ValueError("3x-ui: у токена нет прав на это действие (нужна область admin)")
        if ex.code == 404:
            raise ValueError("3x-ui: нет такого пути — проверьте адрес панели вместе с секретным путём (webBasePath) и версию 3x-ui (≥ 3.8.5)")
        raise ValueError("3x-ui: HTTP %d" % ex.code)
    except ssl.SSLError as ex:
        raise ValueError("3x-ui: сертификат не прошёл проверку (%s) — для самоподписанного включите «без проверки сертификата»" % ex.reason)
    except (urllib.error.URLError, OSError) as ex:
        raise ValueError("3x-ui недоступна: %s" % getattr(ex, "reason", ex))
    try:
        j = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        raise ValueError("3x-ui ответила не JSON: проверьте адрес панели")
    if not isinstance(j, dict) or not j.get("success"):
        raise ValueError("3x-ui: %s" % ((j.get("msg") if isinstance(j, dict) else "") or "ошибка без описания"))
    return j.get("obj")


def xui_host(c):
    """Адрес для Endpoint: XUI_HOST или узел из адреса панели."""
    return c.get("XUI_HOST") or urllib.parse.urlparse(c.get("XUI_URL", "")).hostname or ""


def awg31_conf(server, client_priv, address, host, port):
    """Конфиг клиента AmneziaWG 3.1 — как amneziaWGConfigText в 3x-ui, без DNS (на роутере не применяется)."""
    def v(k, default=""):
        x = server.get(k, default)
        x = "" if x is None else str(x).strip()
        if not XUI_SAFE.match(x):
            raise ValueError("3x-ui вернула недопустимое значение %s" % k)
        return x
    mtu = int(server.get("mtu") or 0) or max(1420 - max(int(server.get("s4") or 0), 0), 1280)
    lines = ["[Interface]", "PrivateKey = %s" % client_priv, "Address = %s" % address, "MTU = %d" % mtu]
    for k in ("Jc", "Jmin", "Jmax", "S1", "S2"):
        lines.append("%s = %s" % (k, v(k.lower(), "0")))
    for k in ("S3", "S4"):
        if int(server.get(k.lower()) or 0) > 0:
            lines.append("%s = %s" % (k, v(k.lower())))
    for i in range(1, 5):
        lines.append("H%d = %s" % (i, v("h%d" % i) or str(i)))
    for i in range(1, 6):
        if v("i%d" % i):
            lines.append("I%d = %s" % (i, v("i%d" % i)))
    for k in ("HeaderProtectionKey", "ContentPaddingAddition", "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
              "KeepaliveTimeout", "MaxHandshakeAttempts"):
        x = v(k[0].lower() + k[1:])
        if x:
            lines.append("%s = %s" % (k, x))
    if server.get("randomTrailers"):
        lines.append("RandomTrailers = on")
    if server.get("disableCookies"):
        lines.append("DisableCookies = on")
    lines += ["", "[Peer]", "PublicKey = %s" % v("publicKey"), "AllowedIPs = 0.0.0.0/0", "Endpoint = %s:%d" % (host, port),
              "PersistentKeepalive = 25", ""]
    return "\n".join(lines)


def awg_keypair():
    rc, priv = run([os.path.join(DD, "awg"), "genkey"], timeout=10)
    priv = priv.strip()
    rc2, pub = run([os.path.join(DD, "awg"), "pubkey"], timeout=10, inp=priv + "\n")
    pub = pub.strip()
    if rc or rc2 or not KEY_RE.match(priv) or not KEY_RE.match(pub):
        raise ValueError("не удалось создать ключи на роутере (awg genkey)")
    return priv, pub


def api_xui_get(h, q):
    c = xui_conf()
    go = bins_installed("amneziawg-go")
    return {"url": c.get("XUI_URL", ""), "token_set": bool(c.get("XUI_TOKEN")), "insecure": c.get("XUI_INSECURE") == "yes",
            "host": c.get("XUI_HOST", ""), "host_default": urllib.parse.urlparse(c.get("XUI_URL", "")).hostname or "",
            "go": go, "go_ok": bool(go) and vkey(go) >= (3,), "tunnels": [dict(v, name=k) for k, v in sorted(xui_map().items())]}


def api_xui_set(h, d):
    old = xui_conf()
    url = str(d.get("url", "")).strip().rstrip("/")
    if not XUI_URL_RE.match(url):
        raise ValueError("адрес 3x-ui: https://узел:порт/секретный-путь (как в браузере, без /panel)")
    tok = str(d.get("token", "")).strip() or old.get("XUI_TOKEN", "")     # пусто — прежний (в браузер не передаётся)
    if not XUI_TOKEN_RE.match(tok):
        raise ValueError("API-токен 3x-ui: возьмите в 3x-ui («Учетная запись → Токен API», область admin) и вставьте целиком")
    host = str(d.get("host", "")).strip()
    if host and not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес для подключения: имя или IP сервера")
    write_secure(XUI_F, 'XUI_URL="%s"\nXUI_TOKEN="%s"\nXUI_INSECURE="%s"\nXUI_HOST="%s"\n'
                 % (url, tok, "yes" if d.get("insecure") else "no", host), 0o600)
    h.act("xui-set", {"url": url, "insecure": bool(d.get("insecure"))})
    return {"ok": True, "msg": "сохранено"}


def api_xui_test(h, d):
    lst = xui_req("GET", "/panel/api/inbounds/list") or []
    awg = [x for x in lst if isinstance(x, dict) and x.get("protocol") == "amneziawg"]
    return {"ok": True, "msg": "3x-ui отвечает: подключений %d, из них AmneziaWG %d" % (len(lst), len(awg))}


def api_xui_create(h, d):
    """Создать в 3x-ui подключение AmneziaWG 3.1 для роутера и добавить туннель."""
    need_pw(h, d, "xui-create")
    name = str(d.get("name", "")).strip() or "awgxui"
    if not NAME_RE.match(name) or name in tunnels(env()) or os.path.exists(os.path.join(DD, name + ".conf")):
        raise ValueError("имя туннеля: awg и 1–10 строчных букв или цифр, не занятое (например awgxui)")
    go = bins_installed("amneziawg-go")
    if not go or vkey(go) < (3,):
        raise ValueError("на роутере amneziawg-go %s: AmneziaWG 3.1 требует v3.x — обновите бинарники («Система и обновление → "
                         "Проверить AmneziaWG → Обновить на роутере»)" % (go or "неизвестной версии"))
    c = xui_conf()
    host = xui_host(c)
    if not host or not HOST_OR_IP_RE.match(host):
        raise ValueError("не задан адрес сервера 3x-ui для подключения")
    lst = xui_req("GET", "/panel/api/inbounds/list", c=c) or []
    used = {int(x.get("port") or 0) for x in lst if isinstance(x, dict)}
    port = str(d.get("port", "")).strip()
    if port:
        if not re.match(r"^\d{4,5}$", port) or not 1024 <= int(port) <= 65535:
            raise ValueError("порт: 1024–65535")
        port = int(port)
        if port in used:
            raise ValueError("порт %d в 3x-ui уже занят другим подключением" % port)
    else:
        port = next(p for p in (secrets.randbelow(40000) + 20000 for _ in range(200)) if p not in used)
    priv, pub = awg_keypair()
    email = "udr-%s-%s-%s" % (re.sub(r"[^a-z0-9]", "", socket.gethostname().lower())[:16] or "router", name, secrets.token_hex(2))
    client = {"email": email, "enable": True, "publicKey": pub, "allowedIPs": ["10.8.1.2/32"], "keepAlive": 25,
              "limitIp": 0, "totalGB": 0, "expiryTime": 0, "tgId": 0, "subId": "", "comment": "UDR-Amnezia " + name, "reset": 0}
    ib = xui_req("POST", "/panel/api/inbounds/add", c=c, body={
        "remark": "UDR-Amnezia %s" % name, "enable": True, "port": port, "protocol": "amneziawg", "listen": "",
        "settings": json.dumps({"clients": [client]}), "streamSettings": "", "sniffing": "", "expiryTime": 0, "total": 0})
    try:
        st = json.loads((ib or {}).get("settings") or "{}")
        server = st.get("server") or {}
        mine = next(x for x in st.get("clients", []) if x.get("email") == email)
        addr = (mine.get("allowedIPs") or ["10.8.1.2/32"])[0]
        iid = int(ib.get("id"))
    except (ValueError, TypeError, StopIteration, AttributeError):
        raise ValueError("3x-ui создала подключение, но ответ не разобран: удалите «UDR-Amnezia %s» в 3x-ui вручную" % name)
    if not server.get("publicKey"):
        raise ValueError("3x-ui не вернула ключ сервера (версия 3x-ui ≥ 3.8.5?)")
    text = awg31_conf(server, priv, addr, host, port)
    try:
        rc, out = tunnel_add(name, text, "3x-ui")
    except ValueError:
        try:
            xui_req("POST", "/panel/api/inbounds/del/%d" % iid, c=c)
        except ValueError:
            pass
        raise
    with LOCK:
        m = xui_map()
        m[name] = {"inbound": iid, "email": email, "port": port, "host": host, "created": now()}
        write_secure(XUI_MAP_F, json.dumps(m), 0o600)
    h.act("xui-create", {"name": name, "inbound": iid, "port": port})
    for _ in range(25):                       # handshake: первый пакет уходит при подъёме (PersistentKeepalive)
        a = hs_age(name)
        if 0 <= a < 30:
            return {"ok": True, "msg": "туннель %s через 3x-ui работает: handshake есть (порт %d)" % (name, port)}
        time.sleep(1)
    return {"ok": False, "msg": "туннель %s добавлен, но handshake пока нет: откройте UDP %d в файрволе сервера 3x-ui "
            "(ufw и панель хостера) и проверьте через минуту" % (name, port)}


def api_xui_remove(h, d):
    """Убрать туннель, созданный через 3x-ui, и (по желанию) его подключение в 3x-ui."""
    need_pw(h, d, "xui-remove")
    name = str(d.get("name", ""))
    m = xui_map()
    if name not in m:
        raise ValueError("туннель не из 3x-ui")
    msg = []
    if d.get("delete_inbound", True):
        try:
            xui_req("POST", "/panel/api/inbounds/del/%d" % int(m[name]["inbound"]))
            msg.append("подключение в 3x-ui удалено")
        except ValueError as ex:
            msg.append("в 3x-ui не удалено: %s" % ex)
    if name in tunnels(env()):
        tunnel_remove(name)
        msg.append("туннель %s убран" % name)
    with LOCK:
        m.pop(name, None)
        write_secure(XUI_MAP_F, json.dumps(m), 0o600)
    h.act("xui-remove", name)
    return {"ok": True, "msg": "; ".join(msg)}
