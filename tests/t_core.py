#!/usr/bin/env python3
"""Защитные функции панели без сервера: запись в файлы, которые читает bash (source), и проверки настроек."""
import os, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgcore-")
os.environ.update(DD=T, AWG_WEBD=os.path.join(T, "web"), AWG_RUN=T)
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.core as C  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


def raises(f, *a):
    try:
        f(*a)
        return False
    except ValueError:
        return True


# fmt_env: всё, что bash выполнил бы при source, не пишется; остальное читается bash буквально
for bad in ['a$(id)', 'a`id`', 'a"b', 'a\\b', 'a\nB=1', 'a\x00b']:
    check("fmt_env: отказ для %r" % bad, raises(C.fmt_env, "K", bad))
check("fmt_env: имя ключа проверяется", raises(C.fmt_env, "K;rm", "x"))
f = os.path.join(T, "e.env")
for v in ["x;reboot", "a|b&c", "(x)", "1.2.3.4/24", "", "a b", "https://h/p?x=1&y=2", "*"]:
    open(f, "w").write(C.fmt_env("K", v) + "\n")
    out = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$K"', "_", f], capture_output=True, text=True).stdout
    check("fmt_env: bash читает %r буквально" % v, out == v, out)

# проверки настроек
check("домены: команда в имени — отказ", raises(C.v_domains, "a.com;reboot"))
check("домены: из адреса берётся имя", C.v_domains("https://Example.COM/path") == "example.com")
check("подсети/адреса клиентов: мусор — отказ", raises(C.v_hosts, "1.2.3.4 $(id)"))
check("страны: только две буквы", C.v_countries("RU, cn;by") == "ru cn by" and raises(C.v_countries, "rus"))
check("источники списков: только https и без спецсимволов", raises(C.v_https_urls, "http://a.b/x") and raises(C.v_https_urls, "https://a.b/$(id)")
      and raises(C.v_https_urls, "https://a.b/x;y") and C.v_https_urls("https://a.b/x.lst") == "https://a.b/x.lst")
for k, (val, _svc, _lab) in C.SETTINGS.items():
    for bad in ['x$(id)', 'x`id`', 'x"y', 'x;reboot']:
        try:
            v = val(bad)
        except (ValueError, TypeError):
            continue
        check("настройка %s: «%s» не пропускается или безопасна" % (k, bad), not any(c in v for c in '$`";'), v)
# run(): по сроку завершаются и потомки команды, а не только она сама
import time  # noqa: E402
mark = os.path.join(T, "child-alive")
t0 = time.time()
rc, out = C.run(["bash", "-c", "(sleep 2; touch %s) & sleep 30" % mark], timeout=1)
check("run: срок соблюдён", rc == 124 and time.time() - t0 < 4, (rc, out))
time.sleep(2.5)
check("run: потомки завершены вместе с командой", not os.path.exists(mark))
check("run: ввод, код возврата, нет команды", C.run(["cat"], inp="abc") == (0, "abc") and C.run(["sh", "-c", "exit 3"])[0] == 3
      and C.run([os.path.join(T, "nope")])[0] == 127)

# фоновые задачи панели: зависшая без вывода команда снимается по сроку; одновременно не больше MAX_RUNNING
import awgweb.data as D  # noqa: E402
J = D.Jobs()
jid = J.start("hang", ["bash", "-c", "sleep 30 & sleep 30"], timeout=1)
time.sleep(2.5)
x = J.get(jid)
check("задача без вывода снята по сроку", x["done"] and "превышено время" in x["out"], x)
ids = [J.start("s%d" % i, ["sleep", "3"], timeout=10) for i in range(D.Jobs.MAX_RUNNING)]
check("та же задача повторно не запускается", J.start("s0", ["sleep", "3"]) == ids[0])
try:
    J.start("extra", ["true"])
    over = False
except C.ApiError as ex:
    over = ex.code == 429
