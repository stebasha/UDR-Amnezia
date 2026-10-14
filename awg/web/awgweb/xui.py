# -*- coding: utf-8 -*-
"""3x-ui (#30, #32): туннели AmneziaWG 3.1 через API панелей 3x-ui по токену.

Панелей может быть несколько. Для каждой:
  • создать — роутер создаёт в 3x-ui (≥ 3.8.5) подключение amneziawg с одним клиентом — самим роутером. Ключ клиента
    создаётся на роутере, в 3x-ui уходит только открытый; ключи сервера и параметры AWG 3.1 генерирует 3x-ui;
  • подключить — туннель к уже существующему клиенту 3x-ui (его ключ хранит 3x-ui);
  • привязать — уже работающий туннель роутера (например, запасной) к его подключению в 3x-ui: по ключу сервера и порту.
Конфиг собирается из ответа API так же, как это делает сама 3x-ui (amneziaWGConfigText / genAmneziaWGConfig), адрес сервера —
как в ссылках 3x-ui (узел, shareAddrStrategy). «Обновить из 3x-ui» переносит изменённые в 3x-ui параметры на роутер."""
from .tools import *  # noqa: F401,F403  (всё из предыдущих модулей)
import urllib.error
import urllib.request

XUI_F = os.path.join(DD, "xui.env")              # одна панель (1.6 до #32) — переносится в xui.json
XUI_DB_F = os.path.join(DD, "xui.json")          # {"panels": {ID: {...}}, "tunnels": {ИМЯ: {...}}}, 600 (токены)
XUI_URL_RE = re.compile(r"^https?://[A-Za-z0-9.-]{1,253}(:\d{1,5})?(/[A-Za-z0-9._~%/-]*)?$")
XUI_TOKEN_RE = re.compile(r"^[A-Za-z0-9._~+/=-]{8,512}$")
XUI_SAFE = re.compile(r"^[^\x00-\x1f\x7f]*$")     # значения из ответа 3x-ui попадают в конфиг: без переводов строк
XUI_ID_RE = re.compile(r"^[a-z][a-z0-9]{0,11}$")
XUI_KINDS = {"created": "создан роутером", "imported": "клиент из 3x-ui", "linked": "привязан"}


def xui_db():
    """Панели и туннели; заодно перенос из формата 1.6-beta (xui.env + карта туннелей)."""
    try:
        d = json.loads(read_file(XUI_DB_F) or "{}")
    except ValueError:
        d = {}
    if not isinstance(d, dict):
        d = {}
    moved = False
    if "panels" not in d and "tunnels" not in d:
        d = {"panels": {}, "tunnels": {k: v for k, v in d.items() if isinstance(v, dict)}}
        moved = bool(d["tunnels"])
    d.setdefault("panels", {})
    d.setdefault("tunnels", {})
    old = parse_env_text(read_file(XUI_F))
    if old.get("XUI_URL") and not d["panels"]:
        d["panels"]["p1"] = {"label": "3x-ui", "url": old["XUI_URL"], "token": old.get("XUI_TOKEN", ""),
                             "insecure": old.get("XUI_INSECURE") == "yes", "host": old.get("XUI_HOST", "")}
        moved = True
    for v in d["tunnels"].values():
        if isinstance(v, dict):
            v.setdefault("panel", "p1")
            v.setdefault("kind", "created")
    if moved:
        xui_db_save(d)
    if os.path.exists(XUI_F) and d["panels"]:
        try:
            os.remove(XUI_F)                       # токен теперь только в xui.json
        except OSError:
            pass
    return d


def xui_db_save(d):
    write_secure(XUI_DB_F, json.dumps(d, ensure_ascii=False), 0o600)


def xui_map():
    return xui_db()["tunnels"]


def xui_panel(pid, db=None):
    """Панель по ID; пусто — единственная настроенная. → (ID, словарь)."""
    db = db or xui_db()
    pid = str(pid or "").strip()
    if not pid and len(db["panels"]) == 1:
        pid = next(iter(db["panels"]))
    if pid not in db["panels"]:
        raise ValueError("панель 3x-ui не выбрана или не настроена: добавьте её (адрес и API-токен)")
    return pid, db["panels"][pid]


