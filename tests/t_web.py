#!/usr/bin/env python3
"""Тесты API веб-панели на стенде tests/web_lab.sh (без root, без сети)."""
import base64
import hashlib
import hmac
import http.client
import json
import os
import struct
import subprocess
import sys
import tempfile
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
        check("обзор: AWG 2.0 у основного", ov["tunnels"][0]["proto"] == "AWG 2.0", ov["tunnels"][0]["proto"])
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
