# -*- coding: utf-8 -*-
"""Конфиги туннелей: поля, проверка, ревизии."""
from .data import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= конфиги: поля, проверка, ревизии
KEY_RE = re.compile(r"^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


def _ints(lo, hi):
    def f(v):
        if not re.match(r"^\d{1,10}$", v) or not lo <= int(v) <= hi:
            raise ValueError("целое от %d до %d" % (lo, hi))
    return f


def _key(v):
    if not KEY_RE.match(v):
        raise ValueError("ключ WireGuard: 44 символа base64, оканчивается на «=»")


def _addrs(v):
    parts = [x.strip() for x in v.split(",") if x.strip()]
    if not parts:
        raise ValueError("пусто")
    for x in parts:
        try:
            ipaddress.ip_interface(x)
        except ValueError:
            raise ValueError("«%s» — не адрес вида 10.8.1.2/32" % x)
    if not any(":" not in x for x in parts):
        raise ValueError("нужен хотя бы один IPv4-адрес")


def _ips(v):
    for x in [x.strip() for x in v.split(",") if x.strip()]:
        try:
            ipaddress.ip_address(x)
        except ValueError:
            if not HOST_RE.match(x):
                raise ValueError("«%s» — не IP-адрес" % x)


def _cidrs(v):
    parts = [x.strip() for x in v.split(",") if x.strip()]
    if not parts:
        raise ValueError("пусто")
    for x in parts:
        try:
            ipaddress.ip_network(x, strict=False)
        except ValueError:
            raise ValueError("«%s» — не сеть вида 0.0.0.0/0" % x)


def _endpoint(v):
    m = re.match(r"^\[([0-9A-Fa-f:.]+)\]:(\d{1,5})$", v) or re.match(r"^([^:\[\]]+):(\d{1,5})$", v)
    if not m or not 1 <= int(m.group(2)) <= 65535:
        raise ValueError("нужно АДРЕС:ПОРТ, например 203.0.113.10:51820")
    host = m.group(1)
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not HOST_RE.match(host):
            raise ValueError("«%s» — не адрес и не имя сервера" % host)


def _hrange(v):
    m = re.match(r"^(\d{1,10})(?:-(\d{1,10}))?$", v)
    if not m or int(m.group(1)) > 4294967295 or (m.group(2) and (int(m.group(2)) > 4294967295 or int(m.group(2)) < int(m.group(1)))):
        raise ValueError("число 0–4294967295 или диапазон «от-до»")


def _itag(v):
    if len(v) > 4096 or not re.match(r"^(\s*<[^<>\r\n]{1,1000}>)+\s*$", v):
        raise ValueError("последовательность тегов вида <b 0x…><r 16>")


def _onoff(v):
    if v.lower() not in ("on", "off", "true", "false", "1", "0", "yes", "no"):
        raise ValueError("on или off")


def _b64(v):
    if not re.match(r"^[A-Za-z0-9+/]{16,128}={0,2}$", v):
        raise ValueError("ключ в base64")


def _mtu(v):
    _ints(1000, 1500)(v)


# раздел, ключ, проверка, обязателен, подсказка
CONF_FIELDS = [
    ("Interface", "PrivateKey", _key, True, "закрытый ключ роутера"),
    ("Interface", "Address", _addrs, True, "адрес в туннеле, например 10.8.1.2/32"),
    ("Interface", "DNS", _ips, False, "не применяется на роутере (DNS задаёт UniFi), только для справки"),
    ("Interface", "MTU", _mtu, False, "пусто — по умолчанию 1376"),
    ("Interface", "Jc", _ints(0, 128), False, "число мусорных пакетов перед handshake"),
    ("Interface", "Jmin", _ints(0, 1280), False, "мин. размер мусорного пакета"),
    ("Interface", "Jmax", _ints(0, 1280), False, "макс. размер мусорного пакета"),
    ("Interface", "S1", _ints(0, 1500), False, "добавка к пакету инициации"),
    ("Interface", "S2", _ints(0, 1500), False, "добавка к пакету ответа"),
    ("Interface", "S3", _ints(0, 1500), False, "AWG 2.0: добавка к cookie"),
    ("Interface", "S4", _ints(0, 1500), False, "AWG 2.0: добавка к данным"),
    ("Interface", "H1", _hrange, False, "заголовок инициации"),
    ("Interface", "H2", _hrange, False, "заголовок ответа"),
    ("Interface", "H3", _hrange, False, "заголовок cookie"),
    ("Interface", "H4", _hrange, False, "заголовок данных"),
    ("Interface", "I1", _itag, False, "AWG 2.0: имитация протокола"),
    ("Interface", "I2", _itag, False, ""),
    ("Interface", "I3", _itag, False, ""),
    ("Interface", "I4", _itag, False, ""),
    ("Interface", "I5", _itag, False, ""),
    ("Interface", "HeaderProtectionKey", _b64, False, "AWG 3.x: ключ защиты заголовков"),
    ("Interface", "ContentPaddingAddition", _hrange, False, "AWG 3.x: добавка к данным, «от-до»"),
    ("Interface", "RekeyAfterTime", _hrange, False, "AWG 3.x: смена ключей через, с"),
    ("Interface", "RekeyTimeout", _hrange, False, "AWG 3.x: таймаут смены ключей, с"),
    ("Interface", "RejectAfterTime", _hrange, False, "AWG 3.x: отклонять старый ключ через, с"),
    ("Interface", "KeepaliveTimeout", _hrange, False, "AWG 3.x: таймаут keepalive, с"),
    ("Interface", "MaxHandshakeAttempts", _hrange, False, "AWG 3.x: попыток handshake"),
    ("Interface", "RandomTrailers", _onoff, False, "AWG 3.x: случайные хвосты пакетов"),
    ("Interface", "DisableCookies", _onoff, False, "AWG 3.x: без cookie-ответов"),
    ("Peer", "PublicKey", _key, True, "открытый ключ сервера"),
    ("Peer", "PresharedKey", _key, False, "общий ключ (если есть)"),
    ("Peer", "Endpoint", _endpoint, True, "адрес и порт сервера"),
    ("Peer", "AllowedIPs", _cidrs, True, "обычно 0.0.0.0/0"),
    ("Peer", "PersistentKeepalive", _ints(0, 65535), False, "секунд; 25 — держать NAT открытым"),
]
FIELD_BY_KEY = {(s, k.lower()): (s, k, f, req, hint) for s, k, f, req, hint in CONF_FIELDS}
SECRET_FIELDS = {"privatekey", "presharedkey", "headerprotectionkey"}


def conf_sections(text):
    """[(имя раздела или '', [строки])] — порядок и комментарии сохраняются."""
    out = [("", [])]
    for line in text.replace("\r", "").split("\n"):
        m = re.match(r"^\s*\[([A-Za-z]+)\]\s*$", line)
        if m:
            out.append((m.group(1), [line]))
        else:
            out[-1][1].append(line)
    return out


def conf_join(secs):
    text = "\n".join("\n".join(lines) for _, lines in secs if lines)
    return text.strip("\n") + "\n"


def conf_fields(text, masked=True):
    res = {"Interface": {}, "Peer": {}}
    other = []
    seen = set()
    peers = 0
    for name, lines in conf_sections(text):
        if name == "Peer":
            peers += 1
            if peers > 1:
                continue
        for line in lines:
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            fk = FIELD_BY_KEY.get((name, k.lower()))
            if fk and (name, fk[1]) not in seen:
                seen.add((name, fk[1]))
                res[name][fk[1]] = (MASK if masked and v else v) if k.lower() in SECRET_FIELDS else v
            elif name in ("Interface", "Peer"):
                other.append("%s.%s" % (name, k))
    return {"fields": res, "other": other, "peers": peers}


def conf_apply_fields(text, fields):
    """Записать поля в текст конфига: меняются только переданные ключи, остальные строки остаются."""
    secs = conf_sections(text)
    for sec in ("Interface", "Peer"):
        upd = fields.get(sec) or {}
        if not isinstance(upd, dict):
            raise ValueError("неверный формат полей")
        idx = next((i for i, (n, _) in enumerate(secs) if n == sec), None)
        if idx is None:
            secs.append((sec, ["[%s]" % sec]))
            idx = len(secs) - 1
        lines = secs[idx][1]
        for key, val in upd.items():
            fk = FIELD_BY_KEY.get((sec, str(key).lower()))
            if not fk:
                raise ValueError("неизвестное поле %s.%s" % (sec, key))
            key = fk[1]
            val = str(val if val is not None else "").strip()
            if "\n" in val or "\r" in val:
                raise ValueError("%s: перевод строки недопустим" % key)
            if key.lower() in SECRET_FIELDS and val == MASK:
                continue                       # секрет не меняется
            pos = next((i for i, l in enumerate(lines) if "=" in l and l.split("=", 1)[0].strip().lower() == key.lower()), None)
            if val == "":
                if pos is not None:
                    del lines[pos]
                continue
            if pos is not None:
                lines[pos] = "%s = %s" % (key, val)
            else:
                last = max([i for i, l in enumerate(lines) if l.strip()] or [0])
                lines.insert(last + 1, "%s = %s" % (key, val))
    return conf_join(secs)


def conf_validate(text):
    """Базовая проверка + значения известных ключей. → список ошибок."""
    errs = check_conf(text)
    vals = {}
    peers = 0
    for name, lines in conf_sections(text):
        if name == "Peer":
            peers += 1
        for line in lines:
            if "=" not in line or line.strip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            fk = FIELD_BY_KEY.get((name, k.strip().lower()))
            if not fk:
                continue
            v = v.strip()
            if name == "Interface" or peers == 1:
                vals[fk[1]] = v
            if v == "" or (k.strip().lower() in SECRET_FIELDS and v == MASK):
                continue
            try:
                fk[2](v)
            except ValueError as ex:
                errs.append("%s: %s" % (fk[1], ex))
    if vals.get("Jmin", "").isdigit() and vals.get("Jmax", "").isdigit() and int(vals["Jmin"]) > int(vals["Jmax"]):
        errs.append("Jmin больше Jmax")
    if peers > 1:
        errs.append("в конфиге несколько [Peer]: для туннеля на роутере нужен один сервер")
    return errs


HISTD = os.path.join(DD, "history")
REV_RE = re.compile(r"^\d{8}-\d{6}(-\d+)?\.conf$")


def rev_key(f):
    m = re.match(r"^(\d{8}-\d{6})(?:-(\d+))?\.conf$", f)
    return (m.group(1), int(m.group(2) or 0)) if m else (f, 0)


def rev_dir(t):
    return os.path.join(HISTD, t)


def rev_save(t, text, why=""):
    """Сохранить версию конфига в историю (до 15 штук на туннель, права 600)."""
    if not text.strip():
        return ""
    d = rev_dir(t)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(HISTD, 0o700)
    lst = sorted((f for f in os.listdir(d) if REV_RE.match(f)), key=rev_key)
    if lst and read_file(os.path.join(d, lst[-1])) == text:
        return lst[-1]
    base = time.strftime("%Y%m%d-%H%M%S")
    name = base + ".conf"
    i = 1
    while os.path.exists(os.path.join(d, name)):
        name = "%s-%d.conf" % (base, i)
        i += 1
    write_secure(os.path.join(d, name), text)
    if why:
        write_secure(os.path.join(d, name + ".why"), why[:200])
    for old in lst[:-14]:
        for f in (old, old + ".why"):
            try:
                os.remove(os.path.join(d, f))
            except OSError:
                pass
    return name


def rev_list(t):
    d = rev_dir(t)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted((f for f in os.listdir(d) if REV_RE.match(f)), key=rev_key, reverse=True):
        p = os.path.join(d, f)
        out.append({"id": f, "time": int(os.stat(p).st_mtime), "why": read_file(p + ".why").strip(),
                    "summary": summary_of(read_file(p))})
    return out


def summary_of(text):
    f = conf_fields(text)["fields"]
    return {"endpoint": f["Peer"].get("Endpoint", ""), "address": f["Interface"].get("Address", ""), "proto": proto_of(text),
            "mtu": f["Interface"].get("MTU", "")}


def apply_conf_text(h, t, text, why):
    """Проверить, сохранить (с версией в истории), перезапустить туннель; при ошибке вернуть прежний. → ответ API."""
    cp = conf_path(t)
    with LOCK:
        old = read_file(cp)
        text = unmask_conf(text, old) if MASK in text else text.replace("\r", "")
        errs = conf_validate(text)
        if errs:
            raise ValueError("конфиг не принят: " + "; ".join(errs))
        if old.strip() == text.strip():
            return {"ok": True, "msg": "изменений нет", "unchanged": True}
        if old:
            rev_save(t, old, "до: " + why)
            write_secure(cp + ".prev", old)
        write_secure(cp, text)
        rc, out = run([os.path.join(DD, "up.sh"), t], timeout=60)
        if rc != 0 and old:
            write_secure(cp, old)
            run([os.path.join(DD, "up.sh"), t], timeout=60)
            h.act("conf-set-failed", {t: why})
            return {"ok": False, "msg": "туннель с новым конфигом не поднялся, возвращён прежний:\n" + out.strip()}
        rev_save(t, text, why)
        if svc_active("awg-self"):
            run(["systemctl", "restart", "awg-self"], timeout=30)   # адрес сервера туннеля — в исключениях awg-self
    h.act("conf-set", {t: why})
    hs = -1
    for _ in range(8):
        time.sleep(1)
        hs = hs_age(t)
        if 0 <= hs < 30:
            break
    return {"ok": True, "msg": out.strip() + ("\nhandshake: %d с назад" % hs if hs >= 0 else
                                               "\nhandshake пока нет: проверьте через несколько секунд (Тест)"), "handshake": hs}
