# -*- coding: utf-8 -*-
"""Клиенты в туннеле (conntrack)."""
from .tunnels import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= клиенты в туннеле (conntrack)
LEASE_FILES = [os.environ.get("AWG_LEASES", "/run/dnsmasq.leases"), "/run/dnsmasq.leases", "/run/dnsmasq.dhcp.leases", "/var/run/dnsmasq.leases", "/tmp/dnsmasq.leases",
               "/data/udapi-config/dnsmasq.lease", "/var/lib/misc/dnsmasq.leases"]


def leases():
    names = {}
    files = list(LEASE_FILES)
    try:
        files += ["/run/" + f for f in os.listdir("/run") if f.startswith("dnsmasq") and f.endswith("leases")]
    except OSError:
        pass
    for f in files:
        for line in read_file(f).splitlines():
            p = line.split()
            if len(p) >= 4 and is_ipv4(p[2]):
                names[p[2]] = {"mac": p[1], "name": "" if p[3] == "*" else p[3]}
    out = run(["ip", "-4", "neigh", "show"], timeout=5)[1]
    for line in out.splitlines():
        p = line.split()
        if p and is_ipv4(p[0]) and "lladdr" in p:
            names.setdefault(p[0], {"mac": p[p.index("lladdr") + 1], "name": ""})
    return names


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
    for line in conntrack_lines()[:60000]:
        if "src=" not in line:
            continue
        kv = re.findall(r"(\w+)=(\S+)", line)
        srcs = [v for k, v in kv if k == "src"]
        dsts = [v for k, v in kv if k == "dst"]
        bts = [int(v) for k, v in kv if k == "bytes" and v.isdigit()]
        mark = next((v for k, v in kv if k == "mark"), "0")
        if len(srcs) < 2 or len(dsts) < 2:
            continue
        src, dst, rdst = srcs[0], dsts[0], dsts[1]
        try:
            ip = ipaddress.ip_address(src)
        except ValueError:
            continue
        if not ip.is_private or src in own:
            continue
        tun = taddr.get(rdst, "")
        try:
            mm = int(mark)
        except ValueError:
            mm = 0
        marked = mv is not None and mk and (mm & mk) == (mv & mk) and mv != 0
        if not tun and not marked:
            continue
        total += 1
        c = cl.setdefault(src, {"ip": src, "conns": 0, "bytes": 0, "tunnels": collections.Counter(), "dst": collections.Counter()})
        c["conns"] += 1
        c["bytes"] += sum(bts)
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
