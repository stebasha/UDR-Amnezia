#!/usr/bin/env python3
"""Анализ безопасности (1.10) на записанных выводах команд (как на UDR7): проброс, WAN_LOCAL, SSH, IPS, соединения."""
import json, os, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgsec-")
os.makedirs(os.path.join(T, "web"))
os.makedirs(os.path.join(T, "proc"))
open(os.path.join(T, "proc", "uptime"), "w").write("360000.5 100.0\n")
open(os.path.join(T, "sshd"), "w").write("PermitRootLogin yes\nPasswordAuthentication no\n")
open(os.path.join(T, "auth.log"), "w").write(
    "Oct 16 10:00:00 UDR7 sshd[1]: Failed password for root from 192.168.3.3 port 5555 ssh2\n"
    "Oct 16 10:00:01 UDR7 sshd[1]: Accepted publickey for root from 192.168.3.3 port 5556 ssh2\n")
eve = [{"timestamp": "2026-10-16T10:00:00.000+1100", "event_type": "alert", "src_ip": "45.1.1.1", "dest_port": 8123,
        "alert": {"signature": "ET SCAN Suspicious inbound", "category": "Attempted Recon", "action": "allowed"}},
       {"timestamp": "2026-10-16T11:00:00.000+1100", "event_type": "alert", "src_ip": "45.1.1.1", "dest_port": 8123,
        "alert": {"signature": "ET SCAN Suspicious inbound", "category": "Attempted Recon", "action": "blocked"}},
       {"event_type": "stats"}]
open(os.path.join(T, "eve.json"), "w").write("first-partial-line\n" + "\n".join(json.dumps(x) for x in eve) + "\n")
open(os.path.join(T, "honey"), "w").write("x")
os.environ.update(DD=T, AWG_WEBD=os.path.join(T, "web"), AWG_RUN=T, AWG_PROC=os.path.join(T, "proc"), AWG_SSHD=os.path.join(T, "sshd"),
                  AWG_AUTHLOG=os.path.join(T, "auth.log"), AWG_EVE=os.path.join(T, "eve.json"), AWG_HONEY=os.path.join(T, "honey"))
open(os.path.join(T, "awg.env"), "w").write("WANIF=eth3\nMAIN=awgmain\n")
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.server as S  # noqa: E402
import awgweb.security as X  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:400]))
    if not cond:
        FAILS.append(name)


HDR = "Chain X (1 references)\n    pkts      bytes target     prot opt in     out     source               destination\n"
NAT_S = "-N UBIOS_PREROUTING_USER_HOOK\n-A UBIOS_PREROUTING_USER_HOOK -d 188.113.154.234/32 -p tcp -m tcp --dport 44300 -j DNAT --to-destination 192.168.1.5:5001\n"
NAT_L = HDR + "\n".join([
    "     718    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:44300 to:192.168.1.5:5001",
    "       0        0 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:44300 to:192.168.1.5:5001",
    "     683    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:8123 to:192.168.1.168:8123",
    "     602    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:25 to:192.168.1.5:25",
    "     251    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:465 to:192.168.1.5:465",
    "   15877    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:80 to:192.168.1.5:80",
    "     316    40000 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:32400 to:192.168.1.5:32400",
    "       0        0 DNAT       tcp  --  *      *       0.0.0.0/0            188.113.154.234      tcp dpt:4430 to:192.168.1.5:4430",
    "      50     4000 DNAT       tcp  --  *      *       203.0.113.0/24       188.113.154.234      tcp dpt:2222 to:192.168.1.9:22",
]) + "\n"
WL = HDR + "\n".join([
    "       2       80 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set UBIOS_policy_src_port_1 src match-set UBIOS_policy_dst_port_1 dst /* 1 */",
    "32035206 28026479184 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED /* 2 */",
    "    7782   597101 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate INVALID /* 3 */",
    "     810   180792 ACCEPT     udp  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set UBIOS_wireguard_ports dst /* 4 */",
    " 1205171 48585495 ACCEPT     tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set UBIOS_unifi_console_https_port dst /* 5 */",
    "  193257 18487561 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* 6 */",
]) + "\n"
SETS = {"UBIOS_policy_src_port_1": ["22"], "UBIOS_policy_dst_port_1": ["22"], "UBIOS_wireguard_ports": ["51820"], "UBIOS_unifi_console_https_port": ["443"]}
CONNS = ("tcp 6 100 ESTABLISHED src=94.243.30.96 dst=188.113.154.234 sport=40000 dport=8123 src=192.168.1.168 dst=94.243.30.96 sport=8123 dport=40000\n"
         "tcp 6 100 ESTABLISHED src=192.168.1.15 dst=188.113.154.234 sport=40000 dport=443 src=188.113.154.234 dst=192.168.1.15\n"
         "udp 17 100 src=80.83.225.5 dst=188.113.154.234 sport=49666 dport=51820 src=188.113.154.234 dst=80.83.225.5\n")
