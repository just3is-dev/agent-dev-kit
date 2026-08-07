#!/usr/bin/env bash
# Общий хелпер для хуков: достаёт поле из JSON-payload хука по пути через
# точку (например "tool_input.file_path"). Один инлайн python3 вместо
# отдельной копии в каждом хуке (issue #22) — до этой правки один и тот же
# разбор stdin-JSON существовал в трёх слегка разных стилях в шести местах.
#
# Использование:
#   value=$(json_field "$payload" "tool_input.file_path" "<дефолт>")
#
# Возвращает $3 (по умолчанию — пустая строка), если путь отсутствует в
# JSON (на любом уровне вложенности) или сам payload не парсится как JSON.
# Не предназначен для булевых полей уровня верхнего JSON (например
# stop_hook_active) — вызывающий сам решает, как трактовать полученную
# python-строку "True"/"False".
json_field() {
  local payload="$1" path="$2" default="${3:-}"
  printf '%s' "$payload" | python3 -c '
import json, sys

path = sys.argv[1]
default = sys.argv[2]
try:
    d = json.load(sys.stdin)
    for key in path.split("."):
        d = d.get(key) if isinstance(d, dict) else None
        if d is None:
            break
    print(default if d is None else d)
except Exception:
    print(default)
' "$path" "$default"
}
