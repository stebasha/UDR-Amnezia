# -*- coding: utf-8 -*-
"""Настройки: Home Assistant, Telegram, вебхук и ntfy, резервные копии, автокопия, система."""
from .importer import *  # noqa: F401,F403  (всё из предыдущих модулей)

HOST_OR_IP_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")


def api_ha_get(h, q):
    c = parse_env_text(read_file(HA_F))
    return {"host": c.get("MQTT_HOST", ""), "port": c.get("MQTT_PORT", "1883"), "user": c.get("MQTT_USER", ""),
            "pass_set": bool(c.get("MQTT_PASS")), "tls": c.get("MQTT_TLS", "no"), "prefix": c.get("HA_PREFIX", "homeassistant"),
            "interval": c.get("HA_INTERVAL", "30"), "allow_reboot": c.get("HA_ALLOW_REBOOT", "no") == "yes",
            "enabled": svc_installed("awg-ha"), "active": svc_active("awg-ha"),
            "log": "\n".join(read_file(os.path.join(DD, "ha.log")).splitlines()[-15:])}


def api_ha_set(h, d):
    old = parse_env_text(read_file(HA_F))
    host = str(d.get("host", "")).strip()
    if not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес брокера: имя или IP")
    port = str(d.get("port", "1883")).strip()
    if not re.match(r"^\d{1,5}$", port) or not 1 <= int(port) <= 65535:
        raise ValueError("порт: 1–65535")
    user = str(d.get("user", "")).strip()
    if not re.match(r"^[\w.@-]{0,64}$", user):
        raise ValueError("логин: буквы, цифры, . @ - _ (до 64)")
    pw = str(d.get("pass", ""))
    if pw == "":
        pw = old.get("MQTT_PASS", "")       # пусто — прежний пароль (в браузер он не передаётся)
    if len(pw) > 128 or re.search(r"[\x00-\x1f\"'`$\\]", pw):
        raise ValueError("пароль: до 128 символов, без кавычек, $, \\ и управляющих символов")
    tls = str(d.get("tls", "no"))
    if tls not in ("no", "yes", "insecure"):
        raise ValueError("TLS: no, yes или insecure")
    if str(d.get("pass", "")) == "" and pw:   # прежний пароль — только тому же брокеру и не открытым текстом вместо TLS
        sch = lambda t: "mqtts" if t != "no" else "mqtt"
        keep_secret("%s://%s:%s" % (sch(old.get("MQTT_TLS", "no")), old.get("MQTT_HOST", ""), old.get("MQTT_PORT", "1883")),
                    "%s://%s:%s" % (sch(tls), host, port), "пароль брокера MQTT")
    prefix = str(d.get("prefix", "homeassistant")).strip() or "homeassistant"
    if not re.match(r"^[a-z0-9_/-]{1,40}$", prefix):
        raise ValueError("префикс discovery: латиница, цифры, _ - /")
    interval = str(d.get("interval", "30")).strip()
    if not re.match(r"^\d{2,3}$", interval) or not 10 <= int(interval) <= 600:
        raise ValueError("период: 10–600 с")
    reboot = "yes" if d.get("allow_reboot") else "no"
    text = "".join('%s="%s"\n' % kv for kv in (("MQTT_HOST", host), ("MQTT_PORT", port), ("MQTT_USER", user), ("MQTT_PASS", pw),
                                               ("MQTT_TLS", tls), ("HA_PREFIX", prefix), ("HA_INTERVAL", interval), ("HA_ALLOW_REBOOT", reboot)))
    with LOCK:
        write_secure(HA_F, text, 0o600)
        if d.get("enabled", True):
            rc, out = unit_on("awg-ha") if not svc_installed("awg-ha") else run(["systemctl", "restart", "awg-ha"], timeout=30)
        else:
            unit_off("awg-ha")
            rc, out = 0, ""
    h.act("ha-set", {"host": host, "port": port, "tls": tls, "reboot": reboot, "enabled": bool(d.get("enabled", True))})
    return {"ok": rc == 0, "msg": "настройки Home Assistant сохранены" + ("" if rc == 0 else ": " + out.strip()[:200])}


