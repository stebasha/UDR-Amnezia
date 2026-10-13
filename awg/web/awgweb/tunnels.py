# -*- coding: utf-8 -*-
"""API туннелей: поля, история, экспорт, порядок."""
from .settings import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= API: туннели (поля, история, экспорт, порядок)
def api_tunnel_fields_get(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
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
    t = get_tunnel(str(d.get("name", "")))
    old, new = preview_text(t, d)
    return {"errors": conf_validate(new), "old": mask_conf(old), "new": mask_conf(new), "changed": old.strip() != new.strip()}


def api_tunnel_conf_set(h, d):
    t = get_tunnel(str(d.get("name", "")))
    old, new = preview_text(t, d)
    return apply_conf_text(h, t, new, "форма" if "fields" in d else "редактор")


def api_tunnel_revisions(h, q):
    t = get_tunnel((q.get("name") or [""])[0])
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
    t = get_tunnel((q.get("name") or [""])[0])
    rid = (q.get("id") or [""])[0]
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return {"name": t, "id": rid, "text": mask_conf(read_file(os.path.join(rev_dir(t), rid))), "current": mask_conf(read_file(conf_path(t)))}


def api_tunnel_revision_restore(h, d):
    t = get_tunnel(str(d.get("name", "")))
    rid = str(d.get("id", ""))
    if not REV_RE.match(rid) or not os.path.exists(os.path.join(rev_dir(t), rid)):
        raise ApiError(404, "нет такой версии")
    return apply_conf_text(h, t, read_file(os.path.join(rev_dir(t), rid)), "возврат версии " + rid[:15])


def api_tunnel_export(h, d):
    t = get_tunnel(str(d.get("name", "")))
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
