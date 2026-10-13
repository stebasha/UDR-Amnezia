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
PANEL_VERSION = re.search(r'^VERSION = "([^"]+)"', open(os.path.join(R, "awg/web/panel.py")).read(), re.M).group(1)
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
              and it["awg"]["state"] == "ok" and it["awg"]["installed"] == "v3.1.20260812" and "--bins-update" in j["cmd"], j)
        go = os.path.join(dd, "amneziawg-go")
        with open(os.path.join(dd, ".binsver"), "w") as f:
            f.write("amneziawg-go v3.1.20260901 %s\n" % hashlib.sha256(open(go, "rb").read()).hexdigest())
        s, j = a.post("/api/bins/check", {})
        check("бинарники: тег сборки из .binsver (сумма совпала)", s == 200 and not j["update"] and j["items"][0]["installed"] == "v3.1.20260901", j)
        os.remove(os.path.join(LAB, "stub", "gh")); os.remove(os.path.join(dd, ".binsver"))
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
        for path, m in (("/api/tokens", "GET"), ("/api/users", "GET"), ("/api/sessions", "GET"), ("/api/web", "GET"), ("/api/ha", "GET"), ("/api/backup/auto", "GET"), ("/api/hooks", "GET"), ("/api/vps", "GET")):
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
