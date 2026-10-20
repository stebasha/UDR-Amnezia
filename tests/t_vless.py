#!/usr/bin/env python3
"""VLESS/Reality (#42) без сети и без Xray: разбор ссылок и подписок, страна, конфиг Xray, API подписок и туннелей
(скачивание, up.sh и службы — заглушки), up.sh --conf-of и поднятие туннеля Xray на заглушках."""
import base64, json, os, socket, subprocess, sys, tempfile, threading
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgvless-")
os.makedirs(os.path.join(T, "web"))
os.environ.update(DD=T, AWG_WEBD=os.path.join(T, "web"), AWG_RUN=T, STATEF=os.path.join(T, "awg-state"))
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.server as S  # noqa: E402
import awgweb.vless as V  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


def raises(f, *a, **k):
    try:
        f(*a, **k)
        return False
    except (ValueError, S.ApiError):
        return True


PBK = "Z" * 43
L1 = ("vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?security=reality&type=tcp&flow=xtls-rprx-vision"
      "&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=ab12#%%F0%%9F%%87%%AB%%F0%%9F%%87%%AE%%20Helsinki%%201" % PBK)
L2 = "vless://aaaaaaaa-2222-3333-4444-555555555555@203.0.113.20:8443?security=tls&type=ws&path=%2Fws&host=cdn.example.com&sni=cdn.example.com#Germany%20Frankfurt"
L3 = "vless://bbbbbbbb-2222-3333-4444-555555555555@203.0.113.30:443?security=reality&type=grpc&serviceName=gr&pbk=%s&sni=a.com#NL-2" % PBK

# ---------------------------------------------------------------- разбор
s1 = V.parse_vless(L1)
check("vless: Reality, vision, флаг → FI", s1["security"] == "reality" and s1["flow"] == "xtls-rprx-vision" and s1["country"] == "FI"
      and s1["sni"] == "www.microsoft.com" and s1["sid"] == "ab12" and s1["port"] == 443, s1)
s2 = V.parse_vless(L2)
check("vless: TLS + ws, страна по названию", s2["type"] == "ws" and s2["path"] == "/ws" and s2["hosthdr"] == "cdn.example.com" and s2["country"] == "DE", s2)
check("vless: страна по коду в имени (NL-2)", V.parse_vless(L3)["country"] == "NL")
for bad, why in [("vmess://abc", "другой протокол"), (L1.replace("pbk=" + PBK, "pbk="), "Reality без pbk"),
                 (L1.replace("security=reality", "security=xtls"), "неизвестная защита"), (L1.replace("type=tcp", "type=kcp"), "неизвестный транспорт"),
                 (L1.replace("sid=ab12", "sid=zz"), "неверный sid"), (L1.replace("@203.0.113.10:443", "@203.0.113.10"), "нет порта"),
                 (L1.replace("sni=www.microsoft.com", "sni=a%22b"), "кавычка в значении"), (L1.replace("flow=xtls-rprx-vision", "flow=evil"), "неизвестный flow")]:
    check("vless: отказ — %s" % why, raises(V.parse_vless, bad))
check("vless: id стабилен и не зависит от имени", V.parse_vless(L1.split("#")[0] + "#other")["id"] == s1["id"])
sub_b64 = base64.b64encode("\n".join([L1, L2, L3, "vmess://xxx", "trojan://y@h:1", L1]).encode()).decode()
servers, skipped = V.parse_sub(sub_b64)
check("подписка base64: 3 сервера VLESS, дубликат убран, 2 строки пропущены", len(servers) == 3 and skipped == 2, (len(servers), skipped))
check("подписка открытым текстом", len(V.parse_sub(L1 + "\r\n" + L2)[0]) == 2)
check("подписка base64url без дополнения", len(V.parse_sub(base64.urlsafe_b64encode((L1 + "\n").encode()).decode().rstrip("="))[0]) == 1)
check("страна: эмодзи, названия по-русски", V.country_of("🇩🇪 x") == "DE" and V.country_of("Нидерланды #3") == "NL" and V.country_of("Server 7") == "")

