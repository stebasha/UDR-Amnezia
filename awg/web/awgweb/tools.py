# -*- coding: utf-8 -*-
"""Ping и traceroute."""
from .backups import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= ping / traceroute
def api_net_tool(h, d):
    kind = str(d.get("kind", ""))
    host = str(d.get("host", "")).strip()
    iface = str(d.get("iface", ""))
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not DOMAIN_RE.match(host):
            raise ValueError("укажите IP-адрес или имя хоста")
    e = env()
    if iface not in tunnels(e) + ["wan"]:
        raise ValueError("интерфейс: туннель или wan")
    dev = wan_if(e) if iface == "wan" else iface
    if kind == "ping":
        mode = str(d.get("mode", "auto"))
        if mode not in ("auto", "icmp", "tcp"):
            raise ValueError("способ: auto, icmp или tcp")
        # auto: ICMP, а если ни одного ответа (его часто режут провайдер или сервер туннеля) — время TCP-подключения
        cmd = [os.path.join(DD, "awgctl.sh"), "ping", mode, dev, host]
    elif kind == "trace":
        tr = shutil.which("traceroute") or shutil.which("tracepath")
        if not tr:
            raise ValueError("на роутере нет traceroute")
        cmd = [tr, "-i", dev, "-n", "-w", "2", "-q", "1", "-m", "20", host] if tr.endswith("traceroute") else [tr, "-n", host]
    else:
        raise ValueError("ping или trace")
    h.act("net-" + kind, {"host": host, "iface": dev})
    return {"job": JOBS.start(kind + host + dev, cmd, 90)}
def get_log_file(h, rest, q):
    k = (q.get("kind") or [""])[0]
    if k == "journal":
        text = run(["journalctl", "-u", "awg-*", "-n", "20000", "--no-pager", "-o", "short-iso"], timeout=30)[1]
    elif k == "audit":
        text = audit_text()
    elif k == "events":
        text = "\n".join("%s  %-8s %s" % (time.strftime("%F %T", time.localtime(e["t"])), e["type"], e["text"]) for e in events(3000))
    elif k in LOGS:
        text = read_file(os.path.join(DD, LOGS[k]))
    else:
        return h.send(404, {"error": "нет такого журнала"})
    h.act("log-download", k)
    fn = "awg-%s-%s.log" % (k, time.strftime("%Y%m%d-%H%M%S"))
    return h.send(200, text, "text/plain; charset=utf-8", {"Content-Disposition": 'attachment; filename="%s"' % fn})
