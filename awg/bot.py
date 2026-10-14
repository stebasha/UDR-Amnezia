#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""awg-bot: Telegram-бот UDR-Amnezia с кнопками.

Меню кнопками (inline-клавиатура, сообщение обновляется на месте): состояние, каналы (сделать активным,
автовыбор, тест, скорость), события и статистика, проверки (диагностика, самопроверка, внешние IP, домен,
отчёт файлом), роутер (процессор, память, диск, температура, соединения), клиенты в туннеле, уведомления
(выключить на время), службы.

Доступ: TG_CHAT — администраторы (всё), TG_VIEWERS — только просмотр. Списки через пробел или запятую
в /data/awg/telegram.env. Чужим чатам бот отвечает только их chat id (раз в 10 минут), чтобы его было
легко добавить. Опасные действия (переключение, перезапуск) — с подтверждением.

Фоном: тревоги о роутере (место, память, процессор, температура, таблица соединений, часы), остановленные
службы, пропавшие подсети VPN-сервера, отклонённое ручное переключение, недельный отчёт.
Уведомления о переключениях каналов шлёт awg-notify (notify.sh), с теми же получателями.

    bot.py               запуск (служба awg-bot)
    bot.py --once-from F обработать готовый ответ getUpdates из файла (тесты; ответы печатаются)
