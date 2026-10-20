# -*- coding: utf-8 -*-
"""API туннелей: поля, история, экспорт, порядок."""
from .settings import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= API: туннели (поля, история, экспорт, порядок)
def api_tunnel_fields_get(h, q):
    t = wg_only(get_tunnel((q.get("name") or [""])[0]))
    text = read_file(conf_path(t))
    f = conf_fields(text)
    return {"name": t, "fields": f["fields"], "other": f["other"], "peers": f["peers"], "proto": proto_of(text),
            "schema": [{"sec": s, "key": k, "req": r, "hint": hint, "secret": k.lower() in SECRET_FIELDS} for s, k, _, r, hint in CONF_FIELDS],
            "text": mask_conf(text), "path": conf_path(t), "revisions": len(rev_list(t))}


def preview_text(t, d):
    old = read_file(conf_path(t))
    if "fields" in d:
        new = conf_apply_fields(old, d.get("fields") or {})
    else:
        new = str(d.get("text", "")).replace("\r", "")
        new = unmask_conf(new, old) if MASK in new else new
    return old, new


def api_tunnel_preview(h, d):
    t = wg_only(get_tunnel(str(d.get("name", ""))))
    old, new = preview_text(t, d)
    return {"errors": conf_validate(new), "old": mask_conf(old), "new": mask_conf(new), "changed": old.strip() != new.strip()}


def api_tunnel_conf_set(h, d):
    t = wg_only(get_tunnel(str(d.get("name", ""))))
    old, new = preview_text(t, d)
    return apply_conf_text(h, t, new, "форма" if "fields" in d else "редактор")


def api_tunnel_revisions(h, q):
    t = wg_only(get_tunnel((q.get("name") or [""])[0]))
    cur = read_file(conf_path(t))
    lst = rev_list(t)
    seen = False
    for r in lst:   # новые сверху: «текущая» — только самая свежая совпадающая, остальные совпадения — «как текущая»
        same = read_file(os.path.join(rev_dir(t), r["id"])).strip() == cur.strip()
        r["current"] = same and not seen
        r["same"] = same and seen
        seen = seen or same
    return {"name": t, "revisions": lst}


def api_tunnel_revision(h, q):
    t = wg_only(get_tunnel((q.get("name") or [""])[0]))
    rid = (q.get("id") or [""])[0]
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return {"name": t, "id": rid, "text": mask_conf(read_file(os.path.join(rev_dir(t), rid))), "current": mask_conf(read_file(conf_path(t)))}


def api_tunnel_revision_restore(h, d):
    t = wg_only(get_tunnel(str(d.get("name", ""))))
    rid = str(d.get("id", ""))
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return apply_conf_text(h, t, read_file(os.path.join(rev_dir(t), rid)), "возврат версии " + rid[:15])


def api_tunnel_export(h, d):
    t = wg_only(get_tunnel(str(d.get("name", ""))))
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act("export-denied", t)
        raise ApiError(403, "текущий пароль неверен")
    h.act("conf-export", t)
    return {"name": t, "filename": t + ".conf", "text": read_file(conf_path(t))}


def api_tunnel_order(h, d):
    e = env()
    cur = e.get("TUNNELS_EXTRA", "").split()
    new = [str(x) for x in (d.get("extra") or [])]
    if sorted(new) != sorted(cur):
        raise ValueError("порядок должен содержать те же дополнительные туннели")
    with LOCK:
        env_set({"TUNNELS_EXTRA": " ".join(new)})
        if svc_active("awg-failover"):
            run(["systemctl", "restart", "awg-failover"], timeout=60)
    h.act("tunnel-order", new)
    return {"ok": True, "msg": "порядок сохранён, сторож перезапущен"}


# ======================================================================= маршруты (#22): разные туннели для разных профилей PBR
ROUTE_ID_RE = re.compile(r"^[a-z][a-z0-9]{0,11}$")


def routes_sh(args, timeout=90):
    return run([os.path.join(DD, "routes.sh")] + args, timeout=timeout,
               env={"STATEF": STATEF, "FORCEF": FORCEF, "SYSD": SYSD})


