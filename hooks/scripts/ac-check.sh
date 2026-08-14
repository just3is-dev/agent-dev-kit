#!/usr/bin/env bash
# Проверка AC-трассируемости: у каждого критерия приёмки (AC-<n>) approved-
# спеки должен быть хотя бы один помеченный тест. Использование:
#   ac-check.sh [--complete] <корень проекта> [тестовый путь ...]
# Переходное состояние (issue #54): approved-спека мержится до реализации,
# тесты AC появляются по ходу милестоуна. Критерий с аннотацией
# «(ждёт #<issue>)» сразу после токена, на той же строке — «AC-7 (ждёт #52)»
# (ставит /plan при декомпозиции, снимает PR, добавляющий тег-тест) —
# принимается без теста; аннотация в другом месте строки или на переносе
# не действует. --complete — проверка полноты на границе милестоуна
# (/consolidate): аннотации не учитываются, каждый AC обязан иметь тест.
# AC-токены собираются из раздела "## Критерии приёмки" approved-спек
# (docs/specs/*.md). Статус читается как первое слово после "Статус:" —
# так строка шаблона "Статус: draft <!-- draft | approved | ... -->"
# (templates/process/spec-template.md) не принимается за approved.
# Только draft/in-progress/etc. пропускаются; approved — проверяется.
# Тестовый корпус — переданные пути (файлы или папки), либо при их
# отсутствии дефолт: tests/, **/*.test.*, **/*.spec.*, test_*.py, за
# вычетом docs/specs/ (сами спеки не должны "покрывать" сами себя) и
# служебных папок (node_modules, vendor, .git, dist, build).
# exit 1 со списком непокрытых AC, exit 0 при полном покрытии или
# отсутствии спек с конвенцией AC. Только проверка, ничего не правит.
#
# Известное ограничение: токен AC-<n> не привязан к конкретной спеке —
# если у двух approved-спек совпадает номер критерия, покрытие одной
# засчитывается и для другой; аннотация «ждёт #N» глобальна так же. Глобальная схема именования AC вне рамок
# этой задачи (issue #5) — уточняется конвенцией тегирования (issue #6).
set -u

complete_mode=0
if [ "${1:-}" = "--complete" ]; then
  complete_mode=1
  shift
fi

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: ac-check.sh [--complete] <project_root> [test_path ...]" >&2
  exit 1
fi
root="${root%/}"
shift

# Неизвестные/переставленные аргументы и битый корень отвергаются громко:
# молчаливая деградация строгого режима в мягкий — ложно-зелёный гейт
for arg in "$root" "$@"; do
  case "$arg" in
    -*)
      echo "ac-check: неизвестный аргумент: $arg" >&2
      echo "usage: ac-check.sh [--complete] <project_root> [test_path ...]" >&2
      exit 1;;
  esac
done
if [ ! -d "$root" ]; then
  echo "ac-check: корень проекта не найден: $root" >&2
  exit 1
fi

specs_dir="$root/docs/specs"
[ -d "$specs_dir" ] || exit 0

# ── Собрать AC-токены из approved-спек ───────────────────────────────────────
# Секции "Критерии приёмки" всех approved-спек копятся в одну строку, а
# извлечение токенов + дедуп идёт одним проходом grep -oE | sort -u —
# вместо сырого сбора в массив и отдельного дедуп-прохода по нему.
declare -a acs=()
sections=""
for spec in "$specs_dir"/*.md; do
  [ -f "$spec" ] || continue
  status_line=$(grep -m1 -E '^Статус:' "$spec" || true)
  status=$(printf '%s' "$status_line" | sed -E 's/^Статус:[[:space:]]*//' | awk '{print $1}')
  [ "$status" = "approved" ] || continue
  # только токены из секции "## Критерии приёмки" (до следующего "## ")
  sections="$sections
$(awk '/^## Критерии приёмки/{flag=1; next} /^## /{flag=0} flag' "$spec")"
done

# Запланированные AC: аннотация «(ждёт #<issue>)» сразу после токена —
# тест появится в названном issue, до тех пор отсутствие теста не ошибка.
# Привязка к токену, а не к строке: другие AC-токены той же строки и
# проза «ждёт #N» вдали от токена pending не становятся.
pending=""
if [ "$complete_mode" -eq 0 ]; then
  pending=$(printf '%s' "$sections" | grep -oE 'AC-[0-9]+[[:space:]]*\(ждёт #[0-9]+\)' | grep -oE 'AC-[0-9]+' | sort -u)
fi

while IFS= read -r ac; do
  [ -n "$ac" ] && acs+=("$ac")
done < <(printf '%s' "$sections" | grep -oE 'AC-[0-9]+' | sort -u)

if [ "${#acs[@]}" -eq 0 ]; then
  exit 0
fi

# ── Собрать тестовый корпус (список файлов) ──────────────────────────────────
# служебные папки и сами спеки — не тестовый корпус
prune_default() {
  find "$1" -type f \
    -not -path "$specs_dir/*" \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    -not -path '*/.git/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    "${@:2}" 2>/dev/null
}

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
    while IFS= read -r f; do test_files+=("$f"); done < <(prune_default "$root/tests")
  fi
  while IFS= read -r f; do test_files+=("$f"); done < <(
    prune_default "$root" -not -path "$root/tests/*" \( -name '*.test.*' -o -name '*.spec.*' -o -name 'test_*.py' \)
  )
fi

# ── Проверить покрытие ────────────────────────────────────────────────────────
# Один проход grep -rhoE по корпусу файлов вместо повторного regex-поиска
# на каждый AC-токен по конкатенации содержимого файлов.
covered=""
if [ "${#test_files[@]}" -gt 0 ]; then
  covered=$(grep -rhoE 'AC-[0-9]+' "${test_files[@]}" 2>/dev/null | sort -u)
fi

declare -a missing=()
for ac in "${acs[@]}"; do
  printf '%s\n' "$covered" | grep -qxF "$ac" && continue
  printf '%s\n' "$pending" | grep -qxF "$ac" && continue
  missing+=("$ac")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Непокрытые критерии приёмки:"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi

exit 0
