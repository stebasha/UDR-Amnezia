# -*- coding: utf-8 -*-
"""Клиенты в туннеле (conntrack)."""
from .tunnels import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= клиенты в туннеле (conntrack)
def conntrack_lines():
    rc, out = run(["conntrack", "-L", "-f", "ipv4"], timeout=15)
    if rc == 0 and "src=" in out:
        return out.splitlines()
    return read_file("/proc/net/nf_conntrack").splitlines()


def parse_mark(m):
    try:
        if "/" in m:
            v, k = m.split("/", 1)
            return int(v, 0), int(k, 0)
        return int(m, 0), 0xFFFFFFFF
    except ValueError:
        return None, None


def clients():
    e = env()
    mv, mk = parse_mark(e.get("MARK", ""))
    taddr = {}
    for t in tunnels(e):
        a = if_ipv4(t)
        if a:
            taddr[a] = t
    own = set(taddr) | {lan_ip()}
    names = leases()
    cl = {}
    total = 0
    priv = {}
    for line in conntrack_lines()[:60000]:
        # разбор split, а не регулярным выражением: в 2–3 раза быстрее на десятках тысяч соединений
        srcs, dsts, bts, mark = [], [], 0, "0"
        for tok in line.split():
            if tok.startswith("src="):
                srcs.append(tok[4:])
            elif tok.startswith("dst="):
                dsts.append(tok[4:])
            elif tok.startswith("bytes="):
                b = tok[6:]
                if b.isdigit():
                    bts += int(b)
            elif tok.startswith("mark="):
                mark = tok[5:]
        if len(srcs) < 2 or len(dsts) < 2:
            continue
        src, dst, rdst = srcs[0], dsts[0], dsts[1]
        tun = taddr.get(rdst, "")
        if not tun:
            try:
                mm = int(mark)
            except ValueError:
                mm = 0
            if not (mv is not None and mk and mv != 0 and (mm & mk) == (mv & mk)):
                continue
        if src not in priv:
            try:
                priv[src] = ipaddress.ip_address(src).is_private and src not in own
            except ValueError:
                priv[src] = False
        if not priv[src]:
            continue
        total += 1
        c = cl.setdefault(src, {"ip": src, "conns": 0, "bytes": 0, "tunnels": collections.Counter(), "dst": collections.Counter()})
        c["conns"] += 1
        c["bytes"] += bts
        c["tunnels"][tun or "PBR"] += 1
        c["dst"][dst] += 1
    out = []
    for ip, c in cl.items():
        n = names.get(ip, {})
        out.append({"ip": ip, "name": n.get("name", ""), "mac": n.get("mac", ""), "conns": c["conns"], "bytes": c["bytes"],
                    "tunnel": c["tunnels"].most_common(1)[0][0], "top": [d for d, _ in c["dst"].most_common(3)]})
    out.sort(key=lambda x: (-x["conns"], x["ip"]))
    return {"clients": out, "total": total, "mark": e.get("MARK", "")}


_CL = {"t": 0.0, "v": None}
_CL_LOCK = threading.Lock()


def api_clients(h, q):
    with _CL_LOCK:
        if _CL["v"] is None or time.time() - _CL["t"] > 5:
            _CL["v"] = clients()
            _CL["t"] = time.time()
        return _CL["v"]
