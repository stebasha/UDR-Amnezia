#!/usr/bin/env python3
"""Защитные функции панели без сервера: запись в файлы, которые читает bash (source), и проверки настроек."""
import os, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="awgcore-")
os.environ.update(DD=T, AWG_WEBD=os.path.join(T, "web"), AWG_RUN=T)
sys.path.insert(0, os.path.join(R, "awg/web"))
import awgweb.core as C  # noqa: E402

FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


def raises(f, *a):
    try:
        f(*a)
        return False
    except ValueError:
        return True


# fmt_env: всё, что bash выполнил бы при source, не пишется; остальное читается bash буквально
for bad in ['a$(id)', 'a`id`', 'a"b', 'a\\b', 'a\nB=1', 'a\x00b']:
    check("fmt_env: отказ для %r" % bad, raises(C.fmt_env, "K", bad))
check("fmt_env: имя ключа проверяется", raises(C.fmt_env, "K;rm", "x"))
f = os.path.join(T, "e.env")
for v in ["x;reboot", "a|b&c", "(x)", "1.2.3.4/24", "", "a b", "https://h/p?x=1&y=2", "*"]:
    open(f, "w").write(C.fmt_env("K", v) + "\n")
    out = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$K"', "_", f], capture_output=True, text=True).stdout
    check("fmt_env: bash читает %r буквально" % v, out == v, out)

# проверки настроек
check("домены: команда в имени — отказ", raises(C.v_domains, "a.com;reboot"))
check("домены: из адреса берётся имя", C.v_domains("https://Example.COM/path") == "example.com")
check("подсети/адреса клиентов: мусор — отказ", raises(C.v_hosts, "1.2.3.4 $(id)"))
check("страны: только две буквы", C.v_countries("RU, cn;by") == "ru cn by" and raises(C.v_countries, "rus"))
check("источники списков: только https и без спецсимволов", raises(C.v_https_urls, "http://a.b/x") and raises(C.v_https_urls, "https://a.b/$(id)")
      and raises(C.v_https_urls, "https://a.b/x;y") and C.v_https_urls("https://a.b/x.lst") == "https://a.b/x.lst")
for k, (val, _svc, _lab) in C.SETTINGS.items():
    for bad in ['x$(id)', 'x`id`', 'x"y', 'x;reboot']:
        try:
            v = val(bad)
        except (ValueError, TypeError):
            continue
        check("настройка %s: «%s» не пропускается или безопасна" % (k, bad), not any(c in v for c in '$`";'), v)
print("core: %d ошибок" % len(FAILS))
sys.exit(1 if FAILS else 0)
