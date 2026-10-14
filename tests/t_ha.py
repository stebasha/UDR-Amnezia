#!/usr/bin/env python3
"""Тесты awg-ha (Home Assistant, MQTT discovery) на стенде web_lab с поддельным брокером MQTT (без сети)."""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB = tempfile.mkdtemp(prefix="awgha-")
FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


def vlen(sock):
    n, mult = 0, 1
    while True:
        b = sock.recv(1)
        if not b:
            raise OSError("closed")
        n += (b[0] & 0x7F) * mult
        mult *= 128
        if not b[0] & 0x80:
            return n


def recv_exact(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            raise OSError("closed")
        b += c
    return b


def mstr(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b


class Broker(threading.Thread):
    """Поддельный брокер: принимает одно соединение за раз, отвечает CONNACK/SUBACK/PINGRESP, пишет PUBLISH."""

    def __init__(self, rc=0):
        super().__init__(daemon=True)
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(5)
        self.port = self.srv.getsockname()[1]
        self.rc = rc
        self.pubs = []          # (topic, payload, retain)
        self.subs = []
        self.connect = None
        self.client = None

    def run(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            self.client = c
            try:
                while True:
                    h = recv_exact(c, 1)[0]
                    body = recv_exact(c, vlen(c))
                    t = h & 0xF0
                    if t == 0x10:
                        self.connect = body
                        c.sendall(bytes([0x20, 2, 0, self.rc]))
                    elif t == 0x30:
                        n = struct.unpack("!H", body[:2])[0]
                        self.pubs.append((body[2:2 + n].decode(), body[2 + n:].decode(), bool(h & 1)))
                    elif t == 0x80:
                        pid = body[:2]
                        i = 2
                        while i < len(body):
                            n = struct.unpack("!H", body[i:i + 2])[0]
                            self.subs.append(body[i + 2:i + 2 + n].decode())
                            i += 3 + n
                        c.sendall(bytes([0x90, 2 + (len(self.subs) or 1)]) + pid + b"\x00" * (len(self.subs) or 1))
                    elif t == 0xC0:
                        c.sendall(bytes([0xD0, 0]))
                    elif t == 0xE0:
                        break
            except OSError:
                pass
            c.close()

    def send(self, topic, payload):
        body = mstr(topic) + payload.encode()
        self.client.sendall(bytes([0x30, len(body)]) + body)

    def last(self, topic):
        for t, p, r in reversed(self.pubs):
            if t == topic:
                return p, r
        return None, None


def lab_env():
    pid = subprocess.check_output([os.path.join(R, "tests/web_lab.sh"), LAB, "18490"]).decode().strip().splitlines()[-1]
    env = dict(x.split("=", 1) for x in open("/proc/%s/environ" % pid).read().split("\0") if "=" in x)
    subprocess.call(["kill", pid])
    return env


def write_conf(dd, port, **kw):
    c = {"MQTT_HOST": "127.0.0.1", "MQTT_PORT": str(port), "MQTT_USER": "ha", "MQTT_PASS": "secret-pw", "MQTT_TLS": "no",
         "HA_PREFIX": "homeassistant", "HA_INTERVAL": "10", "HA_ALLOW_REBOOT": "no"}
    c.update(kw)
    with open(os.path.join(dd, "ha.env"), "w") as f:
        f.write("".join('%s="%s"\n' % kv for kv in c.items()))


def main():
    env = lab_env()
    dd = env["DD"]
    ha = os.path.join(R, "awg/ha.py")
    env["DD"] = dd
    os.makedirs(os.path.join(dd, "route.d"), exist_ok=True)     # дополнительный маршрут (#40)
    open(os.path.join(dd, "route.d", "us.env"), "w").write('RAIL_IF="wgclt2"\nPRIO="32507"\nMARK="0x6c0000/0x7e0000"\nTABLE="179"\nTUNNELS="awgbackup awgmain"\nLABEL="США"\n')
    open(os.path.join(env["AWG_RUN"], "awg-state-us"), "w").write("ACTIVE=awgbackup\n")

    # ---------- ha.py test: discovery и состояние
    b = Broker()
    b.start()
    write_conf(dd, b.port)
    p = subprocess.run([sys.executable, ha, "test"], env=env, capture_output=True, text=True, timeout=60)
    check("test: подключение и публикация", p.returncode == 0 and "OK" in p.stdout, p.stdout + p.stderr)
    cfgs = {t: json.loads(pl) for t, pl, r in b.pubs if t.endswith("/config") and r}
    node = [t for t in cfgs][0].split("/")[2] if cfgs else ""
    check("CONNECT с логином, паролем и LWT", b.connect and b"ha" in b.connect and b"secret-pw" in b.connect and b"offline" in b.connect, b.connect)
    sel = cfgs.get("homeassistant/select/%s/mode/config" % node, {})
    check("select «Канал»: авто и все туннели", sel.get("options") == ["auto", "awgmain", "awgbackup", "awgalt1"], sel)
    check("датчики туннелей и роутера", all(("homeassistant/sensor/%s/%s/config" % (node, o)) in cfgs for o in ("active", "cpu", "temp", "awgmain_rtt", "awgbackup_rx")), list(cfgs)[:8])
    check("кнопки перезапуска туннелей, перезагрузки нет", ("homeassistant/button/%s/awgmain_restart/config" % node) in cfgs
          and ("homeassistant/button/%s/reboot/config" % node) not in cfgs)
    check("у сущностей общее устройство и доступность", all(c["device"]["identifiers"] == [node] and c["availability_topic"].endswith("/status") for c in cfgs.values()))
    rs = cfgs.get("homeassistant/select/%s/route_us_mode/config" % node, {})
    check("маршрут: select канала с цепочкой маршрута, датчики", rs.get("options") == ["auto", "awgbackup", "awgmain"] and rs.get("command_topic", "").endswith("/set/route/us")
          and "США" in rs.get("name", "") and ("homeassistant/sensor/%s/route_us_active/config" % node) in cfgs, rs)
    st, ret = b.last("udr_amnezia/%s/state" % node)
    st = json.loads(st or "{}")
    check("состояние: маршрут с каналом и режимом", st.get("routes", {}).get("us", {}).get("active") == "awgbackup" and st["routes"]["us"]["mode"] == "auto", st.get("routes"))
    check("состояние: активный канал, режим, туннели", st.get("active") == "awgmain" and st.get("mode") == "auto" and "awgmain" in st.get("tunnels", {}) and ret, st)
    av, _ = b.last("udr_amnezia/%s/status" % node)
    check("доступность online", av == "online", av)
    secrets_leak = [pl for t, pl, r in b.pubs if "PrivateKey" in pl or "secret-pw" in pl]
    check("ключи и пароль брокера не публикуются", not secrets_leak, secrets_leak[:1])

    # ---------- неверный пароль
    b2 = Broker(rc=4)
    b2.start()
    write_conf(dd, b2.port)
    p = subprocess.run([sys.executable, ha, "test"], env=env, capture_output=True, text=True, timeout=60)
    check("неверный пароль брокера → FAIL с причиной", p.returncode == 1 and "неверный логин или пароль" in p.stdout, p.stdout)

    # ---------- служба: команды из HA
    b3 = Broker()
    b3.start()
    write_conf(dd, b3.port, HA_ALLOW_REBOOT="no")
    srv = subprocess.Popen([sys.executable, ha], env=dict(env, AWG_HA_STDERR="1"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(100):
            if b3.subs:
                break
            time.sleep(0.1)
        check("служба подписана на команды (без перезагрузки)", sorted(x.rsplit("/", 1)[-1] for x in b3.subs) == ["+", "mode", "restart"], b3.subs)
        forcef = os.path.join(env["AWG_RUN"], "awg-force")
        b3.send("udr_amnezia/%s/set/mode" % node, "awgbackup")
        time.sleep(1.5)
        check("select → ручной выбор канала (как «Активировать»)", os.path.exists(forcef) and open(forcef).read().strip() == "awgbackup",
              open(forcef).read() if os.path.exists(forcef) else "нет файла")
        b3.send("udr_amnezia/%s/set/mode" % node, "auto")
        time.sleep(1.5)
        check("select auto → автовыбор", not os.path.exists(forcef))
        b3.send("udr_amnezia/%s/set/route/us" % node, "awgmain")
        time.sleep(1.5)
        fu = os.path.join(env["AWG_RUN"], "awg-force-us")
        check("маршрут: select → ручной выбор канала маршрута", os.path.exists(fu) and open(fu).read().strip() == "awgmain",
              open(fu).read() if os.path.exists(fu) else "нет файла")
        b3.send("udr_amnezia/%s/set/route/us" % node, "auto")
        time.sleep(1.5)
        check("маршрут: auto → автовыбор", not os.path.exists(fu))
        os.remove(os.path.join(dd, "route.d", "us.env"))
        time.sleep(12)
        gone = [pl for t, pl, r in b3.pubs if t == "homeassistant/select/%s/route_us_mode/config" % node]
        check("убранный маршрут исчезает из HA", gone and gone[-1] == "", gone[-2:])
        b3.send("udr_amnezia/%s/set/reboot" % node, "reboot")
        b3.send("udr_amnezia/%s/set/mode" % node, "evil; reboot")
        time.sleep(1.5)
        srl = os.path.join(LAB, "systemd-run.log")
        check("перезагрузка из HA выключена по умолчанию", not os.path.exists(srl) or "awg-reboot" not in open(srl).read())
        aud = open(os.path.join(dd, "web", "audit.log")).read()
        check("действия из HA в журнале панели", "homeassistant" in aud and "switch" in aud, aud[-300:])
        check("служба жива после мусорной команды", srv.poll() is None)
    finally:
        srv.terminate()
        try:
            out, errs = srv.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            srv.kill()
            out, errs = srv.communicate()
        if FAILS:
            print(errs[-1500:])
    # ---------- брокер шлёт пакет с огромной длиной: соединение рвётся, память не копится
    code = ("import socket, sys; sys.path.insert(0, %r); import ha\n"
            "a, b = socket.socketpair(); m = ha.MQTT.__new__(ha.MQTT); m.sock = a; m.buf = b''\n"
            "b.sendall(bytes([0x30, 0xff, 0xff, 0xff, 0x7f]) + b'x' * 1000)\n"
            "try:\n    m.read_packet(2); print('NO')\nexcept OSError as ex:\n    print('ERR', ex)\n") % os.path.join(R, "awg")
    p = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=30)
    check("MQTT: пакет больше 256 КБ — разрыв, а не накопление", "ERR" in p.stdout and "большой" in p.stdout, p.stdout + p.stderr[-300:])
    print("\nha: %d ошибок" % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