def api_ha_test(h, d):
    h.act("ha-test")
    rc, out = run(["python3", os.path.join(DD, "ha.py"), "test"], timeout=40)
    return {"ok": rc == 0, "msg": out.strip()[-600:] or "нет ответа"}


def api_tg_get(h, q):
    t = parse_env_text(read_file(os.path.join(DD, "telegram.env")))
    tok = t.get("TG_TOKEN", "")
    return {"configured": bool(tok), "token": (tok.split(":")[0] + ":…" + tok[-4:]) if tok else "",
            "chat": " ".join(re.findall(r"-?\d+", t.get("TG_CHAT", ""))), "viewers": " ".join(re.findall(r"-?\d+", t.get("TG_VIEWERS", ""))),
            "muted": [l.split()[0] for l in read_file(os.path.join(DD, "bot.mute")).splitlines() if len(l.split()) == 2 and l.split()[1].isdigit() and int(l.split()[1]) > now()],
            "report_time": t.get("REPORT_TIME", "0900"), "no_wan": t.get("TG_NO_WAN", "0") == "1",
            "notify": svc_active("awg-notify"), "bot": svc_active("awg-bot")}


def api_tg_set(h, d):
    p = os.path.join(DD, "telegram.env")
    t = parse_env_text(read_file(p))
    tok = str(d.get("token", "")).strip()
    if tok:
        if not re.match(r"^\d{5,}:[A-Za-z0-9_-]{30,}$", tok):
            raise ValueError("это не похоже на токен бота вида 123456789:AA…")
        t["TG_TOKEN"] = tok
    if not t.get("TG_TOKEN"):
        raise ValueError("нужен токен бота")
    def chats(v, what, need):
        lst = []
        for x in re.split(r"[\s,;]+", str(v or "").strip()):
            if not x:
                continue
            if not re.match(r"^-?\d{1,20}$", x):
                raise ValueError("%s: «%s» — не chat id (число, у групп — с минусом)" % (what, x))
            if x not in lst:
                lst.append(x)
        if need and not lst:
            raise ValueError("нужен хотя бы один chat id администратора")
        if len(lst) > 10:
            raise ValueError("%s: не больше 10" % what)
        return lst
    admins = chats(d.get("chat", t.get("TG_CHAT", "")), "администраторы", True)
    viewers = [x for x in chats(d.get("viewers", t.get("TG_VIEWERS", "")), "только просмотр", False) if x not in admins]
    chat = " ".join(admins)
    rt = str(d.get("report_time", t.get("REPORT_TIME", "0900"))).strip().replace(":", "")
    if not re.match(r"^([01]\d|2[0-3])[0-5]\d$", rt):
        raise ValueError("время отчёта: ЧЧММ, например 0900")
    lines = ["TG_TOKEN=%s" % t["TG_TOKEN"], 'TG_CHAT="%s"' % chat, 'TG_VIEWERS="%s"' % " ".join(viewers), "REPORT_TIME=%s" % rt]
    if d.get("no_wan"):
        lines.append("TG_NO_WAN=1")
    with LOCK:
        write_secure(p, "\n".join(lines) + "\n")
        msgs = []
        if d.get("enable_notify", True):
            rc, out = unit_on("awg-notify")
            msgs.append("awg-notify: " + ("работает" if rc == 0 else out.strip()[:200]))
        if d.get("enable_bot"):
            rc, out = unit_on("awg-bot")
            msgs.append("awg-bot: " + ("работает" if rc == 0 else out.strip()[:200]))
        elif svc_installed("awg-bot"):
            unit_off("awg-bot")
            msgs.append("awg-bot: выключен")
    h.act("telegram-set", {"chat": chat, "viewers": viewers, "report_time": rt})
    return {"ok": True, "msg": "сохранено\n" + "\n".join(msgs)}