def xui_req(method, path, body=None, p=None, timeout=20):
    """Запрос к API 3x-ui: Bearer-токен, ответ {success, msg, obj} → obj; ошибки — понятным ValueError."""
    p = p if p is not None else xui_panel("")[1]
    if not p.get("url") or not p.get("token"):
        raise ValueError("3x-ui не настроена: укажите адрес панели и API-токен")
    url = p["url"].rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    hdr = {"Authorization": "Bearer " + p["token"], "Accept": "application/json"}
    if data is not None:
        hdr["Content-Type"] = "application/json"
    ctx = None
    if url.startswith("https://"):
        ctx = ssl.create_default_context()
        if p.get("insecure"):
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


def ib_settings(ib):
    """settings подключения: объект (3x-ui ≥ 3.10) или JSON-строка (раньше)."""
    st = (ib or {}).get("settings")
    if isinstance(st, str):
        try:
            st = json.loads(st or "{}")
        except ValueError:
            st = {}
    return st if isinstance(st, dict) else {}


def ib_list(p):
    lst = xui_req("GET", "/panel/api/inbounds/list", p=p) or []
    return [x for x in lst if isinstance(x, dict)]


def ib_get(p, iid):
    for ib in ib_list(p):
        if int(ib.get("id") or 0) == int(iid):
            return ib
    raise ValueError("в 3x-ui нет подключения №%s" % iid)


def xui_nodes(p):
    """Узлы 3x-ui (ID → адрес) — для подключений, которые живут на другом сервере. Нет API узлов — пусто."""
    try:
        lst = xui_req("GET", "/panel/api/nodes/list", p=p, timeout=10) or []
    except ValueError:
        return {}
    return {int(n.get("id") or 0): str(n.get("address") or "") for n in lst if isinstance(n, dict)}


def _shareable(h):
    h = str(h or "").strip().strip("[]").lower()
    return bool(h) and not h.startswith(("/", "@", "127.")) and h not in ("0.0.0.0", "::", "::0", "::1", "localhost")


def ib_host(ib, p, nodes=None):
    """Адрес сервера для Endpoint — как resolveShareHost в 3x-ui: узел, listen, свой адрес; в конце — адрес панели."""
    node = ""
    if ib.get("nodeId"):
        nodes = xui_nodes(p) if nodes is None else nodes
        node = nodes.get(int(ib["nodeId"]), "")
    node = node if _shareable(node) else ""
    listen = ib.get("listen") if _shareable(ib.get("listen")) else ""
    custom = ib.get("shareAddr") if _shareable(ib.get("shareAddr")) else ""
    fb = p.get("host") or urllib.parse.urlparse(p.get("url", "")).hostname or ""
    strat = ib.get("shareAddrStrategy") or "node"
    if strat == "listen":
        h = listen or node or fb
    elif strat == "custom":
        h = custom or node or listen or fb
    else:
        h = node or listen or fb
    h = str(h).strip().strip("[]")
    if not HOST_OR_IP_RE.match(h):
        raise ValueError("3x-ui: не удалось определить адрес сервера подключения (%s) — укажите «Адрес сервера для туннеля»" % (h or "пусто"))
    return h


def awg31_conf(server, client_priv, address, host, port, psk=""):
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
    lines += ["", "[Peer]", "PublicKey = %s" % v("publicKey")]
    if psk:
        if not KEY_RE.match(psk):
            raise ValueError("3x-ui вернула недопустимый общий ключ (preSharedKey)")
        lines.append("PresharedKey = %s" % psk)
    lines += ["AllowedIPs = 0.0.0.0/0", "Endpoint = %s:%d" % (host, port), "PersistentKeepalive = 25", ""]
    return "\n".join(lines)


def awg_keypair():
    rc, priv = run([os.path.join(DD, "awg"), "genkey"], timeout=10)
    priv = priv.strip()
    pub = awg_pub(priv)
    if rc or not KEY_RE.match(priv) or not pub:
        raise ValueError("не удалось создать ключи на роутере (awg genkey)")
    return priv, pub


def awg_pub(priv):
    rc, pub = run([os.path.join(DD, "awg"), "pubkey"], timeout=10, inp=str(priv).strip() + "\n")
    pub = pub.strip()
    return pub if rc == 0 and KEY_RE.match(pub) else ""


