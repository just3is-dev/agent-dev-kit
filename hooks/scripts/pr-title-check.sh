#!/usr/bin/env bash
# PostToolUse(Bash): после gh pr create/edit сверяет фактический заголовок PR
# (gh pr view) с конвенцией conventions.commitStyle=conventional (SPEC-002,
# AC-5). Заголовок PR — будущее сообщение squash-коммита в main, единственная
# точка контроля конвенции (веточные коммиты squash схлопывает).
# Валидируется состояние PR, а не текст команды — разбора shell нет вовсе:
# PreToolUse-парсинг команд давал пары «ложный запрет / молчаливый пропуск»
# на кавычках, heredoc и подстановках (ADR-004, круги ревью PR #62).
# Exit 2 — не блок (действие уже случилось), а требование исправить заголовок
# через gh pr edit; после исправления хук молчит.
# Не вмешиваемся: при plain (дефолт — проект без конфига ведёт себя как
# сегодня) и при conventions.externalTitleLint=true (серверный линтер
# заголовков уже есть — не переизобретаем, «Границы» SPEC-002).
# Тестовые обходы сети (по образцу ADK_GUARD_PR_STATE):
# ADK_GUARD_PR_TITLE — фактический заголовок PR ("unavailable" — gh или PR
# недоступны); ADK_GUARD_ISSUE_LABELS — CSV labels issue (пустая строка —
# labels нет; "unavailable" — gh или issue недоступны).
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/config.sh"
cmd=$(json_field "$payload" "tool_input.command" "")
[ -n "$cmd" ] || exit 0

# Дешёвый фильтр: команда упоминает gh pr create/edit. Ложное срабатывание
# (упоминание в heredoc или доке) безвредно: проверяется фактический
# заголовок PR текущей ветки — если он корректен или PR нет, хук молчит.
printf '%s' "$cmd" | grep -Eq 'gh +pr +(create|edit)' || exit 0

fix_required() {
  echo "$1" >&2
  exit 2
}

# Репозиторий команды — те же кандидаты, что в bash-guard: явный cd в команде
# → cwd сессии из payload → корень сессии → PWD хука; корень — git toplevel.
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

cfg_root="${git_root:-${CLAUDE_PROJECT_DIR:-$PWD}}"
style=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.commitStyle plain conventional,plain)
ext_lint=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.externalTitleLint false)
[ "$style" = "conventional" ] || exit 0
[ "$ext_lint" != "true" ] || exit 0

# Фактический заголовок: явный номер PR из команды (gh pr edit 12), иначе PR
# текущей ветки. gh недоступен или PR не найден — проверять нечего (fail-open).
prnum=$(printf '%s' "$cmd" | grep -Eo 'gh +pr +(create|edit) +[0-9]+' | grep -Eo '[0-9]+' | head -1)
repo_flag=$(printf '%s' "$cmd" | grep -Eo -- '(-R|--repo)[= ][^ ]+' | head -1 | sed -E 's/^(-R|--repo)[= ]//')
if [ -n "${ADK_GUARD_PR_TITLE+x}" ]; then
  [ "$ADK_GUARD_PR_TITLE" != "unavailable" ] || exit 0
  title="$ADK_GUARD_PR_TITLE"
  pr_ref="${prnum:-<N>}"
else
  jq_q='"\(.number) \(.title)"'
  if [ -n "$repo_flag" ]; then
    pr_fields=$(gh pr view ${prnum:+"$prnum"} -R "$repo_flag" --json number,title -q "$jq_q" 2>/dev/null) || pr_fields=""
  elif [ -n "$git_root" ]; then
    pr_fields=$(cd "$git_root" && gh pr view ${prnum:+"$prnum"} --json number,title -q "$jq_q" 2>/dev/null) || pr_fields=""
  else
    pr_fields=""
  fi
  case "$pr_fields" in
    *' '*) pr_ref="${pr_fields%% *}"; title="${pr_fields#* }" ;;
    *) exit 0 ;;
  esac
fi

