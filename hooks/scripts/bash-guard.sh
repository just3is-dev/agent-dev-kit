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
  if git_root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$git_root" ]; then
    break
  fi
  git_root=""
done

if printf '%s' "$cmd" | grep -q 'git commit' && printf '%s' "$cmd" | grep -q -- '--no-verify'; then
  deny "Запрещено: git commit --no-verify обходит гейты качества. Найди и устрани причину падения проверок."
fi

if printf '%s' "$cmd" | grep -Eq 'git push[^|;&]*( --force| -f)\b' \
  && printf '%s' "$cmd" | grep -Eq '(^| )(origin|upstream) +(main|master)\b'; then
  deny "Запрещено: force push в main/master."
fi

# Политика merge (SPEC-002 AC-2, policies.merge из adk.config.json):
# - human-only — merge из агентских сессий запрещён всегда;
# - human-review-required — сверх проверки ready требуется человеческий
#   approve на PR (reviewDecision == APPROVED);
# - agent-after-approve (и отсутствие конфига) — только проверка ready:
#   ready — единственный путь после вердикта APPROVE (draft ставится при
#   создании, ready — ревью-процессом), поэтому "не draft" = машинное
#   доказательство апрува.
# Тестовые обходы сетевых вызовов: ADK_GUARD_PR_STATE=draft|ready|unknown,
# ADK_GUARD_PR_REVIEW_DECISION=<reviewDecision, например APPROVED>.
if printf '%s' "$cmd" | grep -Eq 'gh +pr +merge'; then
  . "$(cd "$(dirname "$0")" && pwd)/lib/config.sh"
  # Конфиг ищем от репозитория команды: корень сессии (CLAUDE_PROJECT_DIR,
  # его использует adk_project_root) в мульти-директорной сессии может
  # указывать вне проекта с adk.config.json.
  merge_policy_rc=0
  merge_policy=$(CLAUDE_PROJECT_DIR="${git_root:-${CLAUDE_PROJECT_DIR:-$PWD}}" \
    adk_config_get "policies.merge" "agent-after-approve" \
    "agent-after-approve,human-review-required,human-only") || merge_policy_rc=$?
  # Ненулевой exit читателя = в конфиге неизвестное значение. Дефолт
  # policies.merge — умышленно разрешающий, поэтому опечатку нельзя молча
  # трактовать как его осознанный выбор (docs/config.md) — fail-closed.
  if [ "$merge_policy_rc" -ne 0 ]; then
    deny "Запрещено: неизвестное значение policies.merge в adk.config.json — merge заблокирован, чтобы опечатка молча не откатилась в разрешающий дефолт. Допустимо: agent-after-approve | human-review-required | human-only."
  fi

  if [ "$merge_policy" = "human-only" ]; then
    deny "Запрещено: policies.merge=human-only — merge из агентской сессии запрещён при любом статусе PR; merge делает человек вне процесса."
  fi

  state="${ADK_GUARD_PR_STATE:-}"
  decision="${ADK_GUARD_PR_REVIEW_DECISION:-}"
  gh_isdraft=""
  gh_decision=""
  if [ -z "$state" ] || { [ "$merge_policy" = "human-review-required" ] && [ -z "$decision" ]; }; then
    # Один сетевой вызов на оба поля PR
    prnum=$(printf '%s' "$cmd" | grep -Eo 'gh +pr +merge +[0-9]+' | grep -Eo '[0-9]+' | head -1)
    repo_flag=$(printf '%s' "$cmd" | grep -Eo -- '(-R|--repo)[= ][^ ]+' | head -1 | sed -E 's/^(-R|--repo)[= ]//')
    jq_q='"\(.isDraft) \(.reviewDecision)"'
    if [ -n "$repo_flag" ]; then
      pr_fields=$(gh pr view ${prnum:+"$prnum"} -R "$repo_flag" --json isDraft,reviewDecision -q "$jq_q" 2>/dev/null) || pr_fields=""
    elif [ -n "$git_root" ]; then
      pr_fields=$(cd "$git_root" && gh pr view ${prnum:+"$prnum"} --json isDraft,reviewDecision -q "$jq_q" 2>/dev/null) || pr_fields=""
    else
      pr_fields=""
    fi
    case "$pr_fields" in
      *' '*) gh_isdraft="${pr_fields%% *}"; gh_decision="${pr_fields#* }" ;;
    esac
  fi

  if [ -z "$state" ]; then
    case "$gh_isdraft" in
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

  if [ "$merge_policy" = "human-review-required" ]; then
    [ -n "$decision" ] || decision="$gh_decision"
    if [ "$decision" != "APPROVED" ]; then
      deny "Запрещено: policies.merge=human-review-required — merge только при человеческом approve на PR (reviewDecision=APPROVED); сейчас: ${decision:-approve отсутствует или статус недоступен}."
    fi
  fi
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
