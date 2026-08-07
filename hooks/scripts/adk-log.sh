#!/usr/bin/env bash
# Журнал прогонов: append-only JSONL. Использование:
#   adk-log.sh <единица> key=value [key=value ...]
# <единица> — имя файла без расширения (issue-<N> | autopilot-<дата>).
# Пишет одну JSON-строку с timestamp в $ADK_LOGS_DIR либо
# <корень проекта>/.adk/logs/<единица>.jsonl (папку создаёт).
# При записи по дефолтному пути кладёт <корень>/.adk/.gitignore с "*" —
# самоигнорирующаяся папка, корневой .gitignore проекта не трогается.
set -u

unit="${1:-}"
if [ -z "$unit" ]; then
  echo "usage: adk-log.sh <unit> key=value [key=value ...]" >&2
  exit 1
fi
case "$unit" in
  */*) echo "adk-log.sh: имя единицы не может содержать '/': $unit" >&2; exit 1 ;;
esac
shift

root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
fi

if [ -n "${ADK_LOGS_DIR:-}" ]; then
  logs_dir="$ADK_LOGS_DIR"
else
  logs_dir="$root/.adk/logs"
  gi="$root/.adk/.gitignore"
  [ -f "$gi" ] || { mkdir -p "$root/.adk" && printf '*\n' > "$gi"; }
fi
mkdir -p "$logs_dir"

line=$(python3 -c '
import json, sys, datetime

pairs = sys.argv[1:]
event = {"timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
for p in pairs:
    if "=" not in p:
        continue
    k, v = p.split("=", 1)
    event[k] = v
print(json.dumps(event, ensure_ascii=False))
' "$@")

printf '%s\n' "$line" >> "$logs_dir/$unit.jsonl"