def client_v4(cl):
    for a in cl.get("allowedIPs") or []:
        a = str(a).strip()
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$", a):
            return a if "/" in a else a + "/32"
    raise ValueError("у клиента 3x-ui нет IPv4-адреса (allowedIPs)")


def router_side():
    """Туннели роутера: ключ сервера, порт и открытый ключ роутера — для сопоставления с подключениями 3x-ui."""
    out = {}
    for t in tunnels(env()):
        f = conf_fields(read_file(conf_path(t)), masked=False)["fields"]
        ep = f["Peer"].get("Endpoint", "")
        port = int(ep.rsplit(":", 1)[1]) if re.match(r"^.+:\d{1,5}$", ep) else 0
        out[t] = {"server": f["Peer"].get("PublicKey", ""), "port": port, "pub": awg_pub(f["Interface"].get("PrivateKey", "")) if f["Interface"].get("PrivateKey") else ""}
    return out


def ib_match(ib, st, rs):
    """→ (туннель роутера, email клиента) для подключения, к которому уже ведёт туннель роутера, или ("", "")."""
    sp = str((st.get("server") or {}).get("publicKey") or "")
    for t, r in rs.items():
        if sp and r["server"] == sp and r["port"] == int(ib.get("port") or 0):
            em = next((str(c.get("email") or "") for c in st.get("clients", []) if isinstance(c, dict) and r["pub"] and c.get("publicKey") == r["pub"]), "")
            return t, em
    return "", ""


def need_go3():
    go = bins_installed("amneziawg-go")
    if not go or vkey(go) < (3,):
        raise ValueError("на роутере amneziawg-go %s: AmneziaWG 3.1 требует v3.x — обновите бинарники («Система и обновление → "
                         "Проверить AmneziaWG → Обновить на роутере»)" % (go or "неизвестной версии"))


def new_name(d, default):
    name = str(d.get("name", "")).strip() or default
    if not NAME_RE.match(name) or name in tunnels(env()) or os.path.exists(os.path.join(DD, name + ".conf")):
        raise ValueError("имя туннеля: awg и 1–10 строчных букв или цифр, не занятое (например %s)" % default)
    return name


def remember(name, rec):
    with LOCK:
        db = xui_db()
        db["tunnels"][name] = rec
        xui_db_save(db)


def wait_hs_msg(name, port, what):
    for _ in range(25):                       # handshake: первый пакет уходит при подъёме (PersistentKeepalive)
        a = hs_age(name)
        if 0 <= a < 30:
            return {"ok": True, "msg": "туннель %s %s: handshake есть" % (name, what)}
        time.sleep(1)
    return {"ok": False, "msg": "туннель %s добавлен, но handshake пока нет: проверьте, что UDP %d открыт в файрволе сервера "
            "(ufw и панель хостера), и посмотрите через минуту" % (name, port)}


# ---------------------------------------------------------------- API
def api_xui_get(h, q):
    db = xui_db()
    go = bins_installed("amneziawg-go")
    panels = [{"id": k, "label": v.get("label", ""), "url": v.get("url", ""), "token_set": bool(v.get("token")),
               "insecure": bool(v.get("insecure")), "host": v.get("host", ""),
               "host_default": urllib.parse.urlparse(v.get("url", "")).hostname or ""} for k, v in sorted(db["panels"].items())]
    tl = []
    for k, v in sorted(db["tunnels"].items()):
        x = dict(v, name=k)
        x["panel_label"] = (db["panels"].get(v.get("panel")) or {}).get("label", "")
        tl.append(x)
    return {"panels": panels, "go": go, "go_ok": bool(go) and vkey(go) >= (3,), "tunnels": tl}


