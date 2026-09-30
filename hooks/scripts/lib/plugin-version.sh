#!/usr/bin/env bash
# Общий хелпер для hooks/scripts/*.sh: читает `version` из
# `.claude-plugin/plugin.json` плагина (issue #154, SPEC-004 AC-5).
# Разбор JSON не дублируется — переиспользует json_field
# (lib/json-field.sh), как paths.sh/config.sh уже переиспользуют друг
# друга (ADR-002: общее — в lib). Как adk_plugin_root находит
# plugin.json что в самом ките (догфудинг), что в установленном кэше
# потребителя, и почему не так, как ищет его copy-вариант ac-check.sh
# (docs/contract.md) — docs/adr/021-plugin-version-lookup.md.
#
# Использование:
#   . lib/plugin-version.sh
#   version=$(adk_plugin_version)   # пустая строка, если не удалось
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
