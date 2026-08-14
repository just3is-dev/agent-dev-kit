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
# - путь найден, [allowed-csv] не передан → печатает найденное значение
#   как есть (bool из JSON — python-строка "True"/"False", тот же
#   компромисс, что и в json_field — вызывающий сам трактует).
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

out = json.dumps(d, ensure_ascii=False) if isinstance(d, (dict, list)) else d

if allowed is not None:
    str_out = out if isinstance(out, str) else str(out)
    if str_out not in allowed:
        sys.stderr.write(
            "adk-config: неизвестное значение %r для %s, использован дефолт %r\n"
            % (str_out, path, default)
        )
        print(default)
        sys.exit(1)

print(out)
' "$cfg" "$path" "$default" "$allowed"
}