# ---------------------------------------------------------------- выбор сервера и задержка
for s, p in zip(servers, (40, 15, -1)):
    s["ping"] = p
check("выбор: самый быстрый среди всех", V.pick(servers)["id"] == s2["id"])
check("выбор: самый быстрый в стране", V.pick(servers, "FI")["id"] == s1["id"])
check("выбор: никто не ответил — первый в стране", V.pick(servers, "NL")["country"] == "NL")
check("выбор: заданный сервер", V.pick(servers, "", s1["id"])["id"] == s1["id"] and V.pick(servers, "US") is None)
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(4)
threading.Thread(target=lambda: [ls.accept() for _ in range(4)], daemon=True).start()
check("tcp_ping: открытый порт — мс, закрытый — -1", V.tcp_ping("127.0.0.1", ls.getsockname()[1]) >= 0 and V.tcp_ping("127.0.0.1", 1, 1) == -1)

# ---------------------------------------------------------------- конфиг Xray
c = V.xray_conf("awgvl", s1, "203.0.113.10", 1400, "eth4")
ob = c["outbounds"][0]
st = ob["streamSettings"]
check("xray: вход tun с именем туннеля и MTU", c["inbounds"][0]["protocol"] == "tun" and c["inbounds"][0]["settings"]["name"] == "awgvl"
      and c["inbounds"][0]["settings"]["mtu"] == 1400)
check("xray: Reality (pbk, sid, sni, fp) и flow", st["security"] == "reality" and st["realitySettings"]["publicKey"] == PBK
      and st["realitySettings"]["shortId"] == "ab12" and ob["settings"]["vnext"][0]["users"][0]["flow"] == "xtls-rprx-vision")
check("xray: соединения привязаны к WAN (без петли через туннель)", st["sockopt"]["interface"] == "eth4")
check("xray: адрес сервера — IPv4", ob["settings"]["vnext"][0]["address"] == "203.0.113.10")
c2 = V.xray_conf("awgvl", s2, "203.0.113.20", 1400, "")
check("xray: TLS + ws (путь, Host)", c2["outbounds"][0]["streamSettings"]["tlsSettings"]["serverName"] == "cdn.example.com"
      and c2["outbounds"][0]["streamSettings"]["wsSettings"]["path"] == "/ws" and "sockopt" not in c2["outbounds"][0]["streamSettings"])

# ---------------------------------------------------------------- API на заглушках
open(os.path.join(T, "awg.env"), "w").write('MAIN=awgmain\nBACKUP=awgbackup\nTUNNELS_EXTRA=""\nWANIF=eth4\n')
calls = {"up": [], "run": [], "fetch": 0}
SUB = {"text": sub_b64}


def fake_fetch(url):
    calls["fetch"] += 1
    return SUB["text"]


V.sub_fetch = fake_fetch
V.ping_all = lambda ss: [s.update(ping=10 + i) or s for i, s in enumerate(ss)]
V.up_tunnel = lambda t, **k: calls["up"].append(t) or (0, "ok")
V.svc_active = lambda u: False
V.run = lambda cmd, **k: calls["run"].append(cmd) or (0, "")
V.need_pw = lambda h, d, w: None
V.link_exists = lambda t: t in calls["up"]


class H:
    user = "admin"

    def __init__(self):
        self.acts = []

    def act(self, a, d=""):
        self.acts.append(a)


