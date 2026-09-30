#!/usr/bin/env bash
# Общий хелпер для hooks/scripts/*.sh: читает `version` из
# `.claude-plugin/plugin.json` плагина (issue #154, SPEC-004 AC-5,
# ADR-021). Разбор JSON не дублируется — переиспользует json_field
# (lib/json-field.sh), как paths.sh/config.sh уже переиспользуют друг
# друга (ADR-002: общее — в lib).
#
# Использование:
#   . lib/plugin-version.sh
#   version=$(adk_plugin_version)   # пустая строка, если не удалось
#
# adk_plugin_root — где искать `.claude-plugin/plugin.json`. Две ветки
# (ADR-021):
# - CLAUDE_PLUGIN_ROOT задан (хост Claude Code выставляет его как реальную
#   переменную окружения для хуков/скриптов, а не только подставляет текст
#   в markdown-инструкциях команд) — используется как есть: в
#   потребительском проекте это путь к УСТАНОВЛЕННОМУ кэшу плагина, а не
#   к корню проекта (в корне потребителя `.claude-plugin/plugin.json`
#   вообще не существует — это файл кита, не потребителя).
# - CLAUDE_PLUGIN_ROOT не задан (ручной запуск adk-ralph.sh, шапка файла:
#   "Запускается вручную из корня проекта") — self-location по
#   ${BASH_SOURCE[0]} этого же файла: hooks/scripts/lib/plugin-version.sh
#   всегда лежит тремя каталогами ниже корня плагина, где бы этот корень
#   физически ни находился — в самом ките при догфудинге (эта правка
#   меняет тот же plugin.json, который читает этот хелпер) или в
#   установленном кэше потребителя. В отличие от scripts/ac-check
#   (docs/contract.md) хелпер никуда не копируется из дерева плагина,
#   поэтому self-location не ломается — copy-вариант ac-check.sh такой
#   гарантии лишён и ищет кэш через `find ~/.claude` по этой же причине.
adk_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
  fi
}

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/json-field.sh"

# adk_plugin_version — печатает version из .claude-plugin/plugin.json под
# adk_plugin_root (пустая строка, если файл отсутствует, не парсится как
# JSON, или поля version в нём нет — вызывающий сам решает фолбэк, эта
# функция никогда не падает и не пишет в stderr).
adk_plugin_version() {
  local root plugin_json
  root=$(adk_plugin_root)
  plugin_json="$root/.claude-plugin/plugin.json"
  [ -f "$plugin_json" ] || { printf '%s\n' ""; return 0; }
  json_field "$(cat "$plugin_json" 2>/dev/null)" "version" ""
}
