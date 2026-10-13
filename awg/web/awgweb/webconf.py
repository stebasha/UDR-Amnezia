# -*- coding: utf-8 -*-
"""Сертификат и настройки самой панели."""
from .account import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= сертификат
UNIFI_CORE = os.environ.get("AWG_UNIFI_CORE", "/data/unifi-core/config")


def cert_info(path):
    """Субъект, издатель, срок, имена из сертификата (без внешних модулей)."""
    try:
        d = ssl._ssl._test_decode_cert(path)
    except Exception:
        return None
    sub = dict(x[0] for x in d.get("subject", ()) if x)
    iss = dict(x[0] for x in d.get("issuer", ()) if x)
    try:
        exp = int(ssl.cert_time_to_seconds(d.get("notAfter", "")))
    except (ValueError, TypeError):
        exp = 0
    sans = [v for k, v in d.get("subjectAltName", ()) if k in ("DNS", "IP Address")]
    return {"subject": sub.get("commonName", ""), "issuer": iss.get("organizationName") or iss.get("commonName", ""),
            "expires": exp, "names": sans, "self_signed": d.get("subject") == d.get("issuer"), "path": path}


def unifi_cert_candidates():
    """Сертификат веб-интерфейса UniFi OS: из конфигов nginx/unifi-core, затем стандартные имена, затем поиск."""
    cands = []
    for f in sorted(globr(os.path.join(UNIFI_CORE, "http"), ".conf")):
        txt = read_file(f)
        c = re.search(r"^\s*ssl_certificate\s+([^;\s]+)\s*;", txt, re.M)
        k = re.search(r"^\s*ssl_certificate_key\s+([^;\s]+)\s*;", txt, re.M)
        if c and k:
            cands.append((c.group(1), k.group(1)))
    y = read_file(os.path.join(UNIFI_CORE, "overrides", "local.yaml"))
    c = re.search(r"(/\S+\.(?:crt|pem))", y)
    k = re.search(r"(/\S+\.key)", y)
    if c and k:
        cands.append((c.group(1).strip("'\""), k.group(1).strip("'\"")))
    cands.append((os.path.join(UNIFI_CORE, "unifi-core.crt"), os.path.join(UNIFI_CORE, "unifi-core.key")))
    for crt in sorted(globr(UNIFI_CORE, ".crt", depth=3)):
        key = crt[:-4] + ".key"
        if os.path.exists(key):
            cands.append((crt, key))
    seen, out = set(), []
    for c, k in cands:
        if (c, k) in seen or not (os.path.isfile(c) and os.path.isfile(k)):
            continue
        seen.add((c, k))
        out.append((c, k))
    # предпочтение: не самоподписанный, с самым поздним сроком
    def score(ck):
        i = cert_info(ck[0]) or {}
        return (0 if i.get("self_signed", True) else 1, i.get("expires", 0))
    return sorted(out, key=score, reverse=True)


def globr(d, ext, depth=1):
    out = []
    try:
        for f in os.listdir(d):
            p = os.path.join(d, f)
            if os.path.isfile(p) and f.endswith(ext):
                out.append(p)
            elif os.path.isdir(p) and depth > 1:
                out += globr(p, ext, depth - 1)
    except OSError:
        pass
    return out


def pick_cert(c):
    """→ (crt, key, режим, предупреждение)."""
    mode = c.get("WEB_CERT", "auto")
    if mode not in ("auto", "unifi", "self"):
        k = c.get("WEB_KEY", "")
        if os.path.isfile(mode) and os.path.isfile(k):
            return mode, k, "file", ""
        return CERT_F, KEY_F, "self", "файлы WEB_CERT/WEB_KEY не найдены, используется самоподписанный"
    if mode in ("auto", "unifi"):
        for crt, key in unifi_cert_candidates():
            i = cert_info(crt) or {}
            if mode == "unifi" or not i.get("self_signed", True):
                return crt, key, "unifi", ""
        if mode == "unifi":
            return CERT_F, KEY_F, "self", "сертификат UniFi не найден, используется самоподписанный"
    return CERT_F, KEY_F, "self", ""