HOOK_URL_RE = re.compile(r"^https?://[A-Za-z0-9.-]{1,253}(:\d{1,5})?(/[A-Za-z0-9._~%/+=&?:@!,;-]*)?$")


def mask_url(u):
    """Адрес без пути и запроса: в путях вебхуков (Slack, Discord, HA) часто секрет."""
    m = re.match(r"^(https?://[^/]+)(/.*)?$", u or "")
    return (m.group(1) + ("/…" if m.group(2) and m.group(2) != "/" else "")) if m else ""


def api_hooks_get(h, q):
    """Вебхук и ntfy (#14). Полный адрес вебхука, заголовок и токен ntfy в браузер не передаются."""
    k = parse_env_text(read_file(HOOKS_F))
    return {"hook_set": bool(k.get("HOOK_URL")), "hook": mask_url(k.get("HOOK_URL", "")), "header_set": bool(k.get("HOOK_HEADER")),
            "ntfy": k.get("NTFY_URL", ""), "ntfy_token_set": bool(k.get("NTFY_TOKEN")), "notify": svc_active("awg-notify")}


def api_hooks_set(h, d):
    k = parse_env_text(read_file(HOOKS_F))
    out = {}
    hook = str(d.get("hook", "")).strip()
    if d.get("hook_clear"):
        hook = ""
    elif not hook:
        hook = k.get("HOOK_URL", "")            # пусто — прежний адрес (в браузер он не передаётся)
    if hook and not HOOK_URL_RE.match(hook):
        raise ValueError("адрес вебхука: http(s)://узел[:порт]/путь, без пробелов и кавычек")
    hdr = str(d.get("header", "")).strip()
    if d.get("header_clear") or not hook:
        hdr = ""
    elif not hdr:
        hdr = k.get("HOOK_HEADER", "")
        if hdr:
            keep_secret(k.get("HOOK_URL", ""), hook, "заголовок вебхука")
    if hdr and not re.match(r"^[A-Za-z0-9-]{1,64}: [ -~]{1,400}$", hdr) or re.search(r"[\"\\$`]", hdr):
        raise ValueError("заголовок: «Имя: значение», латиница, без кавычек, \\, $ и `")
    ntfy = str(d.get("ntfy", "")).strip()
    if ntfy and not HOOK_URL_RE.match(ntfy):
        raise ValueError("адрес ntfy: https://ntfy.sh/ТЕМА или свой сервер")
    tok = str(d.get("ntfy_token", "")).strip()
    if d.get("ntfy_token_clear") or not ntfy:
        tok = ""
    elif not tok:
        tok = k.get("NTFY_TOKEN", "")
        if tok:
            keep_secret(k.get("NTFY_URL", ""), ntfy, "токен ntfy")
    if tok and not re.match(r"^[A-Za-z0-9_.-]{1,128}$", tok):
        raise ValueError("токен ntfy: латиница, цифры, _ . -")
    for key, v in (("HOOK_URL", hook), ("HOOK_HEADER", hdr), ("NTFY_URL", ntfy), ("NTFY_TOKEN", tok)):
        if v:
            out[key] = v
    with LOCK:
        if out:
            write_secure(HOOKS_F, "".join('%s="%s"\n' % kv for kv in out.items()), 0o600)
        elif os.path.exists(HOOKS_F):
            os.remove(HOOKS_F)
        msg = "сохранено"
        if out and not svc_installed("awg-notify"):
            rc, o = unit_on("awg-notify")
            msg += "\nawg-notify: " + ("работает" if rc == 0 else o.strip()[:200])
    h.act("hooks-set", {"hook": mask_url(hook), "ntfy": mask_url(ntfy)})
    return {"ok": True, "msg": msg}


