# -*- coding: utf-8 -*-
"""Резервные копии: проверка; экспорт и импорт настроек."""
from .vps import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= резервные копии: проверка; экспорт настроек
def api_backup_verify(h, d):
    f = str(d.get("name", ""))
    if not BK_RE.match(f) or not os.path.exists(os.path.join(DD, "backups", f)):
        raise ApiError(404, "нет такой копии")
    pw = str(d.get("password", ""))
    if f.endswith(".enc") and not pw:
        raise ValueError("нужен пароль копии")
    h.act("backup-verify", f)
    rc, out = run([os.path.join(DD, "backup.sh"), "verify", os.path.join(DD, "backups", f)], timeout=120, env={"AWG_BACKUP_PASS": pw})
    return {"ok": rc == 0, "msg": out.strip()}


EXPORT_KEYS = list(SETTINGS)


def api_settings_export(h, q):
    e = env()
    h.act("settings-export")
    return {"format": "udr-amnezia-settings", "version": read_file(os.path.join(DD, "VERSION")).strip(), "time": now(),
            "settings": {k: e.get(k, DEFAULTS.get(k, "")) for k in EXPORT_KEYS}, "labels": labels(),
            "note": "без ключей, токенов и паролей; туннели переносятся отдельно (конфиги)"}


def api_settings_import(h, d):
    need_pw(h, d, "settings-import")
    x = d.get("data") or {}
    if not isinstance(x, dict) or x.get("format") != "udr-amnezia-settings":
        raise ValueError("это не файл настроек UDR-Amnezia")
    vals = {k: v for k, v in (x.get("settings") or {}).items() if k in SETTINGS}
    r = api_settings_set(h, {"values": vals}) if vals else {"ok": True, "msg": "настроек нет"}
    labs = x.get("labels") or {}
    if isinstance(labs, dict):
        for t, lab in labs.items():
            if t in tunnels():
                try:
                    api_tunnel_label(h, {"name": t, "label": lab})
                except ValueError:
                    pass
    return r
