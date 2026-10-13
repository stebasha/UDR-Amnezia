#!/bin/bash
# shellcheck disable=SC2034,SC1090  # переменные используются в строках для eval (проверки t/ck), источники — заглушки
# notify.sh (#14): Telegram с резервированием, вебхук и ntfy, коды возврата, секреты не в аргументах curl.
# Запуск: bash tests/t_notify.sh <папка со скриптами awg>
H=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${1:-$H/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd STUB=$T/stub
mkdir -p "$DD" "$STUB" "$T/bin"
cp "$SRC/notify.sh" "$DD/"; chmod 755 "$DD/notify.sh"
printf 'MAIN=awgmain\nBACKUP=awgbackup\n' > "$DD/awg.env"
# curl: url из -K (stdin) или аргументов; ответ — из $STUB/code.<цель>[.<интерфейс>], по умолчанию 200
cat > "$T/bin/curl" <<'S'
#!/bin/bash
cfg=$(cat); i=""; u=""; a=("$@")
for ((k=0; k<${#a[@]}; k++)); do case "${a[k]}" in --interface) i=${a[k+1]};; http*) u=${a[k]};; esac; done
[ -z "$u" ] && u=$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')
case "$u" in *api.telegram.org*) tg=tg;; *ntfy*) tg=ntfy;; *) tg=hook;; esac
{ printf 'CALL %s if=%s\nARGS' "$tg" "${i:-wan}"; printf ' [%s]' "$@"; printf '\nCFG %s\n' "$(printf '%s' "$cfg" | tr '\n' ' ')"; } >> "$STUB/curl.log"
c=200; [ -f "$STUB/code.$tg.${i:-wan}" ] && c=$(cat "$STUB/code.$tg.${i:-wan}"); [ -f "$STUB/code.$tg" ] && c=$(cat "$STUB/code.$tg")
printf '%s' "$c"
S
printf '#!/bin/bash\nexit 3\n' > "$T/bin/systemctl"
chmod 755 "$T"/bin/*
export PATH="$T/bin:$PATH"
fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
N="$DD/notify.sh"
calls(){ cat "$STUB/curl.log" 2>/dev/null | grep -c "^CALL $1"; }
reset(){ rm -f "$STUB"/curl.log "$STUB"/code.* "$DD/notify.spool" "$DD/notify.log"; }

ck "ничего не настроено → код 2" '"$N" "текст"; [ $? = 2 ]'

# --- только вебхук и ntfy
printf 'HOOK_URL="https://hooks.example.com/secret-path"\nHOOK_HEADER="Authorization: Bearer hook-secret"\nNTFY_URL="https://ntfy.example.com/udr"\nNTFY_TOKEN="tk_ntfysecret"\n' > "$DD/hooks.env"
reset; "$N" --html "🛑 <b>Все каналы недоступны</b> · r &amp; x"; rc=$?
ck "хуки: код 0, вебхук и ntfy вызваны" '[ $rc = 0 ] && [ "$(calls hook)" = 1 ] && [ "$(calls ntfy)" = 1 ] && [ "$(calls tg)" = 0 ]'
js=$(grep -A1 "^CALL hook" "$STUB/curl.log" | grep -o "\[{.*}\]" | tr -d '[]')
ck "вебхук: JSON с уровнем critical и текстом без HTML" 'echo "$js" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"level\"]==\"critical\" and d[\"text\"]==\"🛑 Все каналы недоступны · r & x\" and d[\"source\"]==\"udr-amnezia\" and d[\"host\"] and d[\"time\"]>0"'
ck "ntfy: приоритет 5, заголовок, текст" 'grep -A1 "^CALL ntfy" "$STUB/curl.log" | grep -q "\[Priority: 5\]" && grep -A1 "^CALL ntfy" "$STUB/curl.log" | grep -q "\[Title: UDR-Amnezia · "'
ck "секреты (путь вебхука, заголовок, токен ntfy) не в аргументах curl" '! grep "^ARGS" "$STUB/curl.log" | grep -qE "secret-path|hook-secret|tk_ntfysecret" && grep -q "header = \"Authorization: Bearer hook-secret\"" "$STUB/curl.log" && grep -q "Bearer tk_ntfysecret" "$STUB/curl.log"'
reset; echo 500 > "$STUB/code.hook"; echo 403 > "$STUB/code.ntfy"
ck "хуки не доставлены → код 1, причина в журнале" '! "$N" "⚠️ тест" && grep -q "вебхук: HTTP 500" "$DD/notify.log" && grep -q "ntfy: HTTP 403" "$DD/notify.log"'
reset; echo 500 > "$STUB/code.hook"
ck "доставлено хоть куда-то → код 0" '"$N" "✅ тест"'
ck "ntfy: «✅» — обычный приоритет" 'grep -A1 "^CALL ntfy" "$STUB/curl.log" | grep -q "\[Priority: 3\]"'

# --- Telegram + хуки
printf 'TG_TOKEN=123:tok\nTG_CHAT="111 222"\nTG_VIEWERS="333"\n' > "$DD/telegram.env"
reset; "$N" "событие"; rc=$?
ck "оба канала: Telegram всем трём чатам и хуки" '[ $rc = 0 ] && [ "$(calls tg)" = 3 ] && [ "$(calls hook)" = 1 ] && [ "$(calls ntfy)" = 1 ]'
ck "Telegram: токен не в аргументах" '! grep "^ARGS" "$STUB/curl.log" | grep -q "123:tok"'
reset; "$N" --only hooks "только хуки"
ck "--only hooks: Telegram не трогается" '[ "$(calls tg)" = 0 ] && [ "$(calls hook)" = 1 ]'
reset; "$N" --only telegram "только Telegram"
ck "--only telegram: хуки не трогаются" '[ "$(calls tg)" = 3 ] && [ "$(calls hook)" = 0 ]'
reset; echo 000 > "$STUB/code.tg.awgmain"
"$N" "через запасной"; rc=$?
ck "Telegram: основной туннель не пустил — запасной" '[ $rc = 0 ] && grep -q "^CALL tg if=awgbackup" "$STUB/curl.log" && grep -q "доставлено через awgbackup" "$DD/notify.log"'
reset; echo 000 > "$STUB/code.tg"
ck "Telegram недоступен: код 1, сообщение отложено, хуки ушли" '! "$N" "отложить" && [ -s "$DD/notify.spool" ] && [ "$(calls hook)" = 1 ]'
rm -f "$STUB/code.tg"; : > "$STUB/curl.log"
"$N" "следующее"
ck "отложенное уходит со следующим" '[ ! -s "$DD/notify.spool" ] && grep -q "отложено" <(grep "^ARGS" "$STUB/curl.log" | grep "chat_id=111")'
rm -f "$DD/hooks.env"; reset
ck "без hooks.env — только Telegram" '"$N" "x" && [ "$(calls hook)" = 0 ] && [ "$(calls tg)" = 3 ]'
echo "== notify: ошибок $fails"
[ $fails = 0 ]
