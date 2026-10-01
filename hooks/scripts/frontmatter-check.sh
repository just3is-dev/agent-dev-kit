#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md
# парсится и несёт обязательные по типу файла ключи (issue #201, класс
# бага PR #199 — commands/stats.md потерял description/argument-hint).
#
# Разбор — минимальный парсер «key: value / отступ-продолжение», не
# полноценный YAML: без внешней зависимости и терпимый к «: » внутри
# однострочного значения ровно в границах, где терпим построчный
# fallback-парсер рантайма Claude Code (механизм — ADR-022).
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
import sys

# Обязательные и допустимые ключи по типу файла (issue #201). Сейчас
# ALLOWED == REQUIRED для всех типов; опциональный ключ расширяет ALLOWED
# отдельно от REQUIRED.
REQUIRED = {
    "command": ["description", "argument-hint"],
    "agent": ["name", "description", "model", "tools"],
    "skill": ["name", "description"],
}
ALLOWED = {kind: set(keys) for kind, keys in REQUIRED.items()}

QUOTE_CHARS = ("\"", "\x27")


def unquote(v):
    if len(v) >= 2 and v[0] == v[-1] and v[0] in QUOTE_CHARS:
        return v[1:-1]
    return v


def has_colon_trigger(s):
    # ": " в любом месте строки или ":" на самом конце — граница, за
    # которой рантайм теряет фронтматтер (механизм — ADR-022).
    return ": " in s or s.endswith(":")


def parse_frontmatter(text, kind, warnings):
    # (dict ключ->значение, None) при успехе, (None, причина) при ошибке.
    # Строка с колонки 0 вида "key: значение" задаёт ключ; отступная
    # строка — продолжение значения предыдущего ключа. Границы терпимости
    # ниже — ADR-022.
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
    first_value = {}
    key = None
    for lineno, raw in enumerate(lines[1:end], start=2):
        if raw.strip() == "":
            continue
        if raw[0] not in (" ", "\t"):
            if ":" not in raw:
                return None, "строка %d: не \"ключ: значение\" и не отступ-продолжение: %r" % (lineno, raw)
            k, _, rest = raw.partition(":")
            k = k.strip()
            if not k:
                return None, "строка %d: пустой ключ" % lineno
            if rest and not rest[0].isspace():
                return None, "строка %d: нет пробела после \":\" — такую строку fallback-парсер рантайма не кавотирует" % lineno
            v = rest.strip()
            if k not in ALLOWED[kind]:
                return None, "строка %d: неизвестный ключ %r для %s (допустимы: %s)" % (
                    lineno, k, kind, ", ".join(sorted(ALLOWED[kind])))
            if k in data:
                warnings.append("строка %d: повторяющийся ключ %r, предыдущее значение перезаписано" % (lineno, k))
            data[k] = v
            first_value[k] = v
            key = k
        else:
            if key is None:
                return None, "строка %d: строка-продолжение до первого ключа" % lineno
            cont = raw.strip()
            if has_colon_trigger(first_value.get(key, "")):
                return None, "строка %d: строка-продолжение после двоеточия в первой строке записи — рантайм теряет весь блок" % lineno
            if has_colon_trigger(cont):
                return None, "строка %d: двоеточие в строке-продолжении — рантайм теряет значение" % lineno
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
    warnings = []
    data, err = parse_frontmatter(text, kind, warnings)
    for w in warnings:
        print("%s: %s" % (path, w), file=sys.stderr)
    if err:
        errors.append("%s: %s" % (path, err))
        continue
    for req in REQUIRED[kind]:
        if req not in data or not unquote(data[req]).strip():
            errors.append("%s: отсутствует или пуст обязательный ключ %r" % (path, req))

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
'
