#!/usr/bin/env bash
# Notification: Claude ждёт разрешения или ввода — сообщаем немедленно.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
msg=$(json_field "$payload" "message" "")
[ -n "$msg" ] || msg="Claude ждёт вашего ответа"

proj=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
"$(cd "$(dirname "$0")" && pwd)/notify-send.sh" "Claude — $proj" "$msg"
exit 0