def api_xui_set(h, d):
    """Сохранить панель: id пусто — новая (p1, p2, …). Токен пусто — прежний (в браузер не передаётся)."""
    with LOCK:
        db = xui_db()
        pid = str(d.get("id", "")).strip()
        if pid and pid not in db["panels"]:
            raise ValueError("нет такой панели 3x-ui")
        old = db["panels"].get(pid, {})
        url = str(d.get("url", "")).strip().rstrip("/")
        if not XUI_URL_RE.match(url):
            raise ValueError("адрес 3x-ui: https://узел:порт/секретный-путь (как в браузере, без /panel)")
        tok = str(d.get("token", "")).strip() or old.get("token", "")
        if not XUI_TOKEN_RE.match(tok):
            raise ValueError("API-токен 3x-ui: возьмите в 3x-ui («Учетная запись → Токен API», область admin) и вставьте целиком")
        host = str(d.get("host", "")).strip()
        if host and not HOST_OR_IP_RE.match(host):
            raise ValueError("адрес для подключения: имя или IP сервера")
        label = str(d.get("label", "")).strip()[:40] or urllib.parse.urlparse(url).hostname or "3x-ui"
        if re.search(r"[<>\"'&\x00-\x1f]", label):
            raise ValueError("недопустимые символы в названии панели")
        if not pid:
            pid = next("p%d" % i for i in range(1, 100) if "p%d" % i not in db["panels"])
        db["panels"][pid] = {"label": label, "url": url, "token": tok, "insecure": bool(d.get("insecure")), "host": host}
        xui_db_save(db)
    h.act("xui-set", {"id": pid, "url": url, "insecure": bool(d.get("insecure"))})
    return {"ok": True, "msg": "сохранено", "id": pid}


def api_xui_panel_remove(h, d):
    with LOCK:
        db = xui_db()
        pid, _ = xui_panel(d.get("id"), db)
        used = sorted(k for k, v in db["tunnels"].items() if v.get("panel") == pid)
        if used:
            raise ValueError("к панели относятся туннели %s: сначала уберите или отвяжите их" % ", ".join(used))
        db["panels"].pop(pid)
        xui_db_save(db)
    h.act("xui-panel-remove", pid)
    return {"ok": True, "msg": "панель убрана (в самой 3x-ui ничего не изменено)"}


def api_xui_test(h, d):
    pid, p = xui_panel(d.get("id") or d.get("panel"))
    lst = ib_list(p)
    awg = [x for x in lst if x.get("protocol") == "amneziawg"]
    return {"ok": True, "msg": "3x-ui отвечает: подключений %d, из них AmneziaWG %d" % (len(lst), len(awg))}


def api_xui_inbounds(h, q):
    """Подключения AmneziaWG панели: клиенты (без закрытых ключей), сервер, что из них уже связано с роутером."""
    pid, p = xui_panel((q.get("panel") or [""])[0])
    db = xui_db()
    rs = router_side()
    lst = [x for x in ib_list(p) if x.get("protocol") == "amneziawg"]
    nodes = xui_nodes(p) if any(x.get("nodeId") for x in lst) else {}
    out = []
    for ib in lst:
        st = ib_settings(ib)
        try:
            host = ib_host(ib, p, nodes)
        except ValueError:
            host = ""
        t, em = ib_match(ib, st, rs)
        mine = {k: v for k, v in db["tunnels"].items() if v.get("panel") == pid and int(v.get("inbound") or 0) == int(ib.get("id") or 0)}
        stats = {str(c.get("email")): c for c in (ib.get("clientStats") or []) if isinstance(c, dict)}
        cls = []
        for c in st.get("clients", []):
            if not isinstance(c, dict):
                continue
            e = str(c.get("email") or "")
            s_ = stats.get(e, {})
            cls.append({"email": e, "enable": bool(c.get("enable", True)), "address": ", ".join(str(a) for a in c.get("allowedIPs") or []),
                        "has_key": bool(c.get("privateKey")), "psk": bool(c.get("preSharedKey")), "router": e == em and bool(em),
                        "up": int(s_.get("up") or 0), "down": int(s_.get("down") or 0), "comment": str(c.get("comment") or "")[:60]})
        out.append({"id": ib.get("id"), "remark": str(ib.get("remark") or ""), "port": ib.get("port"), "enable": bool(ib.get("enable")),
                    "host": host, "node": bool(ib.get("nodeId")), "clients": cls, "match": t, "match_email": em,
                    "tunnels": sorted(mine)})
    return {"panel": pid, "inbounds": out}


