#!/usr/bin/env bash
# Гейт «забытая аннотация (ждёт #N)» (issue #200): PR, чьё тело содержит
# Closes #N, не должен оставлять в docs/specs/*.md аннотацию «(ждёт #N)»
# с тем же номером — правило шага 3 commands/work.md («тест появился,
# «ждать» больше нечего») ловилось ревью дважды подряд (PR #198 AC-4,
# PR #199 AC-6), гейт дешевле инструкции.
#
# Использование: spec-annotation-check.sh <project_root> (тело PR на stdin)
#   Номера issue разбираются из тела PR самим скриптом (круг 1 ревью PR
#   #242: извлечение "Closes #N" было inline-однострочником в workflow и
#   не тестировалось фикстурами) — вызывающий workflow
#   (.github/workflows/spec-annotation-check.yml) только передаёт тело
#   через github.event.pull_request.body, сеть/git внутри не нужны.
#
# Разбор тела: "Closes #N" (регистронезависимо, опциональное двоеточие
# после "closes", опциональные пробелы перед "#") с левой границей слова —
# "discloses #5" не матчит "closes #5". Другие закрывающие глаголы GitHub
# (Fixes/Resolves/...) и кросс-репо ссылки (owner/repo#N) не разбираются —
# конвенция кита (шаг 5 commands/work.md) предписывает ровно "Closes #N" в
# своём репозитории.
#
# Без "Closes #N" в теле — гейт молчит: exit 0, нечего проверять. С одним
# или несколькими номерами — ищет буквальную подстроку "(ждёт #N)" по всем
# docs/specs/*.md под project_root; нашёл — exit 1 с именем правила и
# списком файлов; не нашёл — exit 0.
set -u

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: spec-annotation-check.sh <project_root> (тело PR на stdin)" >&2
  exit 2
fi

body="$(cat)"
issue_numbers=$(printf '%s' "$body" | grep -ioE '(^|[^a-z])closes:?[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -un)

if [ -z "$issue_numbers" ]; then
  echo "ok: тело PR без Closes #N — проверка аннотаций (ждёт #N) пропущена"
  exit 0
fi

specs_dir="$root/docs/specs"
violations=""

if [ -d "$specs_dir" ]; then
  for n in $issue_numbers; do
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
