#!/usr/bin/env bash
# Смоук-тесты agent-dev-kit: хуки-гейты и монорепный диспетчер.
# Каждый тест сверяет exit-код сценария с ожидаемым. Любой FAIL → exit 1.
set -u

KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$KIT/hooks/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

assert_exit() { # assert_exit <описание> <ожидаемый_код> <фактический_код>
  if [ "$3" -eq "$2" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (ожидали exit $2, получили $3)"
    fails=$((fails + 1))
  fi
}

git_c() { git -c user.email=t@t -c user.name=t "$@"; }

truncate_actual() { # truncate_actual <текст> — усечённое (~200 симв.) однострочное
  # представление фактического значения для FAIL-диагностики: переводы строк
  # схлопнуты в пробелы (issue #96), длинные значения обрезаны с многоточием.
  local t
  t="$(printf '%s' "$1" | tr '\n' ' ' | tr -s ' ')"
  if [ "${#t}" -gt 200 ]; then
    printf '%s…' "${t:0:200}"
  else
    printf '%s' "$t"
  fi
}

assert_contains() { # assert_contains <описание> <текст> <подстрока>
  if printf '%s' "$2" | grep -q -- "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (не найдено: $3; вернулось: '$(truncate_actual "$2")')"
    fails=$((fails + 1))
  fi
}

assert_not_contains() { # assert_not_contains <описание> <текст> <подстрока>
  if printf '%s' "$2" | grep -q -- "$3"; then
    echo "FAIL: $1 (неожиданно найдено: $3; вернулось: '$(truncate_actual "$2")')"
    fails=$((fails + 1))
  else
    echo "PASS: $1"
  fi
}

# ── Само-тест assert_contains / assert_not_contains: FAIL-ветка показывает
# фактическое значение (issue #96, K9 хвост ревью PR #83) ────────────────────
# Каждый вызов ниже — в подстановке команд (`$(...)`), то есть в подоболочке:
# намеренно спровоцированный FAIL инкрементирует $fails только внутри неё и
# не портит счётчик реального прогона.
meta_out=$(assert_contains "meta" "actual-value-xyz" "no-such-substring")
assert_contains "assert_contains: FAIL показывает фактическое значение" "$meta_out" "actual-value-xyz"
meta_out=$(assert_contains "meta" "actual-value-xyz" "actual")
assert_not_contains "assert_contains: PASS-вывод не изменился" "$meta_out" "actual-value-xyz"

meta_out=$(assert_not_contains "meta" "actual-value-abc" "actual")
assert_contains "assert_not_contains: FAIL показывает фактическое значение" "$meta_out" "actual-value-abc"
meta_out=$(assert_not_contains "meta" "actual-value-abc" "no-such-substring")
assert_not_contains "assert_not_contains: PASS-вывод не изменился" "$meta_out" "actual-value-abc"

long_val=$(printf 'x%.0s' $(seq 1 500))
meta_out=$(assert_contains "meta" "$long_val" "no-such-substring")
assert_contains "assert_contains: FAIL показывает начало длинного значения" "$meta_out" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
[ "${#meta_out}" -lt 300 ]
assert_exit "assert_contains: FAIL усекает длинное фактическое значение (не выводит все 500 символов)" 0 $?

multiline_val="$(printf 'line1\nline2\nline3')"
meta_out=$(assert_contains "meta" "$multiline_val" "no-such-substring")
nl_count=$(printf '%s' "$meta_out" | wc -l | tr -d ' ')
assert_exit "assert_contains: FAIL схлопывает переводы строк в диагностике (однострочный вывод)" 0 "$nl_count"

check_ac_doc() { # check_ac_doc <AC-тег> <описание> <файл> <искомая подстрока>
  # Markdown-прозу переносит по словам — схлопываем переводы строк и
  # повторяющиеся пробелы, чтобы искомая фраза не ломалась о жёсткий
  # перенос строки, случайно совпавший с серединой фразы.
  if tr '\n' ' ' < "$3" | tr -s ' ' | grep -qF -- "$4"; then
    echo "PASS: $1: $2"
  else
    echo "FAIL: $1: $2 — не найдена подстрока «$4» в $3"
    fails=$((fails + 1))
  fi
}

md_section() { # md_section <файл> <начало-ERE> <конец-ERE, либо $ — до конца файла>
  # Срез куска markdown-инструкции (шага, раздела) с той же нормализацией
  # переносов, что и в check_ac_doc: результат ищут через assert_contains.
  # Нижняя граница обязательна — срез без неё тянет файл до конца (PR #69).
  # Адреса sed используют `|` вместо `/` как разделитель (issue #98, K11):
  # паттерны шагов могут содержать `/` (например, `origin/main`), а `/`-разделитель
  # ломается на первом же таком паттерне с "unknown command".
  local end="$3"
  [ "$end" = '$' ] || end="\\|$3|"
  sed -nE "\\|$2|,${end}p" "$1" | tr '\n' ' ' | tr -s ' '
}

count_lines() { # count_lines <файл> — обёртка над wc -l для сравнения через assert_exit
  wc -l < "$1" | tr -d ' '
}

jsonl_check() { # jsonl_check <файл> <ожидаемое_число_строк> <спека_полей>
  # Общий валидатор JSONL-смоуков (issue #28 K4, было 3 копии): проверяет,
  # что файл — ровно <ожидаемое_число_строк> валидных JSON-объектов, что
  # у каждой строки есть непустой "timestamp", и сверяет поля по <спеке>.
  # <спека> — одна запись на строку файла (в том же порядке), поля внутри
  # записи разделены '|': "ключ=значение" — точное совпадение,
  # "ключ?" — просто непустое присутствие (пустая спека или пустая запись —
  # без дополнительных проверок полей, только количество строк + timestamp).
  # Печатает "1"/"0" — совместимо с assert_exit.
  python3 -c '
import json, sys
path, expected_n, spec = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(path) as f:
        lines = [json.loads(l) for l in f]
except Exception:
    print("0")
    sys.exit(0)
ok = len(lines) == expected_n
spec_lines = spec.split("\n") if spec else []
if ok and spec_lines and len(spec_lines) != len(lines):
    ok = False
if ok:
    for rec, sl in zip(lines, spec_lines):
        if "timestamp" not in rec or not rec["timestamp"]:
            ok = False
            break
        for tok in sl.split("|"):
            if not tok:
                continue
            if tok.endswith("?"):
                k = tok[:-1]
                if k not in rec or rec[k] in ("", None):
                    ok = False
                    break
            else:
                k, _, v = tok.partition("=")
                if rec.get(k) != v:
                    ok = False
                    break
        if not ok:
            break
print("1" if ok else "0")
' "$1" "$2" "$3"
}

# Общие срезы markdown-шагов команд, переиспользуемые в нескольких блоках
# тестов ниже (issue #98, K16): раньше вычислялись повторно под разными
# именами (work_ready/step6; ap_merge/autopilot_step3/step3/step3_ac3) —
# по одной переменной на срез, вычисленной один раз рядом с хелперами.
work_step6=$(md_section "$KIT/commands/work.md" '^6\. \*\*' '^7\. \*\*')
autopilot_step3=$(md_section "$KIT/commands/autopilot.md" '^3\. \*\*' '^4\. \*\*')

# ── Одиночный проект с контрактом ────────────────────────────────────────────
P="$TMP/proj"
mkdir -p "$P/scripts" "$P/src"
(cd "$P" && git init -q -b main)
cat > "$P/scripts/check" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *bad*) echo "type error in $a"; exit 1;; esac; done
exit 0
EOF
cat > "$P/scripts/test" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")/.." && pwd)"
echo run >> "$here/.test-runs"
[ -f "$here/.fail-tests" ] && { echo "FAIL some.test"; exit 1; }
exit 0
EOF
chmod +x "$P/scripts/check" "$P/scripts/test"
# тестовые артефакты игнорируются, как в реальном проекте — иначе они
# меняют хэш диффа и кэш Stop-хука никогда не попадает
printf '.test-runs\n.fail-tests\n' > "$P/.gitignore"
echo x > "$P/src/good.ts"
echo x > "$P/src/bad.ts"

# post-edit-check
printf '{"tool_input":{"file_path":"%s"}}' "$P/src/bad.ts" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: падающий файл блокируется" 2 $?
printf '{"tool_input":{"file_path":"%s"}}' "$P/src/good.ts" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: чистый файл проходит" 0 $?
printf '{"tool_input":{"file_path":"%s"}}' "$TMP/outside.txt" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: файл вне проекта с контрактом пропускается" 0 $?

