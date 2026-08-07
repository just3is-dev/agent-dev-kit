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

# post-edit-check: правка templates/*/scripts/check не должна ложно фейлить
# (issue #14). Поиск корня останавливался на самом каталоге шаблона — там
# уже лежит исполняемый scripts/check, — и исключение "$root"/templates/*
# после этого не срабатывало, т.к. рассчитано на root = корень кита.
# Кит-подобная структура: свой scripts/check в корне (проходит) и
# templates/demo/scripts/check (падает, если его реально прогнать —
# имитирует контракт шаблона, нерелевантный правке самого файла шаблона).
KITSIM="$TMP/kitsim"
mkdir -p "$KITSIM/scripts" "$KITSIM/templates/demo/scripts"
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
assert_exit "post-edit-check: правка шаблонного templates/*/scripts/check не запускает контракт кита (issue #14)" 0 $?

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
runs=$(wc -l < "$P/.test-runs" | tr -d ' ')
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
if grep -q "Нужно разрешение на Bash" "$NFILE" 2>/dev/null; then
  echo "PASS: notification: запрос ввода порождает уведомление"
else
  echo "FAIL: notification: уведомление не отправлено"
  fails=$((fails + 1))
fi

# stop-test: долгий ход (метка старше порога) на чистом дереве → уведомление
echo $(( $(date +%s) - 100 )) > "$NDIR/sid2"
rm -f "$NFILE"
printf '{"session_id":"sid2"}' | TMPDIR="$TMP/tmpdir" ADK_NOTIFY_FILE="$NFILE" CLAUDE_PROJECT_DIR="$P" "$HOOKS/stop-test.sh" >/dev/null 2>&1
assert_exit "stop-test: уведомление — exit 0 при чистом дереве" 0 $?
if grep -q "Задача завершена" "$NFILE" 2>/dev/null; then
  echo "PASS: stop-test: долгий ход завершён — уведомление отправлено"
else
  echo "FAIL: stop-test: уведомление о завершении не отправлено"
  fails=$((fails + 1))
fi

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
lines=$(wc -l < "$LOGP/.adk/logs/issue-1.jsonl" | tr -d ' ')
assert_exit "AC-1: adk-log: повторная запись дописывает вторую строку, не трёт первую" 2 "$lines"
first_event=$(sed -n '1p' "$LOGP/.adk/logs/issue-1.jsonl" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("event",""))' 2>/dev/null)
if [ "$first_event" = "start" ]; then
  echo "PASS: AC-1: adk-log: первая строка не перезаписана вторым событием"
else
  echo "FAIL: AC-1: adk-log: первая строка изменилась (event=$first_event)"
  fails=$((fails + 1))
fi