def api_hooks_test(h, d):
    if not parse_env_text(read_file(HOOKS_F)):
        raise ValueError("вебхук и ntfy не настроены")
    h.act("hooks-test")
    rc, out = run([os.path.join(DD, "notify.sh"), "--only", "hooks", "✅ Тест уведомлений UDR-Amnezia · %s\nвебхук и ntfy работают" % socket.gethostname()], timeout=40)
    log = "\n".join(l for l in read_file(os.path.join(DD, "notify.log")).splitlines()[-3:] if "вебхук" in l or "ntfy" in l)
    return {"ok": rc == 0, "msg": "отправлено" if rc == 0 else "не доставлено" + (": " + log if log else "")}


def api_tg_test(h, d):
    h.act("telegram-test")
    rc, out = run([os.path.join(DD, "awg-notify.sh"), "test"], timeout=60)
    return {"ok": "отправлено" in out, "msg": out.strip() or "нет ответа"}


def api_backups(h, q):
    d = os.path.join(DD, "backups")
    lst = []
    if os.path.isdir(d):
        for f in sorted(os.listdir(d), reverse=True):
            if BK_RE.match(f):
                st = os.stat(os.path.join(d, f))
                lst.append({"name": f, "size": st.st_size, "time": int(st.st_mtime), "enc": f.endswith(".enc")})
    return {"backups": lst}


def api_backup_create(h, d):
    pw = str(d.get("password", ""))
    if len(pw) < 8:
        raise ValueError("пароль копии — не короче 8 символов (храните его отдельно)")
    h.act("backup-create")
    rc, out = run([os.path.join(DD, "backup.sh"), "create"], timeout=120, env={"AWG_BACKUP_PASS": pw})
    return {"ok": rc == 0, "msg": out.strip()}


def api_backup_delete(h, d):
    f = str(d.get("name", ""))
    if not BK_RE.match(f):
        raise ValueError("недопустимое имя")
    try:
        os.remove(os.path.join(DD, "backups", f))
    except OSError as ex:
        raise ValueError(str(ex))
    h.act("backup-delete", f)
    return {"ok": True}


BK_F = os.path.join(DD, "backup.env")
BK_PASS_F = os.path.join(DD, "backup.pass")


def bk_auto_running():
    return run(["systemctl", "is-active", "--quiet", "awg-backup"], timeout=5)[0] == 0 or \
        run(["systemctl", "is-active", "--quiet", "awg-backup-run"], timeout=5)[0] == 0


def api_backup_auto_get(h, q):
    """Автокопия вне роутера (#12): расписание, куда отправлять, история запусков. Пароль в браузер не передаётся."""
    c = parse_env_text(read_file(BK_F))
    hist = []
    for line in read_file(os.path.join(DD, "backups", "auto.status")).splitlines()[-10:]:
        p = line.split("|", 3)
        if len(p) == 4 and p[0].isdigit():
            hist.append({"time": int(p[0]), "ok": p[1] == "OK", "file": p[2], "msg": p[3]})
    return {"auto": c.get("BK_AUTO", "no"), "keep": c.get("BK_KEEP", "7"), "vps": c.get("BK_VPS", "no") == "yes",
            "vps_host": c.get("BK_VPS_HOST", ""), "vps_host_default": env().get("VPS_IP", ""), "vps_port": c.get("BK_VPS_PORT", "22"),
            "vps_user": c.get("BK_VPS_USER", "root"), "vps_dir": c.get("BK_VPS_DIR", "/root/udr-backups"), "vps_keep": c.get("BK_VPS_KEEP", "14"),
            "tg": c.get("BK_TG", "no") == "yes", "tg_ready": bool(parse_env_text(read_file(os.path.join(DD, "telegram.env"))).get("TG_TOKEN")),
            "key": os.path.exists(os.path.join(DD, "ssh", "id_ed25519")), "pass_set": os.path.exists(BK_PASS_F) and os.path.getsize(BK_PASS_F) > 0,
            "timer": os.path.exists(os.path.join(SYSD, "awg-backup.timer")), "running": bk_auto_running(), "history": list(reversed(hist))}


