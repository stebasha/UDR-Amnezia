#!/usr/bin/env python3
"""Тесты Telegram-бота (bot.py) на стенде tests/web_lab.sh: меню, права, подтверждения, чужие чаты, тишина."""
import json, os, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L = tempfile.mkdtemp(prefix="awgbot-")
FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:400]))
    if not cond:
        FAILS.append(name)


pid = subprocess.check_output([os.path.join(R, "tests/web_lab.sh"), L, "18477"]).decode().split()[-1]
subprocess.call(["kill", pid])
dd = os.path.join(L, "dd")
open(os.path.join(dd, "telegram.env"), "w").write('TG_TOKEN=1:x\nTG_CHAT="111, 222\r"\nTG_VIEWERS=333\n')
upd = {"ok": True, "result": [
    {"update_id": 1, "message": {"chat": {"id": 111}, "text": "/menu"}},
    {"update_id": 2, "callback_query": {"id": "a", "data": "swq:awgbackup", "message": {"message_id": 9, "chat": {"id": 222}}}},
    {"update_id": 3, "callback_query": {"id": "b", "data": "sw:awgbackup", "message": {"message_id": 9, "chat": {"id": 333}}}},
    {"update_id": 4, "callback_query": {"id": "c", "data": "mute:3600", "message": {"message_id": 9, "chat": {"id": 333}}}},
    {"update_id": 5, "message": {"chat": {"id": 999}, "text": "/start"}},
    {"update_id": 6, "callback_query": {"id": "d", "data": "m:svc", "message": {"message_id": 9, "chat": {"id": 333}}}},
    {"update_id": 7, "my_chat_member": {"chat": {"id": 111}}},
]}
f = os.path.join(L, "upd.json")
json.dump(upd, open(f, "w"))
envv = dict(os.environ, DD=dd, STUB=os.path.join(L, "stub"), PATH=os.path.join(L, "bin") + ":" + os.environ["PATH"], AWG_RUN=os.path.join(L, "run"),
            SYSD=os.path.join(L, "sysd"), AWG_SYSNET=os.path.join(L, "sys"), AWG_WEBD=os.path.join(dd, "web"))
