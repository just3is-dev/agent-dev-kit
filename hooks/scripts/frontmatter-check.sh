#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md несёт
# обязательные по типу файла ключи (issue #201, класс бага PR #199).
#
# Разбор — белый список форм "ключ: значение / отступ-продолжение",
# эмпирически проверенных как безопасные против Bun.YAML 1.3.13
# (реверс-инжиниринг бинаря рантайма + дифференциальный фаззинг, см.
# ADR-022), а не попытка эмулировать сам парсер рантайма Claude Code:
# круг 6 ревью показал, что двухфазный алгоритм рантайма (строгий
# Bun.YAML.parse + построчный fallback) не моделируется предикатами на
# stdlib без собственного YAML-парсера — некоторые формы (одиночные
# спецсимволы YAML) не вызывают ошибку строгого парсера, а молча
# заменяют значение на null/массив/обрезанную строку, минуя fallback
# целиком. Гейт поэтому принимает ТОЛЬКО формы, безопасность которых
# проверена эмпирически против установленной версии Bun; всё
# остальное — отказ, даже если конкретный рантайм на конкретной версии
# это бы и разобрал правильно. Это не формальное доказательство
# относительно полной спецификации Bun.YAML — методика и объём проверки
# (фаззинг на сотни тысяч случайных документов по состоянию на круг 8)
# — в ADR-022.
#
# Использование: frontmatter-check.sh <project_root>
# exit 1 со списком ошибок вида "<файл>: <причина>" в stderr, если хоть
# один файл не разобрался как валидный фронтматтер своего типа или не
# хватает обязательного ключа; exit 0, если всё в порядке, в том числе
# когда ни commands/, ни agents/, ни skills/ в корне нет — гейт кита, не
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
# YAML core schema типизирует подобные токены как число (int/float/hex/
# octal/inf/nan), а не строку — обязательный ключ рантайм получает не
# строкой (ADR-022, круг 7 ревью PR #243).
NUMERIC_RE = re.compile(r"[-+]?(\.?[0-9][0-9a-fA-FxXoObB_.eE+-]*|\.(inf|Inf|INF|nan|NaN|NAN))")

KEY_RE = re.compile(r"^([A-Za-z_-]+):( +(.*))?$")


def extract_frontmatter(text):
    # Ленивая граница ---: первое вхождение "---" после открывающей
    # строки, где угодно в тексте, не обязательно отдельной строкой (так
    # же ведёт себя рантайм — ADR-022). Но если найденное вхождение само
    # не образует отдельную строку — оно обрезало значение посреди текста
    # (рантайм это делает молча, гейт обязан заметить и отказать, а не
    # согласиться с уже обрезанным значением — круг 7 ревью PR #243).
    # Сравнение построчное и байт-в-байт (файл открыт с newline=""), так
    # что CRLF/CR или юникодный разделитель строк (U+2028/U+2029/U+0085)
    # прямо на границе "---" уже не даёт точного совпадения со строкой
    # "---" и отклоняется здесь же, без отдельной проверки (круг 10:
    # прежняя проверка по всему файлу удалена как избыточная — то же
    # вхождение внутри блока фронтматтера ловит проверка ниже, а в теле
    # документа после закрывающей --- оно не влияет на разбор
    # фронтматтера вовсе).
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, "нет открывающего --- на первой строке"
    rest = "\n".join(lines[1:])
    idx = rest.find("---")
    if idx == -1:
        return None, "нет закрывающего --- (фронтматтер не завершён)"
    before_ok = idx == 0 or rest[idx - 1] == "\n"
    after = rest[idx + 3:]
    after_ok = after == "" or after[0] == "\n"
    if not (before_ok and after_ok):
        return None, "первое вхождение --- после открывающей строки не на отдельной строке — фронтматтер обрезан посреди значения"
    fm = rest[:idx]
    # Нестандартные пробельные/непечатаемые символы (NBSP, U+3000,
    # вертикальная табуляция и т. п.) внутри блока фронтматтера: str.strip()
    # и построчное сравнение видят их иначе, чем isspace() — рантайм может
    # обработать их не так, как обычный пробел/перевод строки. Безопасность
    # формы не доказана, отказ безусловно (круг 8 ревью PR #243).
    if any(c != " " and c != "\n" and (c.isspace() or not c.isprintable()) for c in fm):
        return None, "фронтматтер содержит нестандартный пробельный или непечатаемый символ"
    return fm.split("\n"), None


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
        # Хвостовые пробелы после закавыченного значения: quoted_safe()
        # получает уже обрезанный v и их не увидит — безопасность формы с
        # таким хвостом не доказана, отказ безусловно (круг 8 ревью PR #243).
        if value_remainder != value_remainder.rstrip():
            return False, None
        if continuation_texts:
            return False, None
        return quoted_safe(v)

    all_lines = [value_remainder] + list(continuation_texts)
    # Таб внутри значения здесь невозможен: extract_frontmatter уже
    # отказал бы на любом табе во фронтматтере (круг 8 ревью PR #243) —
    # прежняя отдельная проверка была недостижимой веткой, убрана в
    # круге 10.
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
    if "..." in assembled:
        # Bun.YAML 1.3.13 трактует "..." (с пробелом или концом строки
        # после) как маркер конца YAML-документа даже внутри значения
        # ключа — результат не бросает исключение, строгий разбор отдаёт
        # несколько документов, фронтматтер молча пустеет (ADR-022, круг
        # 7 ревью PR #243).
        return False, None
    if NUMERIC_RE.fullmatch(assembled):
        return False, None
    if assembled in FORBIDDEN_LITERALS:
        return False, None
    return True, assembled


def build_records(fm_lines, kind, errors):
    records = []
    index = {}
    current = None
    for lineno, raw in enumerate(fm_lines, start=2):
        if raw.strip() == "":
            continue
        # Таб как первый символ здесь тоже невозможен (см. выше) — эта
        # ветка только отличает новую запись от строки-продолжения
        # (круг 10: прежняя проверка "or raw[0] == tab" была
        # недостижимой).
        if raw[0] != " ":
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
                # Повторяющийся ключ — ошибка разбора, не предупреждение с
                # перезаписью: рантайм на дубле ключа теряет весь документ,
                # гейт обязан отказать той же дорогой (круг 8 ревью PR #243).
                errors.append("строка %d: повторяющийся ключ %r" % (lineno, key))
                return None
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


def resolve_frontmatter(fm_lines, kind, errors):
    records = build_records(fm_lines, kind, errors)
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


def parse_frontmatter(text, kind):
    errors = []
    fm_lines, err = extract_frontmatter(text)
    if err:
        return None, err
    data = resolve_frontmatter(fm_lines, kind, errors)
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
        # newline="": без универсального перевода строк — CRLF/CR должны
        # остаться видимыми extract_frontmatter(), не быть молча
        # нормализованы в "\n" (ADR-022, круг 7 ревью PR #243).
        with open(path, encoding="utf-8", newline="") as fh:
            text = fh.read()
    except OSError as e:
        errors.append("%s: не удалось прочитать (%s)" % (path, e))
        continue
    data, err = parse_frontmatter(text, kind)
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
