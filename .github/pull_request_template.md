## Что меняется

<!-- Кратко: что и зачем. Ссылка на issue: Closes #… -->

## Проверено

- [ ] `bash tests/run.sh` — все тесты проходят
- [ ] `shellcheck -S warning install.sh awg/*.sh server/*.sh tests/*.sh` — чисто
- [ ] после правки `install.sh`: `sha256sum install.sh > install.sh.sha256`
- [ ] новые строки панели переведены (`python3 tools/i18n-check.py`)
- [ ] запись в `CHANGELOG.md`; видимое пользователю — в README и плане проверки
- [ ] настройки UniFi не меняются; секреты не попадают в аргументы процессов, журналы и ответы API
- [ ] на роутере (если проверялось): `awgctl selftest` без FAIL, `awgctl drift` чистый
