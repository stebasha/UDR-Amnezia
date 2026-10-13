# -*- coding: utf-8 -*-
"""Сеансы, токены API, пользователи и 2FA."""
from .clients import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= сеансы
def sid(tok):
    return Sessions.key(tok)[:12]


def api_sessions(h, q):
    idle, mx = SESS.limits()
    return {"sessions": sorted(SESS.listing(h.cookie("awgsid")), key=lambda x: -x["seen"]), "idle": idle // 60, "max": mx // 3600}


def api_sessions_config(h, d):
    """Время жизни сеансов (#21): простой (минуты) и всего (часы). Без перезапуска панели."""
    idle, mx = str(d.get("idle", "")).strip(), str(d.get("max", "")).strip()
    if not idle.isdigit() or not 5 <= int(idle) <= 1440:
        raise ValueError("без активности: 5–1440 минут")
    if not mx.isdigit() or not 1 <= int(mx) <= 720:
        raise ValueError("всего: 1–720 часов")
    if int(mx) * 60 < int(idle):
        raise ValueError("общее время не может быть меньше времени без активности")
    need_pw(h, d, "sessions-config")
    with LOCK:
        lines = [x for x in read_file(CONF_F).splitlines() if not re.match(r"^\s*WEB_SESSION_(IDLE|MAX)=", x)]
        write_secure(CONF_F, "\n".join(lines + [fmt_env("WEB_SESSION_IDLE", idle), fmt_env("WEB_SESSION_MAX", mx)]) + "\n")
    SESS._lim = (0, None)
    h.act("sessions-config", {"idle": idle, "max": mx})
    return {"ok": True, "msg": "сеансы: без активности %s мин, всего %s ч" % (idle, mx)}


def api_session_revoke(h, d):
    x = str(d.get("id", ""))
    if x != "others" and not re.match(r"^[0-9a-f]{12}$", x):
        raise ValueError("нет такого сеанса")
    SESS.drop(sid_=x, keep=h.cookie("awgsid"))
    h.act("session-revoke", x)
    return {"ok": True}


def api_tokens(h, q):
    return {"tokens": sorted(TOKENS.listing(), key=lambda x: -x["created"])}


def api_token_create(h, d):
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        h.act("token-create-denied")
        raise ApiError(403, "текущий пароль неверен")
    name = str(d.get("name", "")).strip()
    if not re.match(r"^[\w .:-]{1,40}$", name):
        raise ValueError("название: 1–40 символов (буквы, цифры, пробел, . : - _)")
    role = str(d.get("role", ""))
    if role not in ("read", "admin"):
        raise ValueError("роль: read или admin")
    days = d.get("days", 0)
    if not isinstance(days, int) or not 0 <= days <= 3650:
        raise ValueError("срок: 0 (бессрочно) – 3650 дней")
    tid, tok = TOKENS.create(name, role, days, h.user)
    h.act("token-create", {"id": tid, "name": name, "role": role, "days": days})
    return {"id": tid, "token": tok, "msg": "токен создан: скопируйте его сейчас, повторно он не показывается"}


def api_token_revoke(h, d):
    tid = str(d.get("id", ""))
    if not re.match(r"^[0-9a-f]{12}$", tid):
        raise ValueError("нет такого токена")
    TOKENS.revoke(tid)
    h.act("token-revoke", tid)
    return {"ok": True}
