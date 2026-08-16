#!/usr/bin/env bash
# Общий хелпер для hooks/scripts/*.sh: читает атрибут из adk.config.json по
# пути через точку (например "policies.merge"), по образцу json-field.sh
# (issue #41). Модель конфига — SPEC-002 (docs/specs/002-process-config.md):
# плоский набор независимых атрибутов; отсутствие файла или атрибута = его
# дефолт, что обязано воспроизводить сегодняшнее поведение кита без
# конфига (docs/config.md — таблица дефолтов).
#
# Использование:
#   . lib/config.sh
#   value=$(adk_config_get "policies.merge" "agent-after-approve")
#   value=$(adk_config_get "policies.merge" "agent-after-approve" \
#     "agent-after-approve,human-review-required,human-only")
#
# adk_config_get <path> <default> [allowed-csv]:
# - файла нет, JSON битый, путь не найден на любом уровне вложенности →
#   печатает <default>, exit 0. Конфиг никогда не роняет вызывающий хук.
# - путь найден, [allowed-csv] не передан → печатает найденное значение;
#   bool/число/объект сериализуются как json.dumps (bool → "true"/"false"
#   строчными, как в самом adk.config.json и в <default>, а не
#   python-репрезентацией "True"/"False" — иначе один и тот же атрибут
#   печатался бы по-разному в зависимости от того, задан он в файле или
#   берётся из дефолта).
# - путь найден, [allowed-csv] передан, значение не входит в список →
#   печатает <default>, НО exit 1 и предупреждение в stderr: это
#   единственный случай, отличный от "нет конфига", и он обязан быть
#   громким — молчаливый откат опечатки в дефолт неотличим от валидного
#   конфига, а для полей вроде policies.merge дефолт умышленно
#   разрешающий (обратная совместимость), и опечатку нельзя путать с его
#   осознанным выбором (issue #41 DoD, docs/config.md).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"

adk_config_file() {
  local root="$1"
  if [ -n "${ADK_CONFIG_FILE:-}" ]; then
    printf '%s\n' "$ADK_CONFIG_FILE"
  else
    printf '%s\n' "$root/adk.config.json"
  fi
}

# adk_hook_config_root <cmd> <hook_cwd> — корень, из которого хук читает
# adk.config.json: первый кандидат, где файл реально есть — cwd самой
# команды (adk_command_cwd, lib/paths.sh), затем CLAUDE_PROJECT_DIR
# (мульти-директорная сессия может указывать на другой каталог), и только
# если файла нет ни там, ни там — git toplevel команды (adk_command_git_root)
# безусловно, как и раньше: мейнстрим-раскладка «конфиг на корне репозитория»
# не меняется, даже если файла там тоже нет — тогда adk_config_get вернёт
# дефолт, это его контракт, не этой функции. До этой правки оба хука
# безусловно предпочитали git toplevel — проект, оказавшийся подкаталогом
# более крупного репозитория со своим adk.config.json, свой конфиг не
# находил (issue #78). Печатает пустую строку, если ни один кандидат не
# существует как каталог вовсе (нет ни git-репозитория, ни CLAUDE_PROJECT_DIR) —
# вызывающий откатывается на свой прежний финальный фолбэк
# (${CLAUDE_PROJECT_DIR:-$PWD}), как и раньше.
adk_hook_config_root() {
  local cmd="$1" hook_cwd="$2" cmd_cwd
  cmd_cwd=$(adk_command_cwd "$cmd" "$hook_cwd")
  if [ -n "$cmd_cwd" ] && [ -f "$cmd_cwd/adk.config.json" ]; then
    printf '%s\n' "$cmd_cwd"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/adk.config.json" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  adk_command_git_root "$cmd" "$hook_cwd"
}

# Серверный метод приземления GitHub — производная пары conventions.squash ×
# conventions.branchUpdate, не самостоятельная настройка (SPEC-002, AC-6):
# squash=true → squash-merge; false+rebase → rebase-merge; false+merge →
# merge-commit. Комбинация «rebase-актуализация + merge-commit приземление»
# невыразима сознательно («Решённые вопросы» спеки). Сама производная —
# чистая функция своих двух аргументов, отдельно от чтения конфига.
adk_merge_method() { # adk_merge_method <squash: true|false> <branchUpdate: rebase|merge>
  if [ "$1" = "true" ]; then
    echo "squash-merge"
  elif [ "$2" = "merge" ]; then
    echo "merge-commit"
  else
    echo "rebase-merge"
  fi
}

# Обёртка над конфигом: читает пару атрибутов (неизвестные значения
# откатываются в дефолты с предупреждением adk_config_get в stderr) и
# печатает производный метод.
adk_config_merge_method() {
  local squash branch_update
  squash=$(adk_config_get "conventions.squash" "true" "true,false")
  branch_update=$(adk_config_get "conventions.branchUpdate" "rebase" "rebase,merge")
  adk_merge_method "$squash" "$branch_update"
}

adk_config_get() {
  local path="$1" default="${2:-}" allowed="${3:-}"
  local root cfg
  root=$(adk_project_root)
  cfg=$(adk_config_file "$root")
  python3 -c '
import json, sys

cfg_path, path, default, allowed_csv = sys.argv[1:5]
allowed = [a for a in allowed_csv.split(",") if a] if allowed_csv else None

try:
    with open(cfg_path) as f:
        d = json.load(f)
except Exception:
    print(default)
    sys.exit(0)

for key in path.split("."):
    d = d.get(key) if isinstance(d, dict) else None
    if d is None:
        break

if d is None:
    print(default)
    sys.exit(0)

# json.dumps даёт строчные "true"/"false" для bool (в отличие от print(d),
# который напечатал бы python-репрезентацию "True"/"False") и не трогает
# уже-строковые значения кавычками — единственный не-строковый случай,
# который остаётся строкой сам по себе.
out = d if isinstance(d, str) else json.dumps(d, ensure_ascii=False)

if allowed is not None and out not in allowed:
    sys.stderr.write(
        "adk-config: неизвестное значение %r для %s, использован дефолт %r\n"
        % (out, path, default)
    )
    print(default)
    sys.exit(1)

print(out)
' "$cfg" "$path" "$default" "$allowed"
}
