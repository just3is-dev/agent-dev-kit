#!/usr/bin/env bash
# CLI-обёртка над lib/config.sh для вызова из инструкций команд-markdown
# (хукам сам lib/config.sh sourceable — см. его комментарий). Использование:
#   adk-config.sh <путь.через.точку> [дефолт] [допустимые,значения,csv]
# Печатает значение атрибута (или дефолт, если файла/атрибута нет — конфиг
# не роняет вызывающего) и завершается тем же кодом, что и adk_config_get:
# 0 — значение найдено или взят дефолт по отсутствию; 1 — значение в
# конфиге есть, но не входит в переданный список допустимых (если он
# передан) — дефолт напечатан, но откат не молчаливый (issue #41).
set -u

path="${1:-}"
if [ -z "$path" ]; then
  echo "usage: adk-config.sh <path> [default] [allowed,values,csv]" >&2
  exit 2
fi
default="${2:-}"
allowed="${3:-}"

. "$(cd "$(dirname "$0")" && pwd)/lib/config.sh"
adk_config_get "$path" "$default" "$allowed"
