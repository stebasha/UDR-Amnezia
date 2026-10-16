# -*- coding: utf-8 -*-
"""Импорт туннелей: .conf, vpn://, JSON Amnezia."""
from .api import *  # noqa: F401,F403  (всё из предыдущих модулей)

# ======================================================================= импорт (.conf, vpn://, JSON Amnezia)
IMPORTS = {}
IMPORTS_LOCK = threading.Lock()


def _find_conf(o, depth=0):
    if depth > 6:
        return None
    if isinstance(o, str):
        s = o.strip()
        if s.startswith("{"):
            try:
                return _find_conf(json.loads(s), depth + 1)
            except ValueError:
                return None
        if "[Interface]" in s and "[Peer]" in s:
            return s
        return None
    if isinstance(o, dict):
        for k in ("config", "last_config"):
            if k in o:
                r = _find_conf(o[k], depth + 1)
                if r:
                    return r
        for v in o.values():
            r = _find_conf(v, depth + 1)
            if r:
                return r
    if isinstance(o, list):
        for v in o:
            r = _find_conf(v, depth + 1)
            if r:
                return r
    return None


def decode_import(data):
    """Текст конфига из .conf, ссылки vpn:// (AmneziaVPN) или JSON. → (текст, источник, предупреждения)."""
    s = str(data or "").strip().lstrip("﻿")
    warns = []
    if not s:
        raise ValueError("пусто: вставьте конфиг, ссылку vpn:// или выберите файл")
    if len(s) > 200000:
        raise ValueError("слишком большой текст")
    src = "conf"
    obj = None
    if s.lower().startswith("vpn://"):
        src = "vpn://"
        b = re.sub(r"\s", "", s[6:])
        b += "=" * (-len(b) % 4)
        try:
            raw = base64.urlsafe_b64decode(b)
        except (ValueError, TypeError):
            raise ValueError("ссылка vpn:// повреждена (не base64)")
        js = None
        for cand in (raw[4:], raw):
            try:
                # не больше 2 МБ после распаковки: сжатая «бомба» в 150 КБ иначе развернулась бы в сотни мегабайт памяти роутера
                z = zlib.decompressobj()
                js = z.decompress(cand, 2 * 1024 * 1024)
                if z.unconsumed_tail:
                    raise ValueError("ссылка vpn:// слишком большая после распаковки")
                break
            except zlib.error:
                continue
        if js is None:
            js = raw
        try:
            obj = json.loads(js.decode("utf-8"))
        except ValueError:
            raise ValueError("ссылка vpn:// не распознана: внутри не JSON AmneziaVPN")
    elif s.startswith("{"):
        src = "json"
        try:
            obj = json.loads(s)
        except ValueError:
            raise ValueError("неверный JSON")
    if obj is not None:
        text = _find_conf(obj)
        if not text:
            raise ValueError("в ссылке нет конфига AmneziaWG/WireGuard (возможно, это ключ для другого протокола — OpenVPN, XRay)")
        dns = [obj.get("dns1"), obj.get("dns2")] if isinstance(obj, dict) else [None, None]
        text = text.replace("$PRIMARY_DNS", dns[0] or "1.1.1.1").replace("$SECONDARY_DNS", dns[1] or "1.0.0.1")
        if isinstance(obj, dict) and obj.get("description"):
            warns.append("название в AmneziaVPN: %s" % str(obj.get("description"))[:60])
    else:
        text = s
    text = text.replace("\r", "").strip() + "\n"
    if re.search(r"\$[A-Z_]{3,}", text):
        warns.append("в конфиге остались подстановки вида $ИМЯ: проверьте строки")
    return text, src, warns


def import_put(user, text):
    tok = secrets.token_urlsafe(18)
    with IMPORTS_LOCK:
        for k in [k for k, v in IMPORTS.items() if now() - v["t"] > 900]:
            del IMPORTS[k]
        IMPORTS[tok] = {"t": now(), "user": user, "text": text}
    return tok


def import_get(user, tok):
    with IMPORTS_LOCK:
        x = IMPORTS.get(str(tok or ""))
        if not x or x["user"] != user or now() - x["t"] > 900:
            raise ValueError("загруженный конфиг устарел: загрузите его снова")
        return x["text"]


def api_import_parse(h, d):
    text, src, warns = decode_import(d.get("data", ""))
    errs = conf_validate(text)
    f = conf_fields(text)
    if f["peers"] == 0:
        errs.append("нет раздела [Peer]")
    e = env()
    ep = f["fields"]["Peer"].get("Endpoint", "")
    for t in tunnels(e):
        if ep and conf_get(read_file(conf_path(t, e)), "Endpoint") == ep:
            warns.append("этот сервер (%s) уже используется туннелем %s" % (ep.rsplit(":", 1)[0], t))
    tok = import_put(h.user, text) if not errs else ""
    h.act("import-parse", src)
    return {"ok": not errs, "token": tok, "source": src, "errors": errs, "warnings": warns, "text": mask_conf(text),
            "fields": f["fields"], "proto": proto_of(text), "other": f["other"]}


def api_import_apply(h, d):
    text = import_get(h.user, d.get("token"))
    target = str(d.get("target", ""))
    if target == "new":
        return api_tunnel_add(h, {"name": d.get("name"), "label": d.get("label"), "text": text})
    t = get_tunnel(target)
    r = apply_conf_text(h, t, text, "импорт")
    if d.get("label"):
        api_tunnel_label(h, {"name": t, "label": d.get("label")})
    return r
