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


# ======================================================================= автоподбор обфускации (#33)
TUNE_LOG = os.path.join(DD, "tune.log")
TUNE_RES = os.path.join(DD, "tune.tsv")


def tune_running():
    return run(["systemctl", "is-active", "--quiet", "awg-tune"], timeout=5)[0] == 0


def tune_results():
    head, rows = {}, []
    for line in read_file(TUNE_RES).splitlines():
        p = line.split("\t")
        if line.startswith("# ") and len(p) >= 3:
            head = {"tunnel": p[0][2:], "mode": p[1], "ts": int(p[2]) if p[2].isdigit() else 0, "vps": p[3] if len(p) > 3 else ""}
        elif len(p) == 8 and p[0].isdigit():
            try:
                rows.append({"n": int(p[0]), "ok": p[1] == "1", "hs": int(p[2]), "loss": int(p[3]), "rtt": int(p[4]),
                             "mbps": float(p[5]), "score": int(p[6]), "params": p[7]})
            except ValueError:
                continue
    best = max((r for r in rows if r["ok"]), key=lambda r: (r["score"], -r["n"]), default=None)
    return head, rows, best["n"] if best else None


def active_tunnels():
    """Активные каналы основного маршрута и дополнительных (#22)."""
    out = set()
    d = os.path.dirname(STATEF) or "."
    base = os.path.basename(STATEF)
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for f in names:
        if f == base or f.startswith(base + "-"):
            a = parse_env_text(read_file(os.path.join(d, f))).get("ACTIVE", "")
            if a:
                out.add(a)
    return out


def api_tune_get(h, q):
    head, rows, best = tune_results()
    act = active_tunnels()
    vt = set()
    for line in run([os.path.join(DD, "vps.sh"), "list"], timeout=10)[1].splitlines():
        vid = line.split("\t")[0]
        if VPS_ID_RE.match(vid):
            vt |= set(x for x in vps_sh(["tunnels"], 10, vid)[1].split() if NAME_RE.match(x))
    tl = [{"name": t, "active": t in act, "server": t in vt} for t in tunnels(env())]
    return {"running": tune_running(), "log": read_file(TUNE_LOG)[-20000:], "head": head, "rows": rows, "best": best,
            "tunnels": tl}