if ! printf '%s' "$title" | grep -Eq '\(#[0-9]+\)$'; then
  fix_required "Заголовок PR не соответствует конвенции: conventions.commitStyle=conventional требует завершать заголовок ссылкой на issue «(#N)» — он станет сообщением squash-коммита в main. Сейчас: «$title». Исправь: gh pr edit $pr_ref --title \"<commitType>[(scope)]: <суть> (#N)\"."
fi
issue_n=$(printf '%s' "$title" | grep -Eo '\(#[0-9]+\)$' | grep -Eo '[0-9]+')

if [ -n "${ADK_GUARD_ISSUE_LABELS+x}" ]; then
  labels="$ADK_GUARD_ISSUE_LABELS"
elif [ -n "$repo_flag" ] && labels_raw=$(gh issue view "$issue_n" -R "$repo_flag" --json labels -q '.labels[].name' 2>/dev/null); then
  labels=$(printf '%s' "$labels_raw" | tr '\n' ',')
elif [ -n "$git_root" ] \
  && labels_raw=$(cd "$git_root" && gh issue view "$issue_n" --json labels -q '.labels[].name' 2>/dev/null); then
  labels=$(printf '%s' "$labels_raw" | tr '\n' ',')
else
  labels="unavailable"
fi

# Вердикт по карте типов: дефолтные четыре (docs/config.md), поверх —
# переопределения и кастомные типы из types.* конфига (только label и
# commitType — остальные поля типов хуку не нужны). Формат заголовка
# проверяется от известных commitType (алфавит не ограничивается);
# labels=unavailable — сверка с label пропускается, формат остаётся.
types_json=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get types "{}")
verdict=$(python3 -c '
import json, re, sys
types_json, labels_csv, title = sys.argv[1:4]
types = {
    "task": {"label": "type:task", "commitType": "feat"},
    "bug": {"label": "type:bug", "commitType": "fix"},
    "fastFollow": {"label": "type:fast-follow", "commitType": "fix"},
    "consolidate": {"label": "type:consolidate", "commitType": "refactor"},
}
try:
    cfg = json.loads(types_json)
except Exception:
    cfg = {}
if isinstance(cfg, dict):
    for name, o in cfg.items():
        if isinstance(o, dict):
            t = types.setdefault(name, {})
            for k in ("label", "commitType"):
                if isinstance(o.get(k), str):
                    t[k] = o[k]
commit_types = sorted({t["commitType"] for t in types.values() if t.get("commitType")})
m = re.match(r"^(\S+?)(\([^)]*\))?: .+", title)
if not m or m.group(1) not in commit_types:
    print("format " + "|".join(commit_types))
    sys.exit(0)
if labels_csv == "unavailable":
    print("ok")
    sys.exit(0)
labels = [l.strip() for l in labels_csv.split(",") if l.strip()]
label_map = {t["label"]: t["commitType"] for t in types.values() if t.get("label") and t.get("commitType")}
matched = [l for l in labels if l in label_map]
expected = label_map[matched[0]] if matched else types["task"]["commitType"]
if m.group(1) == expected:
    print("ok")
else:
    # expected — последним: commitType из конфига может содержать пробел,
    # последнее поле read забирает остаток строки целиком
    print("mismatch %d %s %s" % (1 if matched else 0, m.group(1), expected))
' "$types_json" "$labels" "$title")
case "$verdict" in
  ok) ;;
  format\ *)
    fix_required "Заголовок PR не соответствует конвенции: conventions.commitStyle=conventional требует формат «<commitType>[(scope)]: <суть> (#N)», где commitType — один из: ${verdict#format }. Сейчас: «$title». Исправь: gh pr edit $pr_ref --title \"...\"." ;;
  mismatch\ *)
    read -r _ vt_has vt_got vt_exp <<VERDICT_EOF
$verdict
VERDICT_EOF
    if [ "$vt_has" = "1" ]; then
      fix_required "commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — по label issue ожидается «$vt_exp». Исправь: gh pr edit $pr_ref --title \"$vt_exp[(scope)]: <суть> (#$issue_n)\"."
    else
      fix_required "commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — у issue нет label типа, он трактуется как task, ожидается «$vt_exp» (или проставь issue label типа). Исправь: gh pr edit $pr_ref --title \"$vt_exp[(scope)]: <суть> (#$issue_n)\"."
    fi ;;
esac
exit 0
