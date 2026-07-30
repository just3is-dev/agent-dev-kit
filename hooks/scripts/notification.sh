#!/usr/bin/env bash
# Notification: Claude ждёт разрешения или ввода — сообщаем немедленно.
set -u

payload=$(cat)
msg=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("message", ""))
except Exception:
    pass
')
[ -n "$msg" ] || msg="Claude ждёт вашего ответа"

proj=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
"$(cd "$(dirname "$0")" && pwd)/notify-send.sh" "Claude — $proj" "$msg"
exit 0
