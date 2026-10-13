# Как помочь проекту

Спасибо, что хотите помочь. Ниже — как устроен репозиторий, как проверить изменения и что нужно для принятия pull request.

## Сообщить о проблеме

1. Обновитесь до последней версии: `install.sh --update`.
2. Посмотрите `awgctl diagnose` и `awgctl selftest` — часто там уже есть причина и команда для исправления.
3. Создайте issue по шаблону «Ошибка» и приложите обезличенный отчёт: `awgctl report` (файл `/tmp/awg-report-*.txt`; ключи, токены, chat id и публичные IP в нём скрыты). Всё равно просмотрите его перед отправкой.

Об уязвимостях — не в issue, а приватно: см. [SECURITY.md](SECURITY.md).

## Устройство

| Путь | Что там |
|---|---|
| `install.sh` | установщик, обновление с откатом, каналы, бинарники |
| `awg/*.sh` | службы и команды на роутере: сторож `failover.sh`, `guard.sh`, `self.sh`, `subnets.sh`, `notify.sh`, `backup.sh`, `vps.sh`, `awgctl.sh`… |
| `awg/web/panel.py`, `awg/web/awgweb/` | веб-панель, Python (только стандартная библиотека): `panel.py` — точка входа, код — по модулям в `awgweb/` (core → data → configs → … → server; каждый импортирует предыдущий, ссылок вперёд нет — `tools/check-modules.py`) |
| `awg/web/src/*.js`, `awg/web/static/` | интерфейс: части `src/*.js` склеиваются в один `static/app.js` (`python3 tools/build-app.py`, CI проверяет совпадение); `lang-en.js` — английский |
| `awg/bot.py`, `awg/ha.py` | Telegram-бот, Home Assistant (MQTT) |
| `server/` | скрипты для своего VPS: сборка, сервер AmneziaWG, аудит, смена ключей и обфускации |
| `tests/` | тесты на заглушках, без роутера и root |
| `docs/` | возможности, план проверки на роутере |
| `index.html` | гайд; часть генерируется `tools/sync-guide.py` |

## Правила

- **Не трогать UniFi.** Никаких изменений его настроек, портов и файлов; правила — только в своих цепочках и штатных цепочках PBR, с откатом.
- **Бинарники только из официальных исходников** `github.com/amnezia-vpn`.
- **Без внешних зависимостей на роутере:** bash, coreutils, iptables, `python3` со стандартной библиотекой. Код панели, бота и HA — совместим с **Python 3.7** (на UDR7 — 3.9).
- **Секреты:** права 600, не в аргументах процессов (curl/ssh получают их через stdin), не в журналах, не в ответах API.
- **Опасные действия** в панели — с паролем; изменения, которые могут оборвать связь, — с проверкой и автоматическим откатом.
- Сообщения пользователю — по-русски, понятно, с подсказкой, что делать. Для панели каждая новая строка `T('…')` должна иметь перевод в `lang-en.js`.

## Проверки перед pull request

```bash
bash tests/run.sh                                               # все тесты: установщик, службы, панель, бот, HA, перевод
shellcheck -S warning install.sh awg/*.sh server/*.sh tests/*.sh   # предупреждения блокируют CI
sha256sum install.sh > install.sh.sha256                        # после любой правки install.sh
python3 tools/sync-guide.py                                     # обновить гайд, если менялась справка скриптов
python3 tools/build-app.py                                      # после правки awg/web/src/*.js: собрать static/app.js
python3 tools/check-modules.py                                  # модули панели: нет ссылок вперёд
python3 tools/i18n-check.py                                     # строки панели без перевода
```

Тесты панели в браузере (`tests/t_ui.py`) идут, если установлен Playwright: `pip install playwright && python3 -m playwright install chromium`.

CI повторяет это, а также гоняет панель на Python 3.7–3.12, в Chromium (Playwright) и весь набор на aarch64 (панель, бот и HA — и на Python 3.9, как на UDR7).

Новая возможность — вместе с тестом на заглушках (`tests/t_*.sh` или `tests/t_web.py` на стенде `tests/web_lab.sh`), записью в `CHANGELOG.md` (раздел текущей версии) и, если она видна пользователю, — в README и `docs/TESTPLAN-*.md` (как проверить на роутере).

## Проверка на роутере

План — `docs/TESTPLAN-1.4.md` (разделы по версиям). Сначала только чтение: `awgctl diagnose`, `awgctl drift`, `awg-selftest`, журналы. Переключение каналов, kill switch, перезагрузка и всё, что может оборвать связь, — в удобное время и с доступом к роутеру не через туннель.

## Релиз

Версия в `VERSION`, `INSTALLER_VERSION` в `install.sh`, `VERSION` в `awg/web/awgweb/core.py`, раздел `## X.Y.Z` в `CHANGELOG.md`. Тег `vX.Y.Z` запускает workflow `release`: тесты, архив `udr-amnezia-vX.Y.Z.tar.gz` и `SHA256SUMS` в GitHub Release; канал stable ставит его со сверкой суммы. Релиз создавать вручную не нужно; если он уже создан — workflow дозагрузит в него архив (или запустите его вручную: Actions → release → Run workflow, тег). Релиз без архива канал stable поставить не сможет.
