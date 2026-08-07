#!/usr/bin/env bash
# Общий хелпер для hooks/scripts/*.sh: определение корня проекта и пути к
# каталогу журнала (issue #23). До этой правки идентичный блок был
# продублирован построчно в adk-log.sh и adk-stats.sh.
#
# Правило корня (adk_project_root): $CLAUDE_PROJECT_DIR, иначе git-фолбэк
# (git rev-parse --show-toplevel), иначе $PWD. Используют только
# adk-log.sh/adk-stats.sh — у stop-test.sh/notification.sh своё, более
# простое правило (${CLAUDE_PROJECT_DIR:-$PWD}, без git-фолбэка) и оно
# сознательно оставлено как есть: унификация изменила бы их наблюдаемое
# поведение при отсутствии CLAUDE_PROJECT_DIR (см. docs/adr/002-shared-hook-lib-paths.md).
#
# Использование:
#   root=$(adk_project_root)
#   logs_dir=$(adk_logs_dir "$root")

adk_project_root() {
  local root="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  fi
  printf '%s\n' "$root"
}

# adk_logs_dir <root> — печатает путь к каталогу журнала: $ADK_LOGS_DIR,
# если задан, иначе "<root>/.adk/logs". Не создаёт каталог и не трогает
# .adk/.gitignore — это остаётся на вызывающем (только adk-log.sh это делает).
adk_logs_dir() {
  local root="$1"
  if [ -n "${ADK_LOGS_DIR:-}" ]; then
    printf '%s\n' "$ADK_LOGS_DIR"
  else
    printf '%s\n' "$root/.adk/logs"
  fi
}

# adk_notify_send <title> <message> — вызывает notify-send.sh рядом со
# скриптом-вызывающим. До этой правки выражение
# "$(cd "$(dirname "$0")" && pwd)/notify-send.sh" дублировалось в
# stop-test.sh и notification.sh. $0 внутри функции — это $0 вызывающего
# скрипта (bash не меняет его при вызове функции), поэтому путь
# разрешается так же, как и раньше.
adk_notify_send() {
  "$(cd "$(dirname "$0")" && pwd)/notify-send.sh" "$@"
}