def api_routes_get(h, q):
    e = env()
    rails = []
    for line in routes_sh(["rails"], 15)[1].splitlines():
        p = line.split("\t")
        if len(p) == 5:
            rails.append({"prio": p[0], "mark": p[1], "table": p[2], "rail": p[3], "used": "" if p[4] == "-" else p[4]})
    return {"rails": rails, "routes": routes_brief(e), "tunnels": tunnels(e), "labels": labels(), "route_only": e.get("ROUTE_ONLY", "").split()}


def routes_brief(e=None, extra_only=False):
    """Маршруты и их состояние без профилей UniFi (без ip rule) — для бота, HA и обзора. extra_only — без основного."""
    e = e or env()
    routes = []
    if not extra_only:
        st = state()
        routes.append({"id": "main", "label": "", "rail": e.get("RAIL_IF", ""), "table": e.get("TABLE", ""),
                       "tunnels": st.get("TUNNELS", "").split() or tunnels(e), "active": st.get("ACTIVE", ""), "forced": st.get("FORCED", ""),
                       "service": "active" if svc_active("awg-failover") else "inactive", "only": False})
    if not any(f.endswith(".env") for f in (os.listdir(os.path.join(DD, "route.d")) if os.path.isdir(os.path.join(DD, "route.d")) else [])):
        return routes                       # маршрутов нет — routes.sh не запускаем
    for line in routes_sh(["list"], 15)[1].splitlines():
        p = line.split("\t")
        if len(p) == 8 and ROUTE_ID_RE.match(p[0]):
            rf = parse_env_text(read_file(os.path.join(DD, "route.d", p[0] + ".env")))
            routes.append({"id": p[0], "rail": p[1], "table": p[2], "tunnels": p[3].split(), "active": "" if p[4] == "-" else p[4],
                           "service": p[5], "forced": "" if p[6] == "-" else p[6], "label": p[7], "only": rf.get("ONLY") == "yes"})
    return routes


def api_route_save(h, d):
    """Новый маршрут (new) или новые туннели существующего — с паролем: меняется, куда идёт трафик устройств."""
    need_pw(h, d, "route-save")
    rid = str(d.get("id", "")).strip()
    if not ROUTE_ID_RE.match(rid) or rid == "main":
        raise ValueError("ID маршрута: латиница с буквы, до 12 знаков (например, us)")
    tl = [str(x) for x in (d.get("tunnels") or [])]
    if not tl or any(not NAME_RE.match(x) for x in tl):
        raise ValueError("выберите туннели маршрута по порядку")
    label = str(d.get("label", "")).strip()[:40]
    if re.search(r"[<>\"'`$\\&\x00-\x1f]", label):
        raise ValueError("недопустимые символы в названии")
    only = ["--only"] if d.get("only") else []
    if d.get("new"):
        rail = str(d.get("rail", "")).strip()
        if not re.match(r"^[a-z]+clt[0-9]+$", rail):
            raise ValueError("выберите профиль VPN Client UniFi")
        rc, out = routes_sh(["add", rid, rail, " ".join(tl), label] + only, 120)
    else:
        rc, out = routes_sh(["set", rid, " ".join(tl), label] + only, 120)
    if rc != 0:
        raise ValueError(out.strip().replace("ОШИБКА: ", "")[:400])
    h.act("route-save", {"id": rid, "tunnels": tl})
    return {"ok": True, "msg": out.strip()}


def api_route_remove(h, d):
    need_pw(h, d, "route-remove")
    rid = str(d.get("id", "")).strip()
    if not ROUTE_ID_RE.match(rid) or rid == "main":
        raise ValueError("основной маршрут не убирается")
    rc, out = routes_sh(["remove", rid], 120)
    if rc != 0:
        raise ValueError(out.strip().replace("ОШИБКА: ", "")[:400])
    h.act("route-remove", rid)
    return {"ok": True, "msg": out.strip()}


def api_route_switch(h, d):
    rid = str(d.get("id", "")).strip()
    t = str(d.get("tunnel", "")).strip()
    if not ROUTE_ID_RE.match(rid) or rid == "main" or not (t == "auto" or NAME_RE.match(t)):
        raise ValueError("маршрут и туннель")
    rc, out = routes_sh(["switch", rid, t], 15)
    if rc != 0:
        raise ValueError(out.strip().replace("ОШИБКА: ", "")[:300])
    h.act("route-switch", {"id": rid, "tunnel": t})
    return {"ok": True, "msg": out.strip()}
