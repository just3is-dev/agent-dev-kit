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

assert_contains() { # assert_contains <описание> <текст> <подстрока>
  if printf '%s' "$2" | grep -q -- "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (не найдено: $3)"
    fails=$((fails + 1))
  fi
}

assert_not_contains() { # assert_not_contains <описание> <текст> <подстрока>
  if printf '%s' "$2" | grep -q -- "$3"; then
    echo "FAIL: $1 (неожиданно найдено: $3)"
    fails=$((fails + 1))
  else
    echo "PASS: $1"
  fi
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
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-only — merge ready-PR блокируется" 2 $?

printf '{"policies": {"merge": "human-review-required"}}' > "$P/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready ADK_GUARD_PR_REVIEW_DECISION=REVIEW_REQUIRED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-review-required — блок без человеческого approve" 2 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready ADK_GUARD_PR_REVIEW_DECISION=APPROVED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-review-required — merge разрешён при reviewDecision=APPROVED" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=draft ADK_GUARD_PR_REVIEW_DECISION=APPROVED CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=human-review-required — draft блокируется даже с approve" 2 $?

printf '{"policies": {"merge": "agent-after-approve"}}' > "$P/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=agent-after-approve — merge ready-PR разрешён (как без конфига)" 0 $?
printf '{"tool_input":{"command":"gh pr merge 5 --squash"}}' | ADK_GUARD_PR_STATE=draft CLAUDE_PROJECT_DIR="$P" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: policies.merge=agent-after-approve — draft блокируется (как без конфига)" 2 $?

# Конфиг ищется от репозитория команды, а не от корня сессии: в
# мульти-директорной сессии CLAUDE_PROJECT_DIR может указывать вне проекта
printf '{"policies": {"merge": "human-only"}}' > "$P/adk.config.json"
printf '{"tool_input":{"command":"gh pr merge 5"},"cwd":"%s"}' "$P" | ADK_GUARD_PR_STATE=ready CLAUDE_PROJECT_DIR="$TMP" "$HOOKS/bash-guard.sh" >/dev/null 2>&1
assert_exit "AC-2: human-only действует и при корне сессии вне проекта (конфиг от репозитория команды)" 2 $?
rm "$P/adk.config.json"

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

# ── Уведомления ──────────────────────────────────────────────────────────────
NDIR="$TMP/tmpdir/agent-dev-kit-notify"
mkdir -p "$TMP/tmpdir"
NFILE="$TMP/notifications.log"

printf '{"session_id":"sid1"}' | TMPDIR="$TMP/tmpdir" "$HOOKS/prompt-timestamp.sh"
if [ -f "$NDIR/sid1" ] && grep -Eq '^[0-9]+$' "$NDIR/sid1"; then
  echo "PASS: prompt-timestamp: время начала хода записано"
else
  echo "FAIL: prompt-timestamp: файл с меткой не создан"
  fails=$((fails + 1))
fi

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
if [ -f "$NFILE" ]; then
  echo "FAIL: stop-test: короткий ход не должен порождать уведомление"
  fails=$((fails + 1))
else
  echo "PASS: stop-test: короткий ход — без уведомления"
fi

# stop-test: провал тестов → БЕЗ уведомления «завершено» (работа продолжается)
# правка файла инвалидирует кэш успешного прогона (.fail-tests гитигнорится и хэш не меняет)
echo "// change" >> "$P/src/config.ts"
touch "$P/.fail-tests"
echo $(( $(date +%s) - 100 )) > "$NDIR/sid4"
rm -f "$NFILE"
printf '{"session_id":"sid4"}' | TMPDIR="$TMP/tmpdir" ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
st=$?
rm "$P/.fail-tests"
if [ "$st" -eq 2 ] && [ ! -f "$NFILE" ]; then
  echo "PASS: stop-test: красные тесты — блок без уведомления о завершении"
else
  echo "FAIL: stop-test: при красных тестах exit=$st, уведомление: $([ -f "$NFILE" ] && echo да || echo нет)"
  fails=$((fails + 1))
fi

# ── Журнал (adk-log.sh) ──────────────────────────────────────────────────────
LOGP="$TMP/logproj"
mkdir -p "$LOGP"
(cd "$LOGP" && git init -q -b main)

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=start issue=1 >/dev/null 2>&1
assert_exit "AC-1: adk-log: запись под дефолтным путём завершается успешно" 0 $?
if [ -f "$LOGP/.adk/logs/issue-1.jsonl" ]; then
  echo "PASS: AC-1: adk-log: запись создаёт файл в .adk/logs/"
else
  echo "FAIL: AC-1: adk-log: файл .adk/logs/issue-1.jsonl не создан"
  fails=$((fails + 1))
fi

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=review verdict=APPROVE >/dev/null 2>&1
lines=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
assert_exit "AC-1: adk-log: повторная запись дописывает вторую строку, не трёт первую" 2 "$lines"
first_event=$(sed -n '1p' "$LOGP/.adk/logs/issue-1.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("event",""))' 2>/dev/null)
if [ "$first_event" = "start" ]; then
  echo "PASS: AC-1: adk-log: первая строка не перезаписана вторым событием"
else
  echo "FAIL: AC-1: adk-log: первая строка изменилась (event=$first_event)"
  fails=$((fails + 1))
fi

valid=$(jsonl_check "$LOGP/.adk/logs/issue-1.jsonl" 2 "$(printf 'event?\nevent?')")
assert_exit "AC-1: adk-log: каждая строка — валидный JSON с timestamp и полями" 1 "$valid"

before_badpair=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event badpair >/dev/null 2>&1
assert_exit "AC-1: adk-log: аргумент без '=' отклоняется с ошибкой" 1 $?
after_badpair=$(count_lines "$LOGP/.adk/logs/issue-1.jsonl")
assert_exit "AC-1: adk-log: отклонённый аргумент не пишет строку в журнал" "$before_badpair" "$after_badpair"

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=spoof timestamp=bogus >/dev/null 2>&1
last_ts=$(tail -n1 "$LOGP/.adk/logs/issue-1.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("timestamp",""))')
if [ "$last_ts" = "bogus" ]; then
  echo "FAIL: AC-1: adk-log: переданное поле timestamp затёрло служебное"
  fails=$((fails + 1))
else
  echo "PASS: AC-1: adk-log: служебный timestamp не подменяется переданным полем"
fi

CUSTOM="$TMP/customlogs"
rm -rf "$CUSTOM"
ADK_LOGS_DIR="$CUSTOM" CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" autopilot-2026-08-07 event=run_start >/dev/null 2>&1
if [ -f "$CUSTOM/autopilot-2026-08-07.jsonl" ] && [ ! -f "$LOGP/.adk/logs/autopilot-2026-08-07.jsonl" ]; then
  echo "PASS: AC-1: adk-log: ADK_LOGS_DIR переопределяет путь"
else
  echo "FAIL: AC-1: adk-log: ADK_LOGS_DIR не переопределил путь"
  fails=$((fails + 1))
fi

gi_content=$(cat "$LOGP/.adk/.gitignore" 2>/dev/null)
if [ "$gi_content" = "*" ]; then
  echo "PASS: AC-1: adk-log: .adk/.gitignore создан с содержимым *"
else
  echo "FAIL: AC-1: adk-log: .adk/.gitignore отсутствует или содержит не *"
  fails=$((fails + 1))
fi

adk_status=$(cd "$LOGP" && git status --porcelain -- .adk 2>/dev/null)
if [ -z "$adk_status" ]; then
  echo "PASS: AC-1: adk-log: git status пуст для .adk/ (самоигнорирующаяся папка)"
else
  echo "FAIL: AC-1: adk-log: .adk/ виден git status: $adk_status"
  fails=$((fails + 1))
fi

CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event=merge >/dev/null 2>&1
gi_lines_after=$(count_lines "$LOGP/.adk/.gitignore")
assert_exit "AC-1: adk-log: повторная запись не дублирует .adk/.gitignore" 1 "$gi_lines_after"

if grep -qx '\.adk/' "$KIT/templates/base/gitignore"; then
  echo "PASS: AC-1: adk-log: templates/base/gitignore содержит .adk/"
else
  echo "FAIL: AC-1: adk-log: templates/base/gitignore не содержит .adk/"
  fails=$((fails + 1))
fi

# ── Сводка по журналу (adk-stats.sh, AC-3) ───────────────────────────────────
# Схема событий — ADR-001 (docs/adr/001-journal-event-schema.md).

# пустой каталог журнала — exit 0, сообщение, без выдуманных цифр
STATS_EMPTY="$TMP/stats-empty"
mkdir -p "$STATS_EMPTY"
stats_out=$(ADK_LOGS_DIR="$STATS_EMPTY" "$HOOKS/adk-stats.sh" 2>&1)
stats_st=$?
assert_exit "AC-3: adk-stats: пустой каталог журнала — exit 0" 0 "$stats_st"
if printf '%s' "$stats_out" | grep -qi "пуст"; then
  echo "PASS: AC-3: adk-stats: пустой каталог — сообщение об отсутствии записей"
else
  echo "FAIL: AC-3: adk-stats: нет сообщения о пустом журнале: $stats_out"
  fails=$((fails + 1))
fi
assert_not_contains "AC-3: adk-stats: пустой журнал не выдумывает агрегаты" "$stats_out" "Всего задач"

# каталог журнала вовсе не существует — тоже exit 0 с сообщением, не падение
stats_out=$(ADK_LOGS_DIR="$TMP/stats-missing" "$HOOKS/adk-stats.sh" 2>&1)
assert_exit "AC-3: adk-stats: несуществующий каталог журнала — exit 0" 0 $?
if printf '%s' "$stats_out" | grep -qi "пуст"; then
  echo "PASS: AC-3: adk-stats: несуществующий каталог — сообщение, не трейсбек"
else
  echo "FAIL: AC-3: adk-stats: несуществующий каталог не даёт понятного сообщения: $stats_out"
  fails=$((fails + 1))
fi

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
if printf '%s' "$stats_out" | grep -qi "нет ни одной задачи" && printf '%s' "$stats_out" | grep -qi "autopilot"; then
  echo "PASS: AC-3: adk-stats: сообщение честно отличает 'нет issue-записей' от 'журнал пуст'"
else
  echo "FAIL: AC-3: adk-stats: сообщение для каталога только с autopilot-файлом неинформативно: $stats_out"
  fails=$((fails + 1))
fi

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
if printf '%s' "$stats_out" | grep -q "В работе" && printf '%s' "$stats_out" | grep -q "1"; then
  echo "PASS: AC-3: adk-stats: незавершённая задача показана как «в работе»"
else
  echo "FAIL: AC-3: adk-stats: количество задач в работе не отражено в выводе: $stats_out"
  fails=$((fails + 1))
fi

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
if [ "$warn_lines" -ge 2 ]; then
  echo "PASS: AC-3: adk-stats: оба вида битой строки (не-JSON и JSON-не-объект) порождают предупреждения"
else
  echo "FAIL: AC-3: adk-stats: ожидали 2+ предупреждения про issue-12, получили $warn_lines: $stats_err"
  fails=$((fails + 1))
fi

assert_contains "AC-3: adk-stats: всего задач — 3 завершённые (issue-13 без итога и autopilot-файл не задваивают)" "$stats_out" "Всего задач: 3"

assert_contains "AC-3: adk-stats: незавершённая задача (issue-13, без outcome) показана отдельно, не искажает агрегаты" "$stats_out" "В работе (без итога, в агрегаты ниже не входят): 1"

assert_contains "AC-3: adk-stats: средние круги ревью посчитаны верно ((2+1+2)/3 = 1.7, issue-13 не в счёте)" "$stats_out" "Средние круги ревью: 1\.7"

if printf '%s' "$stats_out" | grep -q "33%" && printf '%s' "$stats_out" | grep -q "1/3"; then
  echo "PASS: AC-3: adk-stats: доля застреваний — 33% (1/3)"
else
  echo "FAIL: AC-3: adk-stats: доля застреваний не совпадает с ожиданием: $stats_out"
  fails=$((fails + 1))
fi

assert_contains "AC-3: adk-stats: причина застревания названа в выводе" "$stats_out" "ревьюер второй круг подряд REQUEST_CHANGES"

if printf '%s' "$stats_out" | grep -q "2026-W31" && printf '%s' "$stats_out" | grep -q "2026-W32"; then
  echo "PASS: AC-3: adk-stats: динамика по неделям показывает обе недели фикстуры"
else
  echo "FAIL: AC-3: adk-stats: динамика по неделям не найдена: $stats_out"
  fails=$((fails + 1))
fi

# команда /stats существует и обращается к скрипту агрегации, интерпретирует
# пустой журнал явно, не выдумывая цифры
if [ -f "$KIT/commands/stats.md" ]; then
  echo "PASS: AC-3: commands/stats.md существует"
else
  echo "FAIL: AC-3: commands/stats.md отсутствует"
  fails=$((fails + 1))
fi
if tr '\n' ' ' < "$KIT/commands/stats.md" | tr -s ' ' | grep -qF "hooks/scripts/adk-stats.sh"; then
  echo "PASS: AC-3: commands/stats.md вызывает hooks/scripts/adk-stats.sh"
else
  echo "FAIL: AC-3: commands/stats.md не упоминает hooks/scripts/adk-stats.sh"
  fails=$((fails + 1))
fi
if tr '\n' ' ' < "$KIT/commands/stats.md" | tr -s ' ' | grep -qF "не выдумывай"; then
  echo "PASS: AC-3: commands/stats.md: пустой журнал — не выдумывать цифры"
else
  echo "FAIL: AC-3: commands/stats.md не содержит правило не выдумывать цифры при пустом журнале"
  fails=$((fails + 1))
fi

# ── /work: события журнала (AC-1) ────────────────────────────────────────────
WORKMD="$KIT/commands/work.md"
step1=$(sed -n '/^1\. \*\*/,/^2\. \*\*/p' "$WORKMD" | tr '\n' ' ' | tr -s ' ')
step6=$(sed -n '/^6\. \*\*/,/^7\. \*\*/p' "$WORKMD" | tr '\n' ' ' | tr -s ' ')
step7=$(sed -n '/^7\. \*\*/,$p' "$WORKMD" | tr '\n' ' ' | tr -s ' ')

assert_contains "AC-1: work.md шаг 1 логирует event=start" "$step1" 'adk-log\.sh.*event=start'

assert_contains "AC-1: work.md шаг 6 логирует event=review после каждого вердикта" "$step6" 'adk-log\.sh.*event=review'

assert_contains "AC-1: work.md шаг 7 логирует event=outcome (схема ADR-001)" "$step7" 'adk-log\.sh.*event=outcome'

assert_contains "AC-1: work.md шаг 7 пишет result=merged|stuck (не outcome=ready, issue #21)" "$step7" 'result=<merged|stuck>'

assert_contains "AC-1: work.md шаг 7 считает размер диффа git diff main... --shortstat" "$step7" 'git diff main\.\.\. --shortstat'

assert_contains "AC-1: work.md шаг 7 пишет diff= (не diffstat=, issue #21)" "$step7" 'diff='

for step_name in step1 step6 step7; do
  step_text=$(eval "printf '%s' \"\$$step_name\"")
  assert_contains "AC-1: work.md $step_name — запись в журнал не блокирует задачу (|| true)" "$step_text" 'adk-log\.sh.*|| true'
done

assert_contains "AC-1: work.md шаг 7 — reason закавычен (причина может содержать пробелы)" "$step7" 'reason="'

# ── SPEC-002 AC-2: формулировки отчётов соответствуют политике merge ─────────
# Третий (мягкий) слой enforcement: при политиках с обязательным человеком
# отчёт не обещает merge, а формулируется как «PR готов к ревью коллеги».
assert_contains "AC-2: work.md шаг 7 сверяет формулировку отчёта с policies.merge" "$step7" 'policies\.merge'
assert_contains "AC-2: work.md шаг 7 — при human-политиках отчёт «PR готов к ревью коллеги», не «смержено»" "$step7" 'готов к ревью коллеги'
autopilot_text=$(tr '\n' ' ' < "$KIT/commands/autopilot.md" | tr -s ' ')
assert_contains "AC-2: autopilot.md сверяет формулировку сводки с policies.merge" "$autopilot_text" 'policies\.merge'
assert_contains "AC-2: autopilot.md — при human-политиках сводка «PR готов к ревью коллеги», не «смержено»" "$autopilot_text" 'готов к ревью коллеги'

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
if [ "$stuck_reason" = "тесты не проходят" ]; then
  echo "PASS: AC-1: work.md-смоук: причина застревания сохраняется целиком, с пробелами"
else
  echo "FAIL: AC-1: work.md-смоук: причина застревания искажена или потеряна (reason=$stuck_reason)"
  fails=$((fails + 1))
fi

stuck_stats_out=$(ADK_LOGS_DIR="$WORKP2/.adk/logs" "$HOOKS/adk-stats.sh" 2>&1)
assert_contains "AC-1: work.md-смоук: adk-stats.sh на журнале с result=stuck считает застревание и называет причину (issue #21)" "$stuck_stats_out" "тесты не проходят"

# ── /autopilot: события журнала (AC-2) ───────────────────────────────────────
AUTOMD="$KIT/commands/autopilot.md"
cycle_preamble=$(sed -n '/^## Цикл/,/^1\. \*\*/p' "$AUTOMD" | tr '\n' ' ' | tr -s ' ')
step3=$(sed -n '/^3\. \*\*/,/^4\. \*\*/p' "$AUTOMD" | tr '\n' ' ' | tr -s ' ')
finish_section=$(sed -n '/^## Завершение/,$p' "$AUTOMD" | tr '\n' ' ' | tr -s ' ')

assert_contains "AC-2: autopilot.md логирует event=run_start перед циклом (issue #21: раньше не логировался вовсе)" "$cycle_preamble" 'adk-log\.sh.*event=run_start'

assert_contains "AC-2: autopilot.md шаг 3 логирует event=task на каждую разобранную задачу" "$step3" 'adk-log\.sh.*event=task'

assert_contains "AC-2: autopilot.md «Завершение» логирует event=run_end (не run_finish, issue #21)" "$finish_section" 'adk-log\.sh.*event=run_end'

for outcome_kind in 'result=merged' 'result=stuck' 'result=skipped'; do
  if printf '%s' "$step3" | grep -qF "$outcome_kind"; then
    echo "PASS: AC-2: autopilot.md шаг 3 покрывает исход «$outcome_kind»"
  else
    echo "FAIL: AC-2: autopilot.md шаг 3 не упоминает исход «$outcome_kind»"
    fails=$((fails + 1))
  fi
done

for agg_field in done= stuck= skipped=; do
  if printf '%s' "$finish_section" | grep -qF "$agg_field"; then
    echo "PASS: AC-2: autopilot.md «Завершение» пишет агрегат «$agg_field»"
  else
    echo "FAIL: AC-2: autopilot.md «Завершение» не пишет агрегат «$agg_field»"
    fails=$((fails + 1))
  fi
done

for section_name in cycle_preamble step3 finish_section; do
  section_text=$(eval "printf '%s' \"\$$section_name\"")
  assert_contains "AC-2: autopilot.md $section_name — запись в журнал не блокирует прогон (|| true)" "$section_text" 'adk-log\.sh.*|| true'
done

assert_contains "AC-2: autopilot.md шаг 3 пишет в единицу autopilot-<дата>" "$step3" 'autopilot-\$(date'

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
if [ "$calls" = "web-check:1" ]; then
  echo "PASS: монорепа check: вызван только пакет web"
else
  echo "FAIL: монорепа check: ожидали только web-check, вызовы: $calls"
  fails=$((fails + 1))
fi

rm -f "$M/.calls"
(cd "$M" && ./scripts/check >/dev/null 2>&1)
assert_exit "монорепа check: без аргументов проходит" 0 $?
npkgs=$(count_lines "$M/.calls")
assert_exit "монорепа check: без аргументов вызваны оба пакета, не $npkgs" 2 "$npkgs"

rm -f "$M/.calls"
(cd "$M" && ./scripts/check README.md >/dev/null 2>&1)
assert_exit "монорепа check: корневой файл вне пакетов проходит" 0 $?
[ -f "$M/.calls" ] && { echo "FAIL: монорепа check: корневой файл не должен звать пакеты"; fails=$((fails + 1)); } \
  || echo "PASS: монорепа check: корневой файл не зовёт пакеты"

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
for t in nextjs nestjs python-service monorepo; do
  check_content=$(cat "$KIT/templates/$t/scripts/check")
  assert_contains "AC-4: templates/$t/scripts/check содержит вызов ac-check в полном прогоне" "$check_content" 'scripts/ac-check'
done

project_init_content=$(cat "$KIT/commands/project-init.md")
assert_contains "AC-4: project-init.md содержит шаг копирования ac-check.sh в scripts/ac-check" "$project_init_content" 'scripts/ac-check'

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
  local block_start block_end guard_out guard_st GUARD
  block_start=$(grep -n '^# ── AC-трассируемость' "$KIT/tests/run.sh" | head -1 | cut -d: -f1)
  block_end=$(grep -n '^# ── Конвенция AC-тегирования' "$KIT/tests/run.sh" | head -1 | cut -d: -f1)
  if [ -z "${block_start:-}" ] || [ -z "${block_end:-}" ] || [ "$block_end" -le "$block_start" ]; then
    echo "FAIL: AC-4: тест-страж: заголовки диапазона AC-4-тестов найдены и упорядочены (block_start=$block_start block_end=$block_end)"
    fails=$((fails + 1))
    return
  fi
  echo "PASS: AC-4: тест-страж: заголовки диапазона AC-4-тестов найдены и упорядочены"
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
if [ "$out" = "/explicit/root" ]; then
  echo "PASS: AC-1: paths.sh: adk_project_root вернул явно заданный CLAUDE_PROJECT_DIR"
else
  echo "FAIL: AC-1: paths.sh: adk_project_root вернул '$out' вместо /explicit/root"
  fails=$((fails + 1))
fi

# adk_project_root: CLAUDE_PROJECT_DIR не задан, cwd внутри git-репо — git-фолбэк
GITROOT="$TMP/paths-gitroot"
mkdir -p "$GITROOT/sub"
(cd "$GITROOT" && git_c init -q -b main)
out=$(cd "$GITROOT/sub" && env -u CLAUDE_PROJECT_DIR bash -c ". '$PATHS_LIB'; adk_project_root")
GITROOT_REAL=$(cd "$GITROOT" && pwd -P)
if [ "$out" = "$GITROOT_REAL" ]; then
  echo "PASS: AC-1: paths.sh: adk_project_root — git-фолбэк находит toplevel из подкаталога"
else
  echo "FAIL: AC-1: paths.sh: adk_project_root git-фолбэк вернул '$out', ожидали '$GITROOT_REAL'"
  fails=$((fails + 1))
fi

# adk_project_root: ни CLAUDE_PROJECT_DIR, ни git — $PWD
NOTGIT="$TMP/paths-notgit"
mkdir -p "$NOTGIT"
out=$(cd "$NOTGIT" && env -u CLAUDE_PROJECT_DIR bash -c ". '$PATHS_LIB'; adk_project_root")
# логический $PWD (без -P): скрипт использует голый "$PWD" как последний
# фолбэк, не резолвя симлинки, поэтому и здесь сравниваем без резолва.
NOTGIT_REAL=$(cd "$NOTGIT" && pwd)
if [ "$out" = "$NOTGIT_REAL" ]; then
  echo "PASS: AC-1: paths.sh: adk_project_root — без git и без CLAUDE_PROJECT_DIR отдаёт \$PWD"
else
  echo "FAIL: AC-1: paths.sh: adk_project_root вне git вернул '$out', ожидали '$NOTGIT_REAL'"
  fails=$((fails + 1))
fi

# adk_logs_dir: ADK_LOGS_DIR переопределяет, иначе <root>/.adk/logs
out=$(ADK_LOGS_DIR="/custom/logs" bash -c ". '$PATHS_LIB'; adk_logs_dir /some/root")
if [ "$out" = "/custom/logs" ]; then
  echo "PASS: AC-1: paths.sh: adk_logs_dir уважает ADK_LOGS_DIR"
else
  echo "FAIL: AC-1: paths.sh: adk_logs_dir вернул '$out' вместо /custom/logs"
  fails=$((fails + 1))
fi
out=$(env -u ADK_LOGS_DIR bash -c ". '$PATHS_LIB'; adk_logs_dir /some/root")
if [ "$out" = "/some/root/.adk/logs" ]; then
  echo "PASS: AC-1: paths.sh: adk_logs_dir по умолчанию — <root>/.adk/logs"
else
  echo "FAIL: AC-1: paths.sh: adk_logs_dir без ADK_LOGS_DIR вернул '$out'"
  fails=$((fails + 1))
fi

# Эквивалентность: adk-log.sh пишет в git-toplevel/.adk/logs, если
# CLAUDE_PROJECT_DIR не задан, а cwd — вложенный подкаталог git-репо
# (до переноса в lib/paths.sh это поведение обеспечивалось инлайновым
# блоком; сейчас — общей adk_project_root()).
LOGFB="$TMP/paths-logfallback"
mkdir -p "$LOGFB/nested/deeper"
(cd "$LOGFB" && git_c init -q -b main)
(cd "$LOGFB/nested/deeper" && env -u CLAUDE_PROJECT_DIR "$HOOKS/adk-log.sh" issue-fb event=start issue=1 >/dev/null 2>&1)
LOGFB_REAL=$(cd "$LOGFB" && pwd -P)
if [ -f "$LOGFB_REAL/.adk/logs/issue-fb.jsonl" ]; then
  echo "PASS: AC-1: adk-log.sh: git-фолбэк для корня по-прежнему пишет в toplevel/.adk/logs"
else
  echo "FAIL: AC-1: adk-log.sh: git-фолбэк не сработал — файл не найден в $LOGFB_REAL/.adk/logs"
  fails=$((fails + 1))
fi

# Эквивалентность: adk-stats.sh читает тот же git-toplevel/.adk/logs
stats_fb=$(cd "$LOGFB/nested/deeper" && env -u CLAUDE_PROJECT_DIR "$HOOKS/adk-stats.sh" 2>&1)
assert_contains "AC-3: adk-stats.sh: git-фолбэк для корня по-прежнему читает toplevel/.adk/logs" "$stats_fb" "Завершённых задач ещё нет"

# Сознательное решение НЕ унифицировано: stop-test.sh/notification.sh
# по-прежнему используют ${CLAUDE_PROJECT_DIR:-$PWD} без git-фолбэка
# (docs/adr/002-shared-hook-lib-paths.md) — проверяем исходники напрямую,
# так как поведенческий тест «без CLAUDE_PROJECT_DIR» для stop-test.sh
# требует cwd = корень проекта с исполняемым scripts/test, что здесь не
# создаётся отдельно.
stop_test_content=$(cat "$HOOKS/stop-test.sh")
assert_contains "stop-test.sh: правило корня не унифицировано (нет git-фолбэка, как решено в ADR-002)" "$stop_test_content" '\${CLAUDE_PROJECT_DIR:-\$PWD}'
notification_content=$(cat "$HOOKS/notification.sh")
assert_contains "notification.sh: правило корня не унифицировано (нет git-фолбэка, как решено в ADR-002)" "$notification_content" '\${CLAUDE_PROJECT_DIR:-\$PWD}'

# Дублирующийся резолв notify-send.sh убран из обоих мест — обе точки
# вызова используют общий adk_notify_send из lib/paths.sh.
if grep -q 'adk_notify_send' "$HOOKS/stop-test.sh" && grep -q 'adk_notify_send' "$HOOKS/notification.sh"; then
  echo "PASS: stop-test.sh/notification.sh: используют общий adk_notify_send вместо дублирующегося резолва пути"
else
  echo "FAIL: stop-test.sh/notification.sh: не используют общий adk_notify_send"
  fails=$((fails + 1))
fi

# ── Конфиг процесса: lib/config.sh + adk-config.sh (issue #41, AC-1) ────────
# Модель — SPEC-002 (docs/specs/002-process-config.md): плоские атрибуты,
# отсутствие файла/атрибута = его дефолт (docs/config.md — таблица).
CONFIG_LIB="$HOOKS/lib/config.sh"
CONFP="$TMP/configproj"
mkdir -p "$CONFP"

# Нет файла adk.config.json → дефолт, exit 0 (и через lib, и через CLI)
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
assert_exit "AC-1: config.sh: нет файла — adk_config_get завершается успешно" 0 $?
if [ "$out" = "agent-after-approve" ]; then
  echo "PASS: AC-1: config.sh: нет файла — вернулся дефолт"
else
  echo "FAIL: AC-1: config.sh: нет файла — вернулось '$out' вместо дефолта"
  fails=$((fails + 1))
fi
cli_out=$(CLAUDE_PROJECT_DIR="$CONFP" "$HOOKS/adk-config.sh" policies.merge agent-after-approve)
assert_exit "AC-1: adk-config.sh: нет файла — CLI завершается успешно" 0 $?
if [ "$cli_out" = "agent-after-approve" ]; then
  echo "PASS: AC-1: adk-config.sh: нет файла — CLI вернул дефолт"
else
  echo "FAIL: AC-1: adk-config.sh: нет файла — CLI вернул '$cli_out' вместо дефолта"
  fails=$((fails + 1))
fi

# Файл есть, атрибута нет → дефолт
cat > "$CONFP/adk.config.json" <<'EOF'
{"policies": {"merge": "human-only"}}
EOF
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.review.maxRounds 2")
if [ "$out" = "2" ]; then
  echo "PASS: AC-1: config.sh: файл есть, атрибута нет — вернулся дефолт"
else
  echo "FAIL: AC-1: config.sh: файл есть, атрибута нет — вернулось '$out' вместо дефолта"
  fails=$((fails + 1))
fi

# Атрибут задан → его значение (в т.ч. вложенный путь через точку)
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
if [ "$out" = "human-only" ]; then
  echo "PASS: AC-1: config.sh: атрибут задан — вернулось значение из файла"
else
  echo "FAIL: AC-1: config.sh: атрибут задан — вернулось '$out' вместо human-only"
  fails=$((fails + 1))
fi

# Путь уходит глубже, чем есть данных (промежуточный узел — не объект) → дефолт
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge.extra fallback")
if [ "$out" = "fallback" ]; then
  echo "PASS: AC-1: config.sh: путь глубже данных — вернулся дефолт, не упал"
else
  echo "FAIL: AC-1: config.sh: путь глубже данных — вернулось '$out' вместо дефолта"
  fails=$((fails + 1))
fi

# Битый JSON → дефолт и exit 0 (конфиг не роняет хук)
printf '{broken' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
status=$?
assert_exit "AC-1: config.sh: битый JSON — exit 0, конфиг не роняет хук" 0 "$status"
if [ "$out" = "agent-after-approve" ]; then
  echo "PASS: AC-1: config.sh: битый JSON — вернулся дефолт"
else
  echo "FAIL: AC-1: config.sh: битый JSON — вернулось '$out' вместо дефолта"
  fails=$((fails + 1))
fi

# Неизвестное значение атрибута (не входит в allowed-csv) — дефолт напечатан,
# но откат громкий: exit 1 и предупреждение в stderr, не то же самое, что
# "атрибута нет" (issue #41 DoD — молчаливого разрешения быть не должно).
printf '{"policies": {"merge": "typo-value"}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve agent-after-approve,human-review-required,human-only" 2>"$TMP/config-stderr")
status=$?
assert_exit "AC-1: config.sh: неизвестное значение — exit 1 (не совпадает с 'атрибута нет')" 1 "$status"
if [ "$out" = "agent-after-approve" ]; then
  echo "PASS: AC-1: config.sh: неизвестное значение — на stdout всё равно дефолт (не роняет вызывающего)"
else
  echo "FAIL: AC-1: config.sh: неизвестное значение — вернулось '$out' вместо дефолта"
  fails=$((fails + 1))
fi
stderr_content=$(cat "$TMP/config-stderr")
assert_contains "AC-1: config.sh: неизвестное значение — предупреждение в stderr, откат не молчаливый" "$stderr_content" "typo-value"

# Известное значение из allowed-csv → возвращается как есть, exit 0
printf '{"policies": {"merge": "human-only"}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve agent-after-approve,human-review-required,human-only")
assert_exit "AC-1: config.sh: значение из allowed-csv — exit 0" 0 $?
if [ "$out" = "human-only" ]; then
  echo "PASS: AC-1: config.sh: значение из allowed-csv вернулось как есть"
else
  echo "FAIL: AC-1: config.sh: значение из allowed-csv вернулось '$out' вместо human-only"
  fails=$((fails + 1))
fi

# ADK_CONFIG_FILE переопределяет путь к файлу конфига (по образцу ADK_LOGS_DIR)
CUSTOM_CFG="$TMP/custom-adk.config.json"
printf '{"policies": {"merge": "human-review-required"}}' > "$CUSTOM_CFG"
out=$(ADK_CONFIG_FILE="$CUSTOM_CFG" CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.merge agent-after-approve")
if [ "$out" = "human-review-required" ]; then
  echo "PASS: AC-1: config.sh: ADK_CONFIG_FILE переопределяет путь к конфигу"
else
  echo "FAIL: AC-1: config.sh: ADK_CONFIG_FILE не переопределил путь (вернулось '$out')"
  fails=$((fails + 1))
fi

# Bool-атрибут печатается строчными true/false — и заданный в файле, и
# взятый как дефолт (issue #41 review: python-репрезентация "True"/"False"
# ломала бы потребителей, сравнивающих строку с "true"/"false").
printf '{"policies": {"autopilot": {"enabled": false}}}' > "$CONFP/adk.config.json"
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.autopilot.enabled true")
if [ "$out" = "false" ]; then
  echo "PASS: AC-1: config.sh: bool-значение из файла — строчное 'false', не 'False'"
else
  echo "FAIL: AC-1: config.sh: bool-значение из файла — вернулось '$out' вместо 'false'"
  fails=$((fails + 1))
fi
out=$(CLAUDE_PROJECT_DIR="$CONFP" bash -c ". '$CONFIG_LIB'; adk_config_get policies.autopilot.canMerge true")
if [ "$out" = "true" ]; then
  echo "PASS: AC-1: config.sh: bool-дефолт — строчное 'true' (атрибута нет в файле)"
else
  echo "FAIL: AC-1: config.sh: bool-дефолт — вернулось '$out' вместо 'true'"
  fails=$((fails + 1))
fi

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

# ── Итог ─────────────────────────────────────────────────────────────────────
echo "─────"
if [ "$fails" -eq 0 ]; then
  echo "Все тесты прошли."
  exit 0
else
  echo "Провалено тестов: $fails"
  exit 1
fi