# post-edit-check: правка templates/*/scripts/check в корне кита не должна
# ложно фейлить (issue #14) — см. комментарий у in_kit_templates() в
# post-edit-check.sh. Кит-подобная структура: маркер .claude-plugin/plugin.json,
# свой scripts/check в корне (проходит) и templates/demo/scripts/check
# (падает, если его реально прогнать — имитирует контракт шаблона,
# нерелевантный правке самого файла шаблона).
KITSIM="$TMP/kitsim"
mkdir -p "$KITSIM/.claude-plugin" "$KITSIM/scripts" "$KITSIM/templates/demo/scripts"
echo '{}' > "$KITSIM/.claude-plugin/plugin.json"
cat > "$KITSIM/scripts/check" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$KITSIM/templates/demo/scripts/check" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$KITSIM/scripts/check" "$KITSIM/templates/demo/scripts/check"
printf '{"tool_input":{"file_path":"%s"}}' "$KITSIM/templates/demo/scripts/check" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: правка шаблонного templates/*/scripts/check в корне кита не запускает контракт кита (issue #14)" 0 $?

# post-edit-check: сторонний проект, у которого в пути случайно есть каталог
# "templates" (нет маркера кита .claude-plugin/plugin.json рядом) — не кит,
# его контракт должен по-прежнему отрабатывать как обычно (регрессия фикса
# issue #14: пропуск каталогов templates/ не должен быть шире, чем "templates/
# именно у корня кита").
NOKIT="$TMP/no-kit-marker/templates/myapp"
mkdir -p "$NOKIT/scripts" "$NOKIT/src"
cat > "$NOKIT/scripts/check" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *bad*) exit 1;; esac; done
exit 0
EOF
chmod +x "$NOKIT/scripts/check"
echo x > "$NOKIT/src/bad.ts"
printf '{"tool_input":{"file_path":"%s"}}' "$NOKIT/src/bad.ts" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: проект с 'templates' в пути без маркера кита проверяется как обычно" 2 $?

# post-edit-check: пакет со своим контрактом внутри templates/ монорепы, у
# которой нет маркера кита — контракт пакета должен по-прежнему отрабатывать
# (та же регрессия: не спутать любой каталог templates/ с templates/ кита).
MONOPKG="$TMP/mono-no-kit/templates/mail"
mkdir -p "$MONOPKG/scripts" "$MONOPKG/src"
cat > "$MONOPKG/scripts/check" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *bad*) exit 1;; esac; done
exit 0
EOF
chmod +x "$MONOPKG/scripts/check"
echo x > "$MONOPKG/src/bad.ts"
printf '{"tool_input":{"file_path":"%s"}}' "$MONOPKG/src/bad.ts" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "post-edit-check: пакет со своим контрактом внутри templates/ монорепы без маркера кита проверяется как обычно" 2 $?

# stop-test
touch "$P/.fail-tests"
echo '{}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: красные тесты блокируют завершение" 2 $?
rm "$P/.fail-tests"
rm -f "$P/.test-runs"
echo '{}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: зелёные тесты пропускают" 0 $?
echo '{}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: повторный Stop без правок проходит" 0 $?
runs=$(count_lines "$P/.test-runs")
assert_exit "stop-test: кэш — тесты реально бежали один раз, не $runs" 1 "$runs"
touch "$P/.fail-tests"
echo '{"stop_hook_active":true}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: stop_hook_active — защита от цикла" 0 $?
rm "$P/.fail-tests"
(cd "$P" && git add -A && git_c commit -qm init)
echo '{}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: чистое рабочее дерево пропускается" 0 $?

# bash-guard: обход гейтов
printf '{"tool_input":{"command":"git commit -m fix --no-verify"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: --no-verify запрещён" 2 $?
printf '{"tool_input":{"command":"git push --force origin main"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: force push в main запрещён" 2 $?
printf '{"tool_input":{"command":"git push --force origin issue-42-fix"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: force push в фичевую ветку разрешён" 0 $?
printf '{"tool_input":{"command":"git commit -m ok"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: обычный commit без секретов разрешён" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=draft CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: merge draft-PR запрещён (нет APPROVE)" 2 $?
printf '{"tool_input":{"command":"gh pr merge 5 --merge"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: merge ready-PR (после APPROVE) разрешён" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5"}}' | ADK_GUARD_PR_STATE=unknown CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: merge при непроверяемом статусе PR запрещён" 2 $?
printf '{"tool_input":{"command":"gh pr create --title x"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: gh pr create разрешён" 0 $?

# bash-guard: политика merge из adk.config.json (SPEC-002 AC-2).
# Тесты выше (draft/ready/unknown без конфига) — режим по умолчанию
# agent-after-approve; здесь конфиг задаёт остальные режимы.
printf '{"policies": {"merge": "human-only"}}' > "$P/adk.config.json"
guard_err=$(printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" 2>&1 >/dev/null)
assert_exit "AC-2: policies.merge=human-only — merge ready-PR блокируется" 2 $?
assert_contains "AC-2: human-only — в deny-тексте названа именно политика" "$guard_err" 'policies.merge=human-only'

printf '{"policies": {"merge": "human-review-required"}}' > "$P/adk.config.json"
guard_err=$(printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready ADK_GUARD_PR_REVIEW_DECISION=REVIEW_REQUIRED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" 2>&1 >/dev/null)
assert_exit "AC-2: policies.merge=human-review-required — блок без человеческого approve" 2 $?
assert_contains "AC-2: human-review-required — в deny-тексте названа именно политика" "$guard_err" 'policies.merge=human-review-required'
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready ADK_GUARD_PR_REVIEW_DECISION=APPROVED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-review-required — merge разрешён при reviewDecision=APPROVED" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=draft ADK_GUARD_PR_REVIEW_DECISION=APPROVED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-review-required — draft блокируется даже с approve" 2 $?

printf '{"policies": {"merge": "agent-after-approve"}}' > "$P/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=agent-after-approve — merge ready-PR разрешён (как без конфига)" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=draft CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=agent-after-approve — draft блокируется (как без конфига)" 2 $?

# Неизвестное значение политики — fail-closed: дефолт policies.merge
# умышленно разрешающий, опечатка не должна молча открывать гейт
printf '{"policies": {"merge": "human_only"}}' > "$P/adk.config.json"
guard_err=$(printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" 2>&1 >/dev/null)
assert_exit "AC-2: опечатка в policies.merge блокирует merge (fail-closed, не откат в разрешающий дефолт)" 2 $?
assert_contains "AC-2: опечатка в policies.merge — deny-текст объясняет причину" "$guard_err" 'неизвестное значение policies.merge'

# Конфиг ищется от репозитория команды, а не от корня сессии: в
# мульти-директорной сессии CLAUDE_PROJECT_DIR может указывать вне проекта
printf '{"policies": {"merge": "human-only"}}' > "$P/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$P" | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$TMP" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: human-only действует и при корне сессии вне проекта (конфиг от репозитория команды)" 2 $?

# Конфиг лежит в toplevel репозитория, а команда выполняется из подкаталога:
# политика обязана найтись через rev-parse --show-toplevel, а не от cwd
mkdir -p "$P/sub"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$P/sub" | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$TMP" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: human-only действует из подкаталога репозитория (конфиг от toplevel)" 2 $?
rm "$P/adk.config.json"

# issue #78: проект — подкаталог более крупного репозитория со своим
# adk.config.json (toplevel репозитория без конфига); корень конфига —
# первый кандидат, где файл реально есть (cwd команды → git toplevel этой
# cwd → CLAUDE_PROJECT_DIR → git toplevel безусловно), а не безусловный
# toplevel — до фикса toplevel побеждал всегда, свой конфиг подкаталога не
# находился, human-only не срабатывал.
MONOROOT="$TMP/monorepo"
mkdir -p "$MONOROOT/proj"
(cd "$MONOROOT" && git_c init -q -b main)
printf '{"policies": {"merge": "human-only"}}' > "$MONOROOT/proj/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$MONOROOT/proj" \
  | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$MONOROOT" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "issue #78: bash-guard находит конфиг подкаталога-проекта, а не безусловный toplevel репозитория" 2 $?
rm -rf "$MONOROOT"

# issue #78, круг 2 ревью: git toplevel КОМАНДЫ обязан выигрывать у
# CLAUDE_PROJECT_DIR сессии, а не наоборот — сессия открыта в проекте с
# разрешающим конфигом, а сама команда идёт из подкаталога другого
# репозитория со своим более строгим конфигом; конфиг сессии не должен
# молча подменять конфиг репозитория команды (иначе новый fail-open в том
# же жёстком слое, который #78 и чинил).
MONOROOT2="$TMP/monorepo2"
mkdir -p "$MONOROOT2/sub"
(cd "$MONOROOT2" && git_c init -q -b main)
printf '{"policies": {"merge": "human-only"}}' > "$MONOROOT2/adk.config.json"
SESSIONPROJ="$TMP/session-proj"
mkdir -p "$SESSIONPROJ"
printf '{"policies": {"merge": "agent-after-approve"}}' > "$SESSIONPROJ/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$MONOROOT2/sub" \
  | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$SESSIONPROJ" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "issue #78 круг 2: git toplevel команды выигрывает у CLAUDE_PROJECT_DIR сессии, а не наоборот" 2 $?
rm -rf "$MONOROOT2" "$SESSIONPROJ"

# CLAUDE_PROJECT_DIR остаётся кандидатом (третьим): команда идёт не из
# git-репозитория вовсе — тогда побеждает конфиг сессии.
NONGIT="$TMP/nongit-scratch"
mkdir -p "$NONGIT"
SESSIONPROJ2="$TMP/session-proj2"
mkdir -p "$SESSIONPROJ2"
printf '{"policies": {"merge": "human-only"}}' > "$SESSIONPROJ2/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$NONGIT" \
  | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$SESSIONPROJ2" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "issue #78: CLAUDE_PROJECT_DIR — третий кандидат, побеждает, когда у команды нет своего git-репозитория" 2 $?
rm -rf "$NONGIT" "$SESSIONPROJ2"

# bash-guard: секрет-гейт (фейковый ключ собирается конкатенацией,
# чтобы литерал не лежал в исходниках кита)
FAKE_AWS="AKIA""IOSFODNN7EXAMPLE"
echo "aws_key = '$FAKE_AWS'" > "$P/src/config.ts"
printf '{"tool_input":{"command":"git add -A && git commit -m leak"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: секрет в новом файле блокирует commit" 2 $?
rm "$P/src/config.ts"
echo "const url = process.env.API_URL" > "$P/src/config.ts"
printf '{"tool_input":{"command":"git add -A && git commit -m ok"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: env-переменные вместо секретов — commit разрешён" 0 $?
echo "SECRET=real-value" > "$P/.env"
(cd "$P" && git add -f .env)
printf '{"tool_input":{"command":"git commit -m env"}}' | CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: застейдженный .env блокирует commit" 2 $?
(cd "$P" && git rm -q --cached .env && rm .env)

# bash-guard: мульти-директорная сессия — корень сессии не репозиторий,
# рабочая директория определяется из cwd payload или из cd в самой команде
echo "aws2 = '$FAKE_AWS'" > "$P/src/leak2.ts"
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$P" | CLAUDE_PROJECT_DIR="$TMP" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: секрет-гейт при корне сессии вне репо (cwd из payload)" 2 $?
printf '{"tool_input":{"command":"cd %s && git commit -m x"}}' "$P" | CLAUDE_PROJECT_DIR="$TMP" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "bash-guard: секрет-гейт через cd в команде" 2 $?
rm "$P/src/leak2.ts"

# ── pr-title-check: PostToolUse-валидация заголовка PR (commitStyle=conventional, AC-5) ──
# SPEC-002: заголовок PR — будущее сообщение squash-коммита в main, поэтому
# точка контроля конвенции одна — он, не веточные коммиты. После gh pr
# create/edit проверяется фактический заголовок PR (gh pr view), а не текст
# команды — разбора shell нет вовсе (ADR-004). Хук PostToolUse: действие уже
# случилось, exit 2 — это требование исправить заголовок, не блок.
# Тестовые обходы сети (по образцу ADK_GUARD_PR_STATE):
# ADK_GUARD_PR_TITLE — фактический заголовок PR ("unavailable" — gh или PR
# недоступны); ADK_GUARD_ISSUE_LABELS — CSV labels issue (пустая строка —
# labels нет; "unavailable" — gh или issue недоступны).
TITLEP="$TMP/titleproj"
mkdir -p "$TITLEP"
(cd "$TITLEP" && git init -q -b main)
printf '{"conventions": {"commitStyle": "conventional"}}' > "$TITLEP/adk.config.json"
TCMD='{"tool_input":{"command":"gh pr create --draft --body x"}}'

printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="Добавить фичу (#12)" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — заголовок без префикса типа отклоняется" 2 $?
title_err=$(printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="Добавить фичу (#12)" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" 2>&1 >/dev/null)
assert_contains "AC-5: отказ подсказывает исправление через gh pr edit --title" "$title_err" 'gh pr edit'
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: добавить фичу" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — заголовок без (#N) отклоняется" 2 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: починить гейт (#12)" ADK_GUARD_ISSUE_LABELS="type:bug" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — commitType не соответствует label'у issue (type:bug → fix, не feat)" 2 $?
mm_err=$(printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: починить гейт (#12)" ADK_GUARD_ISSUE_LABELS="type:bug" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" 2>&1 >/dev/null)
assert_contains "AC-5: подсказка mismatch даёт шаблон, проходящий проверку (fix: <суть> (#12))" "$mm_err" 'fix: <суть> (#12)'
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: добавить фичу (#12)" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — корректный заголовок проходит" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="fix(guard): починить гейт (#12)" ADK_GUARD_ISSUE_LABELS="type:bug" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — корректный заголовок со scope проходит" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: добавить фичу (#12)" ADK_GUARD_ISSUE_LABELS="" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — issue без label трактуется как task (feat проходит)" 0 $?
# Любой gh pr edit триггерит сверку фактического заголовка — даже если сама
# команда заголовок не меняла (валидируется состояние PR, не команда)
printf '%s' '{"tool_input":{"command":"gh pr edit 12 --add-label wip"}}' \
  | ADK_GUARD_PR_TITLE="без формата вовсе" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: gh pr edit — фактический заголовок сверяется независимо от флагов команды" 2 $?
# Команда без gh pr create/edit валидацию не запускает вовсе
printf '%s' '{"tool_input":{"command":"git push -u origin issue-12-x"}}' \
  | ADK_GUARD_PR_TITLE="без формата вовсе" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: команда без gh pr create/edit не проверяется" 0 $?
# Shell-подстановки в команде безразличны: проверяется фактический заголовок
# (класс ложных запретов/пропусков парсера команд снят по построению)
printf '%s' '{"tool_input":{"command":"CT=$(hooks/scripts/adk-config.sh types.task.commitType feat); gh pr create --draft --title \"$CT: добавить валидацию (#12)\" --body \"Closes #12\""}}' \
  | ADK_GUARD_PR_TITLE="feat: добавить валидацию (#12)" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: shell-подстановка в команде не мешает — сверяется фактический заголовок" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="unavailable" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: gh или PR недоступны — не блокируем (fail-open)" 0 $?
# Кастомный тип из конфига переопределяет дефолтную карту label → commitType
printf '{"conventions": {"commitStyle": "conventional"}, "types": {"docs": {"label": "type:docs", "commitType": "docs"}}}' > "$TITLEP/adk.config.json"
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="docs: описать конфиг (#12)" ADK_GUARD_ISSUE_LABELS="type:docs" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — кастомный тип из types.* конфига учитывается" 0 $?
# commitType — произвольная строка конфига, алфавит формата не ограничен
printf '{"conventions": {"commitStyle": "conventional"}, "types": {"deps": {"label": "type:deps", "commitType": "build-deps"}}}' > "$TITLEP/adk.config.json"
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="build-deps: обновить зависимости (#12)" ADK_GUARD_ISSUE_LABELS="type:deps" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — commitType с дефисом из конфига проходит проверку формата" 0 $?
printf '{"conventions": {"commitStyle": "conventional"}}' > "$TITLEP/adk.config.json"
# Поведенческое покрытие дефолтной карты: fast-follow → fix, consolidate → refactor
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="fix: доработка по ревью (#12)" ADK_GUARD_ISSUE_LABELS="type:fast-follow" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: type:fast-follow — fix проходит (дефолтная карта, поведение)" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: доработка по ревью (#12)" ADK_GUARD_ISSUE_LABELS="type:fast-follow" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: type:fast-follow — feat отклоняется (ожидается fix)" 2 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="refactor: слить дубли (#12)" ADK_GUARD_ISSUE_LABELS="type:consolidate" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: type:consolidate — refactor проходит (дефолтная карта, поведение)" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: слить дубли (#12)" ADK_GUARD_ISSUE_LABELS="type:consolidate" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: type:consolidate — feat отклоняется (ожидается refactor)" 2 $?
# Недоступность gh/issue не блокирует ложно: формат проверяем (он не требует
# сети), сверку commitType с label'ом — пропускаем
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="feat: добавить фичу (#12)" ADK_GUARD_ISSUE_LABELS="unavailable" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: conventional — недоступность gh/issue не блокирует корректный заголовок" 0 $?
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="без формата вовсе (#12)" ADK_GUARD_ISSUE_LABELS="unavailable" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: недоступность gh/issue — проверка формата всё равно работает" 2 $?
printf '{"conventions": {"commitStyle": "conventional", "externalTitleLint": true}}' > "$TITLEP/adk.config.json"
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="без формата вовсе" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: externalTitleLint=true — серверный линтер есть, локальная проверка выключена" 0 $?
printf '{"conventions": {"commitStyle": "plain"}}' > "$TITLEP/adk.config.json"
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="любой заголовок без конвенции" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: plain — любой заголовок проходит" 0 $?
rm "$TITLEP/adk.config.json"
printf '%s' "$TCMD" \
  | ADK_GUARD_PR_TITLE="любой заголовок без конвенции" ADK_GUARD_ISSUE_LABELS="type:task" CLAUDE_PROJECT_DIR="$TITLEP" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "AC-5: без конфига любой заголовок проходит (дефолт plain)" 0 $?

# issue #78: проект — подкаталог более крупного репозитория со своим
# adk.config.json (toplevel репозитория без конфига); корень конфига —
# первый кандидат, где файл реально есть (cwd команды → git toplevel этой
# cwd → CLAUDE_PROJECT_DIR → git toplevel безусловно), а не безусловный
# toplevel.
MONOTITLE="$TMP/monorepo-title"
mkdir -p "$MONOTITLE/proj"
(cd "$MONOTITLE" && git_c init -q -b main)
printf '{"conventions": {"commitStyle": "conventional"}}' > "$MONOTITLE/proj/adk.config.json"
printf '{"tool_input":{"command":"gh pr create --draft --body x"},"cwd":"%s"}' "$MONOTITLE/proj" \
  | ADK_GUARD_PR_TITLE="без формата вовсе" CLAUDE_PROJECT_DIR="$MONOTITLE" "$HOOKS/pr-title-check.sh" >/dev/null 2>&1
assert_exit "issue #78: pr-title-check находит conventions.commitStyle подкаталога-проекта, а не безусловный toplevel репозитория" 2 $?
rm -rf "$MONOTITLE"

# Хук зарегистрирован в hooks.json именно как PostToolUse с matcher Bash
title_reg=$(python3 -c 'import json, sys
entries = json.load(open(sys.argv[1]))["hooks"].get("PostToolUse", [])
ok = any(e.get("matcher") == "Bash"
         and any("pr-title-check.sh" in h.get("command", "") for h in e.get("hooks", []))
         for e in entries)
print("registered" if ok else "missing")' "$KIT/hooks/hooks.json")
assert_contains "AC-5: pr-title-check.sh зарегистрирован как PostToolUse(Bash)" "$title_reg" 'registered'

# ── Уведомления ──────────────────────────────────────────────────────────────
NDIR="$TMP/tmpdir/agent-dev-kit-notify"
mkdir -p "$TMP/tmpdir"
NFILE="$TMP/notifications.log"

printf '{"session_id":"sid1"}' | TMPDIR="$TMP/tmpdir" "$HOOKS/prompt-timestamp.sh"
assert_contains "prompt-timestamp: время начала хода записано" "$(cat "$NDIR/sid1" 2>/dev/null)" '^[0-9][0-9]*$'

printf '{"message":"Нужно разрешение на Bash"}' | ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/notification.sh"
assert_contains "notification: запрос ввода порождает уведомление" "$(cat "$NFILE" 2>/dev/null)" "Нужно разрешение на Bash"

# stop-test: долгий ход (метка старше порога) на чистом дереве → уведомление
echo $(( $(date +%s) - 100 )) > "$NDIR/sid2"
rm -f "$NFILE"
printf '{"session_id":"sid2"}' | TMPDIR="$TMP/tmpdir" ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: уведомление — exit 0 при чистом дереве" 0 $?
assert_contains "stop-test: долгий ход завершён — уведомление отправлено" "$(cat "$NFILE" 2>/dev/null)" "Задача завершена"

# stop-test: короткий ход (метка свежая) → без уведомления
date +%s > "$NDIR/sid3"
rm -f "$NFILE"
printf '{"session_id":"sid3"}' | TMPDIR="$TMP/tmpdir" ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
[ ! -f "$NFILE" ]
assert_exit "stop-test: короткий ход — без уведомления" 0 $?

# stop-test: провал тестов → БЕЗ уведомления «завершено» (работа продолжается)
# правка файла инвалидирует кэш успешного прогона (.fail-tests гитигнорится и хэш не меняет)
echo "// change" >> "$P/src/config.ts"
touch "$P/.fail-tests"
echo $(( $(date +%s) - 100 )) > "$NDIR/sid4"
rm -f "$NFILE"
printf '{"session_id":"sid4"}' | TMPDIR="$TMP/tmpdir" ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
st=$?
rm "$P/.fail-tests"
assert_exit "stop-test: красные тесты — блок хода" 2 "$st"
[ ! -f "$NFILE" ]
assert_exit "stop-test: красные тесты — без уведомления о завершении" 0 $?

# ── Журнал (adk-log.sh) ──────────────────────────────────────────────────────
LOGP="$TMP/logproj"
mkdir -p "$LOGP"
(cd "$LOGP" && git init -q -b main)

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=start issue=1 >/dev/null 2>&1
assert_exit "AC-1: adk-log: запись под дефолтным путём завершается успешно" 0 $?
[ -f "$LOGP/.adk/logs/issue-1.jsonl" ]
assert_exit "AC-1: adk-log: запись создаёт файл в .adk/logs/" 0 $?

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=review verdict=APPROVE >/dev/null 2>&1
lines=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
assert_exit "AC-1: adk-log: повторная запись дописывает вторую строку, не трёт первую" 2 "$lines"
first_event=$(sed -n '1p' "$LOGP/.adk/logs/issue-1.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("event",""))' 2>/dev/null)
assert_contains "AC-1: adk-log: первая строка не перезаписана вторым событием" "$first_event" '^start$'

valid=$(jsonl_check "$LOGP/.adk/logs/issue-1.jsonl" 2 "$(printf 'event?\nevent?')")
assert_exit "AC-1: adk-log: каждая строка — валидный JSON с timestamp и полями" 1 "$valid"

before_badpair=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event badpair >/dev/null 2>&1
assert_exit "AC-1: adk-log: аргумент без '=' отклоняется с ошибкой" 1 $?
after_badpair=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
assert_exit "AC-1: adk-log: отклонённый аргумент не пишет строку в журнал" "$before_badpair" "$after_badpair"

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=spoof timestamp=bogus >/dev/null 2>&1
last_ts=$(tail -n1 "$LOGP/.adk/logs/issue-1.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("timestamp",""))')
assert_not_contains "AC-1: adk-log: служебный timestamp не подменяется переданным полем" "$last_ts" '^bogus$'

CUSTOM="$TMP/customlogs"
rm -rf "$CUSTOM"
ADK_LOGS_DIR="$CUSTOM" CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" autopilot-2026-08-07 event=run_start >/dev/null 2>&1
[ -f "$CUSTOM/autopilot-2026-08-07.jsonl" ]
assert_exit "AC-1: adk-log: ADK_LOGS_DIR переопределяет путь — файл создан в нём" 0 $?
[ ! -f "$LOGP/.adk/logs/autopilot-2026-08-07.jsonl" ]
assert_exit "AC-1: adk-log: ADK_LOGS_DIR переопределяет путь — файл не создан под дефолтным" 0 $?

gi_content=$(cat "$LOGP/.adk/.gitignore" 2>/dev/null)
assert_contains "AC-1: adk-log: .adk/.gitignore создан с содержимым *" "$gi_content" '^\*$'

adk_status=$(cd "$LOGP" && git status --porcelain -- .adk 2>/dev/null)
[ -z "$adk_status" ]
assert_exit "AC-1: adk-log: git status пуст для .adk/ (самоигнорирующаяся папка)" 0 $?

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=merge >/dev/null 2>&1
gi_lines_after=$(count_lines "$LOGP/.adk/.gitignore")
assert_exit "AC-1: adk-log: повторная запись не дублирует .adk/.gitignore" 1 "$gi_lines_after"

assert_contains "AC-1: adk-log: templates/base/gitignore содержит .adk/" \
  "$(cat "$KIT/templates/base/gitignore")" '^\.adk/$'

# ── Сводка по журналу (adk-stats.sh, AC-3) ───────────────────────────────────
# Схема событий — ADR-001 (docs/adr/001-journal-event-schema.md).

# пустой каталог журнала — exit 0, сообщение, без выдуманных цифр
STATS_EMPTY="$TMP/stats-empty"
mkdir -p "$STATS_EMPTY"
stats_out=$(ADK_LOGS_DIR="$STATS_EMPTY" "$HOOKS/adk-stats.sh" 2>&1)
stats_st=$?
assert_exit "AC-3: adk-stats: пустой каталог журнала — exit 0" 0 "$stats_st"
assert_contains "AC-3: adk-stats: пустой каталог — сообщение об отсутствии записей" "$stats_out" "пуст"
assert_not_contains "AC-3: adk-stats: пустой журнал не выдумывает агрегаты" "$stats_out" "Всего задач"

# каталог журнала вовсе не существует — тоже exit 0 с сообщением, не падение
stats_out=$(ADK_LOGS_DIR="$TMP/stats-missing" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: несуществующий каталог журнала — exit 0" 0 $?
assert_contains "AC-3: adk-stats: несуществующий каталог — сообщение, не трейсбек" "$stats_out" "пуст"

# каталог содержит только autopilot-*.jsonl (нет issue-*.jsonl) — журнал НЕ
# пуст (записи прогонов есть), сообщение не должно врать про "пусто", и
# агрегаты не должны показываться (агрегирует только issue-*.jsonl)
STATS_AP_ONLY="$TMP/stats-autopilot-only"
mkdir -p "$STATS_AP_ONLY"
cat > "$STATS_AP_ONLY/autopilot-2026-08-03.jsonl" <<'EOF'
{"event":"run_start","timestamp":"2026-08-03T08:00:00Z"}
{"event":"run_end","done":"0","stuck":"0","skipped":"0","timestamp":"2026-08-03T08:01:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_AP_ONLY" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: каталог только с autopilot-файлом — exit 0" 0 $?
assert_not_contains "AC-3: adk-stats: каталог только с autopilot-файлом — без агрегатов по задачам" "$stats_out" "Всего задач"
assert_contains "AC-3: adk-stats: сообщение честно отличает 'нет issue-записей' от 'журнал пуст'" "$stats_out" "нет ни одной задачи"
assert_contains "AC-3: adk-stats: сообщение про каталог только с autopilot-файлом называет autopilot" "$stats_out" "autopilot"

# каталог содержит только незавершённую задачу (event=start/review, без
# outcome) — журнал НЕ пуст (есть записи), сообщение не должно говорить
# "Журнал пуст" (это самая частая ситуация свежего проекта — /work только
# начался), задача должна быть видна как "в работе"
STATS_INPROGRESS_ONLY="$TMP/stats-inprogress-only"
mkdir -p "$STATS_INPROGRESS_ONLY"
cat > "$STATS_INPROGRESS_ONLY/issue-30.jsonl" <<'EOF'
{"event":"start","issue":"30","timestamp":"2026-08-05T09:00:00Z"}
{"event":"review","issue":"30","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-05T09:30:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_INPROGRESS_ONLY" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: каталог только с незавершённой задачей — exit 0" 0 $?
assert_not_contains "AC-3: adk-stats: незавершённая-только задача не спутана с пустым журналом" "$stats_out" "Журнал пуст"
assert_contains "AC-3: adk-stats: незавершённая задача показана как «в работе»" "$stats_out" "В работе"
assert_contains "AC-3: adk-stats: количество задач в работе отражено в выводе" "$stats_out" "В работе (без итога): 1"

# строка, оборванная посреди multibyte UTF-8 (типичный исход обрыва процесса
# при записи в журнал) — не должна ронять скрипт UnicodeDecodeError-ом;
# остальные валидные строки того же файла обязаны отработать как обычно
STATS_BADUTF8="$TMP/stats-bad-utf8"
mkdir -p "$STATS_BADUTF8"
{
  printf '{"event":"start","issue":"20","timestamp":"2026-08-05T09:00:00Z"}\n'
  printf '\xE2\x82{"event":"broken"}\n'
  printf '{"event":"outcome","issue":"20","result":"merged","timestamp":"2026-08-05T09:05:00Z"}\n'
} > "$STATS_BADUTF8/issue-20.jsonl"
stats_out=$(ADK_LOGS_DIR="$STATS_BADUTF8" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: оборванная multibyte UTF-8 последовательность не роняет скрипт" 0 $?
assert_contains "AC-3: adk-stats: остальные валидные строки файла с оборванным UTF-8 отработали как обычно" "$stats_out" "Всего задач: 1"

# круги ревью считаются как max(round), а не число строк event=review —
# append-only журнал не гарантирует отсутствия повторной записи одного и
# того же круга (ретрай adk-log.sh); дубль не должен завышать метрику
STATS_DUPROUND="$TMP/stats-dupround"
mkdir -p "$STATS_DUPROUND"
cat > "$STATS_DUPROUND/issue-40.jsonl" <<'EOF'
{"event":"start","issue":"40","timestamp":"2026-08-05T09:00:00Z"}
{"event":"review","issue":"40","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-05T09:10:00Z"}
{"event":"review","issue":"40","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-05T09:11:00Z"}
{"event":"review","issue":"40","round":"2","verdict":"APPROVE","timestamp":"2026-08-05T09:20:00Z"}
{"event":"outcome","issue":"40","result":"merged","timestamp":"2026-08-05T09:25:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_DUPROUND" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: дублирующая запись круга ревью — exit 0" 0 $?
assert_contains "AC-3: adk-stats: круги считаются как max(round)=2, не как число строк event=review=3 — дубль записи круга не завышает метрику" "$stats_out" "Средние круги ревью: 2.0"

# reason нестрокового типа (вложенный объект вместо текста) не должен
# ронять агрегацию TypeError-ом в collections.Counter (объект нехэшируем)
STATS_BADREASON="$TMP/stats-badreason"
mkdir -p "$STATS_BADREASON"
cat > "$STATS_BADREASON/issue-50.jsonl" <<'EOF'
{"event":"start","issue":"50","timestamp":"2026-08-05T09:00:00Z"}
{"event":"outcome","issue":"50","result":"stuck","reason":{"nested":"object"},"timestamp":"2026-08-05T09:05:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_BADREASON" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: reason нестрокового типа не роняет скрипт" 0 $?
assert_contains "AC-3: adk-stats: задача с нестроковым reason всё равно посчитана" "$stats_out" "Всего задач: 1"

# issue #28 K9: issue-*.jsonl физически есть, но целиком из битых строк
# (valid_any=False для каждой) — сообщение должно честно называть это
# "файлы есть, валидных записей нет", а не путать с реально пустым журналом
STATS_ALLBROKEN="$TMP/stats-allbroken"
mkdir -p "$STATS_ALLBROKEN"
cat > "$STATS_ALLBROKEN/issue-99.jsonl" <<'EOF'
это не json, битая строка
42
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_ALLBROKEN" "$HOOKS/adk-stats.sh" 2>/dev/null)
assert_exit "AC-3: adk-stats: файл целиком из битых строк — exit 0" 0 $?
assert_contains "AC-3: adk-stats: файл есть, но валидных записей нет — отдельное сообщение (issue #28 K9)" "$stats_out" "валидных записей нет"
assert_not_contains "AC-3: adk-stats: файл целиком из битых строк не выдаётся за реально пустой журнал (issue #28 K9)" "$stats_out" "Журнал пуст"

# issue #28 K9: event=review без поля round (фолбэк round_count = число
# строк event=review, а не max(round)) — раньше не был покрыт фикстурой
STATS_NOROUND="$TMP/stats-noround"
mkdir -p "$STATS_NOROUND"
cat > "$STATS_NOROUND/issue-60.jsonl" <<'EOF'
{"event":"start","issue":"60","timestamp":"2026-08-05T09:00:00Z"}
{"event":"review","issue":"60","verdict":"REQUEST_CHANGES","timestamp":"2026-08-05T09:10:00Z"}
{"event":"review","issue":"60","verdict":"APPROVE","timestamp":"2026-08-05T09:20:00Z"}
{"event":"outcome","issue":"60","result":"merged","timestamp":"2026-08-05T09:25:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_NOROUND" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: event=review без поля round — exit 0" 0 $?
assert_contains "AC-3: adk-stats: без поля round круги считаются по числу строк event=review=2 (issue #28 K9)" "$stats_out" "Средние круги ревью: 2.0"

# 2-3 задачи + прогон autopilot + одно застревание, с битой строкой в одном файле
STATS_DIR="$TMP/stats-logs"
mkdir -p "$STATS_DIR"

cat > "$STATS_DIR/issue-10.jsonl" <<'EOF'
{"event":"start","issue":"10","timestamp":"2026-07-27T09:00:00Z"}
{"event":"review","issue":"10","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-07-27T09:30:00Z"}
{"event":"review","issue":"10","round":"2","verdict":"APPROVE","timestamp":"2026-07-27T10:00:00Z"}
{"event":"outcome","issue":"10","result":"merged","timestamp":"2026-07-27T10:05:00Z"}
EOF

cat > "$STATS_DIR/issue-11.jsonl" <<'EOF'
{"event":"start","issue":"11","timestamp":"2026-07-28T09:00:00Z"}
{"event":"review","issue":"11","round":"1","verdict":"APPROVE","timestamp":"2026-07-28T09:30:00Z"}
{"event":"outcome","issue":"11","result":"merged","timestamp":"2026-07-28T09:35:00Z"}
EOF

# строки 4 и 5 битые: строка 4 — не JSON вовсе, строка 5 — валидный JSON, но
# не объект (число, а не {..}); обе должны быть пропущены с предупреждением,
# не ронять скрипт и не учитываться как круг ревью
cat > "$STATS_DIR/issue-12.jsonl" <<'EOF'
{"event":"start","issue":"12","timestamp":"2026-08-03T09:00:00Z"}
{"event":"review","issue":"12","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-03T09:30:00Z"}
{"event":"review","issue":"12","round":"2","verdict":"REQUEST_CHANGES","timestamp":"2026-08-03T10:00:00Z"}
это не json, битая строка
42
{"event":"outcome","issue":"12","result":"stuck","reason":"ревьюер второй круг подряд REQUEST_CHANGES","timestamp":"2026-08-03T10:05:00Z"}
EOF

# задача без итога (только start, ревью в процессе) — "в работе", не должна
# искажать среднее число кругов, долю застреваний и "всего задач" по
# завершённым задачам
cat > "$STATS_DIR/issue-13.jsonl" <<'EOF'
{"event":"start","issue":"13","timestamp":"2026-08-04T09:00:00Z"}
{"event":"review","issue":"13","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-04T09:30:00Z"}
EOF

cat > "$STATS_DIR/autopilot-2026-08-03.jsonl" <<'EOF'
{"event":"run_start","timestamp":"2026-08-03T08:00:00Z"}
{"event":"task","issue":"10","result":"merged","timestamp":"2026-08-03T08:10:00Z"}
{"event":"task","issue":"11","result":"merged","timestamp":"2026-08-03T08:20:00Z"}
{"event":"task","issue":"12","result":"stuck","timestamp":"2026-08-03T08:30:00Z"}
{"event":"run_end","done":"2","stuck":"1","skipped":"0","timestamp":"2026-08-03T08:31:00Z"}
EOF

stats_errfile="$TMP/stats-err.$$"
stats_out=$(ADK_LOGS_DIR="$STATS_DIR" "$HOOKS/adk-stats.sh" 2>"$stats_errfile")
stats_st=$?
stats_err=$(cat "$stats_errfile" 2>/dev/null); rm -f "$stats_errfile"
assert_exit "AC-3: adk-stats: битая строка в одном из файлов не роняет скрипт" 0 "$stats_st"

# два разных вида битой строки в issue-12.jsonl — не JSON и JSON-не-объект —
# оба должны попасть в предупреждения (два разных lineno)
warn_lines=$(printf '%s' "$stats_err" | grep -ci "issue-12")
[ "$warn_lines" -ge 2 ]
assert_exit "AC-3: adk-stats: оба вида битой строки (не-JSON и JSON-не-объект) порождают предупреждения" 0 $?

assert_contains "AC-3: adk-stats: всего задач — 3 завершённые (issue-13 без итога и autopilot-файл не задваивают)" "$stats_out" "Всего задач: 3"

assert_contains "AC-3: adk-stats: незавершённая задача (issue-13, без outcome) показана отдельно, не искажает агрегаты" "$stats_out" "В работе (без итога, в агрегаты ниже не входят): 1"

assert_contains "AC-3: adk-stats: средние круги ревью посчитаны верно ((2+1+2)/3 = 1.7, issue-13 не в счёте)" "$stats_out" "Средние круги ревью: 1\.7"

assert_contains "AC-3: adk-stats: доля застреваний — 33%" "$stats_out" "33%"
assert_contains "AC-3: adk-stats: доля застреваний — 1/3 задач" "$stats_out" "1/3"

assert_contains "AC-3: adk-stats: причина застревания названа в выводе" "$stats_out" "ревьюер второй круг подряд REQUEST_CHANGES"

assert_contains "AC-3: adk-stats: динамика по неделям показывает неделю 2026-W31" "$stats_out" "2026-W31"
assert_contains "AC-3: adk-stats: динамика по неделям показывает неделю 2026-W32" "$stats_out" "2026-W32"

# команда /stats существует и обращается к скрипту агрегации, интерпретирует
# пустой журнал явно, не выдумывая цифры
[ -f "$KIT/commands/stats.md" ]
assert_exit "AC-3: commands/stats.md существует" 0 $?
check_ac_doc AC-3 "commands/stats.md вызывает hooks/scripts/adk-stats.sh" \
  "$KIT/commands/stats.md" "hooks/scripts/adk-stats.sh"
check_ac_doc AC-3 "commands/stats.md: пустой журнал — не выдумывать цифры" \
  "$KIT/commands/stats.md" "не выдумывай"

# ── Тип задачи в журнале и разрез /stats по типам (AC-7 SPEC-002) ────────────
# Схема: поле type в событиях журнала — расширение ADR-001 (issue #51).
# Смесь типов: issue-70 (type=task), issue-71 (без поля type — старая запись,
# считается task), issue-72 (type=bug), issue-73 (type=bug только в event=start,
# outcome без поля — тип должен подхватиться из start).
STATS_TYPES="$TMP/stats-types"
mkdir -p "$STATS_TYPES"
cat > "$STATS_TYPES/issue-70.jsonl" <<'EOF'
{"event":"start","issue":"70","type":"task","timestamp":"2026-08-05T09:00:00Z"}
{"event":"review","issue":"70","round":"1","verdict":"APPROVE","timestamp":"2026-08-05T09:30:00Z"}
{"event":"outcome","issue":"70","type":"task","result":"merged","timestamp":"2026-08-05T09:35:00Z"}
EOF
cat > "$STATS_TYPES/issue-71.jsonl" <<'EOF'
{"event":"start","issue":"71","timestamp":"2026-08-05T10:00:00Z"}
{"event":"review","issue":"71","round":"1","verdict":"APPROVE","timestamp":"2026-08-05T10:30:00Z"}
{"event":"outcome","issue":"71","result":"merged","timestamp":"2026-08-05T10:35:00Z"}
EOF
cat > "$STATS_TYPES/issue-72.jsonl" <<'EOF'
{"event":"start","issue":"72","type":"bug","timestamp":"2026-08-06T09:00:00Z"}
{"event":"review","issue":"72","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-06T09:30:00Z"}
{"event":"review","issue":"72","round":"2","verdict":"APPROVE","timestamp":"2026-08-06T10:00:00Z"}
{"event":"outcome","issue":"72","type":"bug","result":"merged","timestamp":"2026-08-06T10:05:00Z"}
EOF
cat > "$STATS_TYPES/issue-73.jsonl" <<'EOF'
{"event":"start","issue":"73","type":"bug","timestamp":"2026-08-07T09:00:00Z"}
{"event":"review","issue":"73","round":"1","verdict":"REQUEST_CHANGES","timestamp":"2026-08-07T09:30:00Z"}
{"event":"review","issue":"73","round":"2","verdict":"REQUEST_CHANGES","timestamp":"2026-08-07T10:00:00Z"}
{"event":"review","issue":"73","round":"3","verdict":"REQUEST_CHANGES","timestamp":"2026-08-07T10:30:00Z"}
{"event":"outcome","issue":"73","result":"stuck","reason":"ревьюер не согласен","timestamp":"2026-08-07T10:35:00Z"}
EOF
stats_out=$(ADK_LOGS_DIR="$STATS_TYPES" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-7: adk-stats: журнал со смесью типов — exit 0" 0 $?
assert_contains "AC-7: adk-stats: разрез по типам присутствует отдельной секцией" \
  "$stats_out" "Разрез по типам"
assert_contains "AC-7: adk-stats: задачи — количество и средние круги ревью (issue-71 без поля type посчитан как task)" \
  "$stats_out" "task: задач 2, среднее кругов 1.0"
assert_contains "AC-7: adk-stats: баги — количество и средние круги ревью ((2+3)/2, тип issue-73 подхвачен из event=start)" \
  "$stats_out" "bug: задач 2, среднее кругов 2.5"
assert_contains "AC-7: adk-stats: общие агрегаты не изменились от появления типов" \
  "$stats_out" "Всего задач: 4"

# писатели журнала передают тип задачи в adk-log.sh
check_ac_doc AC-7 "work.md логирует тип задачи в event=start" \
  "$KIT/commands/work.md" "event=start issue=<N> type=<тип>"
check_ac_doc AC-7 "work.md логирует тип задачи в event=outcome" \
  "$KIT/commands/work.md" "event=outcome type=<тип>"
check_ac_doc AC-7 "autopilot.md логирует тип задачи в event=task" \
  "$KIT/commands/autopilot.md" "event=task issue=<N> type=<тип>"

# схема поля зафиксирована как расширение ADR-001
check_ac_doc AC-7 "ADR-001 описывает поле type" \
  "$KIT/docs/adr/001-journal-event-schema.md" "type=<тип>"
check_ac_doc AC-7 "ADR-001: записи без поля type считаются task" \
  "$KIT/docs/adr/001-journal-event-schema.md" "считается \`task\`"

# читатели: /stats передаёт разрез как есть, /consolidate считает
# «Сбежал от» по label баг-типа, а не поиском по всем issues
check_ac_doc AC-7 "stats.md упоминает разрез по типам" \
  "$KIT/commands/stats.md" "разрез по типам"
check_ac_doc AC-7 "consolidate.md читает label баг-типа из конфига" \
  "$KIT/commands/consolidate.md" "types.bug.label type:bug"
check_ac_doc AC-7 "consolidate.md собирает баг-issues по label, а не поиском по тексту" \
  "$KIT/commands/consolidate.md" "--label"
check_ac_doc AC-7 "consolidate.md: баг-issues без label типа (до SPEC-002) не теряются молча" \
  "$KIT/commands/consolidate.md" "Переходное состояние: баг-issues"

# ── Сверочный поиск «Сбежал от» использует те же параметры, что основная
# выборка по label (issue #89): без --limit gh отдаёт первые 30 записей по
# всему репозиторию, сверка расходится с основной выборкой (--limit 200 +
# фильтр по вехе). Первая проверка — репро: старая форма без --limit сразу
# за --search не матчится.
check_ac_doc "issue #89" "consolidate.md: сверочный поиск «Сбежал от» содержит --limit 200" \
  "$KIT/commands/consolidate.md" '--search "Сбежал от" --limit 200'
check_ac_doc "issue #89" "consolidate.md: сверочный поиск «Сбежал от» фильтруется по вехе, как основная выборка" \
  "$KIT/commands/consolidate.md" 'та же фильтрация по `$ARGUMENTS`, что и в основной выборке'

# ── SPEC-002 AC-8: актуализация отставшей ветки перед ready/merge ────────────
# /work (перед переводом PR в ready) и /autopilot (перед merge ready-PR)
# проверяют состояние PR относительно main; неактуальная ветка
# актуализируется способом из conventions.branchUpdate, после чего гейты
# перегоняются обязательно — merge/ready без перегона запрещён инструкцией.
# Рецепт канонизирован в шаге 6 work.md (issue #75): якоря самого рецепта
# проверяются на work.md, у /autopilot и /review — только их отличия
# (checkout, refspec, ветки отказа, возврат дерева) плюс ссылка на канон.
assert_contains "AC-8: work.md перед ready проверяет BEHIND" "$work_step6" 'BEHIND'
assert_contains "AC-8: work.md перед ready проверяет CONFLICTING" "$work_step6" 'CONFLICTING'
assert_contains "AC-8: autopilot.md перед merge проверяет BEHIND" "$autopilot_step3" 'BEHIND'
assert_contains "AC-8: autopilot.md перед merge проверяет CONFLICTING" "$autopilot_step3" 'CONFLICTING'
# Якоря механики (круг 2 ревью PR #67: фиксы без якорей переживают откат):
# отставание — фактом из git, не mergeStateStatus (обоснование — в каноне,
# work.md шаг 6); в автопилоте — явный checkout и refspec; fetch без
# «origin main» (текст в одной команде с force-push ложно триггерит гейт
# bash-guard); отказы актуализации определены.
assert_contains "AC-8: work.md — отставание фактом из git (rev-list), не mergeStateStatus" "$work_step6" 'git rev-list --count HEAD\.\.origin/main'
assert_contains "AC-8: autopilot.md — отставание фактом из git (rev-list), не mergeStateStatus" "$autopilot_step3" 'git rev-list --count origin/<ветка PR>\.\.origin/main'
assert_contains "AC-8: autopilot.md — актуализация только в явном checkout ветки PR" "$autopilot_step3" 'gh pr checkout <PR>'
assert_contains "AC-8: autopilot.md — push после rebase с обязательным refspec" "$autopilot_step3" 'force-with-lease origin <ветка PR>'
assert_not_contains "AC-8: work.md — fetch без «origin main» (ложный триггер force-push-гейта)" "$work_step6" 'git fetch origin main'
assert_not_contains "AC-8: autopilot.md — fetch без «origin main» (тот же ложный триггер)" "$autopilot_step3" 'git fetch origin main'
# Якоря семантики, не только команд: остановка/застревание, а не «разберись сам»
assert_contains "AC-8: work.md — конфликт при самой актуализации прерывается (--abort)" "$work_step6" 'git rebase --abort'
assert_contains "AC-8: work.md — конфликт при актуализации — остановка и человек, не самодеятельность" "$work_step6" 'остановись и позови пользователя, как при'
assert_contains "AC-8: autopilot.md — конфликт при актуализации прерывается (--abort)" "$autopilot_step3" 'git rebase --abort'
assert_contains "AC-8: autopilot.md — конфликт при актуализации — застревание с причиной" "$autopilot_step3" 'reason="конфликт при актуализации"'
assert_contains "AC-8: autopilot.md — красные гейты после актуализации — застревание с причиной" "$autopilot_step3" 'reason="гейты красные после актуализации"'
# issue #80: исход «красные гейты» в каноне work.md назван явно и
# симметрично autopilot.md (а не выводится косвенно из условия «ready
# только при зелёных»); порядок «гейты → push» — старый порядок «push
# сразу после rebase/merge, гейты перегоняются потом» публиковал бы
# переписанную голову PR раньше, чем стало известно, что она красная.
assert_contains "AC-8: work.md — красные гейты после актуализации ведут к остановке, симметрично autopilot.md (issue #80)" "$work_step6" 'тот же исход, что и конфликт: остановись и позови пользователя'
assert_contains "AC-8: work.md — порядок «гейты → push»: гейты перегоняются локально до публикации (issue #80)" "$work_step6" 'Порядок «гейты → push»'
assert_not_contains "AC-8: work.md — старый порядок «push сразу после rebase, гейты потом» не возвращается (issue #80)" "$work_step6" 'rebase origin/main`), затем `git push'
assert_not_contains "AC-8: work.md — старый порядок не возвращается и для merge-ветки (issue #80, круг 1)" "$work_step6" 'merge origin/main`), затем `git push origin'
assert_contains "AC-8: work.md читает conventions.branchUpdate с дефолтом rebase" "$work_step6" 'conventions\.branchUpdate rebase'
check_ac_doc AC-8 "work.md: при branchUpdate=merge актуализация через git merge, не rebase" \
  "$KIT/commands/work.md" "merge\` — влей main в ветку (\`git merge origin/main\`)"
# Канон живёт в одном месте: work.md называет себя каноном, autopilot.md и
# review.md ссылаются на него, а не переписывают чтение конфига заново
check_ac_doc AC-8 "work.md: шаг 6 объявлен каноническим рецептом актуализации" \
  "$KIT/commands/work.md" "Рецепт актуализации ниже — канонический"
assert_contains "AC-8: autopilot.md ссылается на канонический рецепт шага 6 /work" "$autopilot_step3" 'рецепт — шаг 6 `/work`'
# AC-8 называет /autopilot поимённо: способ актуализации остаётся привязан к
# conventions.branchUpdate и в нём — якорь на текст, чтение конфига — в каноне
assert_contains "AC-8: autopilot.md актуализирует способом из conventions.branchUpdate" "$autopilot_step3" 'conventions\.branchUpdate'
assert_not_contains "K19 (issue #99): анти-дубль — autopilot.md не дублирует канон (чтение branchUpdate из конфига)" "$autopilot_step3" 'conventions\.branchUpdate rebase rebase,merge'
check_ac_doc AC-8 "work.md: после актуализации гейты перегоняются обязательно, ready без перегона запрещён" \
  "$KIT/commands/work.md" "переводить PR в ready без перегона гейтов после актуализации запрещено"
check_ac_doc AC-8 "autopilot.md: после актуализации гейты перегоняются обязательно, merge без перегона запрещён" \
  "$KIT/commands/autopilot.md" "merge без перегона гейтов после актуализации запрещён"
assert_contains "AC-8: work.md — конфликт при актуализации ведёт к остановке (не «разреши сам»)" "$work_step6" 'конфликт с main, остановись и позови пользователя'
assert_contains "AC-8: autopilot.md — конфликт с main (CONFLICTING) ведёт к needs-human" "$autopilot_step3" 'конфликт с main требует человека.*needs-human'
# /review — второй путь в ready: та же проверка актуальности (issue #68,
# fast-follow из вердикта PR #67)
review_ready=$(md_section "$KIT/commands/review.md" '^5\. \*\*' '^6\. \*\*')
assert_contains "AC-8: review.md ссылается на канонический рецепт шага 6 /work" "$review_ready" 'каноническому рецепту шага 6'
assert_contains "AC-8: review.md перед ready определяет отставание фактом из git" "$review_ready" 'git rev-list --count HEAD\.\.origin/main'
assert_contains "AC-8: review.md — актуализация по conventions.branchUpdate" "$review_ready" 'conventions\.branchUpdate'
assert_contains "AC-8: review.md — ready без перегона гейтов после актуализации запрещён" "$review_ready" 'переводить в ready без него запрещено'
assert_contains "AC-8: review.md — конфликт ведёт к остановке, решает человек" "$review_ready" 'остановись, его разрешает человек'
assert_contains "AC-8: review.md — дерево возвращается на исходный ref в любом исходе (issue #80, круг 4: ref вместо ветки — устойчиво к detached HEAD)" "$review_ready" 'верни рабочее дерево на ref, запомненный в шаге 1'
# Круг 1 ревью PR #112: возврат теперь один раз в конце всей команды и
# явно покрывает REQUEST_CHANGES, а не только APPROVE-исходы актуализации
assert_contains "AC-8: review.md — возврат дерева покрывает REQUEST_CHANGES, а не только APPROVE-исходы (issue #80, круг 1)" "$review_ready" 'в любом исходе всей команды (ready, REQUEST_CHANGES'
# Круг 2 ревью PR #112: `git checkout -` полагается на `@{-1}` — тот
# хранит только последний переход между ветками, а дерево между шагом 1
# и возвратом может переключаться произвольное число раз (checkout
# шага 3, дальнейшие действия при доработке/ревью). Возврат — по
# значению ref, захваченному в шаге 1 (круг 4: ref, а не имя ветки — на
# detached HEAD у имени пустой вывод; круг 4 также снял более раннее
# обоснование через «rebase переписывает @{-1}» — эмпирически неверно,
# rebase его не трогает).
step1_review=$(md_section "$KIT/commands/review.md" '^1\. \*\*' '^2\. \*\*')
assert_contains "AC-8: review.md шаг 1 — запоминает исходный ref до первого checkout, устойчиво к detached HEAD (issue #80, круг 4)" "$step1_review" 'git symbolic-ref --short -q HEAD'
assert_contains "AC-8: review.md — возврат дерева по ref, захваченному в шаге 1, а не через git checkout - (issue #80, круг 4)" "$review_ready" 'git checkout <исходный ref>'
# issue #80: шаг 3 (доработка) коммитит правки в ветку PR — без явного
# checkout правки могут уйти в чужую ветку. Круг 2: checkout в шаге 3
# безусловен (даже если чинить нечего) — шаг 4 (ревью) должен видеть
# ветку PR независимо от того, было ли что фиксить.
review_step3=$(md_section "$KIT/commands/review.md" '^3\. \*\*' '^4\. \*\*')
assert_contains "AC-8: review.md шаг 3 — явный checkout ветки PR перед доработкой (issue #80)" "$review_step3" 'gh pr checkout <PR>'
assert_contains "AC-8: review.md шаг 3 — checkout безусловен, даже если чинить нечего (issue #80, круг 2)" "$review_step3" 'безусловно, даже если чинить нечего'
# Круг 1 ревью PR #112: возврат дерева в конце шага 3 (до правки) уводил
# дерево с ветки PR раньше шага 4 (ревью), который должен видеть именно
# её — единый возврат перенесён в конец шага 5, после решения по вердикту.
# Круг 3: старый якорь ('git checkout -') не пинил инвариант — мутация,
# вернувшая преждевременный возврат в НОВОМ словаре («verni... на
# исходный ref»), проходила незамеченной. Якорь теперь позитивный (шаг 3
# явно говорит не возвращать) и по обоим словам, которыми возврат мог бы
# быть выражен.
assert_contains "AC-8: review.md шаг 3 — явно откладывает возврат до шага 5 (issue #80, круг 3)" "$review_step3" 'Дерево пока не возвращай'
assert_not_contains "AC-8: review.md шаг 3 не возвращает дерево преждевременно — шаг 4 (ревью) должен идти по ветке PR (issue #80, круг 1/3)" "$review_step3" 'исходный ref'
assert_not_contains "AC-8: review.md шаг 3 не возвращает дерево преждевременно (старая формулировка «исходная ветка») (issue #80, круг 1/3)" "$review_step3" 'исходную ветку'
check_ac_doc AC-8 "002-process-config.md: AC-8 называет исполнителем актуализации и /review, не только /work и /autopilot (issue #80)" \
  "$KIT/docs/specs/002-process-config.md" "\`/work\`, \`/autopilot\` и \`/review\`"

# ── /work: события журнала (AC-1) ────────────────────────────────────────────
WORKMD="$KIT/commands/work.md"
step1=$(md_section "$WORKMD" '^1\. \*\*' '^2\. \*\*')
step7=$(md_section "$WORKMD" '^7\. \*\*' '$')

assert_contains "AC-1: work.md шаг 1 логирует event=start" "$step1" 'adk-log\.sh.*event=start'

assert_contains "AC-1: work.md шаг 6 логирует event=review после каждого вердикта" "$work_step6" 'adk-log\.sh.*event=review'

assert_contains "AC-1: work.md шаг 7 логирует event=outcome (схема ADR-001)" "$step7" 'adk-log\.sh.*event=outcome'

assert_contains "AC-1: work.md шаг 7 пишет result=merged|stuck (не outcome=ready, issue #21)" "$step7" 'result=<merged|stuck>'

assert_contains "AC-1: work.md шаг 7 считает размер диффа git diff main... --shortstat" "$step7" 'git diff main\.\.\. --shortstat'

assert_contains "AC-1: work.md шаг 7 пишет diff= (не diffstat=, issue #21)" "$step7" 'diff='

for step_name in step1 work_step6 step7; do
  step_text=$(eval "printf '%s' \"\$$step_name\"")
  assert_contains "AC-1: work.md $step_name — запись в журнал не блокирует задачу (|| true)" "$step_text" 'adk-log\.sh.*|| true'
done

assert_contains "AC-1: work.md шаг 7 — reason закавычен (причина может содержать пробелы)" "$step7" 'reason="'

# ── issue #79 (SPEC-001 AC-1): /review тоже логирует круги ───────────────────
# SPEC-001 обещает запись в журнале для каждой завершённой через /work,
# /review или /autopilot задачи, но до этой правки review.md не вызывал
# adk-log.sh ни разу — круги, проведённые через /review, не попадали в
# issue-<N>.jsonl и adk-stats.sh занижал среднее число кругов у самых
# проблемных задач (три и более кругов обычно идут через /review).
assert_contains "issue #79: review.md шаг 5 логирует event=review после каждого вердикта" "$review_ready" 'adk-log\.sh.*event=review'
# Круг 1 ревью PR #116: якорь без границы справа ('.*|| true' — жадный,
# дотягивается до '|| true' СЛЕДУЮЩЕГО вызова adk-log.sh, event=outcome)
# давал ложный PASS даже если сам вызов event=review остался без `|| true`.
# Якорь теперь — литеральная смежность round=.../verdict=.../|| true в
# одном вызове, не растягивается на чужой || true.
assert_contains "issue #79: review.md шаг 5 — запись круга не блокирует задачу (|| true) прямо у своего вызова, не у чужого" "$review_ready" 'event=review round=<номер круга> verdict=<APPROVE|REQUEST_CHANGES> || true'
# Круг 1 ревью PR #116: старый якорь пинил только фразу "с продолжением
# нумерации кругов задачи", а не сам рецепт — мутация, заменившая рецепт
# на "(номер круга — 1)" при сохранении фразы, проходила тестом
# незамеченной. Якоря теперь — конкретные токены рецепта (max(round)+1
# из журнала, не отдельный счётчик с 1).
assert_contains "issue #79: review.md шаг 5 продолжает нумерацию кругов задачи, а не начинает с 1" "$review_ready" 'с продолжением нумерации кругов задачи'
assert_contains "issue #79: review.md шаг 5 берёт круг как наибольший round среди строк event=review журнала (не отдельный счётчик)" "$review_ready" 'наибольший `round` среди его строк `event=review`'
assert_contains "issue #79: review.md шаг 5 — без предыдущих записей круг 1, иначе max+1" "$review_ready" 'это круг 1, иначе `<max+1>`'
assert_contains "issue #79: review.md шаг 5 при переводе в ready обновляет итог result=merged" "$review_ready" 'adk-log\.sh.*event=outcome result=merged'
assert_contains "issue #79: review.md шаг 5 — итог result=merged документирован как сокращённая форма (не выдаёт себя за полный шаг 7 /work)" "$review_ready" 'сокращённая форма'

# Круг 1 ревью PR #116 (блокер): review.md умел искать PR по issue
# ($ARGUMENTS/Closes #N/имя ветки), но не определял <N> в обратную
# сторону (PR → issue) для собственного журналирования в шаге 5 — при
# вызове /review по номеру PR без Closes #N агент рисковал подставить
# в adk-log.sh номер PR вместо issue, заведя в журнале фантомную задачу.
assert_contains "issue #79: review.md шаг 1 определяет <N> по Closes #N в теле PR или по имени ветки issue-<N>-" "$step1_review" 'номер после `Closes #` в теле PR либо после'
assert_contains "issue #79: review.md шаг 1 — <N> не определён явно останавливает журналирование, а не молчаливо подставляет PR" "$step1_review" '`<N>` не определён'
assert_contains "issue #79: review.md шаг 5 не логирует круг без определённого <N>" "$review_ready" '`<N>` не определён — круг не логируется'

# Документация журнала (ADR-001) и шапка adk-stats.sh не должны отставать
# от нового писателя — иначе схема события «сокращённый outcome» и факт
# «/review — третий писатель» существуют только в коде, не как контракт.
check_ac_doc "issue #79" "ADR-001 документирует /review как третьего писателя журнала (issue-<N>.jsonl)" \
  "$KIT/docs/adr/001-journal-event-schema.md" "третий писатель"
check_ac_doc "issue #79" "ADR-001 документирует сокращённую форму outcome, которую пишет /review" \
  "$KIT/docs/adr/001-journal-event-schema.md" "сокращённая форма итога"
check_ac_doc "issue #79" "adk-stats.sh шапка называет /review среди писателей схемы событий" \
  "$KIT/hooks/scripts/adk-stats.sh" "/work, /review и /autopilot"

# ── SPEC-002 AC-2: формулировки отчётов соответствуют политике merge ─────────
# Третий (мягкий) слой enforcement: при политиках с обязательным человеком
# отчёт не обещает merge, а формулируется как «PR готов к ревью коллеги».
assert_contains "AC-2: work.md шаг 7 сверяет формулировку отчёта с policies.merge" "$step7" 'policies\.merge'
assert_contains "AC-2: work.md шаг 7 — при human-политиках отчёт «PR готов к ревью коллеги», не «смержено»" "$step7" 'готов к ревью коллеги'
autopilot_text=$(tr '\n' ' ' < "$KIT/commands/autopilot.md" | tr -s ' ')
assert_contains "AC-2: autopilot.md сверяет формулировку сводки с policies.merge" "$autopilot_text" 'policies\.merge'
assert_contains "AC-2: autopilot.md — заблокированные политикой ready-PR идут в сводку как «ждут человека», не «смержено»" "$autopilot_text" 'ждут человека'
assert_contains "AC-2: autopilot.md шаг 3 — при human-политиках ready-PR не мержится (исключение названо в самом шаге)" "$autopilot_step3" 'policies\.merge'

# Смоук: последовательность вызовов adk-log.sh, которую описывает work.md
# (start → review → outcome, схема ADR-001), даёт журнал с тремя валидными
# записями, и adk-stats.sh на этом журнале агрегирует задачу как завершённую
# (issue #21: раньше event=finish/outcome= не совпадал с тем, что читает
# adk-stats.sh, и реально завершённая задача показывалась как "в работе").
WORKP="$TMP/workproj"
mkdir -p "$WORKP"

CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=start issue=42 >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=review round=1 verdict=APPROVE >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=outcome result=merged duration=42s diff=" 1 file changed, 3 insertions(+)" >/dev/null 2>&1

work_lines=$(count_lines "$WORKP/.adk/logs/issue-42.jsonl" 2>/dev/null)
assert_exit "AC-1: work.md-смоук: start → review → outcome дают три записи в issue-42.jsonl" 3 "${work_lines:-0}"

work_spec=$(printf '%s\n%s\n%s' \
  'event=start|issue=42' \
  'event=review|round=1|verdict=APPROVE' \
  'event=outcome|result=merged|duration?|diff?')
work_valid=$(jsonl_check "$WORKP/.adk/logs/issue-42.jsonl" 3 "$work_spec")
assert_exit "AC-1: work.md-смоук: записи содержат issue/круг/вердикт/итог/длительность" 1 "$work_valid"

work_stats_out=$(ADK_LOGS_DIR="$WORKP/.adk/logs" "$HOOKS/adk-stats.sh" 2>&1)
assert_contains "AC-1: work.md-смоук: adk-stats.sh на журнале /work агрегирует задачу как завершённую, не 'в работе' (issue #21)" "$work_stats_out" "Всего задач: 1"
assert_not_contains "AC-1: work.md-смоук: adk-stats.sh не показывает завершённую задачу как 'в работе' (issue #21)" "$work_stats_out" "В работе"

# Смоук: result=stuck с reason, содержащим пробелы — ровно случай застревания,
# ради которого журнал и заводится (issue #4 агрегирует причины).
WORKP2="$TMP/workproj-stuck"
mkdir -p "$WORKP2"
CLAUDE_PROJECT_DIR="$WORKP2" "$HOOKS/adk-log.sh" issue-43 event=start issue=43 >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP2" "$HOOKS/adk-log.sh" issue-43 event=outcome result=stuck reason="тесты не проходят" duration=120s diff=" 3 files changed" >/dev/null 2>&1
stuck_lines=$(count_lines "$WORKP2/.adk/logs/issue-43.jsonl" 2>/dev/null)
assert_exit "AC-1: work.md-смоук: result=stuck с пробелами в reason не роняет запись" 2 "${stuck_lines:-0}"

stuck_reason=$(tail -n1 "$WORKP2/.adk/logs/issue-43.jsonl" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)
assert_contains "AC-1: work.md-смоук: причина застревания сохраняется целиком, с пробелами" "$stuck_reason" '^тесты не проходят$'

stuck_stats_out=$(ADK_LOGS_DIR="$WORKP2/.adk/logs" "$HOOKS/adk-stats.sh" 2>&1)
assert_contains "AC-1: work.md-смоук: adk-stats.sh на журнале с result=stuck считает застревание и называет причину (issue #21)" "$stuck_stats_out" "тесты не проходят"

# ── /autopilot: события журнала (AC-2) ───────────────────────────────────────
AUTOMD="$KIT/commands/autopilot.md"
cycle_preamble=$(md_section "$AUTOMD" '^## Цикл' '^1\. \*\*')
finish_section=$(md_section "$AUTOMD" '^## Завершение' '$')

assert_contains "AC-2: autopilot.md логирует event=run_start перед циклом (issue #21: раньше не логировался вовсе)" "$cycle_preamble" 'adk-log\.sh.*event=run_start'

assert_contains "AC-2: autopilot.md шаг 3 логирует event=task на каждую разобранную задачу" "$autopilot_step3" 'adk-log\.sh.*event=task'

assert_contains "AC-2: autopilot.md «Завершение» логирует event=run_end (не run_finish, issue #21)" "$finish_section" 'adk-log\.sh.*event=run_end'

for outcome_kind in 'result=merged' 'result=stuck' 'result=skipped'; do
  assert_contains "AC-2: autopilot.md шаг 3 покрывает исход «$outcome_kind»" "$autopilot_step3" "$outcome_kind"
done

for agg_field in done= stuck= skipped=; do
  assert_contains "AC-2: autopilot.md «Завершение» пишет агрегат «$agg_field»" "$finish_section" "$agg_field"
done

for section_name in cycle_preamble autopilot_step3 finish_section; do
  section_text=$(eval "printf '%s' \"\$$section_name\"")
  assert_contains "AC-2: autopilot.md $section_name — запись в журнал не блокирует прогон (|| true)" "$section_text" 'adk-log\.sh.*|| true'
done

assert_contains "AC-2: autopilot.md шаг 3 пишет в единицу autopilot-<дата>" "$autopilot_step3" 'autopilot-\$(date'

# Смоук: последовательность вызовов adk-log.sh, которую описывает autopilot.md
# (run_start → task=merged → task=stuck → task=skipped → run_end, схема
# ADR-001), даёт журнал одного прогона с записью на каждую задачу и итоговой
# записью (сделано/застряло/пропущено), в файле autopilot-<дата>.jsonl.
AUTOP="$TMP/autopproj"
mkdir -p "$AUTOP"
DATE_UNIT="autopilot-$(date +%Y-%m-%d)"

CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=run_start >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=10 result=merged >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=11 result=stuck reason="тесты падают" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=12 result=skipped >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=run_end done=1 stuck=1 skipped=1 >/dev/null 2>&1

auto_lines=$(count_lines "$AUTOP/.adk/logs/$DATE_UNIT.jsonl" 2>/dev/null)
assert_exit "AC-2: autopilot.md-смоук: run_start + три task-записи плюс итоговая run_end дают пять строк" 5 "${auto_lines:-0}"

auto_spec=$(printf '%s\n%s\n%s\n%s\n%s' \
  'event=run_start' \
  'event=task|issue=10|result=merged' \
  'event=task|issue=11|result=stuck|reason=тесты падают' \
  'event=task|issue=12|result=skipped' \
  'event=run_end|done=1|stuck=1|skipped=1')
auto_valid=$(jsonl_check "$AUTOP/.adk/logs/$DATE_UNIT.jsonl" 5 "$auto_spec")
assert_exit "AC-2: autopilot.md-смоук: записи содержат issue/исход задачи и агрегаты итога прогона (сделано/застряло/пропущено)" 1 "$auto_valid"

# ── /autopilot читает policies.autopilot (AC-3) ──────────────────────────────
# Команда — markdown-инструкция; проверяем, что она предписывает чтение
# конфига через adk-config.sh с дефолтами спеки (отсутствие конфига =
# сегодняшнее поведение: лимит 5, merge ready-PR) и все три ветки
# политики: отказ старта, «ждут человека» вместо merge, лимит из конфига.
policy_section=$(md_section "$AUTOMD" '^## Политика прогона' '^## Параметры')
params_section=$(md_section "$AUTOMD" '^## Параметры' '^## Цикл')

assert_contains "AC-3: autopilot.md читает policies.autopilot.enabled через adk-config.sh (дефолт true — без конфига автопилот работает)" \
  "$policy_section" 'adk-config\.sh policies\.autopilot\.enabled true'
assert_contains "AC-3: autopilot.md читает policies.autopilot.canMerge через adk-config.sh (дефолт true — без конфига мержит сам)" \
  "$policy_section" 'adk-config\.sh policies\.autopilot\.canMerge true'
assert_contains "AC-3: autopilot.md читает policies.autopilot.maxTasksPerRun через adk-config.sh (дефолт 5 — как сегодня)" \
  "$policy_section" 'adk-config\.sh policies\.autopilot\.maxTasksPerRun 5'

# политика читается до цикла — иначе «отказ без журнала» невыполним:
# run_start логируется в преамбуле «## Цикл»
policy_line=$(grep -n '^## Политика прогона' "$AUTOMD" | head -1 | cut -d: -f1)
cycle_line=$(grep -n '^## Цикл' "$AUTOMD" | head -1 | cut -d: -f1)
[ -n "$policy_line" ] && [ -n "$cycle_line" ] && [ "$policy_line" -lt "$cycle_line" ]
assert_exit "AC-3: autopilot.md читает политику до «## Цикл» (то есть до run_start)" 0 $?

# enabled=false — отказ старта с объяснением и без побочных эффектов
check_ac_doc AC-3 "autopilot.md: enabled=false — отказ старта" \
  "$AUTOMD" "откажись стартовать"
check_ac_doc AC-3 "autopilot.md: enabled=false — журнал прогона не начинается" \
  "$AUTOMD" "журнал прогона не начинай"
check_ac_doc AC-3 "autopilot.md: enabled=false — отказ объясняет причину (имя атрибута в сообщении)" \
  "$AUTOMD" "policies.autopilot.enabled=false"

# canMerge=false — ready-PR не мержатся, а собираются в список «ждут человека»
finish_ac3=$(md_section "$AUTOMD" '^## Завершение' '$')
assert_contains "AC-3: autopilot.md шаг 3 мержит только при canMerge=true" "$autopilot_step3" 'canMerge=true'
assert_contains "AC-3: autopilot.md шаг 3: canMerge=false — ready-PR не мержится, а попадает в «ждут человека»" "$autopilot_step3" 'canMerge=false.*ждут человека'
assert_contains "AC-3: autopilot.md шаг 3: ready-PR без merge логируется result=ready (ADR-003)" "$autopilot_step3" 'result=ready'
check_ac_doc AC-3 "autopilot.md: задача с ready-PR при canMerge=false не застряла — метка needs-human не ставится" \
  "$AUTOMD" "метку \`needs-human\` не ставь"
assert_contains "AC-3: autopilot.md «Завершение» — сводка содержит отдельный список «ждут человека»" "$finish_ac3" 'ждут человека'
assert_contains "AC-3: autopilot.md «Завершение» — run_end пишет агрегат ready= (сколько PR ждут человека)" "$finish_ac3" 'ready='

# maxTasksPerRun — дефолт лимита; аргумент команды переопределяет
assert_contains "AC-3: autopilot.md лимит прогона по умолчанию — maxTasksPerRun из конфига" "$params_section" 'maxTasksPerRun'
check_ac_doc AC-3 "autopilot.md: аргумент команды переопределяет лимит из конфига" \
  "$AUTOMD" "Аргумент команды переопределяет значение конфига"

# взаимодействие с policies.merge: хук блокирует merge — не обходить
check_ac_doc AC-3 "autopilot.md описывает блокировку merge политикой human-only" \
  "$AUTOMD" "human-only"
check_ac_doc AC-3 "autopilot.md описывает блокировку merge политикой human-review-required" \
  "$AUTOMD" "human-review-required"
check_ac_doc AC-3 "autopilot.md запрещает обходить блокировку merge хуком" \
  "$AUTOMD" "не пытайся обойти"

# ── /plan проставляет label типа задачи (plan.md, AC-4) ──────────────────────
# Команда — markdown-инструкция; проверяем, что шаг создания issues читает
# имя label из конфига (types.task.label, дефолт type:task), создаёт
# отсутствующий label в репо и вешает его на создаваемые issues; тип
# задаётся только label'ом, из текста issue не выводится.
PLANMD="$KIT/commands/plan.md"
plan_step3=$(md_section "$PLANMD" '^3\. \*\*' '^4\. \*\*')

assert_contains "AC-4: plan.md шаг 3 читает имя label типа task из конфига через adk-config.sh (дефолт type:task)" \
  "$plan_step3" 'adk-config\.sh types\.task\.label type:task'
assert_contains "AC-4: plan.md шаг 3 перехватывает stderr gh label create, чтобы разобрать исход (не глушит его 2>/dev/null)" \
  "$plan_step3" 'gh label create.*2>&1'
assert_contains "AC-4: plan.md шаг 3 считает успехом идемпотентный случай «label уже есть» (already exists)" \
  "$plan_step3" 'already exists'
assert_contains "K18 (issue #99): plan.md шаг 3 не глушит прочие ошибки gh label create — говорит явно, что label не создан" \
  "$plan_step3" 'label не создан'
assert_contains "AC-4: plan.md шаг 3 создаёт label до создания issues" \
  "$plan_step3" 'gh label create.*gh issue create'
assert_contains "AC-4: plan.md шаг 3 проставляет label создаваемым issues (--label в gh issue create)" \
  "$plan_step3" 'gh issue create.*--label'
check_ac_doc AC-4 "plan.md: label — единственный источник типа, из текста issue тип не выводится" \
  "$PLANMD" "из текста issue не выводится"
check_ac_doc AC-4 "plan.md: перепланирование не переклеивает labels на закрытых issues" \
  "$PLANMD" "на закрытых issues labels не переклеивай"

# ── /work определяет тип по label и применяет правила типа (work.md, AC-4) ──
# Команда — markdown-инструкция; проверяем, что шаг 1 читает labels issue и
# сопоставляет их с types.* конфига, шаг 3 применяет правила каждого
# дефолтного типа, а шаг 5 ставит commitType типа в заголовок PR.
work_type_step1=$(md_section "$WORKMD" '^1\. \*\*' '^2\. \*\*')
work_type_step3=$(md_section "$WORKMD" '^3\. \*\*' '^4\. \*\*')
work_type_step5=$(md_section "$WORKMD" '^5\. \*\*' '^6\. \*\*')

assert_contains "AC-4: work.md шаг 1 читает labels issue (gh issue view --json labels)" \
  "$work_type_step1" 'gh issue view.*--json labels'
assert_contains "AC-4: work.md шаг 1 читает label типа task из конфига через adk-config.sh (дефолт type:task)" \
  "$work_type_step1" 'adk-config\.sh types\.task\.label type:task'
assert_contains "AC-4: work.md шаг 1 читает label типа bug из конфига (дефолт type:bug)" \
  "$work_type_step1" 'types\.bug\.label type:bug'
assert_contains "AC-4: work.md шаг 1 читает label типа fastFollow из конфига (дефолт type:fast-follow)" \
  "$work_type_step1" 'types\.fastFollow\.label type:fast-follow'
assert_contains "AC-4: work.md шаг 1 читает label типа consolidate из конфига (дефолт type:consolidate)" \
  "$work_type_step1" 'types\.consolidate\.label type:consolidate'
check_ac_doc AC-4 "work.md: нет label или неизвестный label — тип task (безопасный дефолт)" \
  "$WORKMD" "Нет label или ни один label не совпал с типами — тип \`task\`"
check_ac_doc AC-4 "work.md: label — единственный источник типа, из текста issue тип не выводится" \
  "$WORKMD" "из текста issue тип не выводится"

assert_contains "AC-4: work.md шаг 3 — правило bug: первым падающий репро-тест" \
  "$work_type_step3" 'bug.*падающий репро-тест'
assert_contains "AC-4: work.md шаг 3 — правило bug: обязательные поля тела (Воспроизведение/Ожидаемое/Фактическое/Сбежал от)" \
  "$work_type_step3" 'Воспроизведение.*Ожидаемое.*Фактическое.*Сбежал от'
assert_contains "AC-4: work.md шаг 3 — правило task: тесты DoD с AC-тегами" \
  "$work_type_step3" 'task.*AC-тег'
assert_contains "AC-4: work.md шаг 3 — правило fastFollow: источник — вердикт ревью PR #N" \
  "$work_type_step3" 'fastFollow.*вердикт ревью PR #N'
assert_contains "AC-4: work.md шаг 3 — правило consolidate: наблюдаемое поведение не меняется" \
  "$work_type_step3" 'consolidate.*поведение не меняется'

assert_contains "AC-4: work.md шаг 5 читает commitType типа из конфига (adk-config.sh types.<тип>.commitType)" \
  "$work_type_step5" 'adk-config\.sh types\.<тип>\.commitType'
check_ac_doc AC-4 "work.md шаг 5: формат conventional-заголовка с commitType типа — его сверяет pr-title-check (AC-5)" \
  "$WORKMD" "<commitType>[(scope)]: <суть> (#N)"

# ── Монорепа: корневой диспетчер ─────────────────────────────────────────────
M="$TMP/mono"
mkdir -p "$M/scripts" "$M/apps/web/scripts" "$M/apps/web/src" "$M/apps/api/scripts" "$M/apps/api/src"
(cd "$M" && git init -q -b main)
cp "$KIT/templates/monorepo/scripts/"* "$M/scripts/"
chmod +x "$M/scripts/"*
for pkg in web api; do
  cat > "$M/apps/$pkg/scripts/check" <<EOF
#!/usr/bin/env bash
echo "$pkg-check:\$#" >> "\$(cd "\$(dirname "\$0")/../../.." && pwd)/.calls"
for a in "\$@"; do case "\$a" in *fail*) exit 1;; esac; done
exit 0
EOF
  cat > "$M/apps/$pkg/scripts/test" <<EOF
#!/usr/bin/env bash
[ -f "\$(dirname "\$0")/../.fail-tests" ] && exit 1
exit 0
EOF
  chmod +x "$M/apps/$pkg/scripts/check" "$M/apps/$pkg/scripts/test"
done
touch "$M/apps/web/src/page.tsx" "$M/apps/api/src/main.ts" "$M/README.md"

rm -f "$M/.calls"
(cd "$M" && ./scripts/check apps/web/src/page.tsx >/dev/null 2>&1)
assert_exit "монорепа check: файл web проходит" 0 $?
calls=$(cat "$M/.calls" 2>/dev/null)
assert_contains "монорепа check: вызван только пакет web" "$calls" '^web-check:1$'

rm -f "$M/.calls"
(cd "$M" && ./scripts/check >/dev/null 2>&1)
assert_exit "монорепа check: без аргументов проходит" 0 $?
npkgs=$(count_lines "$M/.calls")
assert_exit "монорепа check: без аргументов вызваны оба пакета, не $npkgs" 2 "$npkgs"

rm -f "$M/.calls"
(cd "$M" && ./scripts/check README.md >/dev/null 2>&1)
assert_exit "монорепа check: корневой файл вне пакетов проходит" 0 $?
[ ! -f "$M/.calls" ]
assert_exit "монорепа check: корневой файл не зовёт пакеты" 0 $?

touch "$M/apps/api/src/fail.ts"
(cd "$M" && ./scripts/check apps/api/src/fail.ts >/dev/null 2>&1)
assert_exit "монорепа check: падение пакета пробрасывается" 1 $?
rm "$M/apps/api/src/fail.ts"

(cd "$M" && ./scripts/test >/dev/null 2>&1)
assert_exit "монорепа test: все пакеты зелёные" 0 $?
touch "$M/apps/api/.fail-tests"
(cd "$M" && ./scripts/test >/dev/null 2>&1)
assert_exit "монорепа test: падение пакета пробрасывается" 1 $?
rm "$M/apps/api/.fail-tests"

# хуки в монорепе
printf '{"tool_input":{"file_path":"%s"}}' "$M/apps/web/src/page.tsx" | "$HOOKS/post-edit-check.sh" >/dev/null 2>&1
assert_exit "монорепа post-edit-check: находит пакетный контракт" 0 $?
echo '{}' | CLAUDE_PROJECT_DIR="$M" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "монорепа stop-test: корневой контракт, всё зелёное" 0 $?

# ── AC-трассируемость (ac-check.sh) ──────────────────────────────────────────
ACP="$TMP/acproj"
mkdir -p "$ACP/docs/specs" "$ACP/tests"

write_ac_spec() { # write_ac_spec <файл> <статус> <тело критериев>
  cat > "$1" <<EOF
# SPEC

Статус: $2

## Критерии приёмки

$3
EOF
}

write_ac_spec "$ACP/docs/specs/001-x.md" "approved" "- [ ] AC-101: первый критерий
- [ ] AC-102: второй критерий"
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-101: первый критерий покрыт"
echo "AC-102: второй критерий покрыт"
EOF

"$HOOKS/ac-check.sh" "$ACP" >/dev/null 2>&1
assert_exit "AC-4: ac-check: approved-спека AC-101..AC-102 с помеченными тестами — покрытие полное" 0 $?

# убрали тег AC-102 из тестов — непокрытый критерий должен провалить проверку
# и быть назван в выводе
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-101: первый критерий покрыт"
EOF
ac_out=$("$HOOKS/ac-check.sh" "$ACP" 2>&1)
ac_st=$?
assert_exit "AC-4: ac-check: непокрытый AC-102 — exit 1" 1 "$ac_st"
assert_contains "AC-4: ac-check: непокрытый AC-102 назван в выводе" "$ac_out" "AC-102"

# draft-спека не проверяется — её AC-токены не требуют покрытия.
# tests/run.sh фикстуры на этот момент всё ещё не содержит тега AC-102
# (предыдущий блок), поэтому exit по-прежнему 1 — из-за AC-102, а не AC-9.
write_ac_spec "$ACP/docs/specs/002-y.md" "draft" "- [ ] AC-9: черновой критерий без теста"
ac_out=$("$HOOKS/ac-check.sh" "$ACP" 2>&1)
ac_st=$?
rm "$ACP/docs/specs/002-y.md"
assert_exit "AC-4: ac-check: draft-спека не мешает результату (exit по-прежнему из-за AC-102)" 1 "$ac_st"
assert_not_contains "AC-4: ac-check: AC-токены draft-спеки не требуют покрытия" "$ac_out" "AC-9"

# вернули тег AC-102 — approved-спека снова полностью покрыта
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-101: первый критерий покрыт"
echo "AC-102: второй критерий покрыт"
EOF
"$HOOKS/ac-check.sh" "$ACP" >/dev/null 2>&1
assert_exit "AC-4: ac-check: покрытие восстановлено — exit 0" 0 $?

# approved-спека без AC-токенов — не ломает проверку
write_ac_spec "$ACP/docs/specs/003-z.md" "approved" "Пока без формализованных критериев."
"$HOOKS/ac-check.sh" "$ACP" >/dev/null 2>&1
assert_exit "AC-4: ac-check: approved-спека без AC-токенов не ломает проверку" 0 $?
rm "$ACP/docs/specs/003-z.md"

# переданные явные пути тестов используются вместо дефолтных
mkdir -p "$ACP/alt-tests"
cat > "$ACP/alt-tests/custom.sh" <<'EOF'
echo "AC-101: покрыт в альтернативном месте"
echo "AC-102: покрыт в альтернативном месте"
EOF
"$HOOKS/ac-check.sh" "$ACP" "$ACP/alt-tests" >/dev/null 2>&1
assert_exit "AC-4: ac-check: явно переданный путь тестов используется вместо дефолтного tests/" 0 $?
rm -rf "$ACP/alt-tests"

# без аргументов — usage-ошибка, не падение с трейсбеком
"$HOOKS/ac-check.sh" >/dev/null 2>&1
assert_exit "AC-4: ac-check: без аргументов — usage, exit 1" 1 $?

# регрессия: строка статуса в реальном шаблоне спеки содержит HTML-комментарий-
# подсказку — "Статус: draft <!-- draft | approved | in-progress | done -->"
# (templates/process/spec-template.md). Подстрокой "approved" внутри этого
# комментария черновик не должен приниматься за approved.
TPL="$TMP/ac-template-proj"
mkdir -p "$TPL/docs/specs" "$TPL/tests"
cat > "$TPL/docs/specs/001-draft.md" <<'EOF'
# SPEC-001: черновик

Статус: draft <!-- draft | approved | in-progress | done -->

## Критерии приёмки

- [ ] AC-101: критерий без единого теста
EOF
"$HOOKS/ac-check.sh" "$TPL" >/dev/null 2>&1
assert_exit "AC-4: ac-check: строка статуса шаблона (с HTML-комментарием-подсказкой) не считается approved" 0 $?

# AC-токен вне секции "## Критерии приёмки" (например, упомянутый в прозе
# раздела "## Что делаем") не требует отдельного теста
SEC="$TMP/ac-section-proj"
mkdir -p "$SEC/docs/specs" "$SEC/tests"
cat > "$SEC/docs/specs/001-x.md" <<'EOF'
# SPEC

Статус: approved

## Что делаем

Упоминание AC-7 здесь — прозаическая отсылка, не критерий приёмки.

## Критерии приёмки

- [ ] AC-101: единственный формальный критерий
EOF
cat > "$SEC/tests/run.sh" <<'EOF'
echo "AC-101: критерий покрыт"
EOF
"$HOOKS/ac-check.sh" "$SEC" >/dev/null 2>&1
assert_exit "AC-4: ac-check: AC-токен вне секции «Критерии приёмки» не требует покрытия" 0 $?

# сама спека (даже с именем вида *.spec.md, совпадающим с дефолтным
# паттерном тестового корпуса) не может покрыть сама себя — docs/specs/
# исключены из тестового корпуса
SELFM="$TMP/ac-selfmatch-proj"
mkdir -p "$SELFM/docs/specs"
cat > "$SELFM/docs/specs/001-feature.spec.md" <<'EOF'
# SPEC

Статус: approved

## Критерии приёмки

- [ ] AC-101: критерий без отдельного теста
EOF
ac_out=$("$HOOKS/ac-check.sh" "$SELFM" 2>&1)
ac_st=$?
assert_exit "AC-4: ac-check: спека не засчитывает сама себя как тест (docs/specs исключён)" 1 "$ac_st"
assert_contains "AC-4: ac-check: AC-101 назван непокрытым при самопокрытии спекой" "$ac_out" "AC-101"

# issue #28 K6: корень с trailing slash не должен молча отключать защиту
# от самопокрытия спекой (root не нормализовался → specs_dir перестаёт
# матчиться в -not -path → спека сама себя "покрывает" → ложный exit 0)
ac_out=$("$HOOKS/ac-check.sh" "$SELFM/" 2>&1)
ac_st=$?
assert_exit "AC-4: ac-check: trailing slash в корне не отключает защиту от самопокрытия спекой (issue #28 K6)" 1 "$ac_st"
assert_contains "AC-4: ac-check: AC-101 назван непокрытым при самопокрытии спекой (root с trailing slash)" "$ac_out" "AC-101"

# node_modules/vendor не считаются тестовым корпусом — токен в зависимости
# не должен ложно засчитываться как покрытие
VEND="$TMP/ac-vendor-proj"
mkdir -p "$VEND/docs/specs" "$VEND/tests" "$VEND/node_modules/pkg"
write_ac_spec "$VEND/docs/specs/001-x.md" "approved" "- [ ] AC-101: критерий без реального теста"
echo "AC-101" > "$VEND/node_modules/pkg/index.spec.js"
"$HOOKS/ac-check.sh" "$VEND" >/dev/null 2>&1
assert_exit "AC-4: ac-check: node_modules не считается тестовым корпусом" 1 $?

# issue #28 K6: недоступная поддиректория не должна течь "Permission denied"
# в stderr гейта (2>/dev/null был потерян при переходе на prune_default)
PERMP="$TMP/ac-permdenied-proj"
mkdir -p "$PERMP/docs/specs" "$PERMP/tests" "$PERMP/secret"
write_ac_spec "$PERMP/docs/specs/001-x.md" "approved" "- [ ] AC-101: критерий"
echo "AC-101: покрыт" > "$PERMP/tests/run.sh"
chmod 000 "$PERMP/secret"
ac_err=$("$HOOKS/ac-check.sh" "$PERMP" 2>&1 >/dev/null)
assert_not_contains "AC-4: ac-check: недоступная директория не течёт 'Permission denied' в stderr (issue #28 K6)" "$ac_err" "ermission denied"
chmod 755 "$PERMP/secret"

# ── ac-check.sh: конвенция swift-тестов в дефолтном корпусе (issue #82) ─────
# Баг: дефолтный корпус ac-check знал только конвенции js/python (tests/,
# *.test.*, *.spec.*, test_*.py) — SPM-конвенция шаблона swift-ios
# (Packages/<P>/Tests/**/<X>Tests.swift) ни под один паттерн не подпадала,
# тег AC-N в реальном swift-тесте не засчитывался (ложно-красный гейт).
# Один фикстурный проект проверяет обе части фикса разом: *Tests.swift
# входит в корпус (AC-101 покрыт), а .build/DerivedData/Pods из него
# исключены (AC-102, чей единственный тег лежит в этих папках, остаётся
# непокрытым — иначе гейт затянул бы тесты зависимостей из .build/checkouts).
SWIFTAC="$TMP/ac-swift-proj"
mkdir -p "$SWIFTAC/docs/specs" \
  "$SWIFTAC/Packages/Feature/Tests/FeatureTests" \
  "$SWIFTAC/.build/checkouts/Dep/Tests" \
  "$SWIFTAC/DerivedData/Build/Products/Tests" \
  "$SWIFTAC/Pods/Dep/Tests"

