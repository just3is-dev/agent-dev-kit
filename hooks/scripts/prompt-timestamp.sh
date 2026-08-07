#!/usr/bin/env bash
# UserPromptSubmit: запоминаем время начала хода. Stop-уведомление «задача
# завершена» придёт только если агент работал дольше порога — защита от
# дзиньканья на каждую реплику в живом диалоге.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
sid=$(json_field "$payload" "session_id" "")
[ -n "$sid" ] || exit 0

dir="${TMPDIR:-/tmp}/agent-dev-kit-notify"
mkdir -p "$dir"
date +%s > "$dir/$sid"
exit 0
