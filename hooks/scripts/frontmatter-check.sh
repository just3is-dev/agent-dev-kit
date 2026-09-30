#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md
# парсится и несёт обязательные по типу файла ключи (issue #201).
#
# Контекст: блокер круга 2 PR #199 — перевёрстка сломала фронтматтер
# commands/stats.md (строка продолжения с колонки 0, вне отступа
# предыдущего ключа) — команда теряла description/argument-hint в
# рантайме Claude Code, а ни один гейт кита это не видел (scripts/check
# и тесты были зелёными). Этот скрипт закрывает класс, а не конкретный
# файл: он гоняется по всем commands/*.md, agents/*.md, skills/*/SKILL.md
# сразу, без привязки к тому, что именно менялось в PR.
#
# Разбор — минимальный парсер «key: value / отступ-продолжение», а не
# полноценный YAML (ADR-021): без внешней зависимости (yaml не входит в
# stdlib python3) и, что важнее, терпимый к «: » внутри значения без
# кавычек. На момент issue #201 именно так устроены описания
# commands/autopilot.md и commands/work.md — обычный русский текст со
# своими двоеточиями («...в работу: ветка → тесты...»); под настоящим
# YAML это read ошибка «mapping values are not allowed here», и правкой
# стало бы обязательное кавычение произвольного текста с двоеточием —
# хрупкое требование, которое сломалось бы заново при следующей правке
# формулировки без всякого выигрыша в защите от того класса бага,
# который здесь чинится (кит уже подтвердил это ревью PR #199).
#
# Использование: frontmatter-check.sh <project_root>
# exit 1 со списком ошибок вида "<файл>: <причина>" в stderr, если хоть
# один файл не разобрался как валидный фронтматтер своего типа или не
# хватает обязательного ключа; exit 0 молча, если всё в порядке (в том
# числе когда ни commands/, ни agents/, ни skills/ в корне нет — гейт
# кита, не обязателен для произвольного проекта).
set -u

root="${1:-}"
if [ -z "$root" ]; then
  echo "usage: frontmatter-check.sh <project_root>" >&2
  exit 1
fi
root="${root%/}"

declare -a entries=()
for f in "$root"/commands/*.md; do
  [ -f "$f" ] && entries+=("$f::command")
done
for f in "$root"/agents/*.md; do
  [ -f "$f" ] && entries+=("$f::agent")
done
for f in "$root"/skills/*/SKILL.md; do
  [ -f "$f" ] && entries+=("$f::skill")
done

[ "${#entries[@]}" -eq 0 ] && exit 0

printf '%s\n' "${entries[@]}" | python3 -c '
import sys

REQUIRED = {
    "command": ["description", "argument-hint"],
    "agent": ["name", "description", "model", "tools"],
    "skill": ["name", "description"],
}


def parse_frontmatter(text):
    # Возвращает (dict ключ->значение, None) при успехе, (None, причина)
    # при ошибке разбора. Ключ — строка с колонки 0 вида "key: значение"
    # (значение может быть пустым — тогда его донабирают отступные
    # строки-продолжения ниже). Любая непустая строка не с колонки 0 —
    # продолжение предыдущего ключа; такая же строка, но с колонки 0 и
    # без ":" — это и есть класс бага issue #201 (PR #199: строка
    # продолжения потеряла отступ) — синтаксическая ошибка, а не молчаливая
    # потеря значения.
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, "нет открывающего --- на первой строке"
    end = None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            end = i
            break
    if end is None:
        return None, "нет закрывающего --- (фронтматтер не завершён)"

    data = {}
    key = None
    for lineno, raw in enumerate(lines[1:end], start=2):
        if raw.strip() == "":
            continue
        if raw[0] not in (" ", "\t"):
            if ":" not in raw:
                return None, "строка %d: не \"ключ: значение\" и не отступ-продолжение: %r" % (lineno, raw)
            k, _, v = raw.partition(":")
            k = k.strip()
            v = v.strip()
            if not k:
                return None, "строка %d: пустой ключ" % lineno
            data[k] = v
            key = k
        else:
            if key is None:
                return None, "строка %d: строка-продолжение до первого ключа" % lineno
            cont = raw.strip()
            data[key] = (data[key] + " " + cont).strip() if data[key] else cont
    return data, None


errors = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    path, _, kind = line.rpartition("::")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        errors.append("%s: не удалось прочитать (%s)" % (path, e))
        continue
    data, err = parse_frontmatter(text)
    if err:
        errors.append("%s: %s" % (path, err))
        continue
    for req in REQUIRED[kind]:
        if req not in data or not data[req].strip():
            errors.append("%s: отсутствует или пуст обязательный ключ %r" % (path, req))

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
'