check("сверх MAX_RUNNING — отказ 429", over)
# up.sh из панели — под замком сторожа: пока туннель перезапускает другая служба, второй up.sh не идёт
import fcntl  # noqa: E402
up = os.path.join(T, "up.sh")
open(up, "w").write("#!/bin/sh\necho \"up $1\" >> %s/up.log\n" % T)
os.chmod(up, 0o755)
lk = open(os.path.join(T, "awg-up-awgx.lock"), "w")
fcntl.flock(lk, fcntl.LOCK_EX)
rc, out = C.up_tunnel("awgx", wait=1)
check("up_tunnel: замок занят — up.sh не запускается", rc == 1 and not os.path.exists(os.path.join(T, "up.log")), (rc, out))
fcntl.flock(lk, fcntl.LOCK_UN)
rc, out = C.up_tunnel("awgx", wait=1)
check("up_tunnel: замок свободен — up.sh выполнен", rc == 0 and C.read_file(os.path.join(T, "up.log")) == "up awgx\n", (rc, out))
# импорт vpn://: сжатая «бомба» не разворачивается в память целиком
import base64, struct, zlib  # noqa: E401,E402
import awgweb.importer as IM  # noqa: E402
bomb = zlib.compress(b'{"a":"' + b"x" * (64 * 1024 * 1024) + b'"}', 9)
try:
    IM.decode_import("vpn://" + base64.urlsafe_b64encode(struct.pack(">I", 100) + bomb).decode())
    bomb_ok = False
except ValueError as ex:
    bomb_ok = "слишком большая" in str(ex)
check("vpn://: распаковка ограничена 2 МБ", bomb_ok)
# 3x-ui: токен не уходит по переадресации на другой хост; на тот же хост — можно
import http.server, threading as _th  # noqa: E401,E402
import awgweb.xui as XU  # noqa: E402
SEEN = []


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        SEEN.append((self.headers.get("Host", ""), self.path, self.headers.get("Authorization", "")))
        if self.path == "/away":
            self.send_response(302)
            self.send_header("Location", "http://localhost:%d/steal" % self.server.server_port)
            self.end_headers()
        elif self.path == "/same":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.end_headers()
        else:
            b = b'{"success": true, "obj": 7}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
_th.Thread(target=srv.serve_forever, daemon=True).start()
pp = {"url": "http://127.0.0.1:%d" % srv.server_port, "token": "SECRET-T"}
try:
    XU.xui_req("GET", "/away", p=pp)
    away = False
except ValueError as ex:
    away = "переадресует" in str(ex)
check("3x-ui: переадресация на другой хост — отказ, токен не отправлен", away and not any(x[1] == "/steal" for x in SEEN), SEEN)
check("3x-ui: переадресация на тот же хост работает", XU.xui_req("GET", "/same", p=pp) == 7, SEEN)
srv.shutdown()
# сохранённый секрет (заголовок вебхука, токен ntfy, токен 3x-ui) не уходит на новый узел без повторного ввода
check("keep_secret: тот же узел, другой путь — можно", not raises(C.keep_secret, "https://h.example/a", "https://h.example/b", "x"))
check("keep_secret: другой узел, схема или порт — нельзя", raises(C.keep_secret, "https://h.example/a", "https://evil.example/a", "x")
      and raises(C.keep_secret, "https://h.example/a", "http://h.example/a", "x") and raises(C.keep_secret, "https://h.example/a", "https://h.example:8443/a", "x"))
import awgweb.server as S  # noqa: E402


class FakeH:
    user = "admin"

    def act(self, *a):
        pass


open(C.HOOKS_F, "w").write('HOOK_URL="https://hooks.example/abc"\nHOOK_HEADER="X-Key: s3cret"\nNTFY_URL="https://ntfy.example/t"\nNTFY_TOKEN="tk_1"\n')
check("вебхук: новый узел без заголовка — отказ, файл не тронут", raises(S.api_hooks_set, FakeH(), {"hook": "https://evil.example/x", "ntfy": "https://ntfy.example/t"})
      and "hooks.example" in C.read_file(C.HOOKS_F))
check("ntfy: новый узел без токена — отказ", raises(S.api_hooks_set, FakeH(), {"ntfy": "https://evil.example/t"}))
json_db = '{"panels": {"p1": {"label": "x", "url": "https://xui.example:2053/p", "token": "tokentoken1", "insecure": false, "host": ""}}, "tunnels": {}}'
open(S.XUI_DB_F, "w").write(json_db)
check("3x-ui: новый адрес без токена — отказ, токен не перенесён", raises(S.api_xui_set, FakeH(), {"id": "p1", "url": "https://evil.example:2053/p"})
      and S.xui_db()["panels"]["p1"]["url"] == "https://xui.example:2053/p")
check("3x-ui: тот же узел — прежний токен остаётся", S.api_xui_set(FakeH(), {"id": "p1", "url": "https://xui.example:2053/p2"})["ok"]
      and S.xui_db()["panels"]["p1"]["token"] == "tokentoken1")
print("core: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
