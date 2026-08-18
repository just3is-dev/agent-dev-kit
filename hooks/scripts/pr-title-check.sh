#!/usr/bin/env bash
# PostToolUse(Bash): после gh pr create/edit сверяет фактический заголовок PR
# (gh pr view) с конвенцией conventions.commitStyle=conventional (SPEC-002,
# AC-5). При дефолтном squash-merge заголовок PR — будущее сообщение
# squash-коммита в main, единственная точка контроля конвенции (веточные
# коммиты squash схлопывает); метод приземления — производная
# conventions.squash × conventions.branchUpdate, не жёсткий squash
# (issue #119, хвост ревью PR #117, круг 1; см. docs/config.md).
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

# Дешёвый фильтр: проверяется PR текущей ветки (или явно указанный номером)
# после ЛЮБОЙ команды, где упоминается gh pr create/edit, — в том числе не
# трогавшей PR (grep по докам, heredoc). Это осознанная широта (ADR-004):
# требование исправить корректно и в этом случае — конвенция включена, а
# заголовок существующего PR ей не соответствует; если PR нет или заголовок
# корректен, хук молчит.
printf '%s' "$cmd" | grep -Eq 'gh +pr +(create|edit)' || exit 0

fix_required() {
  echo "$1" >&2
  exit 2
}

hook_cwd=$(json_field "$payload" "cwd" "")
git_root=$(adk_command_git_root "$cmd" "$hook_cwd")

# Корень конфига — правило и обоснование в adk_hook_config_root
# (lib/config.sh, issue #78); финальный фолбэк здесь не изменился.
hook_cfg_root=$(adk_hook_config_root "$cmd" "$hook_cwd")
cfg_root="${hook_cfg_root:-${CLAUDE_PROJECT_DIR:-$PWD}}"
style=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.commitStyle plain conventional,plain)
ext_lint=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.externalTitleLint false)
[ "$style" = "conventional" ] || exit 0
[ "$ext_lint" != "true" ] || exit 0

# Фактический заголовок: явный номер PR из команды (gh pr edit 12), иначе PR
# текущей ветки — тот, что выберет `gh pr view` без номера (несколько PR
# одной ветки или закрытый PR ветки — краевые случаи выбора gh, не наши).
# gh недоступен, PR не найден или -R распарсился ложно (например, из
# grep -R) — проверять нечего (fail-open).
prnum=$(adk_command_pr_number "$cmd" 'create|edit')
repo_flag=$(adk_command_repo_flag "$cmd")
r_flag="${repo_flag:+ -R $repo_flag}"
if [ -n "${ADK_GUARD_PR_TITLE+x}" ]; then
  [ "$ADK_GUARD_PR_TITLE" != "unavailable" ] || exit 0
  title="$ADK_GUARD_PR_TITLE"
  pr_ref="${prnum:-<N>}"
else
  pr_fields=$(adk_gh_pr_fields "$prnum" "$repo_flag" "$git_root" \
    number,title '"\(.number) \(.title)"')
  case "$pr_fields" in
    *' '*) pr_ref="${pr_fields%% *}"; title="${pr_fields#* }" ;;
    *) exit 0 ;;
  esac
fi

if ! printf '%s' "$title" | grep -Eq '\(#[0-9]+\)$'; then
  # «Станет сообщением squash-коммита» верно только при squash-merge —
  # единственном методе приземления, где GitHub кладёт заголовок PR в
  # subject коммита main; при rebase-merge/merge-commit заголовок PR в
  # коммит не попадает (rebase переносит коммиты ветки как есть, у
  # merge-коммита subject по умолчанию — «Merge pull request #N from …»),
  # поэтому для них утверждение не делается вовсе, а не подменяется другим
  # неточным (issue #119, хвост ревью PR #117, круг 1; деривация —
  # adk_config_merge_method, docs/config.md).
  commit_note=""
  if [ "$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_merge_method)" = "squash-merge" ]; then
    commit_note=" — он станет сообщением squash-коммита в main (метод приземления — squash-merge, дефолт)"
  fi
  fix_required "Заголовок PR не соответствует конвенции: conventions.commitStyle=conventional требует завершать заголовок ссылкой на issue «(#N)»$commit_note. Сейчас: «$title». Исправь: gh pr edit $pr_ref$r_flag --title \"<commitType>: <суть> (#N)\" (scope — опционально: «<commitType>(scope): …»)."
fi
issue_n=$(printf '%s' "$title" | grep -Eo '\(#[0-9]+\)$' | grep -Eo '[0-9]+')

# Вердикт по карте типов: дефолтные четыре (docs/config.md), поверх —
# переопределения и кастомные типы из types.* конфига (только label и
# commitType — остальные поля типов хуку не нужны). Формат заголовка
# проверяется от известных commitType (алфавит не ограничивается) и не
# требует сети — поэтому он идёт первым, до запроса labels issue;
# labels_csv=unavailable — режим «только формат» того же скрипта.
types_json=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get types "{}")
title_verdict() { # $1: CSV labels issue или "unavailable" (только формат)
  python3 -c '
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
' "$types_json" "$1" "$title"
}

verdict=$(title_verdict unavailable)
case "$verdict" in
  format\ *)
    fix_required "Заголовок PR не соответствует конвенции: conventions.commitStyle=conventional требует формат «<commitType>[(scope)]: <суть> (#N)», где commitType — один из: ${verdict#format }. Сейчас: «$title». Исправь: gh pr edit $pr_ref$r_flag --title \"<commitType>: <суть> (#N)\" (scope — опционально)." ;;
esac

# Labels issue: env-обход → adk_gh_issue_fields (-R из команды → git-корень
# команды, без отката на локальный репозиторий при явном -R — issue #N
# чужого repo нельзя искать в локальном, labels другого issue дали бы
# ложный mismatch — см. комментарий у adk_gh_issue_fields в lib/paths.sh).
# Код возврата функции различает «issue без labels» (rc=0, пустой список →
# ниже трактуется как task) от «прочитать не удалось» (rc≠0 → unavailable,
# сверка с label пропускается — формат уже проверен). Перевод в CSV
# остаётся здесь же, в хуке.
if [ -n "${ADK_GUARD_ISSUE_LABELS+x}" ]; then
  labels="$ADK_GUARD_ISSUE_LABELS"
elif labels_raw=$(adk_gh_issue_fields "$issue_n" "$repo_flag" "$git_root" labels '.labels[].name'); then
  labels=$(printf '%s' "$labels_raw" | tr '\n' ',')
else
  labels="unavailable"
fi
[ "$labels" != "unavailable" ] || exit 0

verdict=$(title_verdict "$labels")
case "$verdict" in
  mismatch\ *)
    read -r _ vt_has vt_got vt_exp <<VERDICT_EOF
$verdict
VERDICT_EOF
    if [ "$vt_has" = "1" ]; then
      fix_required "commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — по label issue ожидается «$vt_exp». Исправь: gh pr edit $pr_ref$r_flag --title \"$vt_exp: <суть> (#$issue_n)\" (scope — опционально)."
    else
      fix_required "commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — у issue нет label типа, он трактуется как task, ожидается «$vt_exp» (или проставь issue label типа). Исправь: gh pr edit $pr_ref$r_flag --title \"$vt_exp: <суть> (#$issue_n)\" (scope — опционально)."
    fi ;;
esac
exit 0
