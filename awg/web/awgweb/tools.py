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


def xui_map_safe():
    """Туннели, связанные с 3x-ui (#37), — из xui.json без запросов к панели (модуль xui грузится позже)."""
    try:
        d = json.loads(read_file(os.path.join(DD, "xui.json")) or "{}")
        t = d.get("tunnels") if isinstance(d, dict) else None
        return t if isinstance(t, dict) else {}
    except ValueError:
        return {}


def api_tune_get(h, q):
    head, rows, best = tune_results()
    act = active_tunnels()
    vt = set()
    for line in run([os.path.join(DD, "vps.sh"), "list"], timeout=10)[1].splitlines():
        vid = line.split("\t")[0]
        if VPS_ID_RE.match(vid):
            vt |= set(x for x in vps_sh(["tunnels"], 10, vid)[1].split() if NAME_RE.match(x))
    xm = xui_map_safe()
    tl = [{"name": t, "active": t in act, "server": t in vt, "xui": t in xm} for t in tunnels(env()) if not is_xray(t)]
    return {"running": tune_running(), "log": read_file(TUNE_LOG)[-20000:], "head": head, "rows": rows, "best": best,
            "tunnels": tl, "auto": env().get("AUTO_TUNE") == "yes", "bot": svc_active("awg-bot")}


def api_tune_run(h, d):
    """Подбор — отдельной службой (минуты), с паролем: туннель на время подбора меняет параметры."""
    need_pw(h, d, "tune-run")
    t = str(d.get("tunnel", ""))
    if t not in tunnels(env()):
        raise ValueError("выберите туннель")
    wg_only(t)
    mode = str(d.get("mode", "client"))
    if mode not in ("client", "server", "xui"):
        raise ValueError("режим: client, server или xui")
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
    try:
        n = int(d.get("n"))
    except (TypeError, ValueError):
        raise ValueError("номер набора")
    return tune_apply(h, n)


def tune_apply(h, n):
    """То же без пароля — для кнопки бота (#36): администратор Telegram подтверждает сам."""
    head, rows, best = tune_results()
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
    where = "в 3x-ui и на роутере" if head["mode"] == "xui" else "на VPS и роутере"
    return {"ok": True, "msg": "ставлю набор %d %s — смотрите журнал" % (n, where), "job": True}


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


# ======================================================================= отчёт за неделю / месяц (#41)
def hours_since(since):
    """Часовые сводки: из сборщика панели, а вне панели (бот) — из сохранённой истории."""
    if SAMPLER.is_alive():
        return SAMPLER.hours(since)
    try:
        h = json.loads(read_file(HIST_F, "{}")).get("hours") or []
    except ValueError:
        h = []
    return [x for x in h if isinstance(x, dict) and x.get("t", 0) >= since]


def _wavg(pairs):
    pairs = [(v, w) for v, w in pairs if v is not None and w]
    s = sum(w for _, w in pairs)
    return round(sum(v * w for v, w in pairs) / s, 1) if s else None


def report_data(days=7):
    days = 30 if int(days) >= 30 else 7
    since = now() - days * 86400
    hrs = hours_since(since)
    e = env()
    lb = labels()
    tl = tunnels(e)
    names = sorted(set(tl) | {t for h in hrs for t in h.get("tun", {})}, key=lambda x: (x not in tl, tl.index(x) if x in tl else 0, x))
    tun = []
    for t in names:
        xs = [(h["tun"][t], h.get("n", 60)) for h in hrs if t in h.get("tun", {})]
        if not xs:
            continue
        act = sum((h.get("am") or {}).get(t, 0) if "am" in h else (h.get("n", 60) if h.get("active") == t else 0) for h in hrs)
        tun.append({"name": t, "label": lb.get(t, ""), "minutes": sum(n for _, n in xs), "avail": _wavg([(x.get("up"), n) for x, n in xs]),
                    "rtt": _wavg([(x.get("rtt"), n) for x, n in xs]), "loss": _wavg([(x.get("loss"), n) for x, n in xs]),
                    "bytes": int(sum((x.get("rx", 0) + x.get("tx", 0)) / 8.0 * 60 * n for x, n in xs)), "active_min": act})
    sp = {}
    for r in speed_hist():
        if r.get("t", 0) >= since and r.get("down_bps"):
            a = sp.setdefault(r["iface"], {"iface": r["iface"], "n": 0, "down": 0, "up": 0, "ping": []})
            a["n"] += 1
            a["down"] += r["down_bps"]
            a["up"] += r.get("up_bps", 0)
            if r.get("ping_ms"):
                a["ping"].append(r["ping_ms"])
    speed = [{"iface": a["iface"], "n": a["n"], "down_bps": a["down"] // a["n"], "up_bps": a["up"] // a["n"],
              "ping_ms": int(sum(a["ping"]) / len(a["ping"])) if a["ping"] else None} for a in sp.values()]
    routes = []
    for rid in sorted(route_states()):
        rf = parse_env_text(read_file(os.path.join(DD, "route.d", rid + ".env")))
        chain = rf.get("TUNNELS", "").split()
        mins = collections.Counter()
        for h in hrs:
            mins.update((h.get("ra") or {}).get(rid, {}))
        tot = sum(mins.values())
        st = stats_from_events(days, rid)
        routes.append({"id": rid, "label": rf.get("LABEL", ""), "chain": chain, "minutes": tot,
                       "on": [{"tunnel": t or "", "minutes": m} for t, m in mins.most_common()],
                       "first_pct": round(100.0 * mins.get(chain[0], 0) / tot, 1) if tot and chain else None,
                       "switch": st["switch"] + st["degrade"], "both": st["both"]})
    tr = traffic_load()
    d0 = time.strftime("%Y-%m-%d", time.localtime(since))
    dev = collections.defaultdict(lambda: [0, 0])
    for day, v in (tr.get("days") or {}).items():
        if day >= d0:
            for k, (dn, up) in v.items():
                dev[k][0] += dn
                dev[k][1] += up
    nm = tr.get("names") or {}
    devices = sorted(({"key": k, "name": (nm.get(k) or {}).get("name", ""), "ip": (nm.get(k) or {}).get("ip", k), "mac": (nm.get(k) or {}).get("mac", ""),
                       "down": v[0], "up": v[1]} for k, v in dev.items()), key=lambda x: -(x["down"] + x["up"]))[:25]
    return {"days": days, "since": since, "hours": len(hrs), "coverage": round(100.0 * len(hrs) / (days * 24), 1),
            "main": stats_from_events(days), "main_name": e.get("MAIN", "awgmain"), "tunnels": tun, "speed": speed, "routes": routes,
            "acct": e.get("TRAFFIC_ACCT") == "yes", "devices": devices}


