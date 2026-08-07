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

# ── Итог ─────────────────────────────────────────────────────────────────────
echo "─────"
if [ "$fails" -eq 0 ]; then
  echo "Все тесты прошли."
  exit 0
else
  echo "Провалено тестов: $fails"
  exit 1
fi
