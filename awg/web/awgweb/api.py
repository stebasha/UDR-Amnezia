# -*- coding: utf-8 -*-
"""API: обзор, туннели (переключение, добавление, удаление), маршрутизация, службы, инструменты, журналы."""
from .update import *  # noqa: F401,F403  (всё из предыдущих модулей)
from .data import _OV, _OV_LOCK  # noqa: F401

# ======================================================================= API
def api_logout(h, d):
    SESS.drop(tok=h.cookie("awgsid"))
    h.act("logout")
    return {"ok": True}


def api_health(h, q):
    r = dict(health_cached(5))
    r["history"] = SAMPLER.sys_history()
    return r


def api_overview(h, q):
    with _OV_LOCK:          # несколько вкладок не умножают нагрузку на роутер
        if _OV["v"] is None or time.time() - _OV["t"] > 2:
            _OV["v"] = overview()
            _OV["t"] = time.time()
        return _OV["v"]


def api_live(h, q):
    return {"live": SAMPLER.live_data(), "time": now()}


RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400}


def api_history(h, q):
    rg = (q.get("range") or ["24h"])[0]
    if rg not in RANGES:
        raise ValueError("период: 24h, 7d или 30d")
    if rg == "24h":
        return {"range": rg, "points": SAMPLER.history()}
    return {"range": rg, "hours": SAMPLER.hours(now() - RANGES[rg])}


def get_history_csv(h, rest, q):
    rg = (q.get("range") or ["24h"])[0]
    if rg not in RANGES:
        return h.send(400, {"error": "период: 24h, 7d или 30d"})
    rows = ["time,tunnel,active,rx_bps,tx_bps,rtt_ms,loss_pct,handshake_ok_pct"]
    if rg == "24h":
        for p in SAMPLER.history():
            for t, x in sorted(p.get("tun", {}).items()):
                hs = x.get("hs") if isinstance(x.get("hs"), int) else -1
                rows.append("%s,%s,%d,%d,%d,%s,%s,%d" % (time.strftime("%F %T", time.localtime(p["t"])), t, p.get("active") == t,
                                                          x.get("rx", 0), x.get("tx", 0), x.get("rtt", ""), x.get("loss", ""), 100 if 0 <= hs <= 180 else 0))
    else:
        for p in SAMPLER.hours(now() - RANGES[rg]):
            for t, x in sorted(p["tun"].items()):
                rows.append("%s,%s,%d,%d,%d,%s,%s,%s" % (time.strftime("%F %H:00", time.localtime(p["t"])), t, p.get("active") == t, x["rx"], x["tx"],
                                                          "" if x["rtt"] is None else x["rtt"], "" if x["loss"] is None else x["loss"], x["up"]))
    h.act("history-csv", rg)
    fn = "udr-amnezia-history-%s-%s.csv" % (rg, time.strftime("%Y%m%d-%H%M"))
    return h.send(200, "\n".join(rows) + "\n", "text/csv; charset=utf-8", {"Content-Disposition": 'attachment; filename="%s"' % fn})


def api_events(h, q):
    n = int((q.get("n") or ["300"])[0]) if (q.get("n") or ["x"])[0].isdigit() else 300
    return {"events": events(min(n, 3000))[::-1], "stats7": stats_from_events(7), "stats30": stats_from_events(30)}


def get_tunnel(name):
    if name not in tunnels():
        raise ApiError(404, "нет туннеля «%s»" % name)
    return name


def api_tunnel_switch(h, d):
    t = get_tunnel(str(d.get("name", "")))
    write_secure(FORCEF, t + "\n", 0o644)
    h.act("switch", t)
    for _ in range(60):          # круг сторожа с проверками качества бывает дольше 10 с
        time.sleep(0.5)
        if state().get("ACTIVE") == t:
            return {"ok": True, "msg": "активен %s (выбран вручную). Вернуть автоматику: «Авто»" % t}
        if not read_file(FORCEF).strip():
            return {"ok": False, "msg": "сторож отклонил переключение: канал %s не отвечает" % t}
    st = state().get("ACTIVE", "?")
    return {"ok": False, "msg": "не переключилось за 30 с (сейчас %s): канал %s не отвечает или сторож не запущен" % (st, t)}