def api_xui_create(h, d):
    """Создать в 3x-ui подключение AmneziaWG 3.1 для роутера и добавить туннель."""
    need_pw(h, d, "xui-create")
    name = new_name(d, "awgxui")
    need_go3()
    pid, p = xui_panel(d.get("panel"))
    lst = ib_list(p)
    used = {int(x.get("port") or 0) for x in lst}
    port = str(d.get("port", "")).strip()
    if port:
        if not re.match(r"^\d{4,5}$", port) or not 1024 <= int(port) <= 65535:
            raise ValueError("порт: 1024–65535")
        port = int(port)
        if port in used:
            raise ValueError("порт %d в 3x-ui уже занят другим подключением" % port)
    else:
        port = next(x for x in (secrets.randbelow(40000) + 20000 for _ in range(200)) if x not in used)
    host = ib_host({}, p)
    priv, pub = awg_keypair()
    email = "udr-%s-%s-%s" % (re.sub(r"[^a-z0-9]", "", socket.gethostname().lower())[:16] or "router", name, secrets.token_hex(2))
    client = {"email": email, "enable": True, "publicKey": pub, "allowedIPs": ["10.8.1.2/32"], "keepAlive": 25,
              "limitIp": 0, "totalGB": 0, "expiryTime": 0, "tgId": 0, "subId": "", "comment": "UDR-Amnezia " + name, "reset": 0}
    ib = xui_req("POST", "/panel/api/inbounds/add", p=p, body={
        "remark": "UDR-Amnezia %s" % name, "enable": True, "port": port, "protocol": "amneziawg", "listen": "",
        "settings": json.dumps({"clients": [client]}), "streamSettings": "", "sniffing": "", "expiryTime": 0, "total": 0})
    iid = 0
    try:
        iid = int((ib or {}).get("id") or 0)
        st = ib_settings(ib)
        server = st.get("server") or {}
        mine = next(x for x in st.get("clients", []) if x.get("email") == email)
        addr = client_v4(mine)
        if not server.get("publicKey"):
            raise ValueError("3x-ui не вернула ключ сервера (версия 3x-ui ≥ 3.8.5?)")
        text = awg31_conf(server, priv, addr, host, port, str(mine.get("preSharedKey") or ""))
        rc, out = tunnel_add(name, text, "3x-ui")
    except (ValueError, TypeError, StopIteration, AttributeError) as ex:
        msg = str(ex) if isinstance(ex, ValueError) else "ответ 3x-ui не разобран"
        if iid:                                    # подключение в 3x-ui создано, а туннель нет — не оставлять мусор
            try:
                xui_req("POST", "/panel/api/inbounds/del/%d" % iid, p=p)
                msg += "; подключение в 3x-ui удалено"
            except ValueError:
                msg += "; удалите «UDR-Amnezia %s» в 3x-ui вручную" % name
        raise ValueError(msg)
    remember(name, {"panel": pid, "kind": "created", "inbound": iid, "email": email, "port": port, "host": host, "created": now()})
    h.act("xui-create", {"panel": pid, "name": name, "inbound": iid, "port": port})
    return wait_hs_msg(name, port, "через 3x-ui работает (порт %d)" % port)


def api_xui_import(h, d):
    """Туннель к уже существующему клиенту подключения 3x-ui (ключ клиента хранит 3x-ui)."""
    need_pw(h, d, "xui-import")
    name = new_name(d, "awgxui")
    need_go3()
    pid, p = xui_panel(d.get("panel"))
    ib = ib_get(p, d.get("inbound") or 0)
    if ib.get("protocol") != "amneziawg":
        raise ValueError("это не подключение AmneziaWG")
    st = ib_settings(ib)
    email = str(d.get("email", ""))
    cl = next((c for c in st.get("clients", []) if isinstance(c, dict) and str(c.get("email")) == email), None)
    if not cl:
        raise ValueError("в подключении нет клиента %s" % email)
    priv = str(cl.get("privateKey") or "").strip()
    if not KEY_RE.match(priv):
        raise ValueError("закрытого ключа этого клиента в 3x-ui нет (клиент создан со своим ключом): подключить можно только клиента, "
                         "ключ которого сгенерировала 3x-ui; или создайте новый туннель")
    rs = router_side()
    pub = awg_pub(priv)
    if any(r["pub"] == pub for r in rs.values()):
        raise ValueError("этот клиент уже используется туннелем роутера — привяжите тот туннель вместо нового")
    port = int(ib.get("port") or 0)
    host = ib_host(ib, p)
    text = awg31_conf(st.get("server") or {}, priv, client_v4(cl), host, port, str(cl.get("preSharedKey") or ""))
    rc, out = tunnel_add(name, text, "3x-ui")
    remember(name, {"panel": pid, "kind": "imported", "inbound": int(ib.get("id")), "email": email, "port": port, "host": host, "created": now()})
    h.act("xui-import", {"panel": pid, "name": name, "inbound": ib.get("id")})
    return wait_hs_msg(name, port, "подключён к клиенту %s" % email)