def api_backup_auto_set(h, d):
    auto = str(d.get("auto", "no"))
    if auto not in ("no", "daily", "weekly"):
        raise ValueError("расписание: выключено, ежедневно или еженедельно")
    keep, vkeep = str(d.get("keep", "7")).strip(), str(d.get("vps_keep", "14")).strip()
    if not re.match(r"^\d{1,3}$", keep) or not 1 <= int(keep) <= 100 or not re.match(r"^\d{1,3}$", vkeep) or not 1 <= int(vkeep) <= 365:
        raise ValueError("хранить: на роутере 1–100 копий, на VPS 1–365")
    vps, tg = bool(d.get("vps")), bool(d.get("tg"))
    host = str(d.get("vps_host", "")).strip()
    if host and not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес VPS: имя или IP")
    port = str(d.get("vps_port", "22")).strip()
    if not re.match(r"^\d{1,5}$", port) or not 1 <= int(port) <= 65535:
        raise ValueError("порт SSH: 1–65535")
    user = str(d.get("vps_user", "root")).strip()
    if not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", user):
        raise ValueError("пользователь VPS: латиница в нижнем регистре, цифры, _ -")
    vdir = str(d.get("vps_dir", "/root/udr-backups")).strip()
    if not re.match(r"^/[A-Za-z0-9._/-]{1,200}$", vdir) or ".." in vdir:
        raise ValueError("папка на VPS: абсолютный путь из латиницы, цифр, . _ - /")
    if vps and not (host or env().get("VPS_IP")):
        raise ValueError("укажите адрес VPS")
    pw = str(d.get("pass", ""))
    if pw:
        if len(pw) < 8 or len(pw) > 128 or re.search(r"[\x00-\x1f]", pw):
            raise ValueError("пароль автокопии: 8–128 символов")
        write_secure(BK_PASS_F, pw + "\n", 0o600)
    if auto != "no" and not (os.path.exists(BK_PASS_F) and os.path.getsize(BK_PASS_F) > 0):
        raise ValueError("задайте пароль автокопии: без него копию не зашифровать")
    write_secure(BK_F, "".join('%s="%s"\n' % kv for kv in (
        ("BK_AUTO", auto), ("BK_KEEP", keep), ("BK_VPS", "yes" if vps else "no"), ("BK_VPS_HOST", host), ("BK_VPS_PORT", port),
        ("BK_VPS_USER", user), ("BK_VPS_DIR", vdir), ("BK_VPS_KEEP", vkeep), ("BK_TG", "yes" if tg else "no"))), 0o600)
    rc, out = run([os.path.join(DD, "backup.sh"), "timer"], timeout=30, env={"SYSD": SYSD})
    h.act("backup-auto", {"auto": auto, "vps": vps, "tg": tg, "pass": bool(pw)})
    return {"ok": rc == 0, "msg": out.strip() or "сохранено"}


def api_backup_auto_run(h, d):
    if bk_auto_running():
        raise ValueError("автокопия уже выполняется")
    if not (os.path.exists(BK_PASS_F) and os.path.getsize(BK_PASS_F) > 0):
        raise ValueError("сначала задайте пароль автокопии")
    rc, out = run(["systemd-run", "--unit=awg-backup-run", "--collect", "--quiet", "--setenv=DD=" + DD, os.path.join(DD, "backup.sh"), "auto"], timeout=15)
    h.act("backup-auto-run")
    if rc != 0:
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    return {"ok": True, "msg": "автокопия запущена: результат появится в истории через полминуты"}


def api_backup_auto_test(h, d):
    rc, out = run([os.path.join(DD, "backup.sh"), "vps-test"], timeout=40)
    h.act("backup-vps-test")
    return {"ok": rc == 0, "msg": out.strip()}


def get_backup_file(h, rest, q):
    f = (q.get("name") or [""])[0]
    if not BK_RE.match(f) or not os.path.exists(os.path.join(DD, "backups", f)):
        return h.send(404, {"error": "нет такой копии"})
    with open(os.path.join(DD, "backups", f), "rb") as fh:
        data = fh.read()
    h.act("backup-download", f)
    return h.send(200, data, "application/octet-stream", {"Content-Disposition": 'attachment; filename="%s"' % f})