def api_tunnel_auto(h, d):
    try:
        os.remove(FORCEF)
    except OSError:
        pass
    h.act("auto")
    return {"ok": True, "msg": "автоматический выбор канала включён"}


def api_tunnel_test(h, d):
    t = get_tunnel(str(d.get("name", "")))
    h.act("test", t)
    return tunnel_test(t)


def api_tunnel_restart(h, d):
    t = get_tunnel(str(d.get("name", "")))
    h.act("restart-tunnel", t)
    with LOCK:
        rc, out = run([os.path.join(DD, "up.sh"), t], timeout=60)
    return {"ok": rc == 0, "msg": out.strip()}


def api_tunnel_label(h, d):
    t = get_tunnel(str(d.get("name", "")))
    lab = str(d.get("label", "")).strip()[:40]
    if re.search(r"[<>\"'&\x00-\x1f]", lab):
        raise ValueError("недопустимые символы в названии")
    with LOCK:
        ls = labels()
        if lab:
            ls[t] = lab
        else:
            ls.pop(t, None)
        write_secure(LABELS_F, json.dumps(ls, ensure_ascii=False))
    h.act("label", {t: lab})
    return {"ok": True}


def api_tunnel_conf_get(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
    return {"name": t, "text": mask_conf(read_file(conf_path(t))), "path": conf_path(t)}


def tunnel_add(name, text, label=""):
    """Добавить дополнительный туннель: проверка конфига, ревизия, awg.env, подъём, перезапуск сторожа.
    Общая для API, мастера своего VPS (vps.sh setup → panel.py tunnel-add) и 3x-ui. → (код up.sh, вывод)."""
    name = str(name).strip()
    if not NAME_RE.match(name):
        raise ValueError("имя: awg и 1–10 строчных латинских букв или цифр, например awgalt1")
    e = env()
    if name in tunnels(e) or link_exists(name):
        raise ValueError("туннель %s уже есть" % name)
    lab = str(label or "").strip()[:40]
    if re.search(r"[<>\"'&\x00-\x1f]", lab):
        raise ValueError("недопустимые символы в названии")
    cp = os.path.join(DD, name + ".conf")
    with LOCK:
        text = str(text).replace("\r", "")
        errs = conf_validate(text)
        if errs:
            raise ValueError("конфиг не принят: " + "; ".join(errs))
        write_secure(cp, text)
        rev_save(name, text, "добавлен")
        extra = (e.get("TUNNELS_EXTRA", "") + " " + name).split()
        env_set({"TUNNELS_EXTRA": " ".join(extra)})
        if lab:
            ls = labels()
            ls[name] = lab
            write_secure(LABELS_F, json.dumps(ls, ensure_ascii=False))
        rc, out = run([os.path.join(DD, "up.sh"), name], timeout=60)
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
    return rc, out


def api_tunnel_add(h, d):
    rc, out = tunnel_add(d.get("name", ""), d.get("text", ""), d.get("label", ""))
    h.act("tunnel-add", str(d.get("name", "")).strip())
    return {"ok": rc == 0, "msg": out.strip()}


def routes_using(t):
    """Дополнительные маршруты (#22), в цепочке которых есть туннель t."""
    out = []
    try:
        names = sorted(os.listdir(os.path.join(DD, "route.d")))
    except OSError:
        names = []
    for f in names:
        if f.endswith(".env") and t in parse_env_text(read_file(os.path.join(DD, "route.d", f))).get("TUNNELS", "").split():
            out.append(f[:-4])
    return out


def tunnel_remove(t):
    """Убрать дополнительный туннель из сторожа вместе с правилами (конфиг остаётся). Общая для API и 3x-ui."""
    e = env()
    if t not in e.get("TUNNELS_EXTRA", "").split():
        raise ValueError("удалять из панели можно только дополнительные туннели; основной и запасной — через установщик")
    used = routes_using(t)
    if used:
        raise ValueError("туннель %s входит в маршрут %s: сначала уберите его оттуда («Маршруты»)" % (t, ", ".join(used)))
    with LOCK:
        env_set({"TUNNELS_EXTRA": " ".join(x for x in e.get("TUNNELS_EXTRA", "").split() if x != t)})
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
        run(["ip", "link", "del", t], timeout=10)
        run([os.path.join(DD, "failover.sh"), "forget", t], timeout=60)


def api_tunnel_remove(h, d):
    t = get_tunnel(str(d.get("name", "")))
    if t not in env().get("TUNNELS_EXTRA", "").split():
        raise ValueError("удалять из панели можно только дополнительные туннели; основной и запасной — через установщик")
    need_pw(h, d, "tunnel-remove")
    tunnel_remove(t)
    h.act("tunnel-remove", t)
    return {"ok": True, "msg": "%s убран вместе с его правилами; конфиг %s.conf оставлен" % (t, t)}


def api_settings_get(h, q):
    e = env()
    vals = {k: e.get(k, DEFAULTS.get(k, "")) for k in SETTINGS}
    return {"values": vals, "labels": {k: v[2] for k, v in SETTINGS.items()},
            "pbr": {k: e.get(k, "") for k in ("TABLE", "MARK", "PRIO", "RAIL_IF", "WANIF", "MAIN", "BACKUP", "TUNNELS_EXTRA", "VPS_IP")}}


def api_settings_set(h, d):
    vals = d.get("values") or {}
    if not isinstance(vals, dict) or not vals:
        raise ValueError("нет изменений")
    upd = {}
    errs = []
    for k, v in vals.items():
        if k not in SETTINGS:
            errs.append("%s: этот параметр из панели не меняется" % k)
            continue
        try:
            upd[k] = SETTINGS[k][0](v)
        except ValueError as ex:
            errs.append("%s: %s" % (SETTINGS[k][2], ex))
    if errs:
        raise ValueError("; ".join(errs))
    e = env()
    changed = {k: v for k, v in upd.items() if e.get(k, DEFAULTS.get(k, "")) != v}
    if not changed:
        return {"ok": True, "msg": "изменений нет"}
    with LOCK:
        env_set(changed)
        e = env()
        svcs = []
        for k in changed:
            for u in SETTINGS[k][1]:
                if u not in svcs:
                    svcs.append(u)
        msgs = apply_services(svcs, e)
    h.act("settings", changed)
    return {"ok": True, "msg": "сохранено: %s\n%s" % (", ".join(changed), "\n".join(msgs))}


def api_services(h, q):
    return {"services": {u: {"installed": svc_installed(u) or u == "awg-failover", "active": svc_active(u),
                             "enabled": u in units_list(), "info": SERVICE_INFO[u],
                             "available": os.path.exists(os.path.join(DD, u + ".service"))} for u in SERVICES}}


def api_service(h, d):
    u = str(d.get("name", ""))
    a = str(d.get("action", ""))
    if u not in SERVICES or a not in ("restart", "enable", "disable"):
        raise ValueError("недопустимая служба или действие")
    if u == "awg-failover" and a == "disable":
        raise ValueError("сторож из панели не выключается: без него PBR-трафик стоит. Если нужно — systemctl stop awg-failover")
    if a != "disable" and ((u == "awg-bot" and not os.path.exists(os.path.join(DD, "telegram.env")))
                           or (u == "awg-notify" and not notify_configured())):
        raise ValueError("сначала настройте Telegram, вебхук или ntfy (Настройки → Telegram)")
    if u == "awg-ha" and a != "disable" and not os.path.exists(HA_F):
        raise ValueError("сначала настройте брокер MQTT (Настройки → Home Assistant)")
    with LOCK:
        if a == "restart":
            rc, out = run(["systemctl", "restart", u], timeout=60)
        elif a == "enable":
            rc, out = unit_on(u)
        else:
            unit_off(u)
            if u == "awg-guard":    # как в установщике: иначе следующее сохранение настроек включит защиту обратно
                env_set({"LEAK_GUARD": "no"})
            rc, out = 0, ""
    h.act("service-" + a, u)
    return {"ok": rc == 0, "msg": "%s: %s %s" % (u, {"restart": "перезапущена", "enable": "включена", "disable": "выключена"}[a], out.strip()[:300])}


TOOLS = {
    "diagnose": (["diagnose.sh"], 300, "Диагностика"),
    "selftest": (["selftest.sh"], 300, "Самопроверка"),
    "selftest-full": (["selftest.sh", "--full"], 300, "Самопроверка с kill switch"),
    "audit": (["audit.sh"], 120, "Аудит"),
    "dedup": (["failover.sh", "dedup"], 120, "Очистка дубликатов"),
    "mtu": (["mtu.sh"], 300, "Подбор MTU"),
    "report": (["report.sh"], 300, "Отчёт"),
    "guard-check": (["guard.sh", "check"], 60, "Проверка защиты"),
    "self-check": (["self.sh", "check"], 120, "Проверка awg-self"),
    "subnets-check": (["subnets.sh", "check"], 60, "Проверка подсетей"),
    "self-reconnect": (["self.sh", "reconnect"], 60, "Переподключение трафика роутера"),
    "drift": (["drift.sh"], 120, "Сверка с эталоном"),
    "drift-repair": (["drift.sh", "repair"], 180, "Восстановление правил"),
    "drift-save": (["drift.sh", "save"], 60, "Новый эталон"),
}


def api_tool(h, d):
    k = str(d.get("tool", ""))
    if k == "switch-test":
        h.act("tool", k)
        return {"job": JOBS.start(k, switch_test_steps)}
    if k == "domain-check":
        dom = v_domains(str(d.get("domain", "")))
        if not dom or " " in dom:
            raise ValueError("укажите один домен")
        h.act("tool", {k: dom})
        return {"job": JOBS.start(k + dom, [os.path.join(DD, "domain-check.sh"), dom], 120)}
    if k == "speedtest":
        mb = int(d.get("mb", 10)) if str(d.get("mb", "10")).isdigit() else 10
        if mb not in (5, 10, 25, 50, 100):
            raise ValueError("объём: 5, 10, 25, 50 или 100 МБ")
        e = env()
        which = str(d.get("iface", "all"))
        lst = tunnels(e) + [wan_if(e) or "eth3"] if which == "all" else ([wan_if(e)] if which == "wan" else [get_tunnel(which)])
        lst = [i for i in lst if i and link_exists(i)]
        if not lst:
            raise ValueError("нет работающих интерфейсов для замера")
        h.act("tool", {k: lst})
        return {"job": JOBS.start(k, lambda: speed_steps(lst, mb), 600)}
    if k == "mtu-apply":
        t = get_tunnel(str(d.get("name", "")))
        h.act("tool", {k: t})
        return {"job": JOBS.start(k, [os.path.join(DD, "mtu.sh"), t, "--apply"], 300)}
    if k not in TOOLS:
        raise ValueError("нет такого инструмента")
    cmd, to, _ = TOOLS[k]
    if not os.path.exists(os.path.join(DD, cmd[0])):
        raise ValueError("скрипт %s не установлен: обновите набор (install.sh --update)" % cmd[0])
    h.act("tool", k)
    return {"job": JOBS.start(k, [os.path.join(DD, cmd[0])] + cmd[1:], to)}


def api_job(h, q):
    j = JOBS.get((q.get("id") or [""])[0])
    if not j:
        raise ApiError(404, "нет такой задачи")
    off = int((q.get("from") or ["0"])[0]) if (q.get("from") or ["x"])[0].isdigit() else 0
    return {"out": j["out"][off:], "len": len(j["out"]), "done": j["done"], "rc": j["rc"], "kind": j["kind"]}


LOGS = {"failover": "failover.log", "notify": "notify.log", "bot": "bot.log", "install": "install.log", "restore": "restore.log", "update": "update.log"}


def api_logs(h, q):
    k = (q.get("kind") or ["failover"])[0]
    n = min(int((q.get("n") or ["300"])[0]) if (q.get("n") or ["x"])[0].isdigit() else 300, 3000)
    if k == "journal":
        rc, out = run(["journalctl", "-u", "awg-*", "-n", str(n), "--no-pager", "-o", "short-iso"], timeout=20)
        return {"text": out}
    if k == "audit":
        return {"text": "\n".join(audit_text().splitlines()[-n:])}
    if k not in LOGS:
        raise ValueError("нет такого журнала")
    return {"text": "\n".join(read_file(os.path.join(DD, LOGS[k])).splitlines()[-n:])}