def fmt_dur(sec):
    sec = int(sec or 0)
    d, h, m = sec // 86400, sec % 86400 // 3600, sec % 3600 // 60
    if d:
        return "%d д %d ч" % (d, h)
    if h:
        return "%d ч %d мин" % (h, m)
    return "%d мин" % m


def fmt_bytes(b):
    b = float(b or 0)
    for u, k in (("ТБ", 1e12), ("ГБ", 1e9), ("МБ", 1e6), ("КБ", 1e3)):
        if b >= k:
            return "%.1f %s" % (b / k, u)
    return "%d Б" % b


def report_text(r):
    """Отчёт текстом (Telegram, CLI): без HTML, его экранирует отправитель."""
    per = "неделю" if r["days"] == 7 else "30 дней"
    m = r["main"]
    out = ["Отчёт за %s · данных %s%%" % (per, r["coverage"]),
           "Основной канал %s: %s%% времени, вне его %s; переключений %d, возвратов %d%s" % (
               r["main_name"], m["on_main_pct"], fmt_dur(m["off_main_sec"]), m["switch"] + m["degrade"], m["return"],
               ", отказ всех каналов: %d" % m["both"] if m["both"] else "")]
    if r["tunnels"]:
        out.append("")
        out.append("Каналы (доступность · RTT · потери · трафик · активен):")
        for t in r["tunnels"]:
            out.append("  %s%s: %s · %s · %s · %s · %s" % (
                t["name"], " (%s)" % t["label"] if t["label"] else "", "%s%%" % t["avail"] if t["avail"] is not None else "—",
                "%s мс" % t["rtt"] if t["rtt"] is not None else "—", "%s%%" % t["loss"] if t["loss"] is not None else "—",
                fmt_bytes(t["bytes"]), fmt_dur(t["active_min"] * 60)))
    if r["speed"]:
        out.append("")
        out.append("Скорость (средняя по замерам):")
        for s_ in r["speed"]:
            out.append("  %s: ↓ %s · ↑ %s%s (замеров %d)" % (s_["iface"], fmt_bps(s_["down_bps"]), fmt_bps(s_["up_bps"]),
                                                          " · %d мс" % s_["ping_ms"] if s_["ping_ms"] else "", s_["n"]))
    for rt in r["routes"]:
        out.append("")
        out.append("Маршрут %s%s: на первом канале %s; переключений %d" % (
            rt["id"], " (%s)" % rt["label"] if rt["label"] else "", "%s%%" % rt["first_pct"] if rt["first_pct"] is not None else "—", rt["switch"]))
        out += ["  %s: %s" % (x["tunnel"] or "без канала", fmt_dur(x["minutes"] * 60)) for x in rt["on"][:4]]
    if r["acct"]:
        out.append("")
        out.append("Трафик через туннели по устройствам (↓ · ↑):")
        out += ["  %s: %s · %s" % (d["name"] or d["ip"], fmt_bytes(d["down"]), fmt_bytes(d["up"])) for d in r["devices"][:10]] or ["  пока нет данных"]
    return "\n".join(out)


def api_report(h, q):
    d = (q.get("days") or ["7"])[0]
    return report_data(30 if d == "30" else 7)


# ======================================================================= автоподбор при деградации (#36, по желанию)
AUTOTUNE_F = os.path.join(DD, "autotune.json")


