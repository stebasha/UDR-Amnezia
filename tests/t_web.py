#!/usr/bin/env python3
"""Тесты API веб-панели на стенде tests/web_lab.sh (без root, без сети)."""
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANEL_VERSION = re.search(r'^VERSION = "([^"]+)"', open(os.path.join(R, "awg/web/awgweb/core.py")).read(), re.M).group(1)
PORT = int(os.environ.get("WEB_TEST_PORT", "18471"))
LAB = tempfile.mkdtemp(prefix="awgweb-")
FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


class C:
    def __init__(self):
        self.cookie = ""
        self.csrf = ""

    def req(self, method, path, body=None, headers=None, raw=False):
        h = {"Host": "127.0.0.1:%d" % PORT}
        if self.cookie:
            h["Cookie"] = self.cookie
        if body is not None:
            body = json.dumps(body)
            h["Content-Type"] = "application/json"
            if self.csrf:
                h["X-CSRF"] = self.csrf
        h.update(headers or {})
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read()
        sc = r.getheader("Set-Cookie")
        if sc:
            self.cookie = sc.split(";")[0]
        c.close()
        if raw:
            return r.status, data, r
        try:
            return r.status, json.loads(data.decode())
        except ValueError:
            return r.status, data.decode("utf-8", "replace")

    def get(self, p, **k):
        return self.req("GET", p, **k)

    def post(self, p, b=None, **k):
        return self.req("POST", p, b if b is not None else {}, **k)

    def login(self, u="admin", pw="Test-pass-123", totp=None):
        s, j = self.post("/api/login", {"user": u, "password": pw, "totp": totp or ""})
        if s == 200 and j.get("csrf"):
            self.csrf = j["csrf"]
        return s, j


