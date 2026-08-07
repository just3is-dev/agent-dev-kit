#!/usr/bin/env bash
# PostToolUse(Edit|Write): прогоняет контрактный scripts/check по изменённому файлу.
# Нет контракта в проекте — молча пропускаем: плагин безопасен в любом репозитории.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
file_path=$(json_field "$payload" "tool_input.file_path" "")
[ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

# Каталог внутри templates/ кита сам может нести исполняемый scripts/check —
# демонстрационный контракт шаблона, а не корень проекта. Такой каталог не
# должен фиксироваться как root раньше настоящего корня кита (issue #14):
# исключение "$root"/templates/* ниже рассчитано на root = корень кита и не
# сработает, если root = сам каталог шаблона. Отличаем "templates/ кита" от
# случайного каталога templates/ в пути стороннего проекта (или пакета со
# своим контрактом внутри templates/ в монорепе — тот контракт должен
# по-прежнему работать) по маркеру корня кита: .claude-plugin/plugin.json —
# манифест Claude Code плагина, лежащий только в корне самого кита.
in_kit_templates() { # $1: каталог-кандидат в root — лежит ли он внутри
                      # templates/ каталога, чей родитель — корень кита
  s="$1"
  while [ "$s" != "/" ]; do
    p=$(dirname "$s")
    if [ "$(basename "$s")" = "templates" ] && [ -f "$p/.claude-plugin/plugin.json" ]; then
      return 0
    fi
    s="$p"
  done
  return 1
}

# корень проекта = ближайший родитель файла, содержащий scripts/check
dir=$(cd "$(dirname "$file_path")" 2>/dev/null && pwd) || exit 0
root=""
while [ "$dir" != "/" ]; do
  if [ -x "$dir/scripts/check" ] && ! in_kit_templates "$dir"; then
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