def api_xui_link(h, d):
    """Привязать работающий туннель роутера к его подключению в 3x-ui (по ключу сервера и порту). Сеть не меняется."""
    pid, p = xui_panel(d.get("panel"))
    t = get_tunnel(str(d.get("name", "")))
    db = xui_db()
    if t in db["tunnels"]:
        raise ValueError("туннель %s уже связан с 3x-ui" % t)
    ib = ib_get(p, d.get("inbound") or 0)
    m, em = ib_match(ib, ib_settings(ib), {t: router_side()[t]})
    if m != t:
        raise ValueError("туннель %s ведёт не на это подключение: ключ сервера или порт не совпадают" % t)
    remember(t, {"panel": pid, "kind": "linked", "inbound": int(ib.get("id")), "email": em, "port": int(ib.get("port") or 0),
                 "host": "", "created": now()})
    h.act("xui-link", {"panel": pid, "name": t, "inbound": ib.get("id")})
    return {"ok": True, "msg": "туннель %s привязан к подключению №%s «%s»%s" % (t, ib.get("id"), ib.get("remark") or "", (", клиент " + em) if em else "")}


def api_xui_sync(h, d):
    """Перенести на роутер параметры подключения из 3x-ui (обфускация, ключ сервера, порт): ключ и адрес роутера не меняются."""
    need_pw(h, d, "xui-sync")
    name = get_tunnel(str(d.get("name", "")))
    rec = xui_map().get(name)
    if not rec:
        raise ValueError("туннель %s не связан с 3x-ui" % name)
    pid, p = xui_panel(rec.get("panel"))
    ib = ib_get(p, rec.get("inbound") or 0)
    st = ib_settings(ib)
    old = read_file(conf_path(name))
    f = conf_fields(old, masked=False)["fields"]
    priv = f["Interface"].get("PrivateKey", "")
    pub = awg_pub(priv)
    cl = next((c for c in st.get("clients", []) if isinstance(c, dict) and pub and c.get("publicKey") == pub), None)
    if not cl:
        raise ValueError("клиента с ключом роутера в подключении №%s нет: его удалили или сменили ключ в 3x-ui" % ib.get("id"))
    if not cl.get("enable", True):
        raise ValueError("клиент %s в 3x-ui выключен" % cl.get("email"))
    host = f["Peer"].get("Endpoint", "").rsplit(":", 1)[0] or ib_host(ib, p)
    text = awg31_conf(st.get("server") or {}, priv, f["Interface"].get("Address", "") or client_v4(cl), host,
                      int(ib.get("port") or 0), str(cl.get("preSharedKey") or ""))
    res = apply_conf_text(h, name, text, "из 3x-ui")
    if res.get("ok") and not res.get("unchanged"):
        remember(name, dict(rec, port=int(ib.get("port") or 0), synced=now()))
    return res


def api_xui_remove(h, d):
    """Созданный роутером — туннель и (по желанию) подключение в 3x-ui; клиент из 3x-ui — только туннель; привязанный — только связь."""
    need_pw(h, d, "xui-remove")
    name = str(d.get("name", ""))
    m = xui_map()
    if name not in m:
        raise ValueError("туннель не из 3x-ui")
    rec = m[name]
    kind = rec.get("kind", "created")
    msg = []
    if kind == "created" and d.get("delete_inbound", True):
        try:
            _, p = xui_panel(rec.get("panel"))
            xui_req("POST", "/panel/api/inbounds/del/%d" % int(rec["inbound"]), p=p)
            msg.append("подключение в 3x-ui удалено")
        except ValueError as ex:
            msg.append("в 3x-ui не удалено: %s" % ex)
    if kind != "linked" and name in env().get("TUNNELS_EXTRA", "").split():
        tunnel_remove(name)
        msg.append("туннель %s убран" % name)
    if kind == "linked":
        msg.append("связь с 3x-ui убрана; туннель %s работает как прежде" % name)
    with LOCK:
        db = xui_db()
        db["tunnels"].pop(name, None)
        xui_db_save(db)
    h.act("xui-remove", name)
    return {"ok": True, "msg": "; ".join(msg)}