valid=$(python3 -c '
import json, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
ok = len(lines) == 2
for l in lines:
    try:
        d = json.loads(l)
        if "timestamp" not in d or "event" not in d:
            ok = False
    except Exception:
        ok = False
print("1" if ok else "0")
' "$LOGP/.adk/logs/issue-1.jsonl")
assert_exit "AC-1: adk-log: каждая строка — валидный JSON с timestamp и полями" 1 "$valid"

before_badpair=$(wc -l < "$LOGP/.adk/logs/issue-1.jsonl" | tr -d ' ')
CLAUDE_PROJECT_DIR="$LOGP" "$HOOKS/adk-log.sh" issue-1 event badpair >/dev/null 2>&1
assert_exit "AC-1: adk-log: аргумент без '=' отклоняется с ошибкой" 1 $?
after_badpair=$(wc -l < "$LOGP/.adk/logs/issue-1.jsonl" | tr -d ' ')
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
gi_lines_after=$(wc -l < "$LOGP/.adk/.gitignore" | tr -d ' ')
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
if printf '%s' "$stats_out" | grep -q "Всего задач"; then
  echo "FAIL: AC-3: adk-stats: пустой журнал не должен показывать агрегаты"
  fails=$((fails + 1))
else
  echo "PASS: AC-3: adk-stats: пустой журнал не выдумывает агрегаты"
fi

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
if printf '%s' "$stats_out" | grep -q "Всего задач"; then
  echo "FAIL: AC-3: adk-stats: каталог только с autopilot-файлом не должен показывать агрегаты по задачам"
  fails=$((fails + 1))
else
  echo "PASS: AC-3: adk-stats: каталог только с autopilot-файлом — без агрегатов по задачам"
fi
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
if printf '%s' "$stats_out" | grep -q "Журнал пуст"; then
  echo "FAIL: AC-3: adk-stats: незавершённая-только задача ошибочно названа 'журнал пуст' — записи есть (start/review): $stats_out"
  fails=$((fails + 1))
else
  echo "PASS: AC-3: adk-stats: незавершённая-только задача не спутана с пустым журналом"
fi
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
if printf '%s' "$stats_out" | grep -q "Всего задач: 1"; then
  echo "PASS: AC-3: adk-stats: остальные валидные строки файла с оборванным UTF-8 отработали как обычно"
else
  echo "FAIL: AC-3: adk-stats: файл с оборванным UTF-8 не дал ожидаемого результата: $stats_out"
  fails=$((fails + 1))
fi

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
if printf '%s' "$stats_out" | grep -q "Средние круги ревью: 2.0"; then
  echo "PASS: AC-3: adk-stats: круги считаются как max(round)=2, не как число строк event=review=3 — дубль записи круга не завышает метрику"
else
  echo "FAIL: AC-3: adk-stats: дублирующая запись круга исказила метрику кругов ревью: $stats_out"
  fails=$((fails + 1))
fi

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
if printf '%s' "$stats_out" | grep -q "Всего задач: 1"; then
  echo "PASS: AC-3: adk-stats: задача с нестроковым reason всё равно посчитана"
else
  echo "FAIL: AC-3: adk-stats: задача с нестроковым reason не посчитана: $stats_out"
  fails=$((fails + 1))
fi

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

if printf '%s' "$stats_out" | grep -q "Всего задач: 3"; then
  echo "PASS: AC-3: adk-stats: всего задач — 3 завершённые (issue-13 без итога и autopilot-файл не задваивают)"
else
  echo "FAIL: AC-3: adk-stats: неверное число задач: $stats_out"
  fails=$((fails + 1))
fi

if printf '%s' "$stats_out" | grep -q "В работе (без итога, в агрегаты ниже не входят): 1"; then
  echo "PASS: AC-3: adk-stats: незавершённая задача (issue-13, без outcome) показана отдельно, не искажает агрегаты"
else
  echo "FAIL: AC-3: adk-stats: незавершённая задача не отражена в выводе: $stats_out"
  fails=$((fails + 1))
fi

if printf '%s' "$stats_out" | grep -Eq "Средние круги ревью: 1\.7"; then
  echo "PASS: AC-3: adk-stats: средние круги ревью посчитаны верно ((2+1+2)/3 = 1.7, issue-13 не в счёте)"
else
  echo "FAIL: AC-3: adk-stats: средние круги ревью не совпадают с ожиданием: $stats_out"
  fails=$((fails + 1))
fi

if printf '%s' "$stats_out" | grep -q "33%" && printf '%s' "$stats_out" | grep -q "1/3"; then
  echo "PASS: AC-3: adk-stats: доля застреваний — 33% (1/3)"
else
  echo "FAIL: AC-3: adk-stats: доля застреваний не совпадает с ожиданием: $stats_out"
  fails=$((fails + 1))
fi

if printf '%s' "$stats_out" | grep -q "ревьюер второй круг подряд REQUEST_CHANGES"; then
  echo "PASS: AC-3: adk-stats: причина застревания названа в выводе"
else
  echo "FAIL: AC-3: adk-stats: причина застревания не найдена в выводе: $stats_out"
  fails=$((fails + 1))
fi

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

if printf '%s' "$step1" | grep -q 'adk-log\.sh.*event=start'; then
  echo "PASS: AC-1: work.md шаг 1 логирует event=start"
else
  echo "FAIL: AC-1: work.md шаг 1 не логирует event=start"
  fails=$((fails + 1))
fi

if printf '%s' "$step6" | grep -q 'adk-log\.sh.*event=review'; then
  echo "PASS: AC-1: work.md шаг 6 логирует event=review после каждого вердикта"
else
  echo "FAIL: AC-1: work.md шаг 6 не логирует event=review"
  fails=$((fails + 1))
fi

if printf '%s' "$step7" | grep -q 'adk-log\.sh.*event=finish'; then
  echo "PASS: AC-1: work.md шаг 7 логирует event=finish"
else
  echo "FAIL: AC-1: work.md шаг 7 не логирует event=finish"
  fails=$((fails + 1))
fi

if printf '%s' "$step7" | grep -q 'git diff main\.\.\. --shortstat'; then
  echo "PASS: AC-1: work.md шаг 7 считает размер диффа git diff main... --shortstat"
else
  echo "FAIL: AC-1: work.md шаг 7 не считает размер диффа"
  fails=$((fails + 1))
fi

for step_name in step1 step6 step7; do
  step_text=$(eval "printf '%s' \"\$$step_name\"")
  if printf '%s' "$step_text" | grep -q 'adk-log\.sh.*|| true'; then
    echo "PASS: AC-1: work.md $step_name — запись в журнал не блокирует задачу (|| true)"
  else
    echo "FAIL: AC-1: work.md $step_name не отмечает журнал как необязательный (не гейт)"
    fails=$((fails + 1))
  fi
done

if printf '%s' "$step7" | grep -q 'outcome="'; then
  echo "PASS: AC-1: work.md шаг 7 — outcome закавычен (причина может содержать пробелы)"
else
  echo "FAIL: AC-1: work.md шаг 7 не закавычивает outcome — многословная причина сломает вызов"
  fails=$((fails + 1))
fi

# Смоук: последовательность вызовов adk-log.sh, которую описывает work.md
# (start → review → finish), даёт журнал с тремя валидными записями.
WORKP="$TMP/workproj"
mkdir -p "$WORKP"

CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=start issue=42 >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=review round=1 verdict=REQUEST_CHANGES >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP" "$HOOKS/adk-log.sh" issue-42 event=finish outcome=ready rounds=2 duration=42s diffstat=" 1 file changed, 3 insertions(+)" >/dev/null 2>&1

work_lines=$(wc -l < "$WORKP/.adk/logs/issue-42.jsonl" 2>/dev/null | tr -d ' ')
assert_exit "AC-1: work.md-смоук: start → review → finish дают три записи в issue-42.jsonl" 3 "${work_lines:-0}"

work_valid=$(python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        lines = [json.loads(l) for l in f]
except Exception:
    print("0")
    sys.exit(0)
ok = len(lines) == 3
if ok:
    ok = ok and lines[0].get("event") == "start" and lines[0].get("issue") == "42"
    ok = ok and lines[1].get("event") == "review" and lines[1].get("round") == "1" and lines[1].get("verdict") == "REQUEST_CHANGES"
    ok = ok and lines[2].get("event") == "finish" and lines[2].get("outcome") == "ready" and lines[2].get("rounds") == "2" and "duration" in lines[2] and "diffstat" in lines[2]
    ok = ok and all("timestamp" in l for l in lines)
print("1" if ok else "0")
' "$WORKP/.adk/logs/issue-42.jsonl")
assert_exit "AC-1: work.md-смоук: записи содержат issue/круг/вердикт/итог/длительность" 1 "$work_valid"

# Смоук: outcome=stuck:<причина> с пробелами — ровно случай застревания,
# ради которого журнал и заводится (issue #4 агрегирует причины).
WORKP2="$TMP/workproj-stuck"
mkdir -p "$WORKP2"
CLAUDE_PROJECT_DIR="$WORKP2" "$HOOKS/adk-log.sh" issue-43 event=start issue=43 >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WORKP2" "$HOOKS/adk-log.sh" issue-43 event=finish outcome="stuck: тесты не проходят" rounds=2 duration=120s diffstat=" 3 files changed" >/dev/null 2>&1
stuck_lines=$(wc -l < "$WORKP2/.adk/logs/issue-43.jsonl" 2>/dev/null | tr -d ' ')
assert_exit "AC-1: work.md-смоук: outcome=stuck с пробелами в причине не роняет запись" 2 "${stuck_lines:-0}"

stuck_outcome=$(tail -n1 "$WORKP2/.adk/logs/issue-43.jsonl" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("outcome",""))' 2>/dev/null)
if [ "$stuck_outcome" = "stuck: тесты не проходят" ]; then
  echo "PASS: AC-1: work.md-смоук: причина застревания сохраняется целиком, с пробелами"
else
  echo "FAIL: AC-1: work.md-смоук: причина застревания искажена или потеряна (outcome=$stuck_outcome)"
  fails=$((fails + 1))
fi

# ── /autopilot: события журнала (AC-2) ───────────────────────────────────────
AUTOMD="$KIT/commands/autopilot.md"
step3=$(sed -n '/^3\. \*\*/,/^4\. \*\*/p' "$AUTOMD" | tr '\n' ' ' | tr -s ' ')
finish_section=$(sed -n '/^## Завершение/,$p' "$AUTOMD" | tr '\n' ' ' | tr -s ' ')

if printf '%s' "$step3" | grep -q 'adk-log\.sh.*event=task'; then
  echo "PASS: AC-2: autopilot.md шаг 3 логирует event=task на каждую разобранную задачу"
else
  echo "FAIL: AC-2: autopilot.md шаг 3 не логирует event=task"
  fails=$((fails + 1))
fi

if printf '%s' "$finish_section" | grep -q 'adk-log\.sh.*event=run_finish'; then
  echo "PASS: AC-2: autopilot.md «Завершение» логирует event=run_finish"
else
  echo "FAIL: AC-2: autopilot.md «Завершение» не логирует итог прогона"
  fails=$((fails + 1))
fi

for outcome_kind in 'outcome=merged' 'outcome="stuck' 'outcome=skipped'; do
  if printf '%s' "$step3" | grep -qF "$outcome_kind"; then
    echo "PASS: AC-2: autopilot.md шаг 3 покрывает исход «$outcome_kind»"
  else
    echo "FAIL: AC-2: autopilot.md шаг 3 не упоминает исход «$outcome_kind»"
    fails=$((fails + 1))
  fi
done

for agg_field in total= merged= stuck= skipped=; do
  if printf '%s' "$finish_section" | grep -qF "$agg_field"; then
    echo "PASS: AC-2: autopilot.md «Завершение» пишет агрегат «$agg_field»"
  else
    echo "FAIL: AC-2: autopilot.md «Завершение» не пишет агрегат «$agg_field»"
    fails=$((fails + 1))
  fi
done

for section_name in step3 finish_section; do
  section_text=$(eval "printf '%s' \"\$$section_name\"")
  if printf '%s' "$section_text" | grep -q 'adk-log\.sh.*|| true'; then
    echo "PASS: AC-2: autopilot.md $section_name — запись в журнал не блокирует прогон (|| true)"
  else
    echo "FAIL: AC-2: autopilot.md $section_name не отмечает журнал как необязательный (не гейт)"
    fails=$((fails + 1))
  fi
done

if printf '%s' "$step3" | grep -q 'autopilot-\$(date'; then
  echo "PASS: AC-2: autopilot.md шаг 3 пишет в единицу autopilot-<дата>"
else
  echo "FAIL: AC-2: autopilot.md шаг 3 не адресует единицу журнала autopilot-<дата>"
  fails=$((fails + 1))
fi

# Смоук: последовательность вызовов adk-log.sh, которую описывает autopilot.md
# (task=merged → task=stuck → task=skipped → run_finish), даёт журнал одного
# прогона с записью на каждую задачу и итоговой записью (сделано/застряло/
# пропущено), в файле autopilot-<дата>.jsonl.
AUTOP="$TMP/autopproj"
mkdir -p "$AUTOP"
DATE_UNIT="autopilot-$(date +%Y-%m-%d)"

CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=10 outcome=merged >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=11 outcome="stuck: тесты падают" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=task issue=12 outcome=skipped >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$AUTOP" "$HOOKS/adk-log.sh" "$DATE_UNIT" event=run_finish total=3 merged=1 stuck=1 skipped=1 >/dev/null 2>&1

auto_lines=$(wc -l < "$AUTOP/.adk/logs/$DATE_UNIT.jsonl" 2>/dev/null | tr -d ' ')
assert_exit "AC-2: autopilot.md-смоук: три task-записи плюс итоговая run_finish дают четыре строки" 4 "${auto_lines:-0}"

auto_valid=$(python3 -c '
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        lines = [json.loads(l) for l in f]
except Exception:
    print("0")
    sys.exit(0)
ok = len(lines) == 4
if ok:
    ok = ok and lines[0].get("event") == "task" and lines[0].get("issue") == "10" and lines[0].get("outcome") == "merged"
    ok = ok and lines[1].get("event") == "task" and lines[1].get("issue") == "11" and lines[1].get("outcome") == "stuck: тесты падают"
    ok = ok and lines[2].get("event") == "task" and lines[2].get("issue") == "12" and lines[2].get("outcome") == "skipped"
    ok = ok and lines[3].get("event") == "run_finish" and lines[3].get("total") == "3" and lines[3].get("merged") == "1" and lines[3].get("stuck") == "1" and lines[3].get("skipped") == "1"
    ok = ok and all("timestamp" in l for l in lines)
print("1" if ok else "0")
' "$AUTOP/.adk/logs/$DATE_UNIT.jsonl")
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
npkgs=$(wc -l < "$M/.calls" | tr -d ' ')
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

write_ac_spec "$ACP/docs/specs/001-x.md" "approved" "- [ ] AC-1: первый критерий
- [ ] AC-2: второй критерий"
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-1: первый критерий покрыт"
echo "AC-2: второй критерий покрыт"
EOF

"$HOOKS/ac-check.sh" "$ACP" >/dev/null 2>&1
assert_exit "AC-4: ac-check: approved-спека AC-1..AC-2 с помеченными тестами — покрытие полное" 0 $?

# убрали тег AC-2 из тестов — непокрытый критерий должен провалить проверку
# и быть назван в выводе
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-1: первый критерий покрыт"
EOF
ac_out=$("$HOOKS/ac-check.sh" "$ACP" 2>&1)
ac_st=$?
assert_exit "AC-4: ac-check: непокрытый AC-2 — exit 1" 1 "$ac_st"
if printf '%s' "$ac_out" | grep -q "AC-2"; then
  echo "PASS: AC-4: ac-check: непокрытый AC-2 назван в выводе"
else
  echo "FAIL: AC-4: ac-check: AC-2 не найден в выводе: $ac_out"
  fails=$((fails + 1))
fi

# draft-спека не проверяется — её AC-токены не требуют покрытия.
# tests/run.sh фикстуры на этот момент всё ещё не содержит тега AC-2
# (предыдущий блок), поэтому exit по-прежнему 1 — из-за AC-2, а не AC-9.
write_ac_spec "$ACP/docs/specs/002-y.md" "draft" "- [ ] AC-9: черновой критерий без теста"
ac_out=$("$HOOKS/ac-check.sh" "$ACP" 2>&1)
ac_st=$?
rm "$ACP/docs/specs/002-y.md"
assert_exit "AC-4: ac-check: draft-спека не мешает результату (exit по-прежнему из-за AC-2)" 1 "$ac_st"
if printf '%s' "$ac_out" | grep -q "AC-9"; then
  echo "FAIL: AC-4: ac-check: draft-спека попала в проверку (AC-9 в выводе)"
  fails=$((fails + 1))
else
  echo "PASS: AC-4: ac-check: AC-токены draft-спеки не требуют покрытия"
fi

# вернули тег AC-2 — approved-спека снова полностью покрыта
cat > "$ACP/tests/run.sh" <<'EOF'
echo "AC-1: первый критерий покрыт"
echo "AC-2: второй критерий покрыт"
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
echo "AC-1: покрыт в альтернативном месте"
echo "AC-2: покрыт в альтернативном месте"
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

- [ ] AC-1: критерий без единого теста
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

- [ ] AC-1: единственный формальный критерий
EOF
cat > "$SEC/tests/run.sh" <<'EOF'
echo "AC-1: критерий покрыт"
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

- [ ] AC-1: критерий без отдельного теста
EOF
ac_out=$("$HOOKS/ac-check.sh" "$SELFM" 2>&1)
ac_st=$?
assert_exit "AC-4: ac-check: спека не засчитывает сама себя как тест (docs/specs исключён)" 1 "$ac_st"
if printf '%s' "$ac_out" | grep -q "AC-1"; then
  echo "PASS: AC-4: ac-check: AC-1 назван непокрытым при самопокрытии спекой"
else
  echo "FAIL: AC-4: ac-check: AC-1 не назван непокрытым: $ac_out"
  fails=$((fails + 1))
fi

# node_modules/vendor не считаются тестовым корпусом — токен в зависимости
# не должен ложно засчитываться как покрытие
VEND="$TMP/ac-vendor-proj"
mkdir -p "$VEND/docs/specs" "$VEND/tests" "$VEND/node_modules/pkg"
write_ac_spec "$VEND/docs/specs/001-x.md" "approved" "- [ ] AC-1: критерий без реального теста"
echo "AC-1" > "$VEND/node_modules/pkg/index.spec.js"
"$HOOKS/ac-check.sh" "$VEND" >/dev/null 2>&1
assert_exit "AC-4: ac-check: node_modules не считается тестовым корпусом" 1 $?

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
write_ac_spec "$WIRE/docs/specs/001-x.md" "approved" "- [ ] AC-1: критерий"
(cd "$WIRE" && ./scripts/check pkg/src/good.ts >/dev/null 2>&1)
assert_exit "AC-4: contract check: частичный прогон игнорирует непокрытый AC — граница \$#-guard'а" 0 $?

(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: полный прогон падает при непокрытом AC" 1 $?

cat > "$WIRE/tests/run.sh" <<'EOF'
echo "AC-1: критерий покрыт"
EOF
(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: полный прогон проходит при полном покрытии AC" 0 $?

rm "$WIRE/tests/run.sh"
rm "$WIRE/scripts/ac-check"
(cd "$WIRE" && ./scripts/check >/dev/null 2>&1)
assert_exit "AC-4: contract check: без scripts/ac-check — прежнее поведение, непокрытый AC не блокирует" 0 $?

# ── Шаблоны и project-init.md подключают ac-check (issue #7) ────────────────
for t in nextjs nestjs python-service monorepo; do
  if grep -q 'scripts/ac-check' "$KIT/templates/$t/scripts/check"; then
    echo "PASS: AC-4: templates/$t/scripts/check содержит вызов ac-check в полном прогоне"
  else
    echo "FAIL: AC-4: templates/$t/scripts/check не содержит вызов ac-check"
    fails=$((fails + 1))
  fi
done

if grep -q 'scripts/ac-check' "$KIT/commands/project-init.md"; then
  echo "PASS: AC-4: project-init.md содержит шаг копирования ac-check.sh в scripts/ac-check"
else
  echo "FAIL: AC-4: project-init.md не содержит шаг копирования ac-check.sh"
  fails=$((fails + 1))
fi

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

# ── Итог ─────────────────────────────────────────────────────────────────────
echo "─────"
if [ "$fails" -eq 0 ]; then
  echo "Все тесты прошли."
  exit 0
else
  echo "Провалено тестов: $fails"
  exit 1
fi