PROT = {"on": False}
BANS = "Name: AWG_SEC_TRAP\nType: hash:ip\nNumber of entries: 2\nMembers:\n45.1.1.1 timeout 80000 packets 12 bytes 600\n45.2.2.2 timeout 100 packets 3 bytes 120\n"


def fake_run(cmd, timeout=60, env=None, inp=None):
    c = " ".join(cmd)
    if c.startswith("iptables -w 5 -t nat -S"):
        return 0, NAT_S
    if "-t nat -L UBIOS_PREROUTING_USER_HOOK" in c:
        return 0, NAT_L
    if "-L UBIOS_WAN_LOCAL_USER" in c:
        return 0, WL
    if "-L AWG_SEC_IN" in c:
        return (0, HDR + "      40     2000 DROP       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:8123 ! match-set AWG_SEC_GEO src\n"
                + "      15      900 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set AWG_SEC_BAN src\n") if PROT["on"] else (1, "")
    if "-L AWG_SEC_FWD" in c:
        return (0, HDR) if PROT["on"] else (1, "")
    if cmd[:2] == ["ipset", "list"]:
        n = cmd[-1]
        if n == "AWG_SEC_TRAP":
            return 0, BANS
        if n == "AWG_SEC_RATE":
            return 0, "Name: AWG_SEC_RATE\nNumber of entries: 0\nMembers:\n"
        if n == "AWG_SEC_GEO":
            return 0, "Name: AWG_SEC_GEO\nNumber of entries: 9000\n"
        if n in SETS:
            return 0, "Name: %s\nType: bitmap:port\nMembers:\n%s\n" % (n, "\n".join(SETS[n]))
        return 1, ""
    if cmd[:2] == ["ip", "-4"]:
        return 0, "5: eth3    inet 188.113.154.234/24 brd 188.113.154.255 scope global eth3\n"
    if cmd[:2] == ["pgrep", "-af"]:
        return 0, "1936800 /usr/share/ubios-udapi-server/ips_8/suricata/bin/suricata --pcap -c /usr/share/ubios-udapi-server/ips_8/config/suricata_ubios_high.yaml\n"
    if cmd[:2] == ["pgrep", "-x"]:
        return 1, ""
    if cmd[0] == "conntrack":
        return 0, CONNS
    return 1, ""


X.run = fake_run
d = X.sec_collect()
fw = {x["port"]: x for x in d["forwards"]}
check("проброс: дубли правил сложены, 44300 → DSM (по порту в сети), управление", fw[44300]["pkts"] == 718 and fw[44300]["kind"] == "admin" and "DSM" in fw[44300]["service"], fw.get(44300))
check("проброс: 8 портов, ограничение по адресу источника замечено", len(fw) == 8 and fw[2222]["restricted"] and not fw[8123]["restricted"], sorted(fw))
lc = d["local"]
kinds = {a["kind"]: a for a in lc["accept"]}
check("WAN_LOCAL: консоль 443, WireGuard 51820, правило с портом-источником 22", kinds["console"]["dports"] == ["443"] and kinds["wireguard"]["dports"] == ["51820"]
      and kinds["user"]["sports"] == ["22"], lc)
check("WAN_LOCAL: отброшено 193257, ошибочных 7782", lc["drop"] == 193257 and lc["invalid"] == 7782)
check("SSH: только ключ, попытки с LAN — не из интернета", d["ssh"]["password"] == "no" and d["ssh"]["fails_wan"] == 0 and d["ssh"]["fails"][0]["ip"] == "192.168.3.3")
check("IPS: работает, профиль high, 2 события, 1 заблокировано, источник 45.1.1.1", d["ips"]["running"] and d["ips"]["profile"] == "high" and d["ips"]["alerts"] == 2
      and d["ips"]["blocked"] == 1 and d["ips"]["src"][0] == {"ip": "45.1.1.1", "n": 2}, d["ips"])
