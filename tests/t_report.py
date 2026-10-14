#!/usr/bin/env python3
"""Отчёт за неделю (#41) и учёт трафика по устройствам: правила, приращения счётчиков, сводка — на заглушках, без сети."""
import json, os, sys, tempfile, time
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgrep-")
DD, STUB, RUN = os.path.join(T, "dd"), os.path.join(T, "stub"), os.path.join(T, "run")
for d in (DD, STUB, RUN, os.path.join(DD, "web"), os.path.join(DD, "route.d"), os.path.join(T, "bin")):
    os.makedirs(d, exist_ok=True)
# ipset со счётчиками: create — пустой набор, list — строки из $STUB/acc-ИМЯ
open(os.path.join(T, "bin", "ipset"), "w").write('''#!/bin/bash
case "$1" in
  create) echo "$2" >> "$STUB/ipset-created";;
  destroy) echo "$2" >> "$STUB/ipset-destroyed";;
  list) echo "Name: $2"; echo "Members:"; cat "$STUB/acc-$2" 2>/dev/null;;
esac
exit 0
''')
os.chmod(os.path.join(T, "bin", "ipset"), 0o755)
os.environ.update(DD=DD, STUB=STUB, AWG_RUN=RUN, AWG_WEBD=os.path.join(DD, "web"), STATEF=os.path.join(RUN, "awg-state"),
                  AWG_LEASES=os.path.join(T, "leases"), PATH=os.path.join(T, "bin") + ":" + os.path.join(R, "tests/stubs2") + ":" + os.environ["PATH"])
open(os.path.join(DD, "awg.env"), "w").write('MAIN=awgmain\nBACKUP=awgbackup\nTABLE=178\nMARK=0x6a0000/0x7e0000\nTRAFFIC_ACCT=yes\n')
open(os.path.join(T, "leases"), "w").write("1791900000 aa:bb:cc:dd:ee:01 192.168.1.50 tv-living *\n")
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.server as P  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:500]))
    if not cond:
        FAILS.append(name)


ipt = lambda *a: P.run(["iptables"] + list(a))[1]  # noqa: E731
P.acct_on()
P.acct_on()
fw = ipt("-t", "mangle", "-S", "FORWARD")
check("учёт: переход первым в mangle FORWARD и один", fw.splitlines()[1:2] == ["-A FORWARD -j AWG_ACC"] and fw.count("AWG_ACC") == 1, fw)
ch = ipt("-t", "mangle", "-S", "AWG_ACC")
check("учёт: правила только считают (SET и match-set), без ACCEPT/DROP/MARK", "-o awg+ -j SET --add-set AWG_ACC_UP src" in ch and "-i awg+ -m set --match-set AWG_ACC_DN dst" in ch
      and not any(x in ch for x in ("ACCEPT", "DROP", "MARK")), ch)
check("учёт: наборы со счётчиками созданы", open(os.path.join(STUB, "ipset-created")).read().split().count("AWG_ACC_UP") >= 1)
open(os.path.join(STUB, "acc-AWG_ACC_DN"), "w").write("192.168.1.50 packets 10 bytes 5000000\n192.168.1.77 packets 3 bytes 1000\n")
open(os.path.join(STUB, "acc-AWG_ACC_UP"), "w").write("192.168.1.50 packets 9 bytes 300000\n")
P.acct_collect(P.leases())
open(os.path.join(STUB, "acc-AWG_ACC_DN"), "w").write("192.168.1.50 packets 20 bytes 7000000\n192.168.1.77 packets 1 bytes 400\n")
d = P.acct_collect(P.leases())
day = d["days"][time.strftime("%Y-%m-%d")]
check("учёт: приращения по MAC, сброс счётчика (перезагрузка) не даёт минуса", day.get("aa:bb:cc:dd:ee:01") == [7000000, 300000] and day.get("192.168.1.77") == [1400, 0], day)
check("учёт: имя устройства из аренды DHCP", d["names"]["aa:bb:cc:dd:ee:01"]["name"] == "tv-living", d["names"])
check("учёт: файл 600", oct(os.stat(P.TRAFFIC_F).st_mode & 0o777) == "0o600")