class CertWatch(threading.Thread):
    """Следит за файлами сертификата и перечитывает их без перезапуска (продление в UniFi подхватывается само)."""

    def __init__(self, ctx, crt, key):
        super().__init__(daemon=True)
        self.ctx, self.crt, self.key = ctx, crt, key
        self.mt = self.mtimes()

    def mtimes(self):
        try:
            return (os.stat(self.crt).st_mtime, os.stat(self.key).st_mtime)
        except OSError:
            return None

    def run(self):
        while True:
            time.sleep(int(os.environ.get("AWG_CERT_POLL", "60")))
            m = self.mtimes()
            if m and m != self.mt:
                time.sleep(3)           # дождаться записи обоих файлов
                try:
                    self.ctx.load_cert_chain(self.crt, self.key)
                    self.mt = self.mtimes()
                    sys.stderr.write("сертификат перечитан: %s\n" % self.crt)
                except (ssl.SSLError, OSError) as ex:
                    sys.stderr.write("сертификат не перечитан: %s\n" % ex)


# ======================================================================= настройки панели
def api_web_get(h, q):
    c = conf()
    info = h.server.cert_info or {}
    return {"port": c["WEB_PORT"], "bind": c["WEB_BIND"], "tls": c["WEB_TLS"], "allow": c["WEB_ALLOW"], "hosts": c.get("WEB_HOSTS", ""),
            "cert_mode": c.get("WEB_CERT", "auto"), "cert": info, "cert_used": h.server.cert_mode, "cert_warn": h.server.cert_warn,
            "unifi_certs": [dict(cert_info(cr) or {}, key=k) for cr, k in unifi_cert_candidates()[:5]], "lan": lan_ip()}


def port_busy(p):
    out = run(["ss", "-ltnH"], timeout=5)[1]
    return any(re.search(r"[:.]%d$" % p, line.split()[3]) for line in out.splitlines() if len(line.split()) > 3)


PRIVATE_NETS = [ipaddress.ip_network(x) for x in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8",
                                                  "169.254.0.0/16", "fc00::/7", "fe80::/10", "::1/128")]
UNIFI_PORTS = {22, 53, 80, 443, 8080, 8443, 8444, 8880, 8843, 6789, 3478, 10001, 5514, 11443, 1900, 5671, 5656, 9543, 9090}


def api_web_set(h, d):
    c = conf()
    upd = {}
    p = str(d.get("port", c["WEB_PORT"])).strip()
    if not re.match(r"^\d{4,5}$", p) or not 1024 <= int(p) <= 65535 or int(p) in UNIFI_PORTS:
        raise ValueError("порт 1024–65535, не занятый службами UniFi (8443, 8080, 8880 и др.)")
    if p != c["WEB_PORT"] and port_busy(int(p)):
        raise ValueError("порт %s уже занят другой программой" % p)
    upd["WEB_PORT"] = p
    cm = str(d.get("cert_mode", c.get("WEB_CERT", "auto")))
    if cm not in ("auto", "unifi", "self"):
        raise ValueError("сертификат: auto, unifi или self")
    upd["WEB_CERT"] = cm
    hosts = v_domains(d.get("hosts", c.get("WEB_HOSTS", ""))) if str(d.get("hosts", "")).strip() else ""
    upd["WEB_HOSTS"] = hosts
    allow = str(d.get("allow", c["WEB_ALLOW"])).split()
    for n in allow:
        net = ipaddress.ip_network(n, strict=False)
        # явный список частных диапазонов: is_private в Python до 3.11 считал 0.0.0.0/0 частной сетью
        if not any(net.version == p.version and net.subnet_of(p) for p in PRIVATE_NETS):
            raise ValueError("«%s»: разрешать можно только частные сети (панель не для интернета)" % n)
    if not allow:
        raise ValueError("нужна хотя бы одна сеть")
    upd["WEB_ALLOW"] = " ".join(allow)
    with LOCK:
        lines = read_file(CONF_F).splitlines()
        done = set()
        out = []
        for line in lines:
            m = re.match(r"^\s*([A-Z_]+)=", line)
            if m and m.group(1) in upd:
                out.append(fmt_env(m.group(1), upd[m.group(1)]))
                done.add(m.group(1))
            else:
                out.append(line)
        out += [fmt_env(k, v) for k, v in upd.items() if k not in done]
        write_secure(CONF_F, "\n".join(out) + "\n")
    h.act("web-settings", upd)
    threading.Thread(target=lambda: (time.sleep(1.5), run(["systemctl", "--no-block", "restart", "awg-web"], timeout=10)), daemon=True).start()
    scheme = "https" if c["WEB_TLS"] == "yes" else "http"
    return {"ok": True, "msg": "сохранено, панель перезапускается", "url": "%s://%s:%s/" % (scheme, h.headers.get("Host", "").rsplit(":", 1)[0] or lan_ip(), p)}
