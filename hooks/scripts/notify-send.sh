#!/usr/bin/env bash
# Локальное уведомление: macOS (osascript) или Linux (notify-send).
# Тестовый режим: ADK_NOTIFY_FILE=путь — вместо уведомления строка в файл.
title="${1:-Claude Code}"
msg="${2:-}"

if [ -n "${ADK_NOTIFY_FILE:-}" ]; then
  printf '%s|%s\n' "$title" "$msg" >> "$ADK_NOTIFY_FILE"
  exit 0
fi

if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${msg//\"/}\" with title \"${title//\"/}\" sound name \"Glass\"" >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$msg" >/dev/null 2>&1 || true
fi
exit 0
