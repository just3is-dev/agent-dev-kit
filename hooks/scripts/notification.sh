#!/usr/bin/env bash
# Notification: Claude ждёт разрешения или ввода — сообщаем немедленно.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
msg=$(json_field "$payload" "message" "")
[ -n "$msg" ] || msg="Claude ждёт вашего ответа"

proj=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
adk_notify_send "Claude — $proj" "$msg"
exit 0
