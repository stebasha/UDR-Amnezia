#!/usr/bin/env python3
"""Панель в настоящем браузере (#15): Playwright + Chromium на стенде web_lab, без роутера.
Сценарии: вход, обзор, все страницы и вкладки настроек без ошибок JS, редактор туннеля (ошибки видны, предпросмотр,
Esc закрывает только верхнее окно, история растёт), перезагрузка (диалог, неверный пароль), EN/RU.
Ловит регрессии 1.4.2: Esc закрывал редактор вместе с окном подтверждения, ошибка проверки оставалась вне экрана.
Запуск: python3 tests/t_ui.py   (нужен пакет playwright и Chromium: pip install playwright && playwright install chromium)"""
import os
import re
import subprocess
import sys
import tempfile

try:
    from playwright.sync_api import sync_playwright, expect
except ImportError:
    print("ui: пропущено — нет пакета playwright (pip install playwright && playwright install chromium)")
    sys.exit(0 if os.environ.get("AWG_UI_OPTIONAL") else 1)

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB = tempfile.mkdtemp(prefix="awgui-")
PORT = int(os.environ.get("AWG_UI_PORT", "18493"))
URL = "http://127.0.0.1:%d/" % PORT
PW = "Test-pass-123"
FAILS = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)[:300]))
    if not cond:
        FAILS.append(name)


def step(name, fn):
    """Сценарий: исключение (таймаут ожидания и т. п.) — провал этого сценария, остальные продолжаются."""
    try:
        fn()
    except Exception as ex:  # noqa: BLE001 — любой сбой сценария считается провалом
        check(name, False, repr(ex)[:300])


def launch(p):
    exe = os.environ.get("AWG_CHROMIUM")
    if not exe and os.path.exists("/opt/pw-browsers/chromium"):
        exe = "/opt/pw-browsers/chromium"
    try:
        return p.chromium.launch(**({"executable_path": exe} if exe and os.path.isfile(exe) else {}))
    except Exception:
        return p.chromium.launch()


