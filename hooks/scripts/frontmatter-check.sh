#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md несёт
# обязательные по типу файла ключи (issue #201, класс бага PR #199).
#
# Разбор моделирует двухфазный алгоритм рантайма Claude Code (строгий
# Bun.YAML.parse, затем построчный fallback-парсер с кавотированием по
# триггеру) на python3 stdlib, без внешней зависимости — механизм и
# источники реверс-инжиниринга в ADR-022.
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

# Обязательные и допустимые ключи по типу файла (issue #201). Белый список
# ALLOWED — своя, не из рантайма, защита от PR #199 (ADR-022, раздел
# "Решение", п.4): перевёрстанная строка-продолжение, ставшая новым
# "ключ: значение", отвергается как неизвестный ключ, а не молча заводится.
REQUIRED = {
    "command": ["description", "argument-hint"],
    "agent": ["name", "description", "model", "tools"],
    "skill": ["name", "description"],
}
ALLOWED = {kind: set(keys) for kind, keys in REQUIRED.items()}

QUOTE_CHARS = ("\"", "\x27")
# U_1 рантайма (ADR-022): символьный класс fallback-триггера построчного
# кавотирования, буквальный порт регэкспа из бинаря 2.1.114.
U1 = re.compile(r"[{}\[\]*&#!|>%@`]|: ")
# Ключ рантайма: `^([a-zA-Z_-]+):\s+(.+)$`, но разделитель — буквальный
# пробел/таб, не `\s` (NBSP после ":" гейт тоже не принимает — ADR-022).
KEY_RE = re.compile(r"^([A-Za-z_-]+):([ \t](.*))?$")


def extract_frontmatter(text):
    # phH рантайма (ADR-022): ленивый поиск ПЕРВОГО "---" после открывающей
    # границы, где угодно в тексте, не обязательно отдельной строкой.
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, "нет открывающего --- на первой строке"
    rest = "\n".join(lines[1:])
    idx = rest.find("---")
    if idx == -1:
        return None, "нет закрывающего --- (фронтматтер не завершён)"
    return rest[:idx].split("\n"), None


def _find_quote_close(s, start, q):
    i, n = start, len(s)
    if q == "\"":
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == "\"":
                return i
            i += 1
        return None
    while i < n:
        if s[i] == "\x27":
            if i + 1 < n and s[i + 1] == "\x27":
                i += 2
                continue
            return i
        i += 1
    return None


def _unescape(s, q):
    if q == "\"":
        out = []
        i = 0
        while i < len(s):
            if s[i] == "\\" and i + 1 < len(s):
                out.append(s[i + 1])
                i += 2
            else:
                out.append(s[i])
                i += 1
        return "".join(out)
    return s.replace("\x27\x27", "\x27")


def quoted_scalar_legal(first_trimmed, continuation_texts):
    # Значение, начинающееся с кавычки: ищем парную закрывающую кавычку по
    # всем строкам записи (сворачивание многострочного кавыченного скаляра
    # — реальная YAML-семантика); что угодно после закрывающей кавычки,
    # кроме пробелов, — хвост, который ломает разбор (ADR-022).
    q = first_trimmed[0]
    segments = [first_trimmed] + [c.strip() for c in continuation_texts]
    joined = "\n".join(segments)
    close = _find_quote_close(joined, 1, q)
    if close is None:
        return False, None
    trailing = joined[close + 1:]
    if trailing.strip(" \t\n"):
        return False, None
    value = _unescape(joined[1:close], q)
    return True, " ".join(value.split("\n")).strip()


def scalar_legal(value_remainder, continuation_texts):
    trimmed = value_remainder.strip()
    if trimmed[:1] in QUOTE_CHARS:
        return quoted_scalar_legal(trimmed, continuation_texts)
    if trimmed[:2] in ("- ", "? ") or trimmed == "-":
        return False, None
    all_lines = [value_remainder] + list(continuation_texts)
    if any("\t" in ln for ln in all_lines):
        return False, None
    # Голое ":" на конце любой строки записи — fallback его не кавотирует
    # (триггер U_1 требует пробел после ":"), строгий парсер теряет весь
    # блок независимо от продолжения (ADR-022).
    if any(ln.endswith(":") for ln in all_lines):
        return False, None
    if continuation_texts:
        # Многострочное значение: U_1 где угодно в любой строке записи —
        # фатально, фронтматтер теряется целиком (ADR-022).
        if any(U1.search(ln) for ln in all_lines):
            return False, None
        parts = [p.strip() for p in all_lines if p.strip()]
        return True, " ".join(parts)
    if U1.search(value_remainder):
        return False, None
    return True, value_remainder.strip()


def looks_already_quoted(s):
    return len(s) >= 2 and s[0] in QUOTE_CHARS and s[-1] in QUOTE_CHARS


def quote_value(s):
    return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""


def fallback_transform_value(value_remainder):
    v = value_remainder.strip()
    if looks_already_quoted(v):
        return value_remainder, False
    if U1.search(value_remainder):
        return quote_value(v), True
    return value_remainder, False


def fallback_transform_continuation(cont_line):
    c = cont_line.strip()
    if looks_already_quoted(c):
        return cont_line, False
    if U1.search(cont_line):
        return quote_value(c), True
    return cont_line, False


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
            value = m.group(2)[1:] if m.group(2) is not None else ""
            if key not in ALLOWED[kind]:
                errors.append(
                    "строка %d: неизвестный ключ %r для %s (допустимы: %s)"
                    % (lineno, key, kind, ", ".join(sorted(ALLOWED[kind])))
                )
                return None
            if key in index:
                # Повторяющийся ключ — предупреждение, не ошибка
                # (осознанное решение мягче рантайма, ADR-022, п.4).
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

    strict_results = [scalar_legal(r["value"], r["continuations"]) for r in records]
    if all(ok for ok, _ in strict_results):
        return {r["key"]: val for r, (ok, val) in zip(records, strict_results)}

    # Fallback: построчное кавотирование применяется ко ВСЕМ записям
    # документа разом (не только к той, что провалила строгий разбор) — в
    # рантайме это один повторный Bun.YAML.parse над всем предобработанным
    # текстом, одна ошибка в любом месте теряет документ целиком (ADR-022).
    transformed = []
    doc_broken = False
    for r in records:
        new_value, value_requoted = fallback_transform_value(r["value"])
        if value_requoted and r["continuations"]:
            doc_broken = True
        new_conts = []
        for c in r["continuations"]:
            nc, cont_requoted = fallback_transform_continuation(c)
            if cont_requoted:
                doc_broken = True
            new_conts.append(nc)
        transformed.append((r["key"], new_value, new_conts))

    if doc_broken:
        return {}

    fallback_results = [scalar_legal(v, c) for (_, v, c) in transformed]
    if all(ok for ok, _ in fallback_results):
        return {key: val for (key, _, _), (ok, val) in zip(transformed, fallback_results)}
    return {}


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