# история: 3 часа, основной канал 150 минут, запасной 30; маршрут us 100 минут на awgbackup, 20 — без канала
now = int(time.time()) // 3600 * 3600
hrs = []
for i in range(3):
    hrs.append({"t": now - (3 - i) * 3600, "n": 60, "active": "awgmain", "am": {"awgmain": 50, "awgbackup": 10},
                "ra": {"us": {"awgbackup": 40} if i < 2 else {"awgbackup": 20, "": 20}},
                "tun": {"awgmain": {"rx": 8000000, "tx": 800000, "rtt": 40.0, "loss": 0.0, "up": 100.0},
                        "awgbackup": {"rx": 0, "tx": 0, "rtt": 80.0, "loss": 10.0 if i == 0 else 0.0, "up": 90.0}}, "sys": {}})
open(P.HIST_F, "w").write(json.dumps({"points": [], "hours": hrs}))
open(os.path.join(DD, "route.d", "us.env"), "w").write('TUNNELS="awgbackup awgmain"\nLABEL="США"\n')
open(os.path.join(DD, "web", "speed.json"), "w").write(json.dumps([{"t": now - 100, "iface": "awgmain", "down_bps": 80000000, "up_bps": 20000000, "ping_ms": 40},
                                                                  {"t": now - 50, "iface": "awgmain", "down_bps": 60000000, "up_bps": 20000000, "ping_ms": 60},
                                                                  {"t": now - 40 * 86400, "iface": "awgmain", "down_bps": 1, "up_bps": 1}]))
ev = ["%d|switch|awgmain → awgbackup" % (now - 7000), "%d|return|awgbackup → awgmain" % (now - 6000),
      "%d|switch|маршрут us: awgbackup → awgmain" % (now - 5000)]
open(os.path.join(DD, "events.log"), "w").write("\n".join(ev) + "\n")
r = P.report_data(7)
tm = {t["name"]: t for t in r["tunnels"]}
check("отчёт: доступность, RTT, потери по каналам (средние по часам)", tm["awgmain"]["avail"] == 100.0 and tm["awgbackup"]["avail"] == 90.0
      and tm["awgbackup"]["loss"] == 3.3 and tm["awgmain"]["rtt"] == 40.0, tm)
check("отчёт: время активности канала по минутам", tm["awgmain"]["active_min"] == 150 and tm["awgbackup"]["active_min"] == 30, tm)
check("отчёт: трафик канала ≈ средняя скорость × время", abs(tm["awgmain"]["bytes"] - (8800000 / 8 * 3600 * 3)) < 10, tm["awgmain"]["bytes"])
check("отчёт: скорость — только замеры за период", r["speed"] == [{"iface": "awgmain", "n": 2, "down_bps": 70000000, "up_bps": 20000000, "ping_ms": 50}], r["speed"])
rt = r["routes"][0] if r["routes"] else {}
check("отчёт: маршрут — время на первом канале, без канала, переключения", rt.get("first_pct") == 83.3 and {"tunnel": "", "minutes": 20} in rt.get("on", [])
      and rt.get("switch") == 1, rt)
check("отчёт: события маршрутов не попадают в статистику основного", r["main"]["switch"] == 1 and r["main"]["return"] == 1, r["main"])
check("отчёт: устройства с именами", r["acct"] and r["devices"][0]["name"] == "tv-living" and r["devices"][0]["down"] == 7000000, r["devices"])
txt = P.report_text(r)
check("отчёт текстом: каналы, маршрут, устройства", "awgmain: 100.0% · 40.0 мс" in txt and "Маршрут us (США): на первом канале 83.3%" in txt and "tv-living: 7.0 МБ" in txt, txt)
P.acct_off()
check("учёт выключен: правил и переходов нет", "AWG_ACC" not in ipt("-t", "mangle", "-S"), ipt("-t", "mangle", "-S"))
print("report: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
