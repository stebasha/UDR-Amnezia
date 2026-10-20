# -*- coding: utf-8 -*-
"""Сбор данных: состояние туннелей, обзор (с кешем), история и фоновые задачи."""
from .core import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= имена устройств (аренды DHCP, соседи)
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


# ======================================================================= учёт трафика по устройствам (#41, по желанию)
# Два набора ipset со счётчиками: адреса LAN, чей трафик ушёл в туннель (AWG_ACC_UP, по src) и пришёл из туннеля
# (AWG_ACC_DN, по dst). Правила в своей цепочке mangle FORWARD только считают, на трафик не влияют.
ACC_CH = "AWG_ACC"
ACC_SETS = ("AWG_ACC_UP", "AWG_ACC_DN")
TRAFFIC_F = os.path.join(WEBD, "traffic.json")
ACC_RULES = [["-o", "awg+", "-j", "SET", "--add-set", "AWG_ACC_UP", "src"], ["-o", "awg+", "-m", "set", "--match-set", "AWG_ACC_UP", "src"],
             ["-i", "awg+", "-j", "SET", "--add-set", "AWG_ACC_DN", "dst"], ["-i", "awg+", "-m", "set", "--match-set", "AWG_ACC_DN", "dst"]]


def ipt(*a):
    return run(["iptables", "-w", "5"] + list(a), timeout=15)


def acct_on():
    """Наборы и цепочка на месте, переход — первым в mangle FORWARD (UniFi при перепровижнинге может его убрать)."""
    for s_ in ACC_SETS:
        run(["ipset", "create", s_, "hash:ip", "family", "inet", "counters", "maxelem", "4096", "-exist"], timeout=10)
    if ipt("-t", "mangle", "-S", ACC_CH)[0] != 0:
        ipt("-t", "mangle", "-N", ACC_CH)
    have = ipt("-t", "mangle", "-S", ACC_CH)[1]
    if have.count("\n-A ") + have.startswith("-A ") != len(ACC_RULES) or "AWG_ACC_DN dst" not in have:
        ipt("-t", "mangle", "-F", ACC_CH)
        for r in ACC_RULES:
            ipt("-t", "mangle", "-A", ACC_CH, *r)
    fw = [x for x in ipt("-t", "mangle", "-S", "FORWARD")[1].splitlines() if x.startswith("-A ")]
    if not fw or fw[0] != "-A FORWARD -j " + ACC_CH or fw.count("-A FORWARD -j " + ACC_CH) != 1:
        while ipt("-t", "mangle", "-D", "FORWARD", "-j", ACC_CH)[0] == 0:
            pass
        ipt("-t", "mangle", "-I", "FORWARD", "1", "-j", ACC_CH)


def acct_off():
    while ipt("-t", "mangle", "-D", "FORWARD", "-j", ACC_CH)[0] == 0:
        pass
    ipt("-t", "mangle", "-F", ACC_CH)
    ipt("-t", "mangle", "-X", ACC_CH)
    for s_ in ACC_SETS:
        run(["ipset", "destroy", s_], timeout=10)


def acct_read(name):
    out = {}
    for line in run(["ipset", "list", name], timeout=15)[1].splitlines():
        m = re.match(r"^(\d+\.\d+\.\d+\.\d+) packets \d+ bytes (\d+)", line.strip())
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def traffic_load():
    try:
        d = json.loads(read_file(TRAFFIC_F, "{}"))
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def acct_collect(names=None):
    """Приращения счётчиков → сутки (до 62 дней): {"YYYY-MM-DD": {устройство: [из туннеля, в туннель]}}; устройство — MAC, иначе IP."""
    d = traffic_load()
    last = d.get("last") or {}
    days = d.get("days") or {}
    nm = d.get("names") or {}
    cur = {"dn": acct_read("AWG_ACC_DN"), "up": acct_read("AWG_ACC_UP")}
    day = time.strftime("%Y-%m-%d")
    names = names or {}
    for k, i in (("dn", 0), ("up", 1)):
        for ip, b in cur[k].items():
            prev = (last.get(k) or {}).get(ip, 0)
            delta = b - prev if b >= prev else b          # набор пересоздан (перезагрузка) — счётчик с нуля
            if delta <= 0:
                continue
            n = names.get(ip, {})
            key = n.get("mac") or ip
            nm[key] = {"ip": ip, "name": n.get("name") or (nm.get(key) or {}).get("name", ""), "mac": n.get("mac", "")}
            v = days.setdefault(day, {}).setdefault(key, [0, 0])
            v[i] += delta
    for old in sorted(days)[:-62]:
        del days[old]
    keep = {k for v in days.values() for k in v}
    d = {"last": cur, "days": days, "names": {k: v for k, v in nm.items() if k in keep}, "t": now()}
    write_secure(TRAFFIC_F, json.dumps(d, separators=(",", ":")), 0o600)
    return d


