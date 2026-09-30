#!/usr/bin/env bash
# Гейт «забытая аннотация (ждёт #N)» (issue #200): PR, чьё тело содержит
# Closes #N, не должен оставлять в docs/specs/*.md аннотацию «(ждёт #N)»
# с тем же номером — правило шага 3 commands/work.md («тест появился,
# «ждать» больше нечего») ловилось ревью дважды подряд (PR #198 AC-4,
# PR #199 AC-6), гейт дешевле инструкции.
#
# Использование: spec-annotation-check.sh <project_root> [issue_number ...]
#   issue_number — номера из "Closes #N" тела PR; вызывающий workflow
#   (.github/workflows/spec-annotation-check.yml) достаёт их из
#   github.event.pull_request.body через gh/GitHub Actions контекст —
#   здесь сеть и git не нужны, вход полностью фикстурный.
#
# Без issue_number (PR без Closes #N) — гейт молчит: exit 0, нечего
# проверять. С issue_number — ищет буквальную подстроку "(ждёт #N)" по
# всем docs/specs/*.md под project_root; нашёл — exit 1 с именем правила
# и списком файлов; не нашёл — exit 0.
set -u

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: spec-annotation-check.sh <project_root> [issue_number ...]" >&2
  exit 2
fi
shift

if [ $# -eq 0 ]; then
  echo "ok: тело PR без Closes #N — проверка аннотаций (ждёт #N) пропущена"
  exit 0
fi

specs_dir="$root/docs/specs"
violations=""

if [ -d "$specs_dir" ]; then
  for n in "$@"; do
    needle="(ждёт #${n})"
    for f in "$specs_dir"/*.md; do
      [ -f "$f" ] || continue
      if grep -qF -- "$needle" "$f"; then
        violations="${violations}${f}: ${needle}"$'\n'
      fi
    done
  done
fi

if [ -n "$violations" ]; then
  {
    echo "гейт аннотаций спек: PR закрывает issue из списка ниже, но в docs/specs/*.md осталась аннотация «(ждёт #N)» с тем же номером."
    echo "Правило (commands/work.md, шаг 3): критерий, помеченный аннотацией «(ждёт #N)», снимается в том же PR, который закрывает issue #N — тест появился, «ждать» больше нечего."
    echo "Осталось снять:"
    printf '%s' "$violations" | sed 's/^/  - /'
  } >&2
  exit 1
fi

echo "ok: аннотации (ждёт #N) для закрываемых issue не найдены в docs/specs/*.md"
exit 0
