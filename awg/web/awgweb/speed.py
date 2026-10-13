# -*- coding: utf-8 -*-
"""Замер скорости через туннели и WAN."""
from .configs import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= скорость
SPEED_F = os.path.join(WEBD, "speed.json")
SPEED_URL = os.environ.get("AWG_SPEED_URL", "https://speed.cloudflare.com")


def speed_hist():
    try:
        x = json.loads(read_file(SPEED_F, "[]"))
        return x if isinstance(x, list) else []
    except ValueError:
        return []


def speed_steps(ifaces, mb):
    """Замер скорости: задержка (TCP-подключение), загрузка и отдача через указанный интерфейс."""
    res = []
    for i in ifaces:
        yield "== %s\n" % i
        r = {"t": now(), "iface": i, "mb": mb}
        rc, out = curl(["-o", "/dev/null", "--interface", i, "-w", "%{time_connect}", SPEED_URL + "/__down?bytes=0"], 8)
        try:
            r["ping_ms"] = int(float(out.strip() or 0) * 1000)
        except ValueError:
            r["ping_ms"] = 0
        yield "задержка (TCP-подключение): %s мс\n" % (r["ping_ms"] or "—")
        rc, out = curl(["-o", "/dev/null", "--interface", i, "-w", "%{speed_download} %{size_download}",
                        "%s/__down?bytes=%d" % (SPEED_URL, mb * 1000000)], 40)
        p = out.split()
        r["down_bps"] = int(float(p[0]) * 8) if rc == 0 and p else 0
        yield "загрузка: %s\n" % (fmt_bps(r["down_bps"]) if r["down_bps"] else "не удалось (код %d)" % rc)
        up_mb = max(1, mb // 4)
        rc, out = run(["sh", "-c", 'head -c %d /dev/zero | curl -s -4 -m 40 --interface "$1" -o /dev/null -w "%%{speed_upload}" '
                       '--data-binary @- "$2"' % (up_mb * 1000000), "sh", i, SPEED_URL + "/__up"], timeout=45)
        try:
            r["up_bps"] = int(float(out.strip().split()[-1]) * 8) if rc == 0 else 0
        except (ValueError, IndexError):
            r["up_bps"] = 0
        yield "отдача: %s\n\n" % (fmt_bps(r["up_bps"]) if r["up_bps"] else "не удалось (код %d)" % rc)
        res.append(r)
    with LOCK:
        hist = (speed_hist() + res)[-60:]
        write_secure(SPEED_F, json.dumps(hist), 0o600)
    yield "Сохранено в историю замеров.\n"


def fmt_bps(b):
    b = float(b)
    for u, k in (("Гбит/с", 1e9), ("Мбит/с", 1e6), ("Кбит/с", 1e3)):
        if b >= k:
            return "%.1f %s" % (b / k, u)
    return "%d бит/с" % b


def api_speed(h, q):
    return {"history": speed_hist()[::-1]}