out = subprocess.run(["python3", os.path.join(R, "awg/bot.py"), "--once-from", f], env=envv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
calls = [json.loads(l) for l in out.stdout.decode().splitlines() if l.startswith("{")]
by = lambda chat: [c for c in calls if str(c["params"].get("chat_id")) == chat]
btns = lambda c: [b["callback_data"] for r in c["params"].get("reply_markup", {}).get("inline_keyboard", []) for b in r]
m = by("111")
check("меню: состояние и кнопки", m and "Канал" in m[0]["params"]["text"] and "m:tun" in btns(m[0]) and "m:svc" in btns(m[0]), m[:1])
c222 = by("222")
check("переключение просит подтверждения", c222 and "sw:awgbackup" in btns(c222[0]), c222)
c333 = by("333")
check("просмотр: переключать нельзя", any("только администраторам" in c["params"]["text"] for c in c333), c333)
check("просмотр: службы недоступны", any("Только для администраторов" in c["params"]["text"] for c in c333), c333)
check("тишина записана", open(os.path.join(dd, "bot.mute")).read().startswith("333 "))
c999 = by("999")
check("чужой чат получает свой id", c999 and "999" in c999[0]["params"]["text"] and "Нет доступа" in c999[0]["params"]["text"], c999)
check("лишние обновления не ломают бота", "пропускаю обновление типа my_chat_member" in out.stderr.decode(), out.stderr.decode()[-500:])
check("offset сохранён", open(os.path.join(dd, "bot.offset")).read().strip() == "8")
check("переключение не выполнено по кнопке просмотра", not os.path.exists(os.path.join(L, "run", "awg-force")))
# ---------- маршруты (#40)
os.makedirs(os.path.join(dd, "route.d"), exist_ok=True)
open(os.path.join(dd, "route.d", "us.env"), "w").write('RAIL_IF="wgclt2"\nPRIO="32507"\nMARK="0x6c0000/0x7e0000"\nTABLE="179"\nTUNNELS="awgbackup awgmain"\nLABEL="США"\n')
open(os.path.join(L, "run", "awg-state-us"), "w").write("ACTIVE=awgbackup\n")
upd2 = {"ok": True, "result": [
    {"update_id": 20, "message": {"chat": {"id": 111}, "text": "/routes"}},
    {"update_id": 21, "callback_query": {"id": "e", "data": "r:us", "message": {"message_id": 9, "chat": {"id": 111}}}},
    {"update_id": 22, "callback_query": {"id": "f", "data": "rtw:us:awgmain", "message": {"message_id": 9, "chat": {"id": 333}}}},
    {"update_id": 23, "callback_query": {"id": "g", "data": "rtq:us:awgmain", "message": {"message_id": 9, "chat": {"id": 222}}}},
    {"update_id": 24, "message": {"chat": {"id": 222}, "text": "/route us awgmain"}},
    {"update_id": 25, "message": {"chat": {"id": 111}, "text": "/route us nope"}},
    {"update_id": 26, "message": {"chat": {"id": 333}, "text": "/week"}},
]}
json.dump(upd2, open(f, "w"))
out = subprocess.run(["python3", os.path.join(R, "awg/bot.py"), "--once-from", f], env=envv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
calls = [json.loads(l) for l in out.stdout.decode().splitlines() if l.startswith("{")]
m = by("111")
check("маршруты: список с каналом и кнопкой", m and "США" in m[0]["params"]["text"] and "awgbackup" in m[0]["params"]["text"] and "r:us" in btns(m[0]), (m[:1], out.stderr.decode()[-400:]))
check("маршрут: цепочка и переключение на другой канал", len(m) > 1 and "1. awgbackup" in m[1]["params"]["text"] and "rtq:us:awgmain" in btns(m[1]), m[1:2])
c333 = by("333")
check("маршрут: просмотр не переключает", any("только администраторам" in c["params"]["text"] for c in c333), c333)
c222 = by("222")
check("маршрут: подтверждение переключения", c222 and "rtw:us:awgmain" in btns(c222[0]), c222[:1])
fu = os.path.join(L, "run", "awg-force-us")
check("маршрут: /route переключает канал", len(c222) > 1 and c222[1]["params"]["text"].startswith("✅") and os.path.exists(fu) and "awgmain" in open(fu).read(), (c222[1:2], out.stderr.decode()[-300:]))
c333 = by("333")
check("отчёт за неделю: каналы и маршрут, просмотру доступен", any("Отчёт за неделю" in c["params"]["text"] and "Маршрут us (США)" in c["params"]["text"] for c in c333), c333[-1:])
check("маршрут: неверный канал — подсказка", any("Формат: /route" in c["params"]["text"] for c in m), m)
# ---------- нагрузка: проверки не размножаются от частых нажатий; тест только туннелей
dg = os.path.join(dd, "diagnose.sh")
open(dg, "w").write("#!/bin/sh\nsleep 1\necho diag-ok\n")
os.chmod(dg, 0o755)
upd3 = {"ok": True, "result": [
    {"update_id": 30, "callback_query": {"id": "h", "data": "run:diag", "message": {"message_id": 9, "chat": {"id": 111}}}},
    {"update_id": 31, "callback_query": {"id": "i", "data": "run:diag", "message": {"message_id": 9, "chat": {"id": 111}}}},
    {"update_id": 32, "callback_query": {"id": "j", "data": "test:eth3", "message": {"message_id": 9, "chat": {"id": 333}}}},
    {"update_id": 33, "message": {"chat": {"id": 222}, "date": int(__import__("time").time()) - 3600, "text": "/route us awgmain"}},
]}
json.dump(upd3, open(f, "w"))
out = subprocess.run(["python3", os.path.join(R, "awg/bot.py"), "--once-from", f], env=dict(envv, BOT_TEST_WAIT="8"),
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
calls = [json.loads(l) for l in out.stdout.decode().splitlines() if l.startswith("{")]
m = [c["params"].get("text", "") for c in by("111")]
check("повторная диагностика, пока идёт первая, не запускается", sum("уже выполняется" in t for t in m) == 1 and sum("diag-ok" in t for t in m) == 1, m)
c222 = [c["params"].get("text", "") for c in by("222")]
check("команда, пришедшая час назад (бот был остановлен), не выполняется", any("не выполнена" in t for t in c222) and not any(t.startswith("✅") for t in c222), c222)
check("тест по кнопке — только для туннелей", any("Туннеля eth3 нет" in c["params"].get("text", "") for c in by("333")), by("333"))
print("bot: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
