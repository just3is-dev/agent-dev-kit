#!/usr/bin/env bash
# CLI-обёртка над lib/config.sh (контракт adk_config_get — см. его
# комментарий) для вызова из инструкций команд-markdown; хукам сам
# lib/config.sh sourceable. Использование:
#   adk-config.sh <путь.через.точку> [дефолт] [допустимые,значения,csv]
#   adk-config.sh --merge-method   # производный метод приземления (AC-6)
set -u

path="${1:-}"
if [ -z "$path" ]; then
  echo "usage: adk-config.sh <path> [default] [allowed,values,csv] | adk-config.sh --merge-method" >&2
  exit 2
fi
default="${2:-}"
allowed="${3:-}"

. "$(cd "$(dirname "$0")" && pwd)/lib/config.sh"
if [ "$path" = "--merge-method" ]; then
  adk_config_merge_method
else
  adk_config_get "$path" "$default" "$allowed"
fi