def api_tune_run(h, d):
    """Подбор — отдельной службой (минуты), с паролем: туннель на время подбора меняет параметры."""
    need_pw(h, d, "tune-run")
    t = str(d.get("tunnel", ""))
    if t not in tunnels(env()):
        raise ValueError("выберите туннель")
    mode = str(d.get("mode", "client"))
    if mode not in ("client", "server"):
        raise ValueError("режим: client или server")
    n = str(d.get("count", "5")).strip()
    if not n.isdigit() or not 1 <= int(n) <= 12:
        raise ValueError("наборов: 1–12")
    if tune_running() or vps_job_running():
        raise ValueError("уже идёт подбор или действие на VPS: дождитесь окончания")
    if t in active_tunnels() and not d.get("active"):
        raise ValueError("%s сейчас активный канал: подбор прервёт рабочий трафик — включите «разрешить на активном канале»" % t)
    args = ["run", t, mode, n] + (["--active"] if d.get("active") else [])
    write_secure(TUNE_LOG, "%s подбор обфускации %s (%s, наборов %s) — запущено из панели (%s)\n" % (time.strftime("%F %T"), t, mode, n, h.user), 0o600)
    rc, out = run(["systemd-run", "--unit=awg-tune", "--collect", "--quiet", "--setenv=DD=" + DD, "--setenv=STATEF=" + STATEF,
                   "-p", "StandardOutput=append:" + TUNE_LOG, "-p", "StandardError=append:" + TUNE_LOG, "/bin/bash", "-c",
                   '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc', os.path.join(DD, "obfs-tune.sh")] + args, timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    h.act("tune-run", {"tunnel": t, "mode": mode, "count": n})
    return {"ok": True, "msg": "подбор запущен"}


def api_tune_apply(h, d):
    """Поставить набор из последнего подбора: client — через историю конфигов (с откатом, если туннель не поднялся),
    server — согласованно на VPS и роутере (служба, с откатом обеих сторон)."""
    need_pw(h, d, "tune-apply")
    head, rows, best = tune_results()
    try:
        n = int(d.get("n"))
    except (TypeError, ValueError):
        raise ValueError("номер набора")
    r = next((x for x in rows if x["n"] == n), None)
    if not head or not r:
        raise ValueError("в последнем подборе нет такого набора")
    if not r["ok"]:
        raise ValueError("этот набор при подборе не заработал")
    if tune_running() or vps_job_running():
        raise ValueError("идёт подбор или действие на VPS: дождитесь окончания")
    t = head["tunnel"]
    if head["mode"] == "client":
        kv = dict(x.split("=", 1) for x in r["params"].split() if "=" in x)
        if set(kv) - {"Jc", "Jmin", "Jmax"} or not all(v.isdigit() for v in kv.values()):
            raise ValueError("неожиданный набор параметров")
        text = conf_apply_fields(read_file(conf_path(t)), {"Interface": kv})
        res = apply_conf_text(h, t, text, "автоподбор: набор %d" % n)
        h.act("tune-apply", {"tunnel": t, "n": n})
        return res
    write_secure(TUNE_LOG, "%s обфускация %s: ставлю набор %d (%s)\n" % (time.strftime("%F %T"), t, n, h.user), 0o600)
    rc, out = run(["systemd-run", "--unit=awg-tune", "--collect", "--quiet", "--setenv=DD=" + DD, "-p", "StandardOutput=append:" + TUNE_LOG,
                   "-p", "StandardError=append:" + TUNE_LOG, "/bin/bash", "-c", '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc',
                   os.path.join(DD, "obfs-tune.sh"), "apply", str(n)], timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    h.act("tune-apply", {"tunnel": t, "n": n})
    return {"ok": True, "msg": "ставлю набор %d на VPS и роутере — смотрите журнал" % n, "job": True}


# ======================================================================= списки и GeoIP (#38)
LISTS_LOG = os.path.join(DD, "lists.log")


def lists_running():
    return run(["systemctl", "is-active", "--quiet", "awg-lists"], timeout=5)[0] == 0


def api_lists_get(h, q):
    rc, out = run([os.path.join(DD, "lists.sh"), "json"], timeout=20)
    try:
        st = json.loads(out)
    except ValueError:
        st = {"mode": env().get("LISTS_MODE", "off"), "sets": {}, "due": False}
    return {"status": st, "running": lists_running(), "log": read_file(LISTS_LOG)[-8000:],
            "guard": svc_active("awg-guard")}


def api_lists_update(h, d):
    """Скачать списки сейчас (отдельной службой: источники могут отвечать долго). Прежние остаются при любой ошибке."""
    if env().get("LISTS_MODE", "off") == "off":
        raise ValueError("сначала выберите режим «только заблокированное» или «всё, кроме стран»")
    if lists_running():
        raise ValueError("обновление уже идёт")
    write_secure(LISTS_LOG, "%s обновление списков — запущено из панели (%s)\n" % (time.strftime("%F %T"), h.user), 0o600)
    rc, out = run(["systemd-run", "--unit=awg-lists", "--collect", "--quiet", "--setenv=DD=" + DD, "--setenv=STATEF=" + STATEF,
                   "-p", "StandardOutput=append:" + LISTS_LOG, "-p", "StandardError=append:" + LISTS_LOG, "/bin/bash", "-c",
                   '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc', os.path.join(DD, "lists.sh"), "update"], timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    h.act("lists-update", env().get("LISTS_MODE", ""))
    return {"ok": True, "msg": "обновление списков запущено"}
