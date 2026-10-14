# -*- coding: utf-8 -*-
"""HTTP-сервер: обработчик запросов, таблица маршрутов API, запуск и командная строка."""
from .xui import *  # noqa: F401,F403  (всё из предыдущих модулей)
from .data import _OV  # noqa: F401

STATIC_FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
                "/app.js": ("app.js", "application/javascript; charset=utf-8"), "/app.css": ("app.css", "text/css; charset=utf-8"),
                "/favicon.svg": ("favicon.svg", "image/svg+xml"), "/lang-en.js": ("lang-en.js", "application/javascript; charset=utf-8")}
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")


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
            wait = RATE.allow(self.client_ip(), method == "POST")
            if wait:
                return self.send(429, {"error": "слишком много запросов: подождите %d с" % wait}, headers={"Retry-After": str(wait)})
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
    ("GET", "/api/backup/auto"): api_backup_auto_get,
    ("POST", "/api/backup/auto"): api_backup_auto_set,
    ("POST", "/api/backup/auto/run"): api_backup_auto_run,
    ("POST", "/api/backup/auto/test"): api_backup_auto_test,
    ("GET", "/api/xui"): api_xui_get,
    ("POST", "/api/xui"): api_xui_set,
    ("POST", "/api/xui/test"): api_xui_test,
    ("POST", "/api/xui/create"): api_xui_create,
    ("POST", "/api/xui/remove"): api_xui_remove,
    ("POST", "/api/xui/panel/remove"): api_xui_panel_remove,
    ("GET", "/api/xui/inbounds"): api_xui_inbounds,
    ("POST", "/api/xui/import"): api_xui_import,
    ("POST", "/api/xui/link"): api_xui_link,
    ("POST", "/api/xui/sync"): api_xui_sync,
    ("GET", "/api/vps"): api_vps_get,
    ("POST", "/api/vps"): api_vps_set,
    ("POST", "/api/vps/del"): api_vps_del,
    ("GET", "/api/tune"): api_tune_get,
    ("POST", "/api/tune/run"): api_tune_run,
    ("POST", "/api/tune/apply"): api_tune_apply,
    ("GET", "/api/lists"): api_lists_get,
    ("GET", "/api/report"): api_report,
    ("POST", "/api/lists/update"): api_lists_update,
    ("GET", "/api/routes"): api_routes_get,
    ("POST", "/api/route/save"): api_route_save,
    ("POST", "/api/route/remove"): api_route_remove,
    ("POST", "/api/route/switch"): api_route_switch,
    ("POST", "/api/vps/test"): api_vps_test,
    ("POST", "/api/vps/status"): api_vps_status,
    ("POST", "/api/vps/versions"): api_vps_versions,
    ("POST", "/api/vps/run"): api_vps_run,
    ("GET", "/api/vps/job"): api_vps_job,
    ("GET", "/api/hooks"): api_hooks_get,
    ("POST", "/api/hooks"): api_hooks_set,
    ("POST", "/api/hooks/test"): api_hooks_test,
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
    ("POST", "/api/sessions/config"): api_sessions_config,
}


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
    if cmd == "tunnel-add" and len(a) > 2:      # panel.py tunnel-add ИМЯ ФАЙЛ [НАЗВАНИЕ] — для vps.sh setup (#28)
        try:
            rc, out = tunnel_add(a[1], read_file(a[2]), a[3] if len(a) > 3 else "")
        except ValueError as ex:
            print("ОШИБКА: %s" % ex)
            sys.exit(2)
        audit("cli", "127.0.0.1", "tunnel-add", a[1])
        print(out.strip())
        sys.exit(0 if rc == 0 else 1)
    if cmd == "xui":                            # panel.py xui [ПАНЕЛЬ] — подключения AmneziaWG в 3x-ui, только чтение (#32)
        db = xui_db()
        if not db["panels"]:
            print("панелей 3x-ui нет")
            return
        for pid in ([a[1]] if len(a) > 1 else sorted(db["panels"])):
            p = db["panels"].get(pid) or {}
            print("== %s «%s» %s" % (pid, p.get("label", ""), p.get("url", "")))
            try:
                r = api_xui_inbounds(None, {"panel": [pid]})
            except ValueError as ex:
                print("  ОШИБКА: %s" % ex)
                continue
            for ib in r["inbounds"]:
                print("  №%s «%s» %s:%s %s%s%s" % (ib["id"], ib["remark"], ib["host"] or "?", ib["port"], "вкл" if ib["enable"] else "выкл",
                                                   (" · туннель роутера " + ib["match"]) if ib["match"] else "",
                                                   (" · связан: " + ", ".join(ib["tunnels"])) if ib["tunnels"] else ""))
                for c in ib["clients"]:
                    print("     клиент %s %s%s%s" % (c["email"], c["address"], " · ключ в 3x-ui" if c["has_key"] else "", " · роутер" if c["router"] else ""))
        for k, v in sorted(db["tunnels"].items()):
            print("туннель %s: панель %s, подключение №%s, %s" % (k, v.get("panel"), v.get("inbound"), XUI_KINDS.get(v.get("kind"), v.get("kind"))))
        return
    if cmd == "check":
        c = conf()
        print("порт %s, адрес %s, TLS %s, пользователей %d" % (c["WEB_PORT"], c["WEB_BIND"], c["WEB_TLS"], len(load_users())))
        return
    import __main__                     # справка — докстрока точки входа panel.py, а не этого модуля
    print(getattr(__main__, "__doc__", None) or __doc__)
