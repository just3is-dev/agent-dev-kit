#!/usr/bin/env bash
# PreToolUse(Bash): запрещает команды, обходящие гейты качества,
# и блокирует коммиты, в изменениях которых похоже на секреты.
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

if printf '%s' "$cmd" | grep -Eq 'gh +pr +merge'; then
  deny "Запрещено: merge PR делает человек после чтения спеки, тестов и вердикта ревьюера. Заверши работу отчётом со ссылкой на PR."
fi

# --- Секрет-гейт: перед git commit сканируем изменения на ключи и .env ---
if printf '%s' "$cmd" | grep -q 'git commit'; then
  proj="${CLAUDE_PROJECT_DIR:-$PWD}"
  if git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    secret_re='sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

    hits=$( (git -C "$proj" diff HEAD 2>/dev/null; git -C "$proj" diff --cached 2>/dev/null) \
      | grep '^+' | grep -v '^+++' | grep -E "$secret_re" | head -3 || true)

    if [ -z "$hits" ]; then
      while IFS= read -r uf; do
        [ -n "$uf" ] || continue
        f="$proj/$uf"
        [ -f "$f" ] || continue
        [ "$(wc -c < "$f")" -lt 1000000 ] || continue
        h=$(grep -E "$secret_re" "$f" 2>/dev/null | head -3 || true)
        if [ -n "$h" ]; then
          hits="$uf: $h"
          break
        fi
      done <<EOF
$(git -C "$proj" ls-files --others --exclude-standard 2>/dev/null | head -200)
EOF
    fi

    env_staged=$(git -C "$proj" diff --cached --name-only 2>/dev/null \
      | grep -E '(^|/)\.env(\.[^/]+)?$' | grep -v '\.env\.example' || true)

    if [ -n "$hits" ]; then
      deny "Запрещено: в изменениях найдено похожее на секрет (ключ/токен). Убери секрет в переменные окружения (.env, не коммитится) и перегенерируй скомпрометированный ключ. Найдено:
$hits"
    fi
    if [ -n "$env_staged" ]; then
      deny "Запрещено: в коммит попадает файл окружения ($env_staged). Файлы .env не коммитятся; для примера используй .env.example без реальных значений."
    fi
  fi
fi

exit 0