h = H()
check("подписка: только https", raises(V.api_vless_sub_set, h, {"url": "http://sub.example.com/x"}))
check("подписка: спецсимволы в адресе — отказ", raises(V.api_vless_sub_set, h, {"url": "https://sub.example.com/a\"b"}))
r = V.api_vless_sub_set(h, {"url": "https://sub.example.com/api/sub/SECRETTOKEN", "label": "Мой VPN"})
check("подписка добавлена: 3 сервера", r["ok"] and r["id"] == "s1" and "3" in r["msg"], r)
check("файл подписок — 600", oct(os.stat(V.VL_DB_F).st_mode & 0o777) == "0o600")
g = V.api_vless_get(h, {})
check("GET: адрес подписки без токена", g["subs"][0]["url"] == "https://sub.example.com/…" and "SECRETTOKEN" not in json.dumps(g), g["subs"][0]["url"])
check("GET: UUID серверов в браузер не уходят", "11111111-2222" not in json.dumps(g))
check("GET: страны подписки", g["subs"][0]["countries"] == ["DE", "FI", "NL"], g["subs"][0]["countries"])
SUB["text"] = "<html>не подписка</html>"
check("пустой ответ: ошибка, прежний список на месте", raises(V.api_vless_sub_set, h, {"id": "s1"}) and len(V.vl_db()["subs"]["s1"]["servers"]) == 3)
SUB["text"] = sub_b64
check("туннель: без Xray — понятный отказ", raises(V.api_vless_tunnel, h, {"name": "awgvl", "sub": "s1", "country": "FI"}))
os.makedirs(V.XD, exist_ok=True)
open(V.XRAY_BIN, "w").write("#!/bin/sh\necho 'Xray 25.9.11 (Xray, Penetrates Everything.)'\n")
os.chmod(V.XRAY_BIN, 0o755)
check("туннель: имя по правилам", raises(V.api_vless_tunnel, h, {"name": "vless", "sub": "s1"}))
check("туннель: имя основного туннеля занято", raises(V.api_vless_tunnel, h, {"name": "awgmain", "sub": "s1"}))
r = V.api_vless_tunnel(h, {"name": "awgvl", "sub": "s1", "country": "FI", "label": "VLESS FI"})
e = S.env()
check("туннель добавлен: в TUNNELS_EXTRA и XRAY_TUNNELS", r["ok"] and e.get("TUNNELS_EXTRA") == "awgvl" and e.get("XRAY_TUNNELS") == "awgvl", (r, e))
check("туннель поднят через up.sh", calls["up"] == ["awgvl"])
cfg = json.load(open(os.path.join(V.XD, "awgvl.json")))
info = json.load(open(os.path.join(V.XD, "awgvl.info")))
check("файлы туннеля: конфиг 600, сервер FI, адрес 198.19.1.1/32", oct(os.stat(os.path.join(V.XD, "awgvl.json")).st_mode & 0o777) == "0o600"
      and info["country"] == "FI" and info["addr"] == "198.19.1.1/32" and cfg["inbounds"][0]["settings"]["name"] == "awgvl", info)
check(".server — адрес для исключений awg-self", open(os.path.join(V.XD, "awgvl.server")).read().strip() == "203.0.113.10")
check(".info без UUID", "11111111" not in open(os.path.join(V.XD, "awgvl.info")).read())
check("ядро: туннель VLESS распознан", S.is_xray("awgvl") and not S.is_xray("awgmain"))
check("WG-операции для VLESS — отказ с подсказкой", raises(S.wg_only, "awgvl"))
ti = S.tunnel_info("awgvl", e, {}, "", {})
check("обзор: VLESS, сервер и адрес из .info", (ti.get("kind") == "vless" and "203.0.113.10" in str(ti.get("endpoint", ""))), ti)
r = V.api_vless_tunnel(h, {"name": "awgvl", "sub": "s1", "server": s2["id"]})
info = json.load(open(os.path.join(V.XD, "awgvl.info")))
check("смена сервера: конкретный сервер, адрес интерфейса тот же", r["ok"] and info["country"] == "DE" and info["addr"] == "198.19.1.1/32"
      and V.vl_db()["tunnels"]["awgvl"]["mode"] == "fixed", info)
check("второй туннель — свой адрес 198.19.2.1", V.api_vless_tunnel(h, {"name": "awgvl2", "sub": "s1", "country": "NL"})["ok"]
      and json.load(open(os.path.join(V.XD, "awgvl2.info")))["addr"] == "198.19.2.1/32")