check("соединения: только внешние адреса (LAN и свой адрес не в счёт)", d["conns"]["total"] == 2 and {x["port"] for x in d["conns"]["ports"]} == {8123, 51820}, d["conns"])
check("uptime и внешний адрес", d["uptime"] == 360000 and d["wanip"] == "188.113.154.234" and not d["cgnat"])
F, score = X.sec_findings(d)
t = lambda sev, s: any(x["sev"] == sev and s in x["title"] for x in F)
check("находка: DSM открыт всем — исправить", t("crit", "Synology DSM"), [x["title"] for x in F])
check("находка: Home Assistant открыт всем — исправить", t("crit", "Home Assistant"))
check("находка: SMTP с паролем (465) — стоит поправить", t("warn", "465"))
check("находка: приём почты 25 — к сведению, не ограничивать странами", t("info", "Приём почты") and any("Не ограничивайте" in x["fix"] for x in F if "почты" in x["title"]))
check("находка: HTTP 80 — к сведению (Let's Encrypt)", t("info", "HTTP открыт"))
check("находка: неиспользуемый проброс 4430", t("info", "4430 не используется"))
check("находка: консоль UniFi из интернета — стоит поправить", t("warn", "Консоль UniFi"))
check("находка: правило с портом-источником 22", t("warn", "порту-источнику 22"))
check("находка: WireGuard на 51820 — к сведению", t("info", "51820"))
check("находка: IPS работает, SSH по ключу, honeypot — хорошо", t("ok", "IPS работает") and t("ok", "SSH") and t("ok", "honeypot"))
check("находка: Plex и проброс с ограничением по адресам — без тревоги", not any("32400" in x["title"] or "2222" in x["title"] for x in F if x["sev"] in ("crit", "warn")))
check("порядок: сначала «исправить», в конце «хорошо»", F[0]["sev"] == "crit" and F[-1]["sev"] == "ok")
check("оценка: 100 − 25×2 − 8×3 = 26", score == 26, score)
sg = X.sec_suggest(d)
check("рекомендуемое: страны на управление, вход по паролю и консоль (без 25, 80, Plex)", set(sg["SEC_GEO_PORTS"].split()) == {"44300", "8123", "465", "443"}, sg)
# защита включена: порт 25 в «только из стран» — предупреждение; DSM под защитой — без тревоги; блокировки
open(os.path.join(T, "awg.env"), "a").write('SEC_PROTECT=yes\nSEC_GEO_ALLOW="ru"\nSEC_GEO_PORTS="44300 8123 25"\n')
os.makedirs(os.path.join(T, "sec"))
open(os.path.join(T, "sec", "bans.log"), "w").write("%d|trap|45.1.1.1\n1|rate|45.3.3.3\nмусор\n" % (S.now() - 100))
PROT["on"] = True
d = X.sec_collect()
F, score = X.sec_findings(d)
pr = d["protect"]
check("защита: счётчики правил и блокировок", pr["on"] and pr["geo_drop"] == 40 and pr["ban_drop"] == 15 and pr["trap_n"] == 2 and pr["geo_set"] == 9000, pr)
check("защита: заблокированные — по пакетам, оставшееся время", pr["banned"][0] == {"ip": "45.1.1.1", "why": "trap", "left": 80000, "pkts": 12}, pr["banned"])
check("защита: журнал блокировок (новые сверху), за сутки — 1", pr["recent"][0]["ip"] == "45.3.3.3" and len(pr["recent"]) == 2 and pr["day"] == 1, pr["recent"])
check("защита: DSM и HA под ограничением стран — не «исправить»", not t("crit", "Synology DSM") and not t("crit", "Home Assistant"))
check("защита: порт 25 по странам — предупреждение", t("warn", "Порт 25 ограничен"))
check("защита: включена — хорошо", t("ok", "Защита входящих включена"))


class H:
    user = "admin"
    acts = []

    def act(self, a, d=""):
        self.acts.append(a)


def raises(f, *a):
    try:
        f(*a)
        return False
    except ValueError:
        return True


calls = []
X.run = lambda cmd, **k: calls.append(cmd) or (0, "45.1.1.1: блокировка снята")
check("снять блокировку: только IPv4", raises(X.api_security_unban, H(), {"ip": "1.2.3.4; reboot"}))
r = X.api_security_unban(H(), {"ip": "45.1.1.1"})
check("снять блокировку: sec.sh unban, в журнале действий", r["ok"] and calls[-1][1:] == ["unban", "45.1.1.1"] and "sec-unban" in H.acts)
check("настройки: порт — только числа", raises(S.v_ports, "80;id") and S.v_ports("8123, 44300 8123") == "8123 44300")
check("маршруты API", ("GET", "/api/security") in S.ROUTES and ("POST", "/api/security/unban") in S.ROUTES)
check("настройки SEC_* в панели, защита — через awg-guard", all(k in S.SETTINGS and S.SETTINGS[k][1] == ["awg-guard"] for k in ("SEC_PROTECT", "SEC_GEO_ALLOW", "SEC_GEO_PORTS", "SEC_TRAP", "SEC_RATE")))
print("t_security: провалов %d" % len(FAILS))
sys.exit(1 if FAILS else 0)
