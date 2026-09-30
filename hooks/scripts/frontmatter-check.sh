#!/usr/bin/env bash
# Гейт: фронтматтер commands/*.md, agents/*.md и skills/*/SKILL.md
# парсится и несёт обязательные по типу файла ключи (issue #201, класс
# бага PR #199 — commands/stats.md потерял description/argument-hint).
# Разбор — минимальный парсер «key: value / отступ-продолжение», не
# полноценный YAML: без внешней зависимости и терпимый к «: » внутри
# однострочного значения (обоснование границ терпимости — ADR-021).
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

# Обязательные и допустимые ключи по типу файла (issue #201). Сейчас
# ALLOWED == REQUIRED для всех типов — если когда-нибудь появится
# опциональный ключ, ALLOWED расширяется отдельно от REQUIRED.
REQUIRED = {
    "command": ["description", "argument-hint"],
    "agent": ["name", "description", "model", "tools"],
    "skill": ["name", "description"],
}
ALLOWED = {kind: set(keys) for kind, keys in REQUIRED.items()}


def unquote(v):
    # "текст" -> текст — иначе description: "" читается как непустое
    # значение (ревью круга 1 PR #243). Питоновский литерал одинарной
    # кавычки внутри этого инлайн-скрипта недопустим (он завершил бы
    # обрамляющую bash single-quoted строку), поэтому распознаётся только
    # двойная кавычка — единственный стиль кавычек, реально используемый
    # во фронтматтере кита (argument-hint).
    if len(v) >= 2 and v[0] == v[-1] and v[0] == "\"":
        return v[1:-1]
    return v


def parse_frontmatter(text, kind):
    # Возвращает (dict ключ->значение, None) при успехе, (None, причина)
    # при ошибке разбора.
    #
    # Ключ — строка с колонки 0 вида "key: значение" (значение может быть
    # пустым — тогда его донабирают отступные строки-продолжения ниже);
    # ключ обязан входить в ALLOWED[kind] — неизвестный ключ отвергается,
    # а не молча заводится (иначе строка-продолжение, потерявшая отступ
    # и при этом содержащая ":", молча становится новым "ключом" вместо
    # ошибки — ровно класс бага issue #201, замеченный ревью круга 1).
    #
    # Строка не с колонки 0 — продолжение предыдущего ключа. Рантайм
    # Claude Code при провале строгого YAML кавычит только однострочные
    # "key: value" целиком; многострочное значение, чья строка-продолжение
    # сама содержит ": ", под этот fallback не попадает и теряется
    # ("nested mappings are not allowed in compact mappings" — найдено
    # ревью круга 1 PR #243 разбором рантайма) — гейт обязан повторять эту
    # границу, а не быть терпимее рантайма.
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
            if k not in ALLOWED[kind]:
                return None, "строка %d: неизвестный ключ %r для %s (допустимы: %s)" % (
                    lineno, k, kind, ", ".join(sorted(ALLOWED[kind])))
            data[k] = v
            key = k
        else:
            if key is None:
                return None, "строка %d: строка-продолжение до первого ключа" % lineno
            cont = raw.strip()
            if ": " in cont:
                return None, "строка %d: \": \" внутри строки-продолжения — рантайм Claude Code такое значение теряет (нет построчного fallback для многострочных значений)" % lineno
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
    data, err = parse_frontmatter(text, kind)
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