# обновление подписки: сервер туннеля (auto) пропал — туннель на лучший в стране
SUB["text"] = "\n".join([L2, L3.replace("203.0.113.30", "203.0.113.31")])
r = V.api_vless_sub_refresh(h, {"id": "s1"})
db = V.vl_db()
check("обновление: туннель NL переехал на новый сервер страны", "awgvl2" in r["msg"] and json.load(open(os.path.join(V.XD, "awgvl2.info")))["ip"] == "203.0.113.31", r)
check("обновление: туннель с заданным сервером не тронут", db["tunnels"]["awgvl"]["server"] == s2["id"])
check("подписку с туннелями не удалить", raises(V.api_vless_sub_remove, h, {"id": "s1"}))
db["subs"]["s1"]["updated"] = 1
V.vl_db_save(db)
n0 = calls["fetch"]
check("сторож: просроченная подписка обновляется", V.vless_refresh_due() and calls["fetch"] == n0 + 1)
check("сторож: свежая — нет", V.vless_refresh_due() == [] and calls["fetch"] == n0 + 1)
V.tunnel_remove = lambda t: None
r = V.api_vless_tunnel_remove(h, {"name": "awgvl2"})
check("удаление: из XRAY_TUNNELS, файлы удалены, служба остановлена", r["ok"] and S.env().get("XRAY_TUNNELS") == "awgvl"
      and not os.path.exists(os.path.join(V.XD, "awgvl2.json")) and ["systemctl", "stop", "awg-xray-awgvl2"] in calls["run"])
check("удаление: только туннели VLESS", raises(V.api_vless_tunnel_remove, h, {"name": "awgmain"}))
check("журнал действий", "vless-sub" in h.acts and "vless-tunnel" in h.acts and "vless-remove" in h.acts, h.acts)
check("маршруты API подключены", ("POST", "/api/vless/tunnel") in S.ROUTES and ("GET", "/api/vless") in S.ROUTES)

# ---------------------------------------------------------------- up.sh
U = tempfile.mkdtemp(prefix="awgvless-up-")
B = os.path.join(U, "bin")
os.makedirs(os.path.join(U, "xray"))
os.makedirs(B)
open(os.path.join(U, "awg.env"), "w").write('MAIN=awgmain\nTUNNELS_EXTRA="awgx awgy"\nXRAY_TUNNELS="awgx"\n')
LOG = os.path.join(U, "log")
for n, body in {"ip": 'echo "ip $*" >> "$LOG"; case "$*" in "link show awgx") [ -f "$U/up" ];; "link show"*) exit 1;; esac; exit 0',
                "sysctl": 'echo "sysctl $*" >> "$LOG"', "systemctl": 'echo "systemctl $*" >> "$LOG"'}.items():
    open(os.path.join(B, n), "w").write("#!/bin/bash\n" + body + "\n")
    os.chmod(os.path.join(B, n), 0o755)
open(os.path.join(U, "xray", "xray"), "w").write('#!/bin/bash\necho "xray $*" >> "$LOG"; [ "$2" = -test ] && exit 0; touch "$U/up"; exit 0\n')
os.chmod(os.path.join(U, "xray", "xray"), 0o755)
json.dump({"addr": "198.19.1.1/32", "mtu": 1380, "host": "h", "port": 443}, open(os.path.join(U, "xray", "awgx.info"), "w"))
open(os.path.join(U, "xray", "awgx.json"), "w").write("{}")
envx = dict(os.environ, DD=U, U=U, LOG=LOG, AWG_RUN=U, AWG_NO_SCOPE="1", PATH=B + ":" + os.environ["PATH"])
co = lambda t: subprocess.run(["bash", os.path.join(R, "awg/up.sh"), "--conf-of", t], env=envx, capture_output=True, text=True).stdout.strip()
check("up.sh --conf-of: VLESS → xray/ИМЯ.json, AWG → ИМЯ.conf", co("awgx") == "xray/awgx.json" and co("awgy") == "awgy.conf", (co("awgx"), co("awgy")))
p = subprocess.run(["bash", os.path.join(R, "awg/up.sh"), "awgx"], env=envx, capture_output=True, text=True, timeout=30)
lg = open(LOG).read() if os.path.exists(LOG) else ""
check("up.sh: туннель VLESS поднят (Xray, адрес, MTU, rp_filter)", p.returncode == 0 and "xray run -test -c" in lg and "ip addr add 198.19.1.1/32 dev awgx" in lg
      and "ip link set awgx up mtu 1380" in lg and "rp_filter=0" in lg, p.stdout + p.stderr + lg)