write_ac_spec "$SWIFTAC/docs/specs/001-x.md" "approved" "- [ ] AC-101: критерий, закрытый swift-тестом пакета
- [ ] AC-102: критерий, чей тег встречается только в исключённых директориях"

cat > "$SWIFTAC/Packages/Feature/Tests/FeatureTests/FeatureTests.swift" <<'EOF'
import XCTest

final class FeatureTests: XCTestCase {
    func testAC101() {
        // AC-101: критерий покрыт
        XCTAssertTrue(true)
    }
}
EOF
echo "// AC-102" > "$SWIFTAC/.build/checkouts/Dep/Tests/DepTests.swift"
echo "// AC-102" > "$SWIFTAC/DerivedData/Build/Products/Tests/DerivedTests.swift"
echo "// AC-102" > "$SWIFTAC/Pods/Dep/Tests/PodsTests.swift"

swiftac_out=$("$HOOKS/ac-check.sh" "$SWIFTAC" 2>&1)
swiftac_st=$?
assert_exit "issue #82: ac-check: swift-корпус собран — AC-102 (только в .build/DerivedData/Pods) остаётся непокрытым" 1 "$swiftac_st"
assert_not_contains "issue #82: ac-check: *Tests.swift в Packages/<P>/Tests/ засчитан — AC-101 не в списке непокрытых" "$swiftac_out" "AC-101"
assert_contains "issue #82: ac-check: AC-102 назван непокрытым — .build/checkouts не тестовый корпус" "$swiftac_out" "AC-102"