def route_states():
    """Активный канал каждого дополнительного маршрута (#22): {ID: туннель}."""
    out = {}
    try:
        ids = sorted(f[:-4] for f in os.listdir(os.path.join(DD, "route.d")) if f.endswith(".env"))
    except OSError:
        ids = []
    for rid in ids:
        out[rid] = parse_env_text(read_file(STATEF + "-" + rid)).get("ACTIVE", "")
    return out


# ======================================================================= сбор данных
class Sampler(threading.Thread):
    """Каждые 2 с: скорость по туннелям (10 минут в памяти); раз в минуту — точка истории (сутки);
    раз в час — сводка часа (30 дней, #10): средняя скорость, RTT и потери, доля минут со свежим handshake, процессор и память."""
    HOURS = 30 * 24

    def __init__(self):
        super().__init__(daemon=True)
        self.live = collections.defaultdict(lambda: collections.deque(maxlen=300))
        self.prev = {}
        self.hist = {"points": []}
        self.acc = collections.defaultdict(lambda: [0, 0, 0])
        self.lock = threading.Lock()
        self.last_save = now()
        self.cpu_prev = cpu_times()
        self.cpu = 0.0
        self.cpu_acc = [0.0, 0]
        try:
            h = json.loads(read_file(HIST_F, "{}"))
            if isinstance(h.get("points"), list):
                self.hist = h
        except ValueError:
            pass

    def run(self):
        last_min = now() // 60
        while True:
            try:
                self.tick()
                m = now() // 60
                if m != last_min:
                    last_min = m
                    self.minute()
                if now() - self.last_save > 3600:
                    self.save()
            except Exception as ex:  # сбор данных не должен ронять панель
                sys.stderr.write("sampler: %s\n" % ex)
            time.sleep(2)

    def tick(self):
        t0 = time.time()
        c = cpu_times()
        tot = c[0] - self.cpu_prev[0]
        if tot > 0:
            self.cpu = round(100.0 * (tot - (c[1] - self.cpu_prev[1])) / tot, 1)
            self.cpu_acc[0] += self.cpu
            self.cpu_acc[1] += 1
        self.cpu_prev = c
        for t in tunnels():
            rx, tx = sysnet(t, "rx_bytes"), sysnet(t, "tx_bytes")
            p = self.prev.get(t)
            self.prev[t] = (t0, rx, tx)
            if not p or rx < p[1] or tx < p[2]:
                continue
            dt = max(t0 - p[0], 0.5)
            r, w = (rx - p[1]) * 8 / dt, (tx - p[2]) * 8 / dt
            with self.lock:
                self.live[t].append((int(t0), int(r), int(w)))
                a = self.acc[t]
                a[0] += r
                a[1] += w
                a[2] += 1

    def minute(self):
        st = state()
        pt = {"t": now(), "active": st.get("ACTIVE", ""), "tun": {}, "routes": route_states()}
        hsm = hs_all()
        with self.lock:
            for t in tunnels():
                a = self.acc.pop(t, [0, 0, 0])
                n = a[2] or 1
                pt["tun"][t] = {"rx": int(a[0] / n), "tx": int(a[1] / n), "hs": hsm.get(t, -1),
                                "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, ""), "qm": st.get("QMETH_" + t, "")}
            self.hist["points"].append(pt)
            self.hist["points"] = self.hist["points"][-1440:]
            n = self.cpu_acc[1] or 1
            mi = parse_meminfo()
            ct_n = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_count"))
            ct_m = read_int(os.path.join(PROC, "sys/net/netfilter/nf_conntrack_max"))
            ts = temps()
            sp = {"t": now(), "cpu": round(self.cpu_acc[0] / n, 1), "mem": round(100.0 * mi["used_mb"] / mi["total_mb"], 1) if mi["total_mb"] else 0,
                  "temp": max([x["c"] for x in ts] or [0]) or None, "ct": round(100.0 * ct_n / ct_m, 1) if ct_m > 0 and ct_n >= 0 else None,
                  "load": float((read_file(os.path.join(PROC, "loadavg"), "0").split() or ["0"])[0]), "data_free": disk_free_mb()}
            self.cpu_acc = [0.0, 0]
            self.hist.setdefault("sys", []).append(sp)
            self.hist["sys"] = self.hist["sys"][-1440:]
            self.roll_hours()
        if now() // 60 % 10 == 0:            # учёт трафика по устройствам (#41) — раз в 10 минут, вне блокировки
            self.acct()

    def acct(self):
        try:
            on = env().get("TRAFFIC_ACCT") == "yes"
            exists = ipt("-t", "mangle", "-S", ACC_CH)[0] == 0
            if on:
                acct_on()
                acct_collect(leases())
            elif exists:
                acct_off()
        except Exception as ex:   # учёт не должен ронять сбор данных
            sys.stderr.write("acct: %s\n" % ex)

    def roll_hours(self):
        """Под self.lock: свести завершённые часы из минутных точек в hist["hours"] (без повторов)."""
        hours = self.hist.setdefault("hours", [])
        done = hours[-1]["t"] if hours else 0
        cur = now() // 3600 * 3600
        by = collections.OrderedDict()
        for p in self.hist["points"]:
            h = p["t"] // 3600 * 3600
            if done < h < cur:
                by.setdefault(h, {"p": [], "s": []})["p"].append(p)
        for sp in self.hist.get("sys", []):
            h = sp["t"] // 3600 * 3600
            if h in by:
                by[h]["s"].append(sp)
        for h, g in by.items():
            hours.append(hour_summary(h, g["p"], g["s"]))
        if by:
            self.hist["hours"] = hours[-self.HOURS:]
            self.last_save = 0          # сводку часа сохранить сразу

    def save(self):
        self.last_save = now()
        with self.lock:
            try:
                write_secure(HIST_F, json.dumps(self.hist, separators=(",", ":")))
            except OSError:
                pass

    def live_data(self):
        with self.lock:
            return {t: list(q) for t, q in self.live.items()}

    def history(self):
        with self.lock:
            return list(self.hist["points"])

    def sys_history(self):
        with self.lock:
            return list(self.hist.get("sys", []))

    def hours(self, since):
        with self.lock:
            return [h for h in self.hist.get("hours", []) if h["t"] >= since]


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _avg(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def hour_summary(h, pts, sps):
    """Сводка часа: по туннелю средние rx/tx (бит/с), RTT, потери, доля минут со свежим handshake (≤180 с); активный канал."""
    tun = {}
    names = sorted({t for p in pts for t in p.get("tun", {})})
    for t in names:
        xs = [p["tun"][t] for p in pts if t in p.get("tun", {})]
        tun[t] = {"rx": int(sum(x.get("rx", 0) for x in xs) / len(xs)), "tx": int(sum(x.get("tx", 0) for x in xs) / len(xs)),
                  "rtt": _avg([_num(x.get("rtt")) for x in xs]), "loss": _avg([_num(x.get("loss")) for x in xs]),
                  "up": round(100.0 * sum(1 for x in xs if 0 <= (x.get("hs") if isinstance(x.get("hs"), int) else -1) <= 180) / len(xs), 1)}
    am = collections.Counter(p.get("active", "") for p in pts)
    act = am.most_common(1)
    ra = {}
    for p in pts:                  # минуты маршрутов на каждом туннеле (#41)
        for rid, t in (p.get("routes") or {}).items():
            ra.setdefault(rid, collections.Counter())[t or ""] += 1
    return {"t": h, "n": len(pts), "active": act[0][0] if act else "", "tun": tun, "am": dict(am), "ra": {k: dict(v) for k, v in ra.items()},
            "sys": {"cpu": _avg([_num(x.get("cpu")) for x in sps]), "mem": _avg([_num(x.get("mem")) for x in sps]),
                    "temp": max([x["temp"] for x in sps if isinstance(x.get("temp"), (int, float))] or [0]) or None}}


SAMPLER = Sampler()


def events(n=200):
    out = []
    for line in read_file(os.path.join(DD, "events.log")).splitlines()[-n:]:
        p = line.split("|", 2)
        if len(p) == 3 and p[0].isdigit():
            out.append({"t": int(p[0]), "type": p[1], "text": p[2]})
    return out


def stats_from_events(days=7, route=None):
    """Статистика основного маршрута или дополнительного (route=ID): события маршрутов идут с приставкой «маршрут ID: »
    и в статистику основного не входят."""
    if route:
        pre = "маршрут %s: " % route
        ev = [dict(e, text=e["text"][len(pre):]) for e in events(3000) if e["text"].startswith(pre)]
        main = (parse_env_text(read_file(os.path.join(DD, "route.d", route + ".env"))).get("TUNNELS", "").split() or [""])[0]
    else:
        ev = [e for e in events(3000) if not e["text"].startswith("маршрут ")]
        main = env().get("MAIN", "awgmain")
    frm = now() - days * 86400
    cnt = collections.Counter(e["type"] for e in ev if e["t"] >= frm)
    off, on, st = 0, False, 0
    for e in ev:
        # «auto» канал не меняет (сторож остаётся на запасном до возврата); ручной выбор основного — это возврат
        to_main = e["type"] == "force" and e["text"].split()[-1:] == [main]
        if e["type"] in ("switch", "degrade", "force") and not to_main:
            if not on:
                on, st = True, e["t"]
        elif e["type"] in ("return", "start") or to_main:
            if on:
                off += max(0, e["t"] - max(st, frm)) if e["t"] > frm else 0
                on = False
    if on:
        off += now() - max(st, frm)
    return {"days": days, "switch": cnt["switch"], "degrade": cnt["degrade"], "force": cnt["force"],
            "return": cnt["return"], "both": cnt["both"], "start": cnt["start"],
            "off_main_sec": off, "on_main_pct": round(100 - off * 100.0 / (days * 86400), 2)}


def tunnel_info(t, e, st, active, hsm=None):
    xr = is_xray(t, e)
    cp = os.path.join(XD, t + ".json") if xr else conf_path(t, e)
    text = "" if xr else read_file(cp)
    hs = (hsm.get(t, -1) if hsm is not None else hs_age(t)) if link_exists(t) else -1
    ep = conf_get(text, "Endpoint")
    xinfo = {}
    if xr:                      # VLESS (#42): сервер и протокол — из открытой части записи туннеля (без UUID)
        try:
            xinfo = json.loads(read_file(os.path.join(XD, t + ".info")) or "{}")
        except ValueError:
            xinfo = {}
        ep = "%s:%s" % (xinfo.get("host", ""), xinfo.get("port", "")) if xinfo.get("host") else ""
    role = "main" if t == (e.get("MAIN") or "awgmain") else ("backup" if t == e.get("BACKUP") else "extra")
    up = link_exists(t)
    if not up:
        status = "down"
    elif hs < 0 or hs > 180:
        status = "nohs"
    elif t == active:
        status = "active"
    else:
        status = "standby"
    return {
        "name": t, "label": labels().get(t, ""), "role": role, "status": status, "exists": up,
        "handshake": hs, "endpoint": ep, "address": xinfo.get("addr", "") if xr else conf_get(text, "Address"),
        "mtu": read_file("%s/%s/mtu" % (SYSNET, t)).strip() or conf_get(text, "MTU"),
        "proto": ("VLESS" + (" · " + xinfo["security"].capitalize() if xinfo.get("security") not in (None, "", "none") else "")) if xr else proto_of(text),
        "kind": "vless" if xr else "awg", "server": xinfo.get("remark", "") if xr else "", "country": xinfo.get("country", "") if xr else "",
        "conf": os.path.basename(cp), "conf_mode": oct(os.stat(cp).st_mode & 0o777)[2:] if os.path.exists(cp) else "",
        "rx": sysnet(t, "rx_bytes"), "tx": sysnet(t, "tx_bytes"),
        "loss": st.get("LOSS_" + t, ""), "rtt": st.get("RTT_" + t, ""), "dns": st.get("DNS_" + t, ""), "qm": st.get("QMETH_" + t, ""),
        "active": t == active, "forced": st.get("FORCED", "") == t,
    }


def overview():
    e = env()
    st = state()
    table = e.get("TABLE", "")
    tb = pbr_table_routes(table)
    m = re.search(r"^default dev (awg\S+)", tb, re.M)
    active = m.group(1) if m else ""
    hsm = hs_all()
    tl = [tunnel_info(t, e, st, active, hsm) for t in tunnels(e)]
    sv = svc_states(SERVICES)
    fo = sv["awg-failover"]
    services = {u: {"installed": svc_installed(u) or u == "awg-failover", "active": sv[u], "info": SERVICE_INFO[u]}
                for u in SERVICES}
    wan = wan_if(e)
    alerts = []
    if not fo:
        alerts.append(["crit", "Сторож awg-failover не работает: маршрута в туннель нет"])
    if table and not active:
        alerts.append(["crit", "В таблице PBR %s нет маршрута на туннель: устройства под PBR без интернета (утечки нет)" % table])
    if active and active != tl[0]["name"]:
        alerts.append(["warn", "Работает запасной канал %s" % active])
    if st.get("FORCED"):
        alerts.append(["warn", "Канал выбран вручную: %s" % st["FORCED"]])
    for x in tl:
        if x["status"] in ("down", "nohs") and x["name"] != active:
            alerts.append(["warn", "Туннель %s: %s" % (x["name"], "интерфейса нет" if x["status"] == "down" else "нет handshake")])
    if os.path.exists(SIM_F):
        alerts.append(["warn", "Включена имитация падения основного канала"])
    if table and "blackhole" not in tb:
        alerts.append(["crit", "В таблице PBR нет blackhole: при падении туннелей трафик может уйти мимо"])
    for u, s in services.items():
        if s["installed"] and u != "awg-failover" and not s["active"]:
            alerts.append(["warn", "Служба %s установлена, но не работает" % u])
    upd = st.get("UPDATED", "")
    if fo and upd.isdigit() and now() - int(upd) > 60:
        alerts.append(["warn", "Состояние сторожа не обновлялось %d с" % (now() - int(upd))])
    bkd = os.path.join(DD, "backups")
    bk = [f for f in (os.listdir(bkd) if os.path.isdir(bkd) else []) if BK_RE.match(f)]
    newest = max([os.stat(os.path.join(bkd, f)).st_mtime for f in bk] or [0])
    if now() - newest > 30 * 86400:
        alerts.append(["info", "Резервной копии нет или ей больше 30 дней (Настройки → Резервные копии)"])
    hl = health_cached()
    for c in hl["checks"]:
        if c["level"] in ("warn", "crit"):
            alerts.append([c["level"], "Роутер: " + c["text"] + (" — " + c["advice"] if c["advice"] else "")])
    level = "crit" if any(a[0] == "crit" for a in alerts) else ("warn" if any(a[0] == "warn" for a in alerts) else "ok")
    try:
        up = int(float(read_file("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        up = 0
    load = read_file("/proc/loadavg").split()[:3]
    mem = parse_meminfo()
    return {
        "host": socket.gethostname(), "version": read_file(os.path.join(DD, "VERSION")).strip() or VERSION, "panel": VERSION,
        "time": now(), "uptime": up, "load": load, "mem": mem, "level": level, "alerts": alerts,
        "active": active, "forced": st.get("FORCED", ""), "tunnels": tl, "services": services,
        "pbr": {"table": table, "mark": e.get("MARK", ""), "rail": e.get("RAIL_IF", ""), "routes": tb.strip().splitlines(),
                "killswitch": "blackhole" in tb, "subnets": e.get("EXTRA_SUBNETS", "")},
        "wan": {"if": wan, "ip": if_ipv4(wan) if wan else ""},
        "stats": stats_from_events(7), "events": events(15)[::-1],
        "features": {"guard": e.get("LEAK_GUARD") == "yes", "self": e.get("UI_FIX") == "yes",
                     "domains": bool(e.get("TUN_DOMAINS", "").strip()), "subnets": bool(e.get("EXTRA_SUBNETS", "").strip()),
                     "quality": e.get("QUALITY", "yes") == "yes"},
        "data_free_mb": disk_free_mb(),
        "sys": {"cpu": SAMPLER.cpu, "cores": hl["cores"], "temp": hl["temp_max"], "mem_pct": hl["mem"]["used_pct"], "level": hl["level"],
                "conntrack": hl["conntrack"]},
    }


def parse_meminfo():
    mi = {}
    for line in read_file("/proc/meminfo").splitlines():
        p = line.split()
        if len(p) >= 2:
            mi[p[0].rstrip(":")] = int(p[1])
    tot = mi.get("MemTotal", 0)
    av = mi.get("MemAvailable", 0)
    return {"total_mb": tot // 1024, "used_mb": (tot - av) // 1024}


def disk_free_mb():
    try:
        s = os.statvfs(DD)
        return s.f_bavail * s.f_frsize // (1024 * 1024)
    except OSError:
        return -1


def curl(args, timeout=10):
    return run(["curl", "-s", "-4", "-m", str(timeout)] + args, timeout=timeout + 3)


def tunnel_test(t):
    res = {"name": t, "handshake": hs_age(t), "https": [], "dns": False, "ip": "", "mtu": ""}
    targets = env().get("TARGETS", "1.1.1.1 8.8.8.8 9.9.9.9").split()
    for tg in targets:
        t0 = time.time()
        rc, out = curl(["-k", "-o", "/dev/null", "--connect-timeout", "3", "-w", "%{http_code}", "--interface", t, "https://%s/" % tg], 5)
        res["https"].append({"target": tg, "ok": out.strip() not in ("", "000"), "ms": int((time.time() - t0) * 1000)})
    rc, out = curl(["--interface", t, "-H", "accept: application/dns-json", "https://1.1.1.1/dns-query?name=example.com&type=A"], 6)
    res["dns"] = '"Status":0' in out
    for u in ("https://api.ipify.org", "https://ifconfig.me"):
        rc, out = curl(["--interface", t, u], 6)
        if is_ipv4(out.strip()):
            res["ip"] = out.strip()
            break
    mtu = read_file("%s/%s/mtu" % (SYSNET, t)).strip()
    if mtu.isdigit() and not is_xray(t):     # Xray не пропускает ICMP: MTU так не проверить (#42)
        rc, out = run(["ping", "-I", t, "-M", "do", "-c", "2", "-W", "2", "-s", str(int(mtu) - 28), "1.1.1.1"], timeout=8)
        res["mtu"] = "ok" if rc == 0 else "fail"
    res["ok"] = any(x["ok"] for x in res["https"])
    return res


# ======================================================================= фоновые задачи
def kill_group(p):
    """Завершить команду вместе с её потомками (curl, ping): иначе они держат вывод открытым. TERM, затем KILL."""
    stop_group(p)


class Jobs:
    """Фоновые задачи панели. Одинаковая задача не запускается второй раз, пока идёт первая;
    всего одновременно — не больше MAX_RUNNING (проверки сайтов, ping, замеры нагружают роутер)."""
    MAX_RUNNING = 4

    def __init__(self):
        self.j = {}
        self.lock = threading.Lock()

    def start(self, kind, cmd, timeout=600, env_extra=None, after=None):
        with self.lock:
            for k, x in self.j.items():
                if x["kind"] == kind and not x["done"]:
                    return k
            if sum(not x["done"] for x in self.j.values()) >= self.MAX_RUNNING:
                raise ApiError(429, "уже выполняются %d задачи — дождитесь окончания" % self.MAX_RUNNING)
            jid = secrets.token_hex(6)
            self.j[jid] = {"kind": kind, "out": "", "done": False, "rc": None, "started": now()}
            if len(self.j) > 30:
                for k in sorted(self.j, key=lambda k: self.j[k]["started"])[:10]:
                    if self.j[k]["done"]:
                        del self.j[k]
        threading.Thread(target=self._run, args=(jid, cmd, timeout, env_extra, after), daemon=True).start()
        return jid

    def _run(self, jid, cmd, timeout, env_extra, after):
        x = self.j[jid]
        e = dict(os.environ)
        e.update({"NO_COLOR": "1", "LC_ALL": "C.UTF-8", "DD": DD})
        e.update(env_extra or {})
        try:
            if callable(cmd):
                for chunk in cmd():
                    x["out"] += chunk
                x["rc"] = 0
            else:
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, start_new_session=True)
                # срок — таймером: зависшая команда без вывода иначе держала бы задачу (и место в MAX_RUNNING) вечно
                late = []
                wd = threading.Timer(timeout, lambda: (late.append(1), kill_group(p)))
                wd.daemon = True
                wd.start()
                try:
                    for line in iter(p.stdout.readline, b""):
                        x["out"] += ANSI.sub("", line.decode("utf-8", "replace"))
                        if len(x["out"]) > 400000:
                            x["out"] = x["out"][-300000:]
                    x["rc"] = p.wait()
                finally:
                    wd.cancel()
                if late:
                    x["out"] += "\n[превышено время ожидания]\n"
            if after:
                x["out"] += after(x) or ""
        except Exception as ex:
            x["out"] += "\nошибка: %s\n" % ex
            x["rc"] = 1
        x["done"] = True

    def get(self, jid):
        return self.j.get(jid)


JOBS = Jobs()


def switch_test_steps():
    """Имитация падения основного канала и проверка, что сторож переключился (затем флаг снимается)."""
    e = env()
    main = e.get("MAIN") or "awgmain"
    if not e.get("BACKUP") and not e.get("TUNNELS_EXTRA"):
        yield "Запасного канала нет: переключаться некуда.\n"
        return
    open(SIM_F, "w").close()
    yield "Флаг имитации падения %s установлен (%s). Жду переключения до 45 с…\n" % (main, SIM_F)
    ok = False
    try:
        for i in range(45):
            time.sleep(1)
            a = state().get("ACTIVE", "")
            if a and a != main:
                yield "Переключение за ~%d с: активен %s.\n" % (i + 1, a)
                ok = True
                break
        if not ok:
            yield "Переключения не произошло: проверьте, что запасной канал отвечает (Туннели → Тест).\n"
    finally:
        try:
            os.remove(SIM_F)
        except OSError:
            pass
        yield "Флаг снят. Возврат на %s — после RECOVER_SEC=%s с стабильной работы (или «Авто» сразу после перезапуска сторожа).\n" % (
            main, e.get("RECOVER_SEC", "600"))


_HL = {"t": 0.0, "v": None}
_HL_LOCK = threading.Lock()


def health_cached(maxage=30):
    with _HL_LOCK:
        if _HL["v"] is None or time.time() - _HL["t"] > maxage:
            _HL["v"] = system_health(cpu=SAMPLER.cpu if SAMPLER.is_alive() else None, hist=SAMPLER.sys_history())
            _HL["t"] = time.time()
        return _HL["v"]


_OV = {"t": 0.0, "v": None}
_OV_LOCK = threading.Lock()
