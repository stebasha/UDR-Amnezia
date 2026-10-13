# -*- coding: utf-8 -*-
"""Обновление набора из панели, каналы, бинарники AmneziaWG, перезагрузка роутера."""
from .speed import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= обновление из панели
UPD_LOG = os.path.join(DD, "update.log")


REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_./-]{0,99}$")


def channel():
    """(репозиторий, канал, ветка) — как в install.sh: stable по умолчанию, старый .channel с веткой не main → branch."""
    c = parse_env_text(read_file(os.path.join(DD, ".channel")))
    inst = read_file(os.path.join(DD, "install.sh"))
    m = re.search(r"AWG_REPO:-\$\{_ch_repo:-([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\}\}|^AWG_REPO=\$\{AWG_REPO:-([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\}", inst, re.M)
    repo = c.get("AWG_REPO") or (m and (m.group(1) or m.group(2))) or "stebasha/UDR-Amnezia"
    br = c.get("AWG_BRANCH") or "main"
    ch = c.get("AWG_CHANNEL") or ("branch" if br != "main" else "stable")
    if ch not in ("stable", "beta", "branch"):
        ch = "stable"
    if ch == "beta":
        br = "main"
    return repo, ch, br


def resolve_ref(repo, ch, br):
    """→ (ref, kind): тег последнего релиза для stable (нет релизов — main), иначе ветка."""
    if ch == "stable":
        rc, out = curl(["-f", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/%s/releases/latest" % repo], 20)
        try:
            data = json.loads(out) if rc == 0 else {}
        except ValueError:
            data = {}
        tag = str(data.get("tag_name", "")) if isinstance(data, dict) else ""
        if tag and REF_RE.match(tag) and ".." not in tag:
            return tag, "tag"
        return "main", "branch"
    ref = "main" if ch == "beta" else br
    if not REF_RE.match(ref) or ".." in ref:
        raise ValueError("недопустимое имя ветки: %s" % ref)
    return ref, "branch"


def api_update_check(h, d):
    repo, ch, br = channel()
    ref, kind = resolve_ref(repo, ch, br)
    rc, out = curl(["-f", "https://raw.githubusercontent.com/%s/%s/VERSION" % (repo, ref)], 15)
    cur = read_file(os.path.join(DD, "VERSION")).strip()
    new = out.strip() if rc == 0 and re.match(r"^[0-9][0-9A-Za-z.\-]{0,20}$", out.strip()) else ""
    rc2, chg = curl(["-f", "https://raw.githubusercontent.com/%s/%s/CHANGELOG.md" % (repo, ref)], 15)
    notes = ""
    if rc2 == 0 and new:
        m = re.search(r"^## %s\s*(?:\(.*?\))?\s*\n(.*?)(?=^## )" % re.escape(new), chg + "\n## ", re.M | re.S)
        notes = (m.group(1).strip() if m else "")[:6000]
    env_ = "AWG_CHANNEL=%s" % ch + (" AWG_BRANCH=%s" % br if ch == "branch" else "")
    return {"current": cur, "latest": new, "repo": repo, "channel": ch, "branch": br, "ref": ref, "kind": kind,
            # только новее установленной: канал stable до первого релиза или своя ветка могут быть старее (не предлагать откат)
            "update": bool(new) and vkey(new) > vkey(cur), "older": bool(new) and vkey(new) < vkey(cur),
            "notes": notes, "running": update_running(),
            "cmd": "%s bash <(curl -fsSL https://raw.githubusercontent.com/%s/%s/install.sh) --update" % (env_, repo, ref)}


BINS_CACHE = {"t": 0, "latest": {}}
TAG_RE = re.compile(r"^v[0-9][0-9.]{0,30}$")


def bins_installed(name):
    """Тег установленной сборки: из .binsver (если сумма файла совпала), иначе из --version (#11)."""
    path = os.path.join(DD, name)
    for line in read_file(os.path.join(DD, ".binsver")).splitlines():
        p = line.split()
        if len(p) == 3 and p[0] == name and TAG_RE.match(p[1]):
            try:
                with open(path, "rb") as f:
                    if hashlib.sha256(f.read()).hexdigest() == p[2]:
                        return p[1]
            except OSError:
                pass
    rc, out = run([path, "--version"], timeout=5)
    # первая строка: «amneziawg-tools v3.1.20260812 - …» или у старых сборок «amneziawg-go 0.0.20250522» (без v)
    m = re.search(r"v?([0-9]+(?:\.[0-9]+)+)", (out or "").split("\n")[0])
    return "v" + m.group(1) if rc == 0 and m else ""


def bins_latest(repo):
    rc, out = curl(["-f", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/amnezia-vpn/%s/releases/latest" % repo], 20)
    try:
        x = json.loads(out) if rc == 0 else None
        tag = x.get("tag_name", "") if isinstance(x, dict) else ""
    except ValueError:
        tag = ""
    if not TAG_RE.match(tag or ""):
        rc, out = curl(["-f", "https://api.github.com/repos/amnezia-vpn/%s/tags?per_page=30" % repo], 20)
        try:
            x = json.loads(out) if rc == 0 else []
        except ValueError:
            x = []
        tags = [t.get("name", "") for t in x if isinstance(t, dict) and TAG_RE.match(t.get("name", ""))] if isinstance(x, list) else []
        tag = max(tags, key=vkey) if tags else ""
    return tag if TAG_RE.match(tag or "") else ""


def vkey(v):
    return tuple(int(x) for x in re.findall(r"[0-9]+", v))


def api_bins_check(h, d):
    """Сравнить amneziawg-go и awg с последними официальными релизами amnezia-vpn (#11). Ответ GitHub кешируется на час."""
    now = time.time()
    if d.get("force") or now - BINS_CACHE["t"] > 3600 or not all(BINS_CACHE["latest"].values()):
        BINS_CACHE["latest"] = {"amneziawg-go": bins_latest("amneziawg-go"), "awg": bins_latest("amneziawg-tools")}
        BINS_CACHE["t"] = now
    items, upd = [], False
    for name, src in (("amneziawg-go", "amneziawg-go"), ("awg", "amneziawg-tools")):
        cur, new = bins_installed(name), BINS_CACHE["latest"][name]
        st = "unknown" if not new else "nover" if not cur else "ok" if vkey(cur) >= vkey(new) else "update"
        upd = upd or st == "update"
        items.append({"name": name, "repo": "amnezia-vpn/" + src, "installed": cur, "latest": new, "state": st})
    vc = parse_env_text(read_file(os.path.join(DD, "vps.env")))
    vps_ready = os.path.exists(os.path.join(DD, "ssh", "id_ed25519")) and bool(vc.get("VPS_HOST") or env().get("VPS_IP"))
    return {"items": items, "update": upd, "checked": int(BINS_CACHE["t"]), "vps_ready": vps_ready,
            "cmd": "%s/vps.sh router-bins" % DD}


def api_update_channel(h, d):
    ch = str(d.get("channel", ""))
    repo, cur, br = channel()
    if ch == "branch":
        br = str(d.get("branch", "")).strip()
        if not REF_RE.match(br) or ".." in br:
            raise ValueError("недопустимое имя ветки")
    elif ch not in ("stable", "beta"):
        raise ValueError("канал: stable, beta или своя ветка")
    if ch == "beta":
        br = "main"
    write_secure(os.path.join(DD, ".channel"), "AWG_REPO=%s\nAWG_CHANNEL=%s\nAWG_BRANCH=%s\n" % (repo, ch, br), 0o644)
    h.act("update-channel", {"channel": ch, "branch": br})
    return {"ok": True, "channel": ch, "branch": br, "msg": "канал обновлений: %s" % (ch if ch != "branch" else "ветка " + br)}


def update_running():
    return run(["systemctl", "is-active", "--quiet", "awg-update"], timeout=5)[0] == 0


def api_update_run(h, d):
    if update_running():
        raise ValueError("обновление уже идёт")
    repo, ch, br = channel()
    ref, kind = resolve_ref(repo, ch, br)
    write_secure(UPD_LOG, "%s обновление запущено из панели (%s, канал %s, %s %s)\n" % (time.strftime("%F %T"), repo, ch,
                 "релиз" if kind == "tag" else "ветка", ref), 0o600)
    # установщик берётся из той же версии, что и скрипты; AWG_REF фиксирует проверенный релиз (новый, вышедший между
    # проверкой и запуском, не подхватится незаметно)
    script = ('cd /; export AWG_YES=1 AWG_REPO="$1" AWG_CHANNEL="$2" AWG_BRANCH="$3" AWG_REF="$4" AWG_REF_KIND="$5"; '
              'f=$(mktemp); if curl -fsSL -m 120 "https://raw.githubusercontent.com/$1/$4/install.sh" -o "$f" && bash -n "$f"; then '
              'bash "$f" --update; rc=$?; else echo "не удалось скачать install.sh"; rc=1; fi; rm -f "$f"; echo "[код $rc]"; exit $rc')
    rc, out = run(["systemd-run", "--unit=awg-update", "--collect", "--quiet", "-p", "StandardOutput=append:" + UPD_LOG,
                   "-p", "StandardError=append:" + UPD_LOG, "/bin/bash", "-c", script, "awg-update", repo, ch, br, ref, kind], timeout=20)
    if rc != 0:
        raise ValueError("не удалось запустить обновление: " + out.strip()[:300])
    h.act("update-run", ref)
    return {"ok": True, "msg": "обновление запущено; панель перезапустится, страница переподключится сама"}
