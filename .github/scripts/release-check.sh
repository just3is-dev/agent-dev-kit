#!/usr/bin/env bash
# Решает, нужен ли релиз по текущему HEAD заданного git-репозитория
# (SPEC-004, issue #155, AC-2): сравнивает `version` в
# .claude-plugin/plugin.json между HEAD и предыдущим коммитом (HEAD^).
# Скрипт только решает и печатает — git tag / GitHub Release создаёт
# workflow-обёртка (.github/workflows/release.yml), это не его дело
# (issue #155: «тонкая обёртка» вызывает именно этот скрипт).
#
# Использование: release-check.sh [<git_repo>]  (по умолчанию — текущая
# директория). Репозиторий обязан иметь полную историю (fetch-depth: 0
# в чекауте workflow) — .git/shallow ломает git describe/git log диапазоны.
#
# Контракт вывода (stdout), три исхода:
#   версия не менялась либо целевой тег уже существует →
#     первая строка "релиза нет: <причина>", exit 0;
#   версия изменилась и тега ещё нет →
#     строка 1 "RELEASE", строка 2 — целевой тег vX.Y.Z, строки 3+ — notes
#     (заголовки коммитов от предыдущего тега, `- <subject>` на строку;
#     без предыдущего тега — вся история до HEAD, issue #156), exit 0.
# Ошибка (репозиторий не найден, plugin.json битый/без version) — сообщение
# в stderr, exit 1.
set -u

repo="${1:-.}"
if [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "release-check: не git-репозиторий: $repo" >&2
  exit 1
fi

read_version() { # read_version <ревизия> — версия plugin.json на этой ревизии, пусто если файла/поля нет
  local rev="$1" content
  content=$(git -C "$repo" show "$rev:.claude-plugin/plugin.json" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$content" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("version", "")
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
'
}

new_version=$(read_version HEAD)
if [ -z "$new_version" ]; then
  echo "release-check: не удалось прочитать version из .claude-plugin/plugin.json на HEAD" >&2
  exit 1
fi

old_version=$(read_version HEAD^)

if [ "$old_version" = "$new_version" ]; then
  echo "релиза нет: version не изменилась ($new_version)"
  exit 0
fi

tag="v$new_version"
if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "release-check: version «$new_version» не похожа на semver X.Y.Z" >&2
  exit 1
fi

if git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
  echo "релиза нет: тег $tag уже существует"
  exit 0
fi

prev_tag=$(git -C "$repo" describe --tags --abbrev=0 HEAD 2>/dev/null || true)
if [ -n "$prev_tag" ]; then
  range="$prev_tag..HEAD"
else
  range="HEAD"
fi

notes=$(git -C "$repo" log --format='- %s' "$range")

printf 'RELEASE\n%s\n%s\n' "$tag" "$notes"
