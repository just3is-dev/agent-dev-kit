#!/usr/bin/env bash
# CLI-обёртка над lib/plugin-version.sh (adk_plugin_version) — печатает
# version из .claude-plugin/plugin.json плагина (пустая строка, если файл
# или поле не найдены). По образцу adk-config.sh: для вызова из
# инструкций команд-markdown (commands/autopilot.md); хукам/скриптам сам
# lib/plugin-version.sh sourceable напрямую (issue #154, ADR-021).
# Использование: adk-plugin-version.sh
set -u

. "$(cd "$(dirname "$0")" && pwd)/lib/plugin-version.sh"
adk_plugin_version