"""
import collections
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

DD = os.environ.get("DD", "/data/awg")
sys.path.insert(0, os.path.join(DD, "web"))
import panel as P  # noqa: E402  (общие функции с веб-панелью)

LOGF = os.path.join(DD, "bot.log")
OFFF = os.path.join(DD, "bot.offset")
MUTEF = os.path.join(DD, "bot.mute")
TEST = {"on": False, "out": []}
H = P.socket.gethostname()


def log(msg):
    line = "%s %s\n" % (time.strftime("%F %T"), msg)
    try:
        with open(LOGF, "a", encoding="utf-8") as f:
            f.write(line)
        if os.path.getsize(LOGF) > 256 * 1024:
            lines = P.read_file(LOGF).splitlines()[-1500:]
            P.write_secure(LOGF, "\n".join(lines) + "\n", 0o600)
    except OSError:
        pass
    if TEST["on"]:
        sys.stderr.write(line)


def ids(s):
    out = []
    for x in re.split(r"[\s,;]+", s or ""):
        x = re.sub(r"[^0-9-]", "", x)
        if x and x not in out:
            out.append(x)
    return out


def cfg():
    t = P.parse_env_text(P.read_file(os.path.join(DD, "telegram.env")))
    admins = ids(t.get("TG_CHAT", ""))
    viewers = [x for x in ids(t.get("TG_VIEWERS", "")) if x not in admins]
    return {"token": t.get("TG_TOKEN", ""), "admins": admins, "viewers": viewers, "no_wan": t.get("TG_NO_WAN", "0") == "1",
            "report_time": t.get("REPORT_TIME", "0900"), "disk_mb": int(t.get("BOT_DISK_MB", "300") or 300)}


C = cfg()


def esc(s):
    return html.escape(str(s), quote=False)


# ======================================================================= Telegram API через curl
class TG:
    """Запросы идут через туннели, затем напрямую (как у notify.sh): Telegram из РФ напрямую часто недоступен."""

    def __init__(self):
        self.good = None

    def ifaces(self):
        e = P.env()
        lst = P.tunnels(e)
        st = P.state().get("ACTIVE")
        if st in lst:
            lst = [st] + [x for x in lst if x != st]
        if not C["no_wan"]:
            lst.append("")
        if self.good in lst:
            lst = [self.good] + [x for x in lst if x != self.good]
        return lst

    def call(self, method, params=None, doc=None, timeout=35):
        if TEST["on"]:
            TEST["out"].append((method, params or {}, doc))
            return {"message_id": 1} if method.startswith("send") else True
        cfgline = 'url = "https://api.telegram.org/bot%s/%s"\n' % (C["token"], method)
        tmp = None
        try:
            for i in self.ifaces():
                cmd = ["curl", "-4", "-s", "-m", str(timeout + 5), "-K", "-"]
                if i:
                    cmd += ["--interface", i]
                if doc:
                    cmd += ["-F", "document=@%s" % doc]
                    for k, v in (params or {}).items():
                        # --form-string: значение, начинающееся с @ или <, curl иначе понял бы как имя файла для отправки
                        cmd += ["--form-string", "%s=%s" % (k, v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))]
                else:
                    if tmp is None:
                        fd, tmp = tempfile.mkstemp(prefix=".bot-", dir=DD)
                        with os.fdopen(fd, "w", encoding="utf-8") as f:
                            json.dump(params or {}, f, ensure_ascii=False)
                    cmd += ["-H", "Content-Type: application/json", "--data-binary", "@" + tmp]
                try:
                    p = subprocess.run(cmd, input=cfgline.encode(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout + 10)
                except subprocess.TimeoutExpired:
                    continue
                if not p.stdout:
                    continue
                try:
                    r = json.loads(p.stdout.decode("utf-8", "replace"))
                except ValueError:
                    continue
                self.good = i
                if not r.get("ok"):
                    if "message is not modified" not in str(r.get("description", "")):
                        log("API %s: %s" % (method, r.get("description", "")[:200]))
                    return None
                return r.get("result")
            return None
        finally:
            if tmp:
                try:
                    os.remove(tmp)
                except OSError:
                    pass


TGAPI = TG()


def kb(rows):
    return {"inline_keyboard": [[{"text": t, "callback_data": d} for t, d in row] for row in rows if row]}


def send(chat, text, rows=None, pre=False):
    if pre:
        text = "<pre>%s</pre>" % esc(text)
    p = {"chat_id": chat, "text": text[:4090], "parse_mode": "HTML", "disable_web_page_preview": True}
    if rows:
        p["reply_markup"] = kb(rows)
    return TGAPI.call("sendMessage", p)


def edit(chat, mid, text, rows=None):
    p = {"chat_id": chat, "message_id": mid, "text": text[:4090], "parse_mode": "HTML", "disable_web_page_preview": True}
    if rows:
        p["reply_markup"] = kb(rows)
    if TGAPI.call("editMessageText", p) is None:
        send(chat, text, rows)


def send_long(chat, title, text, rows=None):
    """Длинный вывод: до ~3500 символов — сообщением, длиннее — файлом."""
    text = P.ANSI.sub("", text).strip() or "(пусто)"
    if len(text) <= 3500:
        return send(chat, "<b>%s</b>\n<pre>%s</pre>" % (esc(title), esc(text)), rows)
    fd, path = tempfile.mkstemp(prefix="awg-", suffix=".txt", dir="/tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    try:
        TGAPI.call("sendDocument", {"chat_id": chat, "caption": title[:200]}, doc=path, timeout=60)
    finally:
        os.remove(path)
    if rows:
        send(chat, "<b>%s</b>: вывод во вложении" % esc(title), rows)


# ======================================================================= права, состояние чатов
def role(chat):
    chat = str(chat)
    if chat in C["admins"]:
        return "admin"
    if chat in C["viewers"]:
        return "viewer"
    return None


class Act:
    """Обёртка для функций панели: действия пишутся в журнал панели от имени чата."""

    def __init__(self, chat):
        self.user = "telegram:%s" % chat

    def act(self, a, d=""):
        P.audit(self.user, "telegram", a, d)


WAIT = {}             # chat → ожидаемый ввод ("domain", время)
DENIED = {}           # chat → когда отвечали «нет доступа»
LAST = collections.defaultdict(float)


def mutes():
    out = {}
    for line in P.read_file(MUTEF).splitlines():
        p = line.split()
        if len(p) == 2 and p[1].isdigit() and int(p[1]) > P.now():
            out[p[0]] = int(p[1])
    return out


def set_mute(chat, until):
    m = mutes()
    if until:
        m[str(chat)] = until
    else:
        m.pop(str(chat), None)
    P.write_secure(MUTEF, "".join("%s %d\n" % kv for kv in m.items()), 0o600)


# ======================================================================= экраны
def fa(s):
    s = int(s)
    if s < 0:
        return "нет"
    if s < 90:
        return "%d с" % s
    if s < 5400:
        return "%d мин" % (s // 60)
    return "%d ч" % (s // 3600)


def fbytes(b):
    b = float(b or 0)
    for u in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if b < 1024 or u == "ТБ":
            return ("%d %s" if u == "Б" else "%.1f %s") % (b, u)
        b /= 1024


LV = {"ok": "🟢", "warn": "🟡", "crit": "🔴", "info": "🔵"}


def scr_main(chat):
    ov = P.overview()
    st = {"ok": "🟢 <b>Работает</b>", "warn": "🟡 <b>Внимание</b>", "crit": "🔴 <b>Проблема</b>"}[ov["level"]]
    lines = ["%s · %s" % (st, esc(ov["host"]))]
    act = next((t for t in ov["tunnels"] if t["active"]), None)
    if act:
        lab = act["label"] or {"main": "основной", "backup": "запасной", "extra": "дополнительный"}[act["role"]]
        lines.append("🔐 Канал: <b>%s</b> (%s) · %s" % (esc(act["name"]), esc(lab), "вручную" if ov["forced"] else "авто"))
        q = []
        if act["handshake"] >= 0:
            q.append("handshake %s" % fa(act["handshake"]))
        if act["rtt"] not in ("", "0"):
            q.append("RTT %s мс" % act["rtt"])
        if act["loss"] != "" and (act.get("qm") == "tcp" or act["loss"] != "100"):
            q.append("потери %s%%" % act["loss"])
        if q:
            lines.append("⏱ " + " · ".join(q))
    else:
        lines.append("⛔ Активного канала нет: трафик PBR заблокирован (утечки нет)")
    for t in ov["tunnels"]:
        if t["active"]:
            continue
        s = {"standby": "готов", "nohs": "нет handshake", "down": "выключен", "active": "активен"}[t["status"]]
        lines.append("%s %s — %s%s" % ("🛟" if t["role"] == "backup" else "➕", esc(t["label"] or t["name"]), s,
                                       " (%s)" % fa(t["handshake"]) if t["handshake"] >= 0 else ""))
    sy = ov.get("sys") or {}
    lines.append("🖥 CPU %s%% · RAM %s%%%s · /data %s МБ" % (int(sy.get("cpu") or 0), int(sy.get("mem_pct") or 0),
                 " · %d°C" % sy["temp"] if sy.get("temp") else "", ov.get("data_free_mb", "?")))
    real = [a for a in ov["alerts"] if a[0] != "info"]
    if real:
        lines.append("")
        lines += ["%s %s" % (LV.get(a[0], "•"), esc(a[1])) for a in real[:5]]
    lines.append("\n<i>обновлено %s</i>" % time.strftime("%H:%M:%S"))
    rows = [[("🔄 Обновить", "m:main"), ("🔀 Каналы", "m:tun")], [("📜 События", "m:ev"), ("📈 Статистика", "m:stats")],
            [("🩺 Проверки", "m:chk"), ("🖥 Роутер", "m:sys")], [("👥 Клиенты", "m:cl"), ("🔔 Уведомления", "m:mute")]]
    rl = routes_list()
    if rl:
        bad = [r["id"] for r in rl if not (r["service"] == "active" and r["active"])]
        lines.insert(-1, "🧭 Маршруты: %d%s" % (len(rl), " · 🔴 без канала: " + esc(", ".join(bad)) if bad else " · все работают"))
        rows.insert(2, [("🧭 Маршруты", "m:rt")])
    if role(chat) == "admin":
        rows.append([("⚙️ Службы", "m:svc"), ("❓ Помощь", "m:help")])
    else:
        rows.append([("❓ Помощь", "m:help")])
    return "\n".join(lines), rows


def scr_tun(chat):
    ov = P.overview()
    lines = ["<b>🔀 Каналы</b> · порядок: основной → запасной → дополнительные", ""]
    rows = []
    for t in ov["tunnels"]:
        mark = "✅" if t["active"] else {"standby": "⚪", "nohs": "🟡", "down": "🔴"}.get(t["status"], "⚪")
        lines.append("%s <b>%s</b>%s — %s, handshake %s" % (mark, esc(t["name"]), " (%s)" % esc(t["label"]) if t["label"] else "",
                     {"main": "основной", "backup": "запасной", "extra": "доп."}[t["role"]], fa(t["handshake"])))
        rows.append([("%s %s" % (mark, t["label"] or t["name"]), "t:" + t["name"])])
    if ov["forced"]:
        lines.append("\n✋ Выбран вручную: <b>%s</b>" % esc(ov["forced"]))
        if role(chat) == "admin":
            rows.append([("🤖 Вернуть автовыбор", "auto")])
    rows.append([("⬅️ Назад", "m:main")])
    return "\n".join(lines), rows


def scr_tunnel(chat, name):
    ov = P.overview()
    t = next((x for x in ov["tunnels"] if x["name"] == name), None)
    if not t:
        return "Туннеля %s нет" % esc(name), [[("⬅️ Каналы", "m:tun")]]
    port = t["endpoint"].rsplit(":", 1)[-1] if t["endpoint"] else "—"
    lines = ["<b>%s</b>%s" % (esc(t["name"]), " · " + esc(t["label"]) if t["label"] else ""),
             "Роль: %s · протокол %s" % ({"main": "основной", "backup": "запасной", "extra": "дополнительный"}[t["role"]], t["proto"]),
             "Состояние: %s" % {"active": "✅ активен", "standby": "⚪ резерв, готов", "nohs": "🟡 нет handshake", "down": "🔴 выключен"}[t["status"]],
             "Handshake: %s" % fa(t["handshake"]),
             "RTT / потери: %s мс / %s%%%s" % (t["rtt"] or "—", t["loss"] or "—", " (TCP)" if t.get("qm") == "tcp" else ""),
             "DNS через туннель: %s" % {"1": "работает", "0": "нет ответа"}.get(t["dns"], "—"),
             "Порт сервера: %s · MTU %s" % (port, t["mtu"] or "—"),
             "Трафик: ↓ %s · ↑ %s" % (fbytes(t["rx"]), fbytes(t["tx"]))]
    rows = [[("🧪 Тест", "test:" + name)]]
    if role(chat) == "admin":
        if not t["active"] and t["status"] != "down":
            rows[0].insert(0, ("🔀 Сделать активным", "swq:" + name))
        rows.append([("⚡ Скорость", "spd:" + name), ("♻️ Перезапустить", "rsq:" + name)])
    rows.append([("⬅️ Каналы", "m:tun"), ("🏠 Меню", "m:main")])
    return "\n".join(lines), rows


def routes_list():
    try:
        return P.routes_brief(extra_only=True)
    except Exception as ex:
        log("маршруты: %r" % ex)
        return []


def scr_routes(chat):
    """Дополнительные маршруты (#22, #40): у каждого свой профиль PBR, своя цепочка туннелей и свой сторож."""
    rl = routes_list()
    if not rl:
        return ("<b>🧭 Маршруты</b>\nДополнительных маршрутов нет. Их создают в веб-панели: Настройки → Маршруты."
                , [[("⬅️ Назад", "m:main")]])
    lines = ["<b>🧭 Маршруты</b>", ""]
    rows = []
    for r in rl:
        ok = r["service"] == "active" and r["active"]
        lines.append("%s <b>%s</b>%s — %s%s" % ("🟢" if ok else "🔴", esc(r["id"]), " (%s)" % esc(r["label"]) if r["label"] else "",
                     "канал <b>%s</b>" % esc(r["active"]) if r["active"] else "нет рабочего канала (kill switch)",
                     ", вручную" if r["forced"] else ""))
        rows.append([("%s %s" % ("🟢" if ok else "🔴", r["label"] or r["id"]), "r:" + r["id"])])
    rows.append([("🔄 Обновить", "m:rt"), ("⬅️ Назад", "m:main")])
    return "\n".join(lines), rows


def scr_route(chat, rid):
    r = next((x for x in routes_list() if x["id"] == rid), None)
    if not r:
        return "Маршрута %s нет" % esc(rid), [[("⬅️ Маршруты", "m:rt")]]
    tl = {t["name"]: t for t in P.overview()["tunnels"]}
    lines = ["<b>🧭 %s</b>%s" % (esc(r["id"]), " · " + esc(r["label"]) if r["label"] else ""),
             "Профиль UniFi: %s · таблица %s" % (esc(r["rail"]), esc(r["table"])),
             "Сторож: %s · %s" % ("работает" if r["service"] == "active" else "🔴 " + esc(r["service"]),
                                  "вручную: " + esc(r["forced"]) if r["forced"] else "автовыбор"), ""]
    rows = []
    for i, n in enumerate(r["tunnels"]):
        t = tl.get(n, {})
        mark = "✅" if n == r["active"] else {"standby": "⚪", "active": "⚪", "nohs": "🟡", "down": "🔴"}.get(t.get("status"), "⚪")
        lines.append("%s %d. %s — handshake %s" % (mark, i + 1, esc(n), fa(t.get("handshake", -1))))
        if role(chat) == "admin" and n != r["active"] and t.get("status") not in (None, "down"):
            rows.append([("🔀 %s" % n, "rtq:%s:%s" % (rid, n))])
    if role(chat) == "admin" and r["forced"]:
        rows.append([("🤖 Вернуть автовыбор", "rtw:%s:auto" % rid)])
    rows.append([("⬅️ Маршруты", "m:rt"), ("🏠 Меню", "m:main")])
    return "\n".join(lines), rows


def do_route_switch(chat, rid, t):
    try:
        r = P.api_route_switch(Act(chat), {"id": rid, "tunnel": t})
        return ("✅ " if r["ok"] else "⚠️ ") + esc(r["msg"])
    except Exception as ex:
        return "⚠️ " + esc(ex)


def ev_line(e):
    m = {"start": "▶️", "stop": "⏹", "switch": "🔀", "degrade": "📉", "return": "✅", "force": "✋", "auto": "🤖",
         "both": "🛑", "refused": "⚠️", "drift": "⚠️", "reboot": "🔁", "firmware": "🔄", "backup": "💾", "vps": "🖥", "tune": "🛡", "lists": "📋"}.get(e["type"], "•")
    return "%s <code>%s</code> %s" % (m, time.strftime("%d.%m %H:%M", time.localtime(e["t"])), esc(e["text"]))


def scr_ev(chat):
    ev = P.events(14)[::-1]
    lines = ["<b>📜 События</b>", ""] + ([ev_line(e) for e in ev] or ["событий нет"])
    return "\n".join(lines), [[("📈 Статистика", "m:stats"), ("🔄", "m:ev")], [("⬅️ Назад", "m:main")]]


def scr_stats(chat):
    out = ["<b>📈 Статистика</b>"]
    for d in (1, 7, 30):
        s = P.stats_from_events(d)
        out.append("\n<b>%s</b>: на основном %s%%, вне основного %s\nпереключений %d · по качеству %d · вручную %d · все лежали %d · запусков %d" % (
            {1: "Сутки", 7: "7 дней", 30: "30 дней"}[d], s["on_main_pct"], fa(s["off_main_sec"]), s["switch"], s["degrade"], s["force"], s["both"], s["start"]))
    return "\n".join(out), [[("📅 Отчёт за неделю", "m:wk"), ("📜 События", "m:ev")], [("⬅️ Назад", "m:main")]]


def scr_report(chat, days=7):
    """Отчёт (#41): каналы, скорость, маршруты, трафик по устройствам."""
    try:
        txt = P.report_text(P.report_data(days))
    except Exception as ex:
        log("отчёт: %r" % ex)
        txt = "не удалось собрать отчёт: %s" % ex
    return ("<b>📅 %s</b>\n<pre>%s</pre>" % ("Неделя" if days == 7 else "30 дней", esc(txt)),
            [[("7 дней", "m:wk"), ("30 дней", "m:wk30")], [("📈 Статистика", "m:stats"), ("🏠 Меню", "m:main")]])


def scr_chk(chat):
    rows = [[("🩺 Диагностика", "run:diag"), ("✅ Самопроверка", "run:self")],
            [("🌐 Внешние IP", "run:ip"), ("🔎 Проверить сайт", "dom")]]
    if role(chat) == "admin":
        rows.append([("⚡ Скорость каналов", "spd:all"), ("📄 Отчёт файлом", "run:report")])
        rows.append([("🧭 Сверка правил", "run:drift")])
    rows.append([("⬅️ Назад", "m:main")])
    return ("<b>🩺 Проверки</b>\nДиагностика ищет первую причину неисправности и подсказывает команду. "
            "«Проверить сайт» покажет, идёт ли он через туннель и открывается ли напрямую."), rows


def scr_sys(chat):
    h = P.system_health()
    m = h["mem"]
    lines = ["<b>🖥 Роутер</b> · %s" % esc(h["model"]),
             "Процессор: %s%% · нагрузка %s (ядер %d)" % (int(h["cpu"]), " ".join("%.2f" % x for x in h["load"]), h["cores"]),
             "Память: %s%% (свободно %d МБ из %d)" % (m["used_pct"], m["avail_mb"], m["total_mb"])]
    if h["temps"]:
        lines.append("Температура: " + ", ".join("%s %d°C" % (esc(t["name"]), t["c"]) for t in h["temps"][:4]))
    for d in h["disks"]:
        lines.append("Диск %s: свободно %d МБ (%s%% занято)" % (d["path"], d["free_mb"], d["used_pct"]))
    if h["conntrack"]["max"] > 0:
        lines.append("Соединений: %d из %d" % (h["conntrack"]["count"], h["conntrack"]["max"]))
    lines.append("Работает без перезагрузки: %s" % fa(h["uptime"]).replace("мин", "мин"))
    bad = [c for c in h["checks"] if c["level"] in ("warn", "crit")]
    lines.append("")
    if bad:
        for c in bad:
            lines.append("%s %s%s" % (LV[c["level"]], esc(c["text"]), "\n   ↳ " + esc(c["advice"]) if c["advice"] else ""))
    else:
        lines.append("🟢 Замечаний нет")
    top = ", ".join("%s %d МБ" % (esc(p["name"]), p["rss_mb"]) for p in h["procs"][:4])
    lines.append("\n<i>Больше всего памяти: %s</i>" % top)
    return "\n".join(lines), [[("🔄 Обновить", "m:sys")], [("⬅️ Назад", "m:main")]]


def scr_cl(chat):
    c = P.clients()
    lines = ["<b>👥 Клиенты в туннеле</b> · %d устр., %d соединений" % (len(c["clients"]), c["total"]), ""]
    for x in c["clients"][:12]:
        lines.append("• <b>%s</b> <code>%s</code> → %s · %d соед." % (esc(x["name"] or "без имени"), x["ip"], esc(x["tunnel"]), x["conns"]))
    if not c["clients"]:
        lines.append("сейчас через туннель никто не ходит")
    return "\n".join(lines), [[("🔄 Обновить", "m:cl")], [("⬅️ Назад", "m:main")]]


def scr_mute(chat):
    m = mutes().get(str(chat))
    txt = "<b>🔔 Уведомления</b>\nСюда приходят: переключения и возвраты каналов, полная потеря каналов (🛑 — всегда, даже без звука), " \
          "проблемы роутера и служб, ежедневный и недельный отчёты.\n\n"
    txt += ("🔕 Выключены до %s" % time.strftime("%d.%m %H:%M", time.localtime(m))) if m else "🔔 Включены"
    return txt, [[("🔕 1 час", "mute:3600"), ("🔕 8 часов", "mute:28800"), ("🔕 сутки", "mute:86400")],
                 [("🔔 Включить", "mute:0")], [("⬅️ Назад", "m:main")]]


def scr_svc(chat):
    lines = ["<b>⚙️ Службы</b>", ""]
    rows = []
    for u in P.SERVICES:
        if not (P.svc_installed(u) or u == "awg-failover"):
            continue
        a = P.svc_active(u)
        lines.append("%s <b>%s</b> — %s" % ("🟢" if a else "🔴", u, esc(P.SERVICE_INFO[u])))
        rows.append([("♻️ %s" % u.replace("awg-", ""), "svq:" + u)])
    rows = [sum(rows[i:i + 2], []) for i in range(0, len(rows), 2)]
    rows.append([("⬅️ Назад", "m:main")])
    return "\n".join(lines), rows


HELP = ("<b>❓ Команды</b>\n/menu — меню кнопками\n/status — состояние\n/tunnels — каналы\n/router — роутер\n/events — события\n"
        "/clients — клиенты в туннеле\n/week — отчёт за неделю (/week 30 — за 30 дней)\n/routes — дополнительные маршруты\n/domain сайт — проверить сайт\n/switch имя — сделать канал активным\n/auto — вернуть автовыбор\n"
        "/route ID канал|auto — канал маршрута\n/report — отчёт файлом\n/id — chat id\n\nДобавить людей: веб-панель → Настройки → Telegram (администраторы и «только просмотр»).")

SCREENS = {"main": scr_main, "tun": scr_tun, "ev": scr_ev, "stats": scr_stats, "chk": scr_chk, "sys": scr_sys, "cl": scr_cl,
           "mute": scr_mute, "svc": scr_svc, "rt": scr_routes,
           "wk": scr_report, "wk30": lambda c: scr_report(c, 30), "help": lambda c: (HELP, [[("⬅️ Назад", "m:main")]])}
ADMIN_ONLY = ("svc",)


# ======================================================================= действия
JOBS = set()
JOBS_LOCK = threading.Lock()
JOBS_MAX = 2          # тяжёлые проверки (диагностика, отчёт, замер) нагружают роутер: не больше двух сразу


def run_job(chat, kind, arg=""):
    """Долгие проверки — в фоне, результат отдельным сообщением.
    Одна и та же проверка не запускается повторно, пока идёт прежняя; всего не больше JOBS_MAX сразу:
    частые нажатия кнопок не должны размножать diagnose.sh и curl на роутере."""
    if kind == "test" and arg not in P.tunnels(P.env()):
        send(chat, "Туннеля %s нет" % esc(arg))
        return
    key = (kind, arg)
    with JOBS_LOCK:
        if key in JOBS:
            send(chat, "⏳ Эта проверка уже выполняется — дождитесь результата")
            return
        if len(JOBS) >= JOBS_MAX:
            send(chat, "⏳ Уже идут другие проверки — повторите через минуту")
            return
        JOBS.add(key)

    def go():
        try:
            work()
        finally:
            with JOBS_LOCK:
                JOBS.discard(key)

    def work():
        try:
            if kind == "diag":
                rc, out = P.run([os.path.join(DD, "diagnose.sh")], timeout=300)
                send_long(chat, "🩺 Диагностика", out, [[("🏠 Меню", "m:main")]])
            elif kind == "self":
                rc, out = P.run([os.path.join(DD, "selftest.sh")], timeout=300)
                keep = [l for l in out.splitlines() if re.match(r"^\s*(WARN|FAIL|Итог)", l) or "что делать" in l]
                send_long(chat, "✅ Самопроверка", "\n".join(keep) or "все проверки пройдены", [[("🏠 Меню", "m:main")]])
            elif kind == "ip":
                rc, out = P.run([os.path.join(DD, "awgctl.sh"), "ip"], timeout=60)
                send_long(chat, "🌐 Внешние IP", out, [[("🏠 Меню", "m:main")]])
            elif kind == "drift":
                rc, out = P.run([os.path.join(DD, "drift.sh")], timeout=120)
                send_long(chat, "🧭 Сверка правил", out, [[("🏠 Меню", "m:main")]])
            elif kind == "domain":
                rc, out = P.run([os.path.join(DD, "domain-check.sh"), arg], timeout=120)
                send_long(chat, "🔎 " + arg, out, [[("🔎 Ещё сайт", "dom"), ("🏠 Меню", "m:main")]])
            elif kind == "test":
                r = P.tunnel_test(arg)
                ok = "✅ Канал работает" if r["ok"] else "🔴 Канал не пропускает трафик"
                lines = [ok, "handshake: %s" % fa(r["handshake"])]
                lines += ["HTTPS %s: %s" % (x["target"], "%d мс" % x["ms"] if x["ok"] else "нет") for x in r["https"]]
                lines += ["DNS через туннель: %s" % ("да" if r["dns"] else "нет"), "внешний IP: %s" % (r["ip"] or "не получен"),
                          "MTU: %s" % {"ok": "проходит", "fail": "не проходит — подберите MTU", "": "—"}[r["mtu"]]]
                send(chat, "<b>🧪 Тест %s</b>\n%s" % (esc(arg), esc("\n".join(lines))), [[("⬅️ " + arg, "t:" + arg), ("🏠 Меню", "m:main")]])
            elif kind == "speed":
                e = P.env()
                lst = P.tunnels(e) + [P.wan_if(e) or "eth3"] if arg == "all" else [arg]
                lst = [i for i in lst if P.link_exists(i)]
                out = "".join(P.speed_steps(lst, 10))
                send_long(chat, "⚡ Скорость (10 МБ)", out, [[("🏠 Меню", "m:main")]])
            elif kind == "report":
                rc, out = P.run([os.path.join(DD, "report.sh")], timeout=300)
                m = re.search(r"(/tmp/awg-report-\d{8}-\d{6}\.txt)", out)
                if m:
                    TGAPI.call("sendDocument", {"chat_id": chat, "caption": "Отчёт UDR-Amnezia (ключи, токены и публичные IP скрыты)"}, doc=m.group(1), timeout=90)
                else:
                    send_long(chat, "📄 Отчёт", out)
        except Exception as ex:   # действие не должно ронять бота
            log("ошибка %s: %r" % (kind, ex))
            send(chat, "⚠️ Ошибка: %s" % esc(ex))
    threading.Thread(target=go, daemon=True).start()


def do_switch(chat, name):
    try:
        r = P.api_tunnel_switch(Act(chat), {"name": name})
        return ("✅ " if r["ok"] else "⚠️ ") + esc(r["msg"])
    except Exception as ex:
        return "⚠️ " + esc(ex)


def screen(chat, key):
    if key in ADMIN_ONLY and role(chat) != "admin":
        return "⛔ Только для администраторов", [[("⬅️ Назад", "m:main")]]
    return SCREENS.get(key, scr_main)(chat)


def on_callback(q):
    chat = str(((q.get("message") or {}).get("chat") or {}).get("id", ""))
    mid = (q.get("message") or {}).get("message_id")
    data = str(q.get("data", ""))
    r = role(chat)
    TGAPI.call("answerCallbackQuery", {"callback_query_id": q.get("id")}, timeout=10)
    if not r:
        log("кнопка из чужого чата %s" % chat)
        return
    admin = r == "admin"
    log("кнопка %s: %s" % (chat, data))
    k, _, arg = data.partition(":")
    if k == "m":
        edit(chat, mid, *screen(chat, arg))
    elif k == "t":
        edit(chat, mid, *scr_tunnel(chat, arg))
    elif k == "r":
        edit(chat, mid, *scr_route(chat, arg))
    elif k == "test":
        edit(chat, mid, "⏳ Проверяю %s: HTTPS, DNS, внешний IP, MTU…" % esc(arg), [[("⬅️ " + arg, "t:" + arg)]])
        run_job(chat, "test", arg)
    elif k == "run" and arg in ("diag", "self", "ip", "drift") or (k == "run" and arg == "report" and admin):
        names = {"diag": "диагностика", "self": "самопроверка", "ip": "внешние IP", "drift": "сверка правил", "report": "отчёт"}
        send(chat, "⏳ %s… (до минуты)" % names[arg].capitalize())
        run_job(chat, {"diag": "diag", "self": "self", "ip": "ip", "drift": "drift", "report": "report"}[arg])
    elif k == "dom":
        WAIT[chat] = ("domain", time.time())
        send(chat, "🔎 Пришлите адрес сайта, например <code>youtube.com</code>")
    elif k == "mute":
        sec = int(arg) if arg.isdigit() else 0
        set_mute(chat, P.now() + sec if sec else 0)
        edit(chat, mid, *scr_mute(chat))
    elif not admin:
        send(chat, "⛔ Это действие доступно только администраторам")
    elif k == "swq":
        edit(chat, mid, "Сделать <b>%s</b> активным каналом? Сторож не будет возвращаться на основной, пока вы не включите автовыбор." % esc(arg),
             [[("✅ Да, переключить", "sw:" + arg), ("✖️ Отмена", "t:" + arg)]])
    elif k == "sw":
        edit(chat, mid, "⏳ Переключаю на %s…" % esc(arg))
        edit(chat, mid, do_switch(chat, arg), [[("🔀 Каналы", "m:tun"), ("🏠 Меню", "m:main")]])
    elif k == "auto":
        r2 = P.api_tunnel_auto(Act(chat), {})
        edit(chat, mid, "🤖 " + esc(r2["msg"]), [[("🔀 Каналы", "m:tun"), ("🏠 Меню", "m:main")]])
    elif k == "tap" and arg.count(":") == 1:
        t, _, n = arg.partition(":")
        edit(chat, mid, "⏳ Ставлю набор №%s на %s…" % (esc(n), esc(t)))
        try:
            r2 = P.autotune_apply(Act(chat), t, int(n) if n.isdigit() else -1)
            edit(chat, mid, ("✅ " if r2.get("ok") else "⚠️ ") + esc(r2.get("msg", "")), [[("⬅️ " + t, "t:" + t), ("🏠 Меню", "m:main")]])
        except Exception as ex:
            edit(chat, mid, "⚠️ " + esc(ex), [[("🏠 Меню", "m:main")]])
    elif k == "rtq" and arg.count(":") == 1:
        rid, _, t = arg.partition(":")
        edit(chat, mid, "Маршрут <b>%s</b>: сделать <b>%s</b> активным каналом? Сторож маршрута не будет возвращаться на первый, пока вы не включите автовыбор." % (esc(rid), esc(t)),
             [[("✅ Да, переключить", "rtw:%s:%s" % (rid, t)), ("✖️ Отмена", "r:" + rid)]])
    elif k == "rtw" and arg.count(":") == 1:
        rid, _, t = arg.partition(":")
        edit(chat, mid, "⏳ Маршрут %s → %s…" % (esc(rid), esc(t)))
        edit(chat, mid, do_route_switch(chat, rid, t), [[("⬅️ " + rid, "r:" + rid), ("🧭 Маршруты", "m:rt")]])
    elif k == "rsq":
        edit(chat, mid, "Перезапустить туннель <b>%s</b>? Несколько секунд трафик через него не идёт." % esc(arg),
             [[("♻️ Да", "rs:" + arg), ("✖️ Отмена", "t:" + arg)]])
    elif k == "rs":
        try:
            r2 = P.api_tunnel_restart(Act(chat), {"name": arg})
            edit(chat, mid, ("✅ " if r2["ok"] else "⚠️ ") + esc(r2["msg"] or "готово"), [[("⬅️ " + arg, "t:" + arg)]])
        except Exception as ex:
            edit(chat, mid, "⚠️ " + esc(ex), [[("⬅️ Назад", "m:tun")]])
    elif k == "spd":
        send(chat, "⏳ Замер скорости %s… (до 2 минут, расходует ~15 МБ на канал)" % ("всех каналов" if arg == "all" else esc(arg)))
        run_job(chat, "speed", arg)
    elif k == "svq":
        edit(chat, mid, "Перезапустить службу <b>%s</b>?" % esc(arg), [[("♻️ Да", "sv:" + arg), ("✖️ Отмена", "m:svc")]])
    elif k == "sv" and arg in P.SERVICES:
        if arg == "awg-bot":
            edit(chat, mid, "♻️ Перезапускаю бота…")
            P.run(["systemctl", "--no-block", "restart", "awg-bot"])
            return
        try:
            r2 = P.api_service(Act(chat), {"name": arg, "action": "restart"})
            edit(chat, mid, ("✅ " if r2["ok"] else "⚠️ ") + esc(r2["msg"]), [[("⚙️ Службы", "m:svc"), ("🏠 Меню", "m:main")]])
        except Exception as ex:
            edit(chat, mid, "⚠️ " + esc(ex), [[("⚙️ Службы", "m:svc")]])


def on_message(m):
    chat = str((m.get("chat") or {}).get("id", ""))
    text = (m.get("text") or "").strip()
    if not chat:
        return
    r = role(chat)
    if not r:
        if text.startswith("/") and time.time() - DENIED.get(chat, 0) > 600:
            DENIED[chat] = time.time()
            send(chat, "⛔ Нет доступа. Ваш chat id: <code>%s</code>\nАдминистратор может добавить его в веб-панели: Настройки → Telegram." % chat)
        log("игнорирую чужой чат %s" % chat)
        return
    if time.time() - LAST[chat] < 0.7 and not TEST["on"]:   # защита от дребезга; в тестах сообщения идут подряд
        return
    LAST[chat] = time.time()
    w = WAIT.pop(chat, None)
    if w and w[0] == "domain" and not text.startswith("/") and time.time() - w[1] < 300:
        return cmd_domain(chat, text)
    cmd, _, arg = text.partition(" ")
    cmd = cmd.split("@")[0].lower()
    arg = arg.strip()
    log("команда %s: %s" % (chat, cmd))
    admin = r == "admin"
    if cmd in ("/start", "/menu", "/status", "/s"):
        send(chat, *scr_main(chat))
    elif cmd in ("/tunnels", "/channels"):
        send(chat, *scr_tun(chat))
    elif cmd in ("/router", "/sys"):
        send(chat, *scr_sys(chat))
    elif cmd == "/events":
        send(chat, *scr_ev(chat))
    elif cmd == "/stats":
        send(chat, *scr_stats(chat))
    elif cmd == "/clients":
        send(chat, *scr_cl(chat))
    elif cmd in ("/week", "/weekly"):
        send(chat, *scr_report(chat, 30 if arg == "30" else 7))
    elif cmd == "/routes":
        send(chat, *scr_routes(chat))
    elif cmd == "/help":
        send(chat, HELP)
    elif cmd == "/id":
        send(chat, "Ваш chat id: <code>%s</code> · роль: %s" % (chat, "администратор" if admin else "просмотр"))
    elif cmd in ("/domain", "/check"):
        if arg:
            cmd_domain(chat, arg)
        else:
            WAIT[chat] = ("domain", time.time())
            send(chat, "🔎 Пришлите адрес сайта, например <code>youtube.com</code>")
    elif cmd in ("/diag", "/diagnose"):
        send(chat, "⏳ Диагностика…")
        run_job(chat, "diag")
    elif cmd == "/selftest":
        send(chat, "⏳ Самопроверка…")
        run_job(chat, "self")
    elif cmd == "/ip":
        run_job(chat, "ip")
    elif not admin and cmd in ("/switch", "/auto", "/restart", "/report", "/route"):
        send(chat, "⛔ Это действие доступно только администраторам")
    elif cmd == "/switch":
        names = P.tunnels()
        e = P.env()
        name = {"main": e.get("MAIN") or "awgmain", "backup": e.get("BACKUP", "")}.get(arg, arg)
        if name not in names:
            send(chat, "Укажите канал: /switch main | backup | имя (%s)" % ", ".join(names))
        else:
            send(chat, do_switch(chat, name), [[("🔀 Каналы", "m:tun")]])
    elif cmd == "/route":
        rid, _, t = arg.partition(" ")
        r = next((x for x in routes_list() if x["id"] == rid), None)
        t = t.strip()
        if not r or not (t == "auto" or t in r["tunnels"]):
            send(chat, "Формат: /route ID канал|auto. Маршруты: %s" % (", ".join("%s (%s)" % (x["id"], " ".join(x["tunnels"])) for x in routes_list()) or "нет"))
        else:
            send(chat, do_route_switch(chat, rid, t), [[("⬅️ " + rid, "r:" + rid)]])
    elif cmd == "/auto":
        send(chat, "🤖 " + esc(P.api_tunnel_auto(Act(chat), {})["msg"]))
    elif cmd == "/restart":
        P.run(["systemctl", "restart", "awg-failover"], timeout=60)
        send(chat, "♻️ Сторож перезапущен", [[("🏠 Меню", "m:main")]])
    elif cmd == "/report":
        send(chat, "⏳ Собираю отчёт…")
        run_job(chat, "report")
    elif text.startswith("/"):
        send(chat, "Команда не распознана. Меню: /menu", [[("🏠 Меню", "m:main")]])


def cmd_domain(chat, text):
    try:
        dom = P.v_domains(text)
    except ValueError as ex:
        send(chat, "⚠️ %s" % esc(ex))
        return
    if not dom or " " in dom:
        send(chat, "Пришлите один домен, например <code>youtube.com</code>")
        return
    send(chat, "⏳ Проверяю %s…" % esc(dom))
    run_job(chat, "domain", dom)


def process(updates):
    last = None
    for u in updates or []:
        last = u.get("update_id", last)
        try:
            if "callback_query" in u:
                on_callback(u["callback_query"])
            elif "message" in u:
                on_message(u["message"])
            else:
                log("пропускаю обновление типа %s" % next((k for k in u if k != "update_id"), "?"))
        except Exception as ex:
            log("ошибка обработки: %r" % ex)
    if last is not None:
        P.write_secure(OFFF, "%d\n" % (last + 1), 0o600)


# ======================================================================= фоновые тревоги
def broadcast(text, critical=False):
    mu = mutes()
    for c in C["admins"] + C["viewers"]:
        if c in mu and not critical:
            continue
        send(c, text, [[("📊 Состояние", "m:main")]])


def autotune_msgs():
    """Автоподбор при деградации (#36): запуск — сообщением, итог — с кнопкой «Применить» (только администраторам)."""
    for m in P.autotune_tick():
        t = esc(m["tunnel"])
        if m["kind"] == "start":
            broadcast("🛡 <b>Автоподбор обфускации</b> · %s\nКанал <b>%s</b>: %s. Пробую наборы Jc/Jmin/Jmax (до 10 минут; канал неактивный, рабочий трафик не трогается)."
                      % (esc(H), t, esc(m["why"])))
        elif m["kind"] == "offer":
            txt = ("🛡 <b>Автоподбор: %s</b> · %s\nТекущий набор %s. Лучший — №%d: <code>%s</code>\nпотери %s%% · %s мс · %s Мбит/с · оценка %s%s"
                   % (t, esc(H), "работает" if m["base_ok"] else "<b>не работает</b>", m["n"], esc(m["params"]), m["loss"], m["rtt"], m["mbps"], m["score"],
                      " (у текущего %s)" % m["base_score"] if m["base_ok"] else ""))
            for c in C["admins"]:
                send(c, txt + "\n\n«Применить» — конфиг меняется через историю с проверкой handshake и откатом.",
                     [[("✅ Применить №%d" % m["n"], "tap:%s:%d" % (m["tunnel"], m["n"])), ("✖️ Не сейчас", "m:main")]])
            for c in C["viewers"]:
                send(c, txt)
        else:
            broadcast("🛡 <b>Автоподбор: %s</b> · %s\nНабора лучше текущего не нашлось%s. Попробую снова через сутки, если канал не оживёт."
                      % (t, esc(H), " (текущий снова работает)" if m["base_ok"] else ""))


def monitor():
    bad = collections.Counter()
    alerted = {}
    hist = collections.deque(maxlen=1440)
    ev_size = os.path.getsize(os.path.join(DD, "events.log")) if os.path.exists(os.path.join(DD, "events.log")) else 0
    while True:
        time.sleep(60)
        try:
            h = P.system_health(hist=list(hist))
            hist.append({"t": P.now(), "cpu": h["cpu"], "data_free": P.disk_free_mb()})
            cur = {}
            for c in h["checks"]:
                if c["level"] in ("warn", "crit"):
                    cur["sys:" + c["key"]] = (c["level"], "%s %s%s" % (LV[c["level"]], c["text"], "\n↳ " + c["advice"] if c["advice"] else ""))
            watch = [u for u in ("awg-subnets", "awg-self", "awg-guard", "awg-metrics", "awg-web", "awg-notify", "awg-ha")
                     if P.svc_installed(u) and u in P.units_list()]
            sv = P.svc_states(watch) if watch else {}
            for u in watch:
                if not sv.get(u):
                    cur["svc:" + u] = ("warn", "🛑 Служба %s остановлена" % u)
            for s in P.env().get("EXTRA_SUBNETS", "").split():
                rc, out = P.run(["ip", "-4", "route", "show", "table", "all", "to", s], timeout=5)
                if "dev" not in out:
                    cur["sub:" + s] = ("warn", "⚠️ Подсеть VPN-сервера %s пропала (VPN-сервер выключен?)" % s)
            for k in set(cur) | set(bad):
                if k in cur:
                    bad[k] += 1
                    if bad[k] == 3 and k not in alerted:
                        alerted[k] = cur[k][1]
                        broadcast("<b>Роутер %s</b>\n%s" % (esc(H), esc(cur[k][1])), critical=cur[k][0] == "crit")
                else:
                    del bad[k]
                    if k in alerted:
                        broadcast("✅ <b>%s</b>: снова в норме\n<s>%s</s>" % (esc(H), esc(alerted.pop(k).split("\n")[0])))
            # события, о которых не сообщает awg-notify
            evf = os.path.join(DD, "events.log")
            sz = os.path.getsize(evf) if os.path.exists(evf) else 0
            if sz > ev_size:
                with open(evf, encoding="utf-8", errors="replace") as f:
                    f.seek(ev_size)
                    for line in f.read().splitlines():
                        p = line.split("|", 2)
                        if len(p) == 3 and p[1] == "refused":
                            broadcast("⚠️ <b>Ручное переключение отклонено</b> · %s\n%s" % (esc(H), esc(p[2])))
            ev_size = sz
            autotune_msgs()
            # недельный отчёт: понедельник после REPORT_TIME
            wk = time.strftime("%G-%V")
            if time.strftime("%u") == "1" and int(time.strftime("%H%M")) >= int(C["report_time"] or 900) and P.read_file(os.path.join(DD, "bot.lastweek")).strip() != wk:
                P.write_secure(os.path.join(DD, "bot.lastweek"), wk + "\n", 0o600)
                txt, _ = scr_report(None, 7)
                broadcast("<b>Роутер %s</b>\n%s" % (esc(H), txt))
        except Exception as ex:
            log("монитор: %r" % ex)


# ======================================================================= запуск
def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--once-from":
        TEST["on"] = True
        process(json.loads(open(sys.argv[2], encoding="utf-8").read()).get("result", []))
        time.sleep(float(os.environ.get("BOT_TEST_WAIT", "0")))
        for m, p, d in TEST["out"]:
            print(json.dumps({"method": m, "params": p}, ensure_ascii=False))
        return
    if not C["token"] or not C["admins"]:
        sys.exit("нет TG_TOKEN или TG_CHAT в %s/telegram.env" % DD)
    log("бот запущен: администраторы %s%s" % (", ".join(C["admins"]), "; просмотр " + ", ".join(C["viewers"]) if C["viewers"] else ""))
    TGAPI.call("setMyCommands", {"commands": [
        {"command": "menu", "description": "меню кнопками"}, {"command": "status", "description": "состояние"},
        {"command": "tunnels", "description": "каналы"}, {"command": "router", "description": "роутер: CPU, память, диск"},
        {"command": "events", "description": "события"}, {"command": "clients", "description": "клиенты в туннеле"},
        {"command": "routes", "description": "дополнительные маршруты"},
        {"command": "week", "description": "отчёт за неделю"},
        {"command": "domain", "description": "проверить сайт"}, {"command": "help", "description": "помощь"}]})
    threading.Thread(target=monitor, daemon=True).start()
    off = P.read_file(OFFF).strip() or "0"
    while True:
        r = TGAPI.call("getUpdates", {"offset": int(off) if off.isdigit() else 0, "timeout": 25,
                                      "allowed_updates": ["message", "callback_query"]}, timeout=30)
        if r is None:
            time.sleep(5)
            continue
        process(r)
        off = P.read_file(OFFF).strip() or off


if __name__ == "__main__":
    main()
