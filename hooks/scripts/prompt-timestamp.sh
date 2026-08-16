#!/usr/bin/env bash
# UserPromptSubmit: запоминаем время начала хода. Stop-уведомление «задача
# завершена» придёт только если агент работал дольше порога — защита от
# дзиньканья на каждую реплику в живом диалоге.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
sid=$(json_field "$payload" "session_id" "")
[ -n "$sid" ] || exit 0

mkdir -p "$(adk_notify_state_dir)"
date +%s > "$(adk_notify_ts_file "$sid")"
exit 0