def totp(secret):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    d = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
    o = d[-1] & 15
    return "%06d" % ((struct.unpack(">I", d[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def job(c, payload, timeout=60):
    s, j = c.post("/api/tool", payload)
    if s != 200:
        return s, j
    t0 = time.time()
    while time.time() - t0 < timeout:
        s, r = c.get("/api/job?id=" + j["job"])
        if r.get("done"):
            return s, r
        time.sleep(0.3)
    return 0, {"out": "timeout"}


def restart_panel(pid, before=None):
    """Перезапуск панели стенда с тем же окружением (как systemctl restart awg-web). Возвращает новый PID."""
    env = dict(x.split("=", 1) for x in open("/proc/%s/environ" % pid).read().split("\0") if "=" in x)
    cmd = [x for x in open("/proc/%s/cmdline" % pid).read().split("\0") if x]
    cwd = os.readlink("/proc/%s/cwd" % pid)
    subprocess.call(["kill", pid])
    for _ in range(50):
        if not os.path.exists("/proc/%s" % pid):
            break
        time.sleep(0.1)
    if before:
        before()
    p = subprocess.Popen(cmd, env=env, cwd=cwd, stdout=open(os.path.join(LAB, "panel.log"), "a"), stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            http.client.HTTPConnection("127.0.0.1", PORT, timeout=1).request("GET", "/")
            break
        except OSError:
            time.sleep(0.1)
    time.sleep(0.3)
    return str(p.pid)


class FakeXui:
    """Поддельная 3x-ui (#30, #32): /secret/panel/api/inbounds/{list,add,del/ID}, /panel/api/nodes/list, Bearer-токен,
    ответ {success,msg,obj}. legacy=True — settings строкой (до 3.10), иначе объектом (3.10+)."""
    SRV = {"privateKey": "c2VydmVyLXByaXZhdGUta2V5LWZvci10ZXN0cy0xMjM=", "publicKey": "U0VSVkVSLVBVQkxJQy1LRVktRk9SLVRFU1RTLTEyMzQ=",
           "subnetIp": "10.8.1.0", "subnetCidr": 24, "mtu": 0, "jc": 4, "jmin": 50, "jmax": 200, "s1": 40, "s2": 120,
           "s3": 20, "s4": 16, "h1": "100000-200000", "h2": "300000-400000", "h3": "500000-600000", "h4": "700000-800000",
           "i1": "<r 64>", "headerProtectionKey": "aGVhZGVyLXByb3RlY3Rpb24ta2V5LTMyLWJ5dGVzLTAxMjM=",
           "contentPaddingAddition": "10-30", "rekeyAfterTime": "110-130", "rejectAfterTime": "170-220",
           "rekeyTimeout": "4-6", "randomTrailers": True, "disableCookies": False}

    def __init__(self, token="xui-token-123456", existing=None):
        import http.server
        import threading
        self.token, self.added, self.next_id, self.legacy = token, [], 50, False
        self.inbounds = [{"id": 1, "port": 2053, "protocol": "vless", "settings": {"clients": []}}] + (existing or [])
        fx = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def auth(self):
                if self.headers.get("Authorization") != "Bearer " + fx.token:
                    self.reply(401, {"success": False, "msg": "unauthorized"})
                    return False
                return True

            def out(self, ib):
                return dict(ib, settings=json.dumps(ib["settings"]) if fx.legacy else ib["settings"])

            def do_GET(self):
                if self.path == "/secret/panel/api/nodes/list":
                    if self.auth():
                        self.reply(200, {"success": True, "msg": "", "obj": [{"id": 2, "name": "us", "address": "us.example.net"}]})
                    return
                if self.path != "/secret/panel/api/inbounds/list":
                    return self.reply(404, {})
                if self.auth():
                    self.reply(200, {"success": True, "msg": "", "obj": [self.out(x) for x in fx.inbounds]})

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                if not self.path.startswith("/secret/panel/api/inbounds/"):
                    return self.reply(404, {})
                if not self.auth():
                    return
                if self.path.endswith("/add"):
                    ib = json.loads(body)
                    fx.added.append(ib)
                    st = json.loads(ib["settings"]) if isinstance(ib["settings"], str) else ib["settings"]
                    st["server"] = dict(FakeXui.SRV)
                    fx.next_id += 1
                    rec = dict(ib, id=fx.next_id, settings=st)
                    fx.inbounds.append(rec)
                    return self.reply(200, {"success": True, "msg": "ok", "obj": self.out(rec)})
                m = re.match(r".*/del/(\d+)$", self.path)
                if m:
                    fx.inbounds = [x for x in fx.inbounds if x["id"] != int(m.group(1))]
                    return self.reply(200, {"success": True, "msg": "ok", "obj": int(m.group(1))})
                self.reply(404, {})

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()


def main():
    pid = subprocess.check_output([os.path.join(R, "tests/web_lab.sh"), LAB, str(PORT)]).decode().strip().splitlines()[-1]
    dd = os.path.join(LAB, "dd")
    try:
        a = C()
        s, j = a.get("/api/session")
        check("без входа → 401", s == 401 and j.get("setup") is False, j)
        s, j = a.get("/api/overview")
        check("API без входа закрыт", s == 401, s)
        s, b, r = a.get("/", raw=True)
        check("страница отдаётся с CSP", s == 200 and "script-src 'self'" in (r.getheader("Content-Security-Policy") or ""), s)
        s, b, r = a.get("/../web/panel.py", raw=True)
        check("файлы вне списка не отдаются", s == 404, s)
        s, j = a.get("/api/session", headers={"Host": "evil.example:%d" % PORT})
        check("чужой Host (DNS rebinding) → 421", s == 421, s)

        s, j = a.login(pw="wrong")
        check("неверный пароль → 401", s == 401, j)
        s, j = a.post("/api/login", {"user": "admin", "password": "Test-pass-123"}, headers={"Origin": "http://evil.example"})
        check("вход с чужой страницы отклонён", s == 403, j)
        s, j = a.login()
        check("вход", s == 200 and a.csrf and "awgsid=" in a.cookie, j)
        ck = [x for x in open(os.path.join(LAB, "panel.log")).read().splitlines()]
        s, j = a.get("/api/session")
        check("сессия", s == 200 and j["user"] == "admin", j)

        s, j = a.post("/api/tunnel/auto", {}, headers={"X-CSRF": "bad"})
        check("POST без верного CSRF → 403", s == 403, j)
        s, j = a.post("/api/tunnel/auto", {}, headers={"Origin": "http://evil.example"})
        check("POST с чужим Origin → 403", s == 403, j)

        s, ov = a.get("/api/overview")
        check("обзор: 3 туннеля", s == 200 and [t["name"] for t in ov["tunnels"]] == ["awgmain", "awgbackup", "awgalt1"], ov)
        check("обзор: активный awgmain", ov.get("active") == "awgmain", ov.get("active"))
        check("обзор: kill switch", ov["pbr"]["killswitch"] is True)
        st = {t["name"]: t["status"] for t in ov["tunnels"]}
        check("обзор: статусы", st == {"awgmain": "active", "awgbackup": "standby", "awgalt1": "nohs"}, st)
        check("обзор: AWG 2.0 у основного", ov["tunnels"][0]["proto"] in ("AWG 2.0", "AWG 3.x"), ov["tunnels"][0]["proto"])
        check("обзор: статистика 7 дней", ov["stats"]["switch"] == 1 and ov["stats"]["degrade"] == 1, ov["stats"])
        check("в обзоре нет ключей", "aGVsbG8" not in json.dumps(ov), "")

        s, j = a.get("/api/tunnel/conf?name=awgmain")
        check("конфиг: ключи скрыты", s == 200 and "<скрыто>" in j["text"] and "aGVsbG8" not in j["text"], j)
        orig = open(os.path.join(dd, "main.conf")).read()
        txt = j["text"].replace("Jc = 4", "Jc = 5")
        s, j = a.post("/api/tunnel/conf", {"name": "awgmain", "text": txt})
        new = open(os.path.join(dd, "main.conf")).read()
        check("конфиг: сохранён, ключи восстановлены", s == 200 and j["ok"] and "Jc = 5" in new and "aGVsbG8taGVsbG8" in new and "cHNrLXBzay" in new, (j, new))
        check("конфиг: прежняя версия .prev", open(os.path.join(dd, "main.conf.prev")).read() == orig)
        check("конфиг: права 600", oct(os.stat(os.path.join(dd, "main.conf")).st_mode & 0o777) == "0o600")
        s, j = a.post("/api/tunnel/conf", {"name": "awgmain", "text": txt + "PostUp = rm -rf /\n"})
        check("конфиг: PostUp отклонён", s == 400 and "PostUp" in j["error"], j)
        s, j = a.post("/api/tunnel/conf", {"name": "../etc/passwd", "text": txt})
        check("конфиг: чужое имя отклонено", s == 404, j)

        s, j = a.post("/api/tunnel/add", {"name": "awgnl", "label": "Нидерланды", "text": orig})
        env = open(os.path.join(dd, "awg.env")).read()
        check("добавление туннеля", s == 200 and 'TUNNELS_EXTRA="awgalt1 awgnl"' in env and os.path.exists(os.path.join(dd, "awgnl.conf")), (j, env))
        s, j = a.post("/api/tunnel/add", {"name": "eth0", "text": orig})
        check("добавление: имя проверяется", s == 400, j)
        s, j = a.post("/api/tunnel/remove", {"name": "awgmain"})
        check("основной из панели не удаляется", s == 400, j)
        s, j = a.post("/api/tunnel/remove", {"name": "awgnl"})
        check("удаление туннеля без пароля запрещено (#21)", s == 403 and "awgnl" in open(os.path.join(dd, "awg.env")).read(), j)
        s, j = a.post("/api/tunnel/remove", {"name": "awgnl", "current": "Test-pass-123"})
        env = open(os.path.join(dd, "awg.env")).read()
        check("удаление доп. туннеля", s == 200 and "awgnl" not in env, (j, env))
        s, j = a.post("/api/tunnel/label", {"name": "awgmain", "label": "<script>"})
        check("название: опасные символы отклонены", s == 400, j)
        s, j = a.post("/api/tunnel/label", {"name": "awgmain", "label": "Германия"})
        s2, ov = a.get("/api/overview")
        check("название сохраняется", ov["tunnels"][0]["label"] == "Германия", ov["tunnels"][0])

        s, j = a.get("/api/settings")
        check("настройки читаются", s == 200 and j["values"]["TUN_DOMAINS"] == "youtube.com googlevideo.com", j)
        s, j = a.post("/api/settings", {"values": {"TUN_DOMAINS": "youtube.com; rm -rf /"}})
        check("настройки: мусор в доменах отклонён", s == 400, j)
        s, j = a.post("/api/settings", {"values": {"TABLE": "main"}})
        check("настройки: PBR из панели не меняется", s == 400, j)
        s, j = a.post("/api/settings", {"values": {"RECOVER_SEC": "5"}})
        check("настройки: границы чисел", s == 400, j)
        s, j = a.post("/api/settings", {"values": {"TUN_DOMAINS": "YouTube.com\nhttps://googlevideo.com/x ytimg.com", "RECOVER_SEC": "900", "EXTRA_SUBNETS": "192.168.3.7/24"}})
        env = open(os.path.join(dd, "awg.env")).read()
        check("настройки: сохранены и нормализованы", s == 200 and 'TUN_DOMAINS="youtube.com googlevideo.com ytimg.com"' in env
              and "RECOVER_SEC=900" in env and "EXTRA_SUBNETS=192.168.3.0/24" in env and "MAIN=awgmain" in env, (j, env))

        s, j = a.post("/api/service", {"name": "awg-failover", "action": "disable"})
        check("сторож не выключается из панели", s == 400, j)
        s, j = a.post("/api/service", {"name": "sshd", "action": "restart"})
        check("чужие службы недоступны", s == 400, j)

        s, j = a.post("/api/tool", {"tool": "rm"})
        check("неизвестный инструмент отклонён", s == 400, j)
        s, j = job(a, {"tool": "domain-check", "domain": "youtube.com"})
        check("проверка домена выполняется", s == 200 and "Домен: youtube.com" in j["out"] and "TUN_DOMAINS" in j["out"], j)
        s, j = a.post("/api/tool", {"tool": "domain-check", "domain": "a.com; reboot"})
        check("проверка домена: имя проверяется", s == 400, j)
        s, j = job(a, {"tool": "diagnose"}, 120)
        check("диагностика выполняется", s == 200 and j["done"] and len(j["out"]) > 100, j)

        s, j = a.get("/api/logs?kind=audit")
        check("журнал действий пишется", s == 200 and "conf-set" in j["text"] and "settings" in j["text"], j)
        s, j = a.get("/api/logs?kind=../../etc/passwd")
        check("журналы: только из списка", s == 400, j)

        s, j = a.post("/api/backup/create", {"password": "123"})
        check("копия: короткий пароль отклонён", s == 400, j)
        s, j = a.post("/api/backup/create", {"password": "backup-pass-1"})
        s, j = a.get("/api/backups")
        check("копия создаётся", s == 200 and len(j["backups"]) == 1 and j["backups"][0]["enc"], j)
        name = j["backups"][0]["name"]
        s, b, r = a.get("/api/backup/file?name=" + name, raw=True)
        check("копия скачивается", s == 200 and len(b) == 4000 and "attachment" in r.getheader("Content-Disposition"), s)
        s, b, r = a.get("/api/backup/file?name=../awg.env", raw=True)
        check("скачивание: обход пути закрыт", s == 404, s)

        s, j = a.post("/api/passwd", {"user": "viewer", "password": "short", "current": "Test-pass-123"})
        check("пароль: слабый отклонён", s == 400, j)
        s, j = a.post("/api/passwd", {"user": "viewer", "password": "Viewer-pass-12", "current": "wrong"})
        check("пароль: нужен текущий пароль", s == 403, j)
        s, j = a.post("/api/passwd", {"user": "viewer", "password": "Viewer-pass-12", "current": "Test-pass-123"})
        check("новый пользователь", s == 200 and "создан" in j["msg"], j)
        b2 = C()
        s, j = b2.login("viewer", "Viewer-pass-12")
        check("новый пользователь входит", s == 200, j)

        s, j = a.post("/api/totp/begin", {})
        sec = j["secret"]
        s, j = a.post("/api/totp/enable", {"secret": sec, "code": "000000"})
        check("2FA: неверный код", s == 400, j)
        s, j = a.post("/api/totp/enable", {"secret": sec, "code": totp(sec)})
        check("2FA включена", s == 200, j)
        c3 = C()
        s, j = c3.login()
        check("2FA: пароль без кода → need_totp", s == 200 and j.get("need_totp") and not c3.csrf, j)
        s, j = c3.login(totp=totp(sec))
        check("2FA: вход с кодом", s == 200 and c3.csrf, j)
        s, j = a.post("/api/totp/disable", {"current": "Test-pass-123"})
        check("2FA выключена", s == 200, j)

        s, j = a.post("/api/user/delete", {"user": "viewer", "current": "Test-pass-123"})
        s2, j2 = b2.get("/api/overview")
        check("удалённый пользователь теряет сессию", s == 200 and s2 == 401, (j, s2))

        # ---------- 1.4: поля конфига, история, импорт, экспорт
        s, j = a.get("/api/tunnel/fields?name=awgbackup")
        check("поля: читаются, ключи скрыты", s == 200 and j["fields"]["Interface"]["Jc"] == "4" and j["fields"]["Interface"]["PrivateKey"] == "<скрыто>"
              and j["fields"]["Peer"]["Endpoint"] == "203.0.113.77:443", j)
        s, j = a.post("/api/tunnel/preview", {"name": "awgbackup", "fields": {"Interface": {"Jc": "7", "MTU": "1380"}, "Peer": {"PersistentKeepalive": ""}}})
        check("поля: предпросмотр", s == 200 and not j["errors"] and "Jc = 7" in j["new"] and "MTU = 1380" in j["new"]
              and "PersistentKeepalive" not in j["new"] and "aGVsbG8" not in j["new"], j)
        s, j = a.post("/api/tunnel/preview", {"name": "awgbackup", "fields": {"Interface": {"Jmin": "900", "Jmax": "100", "S1": "abc"}}})
        check("поля: ошибки значений", s == 200 and any("Jmin" in x for x in j["errors"]) and any("S1" in x for x in j["errors"]), j)
        s, j = a.post("/api/tunnel/conf", {"name": "awgbackup", "fields": {"Peer": {"Endpoint": "bad endpoint"}}})
        check("поля: неверный Endpoint не сохраняется", s == 400, j)
        s, j = a.post("/api/tunnel/conf", {"name": "awgbackup", "fields": {"Interface": {"PrivateKey": "short"}}})
        check("поля: неверный ключ не сохраняется", s == 400, j)
        bk = open(os.path.join(dd, "backup.conf")).read()
        s, j = a.post("/api/tunnel/conf", {"name": "awgbackup", "fields": {"Interface": {"Jc": "7"}}})
        nb = open(os.path.join(dd, "backup.conf")).read()
        check("поля: сохранены, ключи на месте", s == 200 and j["ok"] and "Jc = 7" in nb and "PresharedKey = cHNrLXBzay" in nb, (j, nb))
        s, j = a.get("/api/tunnel/revisions?name=awgbackup")
        revs = j.get("revisions", [])
        check("история версий", s == 200 and len(revs) == 2 and revs[0]["current"] and not revs[1]["current"], j)
        s, j = a.get("/api/tunnel/revision?name=awgbackup&id=" + revs[-1]["id"])
        check("версия: ключи скрыты", s == 200 and "Jc = 4" in j["text"] and "aGVsbG8" not in j["text"], j)
        s, j = a.post("/api/tunnel/revision/restore", {"name": "awgbackup", "id": revs[-1]["id"]})
        check("возврат версии", s == 200 and j["ok"] and open(os.path.join(dd, "backup.conf")).read() == bk, j)
        s, j = a.get("/api/tunnel/revision?name=awgbackup&id=../../awg.env")
        check("версия: обход пути закрыт", s == 404, j)
        s, j = a.post("/api/tunnel/export", {"name": "awgbackup", "current": "nope"})
        check("экспорт конфига без пароля закрыт", s == 403, j)
        s, j = a.post("/api/tunnel/export", {"name": "awgbackup", "current": "Test-pass-123"})
        check("экспорт конфига с паролем", s == 200 and "PrivateKey = aGVsbG8" in j["text"], s)

        conf_txt = open(os.path.join(dd, "main.conf")).read().replace("198.51.100.20", "192.0.2.99")
        s, j = a.post("/api/import/parse", {"data": conf_txt})
        check("импорт .conf: разбор", s == 200 and j["ok"] and j["token"] and "aGVsbG8" not in json.dumps(j) and j["proto"] == "AWG 2.0", j)
        import zlib as _z
        amn = {"containers": [{"container": "amnezia-awg", "awg": {"last_config": json.dumps({"config": conf_txt.replace("192.0.2.99", "192.0.2.98")})}}],
               "dns1": "1.1.1.1", "description": "Мой сервер"}
        raw = json.dumps(amn).encode()
        link = "vpn://" + base64.urlsafe_b64encode(struct.pack(">I", len(raw)) + _z.compress(raw)).decode().rstrip("=")
        s, j = a.post("/api/import/parse", {"data": link})
        check("импорт vpn://: разбор", s == 200 and j["ok"] and j["source"] == "vpn://" and j["fields"]["Peer"]["Endpoint"] == "192.0.2.98:51820", j)
        tok = j["token"]
        s, j = a.post("/api/import/parse", {"data": "vpn://AAAA"})
        check("импорт: битая ссылка", s == 400, j)
        s, j = a.post("/api/import/parse", {"data": "[Interface]\nPrivateKey = x\n"})
        check("импорт: неполный конфиг", s == 200 and not j["ok"] and j["errors"] and not j["token"], j)
        s, j = a.post("/api/import/apply", {"token": tok, "target": "new", "name": "awgimp", "label": "Импорт"})
        env = open(os.path.join(dd, "awg.env")).read()
        check("импорт: новый туннель", s == 200 and "awgimp" in env and "192.0.2.98" in open(os.path.join(dd, "awgimp.conf")).read(), (j, env))
        s, j = a.post("/api/import/parse", {"data": conf_txt})
        s, j = a.post("/api/import/apply", {"token": j["token"], "target": "awgimp"})
        check("импорт: замена конфига туннеля", s == 200 and "192.0.2.99" in open(os.path.join(dd, "awgimp.conf")).read(), j)
        s, j = a.post("/api/import/apply", {"token": "fake", "target": "awgimp"})
        check("импорт: чужой/старый токен", s == 400, j)
        s, j = a.post("/api/tunnel/order", {"extra": ["awgimp", "awgalt1"]})
        check("порядок доп. туннелей", s == 200 and 'TUNNELS_EXTRA="awgimp awgalt1"' in open(os.path.join(dd, "awg.env")).read(), j)
        s, j = a.post("/api/tunnel/order", {"extra": ["awgimp", "awgmain"]})
        check("порядок: подмена списка отклонена", s == 400, j)
        a.post("/api/tunnel/remove", {"name": "awgimp", "current": "Test-pass-123"})

        # ---------- клиенты, сеансы, настройки, обновление
        s, j = a.get("/api/clients")
        cl = {c["ip"]: c for c in j.get("clients", [])}
        check("клиенты в туннеле", s == 200 and set(cl) == {"192.168.1.20", "192.168.1.41"} and cl["192.168.1.20"]["conns"] == 2
              and cl["192.168.1.20"]["name"] == "iPhone-Aleks" and cl["192.168.1.20"]["bytes"] == 98000, j)
        s, j = a.get("/api/sessions")
        check("сеансы", s == 200 and any(x["me"] for x in j["sessions"]) and len(j["sessions"]) >= 2, j)
        other = [x for x in j["sessions"] if not x["me"]]
        s, j = a.post("/api/session/revoke", {"id": "others"})
        s2, j2 = c3.get("/api/overview")
        s3, j3 = a.get("/api/overview")
        check("завершить другие сеансы", s == 200 and s2 == 401 and s3 == 200, (s2, s3))
        # ---------- 1.5 (#7): сеансы переживают перезапуск панели; в файле только хэши
        sj = open(os.path.join(dd, "web", "sessions.json")).read()
        tok = a.cookie.split("=", 1)[1]
        check("сеансы: файл 600, токена в нём нет, есть хэш", oct(os.stat(os.path.join(dd, "web", "sessions.json")).st_mode & 0o777) == "0o600"
              and tok not in sj and hashlib.sha256(tok.encode()).hexdigest() in sj, sj[:200])
        pid = restart_panel(pid)
        s, j = a.get("/api/overview")
        check("сеансы: после перезапуска панели вход не нужен", s == 200, s)
        s, j = a.post("/api/tunnel/label", {"name": "awgmain", "label": ""})
        check("сеансы: CSRF после перезапуска тот же", s == 200, j)
        s, j = a.post("/api/session/revoke", {"id": "../../x"})
        check("сеансы: мусорный id отклонён", s == 400, j)
        c5 = C(); c5.login()
        s, j = a.get("/api/sessions")
        other = [x["id"] for x in j["sessions"] if not x["me"]]
        s, j = a.post("/api/session/revoke", {"id": other[0]})
        check("сеансы: завершение по id", s == 200 and c5.get("/api/overview")[0] == 401 and a.get("/api/overview")[0] == 200, other)
        # ---------- 1.5 (#21): время жизни сеансов, ротация журнала, частота запросов
        s, j = a.post("/api/sessions/config", {"idle": "2", "max": "12", "current": "Test-pass-123"})
        check("сеансы: границы времени проверяются", s == 400, j)
        s, j = a.post("/api/sessions/config", {"idle": "30", "max": "12", "current": "nope"})
        check("сеансы: настройка только с паролем", s == 403, j)
        s, j = a.post("/api/sessions/config", {"idle": "30", "max": "12", "current": "Test-pass-123"})
        s2, j2 = a.get("/api/sessions")
        wc = open(os.path.join(dd, "web", "web.conf")).read()
        check("сеансы: время жизни сохранено без перезапуска", s == 200 and "WEB_SESSION_IDLE" in wc and j2["idle"] == 30 and j2["max"] == 12, (j, j2))
        c6 = C(); c6.login()
        sid6 = hashlib.sha256(c6.cookie.split("=", 1)[1].encode()).hexdigest()

        def age_c6():
            sf = os.path.join(dd, "web", "sessions.json")
            x = json.load(open(sf))
            x["sessions"][sid6]["seen"] -= 31 * 60
            open(sf, "w").write(json.dumps(x))
        pid = restart_panel(pid, before=age_c6)
        check("сеансы: простой дольше настройки — выход", c6.get("/api/overview")[0] == 401 and a.get("/api/overview")[0] == 200)
        a.post("/api/sessions/config", {"idle": "120", "max": "12", "current": "Test-pass-123"})
        af = os.path.join(dd, "web", "audit.log")
        with open(af, "a") as f:
            f.write(("2026-01-01 00:00:00 127.0.0.1 admin old-entry\n") * 13000)
        a.post("/api/tunnel/label", {"name": "awgmain", "label": ""})
        a.post("/api/tunnel/label", {"name": "awgmain", "label": ""})
        s, j = a.get("/api/logs?kind=audit&n=3000")
        check("журнал действий: ротация в audit.log.1, просмотр видит оба", os.path.exists(af + ".1") and os.path.getsize(af) < 4096
              and "old-entry" in j["text"] and " label " in j["text"].splitlines()[-1], (os.path.getsize(af), j["text"][-200:]))

        def low_rate():
            with open(os.path.join(dd, "web", "web.conf"), "a") as f:
                f.write("WEB_RATE=30\n")
        pid = restart_panel(pid, before=low_rate)
        codes = [a.req("GET", "/api/overview", raw=True) for _ in range(35)]
        lim = [r for st_, b_, r in codes if st_ == 429]
        check("частота API: сверх лимита — 429 с Retry-After", len(lim) >= 4 and int(lim[0].getheader("Retry-After")) > 0, [c[0] for c in codes])

        def norm_rate():
            wf = os.path.join(dd, "web", "web.conf")
            keep = "".join(x for x in open(wf) if not x.startswith("WEB_RATE="))
            open(wf, "w").write(keep)
        pid = restart_panel(pid, before=norm_rate)
        check("частота API: после снятия лимита работает", a.get("/api/overview")[0] == 200)
        s, j = a.get("/api/settings/export")
        check("экспорт настроек без секретов", s == 200 and j["format"] == "udr-amnezia-settings" and "PrivateKey" not in json.dumps(j)
              and j["settings"]["RECOVER_SEC"] == "900", j)
        j["settings"]["RECOVER_SEC"] = "1200"
        s, r = a.post("/api/settings/import", {"data": j, "current": "wrong"})
        check("импорт настроек без верного пароля запрещён (#21)", s == 403 and "RECOVER_SEC=1200" not in open(os.path.join(dd, "awg.env")).read(), r)
        s, r = a.post("/api/settings/import", {"data": j, "current": "Test-pass-123"})
        check("импорт настроек", s == 200 and "RECOVER_SEC=1200" in open(os.path.join(dd, "awg.env")).read(), r)
        s, j = a.post("/api/settings/import", {"data": {"format": "other"}, "current": "Test-pass-123"})
        check("импорт настроек: чужой файл", s == 400, j)
        s, j = a.get("/api/web")
        check("настройки панели читаются", s == 200 and j["port"] == str(PORT), j)
        s, j = a.post("/api/web", {"port": "8443"})
        check("порт UniFi отклонён", s == 400, j)
        for bad in ("0.0.0.0/0", "0.0.0.0/1", "8.8.8.0/24", "192.168.0.0/15", "::/0"):
            s, j = a.post("/api/web", {"port": str(PORT), "allow": bad})
            check("панель в интернет не открыть: %s" % bad, s == 400, j)
        s, j = a.get("/api/system")
        check("канал по умолчанию — stable", j.get("channel") == "stable", j.get("channel"))
        s, j = a.post("/api/update/channel", {"channel": "beta"})
        chf = open(os.path.join(dd, ".channel")).read()
        check("канал: переключение на beta записано", s == 200 and "AWG_CHANNEL=beta" in chf and "AWG_BRANCH=main" in chf, chf)
        s, j = a.post("/api/update/channel", {"channel": "branch", "branch": "../../etc"})
        check("канал: опасное имя ветки отклонено", s == 400, j)
        s, j = a.post("/api/update/channel", {"channel": "stable"})
        s, j = a.post("/api/update/check", {})
        check("проверка обновлений: stable без релизов → ветка main", s == 200 and j["channel"] == "stable" and j["ref"] == "main" and j["kind"] == "branch"
              and "AWG_CHANNEL=stable" in j["cmd"], j)
        s, j = a.post("/api/bins/check", {"force": True})
        check("бинарники: GitHub недоступен → неизвестно, без ложного «обновить»", s == 200 and not j["update"] and all(x["state"] == "unknown" for x in j["items"]), j)
        open(os.path.join(LAB, "stub", "gh"), "w").close()
        s, j = a.post("/api/bins/check", {"force": True})
        it = {x["name"]: x for x in j.get("items", [])}
        check("бинарники: amneziawg-go устарел, awg актуален (тег из списка без мусора)", s == 200 and j["update"]
              and it["amneziawg-go"]["state"] == "update" and it["amneziawg-go"]["latest"] == "v3.1.20260901"
              and it["awg"]["state"] == "ok" and it["awg"]["installed"] == "v3.1.20260812" and "vps.sh router-bins" in j["cmd"] and j["vps_ready"] is False, j)
        go = os.path.join(dd, "amneziawg-go")
        keep = open(go).read()
        open(go, "w").write('#!/bin/bash\nprintf "amneziawg-go 0.0.20250522\\n\\nUserspace AmneziaWG daemon for linux-arm64.\\n"\n')
        s, j = a.post("/api/bins/check", {})
        check("бинарники: старая сборка без «v» распознана и устарела (как на UDR7)", s == 200 and j["items"][0]["installed"] == "v0.0.20250522"
              and j["items"][0]["state"] == "update", j)
        open(go, "w").write(keep)
        with open(os.path.join(dd, ".binsver"), "w") as f:
            f.write("amneziawg-go v3.1.20260901 %s\n" % hashlib.sha256(open(go, "rb").read()).hexdigest())
        s, j = a.post("/api/bins/check", {})
        check("бинарники: тег сборки из .binsver (сумма совпала)", s == 200 and not j["update"] and j["items"][0]["installed"] == "v3.1.20260901", j)
        os.remove(os.path.join(LAB, "stub", "gh")); os.remove(os.path.join(dd, ".binsver"))
        for v, upd, older in (("1.4.3", False, True), ("99.0.0", True, False), (PANEL_VERSION, False, False)):
            open(os.path.join(LAB, "stub", "ver"), "w").write(v + "\n")
            s, j = a.post("/api/update/check", {})
            check("проверка обновлений: в канале %s — %s" % (v, "обновление" if upd else "старее, не предлагать" if older else "актуально"),
                  s == 200 and j["update"] is upd and j["older"] is older, j)
        os.remove(os.path.join(LAB, "stub", "ver"))
        s, j = a.post("/api/update/run", {})
        check("обновление запускается отдельной службой", s == 200 and "awg-update" in open(os.path.join(LAB, "systemd-run.log")).read(), j)
        s, j = a.get("/api/update/log")
        check("журнал обновления", s == 200 and "запущено из панели" in j["text"], j)
        s, j = job(a, {"tool": "drift-save"})
        check("эталон снимается", s == 200 and os.path.exists(os.path.join(dd, "drift.base")), j)
        s, j = job(a, {"tool": "drift"})
        check("сверка с эталоном: совпадает", s == 200 and j["rc"] == 0 and "совпадают" in j["out"], j)
        open(os.path.join(LAB, "stub", "table"), "w").write("default dev awgmain metric 5\n")
        s, j = job(a, {"tool": "drift"})
        check("сверка: пропавший blackhole найден", s == 200 and j["rc"] == 1 and "blackhole" in j["out"], j)
        open(os.path.join(LAB, "stub", "table"), "w").write("default dev awgmain metric 5\nblackhole default metric 200\n")
        s, j = a.post("/api/net", {"kind": "ping", "host": "1.1.1.1; reboot", "iface": "awgmain"})
        check("ping: адрес проверяется", s == 400, j)
        s, j = a.post("/api/tool", {"tool": "speedtest", "mb": 7})
        check("скорость: объём проверяется", s == 400, j)

        # ---------- 1.4.1: железо, скачивание журналов, перевод, несколько чатов Telegram
        s, j = a.get("/api/health")
        check("здоровье роутера", s == 200 and j["level"] in ("ok", "warn", "crit") and j["cores"] >= 1 and j["mem"]["total_mb"] > 0
              and all("key" in c and "text" in c for c in j["checks"]), j)
        s, j = a.get("/api/overview")
        check("обзор: сведения о роутере", "sys" in j and "cpu" in j["sys"], j.get("sys"))
        s, b, r = a.get("/api/logs/file?kind=events", raw=True)
        check("журнал скачивается файлом", s == 200 and "attachment" in (r.getheader("Content-Disposition") or "") and b"start" in b, s)
        s, b, r = a.get("/api/logs/file?kind=../../awg.env", raw=True)
        check("скачивание журналов: только из списка", s == 404, s)
        s, b, r = a.get("/lang-en.js", raw=True)
        check("словарь английского отдаётся", s == 200 and b"AWG_EN" in b, s)
        s, j = a.post("/api/telegram", {"token": "123456789:" + "A" * 35, "chat": "111, 222", "viewers": "333 111", "report_time": "09:00", "enable_notify": False})
        tg = open(os.path.join(dd, "telegram.env")).read()
        check("Telegram: несколько чатов и только просмотр", s == 200 and 'TG_CHAT="111 222"' in tg and 'TG_VIEWERS="333"' in tg, (j, tg))
        s, j = a.post("/api/telegram", {"chat": "111; rm -rf /", "report_time": "09:00", "enable_notify": False})
        check("Telegram: мусор в chat id отклонён", s == 400, j)
        s, j = a.get("/api/telegram")
        check("Telegram: чтение без токена целиком", s == 200 and j["chat"] == "111 222" and j["viewers"] == "333" and "A" * 35 not in j["token"], j)

        # ---------- 1.5 (#10): длинная история и CSV
        h0 = int(time.time()) // 3600 * 3600
        hrs = [{"t": h0 - k * 3600, "n": 60, "active": "awgmain", "tun": {"awgmain": {"rx": 1000, "tx": 100, "rtt": 40.0, "loss": 0.0, "up": 100.0},
                "awgbackup": {"rx": 10, "tx": 1, "rtt": None, "loss": None, "up": 0.0}}, "sys": {"cpu": 5.0, "mem": 50.0, "temp": None}} for k in range(720, 0, -1)]
        pid = restart_panel(pid, before=lambda: json.dump({"points": [], "hours": hrs}, open(os.path.join(dd, "web", "history.json"), "w")))
        s, j = a.get("/api/history?range=7d")
        check("история 7 дней: сводки часов", s == 200 and 160 <= len(j.get("hours", [])) <= 168 and "awgmain" in j["hours"][0]["tun"], len(j.get("hours", [])))
        s, j = a.get("/api/history?range=30d")
        check("история 30 дней", s == 200 and 700 <= len(j.get("hours", [])) <= 720, len(j.get("hours", [])))
        s, j = a.get("/api/history?range=1y")
        check("история: период проверяется", s == 400, j)
        s, b, r = a.get("/api/history.csv?range=7d", raw=True)
        lines = b.decode().splitlines()
        check("CSV: заголовок, строки по туннелям, файл", s == 200 and lines[0].startswith("time,tunnel,active,rx_bps") and len(lines) > 300
              and "attachment" in (r.getheader("Content-Disposition") or "") and ",awgbackup," in b.decode(), lines[:2])
        code = ("import sys, os; sys.path.insert(0, %r); import panel as P\n"
                "pts=[{'t':7200+i*60,'active':'m','tun':{'m':{'rx':100,'tx':10,'hs':30 if i<45 else 500,'loss':'2','rtt':'40'}}} for i in range(60)]\n"
                "h=P.hour_summary(7200, pts, [{'cpu':10,'mem':50,'temp':60}])\n"
                "print(h['tun']['m']['up'], h['tun']['m']['rtt'], h['tun']['m']['loss'], h['tun']['m']['rx'], h['active'], h['sys']['temp'])") % os.path.join(R, "awg/web")
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=dict(os.environ, DD=dd, AWG_WEBD=tempfile.mkdtemp())).stdout.strip()
        check("сводка часа: доля handshake, средние RTT и потери", out == "75.0 40.0 2.0 100 m 60", out)

        # ---------- 1.5 (#5): Home Assistant
        s, j = a.post("/api/ha", {"host": "evil;rm", "port": "1883"})
        check("HA: адрес брокера проверяется", s == 400, j)
        s, j = a.post("/api/ha", {"host": "192.168.1.10", "port": "1883", "user": "ha", "pass": "mqtt-pass-1", "tls": "no",
                                  "prefix": "homeassistant", "interval": "30", "allow_reboot": False, "enabled": False})
        he = open(os.path.join(dd, "ha.env")).read()
        check("HA: настройки сохранены, файл 600", s == 200 and 'MQTT_HOST="192.168.1.10"' in he and 'HA_ALLOW_REBOOT="no"' in he
              and oct(os.stat(os.path.join(dd, "ha.env")).st_mode & 0o777) == "0o600", (j, he))
        s, j = a.get("/api/ha")
        check("HA: пароль в браузер не отдаётся", s == 200 and j["pass_set"] and "mqtt-pass-1" not in json.dumps(j), j)
        s, j = a.post("/api/ha", {"host": "192.168.1.10", "port": "1883", "user": "ha", "pass": "", "tls": "no", "prefix": "homeassistant",
                                  "interval": "30", "allow_reboot": False, "enabled": False})
        check("HA: пустой пароль сохраняет прежний", 'MQTT_PASS="mqtt-pass-1"' in open(os.path.join(dd, "ha.env")).read())
        s, j = a.post("/api/ha", {"host": "192.168.1.10", "pass": 'x"; reboot; "', "interval": "30"})
        check("HA: опасный пароль отклонён", s == 400, j)

        # ---------- 1.5 (#12): автокопия вне роутера
        with open(os.path.join(dd, "awg.env"), "a") as f:
            f.write("VPS_IP=203.0.113.9\n")
        s, j = a.post("/api/backup/auto", {"auto": "daily", "keep": "7", "vps": True, "vps_dir": "/root/bk", "vps_keep": "14"})
        check("автокопия: без пароля расписание не включить", s == 400 and "пароль" in j.get("error", ""), j)
        s, j = a.post("/api/backup/auto", {"auto": "daily", "pass": "bk-pass-12345", "vps": True, "vps_dir": "/root/../etc", "vps_keep": "14"})
        check("автокопия: папка с .. отклонена", s == 400, j)
        s, j = a.post("/api/backup/auto", {"auto": "daily", "pass": "bk-pass-12345", "vps": True, "vps_host": "x;reboot"})
        check("автокопия: адрес VPS проверяется", s == 400, j)
        s, j = a.post("/api/backup/auto", {"auto": "weekly", "keep": "5", "pass": "bk-pass-12345", "vps": True, "vps_host": "", "vps_port": "2222",
                                           "vps_user": "root", "vps_dir": "/root/udr-backups", "vps_keep": "10", "tg": True})
        be, bp = os.path.join(dd, "backup.env"), os.path.join(dd, "backup.pass")
        check("автокопия: настройки и пароль сохранены (600), расписание применено", s == 200 and 'BK_AUTO="weekly"' in open(be).read()
              and 'BK_VPS_PORT="2222"' in open(be).read() and open(bp).read().strip() == "bk-pass-12345"
              and oct(os.stat(bp).st_mode & 0o777) == "0o600" and "weekly" in j.get("msg", ""), j)
        with open(os.path.join(dd, "backups", "auto.status"), "a") as f:
            f.write("1791800000|OK|awg-auto-1.tgz.enc|VPS: ok\n1791900000|FAIL||VPS: Permission denied\n")
        s, j = a.get("/api/backup/auto")
        check("автокопия: пароль не отдаётся, история новыми сверху", s == 200 and j["pass_set"] and "bk-pass" not in json.dumps(j)
              and j["auto"] == "weekly" and j["vps_host_default"] and j["history"][0]["ok"] is False and j["history"][1]["file"] == "awg-auto-1.tgz.enc", j)
        s, j = a.post("/api/backup/auto", {"auto": "weekly", "keep": "5", "pass": "", "vps": False, "tg": False})
        check("автокопия: пустой пароль сохраняет прежний", s == 200 and open(bp).read().strip() == "bk-pass-12345", j)
        s, j = a.post("/api/backup/auto/run", {})
        check("автокопия: «Сделать сейчас» — отдельной службой", s == 200 and "awg-backup-run" in open(os.path.join(LAB, "systemd-run.log")).read(), j)
        s, j = a.post("/api/backup/auto/test", {})
        check("автокопия: проверка VPS", s == 200 and j["ok"] and "VPS" in j["msg"], j)

        # ---------- 1.5 (#13): свой VPS
        s, j = a.post("/api/vps", {"host": "x;reboot", "port": "22", "user": "root"})
        check("VPS: адрес проверяется", s == 400, j)
        s, j = a.post("/api/vps", {"host": "", "port": "2222", "user": "root"})
        vf = os.path.join(dd, "vps.env")
        check("VPS: настройки сохранены (600)", s == 200 and 'VPS_PORT="2222"' in open(vf).read() and oct(os.stat(vf).st_mode & 0o777) == "0o600", j)
        s, j = a.get("/api/vps")
        check("VPS: адрес по умолчанию из awg.env, ключа нет", s == 200 and j["host_default"] == "203.0.113.9" and j["port"] == "2222" and not j["key"]
              and isinstance(j["tunnels"], list), j)
        s, j = a.post("/api/vps/test", {})
        check("VPS: без ключа роутера — понятная причина", s == 200 and not j["ok"] and "нет ключа роутера" in j["msg"], j)
        s, j = a.post("/api/vps/run", {"action": "rotate-keys", "current": "wrong"})
        check("VPS: изменения только с паролем", s == 403, j)
        s, j = a.post("/api/vps/run", {"action": "rm -rf", "current": "Test-pass-123"})
        check("VPS: неизвестное действие отклонено", s == 400, j)
        s, j = a.post("/api/vps/run", {"action": "obfs", "tunnel": "awg;x", "current": "Test-pass-123"})
        check("VPS: имя туннеля проверяется", s == 400, j)
        s, j = a.post("/api/vps/run", {"action": "update", "current": "Test-pass-123"})
        srl = open(os.path.join(LAB, "systemd-run.log")).read()
        check("VPS: действие запускается отдельной службой", s == 200 and "--unit=awg-vps-job" in srl and "vps.sh update" in srl, (j, srl[-300:]))
        s, j = a.get("/api/vps/job")
        check("VPS: журнал действия", s == 200 and "обновление AmneziaWG на VPS — запущено из панели" in j["text"], j)
        # мастер своего VPS (#28): пароль VPS — только во временный файл 600, не в аргументы и не в журнал
        s, j = a.post("/api/vps/run", {"action": "setup", "host": "198.51.100.7", "port": "22", "user": "root", "vps_password": "Vps-Pass-1",
                                       "name": "awgmain", "awg_port": "51823", "current": "Test-pass-123"})
        check("VPS-мастер: занятое имя туннеля отклонено", s == 400, j)
        s, j = a.post("/api/vps/run", {"action": "setup", "host": "198.51.100.7", "port": "22", "user": "root", "vps_password": "Vps-Pass-1",
                                       "name": "awgvps", "awg_port": "51823", "current": "Test-pass-123"})
        srl = open(os.path.join(LAB, "systemd-run.log")).read().splitlines()[-1]
        pfs = [f for f in os.listdir(dd) if f.startswith(".vpspass-")]
        pf = os.path.join(dd, pfs[0]) if pfs else ""
        check("VPS-мастер: запуск с файлом пароля 600, пароля нет в аргументах и журналах",
              s == 200 and "vps.sh setup awgvps 51823" in srl and "VPS_PASS_FILE=" + pf in srl and "Vps-Pass-1" not in srl
              and pf and open(pf).read() == "Vps-Pass-1" and oct(os.stat(pf).st_mode & 0o777) == "0o600"
              and "Vps-Pass-1" not in open(os.path.join(dd, "web", "audit.log")).read()
              and 'VPS_HOST="198.51.100.7"' in open(os.path.join(dd, "vps.env")).read(), (j, srl))
        if pf:
            os.remove(pf)
        # общий tunnel_add из командной строки (им пользуется мастер)
        cf = os.path.join(LAB, "cli.conf")
        open(cf, "w").write(open(os.path.join(dd, "main.conf")).read())
        p_ = subprocess.run([sys.executable, os.path.join(dd, "web", "panel.py"), "tunnel-add", "awgcli", cf, "Свой VPS"],
                            capture_output=True, text=True, env=dict(os.environ, **{k: v for k, v in (x.split("=", 1) for x in open("/proc/%s/environ" % pid).read().split("\0") if "=" in x)}))
        ev = open(os.path.join(dd, "awg.env")).read()
        check("panel.py tunnel-add: туннель, название, ревизия", p_.returncode == 0 and "awgcli" in ev and os.path.exists(os.path.join(dd, "awgcli.conf"))
              and json.load(open(os.path.join(dd, "web", "labels.json"))).get("awgcli") == "Свой VPS", p_.stdout + p_.stderr)
        p_ = subprocess.run([sys.executable, os.path.join(dd, "web", "panel.py"), "tunnel-add", "awgcli", cf], capture_output=True, text=True,
                            env=dict(os.environ, DD=dd, AWG_WEBD=os.path.join(dd, "web")))
        check("panel.py tunnel-add: повтор — отказ с кодом 2", p_.returncode == 2 and "уже есть" in p_.stdout, p_.stdout)
        a.post("/api/tunnel/remove", {"name": "awgcli", "current": "Test-pass-123"})

        # ---------- 1.6 (#30, #32): туннели через 3x-ui (AmneziaWG 3.1), несколько панелей
        rpriv = "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI="                   # закрытый ключ роутера в конфигах стенда
        rpub = base64.b64encode(hashlib.sha256(rpriv.encode()).digest()).decode()  # как заглушка awg pubkey
        ppriv = base64.b64encode(hashlib.sha256(b"phone").digest()).decode()
        home = {"id": 45, "port": 443, "protocol": "amneziawg", "remark": "Home", "enable": True, "listen": "",
                "settings": {"server": dict(FakeXui.SRV, publicKey="c2VydmVyLXNlcnZlci1zZXJ2ZXItc2VydmVyLWtleTE="),
                             "clients": [{"email": "home", "enable": True, "publicKey": rpub, "allowedIPs": ["10.8.1.2/32"],
                                          "preSharedKey": "cHNrLXBzay1wc2stcHNrLXBzay1wc2stcHNrLXBzazE="},
                                         {"email": "phone", "enable": True, "privateKey": ppriv, "publicKey": "cGhvbmUtcHViLWtleS1waG9uZS1wdWIta2V5LTAwMDA=",
                                          "allowedIPs": ["10.8.1.3/32", "fd00::3/128"]}]},
                "clientStats": [{"email": "home", "up": 1000, "down": 5000}]}
        us = {"id": 48, "port": 25353, "protocol": "amneziawg", "remark": "US", "enable": True, "nodeId": 2, "shareAddrStrategy": "node",
              "settings": {"server": dict(FakeXui.SRV), "clients": []}}
        fx = FakeXui(existing=[home, us])
        base = "http://127.0.0.1:%d/secret" % fx.port
        # перенос из 1.6-beta: xui.env + карта туннелей → xui.json (панель p1)
        open(os.path.join(dd, "xui.env"), "w").write('XUI_URL="%s"\nXUI_TOKEN="xui-token-123456"\nXUI_INSECURE="no"\nXUI_HOST="203.0.113.50"\n' % base)
        open(os.path.join(dd, "xui.json"), "w").write('{"awgold": {"inbound": 7, "email": "e", "port": 1, "host": "h", "created": 1}}')
        s, j = a.get("/api/xui")
        db = json.load(open(os.path.join(dd, "xui.json")))
        check("3x-ui: перенос старых настроек в xui.json (панель p1, туннель с панелью), xui.env удалён",
              s == 200 and [p["id"] for p in j["panels"]] == ["p1"] and db["tunnels"]["awgold"]["panel"] == "p1"
              and not os.path.exists(os.path.join(dd, "xui.env")) and oct(os.stat(os.path.join(dd, "xui.json")).st_mode & 0o777) == "0o600", (j, db))
        os.remove(os.path.join(dd, "xui.json"))
        s, j = a.post("/api/xui", {"url": base + "/x\nPostUp=evil", "token": "xui-token-123456"})
        check("3x-ui: опасный адрес отклонён", s == 400, j)
        s, j = a.post("/api/xui", {"url": base, "token": "wrong-token-1", "host": "203.0.113.50", "label": "Финляндия"})
        xpid = j.get("id")
        s, j = a.post("/api/xui/test", {"id": xpid})
        check("3x-ui: неверный токен → понятная ошибка 401", s == 400 and "401" in j.get("error", ""), j)
        s, j = a.post("/api/xui", {"id": xpid, "url": base, "token": "xui-token-123456", "host": "203.0.113.50", "label": "Финляндия"})
        xe = open(os.path.join(dd, "xui.json")).read()
        check("3x-ui: панель сохранена (600), тот же ID", s == 200 and j["id"] == xpid == "p1" and "xui-token-123456" in xe
              and oct(os.stat(os.path.join(dd, "xui.json")).st_mode & 0o777) == "0o600", j)
        s, j = a.post("/api/xui", {"url": "https://xui2.example.com:2053/abc", "token": "other-token-777", "label": "Швеция"})
        s, j = a.get("/api/xui")
        check("3x-ui: две панели, токены в браузер не отдаются, amneziawg-go v3 подходит",
              s == 200 and [p["id"] for p in j["panels"]] == ["p1", "p2"] and all(p["token_set"] for p in j["panels"])
              and "xui-token" not in json.dumps(j) and "other-token" not in json.dumps(j) and j["go_ok"], j)
        s, j = a.post("/api/xui/test", {"id": "p1"})
        check("3x-ui: проверка подключения (3.10: settings объектом)", s == 200 and "подключений 3, из них AmneziaWG 2" in j["msg"], j)
        s, j = a.get("/api/xui/inbounds?panel=p1")
        ib = {x["id"]: x for x in j.get("inbounds", [])}
        hm = ib.get(45, {})
        check("3x-ui: подключения AmneziaWG — #45 ведёт туннель awgbackup, клиент home — роутер, у phone ключ в 3x-ui",
              s == 200 and hm.get("match") == "awgbackup" and hm.get("match_email") == "home"
              and [c["router"] for c in hm["clients"]] == [True, False] and [c["has_key"] for c in hm["clients"]] == [False, True]
              and hm["host"] == "203.0.113.50" and hm["clients"][0]["down"] == 5000, j)
        check("3x-ui: адрес подключения на узле — адрес узла", ib.get(48, {}).get("host") == "us.example.net" and not ib.get(48, {}).get("match"), ib.get(48))
        check("3x-ui: закрытые ключи из 3x-ui в браузер не отдаются", ppriv not in json.dumps(j) and "privateKey" not in json.dumps(j), j)
        # создать: подключение в 3x-ui + туннель (старый формат ответа — settings строкой)
        fx.legacy = True
        s, j = a.post("/api/xui/create", {"panel": "p1", "name": "awgxui", "current": "wrong"})
        check("3x-ui: создание только с паролем", s == 403 and not fx.added, j)
        open(os.path.join(LAB, "stub", "hs", "awgxui"), "w").write("5")       # заглушка awg: в файле — возраст handshake
        s, j = a.post("/api/xui/create", {"panel": "p1", "name": "awgxui", "port": "2053", "current": "Test-pass-123"})
        check("3x-ui: занятый порт отклонён до создания", s == 400 and "занят" in j.get("error", "") and not fx.added, j)
        s, j = a.post("/api/xui/create", {"panel": "p1", "name": "awgxui", "current": "Test-pass-123"})
        sent = fx.added[-1] if fx.added else {}
        cl = json.loads(sent.get("settings", "{}")).get("clients", [{}])[0]
        check("3x-ui: подключение amneziawg создано, в 3x-ui ушёл только открытый ключ", s == 200 and j["ok"] and sent.get("protocol") == "amneziawg"
              and 20000 <= sent.get("port", 0) < 60000 and cl.get("publicKey") and "privateKey" not in cl, (j, sent))
        conf = open(os.path.join(dd, "awgxui.conf")).read() if os.path.exists(os.path.join(dd, "awgxui.conf")) else ""
        check("3x-ui: конфиг AWG 3.1 из ответа API (ключ сервера, S3/S4, H-диапазоны, I1, защита заголовков, Endpoint)",
              "PublicKey = U0VSVkVSLVBVQkxJQy1LRVktRk9SLVRFU1RTLTEyMzQ=" in conf and "S4 = 16" in conf and "H1 = 100000-200000" in conf
              and "I1 = <r 64>" in conf and "HeaderProtectionKey = " in conf and "RandomTrailers = on" in conf and "DisableCookies" not in conf
              and "MTU = 1404" in conf and "Endpoint = 203.0.113.50:%d" % sent.get("port", 0) in conf and "DNS" not in conf, conf)
        ev = open(os.path.join(dd, "awg.env")).read()
        s, j = a.get("/api/xui")
        t1 = [t for t in j["tunnels"] if t["name"] == "awgxui"]
        check("3x-ui: туннель добавлен и запомнен (панель, «создан роутером»)", "awgxui" in ev and t1 and t1[0]["panel"] == "p1" and t1[0]["kind"] == "created"
              and t1[0]["panel_label"] == "Финляндия" and json.load(open(os.path.join(dd, "web", "labels.json"))).get("awgxui") == "3x-ui", (ev, j))
        s, j = a.post("/api/xui/remove", {"name": "awgxui", "current": "Test-pass-123"})
        check("3x-ui: удаление — туннель убран, подключение в 3x-ui удалено", s == 200 and "awgxui" not in open(os.path.join(dd, "awg.env")).read()
              and not [x for x in fx.inbounds if str(x.get("remark", "")).startswith("UDR-Amnezia")], (j, fx.inbounds))
        fx.legacy = False
        # 3x-ui 3.10 (settings объектом): создание доходит до конца, а при ошибке подключение в 3x-ui не остаётся
        open(os.path.join(LAB, "stub", "hs", "awgxui3"), "w").write("5")
        s, j = a.post("/api/xui/create", {"panel": "p1", "name": "awgxui3", "current": "Test-pass-123"})
        check("3x-ui 3.10: создание работает", s == 200 and j["ok"] and os.path.exists(os.path.join(dd, "awgxui3.conf")), j)
        a.post("/api/xui/remove", {"name": "awgxui3", "current": "Test-pass-123"})
        n0 = len(fx.inbounds)
        open(os.path.join(dd, "awgbad.conf"), "w").write("занято")
        os.chmod(os.path.join(dd, "awgbad.conf"), 0o600)
        s, j = a.post("/api/xui/create", {"panel": "p1", "name": "awgbad", "current": "Test-pass-123"})
        check("3x-ui: занятое имя — отказ до создания в 3x-ui", s == 400 and len(fx.inbounds) == n0, j)
        os.remove(os.path.join(dd, "awgbad.conf"))
        # привязать работающий туннель (запасной) к его подключению: по ключу сервера и порту
        s, j = a.post("/api/xui/link", {"panel": "p1", "inbound": 48, "name": "awgmain"})
        check("3x-ui: привязка к чужому подключению — отказ", s == 400 and "не совпадают" in j.get("error", ""), j)
        bk0 = open(os.path.join(dd, "backup.conf")).read()
        s, j = a.post("/api/xui/link", {"panel": "p1", "inbound": 45, "name": "awgbackup"})
        db = json.load(open(os.path.join(dd, "xui.json")))
        check("3x-ui: awgbackup привязан к №45 (клиент home), конфиг не тронут", s == 200 and db["tunnels"]["awgbackup"]["kind"] == "linked"
              and db["tunnels"]["awgbackup"]["email"] == "home" and open(os.path.join(dd, "backup.conf")).read() == bk0, (j, db))
        # обновить из 3x-ui: в 3x-ui сменили обфускацию — роутер берёт новые значения, свой ключ и адрес оставляет
        fx.inbounds[[x["id"] for x in fx.inbounds].index(45)]["settings"]["server"].update(h1="111-222", jc=7)
        s, j = a.post("/api/xui/sync", {"name": "awgbackup", "current": "wrong"})
        check("3x-ui: обновление из 3x-ui только с паролем", s == 403 and open(os.path.join(dd, "backup.conf")).read() == bk0, j)
        s, j = a.post("/api/xui/sync", {"name": "awgbackup", "current": "Test-pass-123"})
        bk1 = open(os.path.join(dd, "backup.conf")).read()
        check("3x-ui: обновлено из 3x-ui — новые H1/Jc, прежние ключ роутера, адрес, общий ключ и Endpoint", s == 200 and j.get("ok")
              and "H1 = 111-222" in bk1 and "Jc = 7" in bk1 and "PrivateKey = " + rpriv in bk1 and "Endpoint = 203.0.113.77:443" in bk1
              and "PresharedKey = cHNrLXBzay1wc2stcHNrLXBzay1wc2stcHNrLXBzazE=" in bk1
              and re.search(r"Address = 10\.8\.1\.\d+/32", bk1), (j, bk1))
        # подключить клиента, ключ которого хранит 3x-ui
        s, j = a.post("/api/xui/import", {"panel": "p1", "inbound": 45, "email": "home", "name": "awgph", "current": "Test-pass-123"})
        check("3x-ui: клиент без ключа в 3x-ui — отказ", s == 400 and "закрытого ключа" in j.get("error", ""), j)
        open(os.path.join(LAB, "stub", "hs", "awgph"), "w").write("5")
        s, j = a.post("/api/xui/import", {"panel": "p1", "inbound": 45, "email": "phone", "name": "awgph", "current": "Test-pass-123"})
        ph = open(os.path.join(dd, "awgph.conf")).read() if os.path.exists(os.path.join(dd, "awgph.conf")) else ""
        check("3x-ui: клиент phone подключён туннелем awgph (его ключ, IPv4-адрес, Endpoint)", s == 200 and j["ok"] and "PrivateKey = " + ppriv in ph
              and "Address = 10.8.1.3/32" in ph and "Endpoint = 203.0.113.50:443" in ph and "H1 = 111-222" in ph, (j, ph))
        s, j = a.post("/api/xui/panel/remove", {"id": "p1"})
        check("3x-ui: панель с туннелями не убирается", s == 400 and "awgbackup" in j.get("error", ""), j)
        s, j = a.post("/api/xui/remove", {"name": "awgph", "current": "Test-pass-123"})
        check("3x-ui: клиент из 3x-ui — убран только туннель, клиент в 3x-ui остался", s == 200 and "awgph" not in open(os.path.join(dd, "awg.env")).read()
              and [c["email"] for c in fx.inbounds[[x["id"] for x in fx.inbounds].index(45)]["settings"]["clients"]] == ["home", "phone"], j)
        s, j = a.post("/api/xui/remove", {"name": "awgbackup", "current": "Test-pass-123"})
        ev = open(os.path.join(dd, "awg.env")).read()
        check("3x-ui: отвязка — запасной канал на месте, подключение №45 цело", s == 200 and "BACKUP=awgbackup" in ev.replace('"', "")
              and 45 in [x["id"] for x in fx.inbounds] and "awgbackup" not in json.load(open(os.path.join(dd, "xui.json")))["tunnels"], (j, ev))
        open(os.path.join(dd, "backup.conf"), "w").write(bk0)
        s, j = a.post("/api/xui/panel/remove", {"id": "p2"})
        check("3x-ui: панель без туннелей убирается", s == 200 and [p["id"] for p in a.get("/api/xui")[1]["panels"]] == ["p1"], j)
        p_ = subprocess.run([sys.executable, os.path.join(dd, "web", "panel.py"), "xui"], capture_output=True, text=True,
                            env=dict(os.environ, DD=dd, AWG_WEBD=os.path.join(dd, "web")))
        check("panel.py xui: подключения панели и связь с роутером (только чтение)", p_.returncode == 0 and "№45 «Home» 203.0.113.50:443" in p_.stdout
              and "туннель роутера awgbackup" in p_.stdout and ppriv not in p_.stdout, p_.stdout + p_.stderr)
        go = os.path.join(dd, "amneziawg-go")
        keep_go = open(go).read()
        open(go, "w").write('#!/bin/bash\necho "amneziawg-go 0.0.20250522"\n')
        s, j = a.post("/api/xui/create", {"name": "awgxui2", "current": "Test-pass-123"})
        check("3x-ui: старый amneziawg-go — отказ с подсказкой обновить", s == 400 and "Обновить на роутере" in j.get("error", ""), j)
        open(go, "w").write(keep_go)
        fx.srv.shutdown()

        # ---------- 1.6 (#32): несколько своих VPS
        s, j = a.post("/api/vps", {"new": True, "label": "Швеция", "host": "198.51.100.30", "port": "2222", "user": "root"})
        vf = os.path.join(dd, "vps.d", "%s.env" % j.get("vps"))
        check("VPS: добавлен второй (ID v2, файл 600)", s == 200 and j.get("vps") == "v2" and os.path.exists(vf)
              and oct(os.stat(vf).st_mode & 0o777) == "0o600" and 'VPS_LABEL="Швеция"' in open(vf).read(), j)
        s, j = a.get("/api/vps?vps=v2")
        check("VPS: выбранный VPS и список", s == 200 and j["host"] == "198.51.100.30" and j["port"] == "2222" and j["label"] == "Швеция"
              and [p["id"] for p in j["profiles"]][:1] == ["main"] and "v2" in [p["id"] for p in j["profiles"]], j)
        s, j = a.post("/api/vps", {"new": True, "label": 'x"; rm', "host": "198.51.100.31"})
        check("VPS: опасное название отклонено", s == 400, j)
        s, j = a.get("/api/vps?vps=a;b")
        check("VPS: неверный ID → 400", s == 400, j)
        s, j = a.post("/api/vps/del", {"vps": "main"})
        check("VPS: основной не удаляется", s == 400, j)
        s, j = a.post("/api/vps/del", {"vps": "v2"})
        check("VPS: второй убран из списка", s == 200 and not os.path.exists(vf), j)

        # ---------- 1.6 (#22): маршруты — разные туннели для разных профилей PBR UniFi
        open(os.path.join(LAB, "stub", "rules"), "w").write("32504:\tfrom all fwmark 0x6a0000/0x7e0000 lookup 178.wgclt1\n"
                                                           "32505:\tfrom all fwmark 0x6c0000/0x7e0000 lookup 179.wgclt2\n")
        s, j = a.get("/api/routes")
        rl = {x["rail"]: x for x in j.get("rails", [])}
        check("маршруты: профили UniFi, основной занят, wgclt2 свободен", s == 200 and rl.get("wgclt1", {}).get("used") == "main"
              and rl.get("wgclt2", {}).get("used") == "" and j["routes"][0]["id"] == "main", j)
        s, j = a.post("/api/route/save", {"new": True, "id": "us", "rail": "wgclt2", "tunnels": ["awgalt1", "awgbackup"], "label": "США", "current": "wrong"})
        check("маршруты: создание только с паролем", s == 403 and not os.path.exists(os.path.join(dd, "route.d", "us.env")), j)
        s, j = a.post("/api/route/save", {"new": True, "id": "us", "rail": "wgclt2", "tunnels": ["awgalt1", "awgbackup"], "label": "США", "only": True,
                                           "current": "Test-pass-123"})
        rf = open(os.path.join(dd, "route.d", "us.env")).read() if os.path.exists(os.path.join(dd, "route.d", "us.env")) else ""
        check("маршруты: маршрут us создан (таблица 179, туннели, служба)", s == 200 and 'TABLE="179"' in rf and 'TUNNELS="awgalt1 awgbackup"' in rf
              and os.path.exists(os.path.join(LAB, "sysd", "awg-failover-us.service")) and "awg-failover-us" in open(os.path.join(dd, ".units")).read(), (j, rf))
        check("маршруты: «только для маршрута» — основной не использует его туннели (кроме основного)",
              'ROUTE_ONLY="awgalt1 awgbackup"' in open(os.path.join(dd, "awg.env")).read(), open(os.path.join(dd, "awg.env")).read())
        s, j = a.get("/api/routes")
        us = [x for x in j["routes"] if x["id"] == "us"]
        check("маршруты: в списке с названием и туннелями", us and us[0]["label"] == "США" and us[0]["tunnels"] == ["awgalt1", "awgbackup"] and us[0]["only"], j)
        s, j = a.post("/api/tunnel/remove", {"name": "awgalt1", "current": "Test-pass-123"})
        check("маршруты: туннель маршрута не удаляется", s == 400 and "маршрут us" in j.get("error", ""), j)
        s, j = a.post("/api/route/switch", {"id": "us", "tunnel": "awgbackup"})
        check("маршруты: ручной выбор канала маршрута", s == 200 and open(os.path.join(LAB, "run", "awg-force-us")).read().strip() == "awgbackup", j)
        s, j = a.post("/api/route/switch", {"id": "us", "tunnel": "auto"})
        check("маршруты: автоматика", s == 200 and not os.path.exists(os.path.join(LAB, "run", "awg-force-us")), j)
        s, j = a.post("/api/route/save", {"new": True, "id": "x2", "rail": "wgclt2", "tunnels": ["awgmain"], "current": "Test-pass-123"})
        check("маршруты: занятый профиль — отказ", s == 400 and "занят" in j.get("error", ""), j)
        s, j = a.post("/api/route/remove", {"id": "us", "current": "Test-pass-123"})
        check("маршруты: убран — файл, служба, исключения", s == 200 and not os.path.exists(os.path.join(dd, "route.d", "us.env"))
              and not os.path.exists(os.path.join(LAB, "sysd", "awg-failover-us.service")) and 'ROUTE_ONLY=""' in open(os.path.join(dd, "awg.env")).read(), j)
        # ---------- 1.6 (#23): IPv6 через туннель — по желанию
        s, j = a.post("/api/settings", {"values": {"LEAK_V6": "tunnel"}})
        check("IPv6: неизвестное значение отклонено", s == 400, j)
        s, j = a.post("/api/settings", {"values": {"LEAK_V6": "route"}})
        check("IPv6: «через туннель» сохраняется, сторож перезапускается", s == 200 and "LEAK_V6=route" in open(os.path.join(dd, "awg.env")).read().replace('"', "")
              and "awg-failover" in j.get("msg", ""), j)
        a.post("/api/settings", {"values": {"LEAK_V6": "block"}})
        # ---------- 1.6 (#33): автоподбор обфускации
        s, j = a.get("/api/tune")
        tn = {x["name"]: x for x in j.get("tunnels", [])}
        check("подбор: список туннелей, активный отмечен", s == 200 and tn.get("awgmain", {}).get("active") and not tn.get("awgbackup", {}).get("active"), j)
        s, j = a.post("/api/tune/run", {"tunnel": "awgmain", "mode": "client", "count": "3", "current": "Test-pass-123"})
        check("подбор: на активном канале без разрешения — отказ", s == 400 and "активный канал" in j.get("error", ""), j)
        s, j = a.post("/api/tune/run", {"tunnel": "awgbackup", "mode": "client", "count": "3", "current": "wrong"})
        check("подбор: только с паролем", s == 403, j)
        s, j = a.post("/api/tune/run", {"tunnel": "awgbackup", "mode": "client", "count": "3", "current": "Test-pass-123"})
        srl = open(os.path.join(LAB, "systemd-run.log")).read()
        check("подбор: отдельной службой awg-tune", s == 200 and "--unit=awg-tune" in srl and "obfs-tune.sh run awgbackup client 3" in srl, (j, srl[-300:]))
        open(os.path.join(dd, "tune.tsv"), "w").write("# awgbackup\tclient\t1791900000\t\n0\t1\t0\t0\t20\t8.0\t102\tJc=4 Jmin=40 Jmax=70\n"
                                                    "1\t1\t1\t0\t20\t10.0\t103\tJc=3 Jmin=10 Jmax=50\n2\t0\t-1\t100\t0\t0\t0\tJc=10 Jmin=100 Jmax=1000\n")
        s, j = a.get("/api/tune")
        check("подбор: результаты и лучший набор", s == 200 and j["best"] == 1 and len(j["rows"]) == 3 and j["head"]["tunnel"] == "awgbackup", j)
        s, j = a.post("/api/tune/apply", {"n": 2, "current": "Test-pass-123"})
        check("подбор: нерабочий набор не ставится", s == 400, j)
        s, j = a.post("/api/tune/apply", {"n": 1, "current": "Test-pass-123"})
        bk = open(os.path.join(dd, "backup.conf")).read()
        check("подбор: набор 1 поставлен через историю конфигов (Jc/Jmin/Jmax, ключи на месте)", s == 200 and j.get("ok") and "Jc = 3" in bk
              and "Jmin = 10" in bk and "Jmax = 50" in bk and "PrivateKey = aGVsbG8" in bk and "S1 = 15" in bk, (j, bk))

        # ---------- 1.5 (#14): вебхук и ntfy
        s, j = a.post("/api/hooks", {"hook": "https://hooks.example.com/x\"; rm"})
        check("хуки: опасный адрес отклонён", s == 400, j)
        s, j = a.post("/api/hooks", {"hook": "https://hooks.example.com/api/webhook/SECRETID", "header": 'X-Key: a"b'})
        check("хуки: заголовок с кавычкой отклонён", s == 400, j)
        s, j = a.post("/api/hooks", {"hook": "https://hooks.example.com/api/webhook/SECRETID", "header": "Authorization: Bearer hsec",
                                     "ntfy": "https://ntfy.sh/udr-test", "ntfy_token": "tk_abc"})
        hf = os.path.join(dd, "hooks.env")
        check("хуки: сохранены (600)", s == 200 and 'HOOK_URL="https://hooks.example.com/api/webhook/SECRETID"' in open(hf).read()
              and oct(os.stat(hf).st_mode & 0o777) == "0o600", j)
        s, j = a.get("/api/hooks")
        check("хуки: путь вебхука, заголовок и токен в браузер не отдаются", s == 200 and j["hook"] == "https://hooks.example.com/…" and j["header_set"]
              and j["ntfy_token_set"] and "SECRETID" not in json.dumps(j) and "hsec" not in json.dumps(j) and "tk_abc" not in json.dumps(j), j)
        s, j = a.post("/api/hooks", {"ntfy": "https://ntfy.sh/udr-test"})
        hv = open(hf).read()
        check("хуки: пустые поля сохраняют прежние значения", s == 200 and "SECRETID" in hv and "hsec" in hv and "tk_abc" in hv, hv)
        s, j = a.post("/api/hooks/test", {})
        check("хуки: тестовое сообщение (настоящий notify.sh, заглушка curl)", s == 200 and j["ok"] and j["msg"] == "отправлено", j)
        s, j = a.post("/api/hooks", {"hook_clear": True, "ntfy": ""})
        check("хуки: всё убрано — файл удалён", s == 200 and not os.path.exists(hf), j)

        # ---------- 1.5 (#6): токены API
        s, j = a.post("/api/token/create", {"name": "ha", "role": "read", "days": 0, "current": "nope"})
        check("токен: без пароля не создать", s == 403, j)
        s, j = a.post("/api/token/create", {"name": "ha", "role": "read", "days": 0, "current": "Test-pass-123"})
        rtok = j.get("token", "")
        check("токен: создан, показан один раз", s == 200 and rtok.startswith("awg_"), j)
        s, j = a.post("/api/token/create", {"name": "ops", "role": "admin", "days": 30, "current": "Test-pass-123"})
        atok, atid = j.get("token", ""), j.get("id", "")
        s, j = a.post("/api/token/create", {"name": "x" * 50, "role": "read", "days": 0, "current": "Test-pass-123"})
        check("токен: название проверяется", s == 400, j)
        s, j = a.post("/api/token/create", {"name": "bad", "role": "root", "days": 0, "current": "Test-pass-123"})
        check("токен: роль проверяется", s == 400, j)
        tj = open(os.path.join(dd, "web", "tokens.json")).read()
        check("токен: в файле только хэш, права 600", rtok not in tj and hashlib.sha256(rtok.encode()).hexdigest() in tj
              and oct(os.stat(os.path.join(dd, "web", "tokens.json")).st_mode & 0o777) == "0o600")
        s, j = a.get("/api/tokens")
        check("токен: список без хэшей", s == 200 and len(j["tokens"]) == 2 and "hash" not in json.dumps(j), j)
        r_ = C(); bh = lambda t: {"Authorization": "Bearer " + t}
        s, j = r_.get("/api/overview", headers=bh(rtok))
        check("токен read: чтение работает", s == 200 and "tunnels" in j, s)
        s, j = r_.req("POST", "/api/tunnel/auto", {}, headers=bh(rtok))
        check("токен read: изменения запрещены", s == 403, j)
        s, j = r_.req("POST", "/api/tunnel/label", {"name": "awgmain", "label": ""}, headers=bh(atok))
        check("токен admin: управление без CSRF", s == 200, j)
        for path, m in (("/api/tokens", "GET"), ("/api/users", "GET"), ("/api/sessions", "GET"), ("/api/web", "GET"), ("/api/ha", "GET"), ("/api/backup/auto", "GET"), ("/api/hooks", "GET"), ("/api/vps", "GET"), ("/api/xui", "GET")):
            s, j = r_.req(m, path, headers=bh(atok))
            check("токен admin: %s только по паролю" % path, s == 403, j)
        s, j = r_.req("POST", "/api/system/reboot", {"current": ""}, headers=bh(atok))
        s2, j2 = r_.req("POST", "/api/tunnel/export", {"name": "awgmain", "current": ""}, headers=bh(atok))
        s3, b3, _ = r_.req("GET", "/api/backup/file/x.tgz", headers=bh(atok), raw=True)
        check("токен admin: перезагрузка, ключи и копии недоступны", s == 403 and s2 == 403 and s3 == 403, (s, s2, s3))
        s, j = r_.get("/api/overview", headers=bh("awg_" + "A" * 43))
        check("токен: неверный → 401", s == 401, j)
        s, j = a.get("/api/tokens")
        used = {x["name"]: x for x in j["tokens"]}
        check("токен: отмечено последнее использование", used["ha"]["last_used"] > 0 and used["ha"]["last_ip"] == "127.0.0.1", used)
        s, j = a.post("/api/token/revoke", {"id": atid})
        s2, j2 = r_.get("/api/overview", headers=bh(atok))
        check("токен: отозванный не работает", s == 200 and s2 == 401, (j, s2))
        pid = restart_panel(pid)
        s, j = r_.get("/api/overview", headers=bh(rtok))
        check("токен: работает после перезапуска панели", s == 200, s)
        aud = open(os.path.join(dd, "web", "audit.log")).read()
        check("токен: действия в журнале от имени token:…", "token:ops" in aud and "token-create" in aud and "token-revoke" in aud, aud[-400:])

        # ---------- 1.4.3: версия страницы, ping с выбором способа
        s, b, r = a.get("/app.js", raw=True)
        pv = re.search(rb"const PAGE_VERSION = '([^']*)'", b)
        check("app.js: версия страницы подставлена", s == 200 and pv and pv.group(1).decode() == PANEL_VERSION, pv and pv.group(1))
        s, j = a.get("/api/overview")
        check("обзор отдаёт версию панели", j.get("panel") == PANEL_VERSION, j.get("panel"))
        s, j = C().login()
        check("вход отдаёт версию панели", s == 200 and j.get("version") == PANEL_VERSION, j)
        s, j = a.post("/api/net", {"kind": "ping", "host": "1.1.1.1", "iface": "awgmain", "mode": "udp"})
        check("ping: способ проверяется", s == 400, j)
        s, j = a.post("/api/net", {"kind": "ping", "host": "1.1.1.1", "iface": "wan", "mode": "tcp"})
        check("ping: TCP-способ запускается", s == 200 and j.get("job"), j)

        # ---------- 1.4.2: перезагрузка роутера, выключение защиты из панели
        s, j = a.post("/api/system/reboot", {"current": "nope"})
        srl = open(os.path.join(LAB, "systemd-run.log")).read()
        check("перезагрузка: без пароля нельзя", s == 403 and "awg-reboot" not in srl, j)
        s, j = a.post("/api/system/reboot", {"current": "Test-pass-123"}, headers={"X-CSRF": "bad"})
        check("перезагрузка: только с CSRF", s == 403, j)
        open(os.path.join(LAB, "stub", "svc", "awg-update"), "w").close()
        s, j = a.post("/api/system/reboot", {"current": "Test-pass-123"})
        check("перезагрузка: не во время обновления", s == 400 and "обновлени" in j.get("error", ""), j)
        os.remove(os.path.join(LAB, "stub", "svc", "awg-update"))
        s, j = a.post("/api/system/reboot", {"current": "Test-pass-123"})
        srl = open(os.path.join(LAB, "systemd-run.log")).read()
        check("перезагрузка: с паролем — отложенный reboot через systemd-run", s == 200 and j.get("delay") == 5
              and "--unit=awg-reboot" in srl and "--on-active=5" in srl and "reboot" in srl.split("awg-reboot")[-1], (j, srl[-300:]))
        s, j = a.get("/api/events")
        check("перезагрузка: событие в журнале", any(e.get("type") == "reboot" for e in (j.get("events") or [])), j)
        audit_txt = open(os.path.join(dd, "web", "audit.log")).read() if os.path.exists(os.path.join(dd, "web", "audit.log")) else ""
        check("перезагрузка: в журнале действий", "reboot-denied" in audit_txt and "reboot" in audit_txt.replace("reboot-denied", ""), audit_txt[-300:])
        gs = os.path.join(dd, "guard.sh")
        open(gs, "w").write("#!/bin/bash\necho \"guard.sh $*: ок\"\n")   # настоящий remove на стенде не нужен
        s, j = a.post("/api/service", {"name": "awg-guard", "action": "disable"})
        envt = open(os.path.join(dd, "awg.env")).read()
        check("выключение awg-guard из панели ставит LEAK_GUARD=no", s == 200 and "LEAK_GUARD=no" in envt and "LEAK_GUARD=yes" not in envt, (j, envt))

        s, j = a.post("/api/logout", {})
        s, j = a.get("/api/overview")
        check("выход закрывает сессию", s == 401, s)

        t = C()
        for _ in range(5):
            t.login(pw="bad-bad-bad")
        s, j = t.login()
        check("5 неудачных входов → блокировка", s == 429, j)

        users = json.load(open(os.path.join(dd, "web", "users.json")))
        check("пароли хранятся как PBKDF2", "hash" in users["admin"] and "Test-pass" not in json.dumps(users))
        check("users.json — права 600", oct(os.stat(os.path.join(dd, "web", "users.json")).st_mode & 0o777) == "0o600")
    finally:
        subprocess.call(["kill", pid])
        print(open(os.path.join(LAB, "panel.log")).read()[-2000:] if FAILS else "", end="")
    print("\nweb: %d ошибок" % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
