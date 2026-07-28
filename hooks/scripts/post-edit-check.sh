#!/usr/bin/env bash
# PostToolUse(Edit|Write): прогоняет контрактный scripts/check по изменённому файлу.
# Нет контракта в проекте — молча пропускаем: плагин безопасен в любом репозитории.
set -u

payload=$(cat)
file_path=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
')
[ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

# корень проекта = ближайший родитель файла, содержащий scripts/check
dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd) || exit 0
root=""
while [ "$dir" != "/" ]; do
  if [ -x "$dir/scripts/check" ]; then
    root="$dir"
    break
  fi
  dir=$(dirname "$dir")
done
[ -n "$root" ] || exit 0

# сам плагин и его шаблоны не проверяем контрактом целевого проекта
case "$file_path" in
  "$root"/templates/*) exit 0 ;;
esac

output=$(cd "$root" && ./scripts/check "$file_path" 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  {
    echo "scripts/check провалился для $file_path (exit $status). Исправь ошибки, прежде чем продолжать:"
    printf '%s\n' "$output" | tail -n 60
  } >&2
  exit 2
fi
exit 0