def ev_add(kind, text):
    try:
        with open(os.path.join(DD, "events.log"), "a", encoding="utf-8") as f:
            f.write("%d|%s|%s\n" % (now(), kind, text))
    except OSError:
        pass


def autotune_state():
    try:
        st = json.loads(read_file(AUTOTUNE_F, "{}"))
    except ValueError:
        st = {}
    return st if isinstance(st, dict) else {}


def autotune_tick():
    """Раз в минуту (бот): неактивный туннель без handshake или с потерями выше порога дольше AUTO_TUNE_AFTER →
    подбор «только роутер» на нём (не чаще AUTO_TUNE_EVERY на туннель). По окончании — предложение лучшего набора.
    → список сообщений для Telegram: {"kind": "start"|"offer"|"none", ...}."""
    e = env()
    if e.get("AUTO_TUNE") != "yes":
        return []
    after = int(e.get("AUTO_TUNE_AFTER", "900") or 900)
    every = int(e.get("AUTO_TUNE_EVERY", "86400") or 86400)
    lim = int(e.get("QUALITY_LOSS", "40") or 40)
    st = autotune_state()
    bad, last = st.get("bad") or {}, st.get("last") or {}
    out = []
    t0 = now()
    run_ = st.get("run")
    if run_:
        if tune_running():
            return []
        head, rows, best = tune_results()
        st["run"] = None
        if head.get("tunnel") == run_["tunnel"] and head.get("ts", 0) >= run_["ts"] - 60:
            base = next((r for r in rows if r["n"] == 0), None)
            b = next((r for r in rows if r["n"] == best), None) if best is not None else None
            if b and b["n"] != 0:
                st["offer"] = {"tunnel": run_["tunnel"], "n": b["n"], "ts": t0}
                out.append({"kind": "offer", "tunnel": run_["tunnel"], "n": b["n"], "params": b["params"], "score": b["score"],
                            "base_ok": bool(base and base["ok"]), "base_score": base["score"] if base else 0,
                            "loss": b["loss"], "rtt": b["rtt"], "mbps": b["mbps"]})
            else:
                out.append({"kind": "none", "tunnel": run_["tunnel"], "base_ok": bool(base and base["ok"])})
            ev_add("tune", "автоподбор %s: %s" % (run_["tunnel"], "лучший набор №%d — ждёт «Применить»" % b["n"] if b and b["n"] else "лучше текущего нет"))
        write_secure(AUTOTUNE_F, json.dumps(st), 0o600)
        return out
    act = active_tunnels()
    for t in tunnels(e):
        if t in act or not link_exists(t):
            bad.pop(t, None)
            continue
        hs = hs_age(t)
        lv = state().get("LOSS_" + t, "")
        loss = float(lv) if re.match(r"^[0-9]+(\.[0-9]+)?$", lv) else None
        if hs < 0 or hs > 180 or (loss is not None and loss >= lim):
            bad.setdefault(t, t0)
        else:
            bad.pop(t, None)
    for t, since in sorted(bad.items(), key=lambda x: x[1]):
        if t0 - since >= after and t0 - last.get(t, 0) >= every and not tune_running() and not vps_job_running():
            hs = hs_age(t)
            why = "нет handshake %s" % ("никогда" if hs < 0 else "%d мин" % (hs // 60)) if hs < 0 or hs > 180 else "потери выше %d%%" % lim
            write_secure(TUNE_LOG, "%s автоподбор %s: %s дольше %d мин\n" % (time.strftime("%F %T"), t, why, after // 60), 0o600)
            rc, o = run(["systemd-run", "--unit=awg-tune", "--collect", "--quiet", "--setenv=DD=" + DD, "--setenv=STATEF=" + STATEF,
                         "-p", "StandardOutput=append:" + TUNE_LOG, "-p", "StandardError=append:" + TUNE_LOG, "/bin/bash", "-c",
                         '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc', os.path.join(DD, "obfs-tune.sh"), "run", t, "client", "5"], timeout=20)
            last[t] = t0
            if rc == 0:
                st["run"] = {"tunnel": t, "ts": t0}
                ev_add("tune", "автоподбор %s: запущен (%s)" % (t, why))
                out.append({"kind": "start", "tunnel": t, "why": why})
            break
    st["bad"], st["last"] = bad, last
    write_secure(AUTOTUNE_F, json.dumps(st), 0o600)
    return out


def autotune_apply(h, t, n):
    """Кнопка «Применить» из сообщения бота: только тот набор, что предлагался, и только пока результаты те же."""
    st = autotune_state()
    o = st.get("offer") or {}
    head, rows, best = tune_results()
    if o.get("tunnel") != t or o.get("n") != n or head.get("tunnel") != t:
        raise ValueError("предложение устарело: после него был другой подбор. Откройте «Инструменты → Подбор параметров обфускации»")
    res = tune_apply(h, n)
    st["offer"] = None
    write_secure(AUTOTUNE_F, json.dumps(st), 0o600)
    return res