def main():
    pid = subprocess.check_output([os.path.join(R, "tests/web_lab.sh"), LAB, str(PORT)]).decode().strip().splitlines()[-1]
    errors = []
    try:
        with sync_playwright() as p:
            br = launch(p)
            ctx = br.new_context(viewport={"width": 1280, "height": 800}, locale="ru-RU")
            page = ctx.new_page()
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda m: m.type == "error" and not re.search(r"status of 4\d\d", m.text) and errors.append(m.text))
            page.set_default_timeout(15000)

            def login():
                page.goto(URL)
                page.fill("#lu", "admin")
                page.fill("#lp", "wrong-password")
                page.click("button[type=submit]")
                expect(page.locator(".login .alert.crit")).to_be_visible()
                check("вход: неверный пароль — сообщение на форме", True)
                page.fill("#lp", PW)
                page.click("button[type=submit]")
                expect(page.get_by_text("Канал", exact=True).first).to_be_visible()
                check("вход: после верного пароля — обзор", "#/overview" in page.url, page.url)
            step("вход", login)

            def pages():
                for h in ("#/overview", "#/tunnels", "#/routing", "#/tools", "#/system", "#/logs/events"):
                    page.goto(URL + h)
                    page.wait_for_timeout(700)
                    check("страница %s открывается" % h, page.locator("#app main, #app .main, main").count() > 0 and not errors, errors[-3:])
                tabs = ("failover", "services", "telegram", "ha", "users", "web", "backups", "routes", "vps", "xui", "system")
                for t in tabs:
                    page.goto(URL + "#/settings/" + t)
                    page.wait_for_timeout(700)
                    check("настройки → %s без ошибок JS" % t, not errors, errors[-3:])
            step("страницы", pages)

            def lists_form():
                page.goto(URL + "#/routing")
                card = page.locator(".card", has=page.get_by_text("Списки, GeoIP и исключения", exact=True))
                expect(card.first).to_be_visible()
                txt = card.first.inner_text()
                check("маршрутизация: исключения в обе стороны — в форме списков и GeoIP",
                      all(k in txt for k in ("LISTS_MODE", "GEO_COUNTRIES", "DIRECT_DOMAINS", "TUN_DOMAINS")), txt[:300])
                check("маршрутизация: отдельных форм доменов и исключений больше нет",
                      page.get_by_text("Исключения: напрямую мимо туннеля", exact=True).count() == 0)
            step("форма списков", lists_form)

            def editor():
                page.goto(URL + "#/tunnels")
                page.get_by_role("button", name="Настроить").first.click()
                ed = page.locator(".modal-bg").nth(0)        # редактор — первое окно; окно подтверждения ляжет поверх
                expect(ed.get_by_text("Параметры", exact=True)).to_be_visible()
                hist0 = int(re.search(r"История \((\d+)\)", ed.inner_text()).group(1))
                mtu = ed.locator(".field", has=page.locator("label", has_text=re.compile(r"^MTU"))).locator("input")
                mtu.fill("abc")
                ed.get_by_role("button", name="Проверить и применить").click()
                bad = ed.locator(".res.bad")
                expect(bad).to_be_visible()
                check("редактор: ошибка проверки показана", "Не принято" in bad.inner_text(), bad.inner_text())
                page.wait_for_timeout(600)
                box, vh = bad.bounding_box(), page.viewport_size["height"]
                check("редактор: ошибка прокручена в видимую область (регрессия 1.4.2)", box and 0 <= box["y"] < vh, box)
                expect(page.locator(".toast").last).to_contain_text("Не принято")
                mtu.fill("1400")
                ed.get_by_role("button", name="Проверить и применить").click()
                expect(page.get_by_text("Проверьте изменения", exact=False)).to_be_visible()
                n = page.locator(".modal-bg").count()
                page.keyboard.press("Escape")
                page.wait_for_timeout(300)
                check("Esc закрывает только верхнее окно (регрессия 1.4.2)", page.locator(".modal-bg").count() == n - 1 and ed.is_visible(),
                      page.locator(".modal-bg").count())
                ed.get_by_role("button", name="Проверить и применить").click()
                cm = page.locator(".modal-bg").nth(1)
                cm.get_by_role("button", name="Применить").click()
                expect(page.locator(".toast").last).to_contain_text("Конфиг применён")
                expect(ed.get_by_text(re.compile(r"История \((?!%d\))\d+\)" % hist0))).to_be_visible()
                hist1 = int(re.search(r"История \((\d+)\)", ed.inner_text()).group(1))
                check("редактор: после применения «История» выросла (%d → %d)" % (hist0, hist1), hist1 > hist0)
                page.keyboard.press("Escape")
                page.wait_for_timeout(300)
                check("Esc закрывает редактор", page.locator(".modal-bg").count() == 0, page.locator(".modal-bg").count())
            step("редактор туннеля", editor)

            def vless():
                page.goto(URL + "#/tunnels")
                page.get_by_role("button", name="VLESS", exact=True).click()
                dlg = page.locator(".modal-bg").last
                expect(dlg.get_by_text("Подписки", exact=True)).to_be_visible()
                txt = dlg.inner_text()
                check("VLESS: окно — Xray, подписки, туннели", "Xray" in txt and "Добавить подписку" in txt and "Туннели VLESS" in txt, txt[:300])
                check("VLESS: без Xray — кнопка «Установить Xray»", dlg.get_by_role("button", name="Установить Xray").count() == 1)
                page.keyboard.press("Escape")
                page.wait_for_timeout(300)
                check("VLESS: окно закрывается", page.locator(".modal-bg").count() == 0)
            step("VLESS", vless)

            def reboot():
                page.goto(URL + "#/overview")
                page.get_by_role("button", name="Перезагрузить").first.click()
                dlg = page.locator(".modal-bg").nth(0)
                expect(dlg.get_by_text("Перезагрузить роутер?")).to_be_visible()
                dlg.locator("input[type=password]").fill("wrong")
                dlg.get_by_role("button", name="Перезагрузить").click()
                expect(page.locator(".toast").last).to_contain_text("пароль")
                check("перезагрузка: неверный пароль — отказ, диалог открыт", dlg.is_visible())
                srl = os.path.join(LAB, "systemd-run.log")
                check("перезагрузка не запущена", not os.path.exists(srl) or "awg-reboot" not in open(srl).read())
                page.keyboard.press("Escape")
                page.wait_for_timeout(300)
                check("перезагрузка: Esc закрывает диалог", page.locator(".modal-bg").count() == 0)
            step("перезагрузка", reboot)

            def lang():
                page.evaluate("localStorage.setItem('awg-lang', 'en')")
                page.goto(URL + "#/overview")
                page.reload()
                expect(page.get_by_text("Channel", exact=True).first).to_be_visible()
                check("EN: обзор на английском", page.get_by_role("button", name="Reboot").count() > 0)
                page.goto(URL + "#/settings/vps")
                page.wait_for_timeout(700)
                body = page.locator("#app").inner_text()
                cyr = [w for w in re.findall(r"[А-Яа-яЁё]{4,}", body)][:5]
                check("EN: на странице «Свой VPS» нет русских слов", not cyr, cyr)
                page.evaluate("localStorage.setItem('awg-lang', 'ru')")
                page.reload()
                expect(page.get_by_text("Свой VPS", exact=False).first).to_be_visible()
                check("RU: язык возвращается", True)
            step("язык", lang)

            check("в консоли нет ошибок JS", not errors, errors[:5])
            br.close()
    finally:
        subprocess.call(["kill", pid])
    print("\nui: %d ошибок" % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