# .build/checkouts тянет тесты зависимостей репозитория (не своих) — их
# присутствие не должно замедлять/засорять корпус: явное регресс-repro,
# что после фикса каталог по-прежнему исключён, даже если в нём лежит файл,
# который под старым паттерном не матчился бы вовсе (AC-103 нигде, кроме
# .build, не встречается — обязан остаться непокрытым)
write_ac_spec "$SWIFTAC/docs/specs/001-x.md" "approved" "- [ ] AC-103: критерий только в .build/checkouts"
echo "// AC-103" > "$SWIFTAC/.build/checkouts/Dep/Tests/OnlyInBuildTests.swift"
"$HOOKS/ac-check.sh" "$SWIFTAC" >/dev/null 2>&1
assert_exit "issue #82: ac-check: тег, существующий только в .build/checkouts, не засчитывается как покрытие" 1 $?

# ── Запланированные AC: аннотация «(ждёт #N)» (issue #54) ───────────────────
# Репро бага: approved-спека мержится до реализации милестоуна, тест AC
# появляется в одном из будущих issues — гейт не должен быть красным весь
# милестоун, если непокрытый AC явно помечен номером issue.
PEND="$TMP/ac-pending-proj"
mkdir -p "$PEND/docs/specs" "$PEND/tests"
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101 (ждёт #7): критерий, тест которого появится в issue #7"
: > "$PEND/tests/run.sh"
"$HOOKS/ac-check.sh" "$PEND" >/dev/null 2>&1
assert_exit "issue #54: ac-check: непокрытый AC с аннотацией «ждёт #N» принимается" 0 $?

# --complete (граница милестоуна): аннотации не оправдывают отсутствие теста
pend_out=$("$HOOKS/ac-check.sh" --complete "$PEND" 2>&1)
pend_st=$?
assert_exit "issue #54: ac-check --complete: аннотированный AC без теста — непокрыт" 1 "$pend_st"
assert_contains "issue #54: ac-check --complete: непокрытый AC назван в выводе" "$pend_out" "AC-101"

# аннотация одного AC не оправдывает другой непокрытый AC без аннотации
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101 (ждёт #7): запланирован
- [ ] AC-102: ни теста, ни аннотации"
pend_out=$("$HOOKS/ac-check.sh" "$PEND" 2>&1)
pend_st=$?
assert_exit "issue #54: ac-check: AC без теста и без аннотации остаётся непокрытым" 1 "$pend_st"
assert_contains "issue #54: ac-check: непокрытым назван именно AC без аннотации" "$pend_out" "AC-102"
assert_not_contains "issue #54: ac-check: аннотированный AC не попадает в непокрытые" "$pend_out" "AC-101"

# оставшаяся аннотация на уже покрытом AC безвредна, в том числе в --complete
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101 (ждёт #7): тест уже добавлен, аннотацию забыли снять"
echo "AC-101: покрыт" > "$PEND/tests/run.sh"
"$HOOKS/ac-check.sh" --complete "$PEND" >/dev/null 2>&1
assert_exit "issue #54: ac-check --complete: покрытый AC с оставшейся аннотацией проходит" 0 $?

# аннотация действует только в секции критериев — «ждёт #N» в прозе не считается
cat > "$PEND/docs/specs/001-x.md" <<'EOF'
# SPEC

Статус: approved

## Что делаем

AC-101 ждёт #7 — но это проза, а не критерий.

## Критерии приёмки

- [ ] AC-101: критерий без теста и без аннотации в секции
EOF
: > "$PEND/tests/run.sh"
"$HOOKS/ac-check.sh" "$PEND" >/dev/null 2>&1
assert_exit "issue #54: ac-check: «ждёт #N» вне секции критериев не аннотирует AC" 1 $?

# круг ревью 1 (PR #55): аннотация привязана к токену, а не к строке —
# «(ждёт #N)» помечает pending только AC непосредственно перед собой;
# токен, упомянутый дальше в тексте того же критерия, тестом не освобождён
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101 (ждёт #7): пересекается с AC-102
- [ ] AC-102: ни теста, ни аннотации"
: > "$PEND/tests/run.sh"
pend_out=$("$HOOKS/ac-check.sh" "$PEND" 2>&1)
pend_st=$?
assert_exit "issue #54: ac-check: аннотация не заражает другие AC-токены своей строки" 1 "$pend_st"
assert_contains "issue #54: ac-check: AC из текста аннотированной строки остаётся непокрытым" "$pend_out" "AC-102"

# проза «ждёт #N» не сразу после токена — не аннотация
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101: команда сообщает «ждёт #12» в отчёте"
"$HOOKS/ac-check.sh" "$PEND" >/dev/null 2>&1
assert_exit "issue #54: ac-check: «ждёт #N» не сразу после AC-токена — не аннотация" 1 $?

# круг ревью 1 (PR #55): строгий режим не деградирует молча — --complete не
# первым аргументом (лёгкая перестановка при вызове из /consolidate) раньше
# трактовался как путь тестов: аннотированный AC принимался, exit 0
write_ac_spec "$PEND/docs/specs/001-x.md" "approved" "- [ ] AC-101 (ждёт #7): запланирован"
: > "$PEND/tests/run.sh"
"$HOOKS/ac-check.sh" "$PEND" --complete "$PEND/tests/run.sh" >/dev/null 2>&1
assert_exit "issue #54: ac-check: --complete не первым аргументом — громкая ошибка, не мягкий режим" 1 $?

# несуществующий корень — ошибка, а не молчаливый exit 0
"$HOOKS/ac-check.sh" "$TMP/no-such-root" >/dev/null 2>&1
assert_exit "issue #54: ac-check: несуществующий корень проекта — ошибка" 1 $?

# ── AC-проверка подключена к контракту проекта (issue #7) ───────────────────
# Используем реальный отгружаемый templates/monorepo/scripts/check (а не его
# пересказ) — без пакетов у него нет внешних зависимостей (npx/uv), поэтому
# он хермитично гоняется в тестах кита. Пакет pkg/ — хендкрафченный (внешние
# тулинги не нужны кит-тестам), он проверяет, что оригинальная маршрутизация
# по файлам не тронута: ac-check добавлен только хвостом полного прогона.
WIRE="$TMP/wireproj"
mkdir -p "$WIRE/docs/specs" "$WIRE/tests" "$WIRE/scripts" "$WIRE/pkg/scripts" "$WIRE/pkg/src"
cp "$KIT/templates/monorepo/scripts/check" "$WIRE/scripts/check"
chmod +x "$WIRE/scripts/check"
cp "$KIT/hooks/scripts/ac-check.sh" "$WIRE/scripts/ac-check"
chmod +x "$WIRE/scripts/ac-check"
cat > "$WIRE/pkg/scripts/check" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *bad*) echo "type error in $a"; exit 1;; esac; done
exit 0
EOF
chmod +x "$WIRE/pkg/scripts/check"
echo x > "$WIRE/pkg/src/good.ts"
echo x > "$WIRE/pkg/src/bad.ts"

(cd "$WIRE" && ./scripts/check pkg/src/bad.ts >/dev/null 2>&1)
assert_exit "AC-4: contract check (реальный templates/monorepo/scripts/check): частичный прогон по-прежнему ловит bad-файл пакета" 1 $?
(cd "$WIRE" && ./scripts/check pkg/src/good.ts >/dev/null 2>&1)
assert_exit "AC-4: contract check: частичный прогон по чистому файлу проходит" 0 $?

# непокрытый AC уже есть в docs/specs — частичный прогон (аргументы-файлы)
# всё равно не должен звать ac-check, иначе любая точечная правка файла
# (её гоняет post-edit-check после каждого Edit) блокировалась бы AC-гейтом
write_ac_spec "$WIRE/docs/specs/001-x.md" "approved" "- [ ] AC-101: критерий"
(cd "$WIRE" && ./scripts/check pkg/src/good.ts >/dev/null 2>&1)
assert_exit "AC-4: contract check: частичный прогон игнорирует непокрытый AC — граница \$#-guard'а" 0 $?

(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: полный прогон падает при непокрытом AC" 1 $?

cat > "$WIRE/tests/run.sh" <<'EOF'
echo "AC-101: критерий покрыт"
EOF
(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: полный прогон проходит при полном покрытии AC" 0 $?

rm "$WIRE/tests/run.sh"
rm "$WIRE/scripts/ac-check"
(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: без scripts/ac-check — прежнее поведение, непокрытый AC не блокирует" 0 $?

# ── Шаблоны и project-init.md подключают ac-check (issue #7) ────────────────
for t in nextjs nestjs python-service swift-ios monorepo; do
  check_content=$(cat "$KIT/templates/$t/scripts/check")
  assert_contains "AC-4: templates/$t/scripts/check содержит вызов ac-check в полном прогоне" "$check_content" 'scripts/ac-check'
done

project_init_content=$(cat "$KIT/commands/project-init.md")
assert_contains "AC-4: project-init.md содержит шаг копирования ac-check.sh в scripts/ac-check" "$project_init_content" 'scripts/ac-check'

# ── Шаблон swift-ios: поведение контрактных скриптов (issue #70) ────────────
# Стаб swift на PATH — тесты гоняются без тулчейна Xcode; PATH сужен до
# системных директорий, чтобы xcodegen с машины не подмешивался.
SIOS="$TMP/swiftios-proj"
SBIN="$TMP/swiftios-bin"
mkdir -p "$SIOS" "$SBIN"
cp -R "$KIT/templates/swift-ios/scripts" "$SIOS/scripts"
cat > "$SBIN/swift" <<'EOF'
#!/usr/bin/env bash
echo "SWIFT_STUB $*"
case "$1" in
  test)
    case "${SWIFT_STUB_TEST_MODE:-pass}" in
      notests) echo "error: no tests found; create a target in the 'Tests' directory"; exit 1 ;;
      fail) echo "Test Case 'X' failed"; exit 1 ;;
      slow) echo "SLOW_MARKER_1"; sleep 1; echo "SLOW_MARKER_2"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  build)
    if [ "${SWIFT_STUB_BUILD_MODE:-pass}" = "fail" ]; then
      echo "error: cannot convert value"
      exit 1
    fi ;;
esac
exit 0
EOF
chmod +x "$SBIN/swift"
SPATH="$SBIN:/usr/bin:/bin"

# голый проект: нет исходников, пакетов и .xcodeproj — check/test молча зелёные
(cd "$SIOS" && PATH="$SPATH" ./scripts/check >/dev/null 2>&1)
assert_exit "issue #70: swift-ios: check на голом проекте — exit 0" 0 $?
(cd "$SIOS" && PATH="$SPATH" ./scripts/test >/dev/null 2>&1)
assert_exit "issue #70: swift-ios: test на голом проекте — exit 0" 0 $?

# падающие тесты пакета роняют гейт независимо от раскладки каталогов
# (репро блокера круга 1 PR #71: пакет без каталога Tests/ молча пропускался)
mkdir -p "$SIOS/Packages/Engine/Sources"
echo "// manifest" > "$SIOS/Packages/Engine/Package.swift"
sios_out=$(cd "$SIOS" && PATH="$SPATH" SWIFT_STUB_TEST_MODE=fail ./scripts/test 2>&1)
sios_st=$?
assert_exit "issue #70: swift-ios: падающие тесты пакета роняют scripts/test (без каталога Tests/)" 1 "$sios_st"
assert_contains "issue #70: swift-ios: вывод упавших тестов доходит до гейта" "$sios_out" "failed"

# пакет без тест-таргетов: «no tests found» — не провал (контракт)
(cd "$SIOS" && PATH="$SPATH" SWIFT_STUB_TEST_MODE=notests ./scripts/test >/dev/null 2>&1)
assert_exit "issue #70: swift-ios: «no tests found» пакета — не провал, exit 0" 0 $?

# K20 (issue #99): вывод swift test стримится (tee), а не копится в переменной
# до завершения пакета — проверяем, что первая строка появляется в выводе,
# пока процесс ещё жив (до того как стаб допишет вторую строку).
sios_stream_out="$TMP/swiftios-stream.log"
(cd "$SIOS" && PATH="$SPATH" SWIFT_STUB_TEST_MODE=slow ./scripts/test >"$sios_stream_out" 2>&1) &
stream_pid=$!
sleep 0.4
stream_still_running="no"
kill -0 "$stream_pid" 2>/dev/null && stream_still_running="yes"
stream_partial=$(cat "$sios_stream_out" 2>/dev/null)
wait "$stream_pid"
assert_contains "K20 (issue #99): swift-ios scripts/test — замер сделан пока swift test ещё выполняется (проверка валидна)" \
  "$stream_still_running" "yes"
assert_contains "K20 (issue #99): swift-ios scripts/test стримит первую строку вывода swift test раньше завершения пакета (tee, не накопление в переменной)" \
  "$stream_partial" "SLOW_MARKER_1"
assert_not_contains "K20 (issue #99): swift-ios scripts/test — вторая строка вывода ещё не записана в момент замера" \
  "$stream_partial" "SLOW_MARKER_2"

# check по файлу пакета собирает этот пакет — ошибка типов ловится
# PostToolUse-гейтом, а не только полным прогоном (круг 1 PR #71)
echo "let x = 1" > "$SIOS/Packages/Engine/Sources/E.swift"
sios_out=$(cd "$SIOS" && PATH="$SPATH" SWIFT_STUB_BUILD_MODE=fail ./scripts/check Packages/Engine/Sources/E.swift 2>&1)
sios_st=$?
assert_exit "issue #70: swift-ios: check <файл пакета> — ошибка типов пакета роняет гейт" 1 "$sios_st"
assert_contains "issue #70: swift-ios: собирается именно пакет переданного файла" "$sios_out" "build --package-path Packages/Engine"

# файл вне пакетов: только линт, сборка не зовётся (типы таргетов — ADR-006)
mkdir -p "$SIOS/App"
echo "let y = 2" > "$SIOS/App/A.swift"
sios_out=$(cd "$SIOS" && PATH="$SPATH" SWIFT_STUB_BUILD_MODE=fail ./scripts/check App/A.swift 2>&1)
sios_st=$?
assert_exit "issue #70: swift-ios: check <файл вне пакетов> — линт без сборки, exit 0" 0 "$sios_st"
assert_not_contains "issue #70: swift-ios: для файла вне пакетов swift build не вызывается" "$sios_out" "build --package-path"

# project.yml без xcodegen на PATH — громкая ошибка, не молчаливый пропуск smoke
touch "$SIOS/project.yml"
sios_out=$(cd "$SIOS" && PATH="$SPATH" ./scripts/test 2>&1)
sios_st=$?
assert_exit "issue #70: swift-ios: project.yml без xcodegen — громкая ошибка" 1 "$sios_st"
assert_contains "issue #70: swift-ios: ошибка называет xcodegen" "$sios_out" "xcodegen"
rm "$SIOS/project.yml"

# шум xcodebuild в stderr на успешном пути не ломает разбор списка схем
# (круг 2 PR #71: 2>&1 подмешивал stderr в JSON → JSONDecodeError на
# здоровом проекте)
mkdir -p "$SIOS/Demo.xcodeproj"
cat > "$SBIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-list*)
    echo '{"project":{"schemes":["Demo"]}}'
    echo "DVTPlugInLoading: Requested but did not find extension point" >&2
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$SBIN/xcodebuild"
sios_out=$(cd "$SIOS" && PATH="$SPATH" ./scripts/test 2>&1)
sios_st=$?
assert_exit "issue #70: swift-ios: stderr-шум xcodebuild -list не ломает smoke здорового проекта" 0 "$sios_st"
assert_not_contains "issue #70: swift-ios: разбор схем не падает JSONDecodeError от шума" "$sios_out" "JSONDecodeError"
rm -rf "$SIOS/Demo.xcodeproj" "$SBIN/xcodebuild"

# scripts/check самого кита (dogfood, issue #9) — по образцу проверки выше
# для templates/*/scripts/check; раньше не было теста, что строка вызова
# ac-check.sh не была случайно удалена (issue #28 K8, хвост ревью PR #19)
kit_check_content=$(cat "$KIT/scripts/check")
assert_contains "AC-4: scripts/check кита содержит вызов ac-check.sh (issue #28 K8)" "$kit_check_content" 'ac-check.sh'

# ── scripts/check самого кита применяет $#-guard к ac-check (issue #24) ──────
# Реальный scripts/check кита копируется в изолированную фикстуру-кита:
# hooks/scripts/ac-check.sh — стаб, печатающий маркер (отличить вызов от
# невызова), claude-CLI на PATH — тоже стаб (реальный "claude plugin validate"
# не должен зависеть от того, установлен ли claude в окружении, где гоняются
# тесты кита).
KCHK="$TMP/kitcheck"
mkdir -p "$KCHK/.claude-plugin" "$KCHK/hooks/scripts" "$KCHK/scripts" "$KCHK/tests" "$KCHK/bin"
echo '{}' > "$KCHK/.claude-plugin/plugin.json"
echo '{}' > "$KCHK/.claude-plugin/marketplace.json"
echo '{}' > "$KCHK/hooks/hooks.json"
cp "$KIT/scripts/check" "$KCHK/scripts/check"
chmod +x "$KCHK/scripts/check"
cat > "$KCHK/hooks/scripts/ac-check.sh" <<'EOF'
#!/usr/bin/env bash
echo "AC_CHECK_CALLED"
exit 0
EOF
chmod +x "$KCHK/hooks/scripts/ac-check.sh"
cat > "$KCHK/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$KCHK/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$KCHK/bin/claude"

kchk_out=$(cd "$KCHK" && PATH="$KCHK/bin:$PATH" ./scripts/check some/file.ts 2>&1)
kchk_st=$?
assert_exit "кит: scripts/check <файл> — частичный прогон завершается успешно" 0 "$kchk_st"
assert_not_contains "кит: scripts/check <файл> не запускает ac-check.sh (issue #24)" "$kchk_out" "AC_CHECK_CALLED"

kchk_out=$(cd "$KCHK" && PATH="$KCHK/bin:$PATH" ./scripts/check 2>&1)
kchk_st=$?
assert_exit "кит: scripts/check без аргументов — полный прогон завершается успешно" 0 "$kchk_st"
assert_contains "кит: scripts/check без аргументов запускает ac-check.sh (issue #24)" "$kchk_out" "AC_CHECK_CALLED"

# ── тест-страж: фикстуры блока ac-check.sh не самопокрывают AC-N кита (issue #27) ─
# Раньше строки-фикстуры внутри тестов ac-check.sh (весь диапазон AC-4-тестов
# от заголовка «AC-трассируемость» до заголовка «Конвенция AC-тегирования» —
# сам этот диапазон легитимно несёт реальный тег AC-4, он тестирует ac-check
# как фичу) физически лежали в этом файле и совпадали с grep-корпусом
# догфуда AC-N самого кита (docs/specs/001-process-observability.md),
# поэтому ./scripts/check давал ложный exit 0, даже если реальные теги
# были убраны из журнал-тестов вне этого диапазона.
# Здесь копия этого файла: реальные теги AC-N вне диапазона AC-4-тестов
# вычищаются (имитируя ручное удаление из журнал-тестов), а сам диапазон и
# его фикстуры остаются как есть — если фикстуры снова станут номерами
# реальных критериев (текущая нумерация фикстур в сотнях, см. диапазон
# выше), ac-check честно этого не заметит и тест упадёт. Тег каждого AC-N
# собирается динамически из секции «## Критерии приёмки» спеки (тем же
# способом, что и сам ac-check.sh) — а не как строковый литерал, чтобы сам
# тест-страж не плодил новую самопокрывающуюся строку.
guard_ac_check() {
  local block_start block_end block_ok guard_out guard_st GUARD
  block_start=$(grep -n '^# ── AC-трассируемость' "$KIT/tests/run.sh" | head -1 | cut -d: -f1)
  block_end=$(grep -n '^# ── Конвенция AC-тегирования' "$KIT/tests/run.sh" | head -1 | cut -d: -f1)
  block_ok=0
  [ -n "${block_start:-}" ] && [ -n "${block_end:-}" ] && [ "$block_end" -gt "$block_start" ] || block_ok=1
  assert_exit "AC-4: тест-страж: заголовки диапазона AC-4-тестов найдены и упорядочены" 0 "$block_ok"
  [ "$block_ok" -eq 0 ] || return
  block_end=$((block_end - 1))

  GUARD="$TMP/ac-guard-proj"
  mkdir -p "$GUARD/docs/specs" "$GUARD/tests"
  cp "$KIT/docs/specs/001-process-observability.md" "$GUARD/docs/specs/001-process-observability.md"

  declare -a guard_sed_args=()
  declare -a guard_tags=()
  while IFS= read -r tag; do
    guard_tags+=("$tag")
    guard_sed_args+=(-e "1,$((block_start - 1)) s/${tag}([^0-9]|\$)/ZZ\\1/g")
    guard_sed_args+=(-e "$((block_end + 1)),\$ s/${tag}([^0-9]|\$)/ZZ\\1/g")
  done < <(awk '/^## Критерии приёмки/{flag=1; next} /^## /{flag=0} flag' \
             "$GUARD/docs/specs/001-process-observability.md" | grep -oE 'AC-[0-9]+' | sort -u)
  sed -E "${guard_sed_args[@]}" "$KIT/tests/run.sh" > "$GUARD/tests/run.sh"

  # sanity: sed только подставляет текст, не удаляет строки — число строк копии
  # обязано совпасть с оригиналом. Если адреса sed сломались (пустой или
  # перевёрнутый диапазон), копия могла бы получиться усечённой/пустой, и
  # проверка ac-check ниже была бы вакуумным "все AC непокрыты" не по факту
  # вычищенных тегов, а из-за пустого корпуса — тест-страж прошёл бы вхолостую.
  assert_exit "AC-4: тест-страж: копия tests/run.sh для проверки не усечена (совпадает по числу строк с оригиналом)" \
    "$(count_lines "$KIT/tests/run.sh")" "$(count_lines "$GUARD/tests/run.sh")"

  guard_out=$("$HOOKS/ac-check.sh" "$GUARD" 2>&1)
  guard_st=$?
  assert_exit "AC-4: тест-страж: реальные теги AC-N вне диапазона AC-4-тестов убраны — ac-check честно падает" 1 "$guard_st"
  for tag in "${guard_tags[@]}"; do
    # свой собственный реальный тег диапазона (AC-4) остаётся покрытым — он
    # не тронут (живёт внутри исключённого диапазона), это не баг issue #27
    [ "$tag" = "AC-4" ] && continue
    assert_contains "AC-4: тест-страж: непокрытый $tag назван в выводе — фикстуры диапазона AC-4-тестов не самопокрывают его" "$guard_out" "$tag"
  done
}
guard_ac_check

# ── Конвенция AC-тегирования зафиксирована в промптах и скилле tdd (issue #6) ─
# Только markdown: проверяем, что нужный текст конвенции присутствует в
# правильном месте каждого из семи файлов, а не просто что "AC-" где-то
# встречается в файле.
check_ac_doc AC-5 "spec-template: критерий приёмки — пронумерованный checkbox AC-1" \
  "$KIT/templates/process/spec-template.md" "- [ ] AC-1:"
check_ac_doc AC-5 "spec-template: пример второго критерия пронумерован" \
  "$KIT/templates/process/spec-template.md" "- [ ] AC-2:"

check_ac_doc AC-5 "/spec: правило нумерации критериев AC-1, AC-2, …" \
  "$KIT/commands/spec.md" "AC-1, AC-2"

check_ac_doc AC-5 "planner: план показывает покрытие «AC-N → задачи»" \
  "$KIT/agents/planner.md" "AC-N → задачи"
check_ac_doc AC-5 "planner: DoD задачи ссылается на номер AC" \
  "$KIT/agents/planner.md" "номер AC, который она закрывает"

check_ac_doc AC-5 "/plan: покрытие показывается в формате «AC-N → задачи»" \
  "$KIT/commands/plan.md" "AC-N → задачи"
check_ac_doc AC-5 "/plan: DoD в чате показывается со ссылкой на номер AC" \
  "$KIT/commands/plan.md" "номер AC"

check_ac_doc AC-5 "/work: тесты по DoD помечаются номером AC" \
  "$KIT/commands/work.md" "тем же номером AC"

check_ac_doc AC-5 "reviewer: тег AC-N должен соответствовать сути критерия" \
  "$KIT/agents/reviewer.md" "соответствует сути критерия"

check_ac_doc AC-5 "skills/tdd: тег в имени describe/it" \
  "$KIT/skills/tdd/SKILL.md" 'it("AC-'
check_ac_doc AC-5 "skills/tdd: для bash-тестов тег в строке описания" \
  "$KIT/skills/tdd/SKILL.md" "в строке описания для bash-тестов"
check_ac_doc AC-5 "skills/tdd: ссылка на ac-check" \
  "$KIT/skills/tdd/SKILL.md" "hooks/scripts/ac-check.sh"

# ── Петля сбежавших дефектов зафиксирована в процессе (issue #8, AC-6) ──────
check_ac_doc AC-6 "README содержит правило «Сбежал от: <гейт>»" \
  "$KIT/README.md" "Сбежал от:"
check_ac_doc AC-6 "consolidate.md агрегирует распределение «Сбежал от» по гейтам" \
  "$KIT/commands/consolidate.md" "агрегацию по гейтам"
check_ac_doc AC-6 "consolidate.md вызывает adk-stats.sh" \
  "$KIT/commands/consolidate.md" "hooks/scripts/adk-stats.sh"

# ── Цикл аннотаций «ждёт #N» закреплён в процессе (issue #54) ───────────────
check_ac_doc "issue #54" "/plan проставляет аннотации «ждёт #N» при декомпозиции" \
  "$KIT/commands/plan.md" "ждёт #"
check_ac_doc "issue #54" "/work снимает аннотацию в PR, добавляющем тег-тест" \
  "$KIT/commands/work.md" "(ждёт #N)"
check_ac_doc "issue #54" "/consolidate прогоняет ac-check --complete на границе вехи" \
  "$KIT/commands/consolidate.md" "ac-check.sh --complete"
check_ac_doc "issue #54" "шаблон спеки: секция «Переходные состояния»" \
  "$KIT/templates/process/spec-template.md" "## Переходные состояния"
check_ac_doc "issue #54" "reviewer: переходные состояния гейтов в чек-листе" \
  "$KIT/agents/reviewer.md" "Переходные состояния"
check_ac_doc "issue #54" "контракт: аннотация «ждёт #N» и --complete описаны" \
  "$KIT/docs/contract.md" "ждёт #"

# ── Общий хелпер hooks/scripts/lib/paths.sh (issue #23) ─────────────────────
# Кандидат K3 из /consolidate: adk-log.sh и adk-stats.sh дублировали
# построчно правило определения корня проекта и каталога журнала;
# stop-test.sh/notification.sh дублировали резолв пути к notify-send.sh.
# Ниже — проверки самого хелпера и сквозная (end-to-end) эквивалентность
# поведения adk-log.sh/adk-stats.sh (в т.ч. git-фолбэк) до и после переноса
# логики в lib/paths.sh, плюс подтверждение, что root-правило
# stop-test.sh/notification.sh сознательно НЕ унифицировано (см. ADR).

PATHS_LIB="$HOOKS/lib/paths.sh"

# adk_project_root: CLAUDE_PROJECT_DIR задан — используется как есть
out=$(CLAUDE_PROJECT_DIR="/explicit/root" bash -c ". '$PATHS_LIB'; adk_project_root")
assert_exit "AC-1: paths.sh: adk_project_root уважает CLAUDE_PROJECT_DIR" 0 $?
assert_contains "AC-1: paths.sh: adk_project_root вернул явно заданный CLAUDE_PROJECT_DIR" "$out" '^/explicit/root$'

# adk_project_root: CLAUDE_PROJECT_DIR не задан, cwd внутри git-репо — git-фолбэк
GITROOT="$TMP/paths-gitroot"
mkdir -p "$GITROOT/sub"
(cd "$GITROOT" && git_c init -q -b main)
out=$(cd "$GITROOT/sub" && env -u CLAUDE_PROJECT_DIR bash -c ". '$PATHS_LIB'; adk_project_root")
GITROOT_REAL=$(cd "$GITROOT" && pwd -P)
[ "$out" = "$GITROOT_REAL" ]
assert_exit "AC-1: paths.sh: adk_project_root — git-фолбэк находит toplevel из подкаталога" 0 $?

# adk_project_root: ни CLAUDE_PROJECT_DIR, ни git — $PWD
NOTGIT="$TMP/paths-notgit"
mkdir -p "$NOTGIT"
out=$(cd "$NOTGIT" && env -u CLAUDE_PROJECT_DIR bash -c ". '$PATHS_LIB'; adk_project_root")
# логический $PWD (без -P): скрипт использует голый "$PWD" как последний
# фолбэк, не резолвя симлинки, поэтому и здесь сравниваем без резолва.
NOTGIT_REAL=$(cd "$NOTGIT" && pwd)
[ "$out" = "$NOTGIT_REAL" ]
assert_exit "AC-1: paths.sh: adk_project_root — без git и без CLAUDE_PROJECT_DIR отдаёт \$PWD" 0 $?

# adk_logs_dir: ADK_LOGS_DIR переопределяет, иначе <root>/.adk/logs
out=$(ADK_LOGS_DIR="/custom/logs" bash -c ". '$PATHS_LIB'; adk_logs_dir /some/root")
assert_contains "AC-1: paths.sh: adk_logs_dir уважает ADK_LOGS_DIR" "$out" '^/custom/logs$'
out=$(env -u ADK_LOGS_DIR bash -c ". '$PATHS_LIB'; adk_logs_dir /some/root")
assert_contains "AC-1: paths.sh: adk_logs_dir по умолчанию — <root>/.adk/logs" "$out" '^/some/root/\.adk/logs$'

# Эквивалентность: adk-log.sh пишет в git-toplevel/.adk/logs, если
# CLAUDE_PROJECT_DIR не задан, а cwd — вложенный подкаталог git-репо
# (до переноса в lib/paths.sh это поведение обеспечивалось инлайновым
# блоком; сейчас — общей adk_project_root()).
LOGFB="$TMP/paths-logfallback"
mkdir -p "$LOGFB/nested/deeper"
(cd "$LOGFB" && git_c init -q -b main)
(cd "$LOGFB/nested/deeper" && env -u CLAUDE_PROJECT_DIR "$HOOKS/adk-log.sh" issue-fb event=start issue=1 >/dev/null 2>&1)
LOGFB_REAL=$(cd "$LOGFB" && pwd -P)
[ -f "$LOGFB_REAL/.adk/logs/issue-fb.jsonl" ]
assert_exit "AC-1: adk-log.sh: git-фолбэк для корня по-прежнему пишет в toplevel/.adk/logs" 0 $?

# Эквивалентность: adk-stats.sh читает тот же git-toplevel/.adk/logs
stats_fb=$(cd "$LOGFB/nested/deeper" && env -u CLAUDE_PROJECT_DIR "$HOOKS/adk-stats.sh" 2>&1)
assert_contains "AC-3: adk-stats.sh: git-фолбэк для корня по-прежнему читает toplevel/.adk/logs" "$stats_fb" "Завершённых задач ещё нет"

# Сознательное решение НЕ унифицировано: заголовок уведомления по-прежнему
# без git-фолбэка (${CLAUDE_PROJECT_DIR:-$PWD}, не adk_project_root —
# docs/adr/002-shared-hook-lib-paths.md). Проверяем поведением, а не грепом
# по исходнику paths.sh (грep по всему файлу ловит и комментарии, а не
# только код — не отличит рефакторинг от фактического снятия правила):
# запускаем notification.sh с cwd = подкаталог git-репо ($GITROOT/sub,
# фикстура выше) и без CLAUDE_PROJECT_DIR. Если бы заголовок резолвился
# через adk_project_root (git-фолбэк на toplevel), title был бы
# "Claude — $(basename "$GITROOT")", а не "Claude — sub".
NOTIFY_TITLE_FILE="$TMP/paths-notify-title"
rm -f "$NOTIFY_TITLE_FILE"
printf '{"message":"x"}' | (cd "$GITROOT/sub" && env -u CLAUDE_PROJECT_DIR ADK_NOTIFY_FILE="$NOTIFY_TITLE_FILE" "$HOOKS/notification.sh")
notify_title_line=$(cat "$NOTIFY_TITLE_FILE" 2>/dev/null)
assert_contains "adk_notify_send: заголовок — basename \$PWD подкаталога (sub), без git-фолбэка на toplevel (ADR-002)" "$notify_title_line" '^Claude — sub|'

stop_test_content=$(cat "$HOOKS/stop-test.sh")
assert_contains "stop-test.sh: правило корня для поиска scripts/test не унифицировано (нет git-фолбэка, как решено в ADR-002)" "$stop_test_content" '\${CLAUDE_PROJECT_DIR:-\$PWD}'
notification_content=$(cat "$HOOKS/notification.sh")
paths_content=$(cat "$PATHS_LIB")

# Дублирующийся резолв notify-send.sh убран из обоих мест — обе точки
# вызова используют общий adk_notify_send из lib/paths.sh.
assert_contains "stop-test.sh: использует общий adk_notify_send вместо дублирующегося резолва пути" "$stop_test_content" 'adk_notify_send'
assert_contains "notification.sh: использует общий adk_notify_send вместо дублирующегося резолва пути" "$notification_content" 'adk_notify_send'

# issue #93: сборка пути состояния уведомлений (agent-dev-kit-notify) убрана
# из вызывающих скриптов — они больше не содержат литерала "agent-dev-kit-notify".
prompt_ts_content=$(cat "$HOOKS/prompt-timestamp.sh")
assert_not_contains "prompt-timestamp.sh: без ручной сборки пути agent-dev-kit-notify — использует adk_notify_state_dir" "$prompt_ts_content" 'agent-dev-kit-notify'
assert_not_contains "stop-test.sh: без ручной сборки пути agent-dev-kit-notify — использует adk_notify_ts_file" "$stop_test_content" 'agent-dev-kit-notify'

# ── Конфиг процесса: lib/config.sh + adk-config.sh (issue #41, AC-1) ────────
# Модель — SPEC-002 (docs/specs/002-process-config.md): плоские атрибуты,
# отсутствие файла/атрибута = его дефолт (docs/config.md — таблица).
CONFIG_LIB="$HOOKS/lib/config.sh"
CONFP="$TMP/configproj"
mkdir -p "$CONFP"

# Нет файла adk.config.json → дефолт, exit 0 (и через lib, и через CLI)
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
assert_exit "AC-1: config.sh: нет файла — adk_config_get завершается успешно" 0 $?
assert_contains "AC-1: config.sh: нет файла — вернулся дефолт" "$out" '^agent-after-approve$'
cli_out=$(CLAUDE_PROJECT_DIR="$CONFP" "$HOOKS/adk-config.sh" policies.merge agent-after-approve)
assert_exit "AC-1: adk-config.sh: нет файла — CLI завершается успешно" 0 $?
assert_contains "AC-1: adk-config.sh: нет файла — CLI вернул дефолт" "$cli_out" '^agent-after-approve$'

# Файл есть, атрибута нет → дефолт
cat > "$CONFP/adk.config.json" <<'EOF'
{"policies": {"merge": "human-only"}}
EOF
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.review.maxRounds 2")
assert_contains "AC-1: config.sh: файл есть, атрибута нет — вернулся дефолт" "$out" '^2$'

# Атрибут задан → его значение (в т.ч. вложенный путь через точку)
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
assert_contains "AC-1: config.sh: атрибут задан — вернулось значение из файла" "$out" '^human-only$'

# Путь уходит глубже, чем есть данных (промежуточный узел — не объект) → дефолт
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge.extra fallback")
assert_contains "AC-1: config.sh: путь глубже данных — вернулся дефолт, не упал" "$out" '^fallback$'

# Битый JSON → дефолт и exit 0 (конфиг не роняет хук)
printf '{broken' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
status=$?
assert_exit "AC-1: config.sh: битый JSON — exit 0, конфиг не роняет хук" 0 "$status"
assert_contains "AC-1: config.sh: битый JSON — вернулся дефолт" "$out" '^agent-after-approve$'

# Неизвестное значение атрибута (не входит в allowed-csv) — дефолт напечатан,
# но откат громкий: exit 1 и предупреждение в stderr, не то же самое, что
# "атрибута нет" (issue #41 DoD — молчаливого разрешения быть не должно).
printf '{"policies": {"merge": "typo-value"}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve agent-after-approve,human-review-required,human-only" 2>"$TMP/config-stderr")
status=$?
assert_exit "AC-1: config.sh: неизвестное значение — exit 1 (не совпадает с 'атрибута нет')" 1 "$status"
assert_contains "AC-1: config.sh: неизвестное значение — на stdout всё равно дефолт (не роняет вызывающего)" "$out" '^agent-after-approve$'
stderr_content=$(cat "$TMP/config-stderr")
assert_contains "AC-1: config.sh: неизвестное значение — предупреждение в stderr, откат не молчаливый" "$stderr_content" "typo-value"

# Известное значение из allowed-csv → возвращается как есть, exit 0
printf '{"policies": {"merge": "human-only"}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve agent-after-approve,human-review-required,human-only")
assert_exit "AC-1: config.sh: значение из allowed-csv — exit 0" 0 $?
assert_contains "AC-1: config.sh: значение из allowed-csv вернулось как есть" "$out" '^human-only$'

# ADK_CONFIG_FILE переопределяет путь к файлу конфига (по образцу ADK_LOGS_DIR)
CUSTOM_CFG="$TMP/custom-adk.config.json"
printf '{"policies": {"merge": "human-review-required"}}' > "$CUSTOM_CFG"
out=$(ADK_CONFIG_FILE="$CUSTOM_CFG" CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
assert_contains "AC-1: config.sh: ADK_CONFIG_FILE переопределяет путь к конфигу" "$out" '^human-review-required$'

# Bool-атрибут печатается строчными true/false — и заданный в файле, и
# взятый как дефолт (issue #41 review: python-репрезентация "True"/"False"
# ломала бы потребителей, сравнивающих строку с "true"/"false").
printf '{"policies": {"autopilot": {"enabled": false}}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.autopilot.enabled true")
assert_contains "AC-1: config.sh: bool-значение из файла — строчное 'false', не 'False'" "$out" '^false$'
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.autopilot.canMerge true")
assert_contains "AC-1: config.sh: bool-дефолт — строчное 'true' (атрибута нет в файле)" "$out" '^true$'

# adk-config.sh без пути атрибута — понятная ошибка использования, не тихий сбой
"$HOOKS/adk-config.sh" >/dev/null 2>"$TMP/config-usage-stderr"
assert_exit "AC-1: adk-config.sh: без аргумента пути — exit 2 (usage)" 2 $?
assert_contains "AC-1: adk-config.sh: без аргумента пути — сообщение usage в stderr" "$(cat "$TMP/config-usage-stderr")" "usage"

# docs/config.md документирует полный плоский набор атрибутов спеки С ИХ
# ДЕФОЛТАМИ (не только имя атрибута) — DoD issue #41. Разбираем таблицу
# markdown (колонки "Атрибут"/"Тип"/"Дефолт"/"Что воспроизводит") и
# сверяем колонку "Дефолт" с ожидаемым значением, чтобы строка без
# дефолта или с неверным дефолтом реально роняла тест.
CONFIG_DOC="$KIT/docs/config.md"
check_config_default() { # check_config_default <атрибут> <ожидаемый_дефолт>
  local attr="$1" expected="$2" actual
  actual=$(python3 -c '
import sys
path, attr = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.startswith("| `" + attr + "`"):
        continue
    protected = line.replace("\\|", "\x00")
    cells = [c.strip() for c in protected.strip("|").split("|")]
    if len(cells) < 3:
        continue
    print(cells[2].strip("`").replace("\x00", "\\|"))
    break
' "$CONFIG_DOC" "$attr")
  if [ "$actual" = "$expected" ]; then
    echo "PASS: AC-1: docs/config.md — $attr документирует дефолт '$expected'"
  else
    echo "FAIL: AC-1: docs/config.md — $attr дефолт в доке '$actual', ожидали '$expected'"
    fails=$((fails + 1))
  fi
}
check_config_default "policies.merge" "agent-after-approve"
check_config_default "policies.review.maxRounds" "2"
check_config_default "policies.review.humanApprovalRequired" "false"
check_config_default "policies.autopilot.enabled" "true"
check_config_default "policies.autopilot.canMerge" "true"
check_config_default "policies.autopilot.maxTasksPerRun" "5"
check_config_default "conventions.squash" "true"
check_config_default "conventions.branchUpdate" "rebase"
check_config_default "conventions.commitStyle" "plain"
check_config_default "conventions.language" "ru"
check_config_default "conventions.branchPattern" "issue-{n}-{slug}"
check_config_default "conventions.attribution" "true"
check_config_default "conventions.externalTitleLint" "false"

for typ in "type:task" "type:bug" "type:fast-follow" "type:consolidate"; do
  check_ac_doc AC-1 "docs/config.md документирует дефолтный тип $typ" "$CONFIG_DOC" "$typ"
done
check_ac_doc AC-1 "docs/config.md документирует поведение при неизвестном значении атрибута (откат не молчаливый)" \
  "$CONFIG_DOC" "молча использует дефолт как ни в чём не бывало"

# Карта дефолтных типов живёт и в таблице docs/config.md, и в python-словаре
# pr-title-check.sh. Инструкции команд сшиты с таблицей doc-тестами выше,
# словарь хука — нет: разъехавшись, он требовал бы один commitType, пока доки
# и /work обещают другой. Сверяем все четыре пары label/commitType.
type_map_diff=$(python3 -c '
import re, sys
doc_path, hook_path = sys.argv[1:3]
doc = {}
for line in open(doc_path, encoding="utf-8"):
    m = re.match(r"^\| `(\w+)` \| `([^`]+)` \| `([^`]+)` \|", line)
    if m:
        doc[m.group(1)] = (m.group(2), m.group(3))
hook = {}
block = re.search(r"^types = \{$(.*?)^\}$", open(hook_path, encoding="utf-8").read(), re.M | re.S)
if block:
    for name, label, ctype in re.findall(
            r"\"(\w+)\": \{\"label\": \"([^\"]+)\", \"commitType\": \"([^\"]+)\"\}", block.group(1)):
        hook[name] = (label, ctype)
for name in ("task", "bug", "fastFollow", "consolidate"):
    d, h = doc.get(name), hook.get(name)
    if d is None or h is None or d != h:
        print("%s: docs/config.md %s, pr-title-check.sh %s;" % (name, d, h))
' "$CONFIG_DOC" "$HOOKS/pr-title-check.sh")
if [ -z "$type_map_diff" ]; then
  echo "PASS: AC-5: карта дефолтных типов docs/config.md совпадает со словарём pr-title-check.sh"
else
  echo "FAIL: AC-5: карта дефолтных типов разошлась — $type_map_diff"
  fails=$((fails + 1))
fi

# ── /project-init заполняет adk.config.json пресетами-ярлыками (issue #42, AC-1) ─
# Пресеты — только наборы готовых ответов в диалоге init (SPEC-002): в файл
# попадают плоские атрибуты из docs/config.md, имя пресета в рантайме не
# существует; существующий конфиг никогда не перезаписывается.
PI_MD="$KIT/commands/project-init.md"

check_ac_doc AC-1 "project-init.md содержит шаг записи adk.config.json (не просто упоминание)" \
  "$PI_MD" "запиши \`adk.config.json\` в корень проекта"
check_ac_doc AC-1 "project-init.md задаёт вопрос о процессе через AskUserQuestion" \
  "$PI_MD" "спроси через AskUserQuestion, как устроен процесс"
for preset in "личный" "командный" "только вручную"; do
  check_ac_doc AC-1 "project-init.md предлагает пресет-ярлык «$preset»" \
    "$PI_MD" "$preset"
done
for merge_val in agent-after-approve human-review-required human-only; do
  check_ac_doc AC-1 "project-init.md сопоставляет пресетам значение policies.merge=$merge_val" \
    "$PI_MD" "$merge_val"
done
for attr in policies.review.humanApprovalRequired policies.autopilot.enabled policies.autopilot.canMerge; do
  check_ac_doc AC-1 "project-init.md задаёт пресетами атрибут $attr" \
    "$PI_MD" "$attr"
done
check_ac_doc AC-1 "project-init.md: явный запрет перезаписи существующего конфига" \
  "$PI_MD" "уже есть — не трогай и не перезаписывай"
check_ac_doc AC-1 "project-init.md: существующий конфиг упоминается в итоговом отчёте" \
  "$PI_MD" "скажи об этом в итоговом отчёте"
check_ac_doc AC-1 "project-init.md: файл создаётся всегда, даже при полностью дефолтном пресете" \
  "$PI_MD" "Файл создавай всегда, даже если все выбранные значения совпадают с дефолтами"
check_ac_doc AC-1 "project-init.md: имя пресета в файл не записывается" \
  "$PI_MD" "имя пресета в файл не записывается"
assert_not_contains "AC-1: project-init.md не пишет поле \"preset\" в конфиг" "$project_init_content" '"preset"'

# конфиг коммитится (разделяемая правда команды) — шаблонный gitignore не
# должен его игнорировать ни литеральной строкой, ни широким паттерном;
# проверяем поведением, через git check-ignore (глобальный excludesFile
# машины отключён, чтобы чужой ~/.gitignore не давал ложный результат)
GICONF="$TMP/gitignore-config"
mkdir -p "$GICONF"
(cd "$GICONF" && git init -q -b main)
cp "$KIT/templates/base/gitignore" "$GICONF/.gitignore"
(cd "$GICONF" && git -c core.excludesFile=/dev/null check-ignore -q adk.config.json)
assert_exit "AC-1: templates/base/gitignore не игнорирует adk.config.json (в отличие от .adk/)" 1 $?

check_ac_doc AC-1 "README отражает adk.config.json в разделе /project-init" \
  "$KIT/README.md" "запишет плоские атрибуты процесса в \`adk.config.json\`"

# ── Производный метод приземления и сервер нового репозитория (issue #48, AC-6) ─
# SPEC-002: серверный метод приземления GitHub — производная пары
# conventions.squash × conventions.branchUpdate, не самостоятельная
# настройка: squash=true → squash-merge; false+rebase → rebase-merge;
# false+merge → merge-commit. Комбинация «rebase-актуализация +
# merge-commit приземление» невыразима сознательно («Решённые вопросы»).
MMP="$TMP/mergemethod"
mkdir -p "$MMP"

check_merge_method() { # check_merge_method <описание> <ожидаемое>
  local out
  out=$(CLAUDE_PROJECT_DIR="$MMP" "$HOOKS/adk-config.sh" --merge-method 2>/dev/null)
  if [ "$out" = "$2" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (вернулось '$out', ожидали '$2')"
    fails=$((fails + 1))
  fi
}

# branchUpdate=merge в фикстуре нарочно: squash=true главнее стиля ветки
printf '{"conventions": {"squash": true, "branchUpdate": "merge"}}' > "$MMP/adk.config.json"
CLAUDE_PROJECT_DIR="$MMP" "$HOOKS/adk-config.sh" --merge-method >/dev/null 2>&1
assert_exit "AC-6: merge-method: вывод завершается успешно" 0 $?
check_merge_method "AC-6: merge-method: squash=true → squash-merge (независимо от branchUpdate)" "squash-merge"

printf '{"conventions": {"squash": false, "branchUpdate": "rebase"}}' > "$MMP/adk.config.json"
check_merge_method "AC-6: merge-method: squash=false + branchUpdate=rebase → rebase-merge" "rebase-merge"

printf '{"conventions": {"squash": false, "branchUpdate": "merge"}}' > "$MMP/adk.config.json"
check_merge_method "AC-6: merge-method: squash=false + branchUpdate=merge → merge-commit" "merge-commit"

# дефолты: squash=true, branchUpdate=rebase (docs/config.md) → squash-merge
rm "$MMP/adk.config.json"
check_merge_method "AC-6: merge-method: без конфига — дефолт squash-merge" "squash-merge"

printf '{"conventions": {"squash": false}}' > "$MMP/adk.config.json"
check_merge_method "AC-6: merge-method: squash=false без branchUpdate — дефолт rebase даёт rebase-merge" "rebase-merge"
rm "$MMP/adk.config.json"

# /project-init для нового репозитория применяет серверные настройки по конфигу
check_ac_doc AC-6 "project-init.md выводит метод приземления через adk-config.sh --merge-method" \
  "$PI_MD" "adk-config.sh --merge-method"
check_ac_doc AC-6 "project-init.md применяет allowed merge methods по производному значению" \
  "$PI_MD" "allow_squash_merge"
check_ac_doc AC-6 "project-init.md включает delete_branch_on_merge" \
  "$PI_MD" "delete_branch_on_merge=true"
check_ac_doc AC-6 "project-init.md настраивает protection по policies (человеческий approve)" \
  "$PI_MD" "required_pull_request_reviews"
check_ac_doc AC-6 "README описывает производный метод приземления в серверном гейте" \
  "$KIT/README.md" "метод приземления, производный от"

# ── /project-init: branch protection — 403, restrictions, дефолтная ветка
# (issue #90, хвост вердиктов ревью PR #63 и PR #65). Три факта из DoD:
# 403 назван наравне с 404 как факт (не сбой инициализации), restrictions:
# null в PUT (GitHub иначе отвечает 422 без всех четырёх верхнеуровневых
# ключей), имя ветки берётся из default_branch в обоих вызовах — не
# зашито литералом main.
check_ac_doc "issue #90" "project-init.md: PUT branch protection несёт restrictions: null" \
  "$PI_MD" "restrictions=null"
check_ac_doc "issue #90" "project-init.md: PUT branch protection берёт ветку из default_branch, не из литерала main" \
  "$PI_MD" "gh api repos/{owner}/{repo} -q .default_branch"
check_ac_doc "issue #90" "project-init.md: PUT branch protection адресуется по <default_branch>, не по main" \
  "$PI_MD" "gh api -X PUT repos/{owner}/{repo}/branches/<default_branch>/protection"
check_ac_doc "issue #90" "project-init.md: 403 на PUT branch protection назван фактом, не сбоем инициализации" \
  "$PI_MD" "Ответ \`403\` на этот вызов — не сбой инициализации"
check_ac_doc "issue #90" "project-init.md: сверка существующего репозитория читает branch protection по default_branch" \
  "$PI_MD" "gh api repos/{owner}/{repo}/branches/<default_branch>/protection"
check_ac_doc "issue #90" "project-init.md: сверка существующего репозитория называет 403 фактом наравне с 404" \
  "$PI_MD" "ответ 403 — под текущими правами доступа к настройкам"
assert_not_contains "issue #90: старая форма — PUT протекции литералом branches/main/protection не матчится" \
  "$project_init_content" 'branches/main/protection'

# ── /project-init генерирует ISSUE_TEMPLATE из блока types (issue #49, AC-6) ─
# SPEC-002: .github/ISSUE_TEMPLATE/* генерируются из types при /project-init —
# люди в команде создают issues в том же формате, что и агенты; иначе /work,
# читающий тип по label и ожидающий обязательные поля типа, их не найдёт.
check_ac_doc AC-6 "project-init.md генерирует .github/ISSUE_TEMPLATE/* из блока types" \
  "$PI_MD" "одному шаблону на каждый тип из \`types.*\`"
check_ac_doc AC-6 "project-init.md читает атрибуты типов через adk-config.sh, а не переписывает из доков" \
  "$PI_MD" "adk-config.sh types.bug.label type:bug"
check_ac_doc AC-6 "project-init.md: имя файла шаблона — имя типа, а не label с двоеточием" \
  "$PI_MD" "имя файла — имя типа"
check_ac_doc AC-6 "project-init.md: name и labels во front matter — из types.<имя>.label" \
  "$PI_MD" "types.<имя>.label"
check_ac_doc AC-6 "project-init.md: тело шаблона — из полей types.<имя>.requiredFields" \
  "$PI_MD" "types.<имя>.requiredFields"
check_ac_doc AC-6 "project-init.md: пустой requiredFields (дефолтный consolidate) — свободная секция, не пустой шаблон" \
  "$PI_MD" "пустой или отсутствующий \`requiredFields\`"
check_ac_doc AC-6 "project-init.md: шаблон bug содержит строку «Сбежал от: <гейт>» (её агрегирует /consolidate)" \
  "$PI_MD" "Сбежал от: <гейт>"

# дефолтный набор типов — перечислены все четыре шаблона с их label'ами
for pair in "task type:task" "bug type:bug" "fastFollow type:fast-follow" \
  "consolidate type:consolidate"; do
  tname="${pair%% *}"
  tlabel="${pair#* }"
  check_ac_doc AC-6 "project-init.md перечисляет дефолтный шаблон $tname с label $tlabel" \
    "$PI_MD" "\`$tname\` (\`$tlabel\`)"
done

# существующее не перезаписывается — принцип спеки
check_ac_doc AC-6 "project-init.md: явный запрет перезаписи существующих шаблонов" \
  "$PI_MD" "Существующие файлы в \`.github/ISSUE_TEMPLATE/\` не перезаписывай"
check_ac_doc AC-6 "project-init.md: о расхождении существующего шаблона с генерируемым сообщается пользователю" \
  "$PI_MD" "сообщи пользователю о расхождении"

# ── /project-init сверяет настройки существующего репозитория (issue #50, AC-6) ─
# SPEC-002: существующее не перезаписывается — в существующем репозитории
# настройки читаются, расхождения с конфигом сообщаются, ничего не меняется.
check_ac_doc AC-6 "project-init.md содержит ветку «существующий репозиторий» (только сверка)" \
  "$PI_MD" "Существующий репозиторий — только сверка"
check_ac_doc AC-6 "project-init.md: ветка сверки читает фактические merge methods и delete_branch_on_merge" \
  "$PI_MD" "прочитай фактические настройки"
check_ac_doc AC-6 "project-init.md: ветка сверки читает branch protection (404 — тоже факт)" \
  "$PI_MD" "404 — protection не настроена"
check_ac_doc AC-6 "project-init.md: ветка сверки проверяет наличие ISSUE_TEMPLATE по типам конфига" \
  "$PI_MD" "наличие файлов \`.github/ISSUE_TEMPLATE/\` по типам"
check_ac_doc AC-6 "project-init.md: расхождения выводятся парой «ожидается по конфигу / фактически»" \
  "$PI_MD" "ожидается по конфигу / фактически"
check_ac_doc AC-6 "project-init.md: явный запрет изменяющих вызовов в ветке существующего репозитория" \
  "$PI_MD" "запрещён любой изменяющий вызов \`gh api\`"
check_ac_doc AC-6 "project-init.md: расхождение — не ошибка, команда завершается успешно" \
  "$PI_MD" "расхождение — не ошибка инициализации"
# применение настроек привязано только к новому репозиторию
check_ac_doc AC-6 "project-init.md: ветка применения настроек названа веткой нового репозитория" \
  "$PI_MD" "Новый репозиторий — применяем настройки"
check_ac_doc AC-6 "project-init.md: серверные настройки применяются сразу после создания remote (новый репозиторий)" \
  "$PI_MD" "Сразу после создания remote настрой сервер по конфигу"

# ── Итог ─────────────────────────────────────────────────────────────────────
echo "─────"
if [ "$fails" -eq 0 ]; then
  echo "Все тесты прошли."
  exit 0
else
  echo "Провалено тестов: $fails"
  exit 1
fi
