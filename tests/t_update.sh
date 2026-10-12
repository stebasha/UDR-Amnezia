#!/bin/bash
# Обновление со старых установщиков (1.0.0 / 1.1.0): они копировали новый install.sh поверх себя во время работы.
# Имитируем это для каждого размера старого файла и проверяем, что старый bash спокойно завершается на «площадке».
# Запуск: bash tests/t_update.sh [путь/к/install.sh]
H=$(cd "$(dirname "$0")" && pwd)
NEW=$(cd "$(dirname "${1:-$H/../install.sh}")" && pwd)/$(basename "${1:-$H/../install.sh}")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
for size in 64854 64855 76237 76238; do
  f=$T/old-$size.sh
  { echo '#!/bin/bash'; echo 'INSTALLER_VERSION=1.1.0'; } > "$f"
  last="cp \"$NEW\" \"$f\"; echo OLD_DONE"
  pad=$(( size - $(wc -c < "$f") - ${#last} - 1 ))
  # комментарий-заполнитель до нужного размера, последней строкой — «копирование себя», как делал старый --update
  printf '#%*s\n' $((pad - 2)) '' | tr ' ' 'x' >> "$f"
  echo "$last" >> "$f"
  [ "$(wc -c < "$f")" = "$size" ] || { echo "  FAIL размер имитации $size: $(wc -c < "$f")"; fails=$((fails+1)); continue; }
  out=$(timeout 20 bash "$f" </dev/null 2>&1); rc=$?
  if [ $rc = 0 ] && echo "$out" | grep -q OLD_DONE && echo "$out" | grep -q "Скрипты обновлены" && ! echo "$out" | grep -q -i -E "error|ошибка|not found|syntax"; then
    echo "  OK   старый установщик размером $size байт после самообновления завершается чисто"
  else
    echo "  FAIL старый установщик $size байт: rc=$rc"; echo "$out" | head -n 5 | sed 's/^/        /'; fails=$((fails+1))
  fi
done
echo "update: провалов $fails"; [ $fails = 0 ]
