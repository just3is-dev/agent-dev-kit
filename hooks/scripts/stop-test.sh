#!/usr/bin/env bash
# Stop: агент не может завершить работу, пока scripts/test не проходит.
# Тесты гоняются только если в рабочем дереве есть изменения; успешный прогон
# кэшируется по хэшу diff, чтобы повторные Stop не перезапускали тесты впустую.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
# stop_hook_active — JSON-булево; json_field возвращает python-строковое
# представление ("True"/"False") или default при отсутствии поля/ошибке
# разбора. Нормализуем к прежнему "1"/"0", чтобы проверка ниже не менялась.
case "$(json_field "$payload" "stop_hook_active" "False")" in
  True) stop_active=1 ;;
  *) stop_active=0 ;;
esac
session_id=$(json_field "$payload" "session_id" "")

# Уведомление «задача завершена» при успешном выходе (exit 0), если ход
# длился дольше порога (ADK_NOTIFY_MIN_SECONDS, по умолчанию 45 с) —
# короткие реплики живого диалога уведомлений не порождают.
notify_done() {
  [ -n "$session_id" ] || return 0
  ts_file="${TMPDIR:-/tmp}/agent-dev-kit-notify/$session_id"
  [ -f "$ts_file" ] || return 0
  started=$(cat "$ts_file" 2>/dev/null)
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  elapsed=$(( $(date +%s) - started ))
  threshold="${ADK_NOTIFY_MIN_SECONDS:-45}"
  [ "$elapsed" -ge "$threshold" ] || return 0
  proj_name=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
  adk_notify_send "Claude — $proj_name" "Задача завершена (${elapsed} c), гейты зелёные"
}
on_exit() {
  status=$?
  [ "$status" -eq 0 ] && notify_done
  exit "$status"
}
trap on_exit EXIT

# защита от цикла: этот Stop уже вызван из-за нашего же блокирующего хука
[ "$stop_active" = "1" ] && exit 0

proj="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -x "$proj/scripts/test" ] || exit 0
cd "$proj" || exit 0

cache_dir=""
current_hash=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
  if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$untracked" ]; then
    exit 0
  fi
  cache_dir="$(git rev-parse --git-dir)/agent-dev-kit"
  mkdir -p "$cache_dir"
  current_hash=$(
    {
      git diff 2>/dev/null
      git diff --cached 2>/dev/null
      if [ -n "$untracked" ]; then
        printf '%s\n' "$untracked" | tr '\n' '\0' | xargs -0 shasum 2>/dev/null
      fi
    } | shasum | cut -d' ' -f1
  )
  if [ -f "$cache_dir/tests-passed" ] && [ "$(cat "$cache_dir/tests-passed")" = "$current_hash" ]; then
    exit 0
  fi
fi

output=$(./scripts/test 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
  {
    echo "scripts/test провалился (exit $status). Работа не завершена, пока тесты не проходят:"
    printf '%s\n' "$output" | tail -n 80
  } >&2
  exit 2
fi

if [ -n "$cache_dir" ] && [ -n "$current_hash" ]; then
  printf '%s' "$current_hash" > "$cache_dir/tests-passed"
fi
exit 0
