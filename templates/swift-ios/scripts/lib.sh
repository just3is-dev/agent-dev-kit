#!/usr/bin/env bash
# Общие хелперы контрактных скриптов шаблона swift-ios (check/fix/test).
# Подключается через `source`, не исполняется напрямую.

# Файлы проекта по имени, без артефактов сборки и зависимостей.
find_clean() {
  find . -name "$1" \
    -not -path '*/.build/*' \
    -not -path '*/DerivedData/*' \
    -not -path '*/Pods/*' \
    -not -path '*/.git/*'
}
