#!/usr/bin/env bash
# Проверка AC-трассируемости: у каждого критерия приёмки (AC-<n>) approved-
# спеки должен быть хотя бы один помеченный тест. Использование:
#   ac-check.sh <корень проекта> [тестовый путь ...]
# AC-токены собираются из раздела "## Критерии приёмки" approved-спек
# (docs/specs/*.md, строка "Статус: approved" — draft и прочие статусы не
# проверяются). Тестовый корпус — переданные пути (файлы или папки), либо
# при их отсутствии дефолт: tests/, **/*.test.*, **/*.spec.*, test_*.py.
# exit 1 со списком непокрытых AC, exit 0 при полном покрытии или
# отсутствии спек с конвенцией AC. Только проверка, ничего не правит.
set -u

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: ac-check.sh <project_root> [test_path ...]" >&2
  exit 1
fi
shift

specs_dir="$root/docs/specs"
[ -d "$specs_dir" ] || exit 0

# ── Собрать AC-токены из approved-спек ───────────────────────────────────────
declare -a acs=()
for spec in "$specs_dir"/*.md; do
  [ -f "$spec" ] || continue
  status_line=$(grep -m1 -E '^Статус:' "$spec" || true)
  case "$status_line" in
    *approved*) ;;
    *) continue ;;
  esac
  # только токены из секции "## Критерии приёмки" (до следующего "## ")
  section=$(awk '/^## Критерии приёмки/{flag=1; next} /^## /{flag=0} flag' "$spec")
  while IFS= read -r ac; do
    [ -n "$ac" ] && acs+=("$ac")
  done < <(printf '%s' "$section" | grep -oE 'AC-[0-9]+' | sort -u)
done

if [ "${#acs[@]}" -eq 0 ]; then
  exit 0
fi
declare -a dedup=()
while IFS= read -r ac; do
  [ -n "$ac" ] && dedup+=("$ac")
done < <(printf '%s\n' "${acs[@]}" | sort -u)
acs=("${dedup[@]}")

# ── Собрать тестовый корпус (список файлов) ──────────────────────────────────
declare -a test_files=()
if [ "$#" -gt 0 ]; then
  for p in "$@"; do
    if [ -d "$p" ]; then
      while IFS= read -r f; do test_files+=("$f"); done < <(find "$p" -type f)
    elif [ -f "$p" ]; then
      test_files+=("$p")
    fi
  done
else
  if [ -d "$root/tests" ]; then
    while IFS= read -r f; do test_files+=("$f"); done < <(find "$root/tests" -type f)
  fi
  while IFS= read -r f; do test_files+=("$f"); done < <(
    find "$root" -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name 'test_*.py' \) 2>/dev/null
  )
fi

corpus=""
if [ "${#test_files[@]}" -gt 0 ]; then
  corpus=$(cat "${test_files[@]}" 2>/dev/null)
fi

# ── Проверить покрытие ────────────────────────────────────────────────────────
declare -a missing=()
for ac in "${acs[@]}"; do
  n="${ac#AC-}"
  if ! printf '%s\n' "$corpus" | grep -qE "AC-${n}([^0-9]|\$)"; then
    missing+=("$ac")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Непокрытые критерии приёмки:"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi

exit 0
