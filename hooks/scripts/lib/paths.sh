#!/usr/bin/env bash
# Общий хелпер для hooks/scripts/*.sh: определение корня проекта и пути к
# каталогу журнала (issue #23). До этой правки идентичный блок был
# продублирован построчно в adk-log.sh и adk-stats.sh.
#
# Правило корня (adk_project_root): $CLAUDE_PROJECT_DIR, иначе git-фолбэк
# (git rev-parse --show-toplevel), иначе $PWD. Используют только
# adk-log.sh/adk-stats.sh — у stop-test.sh/notification.sh своё, более
# простое правило (${CLAUDE_PROJECT_DIR:-$PWD}, без git-фолбэка) и оно
# сознательно оставлено как есть: унификация изменила бы их наблюдаемое
# поведение при отсутствии CLAUDE_PROJECT_DIR (см. docs/adr/002-shared-hook-lib-paths.md).
#
# Использование:
#   root=$(adk_project_root)
#   logs_dir=$(adk_logs_dir "$root")

adk_project_root() {
  local root="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  fi
  printf '%s\n' "$root"
}

# adk_logs_dir <root> — печатает путь к каталогу журнала: $ADK_LOGS_DIR,
# если задан, иначе "<root>/.adk/logs". Не создаёт каталог и не трогает
# .adk/.gitignore — это остаётся на вызывающем (только adk-log.sh это делает).
adk_logs_dir() {
  local root="$1"
  if [ -n "${ADK_LOGS_DIR:-}" ]; then
    printf '%s\n' "$ADK_LOGS_DIR"
  else
    printf '%s\n' "$root/.adk/logs"
  fi
}

# adk_notify_send <title> <message> — вызывает notify-send.sh рядом со
# скриптом-вызывающим. До этой правки выражение
# "$(cd "$(dirname "$0")" && pwd)/notify-send.sh" дублировалось в
# stop-test.sh и notification.sh. $0 внутри функции — это $0 вызывающего
# скрипта (bash не меняет его при вызове функции), поэтому путь
# разрешается так же, как и раньше.
adk_notify_send() {
  "$(cd "$(dirname "$0")" && pwd)/notify-send.sh" "$@"
}

# adk_command_git_root <cmd> <hook_cwd> — git toplevel репозитория, к которому
# относится Bash-команда хука. Кандидаты в порядке достоверности: явный `cd`
# в самой команде → cwd сессии из payload хука → корень сессии → PWD хука
# (корень сессии может не быть репозиторием: сессия открыта выше, проект
# подключён дополнительной директорией). До этой правки блок был продублирован
# в bash-guard.sh и pr-title-check.sh (ADR-002: общее — в lib). Печатает
# пустую строку, если репозиторий не найден.
adk_command_git_root() {
  local cmd="$1" hook_cwd="$2" cd_prefix="" d="" root=""
  case "$cmd" in
    cd\ *) cd_prefix=$(printf '%s' "$cmd" | sed -E 's/^cd +//; s/ *(&&|;|\|).*$//' | tr -d '"'"'"'') ;;
  esac
  for d in "$cd_prefix" "$hook_cwd" "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    if root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  printf '%s\n' ""
}

# adk_command_repo_flag <cmd> — значение первого -R/--repo в команде (пусто,
# если флага нет). Текстовая эвристика: ложное совпадение (например, grep -R)
# даёт нерабочее значение repo, и вызывающие фейлятся открыто — приемлемо.
adk_command_repo_flag() {
  printf '%s' "$1" | grep -Eo -- '(-R|--repo)[= ][^ ]+' | head -1 | sed -E 's/^(-R|--repo)[= ]//'
}

# adk_command_pr_number <cmd> <подкоманды-ERE> — явный номер PR сразу после
# `gh pr <подкоманда>` (пусто, если команда без номера, например gh pr create).
adk_command_pr_number() {
  printf '%s' "$1" | grep -Eo "gh +pr +($2) +[0-9]+" | grep -Eo '[0-9]+' | head -1
}

# adk_gh_pr_fields <prnum> <repo_flag> <git_root> <json-поля> <jq-выражение> —
# один вызов `gh pr view` за нужные поля PR. Репозиторий: -R из команды →
# git-корень команды → ни того, ни другого = запроса нет. Пустой <prnum> —
# PR текущей ветки. Печатает вывод jq-выражения; пустая строка — «прочитать
# не удалось» (gh недоступен, PR не найден, репозиторий не определён), что
# каждый вызывающий трактует по своему правилу. До этой правки блок был
# продублирован в bash-guard.sh и pr-title-check.sh (ADR-002: общее — в lib).
adk_gh_pr_fields() {
  local prnum="$1" repo_flag="$2" git_root="$3" json_fields="$4" jq_q="$5" out=""
  if [ -n "$repo_flag" ]; then
    out=$(gh pr view ${prnum:+"$prnum"} -R "$repo_flag" --json "$json_fields" -q "$jq_q" 2>/dev/null) || out=""
  elif [ -n "$git_root" ]; then
    out=$(cd "$git_root" && gh pr view ${prnum:+"$prnum"} --json "$json_fields" -q "$jq_q" 2>/dev/null) || out=""
  fi
  printf '%s\n' "$out"
}
