#!/usr/bin/env python3
"""Автоподбор при деградации (#36): когда запускается, как часто, что предлагает и что ставит по кнопке — без сети."""
import json, os, sys, tempfile, time
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgat-")
DD, RUN = os.path.join(T, "dd"), os.path.join(T, "run")
for d in (DD, RUN, os.path.join(DD, "web")):
    os.makedirs(d, exist_ok=True)
os.environ.update(DD=DD, AWG_RUN=RUN, AWG_WEBD=os.path.join(DD, "web"), STATEF=os.path.join(RUN, "awg-state"))
open(os.path.join(DD, "awg.env"), "w").write('MAIN=awgmain\nBACKUP=awgbackup\nQUALITY_LOSS=40\nAUTO_TUNE=yes\n')
open(os.path.join(RUN, "awg-state"), "w").write("ACTIVE=awgbackup\nLOSS_awgmain=100\n")
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.tools as TL  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:500]))
    if not cond:
        FAILS.append(name)


CLOCK = {"t": 1_800_000_000}
RUNS = []
TUNE = {"running": False}
TL.now = lambda: CLOCK["t"]
TL.tunnels = lambda e=None: ["awgmain", "awgbackup"]
TL.link_exists = lambda t: True
TL.hs_age = lambda t: 900 if t == "awgmain" else 20          # основной молчит 15 минут — его и подбираем
TL.tune_running = lambda: TUNE["running"]
TL.vps_job_running = lambda: False
TL.run = lambda cmd, timeout=60, env=None, inp=None: (RUNS.append(cmd), (0, ""))[1]
applied = []
TL.tune_apply = lambda h, n: (applied.append(n), {"ok": True, "msg": "набор %d поставлен" % n})[1]

check("деградация меньше 15 минут — ждём", TL.autotune_tick() == [] and not RUNS)
CLOCK["t"] += 600
check("…ещё ждём (10 минут)", TL.autotune_tick() == [] and not RUNS)
CLOCK["t"] += 360
m = TL.autotune_tick()
check("15 минут без handshake — подбор «только роутер» на неактивном основном", m and m[0]["kind"] == "start" and m[0]["tunnel"] == "awgmain"
      and RUNS and RUNS[-1][-4:] == ["run", "awgmain", "client", "5"] and "--active" not in RUNS[-1], (m, RUNS[-1:]))
check("активный канал не трогается", all("awgbackup" not in c for c in RUNS))
TUNE["running"] = True
CLOCK["t"] += 60
check("пока подбор идёт — тишина", TL.autotune_tick() == [])
TUNE["running"] = False
open(TL.TUNE_RES, "w").write("# awgmain\tclient\t%d\t\n0\t0\t-1\t100\t0\t0.0\t0\tJc=4 Jmin=40 Jmax=70\n"
                             "1\t1\t2\t0\t45\t30.5\t95\tJc=7 Jmin=20 Jmax=300\n2\t1\t3\t5\t60\t12.0\t70\tJc=3 Jmin=10 Jmax=50\n" % (CLOCK["t"] - 30))
CLOCK["t"] += 60
m = TL.autotune_tick()
check("итог: лучший набор предложен, текущий не работает", m and m[0]["kind"] == "offer" and m[0]["n"] == 1 and not m[0]["base_ok"]
      and m[0]["params"] == "Jc=7 Jmin=20 Jmax=300", m)
ev = open(os.path.join(DD, "events.log")).read()
check("события: запуск и итог", "|tune|автоподбор awgmain: запущен" in ev and "лучший набор №1" in ev, ev)
n0 = len(RUNS)
for _ in range(30):
    CLOCK["t"] += 600
    TL.autotune_tick()
check("не чаще раза в сутки на туннель", len(RUNS) == n0, RUNS[n0:])
try:
    TL.autotune_apply(None, "awgmain", 2)
    check("кнопка: чужой набор отклонён", False)
except ValueError as ex:
    check("кнопка: чужой набор отклонён", "устарело" in str(ex))
r = TL.autotune_apply(None, "awgmain", 1)
check("кнопка: предложенный набор ставится", r["ok"] and applied == [1], (r, applied))
try:
    TL.autotune_apply(None, "awgmain", 1)
    check("кнопка: повторно — нет", False)
except ValueError:
    check("кнопка: повторно — нет", True)
open(os.path.join(DD, "awg.env"), "w").write('MAIN=awgmain\nAUTO_TUNE=no\n')
CLOCK["t"] += 90000
check("выключено — ничего не делает", TL.autotune_tick() == [] and len(RUNS) == n0)
print("autotune: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
