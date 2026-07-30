#!/usr/bin/env bash
# UserPromptSubmit: запоминаем время начала хода. Stop-уведомление «задача
# завершена» придёт только если агент работал дольше порога — защита от
# дзиньканья на каждую реплику в живом диалоге.
set -u

payload=$(cat)
sid=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id", ""))
except Exception:
    pass
')
[ -n "$sid" ] || exit 0

dir="${TMPDIR:-/tmp}/agent-dev-kit-notify"
mkdir -p "$dir"
date +%s > "$dir/$sid"
exit 0
