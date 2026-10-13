# -*- coding: utf-8 -*-
"""Свой VPS: подключение, состояние, обновление AmneziaWG, ключи и обфускация (#13)."""
from .webconf import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= свой VPS (#13)
VPS_F = os.path.join(DD, "vps.env")              # VPS main (как до #32)
VPS_D = os.path.join(DD, "vps.d")                # остальные свои VPS (#32): vps.d/ID.env
VPS_ID_RE = re.compile(r"^[a-z][a-z0-9]{0,11}$")
VPS_LOG = os.path.join(DD, "vps-job.log")
VPS_ACTIONS = {"setup": "подключение своего VPS", "addkey": "ключ роутера на VPS", "update": "обновление AmneziaWG на VPS", "router-bins": "обновление AmneziaWG на роутере", "rotate-keys": "смена ключей", "obfs": "смена параметров обфускации"}


def vps_job_running():
    return run(["systemctl", "is-active", "--quiet", "awg-vps-job"], timeout=5)[0] == 0


def vps_file(vid):
    return VPS_F if vid == "main" else os.path.join(VPS_D, vid + ".env")


def vps_profiles():
    """Свои VPS (#32): main (vps.env, адрес по умолчанию — VPS_IP) и vps.d/ID.env."""
    out = []
    c = parse_env_text(read_file(VPS_F))
    out.append({"id": "main", "host": c.get("VPS_HOST", "") or env().get("VPS_IP", ""), "label": c.get("VPS_LABEL", "")})
    try:
        names = sorted(os.listdir(VPS_D))
    except OSError:
        names = []
    for f in names:
        vid = f[:-4] if f.endswith(".env") else ""
        if VPS_ID_RE.match(vid) and vid != "main":
            c = parse_env_text(read_file(os.path.join(VPS_D, f)))
            out.append({"id": vid, "host": c.get("VPS_HOST", ""), "label": c.get("VPS_LABEL", "")})
    return out


def vps_id(d, must_exist=True):
    vid = str((d.get("vps") if isinstance(d, dict) else "") or "main").strip()
    if isinstance(d, dict) and isinstance(d.get("vps"), list):        # из строки запроса
        vid = str(d["vps"][0] or "main")
    if not VPS_ID_RE.match(vid):
        raise ValueError("неверный ID VPS")
    if must_exist and vid != "main" and not os.path.exists(vps_file(vid)):
        raise ValueError("нет такого VPS: %s" % vid)
    return vid


def vps_sh(args, timeout, vid="main"):
    return run([os.path.join(DD, "vps.sh")] + ([] if vid == "main" else ["--vps", vid]) + args, timeout=timeout)


def api_vps_get(h, q):
    vid = vps_id(q)
    c = parse_env_text(read_file(vps_file(vid)))
    key = os.path.join(DD, "ssh", "id_ed25519")
    tuns = [t for t in vps_sh(["tunnels"], 10, vid)[1].split() if NAME_RE.match(t)]
    return {"vps": vid, "profiles": vps_profiles(), "label": c.get("VPS_LABEL", ""),
            "host": c.get("VPS_HOST", ""), "host_default": env().get("VPS_IP", "") if vid == "main" else "",
            "port": c.get("VPS_PORT", "22"), "user": c.get("VPS_USER", "root"),
            "key": os.path.exists(key), "pub": read_file(key + ".pub").strip()[:200], "tunnels": tuns,
            "running": vps_job_running(), "log": read_file(VPS_LOG)[-20000:]}


def api_vps_set(h, d):
    """Сохранить VPS; vps="" и new — добавить новый (ID v2, v3, …). → {ok, msg, vps}."""
    if d.get("new"):
        used = {p["id"] for p in vps_profiles()}
        vid = next("v%d" % i for i in range(2, 100) if "v%d" % i not in used)
    else:
        vid = vps_id(d, must_exist=False)
    host = str(d.get("host", "")).strip()
    if host and not HOST_OR_IP_RE.match(host):
        raise ValueError("адрес VPS: имя или IP")
    if vid != "main" and not host:
        raise ValueError("укажите адрес VPS")
    port = str(d.get("port", "22")).strip()
    if not re.match(r"^\d{1,5}$", port) or not 1 <= int(port) <= 65535:
        raise ValueError("порт SSH: 1–65535")
    user = str(d.get("user", "root")).strip()
    if not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", user):
        raise ValueError("пользователь: латиница в нижнем регистре, цифры, _ -")
    label = str(d.get("label", "")).strip()[:40]
    if re.search(r"[<>\"'`$\\&\x00-\x1f]", label):
        raise ValueError("недопустимые символы в названии VPS")
    if vid != "main":
        os.makedirs(VPS_D, mode=0o700, exist_ok=True)
    write_secure(vps_file(vid), 'VPS_HOST="%s"\nVPS_PORT="%s"\nVPS_USER="%s"\nVPS_LABEL="%s"\n' % (host, port, user, label), 0o600)
    h.act("vps-set", {"vps": vid, "host": host, "port": port, "user": user})
    return {"ok": True, "msg": "сохранено", "vps": vid}


def api_vps_del(h, d):
    vid = vps_id(d)
    if vid == "main":
        raise ValueError("основной VPS не удаляется — можно изменить его адрес")
    if vps_job_running():
        raise ValueError("на VPS выполняется действие: дождитесь окончания")
    os.remove(vps_file(vid))
    h.act("vps-del", vid)
    return {"ok": True, "msg": "VPS убран из списка (сервер и туннели не тронуты)"}


def api_vps_test(h, d):
    rc, out = vps_sh(["test"], 40, vps_id(d))
    return {"ok": rc == 0, "msg": out.strip()}


def api_vps_status(h, d):
    h.act("vps-status")
    rc, out = vps_sh(["status"], 120, vps_id(d))
    return {"ok": rc == 0, "text": out.strip()}


def api_vps_versions(h, d):
    rc, out = vps_sh(["versions"], 90, vps_id(d))
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
    if a in ("setup", "addkey"):   # мастер (#28): адрес VPS сохраняется (новый VPS — с новым ID, #32)
        d = dict(d, vps=api_vps_set(h, d)["vps"], new=False)
    vid = vps_id(d)
    args = ([] if vid == "main" else ["--vps", vid]) + [a]
    t = str(d.get("tunnel", "")).strip()
    if a in ("rotate-keys", "obfs") and t:
        if not NAME_RE.match(t):
            raise ValueError("недопустимое имя туннеля")
        args.append(t)
    env_ = []
    if a in ("setup", "addkey"):   # пароль VPS — только во временный файл 600 до первого входа
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
    h.act("vps-" + a, {"vps": vid, "tunnel": t})
    return {"ok": True, "msg": VPS_ACTIONS[a] + ": запущено", "vps": vid}


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
