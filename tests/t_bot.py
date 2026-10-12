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
print("bot: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
