#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""awg-ha: интеграция с Home Assistant через MQTT discovery (#5). Только стандартная библиотека Python.

Home Assistant сам находит устройство «UDR-Amnezia» (интеграция MQTT в HA, брокер Mosquitto и т. п.):
  датчики — активный канал, режим (авто/вручную), по каждому туннелю: связь, handshake, RTT, потери, трафик;
            kill switch, состояние, число замечаний, процессор, память, температура, свободно на /data;
  select «Канал» — авто или конкретный туннель (то же, что «Активировать»/«Автовыбор» в панели);
  дополнительные маршруты (#22, #40) — по каждому: канал, связь, select «Маршрут …: канал» (авто или туннель цепочки);
  кнопки — перезапуск туннеля; перезагрузка роутера — только если HA_ALLOW_REBOOT=yes.

Настройки — /data/awg/ha.env (панель: «Настройки → Home Assistant»):
  MQTT_HOST, MQTT_PORT (1883), MQTT_USER, MQTT_PASS, MQTT_TLS (no|yes|insecure), HA_PREFIX (homeassistant),
  HA_INTERVAL (30 с), HA_ALLOW_REBOOT (no)

    ha.py           служба awg-ha: публикует состояние, принимает команды
    ha.py test      подключиться к брокеру, опубликовать discovery и состояние один раз, вывести итог
    ha.py remove    убрать устройство из HA (пустые retained-конфиги)
Брокер недоступен — служба переподключается с паузой и сторожу не мешает.
"""
import json
import os
import re
import socket
import ssl
import struct
import sys
import time

DD = os.environ.get("DD", "/data/awg")
sys.path.insert(0, os.path.join(DD, "web"))
import panel as P  # noqa: E402  (общие функции с веб-панелью)

CONF_F = os.path.join(DD, "ha.env")
LOGF = os.path.join(DD, "ha.log")
NODE = re.sub(r"[^a-z0-9_]", "_", ("udr_amnezia_" + socket.gethostname()).lower())[:60]
BASE = "udr_amnezia/" + NODE
AVAIL = BASE + "/status"
STATE = BASE + "/state"
SET_MODE = BASE + "/set/mode"
SET_RESTART = BASE + "/set/restart"
SET_REBOOT = BASE + "/set/reboot"
SET_ROUTE = BASE + "/set/route/"     # + ID маршрута (#40): auto или туннель


def log(msg):
    line = "%s %s\n" % (time.strftime("%F %T"), msg)
    try:
        with open(LOGF, "a", encoding="utf-8") as f:
            f.write(line)
        if os.path.getsize(LOGF) > 128 * 1024:
            P.write_secure(LOGF, "\n".join(P.read_file(LOGF).splitlines()[-800:]) + "\n", 0o600)
    except OSError:
        pass
    if os.environ.get("AWG_HA_STDERR"):
        sys.stderr.write(line)


def conf():
    c = P.parse_env_text(P.read_file(CONF_F))
    return {"host": c.get("MQTT_HOST", ""), "port": int(c.get("MQTT_PORT", "1883") or 1883), "user": c.get("MQTT_USER", ""),
            "pass": c.get("MQTT_PASS", ""), "tls": c.get("MQTT_TLS", "no"), "prefix": c.get("HA_PREFIX", "homeassistant") or "homeassistant",
            "interval": max(10, min(600, int(c.get("HA_INTERVAL", "30") or 30))), "reboot": c.get("HA_ALLOW_REBOOT", "no") == "yes"}


# ======================================================================= MQTT 3.1.1 (минимум: CONNECT, PUBLISH QoS 0, SUBSCRIBE, PING)
def _len(n):
    out = b""
    while True:
        d, n = n % 128, n // 128
        out += bytes([d | (0x80 if n else 0)])
        if not n:
            return out


def _str(s):
    b = s.encode("utf-8") if isinstance(s, str) else s
    return struct.pack("!H", len(b)) + b


class MQTT:
    def __init__(self, host, port, user="", pw="", tls="no", client_id=NODE, keepalive=60, timeout=10):
        self.host, self.port, self.user, self.pw, self.tls = host, port, user, pw, tls
        self.cid, self.keepalive, self.timeout = client_id, keepalive, timeout
        self.sock = None
        self.buf = b""
        self.last_tx = 0
        self.pid = 0

    def connect(self, will_topic=None, will_payload=b"", will_retain=True):
        s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        if self.tls in ("yes", "insecure"):
            ctx = ssl.create_default_context()
            if self.tls == "insecure":
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            s = ctx.wrap_socket(s, server_hostname=self.host)
        self.sock = s
        flags = 0x02  # clean session
        payload = _str(self.cid)
        if will_topic:
            flags |= 0x04 | (0x20 if will_retain else 0)
            payload += _str(will_topic) + _str(will_payload)
        if self.user:
            flags |= 0x80
            payload += _str(self.user)
            if self.pw:
                flags |= 0x40
                payload += _str(self.pw)
        var = _str("MQTT") + bytes([4, flags]) + struct.pack("!H", self.keepalive)
        self._send(0x10, var + payload)
        t, body = self.read_packet(self.timeout)
        if t != 0x20 or len(body) < 2:
            raise OSError("брокер не ответил CONNACK")
        if body[1] != 0:
            raise OSError({1: "версия протокола не поддерживается", 2: "client id отклонён", 3: "брокер недоступен",
                           4: "неверный логин или пароль", 5: "нет прав"}.get(body[1], "код %d" % body[1]))

    def _send(self, hdr, body):
        self.sock.sendall(bytes([hdr]) + _len(len(body)) + body)
        self.last_tx = time.time()

    def publish(self, topic, payload, retain=False):
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload, ensure_ascii=False)
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        self._send(0x30 | (1 if retain else 0), _str(topic) + payload)

    def subscribe(self, topics):
        self.pid = self.pid % 65535 + 1
        body = struct.pack("!H", self.pid) + b"".join(_str(t) + b"\x00" for t in topics)
        self._send(0x82, body)

    def ping(self):
        self._send(0xC0, b"")

    def disconnect(self):
        try:
            self._send(0xE0, b"")
            self.sock.close()
        except OSError:
            pass

    def read_packet(self, timeout):
        """→ (тип, тело) или (None, None) по таймауту."""
        self.sock.settimeout(timeout)
        while True:
            if len(self.buf) >= 2:
                mult, n, i = 1, 0, 1
                while i < len(self.buf):
                    b = self.buf[i]
                    n += (b & 0x7F) * mult
                    mult *= 128
                    i += 1
                    if not b & 0x80:
                        break
                else:
                    i = -1
                if i > 0 and len(self.buf) >= i + n:
                    t, body = self.buf[0] & 0xF0, self.buf[i:i + n]
                    self.buf = self.buf[i + n:]
                    return t, body
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                return None, None
            if not chunk:
                raise OSError("брокер закрыл соединение")
            self.buf += chunk


def parse_publish(body):
    n = struct.unpack("!H", body[:2])[0]
    return body[2:2 + n].decode("utf-8", "replace"), body[2 + n:].decode("utf-8", "replace")


# ======================================================================= Home Assistant
class Act:
    """Действия из HA пишутся в журнал панели от имени homeassistant."""
    user = "homeassistant"

    def act(self, a, d=""):
        P.audit(self.user, "mqtt", a, d)


def overview():
    """Состояние для HA: как в панели, плюс дополнительные маршруты."""
    ov = P.overview()
    try:
        ov["routes"] = P.routes_brief(extra_only=True)
    except Exception as ex:   # маршруты — не повод не публиковать остальное
        log("маршруты: %s" % ex)
        ov["routes"] = []
    return ov


def shape(ov):
    """Что определяет набор сущностей: туннели и маршруты с их цепочками."""
    return [t["name"] for t in ov["tunnels"]], [(r["id"], r["label"], tuple(r["tunnels"])) for r in ov.get("routes", [])]


def device(ov):
    return {"identifiers": [NODE], "name": "UDR-Amnezia (%s)" % ov["host"], "manufacturer": "UDR-Amnezia",
            "model": "AmneziaWG на UniFi Dream Router", "sw_version": ov.get("version", "")}


def discovery(ov, c):
    """→ [(topic, config)]: все сущности устройства."""
    dev = device(ov)
    out = []

    def ent(comp, oid, name, **kw):
        cfg = {"name": name, "unique_id": "%s_%s" % (NODE, oid), "object_id": "%s_%s" % (NODE, oid), "device": dev,
               "availability_topic": AVAIL, "state_topic": STATE}
        cfg.update(kw)
        out.append(("%s/%s/%s/%s/config" % (c["prefix"], comp, NODE, oid), cfg))

    ent("sensor", "active", "Активный канал", value_template="{{ value_json.active or 'нет' }}", icon="mdi:vpn")
    ent("sensor", "level", "Состояние", value_template="{{ value_json.level }}", icon="mdi:shield-check")
    ent("sensor", "alerts", "Замечаний", value_template="{{ value_json.alerts }}", icon="mdi:alert-circle-outline", state_class="measurement")
    ent("binary_sensor", "killswitch", "Kill switch", value_template="{{ 'ON' if value_json.killswitch else 'OFF' }}", icon="mdi:shield-lock")
    ent("sensor", "cpu", "Процессор", value_template="{{ value_json.cpu }}", unit_of_measurement="%", state_class="measurement", icon="mdi:cpu-64-bit")
    ent("sensor", "mem", "Память", value_template="{{ value_json.mem }}", unit_of_measurement="%", state_class="measurement", icon="mdi:memory")
    ent("sensor", "temp", "Температура", value_template="{{ value_json.temp }}", unit_of_measurement="°C", device_class="temperature", state_class="measurement")
    ent("sensor", "data_free", "Свободно в /data", value_template="{{ value_json.data_free_mb }}", unit_of_measurement="MB", device_class="data_size", state_class="measurement")
    names = [t["name"] for t in ov["tunnels"]]
    ent("select", "mode", "Канал", command_topic=SET_MODE, options=["auto"] + names, value_template="{{ value_json.mode }}", icon="mdi:swap-horizontal")
    for t in ov["tunnels"]:
        n, lab = t["name"], t["label"] or t["name"]
        v = "value_json.tunnels['%s']" % n
        ent("binary_sensor", n + "_up", lab + ": связь", value_template="{{ 'ON' if %s.up else 'OFF' }}" % v, device_class="connectivity")
        ent("sensor", n + "_hs", lab + ": handshake", value_template="{{ %s.handshake }}" % v, unit_of_measurement="s", device_class="duration", state_class="measurement")
        ent("sensor", n + "_rtt", lab + ": RTT", value_template="{{ %s.rtt }}" % v, unit_of_measurement="ms", state_class="measurement", icon="mdi:timer-outline")
        ent("sensor", n + "_loss", lab + ": потери", value_template="{{ %s.loss }}" % v, unit_of_measurement="%", state_class="measurement", icon="mdi:chart-bell-curve")
        ent("sensor", n + "_rx", lab + ": получено", value_template="{{ %s.rx }}" % v, unit_of_measurement="B", device_class="data_size", state_class="total_increasing")
        ent("sensor", n + "_tx", lab + ": отправлено", value_template="{{ %s.tx }}" % v, unit_of_measurement="B", device_class="data_size", state_class="total_increasing")
        out.append(("%s/button/%s/%s_restart/config" % (c["prefix"], NODE, n),
                    {"name": lab + ": перезапустить", "unique_id": "%s_%s_restart" % (NODE, n), "object_id": "%s_%s_restart" % (NODE, n),
                     "device": dev, "availability_topic": AVAIL, "command_topic": SET_RESTART, "payload_press": n, "icon": "mdi:restart"}))
    for r in ov.get("routes", []):
        rid, lab = r["id"], "Маршрут " + (r["label"] or r["id"])
        v = "value_json.routes['%s']" % rid
        ent("sensor", "route_%s_active" % rid, lab + ": канал", value_template="{{ %s.active or 'нет' }}" % v, icon="mdi:routes")
        ent("binary_sensor", "route_%s_up" % rid, lab + ": связь", value_template="{{ 'ON' if %s.up else 'OFF' }}" % v, device_class="connectivity")
        ent("select", "route_%s_mode" % rid, lab + ": выбор канала", command_topic=SET_ROUTE + rid, options=["auto"] + list(r["tunnels"]),
            value_template="{{ %s.mode }}" % v, icon="mdi:swap-horizontal")
    if c["reboot"]:
        out.append(("%s/button/%s/reboot/config" % (c["prefix"], NODE),
                    {"name": "Перезагрузить роутер", "unique_id": NODE + "_reboot", "object_id": NODE + "_reboot", "device": dev,
                     "availability_topic": AVAIL, "command_topic": SET_REBOOT, "payload_press": "reboot", "device_class": "restart"}))
    return out


def snapshot(ov):
    num = lambda x: float(x) if re.match(r"^-?\d+(\.\d+)?$", str(x)) else None  # noqa: E731
    return {
        "active": ov["active"], "mode": ov["forced"] or "auto", "level": ov["level"],
        "alerts": len([a for a in ov["alerts"] if a[0] != "info"]), "killswitch": ov["pbr"]["killswitch"],
        "cpu": round(ov["sys"]["cpu"] or 0, 1), "mem": ov["sys"]["mem_pct"], "temp": ov["sys"]["temp"], "data_free_mb": ov["data_free_mb"],
        "tunnels": {t["name"]: {"up": t["status"] in ("active", "standby"), "handshake": t["handshake"] if t["handshake"] >= 0 else None,
                                "rtt": num(t["rtt"]), "loss": num(t["loss"]), "rx": t["rx"], "tx": t["tx"]} for t in ov["tunnels"]},
        "routes": {r["id"]: {"active": r["active"], "mode": r["forced"] or "auto", "up": r["service"] == "active" and bool(r["active"])}
                   for r in ov.get("routes", [])},
    }


def handle(topic, payload, c):
    """Команда из HA → то же действие, что в панели. Возвращает текст для журнала."""
    a = Act()
    names = P.tunnels(P.env())
    if topic == SET_MODE:
        if payload == "auto":
            return P.api_tunnel_auto(a, {}).get("msg", "автоматический выбор")
        if payload in names:
            # как «Активировать» в панели, но без ожидания сторожа (до 30 с): новое состояние уйдёт следующей публикацией,
            # отказ сторожа (канал не отвечает) виден в HA по «Канал» = прежний/auto
            P.write_secure(P.FORCEF, payload + "\n", 0o644)
            a.act("switch", payload)
            return "ручной выбор %s передан сторожу" % payload
        return "неизвестный канал «%s»" % payload[:40]
    if topic.startswith(SET_ROUTE):
        rid = topic[len(SET_ROUTE):]
        r = P.api_route_switch(a, {"id": rid, "tunnel": payload})
        return r.get("msg", "маршрут %s: %s" % (rid, payload))
    if topic == SET_RESTART:
        if payload in names:
            r = P.api_tunnel_restart(a, {"name": payload})
            return r.get("msg", "перезапуск %s" % payload)
        return "неизвестный туннель «%s»" % payload[:40]
    if topic == SET_REBOOT:
        if not c["reboot"] or payload != "reboot":
            a.act("reboot-denied", "ha")
            return "перезагрузка из HA выключена (HA_ALLOW_REBOOT=no)"
        if P.update_running():
            return "идёт обновление: перезагрузка отклонена"
        rb = P.shutil.which("reboot") or "/sbin/reboot"
        rc, out = P.run(["systemd-run", "--unit=awg-reboot", "--collect", "--quiet", "--on-active=%d" % P.REBOOT_DELAY, rb], timeout=15)
        a.act("reboot", "из Home Assistant")
        return "перезагрузка через %d с" % P.REBOOT_DELAY if rc == 0 else "не удалось: " + out.strip()[:200]
    return ""


def publish_all(m, c, ov, with_config=True, old=None):
    """→ темы конфигов, если публиковались. old — прежние: исчезнувшие (убранный туннель или маршрут) удаляются из HA."""
    topics = None
    if with_config:
        d = discovery(ov, c)
        topics = {t for t, _ in d}
        for topic in sorted((old or set()) - topics):
            m.publish(topic, b"", retain=True)
        for topic, cfg in d:
            m.publish(topic, cfg, retain=True)
    m.publish(AVAIL, "online", retain=True)
    m.publish(STATE, snapshot(ov), retain=True)
    return topics


def run_once(c):
    m = MQTT(c["host"], c["port"], c["user"], c["pass"], c["tls"])
    m.connect(will_topic=AVAIL, will_payload=b"offline")
    ov = overview()
    publish_all(m, c, ov)
    m.disconnect()
    return len(discovery(ov, c))


def remove(c):
    m = MQTT(c["host"], c["port"], c["user"], c["pass"], c["tls"])
    m.connect()
    ov = overview()
    for topic, _ in discovery(ov, dict(c, reboot=True)):
        m.publish(topic, b"", retain=True)
    m.publish(STATE, b"", retain=True)
    m.publish(AVAIL, b"", retain=True)
    m.disconnect()


def serve():
    pause = 5
    while True:
        c = conf()
        if not c["host"]:
            log("MQTT_HOST не задан в %s: жду настройки" % CONF_F)
            time.sleep(60)
            continue
        try:
            m = MQTT(c["host"], c["port"], c["user"], c["pass"], c["tls"])
            m.connect(will_topic=AVAIL, will_payload=b"offline")
            m.subscribe([SET_MODE, SET_RESTART, SET_ROUTE + "+"] + ([SET_REBOOT] if c["reboot"] else []))
            names = None
            topics = None
            log("подключено к %s:%d" % (c["host"], c["port"]))
            pause = 5
            next_pub = 0
            while True:
                if time.time() >= next_pub:
                    ov = overview()
                    cur = shape(ov)
                    tp = publish_all(m, c, ov, with_config=cur != names, old=topics)   # туннели или маршруты поменялись — пересобрать
                    topics = tp if tp is not None else topics
                    names = cur
                    next_pub = time.time() + c["interval"]
                if time.time() - m.last_tx > 30:
                    m.ping()
                t, body = m.read_packet(1.0)
                if t == 0x30:
                    topic, payload = parse_publish(body)
                    try:
                        msg = handle(topic, payload.strip(), c)
                    except Exception as ex:  # ошибка команды не должна ронять службу
                        msg = "ошибка: %s" % ex
                    if msg:
                        log("HA %s %s → %s" % (topic.rsplit("/", 1)[-1], payload.strip()[:40], msg))
                    next_pub = 0    # сразу показать новое состояние
        except (OSError, ValueError, ssl.SSLError) as ex:
            log("брокер %s:%s: %s; повтор через %d с" % (c["host"], c["port"], ex, pause))
            time.sleep(pause)
            pause = min(300, pause * 2)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    c = conf()
    if cmd == "test":
        if not c["host"]:
            print("FAIL MQTT_HOST не задан (%s)" % CONF_F)
            return 1
        try:
            n = run_once(c)
        except (OSError, ValueError, ssl.SSLError) as ex:
            print("FAIL брокер %s:%d: %s" % (c["host"], c["port"], ex))
            return 1
        print("OK   опубликовано в %s:%d — сущностей: %d, устройство %s (префикс %s)" % (c["host"], c["port"], n, NODE, c["prefix"]))
        return 0
    if cmd == "remove":
        remove(c)
        print("OK   устройство убрано из Home Assistant")
        return 0
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
