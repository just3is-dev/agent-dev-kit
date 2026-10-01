#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md несёт
# обязательные по типу файла ключи (issue #201, класс бага PR #199).
#
# Разбор — доказуемо безопасный белый список форм "ключ: значение /
# отступ-продолжение", а не попытка эмулировать сам парсер рантайма
# Claude Code: круг 6 ревью показал, что двухфазный алгоритм рантайма
# (строгий Bun.YAML.parse + построчный fallback) не моделируется
# предикатами на stdlib без собственного YAML-парсера — некоторые формы
# (одиночные спецсимволы YAML) не вызывают ошибку строгого парсера, а
# молча заменяют значение на null/массив/обрезанную строку, минуя
# fallback целиком. Гейт поэтому принимает ТОЛЬКО формы, для которых
# результат разбора доказуемо не зависит от деталей самого парсера;
# всё остальное — отказ, даже если конкретный рантайм на конкретной
# версии это бы и разобрал правильно. Источники и обоснование — ADR-022.
#
# Использование: frontmatter-check.sh <project_root>
# exit 1 со списком ошибок вида "<файл>: <причина>" в stderr, если хоть
# один файл не разобрался как валидный фронтматтер своего типа или не
# хватает обязательного ключа; exit 0, если всё в порядке (возможны
# предупреждения в stderr, не влияющие на exit code), в том числе когда
# ни commands/, ни agents/, ни skills/ в корне нет — гейт кита, не
# обязателен для произвольного проекта.
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
import re
import sys

# Обязательные и допустимые ключи по типу файла (issue #201). Белый
# список ALLOWED — отдельная, более строгая защита от класса бага
# PR #199: перевёрстанная строка-продолжение, ставшая синтаксически
# валидным новым "ключ: значение", отвергается как неизвестный ключ, а
# не молча заводится (ADR-022).
REQUIRED = {
    "command": ["description", "argument-hint"],
    "agent": ["name", "description", "model", "tools"],
    "skill": ["name", "description"],
}
ALLOWED = {kind: set(keys) for kind, keys in REQUIRED.items()}

QUOTE_CHARS = ("\"", "\x27")
# Одиночные спецсимволы, при которых значение однозначно опасно в ЛЮБОЙ
# позиции: у каждого своя YAML-семантика (комментарий, flow-коллекция,
# якорь, тег, блочный скаляр, литерал), и не каждая форма даёт ошибку
# строгого парсера — некоторые молча подменяют значение (ADR-022).
U1_CHARS = set("{}[]*&#!|>%@`")
# Символы, запрещённые как ПЕРВЫЙ символ значения (индикаторы блочных
# конструкций YAML плюс кавычки/двоеточие/запятая) — ADR-022.
FORBIDDEN_LEAD_CHARS = set("-?:,[]{}#&*!|>\x27\"%@`")
NULL_LITERALS = {"~", "null", "Null", "NULL"}
BOOL_LITERALS = {"true", "True", "TRUE", "false", "False", "FALSE"}
FORBIDDEN_LITERALS = NULL_LITERALS | BOOL_LITERALS

KEY_RE = re.compile(r"^([A-Za-z_-]+):( +(.*))?$")


def extract_frontmatter(text):
    # Ленивая граница ---: первое вхождение "---" после открывающей
    # строки, где угодно в тексте, не обязательно отдельной строкой
    # (так же ведёт себя рантайм — ADR-022).
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, "нет открывающего --- на первой строке"
    rest = "\n".join(lines[1:])
    idx = rest.find("---")
    if idx == -1:
        return None, "нет закрывающего --- (фронтматтер не завершён)"
    return rest[:idx].split("\n"), None


def quoted_safe(v):
    # Однострочное кавыченное значение без внутренних кавычек/бэкслешей —
    # однозначный скаляр независимо от деталей парсера. Всё остальное
    # (незакрытая кавычка, хвост после закрывающей, экранирование,
    # перенос на другую строку) — отказ, не попытка разобрать (ADR-022).
    q = v[0]
    if len(v) < 2 or v[-1] != q:
        return False, None
    inner = v[1:-1]
    if q == "\"":
        if "\\" in inner or "\"" in inner:
            return False, None
    elif "\x27" in inner:
        return False, None
    return True, inner


def scalar_safe(value_remainder, continuation_texts):
    v = value_remainder.strip()
    if v[:1] in QUOTE_CHARS:
        if continuation_texts:
            return False, None
        return quoted_safe(v)

    all_lines = [value_remainder] + list(continuation_texts)
    if any("\t" in ln for ln in all_lines):
        return False, None
    if any(ln.rstrip(" ").endswith(":") for ln in all_lines):
        return False, None
    if any(ch in ln for ln in all_lines for ch in U1_CHARS):
        return False, None
    if continuation_texts and any(": " in ln for ln in all_lines):
        return False, None

    first_token = v
    if not first_token:
        first_token = next((c.strip() for c in continuation_texts if c.strip()), "")
    if first_token[:1] in FORBIDDEN_LEAD_CHARS:
        return False, None

    assembled = " ".join(p.strip() for p in all_lines if p.strip())
    if assembled in FORBIDDEN_LITERALS:
        return False, None
    return True, assembled


def build_records(fm_lines, kind, errors, warnings):
    records = []
    index = {}
    current = None
    for lineno, raw in enumerate(fm_lines, start=2):
        if raw.strip() == "":
            continue
        if raw[0] not in (" ", "\t"):
            m = KEY_RE.match(raw)
            if not m:
                errors.append("строка %d: не \"ключ: значение\" и не отступ-продолжение: %r" % (lineno, raw))
                return None
            key = m.group(1)
            value = m.group(3) if m.group(3) is not None else ""
            if key not in ALLOWED[kind]:
                errors.append(
                    "строка %d: неизвестный ключ %r для %s (допустимы: %s)"
                    % (lineno, key, kind, ", ".join(sorted(ALLOWED[kind])))
                )
                return None
            if key in index:
                # Повторяющийся ключ — предупреждение, не ошибка
                # (осознанное решение, ADR-022).
                warnings.append("строка %d: повторяющийся ключ %r, предыдущее значение перезаписано" % (lineno, key))
                record = index[key]
                record["value"] = value
                record["continuations"] = []
            else:
                record = {"key": key, "value": value, "continuations": []}
                index[key] = record
                records.append(record)
            current = record
        else:
            if current is None:
                errors.append("строка %d: строка-продолжение до первого ключа" % lineno)
                return None
            current["continuations"].append(raw)
    return records


def resolve_frontmatter(fm_lines, kind, errors, warnings):
    records = build_records(fm_lines, kind, errors, warnings)
    if records is None:
        return None
    data = {}
    for r in records:
        ok, val = scalar_safe(r["value"], r["continuations"])
        if not ok:
            errors.append(
                "ключ %r: значение не распознано как безопасная форма (могло бы потеряться или исказиться в рантайме)"
                % r["key"]
            )
            return None
        data[r["key"]] = val
    return data


def parse_frontmatter(text, kind, warnings):
    errors = []
    fm_lines, err = extract_frontmatter(text)
    if err:
        return None, err
    data = resolve_frontmatter(fm_lines, kind, errors, warnings)
    if data is None:
        return None, errors[0]
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
    warnings = []
    data, err = parse_frontmatter(text, kind, warnings)
    for w in warnings:
        print("%s: %s" % (path, w), file=sys.stderr)
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
