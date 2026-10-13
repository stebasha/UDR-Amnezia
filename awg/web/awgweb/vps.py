# -*- coding: utf-8 -*-
"""Свой VPS: подключение, состояние, обновление AmneziaWG, ключи и обфускация (#13)."""
from .webconf import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= свой VPS (#13)
VPS_F = os.path.join(DD, "vps.env")
VPS_LOG = os.path.join(DD, "vps-job.log")
VPS_ACTIONS = {"setup": "подключение своего VPS", "addkey": "ключ роутера на VPS", "update": "обновление AmneziaWG на VPS", "router-bins": "обновление AmneziaWG на роутере", "rotate-keys": "смена ключей", "obfs": "смена параметров обфускации"}


def vps_job_running():
    return run(["systemctl", "is-active", "--quiet", "awg-vps-job"], timeout=5)[0] == 0


def vps_sh(args, timeout):
    return run([os.path.join(DD, "vps.sh")] + args, timeout=timeout)


def api_vps_get(h, q):
    c = parse_env_text(read_file(VPS_F))
    key = os.path.join(DD, "ssh", "id_ed25519")
    tuns = [t for t in vps_sh(["tunnels"], 10)[1].split() if NAME_RE.match(t)]
    return {"host": c.get("VPS_HOST", ""), "host_default": env().get("VPS_IP", ""), "port": c.get("VPS_PORT", "22"), "user": c.get("VPS_USER", "root"),
            "key": os.path.exists(key), "pub": read_file(key + ".pub").strip()[:200], "tunnels": tuns,
            "running": vps_job_running(), "log": read_file(VPS_LOG)[-20000:]}


def api_vps_set(h, d):
    host = str(d.get("host", "")).strip()
    if host and not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес VPS: имя или IP")
    port = str(d.get("port", "22")).strip()
    if not re.match(r"^\d{1,5}$", port) or not 1 <= int(port) <= 65535:
        raise ValueError("порт SSH: 1–65535")
    user = str(d.get("user", "root")).strip()
    if not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", user):
        raise ValueError("пользователь: латиница в нижнем регистре, цифры, _ -")
    write_secure(VPS_F, 'VPS_HOST="%s"\nVPS_PORT="%s"\nVPS_USER="%s"\n' % (host, port, user), 0o600)
    h.act("vps-set", {"host": host, "port": port, "user": user})
    return {"ok": True, "msg": "сохранено"}


def api_vps_test(h, d):
    rc, out = vps_sh(["test"], 40)
    return {"ok": rc == 0, "msg": out.strip()}


def api_vps_status(h, d):
    h.act("vps-status")
    rc, out = vps_sh(["status"], 120)
    return {"ok": rc == 0, "text": out.strip()}


def api_vps_versions(h, d):
    rc, out = vps_sh(["versions"], 90)
    return {"ok": rc in (0, 10), "update": rc == 10, "text": out.strip()}


def api_vps_run(h, d):
    """Изменения на VPS — отдельной службой (сборка идёт минуты), только с паролем текущего пользователя."""
    a = str(d.get("action", ""))
    if a not in VPS_ACTIONS:
        raise ValueError("действие: setup, addkey, update, router-bins, rotate-keys или obfs")
    need_pw(h, d, "vps-" + a)
    if vps_job_running():
        raise ValueError("на VPS уже выполняется действие: дождитесь окончания")
    if update_running():
        raise ValueError("идёт обновление набора: дождитесь его окончания")
    args = [a]
    t = str(d.get("tunnel", "")).strip()
    if a in ("rotate-keys", "obfs") and t:
        if not NAME_RE.match(t):
            raise ValueError("недопустимое имя туннеля")
        args.append(t)
    env_ = []
    if a in ("setup", "addkey"):   # мастер (#28): адрес VPS сохраняется, пароль VPS — только во временный файл 600 до первого входа
        api_vps_set(h, d)
        if a == "setup":
            t = str(d.get("name", "awgvps")).strip() or "awgvps"
            if not NAME_RE.match(t) or t in tunnels(env()):
                raise ValueError("имя туннеля: awg и 1–10 строчных букв или цифр, не занятое (например awgvps)")
            ap = str(d.get("awg_port", "51823")).strip()
            if not re.match(r"^\d{4,5}$", ap) or not 1024 <= int(ap) <= 65535:
                raise ValueError("порт AmneziaWG: 1024–65535")
            args += [t, ap]
        vp = str(d.get("vps_password", ""))
        if vp:
            if len(vp) > 256 or re.search(r"[\x00-\x1f]", vp):
                raise ValueError("пароль VPS: до 256 символов, без управляющих")
            pf = os.path.join(DD, ".vpspass-%s" % secrets.token_hex(6))
            write_secure(pf, vp, 0o600)
            env_ = ["--setenv=VPS_PASS_FILE=" + pf]
    write_secure(VPS_LOG, "%s %s — запущено из панели (%s)\n" % (time.strftime("%F %T"), VPS_ACTIONS[a], h.user), 0o600)
    rc, out = run(["systemd-run", "--unit=awg-vps-job", "--collect", "--quiet", "--setenv=DD=" + DD] + env_ + ["-p", "StandardOutput=append:" + VPS_LOG,
                   "-p", "StandardError=append:" + VPS_LOG, "/bin/bash", "-c", '"$0" "$@"; rc=$?; echo "[код $rc]"; exit $rc',
                   os.path.join(DD, "vps.sh")] + args, timeout=20)
    if rc != 0:
        for x in env_:
            try:
                os.remove(x.split("=", 2)[2])
            except OSError:
                pass
        raise ValueError("не удалось запустить: " + out.strip()[:300])
    h.act("vps-" + a, t)
    return {"ok": True, "msg": VPS_ACTIONS[a] + ": запущено"}


def api_vps_job(h, q):
    return {"running": vps_job_running(), "text": read_file(VPS_LOG)[-20000:]}


REBOOT_DELAY = 5


def api_system_reboot(h, d):
    """Перезагрузка роутера целиком (UniFi тоже). Только с паролем текущего пользователя; не во время обновления."""
    need_pw(h, d, "reboot")
    if update_running():
        raise ValueError("идёт обновление набора: дождитесь его окончания, потом перезагружайте")
    rb = shutil.which("reboot") or "/sbin/reboot"
    rc, out = run(["systemd-run", "--unit=awg-reboot", "--collect", "--quiet", "--on-active=%d" % REBOOT_DELAY, rb], timeout=15)
    if rc != 0:
        raise ValueError("не удалось запланировать перезагрузку: " + out.strip()[:300])
    h.act("reboot", "через %d с" % REBOOT_DELAY)
    try:
        with open(os.path.join(DD, "events.log"), "a", encoding="utf-8") as f:
            f.write("%d|reboot|перезагрузка роутера из панели (%s)\n" % (now(), h.user))
    except OSError:
        pass
    if notify_configured() and os.access(os.path.join(DD, "notify.sh"), os.X_OK):
        run([os.path.join(DD, "notify.sh"), "--html", "🔁 <b>Перезагрузка роутера</b> · %s\nиз веб-панели, пользователь %s"
             % (html.escape(socket.gethostname()), html.escape(h.user))], timeout=8)
    return {"ok": True, "delay": REBOOT_DELAY,
            "msg": "роутер перезагрузится через %d с; интернет и UniFi вернутся через 2–4 минуты" % REBOOT_DELAY}


def api_update_log(h, q):
    t = read_file(UPD_LOG)
    return {"text": t[-60000:], "running": update_running(), "version": read_file(os.path.join(DD, "VERSION")).strip()}
