#!/usr/bin/env bash
# PreToolUse(Bash): запрещает команды, обходящие гейты качества.
set -u

payload=$(cat)
cmd=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
')
[ -n "$cmd" ] || exit 0

deny() {
  echo "$1" >&2
  exit 2
}

if printf '%s' "$cmd" | grep -q 'git commit' && printf '%s' "$cmd" | grep -q -- '--no-verify'; then
  deny "Запрещено: git commit --no-verify обходит гейты качества. Найди и устрани причину падения проверок."
fi

if printf '%s' "$cmd" | grep -Eq 'git push[^|;&]*( --force| -f)\b' \
  && printf '%s' "$cmd" | grep -Eq '(^| )(origin|upstream) +(main|master)\b'; then
  deny "Запрещено: force push в main/master."
fi

exit 0
