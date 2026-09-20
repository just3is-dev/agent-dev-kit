#!/usr/bin/env bash
# Решает, обязателен ли бамп version в PR, который меняет файлы плагина
# (SPEC-004 AC-1, issue #151): сравнивает список изменённых путей PR с
# перечнем «файлов плагина» из docs/contract.md (раздел «Версионирование
# плагина») и version на base/head. Вход фикстурный — сеть и git внутри
# не нужны; сравнение с base-веткой делает вызывающий workflow
# (.github/workflows/version-bump-check.yml).
#
# Использование: version-bump-check.sh <base_version> <head_version>
#   список изменённых путей PR — по одному на строку на stdin.
#
# Перечень «файлов плагина» ниже СИНХРОНИЗИРОВАН с docs/contract.md
# (условия 1 и 2, раздел «Версионирование плагина») — при правке
# перечня в contract.md обнови is_plugin_file() здесь же.
#
# Контракт: среди изменённых путей есть файл плагина и base_version ==
# head_version → сообщение с названием правила и ссылкой на
# docs/contract.md в stderr, exit 1. Иначе — "ok: ..." в stdout, exit 0.
set -u

base_version="${1:-}"
head_version="${2:-}"

if [ -z "$base_version" ] || [ -z "$head_version" ]; then
  echo "usage: version-bump-check.sh <base_version> <head_version> (список изменённых путей на stdin)" >&2
  exit 2
fi

is_plugin_file() { # is_plugin_file <путь> — 0, если путь относится к «файлам плагина» docs/contract.md
  case "$1" in
    # условие 1: загружается механикой Claude Code
    commands/*|agents/*|skills/*|hooks/*|.claude-plugin/plugin.json)
      return 0 ;;
    # условие 2: читается исполняемой частью плагина через
    # ${CLAUDE_PLUGIN_ROOT} в рантайме
    docs/contract.md|docs/config.md|docs/adr/*|templates/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

changed_plugin_files=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_plugin_file "$path"; then
    changed_plugin_files="${changed_plugin_files}${path}"$'\n'
  fi
done

if [ -z "$changed_plugin_files" ]; then
  echo "ok: изменённые пути не относятся к файлам плагина (docs/contract.md) — бамп version не требуется"
  exit 0
fi

if [ "$base_version" = "$head_version" ]; then
  {
    echo "гейт бампа версии: изменены файлы плагина, но version в .claude-plugin/plugin.json не изменилась ($head_version)."
    echo "Правило (docs/contract.md, раздел «Версионирование плагина»): любой PR, меняющий файлы плагина, обязан бампать version (уровень patch — минимум)."
    echo "Изменённые файлы плагина:"
    printf '%s' "$changed_plugin_files" | sed 's/^/  - /'
  } >&2
  exit 1
fi

echo "ok: version изменилась ($base_version -> $head_version) — файлы плагина покрыты бампом"
exit 0