os.remove(os.path.join(U, "xray", "xray"))
p = subprocess.run(["bash", os.path.join(R, "awg/up.sh"), "awgx"], env=envx, capture_output=True, text=True, timeout=30)
check("up.sh: без Xray — понятная ошибка", p.returncode != 0 and "Xray не установлен" in p.stdout, p.stdout)

# ---------------------------------------------------------------- xray.sh: официальный релиз, сверка SHA256 (curl — заглушка)
import hashlib, zipfile  # noqa: E402
X = tempfile.mkdtemp(prefix="awgvless-x-")
XB, REL = os.path.join(X, "bin"), os.path.join(X, "rel")
os.makedirs(XB)
os.makedirs(REL)
asset = {"aarch64": "Xray-linux-arm64-v8a.zip", "x86_64": "Xray-linux-64.zip"}.get(os.uname().machine, "Xray-linux-64.zip")
zp = os.path.join(REL, asset)
with zipfile.ZipFile(zp, "w") as z:
    z.writestr(zipfile.ZipInfo("xray"), '#!/bin/sh\necho "Xray 25.9.11 (Xray, Penetrates Everything.) linux"\n')
dg = hashlib.sha256(open(zp, "rb").read()).hexdigest()
open(zp + ".dgst", "w").write("MD5= 00\nSHA2-256= %s\nSHA2-512= 11\n" % dg)
open(os.path.join(REL, "latest"), "w").write('{"tag_name": "v25.9.11", "name": "Xray-core v25.9.11"}')
open(os.path.join(XB, "curl"), "w").write("""#!/bin/bash
o=""; u=""; while [ $# -gt 0 ]; do case "$1" in -o) o=$2; shift;; https://*) u=$1;; esac; shift; done
echo "$u" >> "$REL/urls"
case "$u" in */releases/latest) f=$REL/latest;; */releases/download/v25.9.11/*) f=$REL/${u##*/};; *) exit 22;; esac
[ -f "$f" ] || exit 22; cp "$f" "$o"
""")
os.chmod(os.path.join(XB, "curl"), 0o755)
os.makedirs(os.path.join(X, "dd"))
open(os.path.join(X, "dd", "awg.env"), "w").write('XRAY_TUNNELS=""\n')
envs = dict(os.environ, DD=os.path.join(X, "dd"), REL=REL, STATEF=os.path.join(X, "st"), PATH=XB + ":" + os.environ["PATH"])
xr = lambda *a: subprocess.run(["bash", os.path.join(R, "awg/xray.sh")] + list(a), env=envs, capture_output=True, text=True, timeout=60)
check("xray.sh latest: версия из официального релиза", xr("latest").stdout.strip() == "25.9.11")
p = xr("install")
urls = open(os.path.join(REL, "urls")).read()
check("xray.sh install: SHA256 сверен, установлен", p.returncode == 0 and "SHA-256 совпал" in p.stdout and xr("version").stdout.strip() == "25.9.11", p.stdout + p.stderr)
check("xray.sh: только github.com/XTLS/Xray-core", all(u.startswith(("https://github.com/XTLS/Xray-core/", "https://api.github.com/repos/XTLS/Xray-core/"))
                                                     for u in urls.split()), urls)
check("xray.sh install: та же версия — без скачивания", "уже установлен" in xr("install").stdout)
open(zp + ".dgst", "w").write("SHA2-256= %s\n" % ("0" * 64))
os.remove(os.path.join(X, "dd", "xray", "xray"))
p = xr("install", "25.9.11")
check("xray.sh: SHA256 не совпал — не устанавливает", p.returncode != 0 and "не совпал" in p.stderr and not os.path.exists(os.path.join(X, "dd", "xray", "xray")), p.stdout + p.stderr)
check("xray.sh: неверная версия — отказ", xr("install", "1.2;id").returncode != 0)

print("t_vless: провалов %d" % len(FAILS))
sys.exit(1 if FAILS else 0)