def get_report_file(h, rest, q):
    f = (q.get("name") or [""])[0]
    if not re.match(r"^awg-report-\d{8}-\d{6}\.txt$", f) or not os.path.exists(os.path.join("/tmp", f)):
        return h.send(404, {"error": "нет такого отчёта"})
    h.act("report-download", f)
    return h.send(200, read_file(os.path.join("/tmp", f)), "text/plain; charset=utf-8",
                  {"Content-Disposition": 'attachment; filename="%s"' % f})


def api_users(h, q):
    u = load_users()
    return {"users": [{"name": k, "totp": bool(v.get("totp")), "me": k == h.user} for k, v in sorted(u.items())]}


def api_passwd(h, d):
    users = load_users()
    me = users.get(h.user)
    if not me or not check_pw(me, str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    target = str(d.get("user") or h.user)
    if not USER_RE.match(target):
        raise ValueError("имя: латиница, цифры, _.- до 32 символов")
    pw = str(d.get("password", ""))
    pr = pw_problem(pw)
    if pr:
        raise ValueError(pr)
    with LOCK:
        users = load_users()
        existed = target in users
        rec = users.get(target, {})
        rec.update(hash_pw(pw))
        users[target] = rec
        save_users(users)
    if target != h.user:
        SESS.drop(user=target)
    h.act("passwd", target)
    return {"ok": True, "msg": "пользователь %s %s" % (target, "— пароль изменён" if existed else "создан")}


def api_user_delete(h, d):
    users = load_users()
    if not check_pw(users.get(h.user, {"salt": "00", "iter": 1, "hash": ""}), str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    t = str(d.get("user", ""))
    if t == h.user:
        raise ValueError("себя удалить нельзя")
    if t not in users:
        raise ValueError("нет такого пользователя")
    with LOCK:
        users.pop(t)
        save_users(users)
    SESS.drop(user=t)
    h.act("user-delete", t)
    return {"ok": True}


def api_totp_begin(h, d):
    sec = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    uri = "otpauth://totp/UDR-Amnezia:%s?secret=%s&issuer=UDR-Amnezia" % (urllib.parse.quote(h.user), sec)
    return {"secret": sec, "uri": uri}


def api_totp_enable(h, d):
    sec = str(d.get("secret", ""))
    if not re.match(r"^[A-Z2-7]{16,64}$", sec):
        raise ValueError("неверный секрет")
    if not totp_ok(sec, d.get("code")):
        raise ValueError("код не подошёл: проверьте время на телефоне и введите новый код")
    with LOCK:
        users = load_users()
        users[h.user]["totp"] = sec
        save_users(users)
    h.act("totp-enable")
    return {"ok": True}


def api_totp_disable(h, d):
    users = load_users()
    if not check_pw(users[h.user], str(d.get("current", ""))):
        raise ApiError(403, "текущий пароль неверен")
    with LOCK:
        users[h.user].pop("totp", None)
        save_users(users)
    h.act("totp-disable")
    return {"ok": True}


def api_system(h, q):
    def ver(cmd):
        return run(cmd, timeout=5)[1].strip().splitlines()[0] if run(cmd, timeout=5)[0] == 0 else "?"
    inst = read_file(os.path.join(DD, "install.sh"))
    m = re.search(r"^INSTALLER_VERSION=(\S+)", inst, re.M)
    return {"version": read_file(os.path.join(DD, "VERSION")).strip(), "installer": m.group(1) if m else "?",
            "panel": VERSION, "awg": ver([os.path.join(DD, "awg"), "--version"]),
            "amneziawg_go": ver([os.path.join(DD, "amneziawg-go"), "--version"]),
            "python": sys.version.split()[0], "host": socket.gethostname(), "web": {k: v for k, v in conf().items()},
            "tls": h.server.tls, "data_free_mb": disk_free_mb(), "channel": channel()[1], "branch": channel()[2]}
