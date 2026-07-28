#!/usr/bin/env bash
# Stop: агент не может завершить работу, пока scripts/test не проходит.
# Тесты гоняются только если в рабочем дереве есть изменения; успешный прогон
# кэшируется по хэшу diff, чтобы повторные Stop не перезапускали тесты впустую.
set -u

payload=$(cat)
stop_active=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("1" if d.get("stop_hook_active") else "0")
except Exception:
    print("0")
')
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
