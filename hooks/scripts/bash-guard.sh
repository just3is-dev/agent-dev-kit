#!/usr/bin/env bash
# PreToolUse(Bash): запрещает команды, обходящие гейты качества,
# и блокирует коммиты, в изменениях которых похоже на секреты.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
cmd=$(json_field "$payload" "tool_input.command" "")
[ -n "$cmd" ] || exit 0

deny() {
  echo "$1" >&2
  exit 2
}

# Рабочая директория команды. Корень сессии (CLAUDE_PROJECT_DIR) может не быть
# репозиторием (сессия открыта выше, проект подключён дополнительной
# директорией), поэтому кандидаты в порядке достоверности: явный `cd` в самой
# команде → cwd сессии из payload хука → корень сессии → PWD хука.
hook_cwd=$(json_field "$payload" "cwd" "")
cd_prefix=""
case "$cmd" in
  cd\ *) cd_prefix=$(printf '%s' "$cmd" | sed -E 's/^cd +//; s/ *(&&|;|\|).*$//' | tr -d '"'"'"'') ;;
esac

git_root=""
for d in "$cd_prefix" "$hook_cwd" "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    git_root="$d"
    break
  fi
done

if printf '%s' "$cmd" | grep -q 'git commit' && printf '%s' "$cmd" | grep -q -- '--no-verify'; then
  deny "Запрещено: git commit --no-verify обходит гейты качества. Найди и устрани причину падения проверок."
fi

if printf '%s' "$cmd" | grep -Eq 'git push[^|;&]*( --force| -f)\b' \
  && printf '%s' "$cmd" | grep -Eq '(^| )(origin|upstream) +(main|master)\b'; then
  deny "Запрещено: force push в main/master."
fi

# Политика merge: только PR, прошедший ревью. Ready — единственный путь
# после вердикта APPROVE (draft ставится при создании, ready — ревью-процессом),
# поэтому "не draft" = машинное доказательство апрува.
# ADK_GUARD_PR_STATE=draft|ready|unknown — тестовый обход сетевого вызова.
if printf '%s' "$cmd" | grep -Eq 'gh +pr +merge'; then
  state="${ADK_GUARD_PR_STATE:-}"
  if [ -z "$state" ]; then
    prnum=$(printf '%s' "$cmd" | grep -Eo 'gh +pr +merge +[0-9]+' | grep -Eo '[0-9]+' | head -1)
    repo_flag=$(printf '%s' "$cmd" | grep -Eo -- '(-R|--repo)[= ][^ ]+' | head -1 | sed -E 's/^(-R|--repo)[= ]//')
    if [ -n "$repo_flag" ]; then
      isdraft=$(gh pr view ${prnum:+"$prnum"} -R "$repo_flag" --json isDraft -q .isDraft 2>/dev/null) || isdraft=""
    elif [ -n "$git_root" ]; then
      isdraft=$(cd "$git_root" && gh pr view ${prnum:+"$prnum"} --json isDraft -q .isDraft 2>/dev/null) || isdraft=""
    else
      isdraft=""
    fi
    case "$isdraft" in
      false) state="ready" ;;
      true)  state="draft" ;;
      *)     state="unknown" ;;
    esac
  fi
  case "$state" in
    ready) ;;
    draft) deny "Запрещено: PR ещё черновик — merge возможен только после вердикта APPROVE (в ready PR переводит ревью-процесс, не merge-намерение)." ;;
    *) deny "Запрещено: статус PR проверить не удалось (нет git-репозитория в контексте команды или gh недоступен) — merge только для PR со статусом ready. Подсказка: выполняй merge из директории репозитория или с флагом -R owner/repo." ;;
  esac
fi

# --- Секрет-гейт: перед git commit сканируем изменения на ключи и .env ---
if printf '%s' "$cmd" | grep -q 'git commit' && [ -n "$git_root" ]; then
  secret_re='sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

  hits=$( (git -C "$git_root" diff HEAD 2>/dev/null; git -C "$git_root" diff --cached 2>/dev/null) \
    | grep '^+' | grep -v '^+++' | grep -E "$secret_re" | head -3 || true)

  if [ -z "$hits" ]; then
    while IFS= read -r uf; do
      [ -n "$uf" ] || continue
      f="$git_root/$uf"
      [ -f "$f" ] || continue
      [ "$(wc -c < "$f")" -lt 1000000 ] || continue
      h=$(grep -E "$secret_re" "$f" 2>/dev/null | head -3 || true)
      if [ -n "$h" ]; then
        hits="$uf: $h"
        break
      fi
    done <<EOF
$(git -C "$git_root" ls-files --others --exclude-standard 2>/dev/null | head -200)
EOF
  fi

  env_staged=$(git -C "$git_root" diff --cached --name-only 2>/dev/null \
    | grep -E '(^|/)\.env(\.[^/]+)?$' | grep -v '\.env\.example' || true)

  if [ -n "$hits" ]; then
    deny "Запрещено: в изменениях найдено похожее на секрет (ключ/токен). Убери секрет в переменные окружения (.env, не коммитится) и перегенерируй скомпрометированный ключ. Найдено:
$hits"
  fi
  if [ -n "$env_staged" ]; then
    deny "Запрещено: в коммит попадает файл окружения ($env_staged). Файлы .env не коммитятся; для примера используй .env.example без реальных значений."
  fi
fi

exit 0
