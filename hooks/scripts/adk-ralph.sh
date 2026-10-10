#!/usr/bin/env bash
# Ralph-цикл SPEC-003 (docs/specs/003-autonomy.md): выполняет очередь issues
# свежими headless-процессами `claude -p`, без интерактивной сессии — память
# между итерациями держат git/issues/журнал, не контекст модели. Запускается
# вручную из корня проекта: hooks/scripts/adk-ralph.sh
#
# issue #139 — базовый цикл (AC-1) и запрет
# --dangerously-skip-permissions (AC-7). Бюджеты задачи/прогона — issues
# #131/#132 (время/токены), консервативные дефолты — issue #138. Breaker уровня
# системы — issue #135, ADR-015: красные гейты main перед каждой итерацией,
# отказ записи журнала, серия git-конфликтов актуализации подряд. Breaker
# уровня прогона — issue #134, ADR-016: накопленные застревания и доля
# пропущенных из-за зависимостей за прогон. Оба уровня breaker'а
# реализованы в этой версии. Стоп-файл `.adk/stop` — issue #130, SPEC-003
# AC-2, приоритет при коллизии причин остановки — ADR-018. Расход задач
# (duration/tokens в event=task, usage из --output-format json, состав
# счётчика и токеновые бюджеты задачи/прогона) — issue #132, ADR-001
# «Расширения схемы»; множитель бюджетов size:large — issue #133. Merge ready-PR
# по policies.merge/canMerge — issue #129, ADR-019: fail-closed на
# неизвестное значение конфига (никогда не мержит), human-only/
# human-review-required-без-approve — «ждут человека» (result=ready, как
# раньше), иначе актуализация + локальные гейты + `gh pr merge` с флагом
# из `adk-config.sh --merge-method`; конфликт/красные гейты после
# актуализации — застревание задачи (result=stuck), не остановка прогона.
#
# Правило выбора следующей задачи — то же, что шаг 1 commands/autopilot.md:
# открытый issue, без метки needs-human, все «Зависит от: Blocked by #N»
# закрыты. Отличие от /autopilot: очередь не сужена текущим milestone —
# ralph как скрипт не обладает суждением «какой milestone сейчас текущий»
# (см. ADR-007).
#
# Label-резерв owner:human (issue #158): issue с этой меткой пропускается тем
# же способом, что needs-human, — молча, вне кандидатов, без записи в журнал
# и без needs-human/уведомления. Ставит и снимает метку человек в любой
# момент (`gh issue edit N --add-label|--remove-label owner:human`); ralph её
# не трогает — только читает при каждом select_next. Отличие от needs-human:
# это не застревание и не skip по зависимости, поэтому счётчик
# зарезервированных не входит ни в ready/stuck/skipped журнала, только в
# отдельную строку сводки прогона.
#
# Спека вехи ещё не в default branch (issue #218, ADR-024, симметрично шагу 1
# commands/work.md и commands/autopilot.md): issue со строкой «Спека:
# docs/specs/NNN-<слаг>.md» в теле, чей файл ещё не существует в
# origin/$default_branch (PR спеки ready, но `policies.merge` не даёт агенту его
# смержить), пропускается тем же молчаливым способом, что owner:human —
# без needs-human, без записи в журнал, вне ready/stuck/skipped. Без этого
# select_next отдал бы issue `claude -p` с текстом commands/work.md,
# тот остановился бы без ветки и PR (шаг 1 /work, «номер задан явно —
# остановись»), а find_pr_state прочёл бы «PR нет» как застревание —
# ложная needs-human на легальном ожидании человека.
#
# Тесты: hooks/scripts/adk-ralph.sh стабами claude/gh на суженном PATH,
# журнал — $ADK_LOGS_DIR, уведомления — $ADK_NOTIFY_FILE (notify-send.sh),
# конфиг — $ADK_CONFIG_FILE (lib/config.sh) — все три уже поддержаны
# переиспользуемыми хелперами, ralph не добавляет своего механизма.
set -u
# Job control (issue #131, ADR-017 §1) НЕ включается безусловно для всего
# скрипта: под tty глобальный `set -m` даёт каждому foreground-job'у
# собственную группу процессов и терминал — INT/TERM с терминала до них не
# долетает, а фоновый job без перенаправления stdin способен тихо
# застопориться на чтении tty (SIGTTIN). Поэтому `-m` включается ТОЛЬКО на
# время фонового запуска claude -p ниже (`set -m; … & set +m`) —
# единственного места, которому нужна своя группа процессов для group-kill
# по бюджету задачи; там же явный `</dev/null` фоновому job'у.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" # sourcing lib/config.sh тянет lib/paths.sh следом
. "$SCRIPT_DIR/lib/plugin-version.sh" # adk_plugin_version — issue #154, ADR-021

root=$(adk_project_root)
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# Экспорт обязателен: без него дочерний headless-процесс `claude -p` не
# наследует CLAUDE_PLUGIN_ROOT при штатном ручном запуске (шапка файла),
# где переменная не выставлена вовсе — а commands/work.md, которым
# инструктируется этот процесс, ссылается на
# ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/... в десятке мест.
export CLAUDE_PLUGIN_ROOT="$plugin_root"
work_md="$plugin_root/commands/work.md"

# ── Политика: enabled=false / неизвестное значение — отказ старта fail-closed,
# без единого побочного эффекта (ADR-007 §5) ─────────────────────────────────
enabled=$(adk_config_get "policies.autopilot.enabled" "true" "true,false")
enabled_rc=$?
if [ "$enabled_rc" -ne 0 ]; then
  echo "adk-ralph: policies.autopilot.enabled — неизвестное значение в конфиге," \
    "отказ старта (fail-closed)." >&2
  exit 1
fi
if [ "$enabled" != "true" ]; then
  echo "adk-ralph: автопилот выключен конфигом (policies.autopilot.enabled=false)," \
    "включается правкой adk.config.json явным коммитом." >&2
  exit 1
fi

if [ ! -f "$work_md" ]; then
  echo "adk-ralph: не найден $work_md (инструкции /work)" >&2
  exit 1
fi

# Префлайт бинаря claude — тот же класс проверки, что и work_md выше: без
# него каждая итерация цикла дошла бы до find_pr_state → "none" → ложное
# «PR не создан» по всей очереди issues (ADR-007 §4). Дешевле остановиться
# до первой задачи, чем узнать об этом после того, как вся очередь уже
# помечена needs-human.
if ! command -v claude >/dev/null 2>&1; then
  echo "adk-ralph: бинарь claude не найден в PATH (не установлен/не в PATH)" \
    "— отказ старта до какого-либо побочного эффекта (ADR-007 §4)." >&2
  exit 1
fi

# Стоп-файл `.adk/stop` (issue #130, SPEC-003 AC-2, ADR-018) — прошлого
# прогона не должен убивать новый, поэтому удаляется здесь, ПОСЛЕ всех
# fail-closed preflight-проверок выше (иначе отказ старта по одной из них
# уже трогал бы файловую систему до своего единственного разрешённого
# побочного эффекта, ADR-007 §4/§5). Проверка самого файла — на границе
# каждой итерации цикла ниже.
stop_file="$root/.adk/stop"
rm -f "$stop_file" 2>/dev/null
if [ -e "$stop_file" ]; then
  # Не должно происходить при обычном touch/rm-совместимом файле — громкое
  # предупреждение вместо тихого проглатывания (например, если
  # .adk/stop — каталог: `rm -f` каталоги не берёт). Прогон всё равно
  # стартует; ближайшая проверка границы итерации ниже честно остановит
  # его причиной «стоп-файл», раз файл физически остался на месте.
  echo "adk-ralph: не удалось удалить $stop_file на старте — прогон остановится" \
    "на первой же проверке границы итерации с причиной «стоп-файл», пока файл" \
    "не будет убран вручную." >&2
fi

run_unit="autopilot-$(date +%Y-%m-%d)"
logger="$SCRIPT_DIR/adk-log.sh"
notifier="$SCRIPT_DIR/notify-send.sh"

# ── Прерывание сигналом (issue #131, ADR-017 §1) ────────────────────────────
# До этой задачи claude -p выполнялся синхронно на переднем плане — Ctrl-C по
# ralph доходил и до него как до члена того же foreground process group.
# Бюджет задачи требует бэкграундить claude -p (чтобы параллельно опрашивать
# бюджет); фоновый job получает собственную группу процессов только на время
# своего запуска (`set -m` вокруг самого `&` ниже, круг 2 ревью PR #193) — с
# этого момента INT/TERM с терминала до него больше не доходит сам по себе
# (сама группа не меняется дальнейшим `set +m`). `claude_pid` — глобальная
# переменная, непустая ровно на время жизни фонового claude -p (выставляется/
# очищается вокруг каждого запуска ниже); обработчик сигнала добивает именно
# её (и группу процессов, если она ещё жива), а не полагается на то, что
# сигнал и так дойдёт. `done="${merged_count:-0}"` (не литеральный `0`) —
# круг 4 ревью PR #193: после интеграции issue #129 (merge ready-PR)
# обработчик обязан отражать реально смерженное этим прогоном до сигнала,
# тем же полем, что и штатный хвост цикла в самом конце файла — до этой
# правки сигнал после успешного merge искажал бы журнал буквальным нулём
# независимо от факта merge. Реестр `event=run_end.reason` (ADR-007 §3 /
# ADR-001) синхронизирован новым значением "прерван сигналом <sig>".
claude_pid=""
ralph_signal_cleanup() {
  local sig="$1" sig_exit=130
  # Конвенция exit-кода 128+N — 130 для INT (128+2), 143 для TERM (128+15);
  # круг 2 ревью PR #193 нашёл, что обе ветки раньше отдавали буквальный 130.
  if [ "$sig" = "TERM" ]; then
    sig_exit=143
  fi
  echo "adk-ralph: получен сигнал $sig — прогон прерывается." >&2
  if [ -n "$claude_pid" ]; then
    kill -TERM -- "-$claude_pid" 2>/dev/null || true
    sleep 0.2
    kill -0 "$claude_pid" 2>/dev/null && kill -KILL -- "-$claude_pid" 2>/dev/null
  fi
  "$logger" "$run_unit" event=run_end done="${merged_count:-0}" ready="${ready_count:-0}" \
    tokens="${run_tokens_used:-0}" \
    stuck="${stuck_count:-0}" skipped="${skipped_count:-0}" \
    blocked_on_ready="${blocked_on_ready_count:-0}" \
    closed_externally="${closed_externally_count:-0}" \
    reason="прерван сигналом $sig" || true
  exit "$sig_exit"
}
trap 'ralph_signal_cleanup INT' INT
trap 'ralph_signal_cleanup TERM' TERM

task_label=$(adk_config_get "types.task.label" "type:task")
bug_label=$(adk_config_get "types.bug.label" "type:bug")
ff_label=$(adk_config_get "types.fastFollow.label" "type:fast-follow")
consolidate_label=$(adk_config_get "types.consolidate.label" "type:consolidate")

# ── Состояние прогона ─────────────────────────────────────────────────────
handled=""  # issue-номера, по которым уже записана строка event=task
stuck=""    # issue-номера, застрявшие в этом прогоне (needs-human поставлен)
skipped=""  # issue-номера, пропущенные в этом прогоне (зависимость от stuck)
ready_nums=""  # issue-номера, ставшие ready в этом прогоне (подмножество
               # handled) — вход select_next для ADR-014 (issue #147)
merged_nums=""  # issue-номера, смерженные этим прогоном (issue #129,
                # ADR-019) — подмножество handled, отдельно от ready_nums:
                # мердж уже не ждёт человека, select_next не должен считать
                # его блокером ready (ADR-014 §2 говорит именно про ready-но-
                # не-смерженный блокер).
closed_externally_nums=""  # issue-номера, закрытые человеком (или другим
                # процессом) ДО того, как ralph успел их исполнить этим
                # прогоном (issue #220 п.1, рационале — ADR-019 доп.) —
                # подмножество handled, отдельно и от merged_nums, и от
                # skipped. select_next вычитает эти номера из open_numbers
                # тем же способом, что и merged_now.
blocked_on_ready_nums=""  # issue-номера, отнесённые к blocked-on-ready в этом
                          # прогоне (подмножество handled), переживает
                          # итерации внешнего цикла — см. ADR-014 п.2
ready_count=0
merged_count=0  # issue #129, ADR-019 — идёт в event=run_end.done (поле уже
                # предусмотрено ADR-001 схемой, adk-ralph.sh раньше всегда
                # писал в него 0 — merge не был реализован)
stuck_count=0
skipped_count=0
blocked_on_ready_count=0  # задачи, заблокированные ready-но-не-смерженным
                          # блокером этого прогона (ADR-014, issue #147)
closed_externally_count=0  # issue-номера, закрытые человеком до старта
                            # задачи этим прогоном (issue #220 п.1)
ready_list=""
merged_list=""
usage_summary=""  # строки «#N: 12s/3456 ток.» по клод-исполненным задачам (issue #132)
stuck_summary=""
skipped_summary=""
closed_externally_summary=""
blocked_on_ready_summary=""
waiting_for_spec_nums=""  # issue-номера, у которых спека ещё не в default
                          # branch — НЕ подмножество handled (issue #218,
                          # круг 4 ревью PR #246): перезаписывается целиком
                          # на каждой итерации значением из последнего вызова
                          # select_next (который каждый раз освежает fetch +
                          # ls-tree), а не накапливается — спеку могли
                          # смержить по ходу прогона, и к концу прогона
                          # достоверен только самый свежий список, не их
                          # объединение за весь прогон.
waiting_for_spec_count=0
waiting_for_spec_summary=""
stop_reason=""
exit_code=0

# ── Breaker уровня системы (issue #135, SPEC-003 «Система», половина AC-5
# уровня системы; ADR-015) — три независимых триггера немедленного полного
# стопа: красные гейты main (run_main_gates, определена ниже, у цикла),
# отказ записи журнала (journal_break сразу под этим блоком) и серия
# подряд идущих git-конфликтов актуализации default branch между
# итерациями (actualization_conflict_streak, считает return_to_default_branch
# ниже). В отличие от breaker'а уровня прогона ниже (issue #134,
# maxStuckPerRun/maxSkippedShare) система не разбирает содержимое очереди
# issues, а реагирует на отказ самой инфраструктуры прогона.
actualization_conflict_streak=0
# Порог — не атрибут конфига (в отличие от maxStuckPerRun/maxSkippedShare
# run-уровня): системный breaker — безусловная защита инфраструктуры, не
# настраиваемая политика прогона (ADR-015). 2 — тот же консервативный
# дефолт, что и у maxStuckPerRun (SPEC-003 «Стадийный circuit breaker»).
actualization_conflict_threshold=2
actualization_breaker_tripped=0

# ── Breaker уровня прогона (issue #134, SPEC-003 «Прогон», вторая половина
# AC-5; ADR-016) — в отличие от системного breaker'а выше, разбирает именно
# содержимое очереди этого прогона: накопленные застревания
# (policies.autopilot.breaker.maxStuckPerRun) и доля пропущенных
# из-за зависимостей (policies.autopilot.breaker.maxSkippedShare).
# run_breaker_min_denominator — минимальный знаменатель доли (ready+stuck+
# skipped), ниже которого доля статистически не значима и не оценивается
# вовсе; фиксированная константа, не атрибут конфига — тем же принципом,
# что actualization_conflict_threshold выше (ADR-016 §2). run_breaker_reason
# — сбрасывается в начале каждой итерации цикла, выставляется внутри ветки
# result=stuck сразу после инкремента stuck_count (ADR-016 §1) и проверяется
# после return_to_default_branch, рядом с actualization_breaker_tripped.
run_breaker_min_denominator=4
run_breaker_reason=""

# run_breaker_check_stuck — true (exit 0), когда stuck_count достиг
# maxStuckPerRun (дефолт 2). Вызывается ТОЛЬКО сразу после того, как
# stuck_count уже вырос на новом result=stuck этого прогона — поэтому порог
# 0 или 1 останавливает цикл на первом же застревании, а не до старта
# прогона (когда stuck_count ещё 0, но функция вовсе не вызывается): условие
# «застревания достигли порога» иначе бессмысленно проверять там, где
# застревания ещё не было (ADR-016 §1). Неизвестное/нечисловое значение
# конфига — предупреждение в stderr и дефолт 2 (та же дисциплина, что и
# остальной разбор конфига в этом скрипте).
run_breaker_check_stuck() {
  local threshold
  threshold=$(config_number "policies.autopilot.breaker.maxStuckPerRun" "2" nonneg_int)
  [ "$stuck_count" -ge "$threshold" ]
}

# run_breaker_check_skipped_share — true (exit 0), когда доля пропущенных
# из-за зависимостей выше maxSkippedShare (дефолт 0.5; сравнение строгое —
# «выше», значение ровно на пороге не останавливает цикл). Знаменатель —
# ready_count + merged_count + stuck_count + skipped_count: задачи, реально
# доигранные до исхода этим прогоном (merged_count добавлен issue #129,
# ADR-019 — смерженная задача доиграна до исхода не менее, чем ready-PR,
# ждущий человека; на прогонах без merge merged_count всегда 0, формула не
# меняет прежний результат). Не включает blocked-on-ready (ADR-014:
# «семантически не неудача») и не включает owner:human/уже-needs-human
# issues — они и так не входят ни в один из счётчиков (ADR-007, ADR-014).
# Ниже run_breaker_min_denominator доля не оценивается вовсе, функция
# безусловно возвращает false — вызывается на входе каждой итерации, не
# только сразу после каскада SKIP: доля способна впервые достичь минимума
# знаменателя и на исходе ready/merged/stuck обычной задачи, не только на
# пропуске (ADR-016 §2-3).
run_breaker_check_skipped_share() {
  local threshold total
  threshold=$(config_number "policies.autopilot.breaker.maxSkippedShare" "0.5" nonneg_float)
  total=$((ready_count + merged_count + stuck_count + skipped_count))
  [ "$total" -ge "$run_breaker_min_denominator" ] || return 1
  python3 -c '
import sys
skipped, total, threshold = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
sys.exit(0 if skipped / total > threshold else 1)
' "$skipped_count" "$total" "$threshold"
}

journal_break() { # journal_break — общая точка остановки на отказе
  # adk-log.sh (issue #135): здесь журнал — несущая часть предохранителей,
  # не наблюдаемость, поэтому, в отличие от "|| true" в commands/*.md
  # (журнал необязателен для самой задачи), отказ записи немедленно
  # останавливает весь прогон. Вызывающий код сам решает, нужен ли перед
  # `break` возврат дерева на default branch — эта функция только
  # выставляет причину и код выхода.
  echo "adk-ralph: adk-log.sh не удался — журнал недоступен, немедленный стоп" \
    "(issue #135, SPEC-003 «Система»: здесь журнал несущая часть предохранителей)." >&2
  stop_reason="системный breaker: отказ записи журнала"
  exit_code=1
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
issues_file="$work_dir/issues.json"

# Версия плагина на event=run_start (issue #154, SPEC-004 AC-5, ADR-021):
# поле опционально дописывается только когда непусто (как duration/tokens
# на event=task ниже, issue #132) — plugin.json не найден/битый не должен
# портить сам запуск, run_start пишется без поля, ADR-001 «Расширения
# схемы» трактует строку без поля как прежде.
plugin_version=$(adk_plugin_version)
run_start_extra=""
[ -n "$plugin_version" ] && run_start_extra="version=$plugin_version"

if ! "$logger" "$run_unit" event=run_start $run_start_extra; then
  journal_break
fi

issue_fetch_limit=100
# Guard на exit_code — иначе отказ journal_break выше был бы молча
# переписан причиной gh issue list (issue #135, круг 1 ревью PR #191):
# оба пути ведут к одному общему хвосту (run_end/summary/notify), но
# причина должна остаться первой настоящей, а не последней проверенной;
# заодно этот read-only вызов gh не тратится впустую, когда журнал уже
# сломан и прогон и так не стартует.
if [ "$exit_code" -eq 0 ] && ! (cd "$root" && gh issue list --state open --json number,labels,body --limit "$issue_fetch_limit") \
  >"$issues_file" 2>"$work_dir/gh-issue-list.err"; then
  # Единообразно с остальными путями отказа этого скрипта: run_start уже
  # записан, поэтому этот сбой обязан дописать run_end/reason и
  # уведомление, а не выйти молча (иначе в журнале висит прогон без
  # исхода) — общий хвост ниже делает это для exit_code!=0.
  echo "adk-ralph: gh issue list не удался:" >&2
  cat "$work_dir/gh-issue-list.err" >&2
  stop_reason="gh issue list не удался"
  exit_code=1
fi

# Безопасно вычислять и без guard'а на exit_code: если gh issue list выше
# не удался, issues_file пуст/невалиден, json.load бросит исключение,
# `|| echo 0` даст 0 — предупреждение об усечении просто не напечатается.
fetched_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$issues_file" 2>/dev/null || echo 0)
if [ "$fetched_count" -eq "$issue_fetch_limit" ] 2>/dev/null; then
  echo "adk-ralph: gh issue list вернул ровно $issue_fetch_limit открытых issues —" \
    "список мог быть усечён лимитом, «очередь пуста» в конце прогона не гарантирует," \
    "что открытых issues действительно не осталось." >&2
fi

# Число открытых issues с owner:human (issue #158) — считается один раз с
# начальной выборки issues_file (не меняется в ходе прогона: список не
# перезапрашивается между итерациями, см. select_next ниже). Только для
# итоговой сводки — не журнал (это не result=, не аномалия).
reserved_count=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    issues = json.load(f)
print(sum(1 for it in issues
           if "owner:human" in {l.get("name", "") for l in (it.get("labels") or [])}))
' "$issues_file" 2>/dev/null || echo 0)

csv_add() { # csv_add <csv> <значение> — печатает csv с добавленным значением
  if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s,%s' "$1" "$2"; fi
}

# select_next — один проход: печатает 0+ строк "SKIP <N> <type>" (каскад
# пропуска зависимостей от уже застрявших/пропущенных в этом прогоне задач,
# до неподвижной точки — переход по цепочке зависимостей), затем ровно одну
# строку "NEXT <N> <type> <size>" (следующая задача к исполнению; <size> —
# "large" при label size:large, иначе "-", issue #133) либо "NONE"
# (доступных задач не осталось).
#
# Перед каждым вызовом освежаем список файлов docs/specs/*.md в
# origin/$default_branch (issue #218, круг 2 ревью PR #246, ADR-007 §6) —
# дёшево (один fetch + один ls-tree) и позволяет ralph заметить merge PR
# спеки человеком посреди прогона. `default_branch` вычисляется один раз
# ниже по файлу (до первого вызова select_next, issue #144/#220 п.2) —
# хардкод `origin/main` здесь молча исключал бы из очереди КАЖДЫЙ issue
# со спекой на репозитории с другим default branch, без needs-human и
# какого-либо сигнала (воспроизведено мутацией круга 2: фикстура с
# `--branch trunk` → 3 FAIL). Fetch может упасть (сеть) — `|| true`
# намеренно: пустой/устаревший список на этой итерации лишь оставляет
# issue со спекой вне кандидатов (безопасное направление отказа,
# симметрично owner:human — не needs-human).
select_next() {
  git -C "$root" fetch origin >/dev/null 2>&1 || true
  existing_specs=$(git -C "$root" ls-tree -r --name-only "origin/$default_branch" -- docs/specs 2>/dev/null | tr '\n' ',')
  python3 - "$issues_file" "$handled" "$stuck" "$skipped" "$ready_nums" \
    "$blocked_on_ready_nums" "$merged_nums" "$closed_externally_nums" \
    "$task_label" "$bug_label" "$ff_label" "$consolidate_label" "$existing_specs" <<'PYEOF'
import json, re, sys

issues_file, handled_csv, stuck_csv, skipped_csv, ready_csv, prev_bor_csv, merged_csv, closed_csv = sys.argv[1:9]
task_label, bug_label, ff_label, consolidate_label = sys.argv[9:13]
existing_specs_csv = sys.argv[13]
existing_specs = {p for p in existing_specs_csv.split(",") if p}


def csv_ints(s):
    return {int(x) for x in s.split(",") if x}


handled = csv_ints(handled_csv)
unresolved = csv_ints(stuck_csv) | csv_ints(skipped_csv)
ready_now = csv_ints(ready_csv)
prev_blocked_on_ready = csv_ints(prev_bor_csv)
merged_now = csv_ints(merged_csv)
closed_externally_now = csv_ints(closed_csv)

with open(issues_file) as f:
    issues = json.load(f)
issues.sort(key=lambda it: it["number"])

# issues_file — снимок "gh issue list --state open" на старте прогона
# (не перезапрашивается между итерациями), поэтому смерженный этим прогоном
# issue остаётся в снимке как «открытый». merged_now вычитается из
# open_numbers (issue #129, ADR-019 §10): "Blocked by #<смерженный>" не
# должен вечно висеть неразрешённым блокером — merge закрывает issue на
# GitHub (Closes #N в теле PR, конвенция шага 5 commands/work.md) так же
# определённо, как issue, отсутствующий в снимке вовсе. Без вычитания
# зависимая задача не становится ни NEXT, ни blocked-on-ready (у неё нет
# собственного ready-PR, чтобы попасть в эту ветку) и молча выпадает из
# сводки прогона — регрессия ADR-014/issue #147 для новой ветки исходов.
# closed_externally_now вычитается тем же способом и по той же причине
# (issue #220 п.1): issue, закрытый человеком ДО того, как этот прогон
# успел его исполнить, точно так же больше не открыт на GitHub — его
# "Blocked by #N" не должен ни каскадно SKIP'ить зависимые (блокер не
# застрял, причина другая), ни висеть вечным блокером, которого не было бы,
# закройся issue до снимка очереди, а не посреди прогона.
open_numbers = {it["number"] for it in issues} - merged_now - closed_externally_now


def blockers(body):
    out = set()
    # [ \t]+ (issue #215), не \s+: \s матчит и перевод строки, из-за чего
    # голое «Blocked by» на конце строки захватывало номер со следующей
    # строки как ложный блокер, даже когда та строка — обычный текст, не
    # намеренная зависимость. Разделитель номеров ВНУТРИ списка блокеров
    # (issue #146: «and», запятая, отдельные строки «Blocked by #N») не
    # затронут — он разбирается отдельным findall «#(\d+)» ниже, по всей
    # захваченной строке, а не этим \s+.
    for m in re.finditer(r"Blocked by[ \t]+([^\n]*)", body or ""):
        out.update(int(x) for x in re.findall(r"#(\d+)", m.group(1)))
    return out


def labels_of(it):
    return {l.get("name", "") for l in (it.get("labels") or [])}


def type_of(it):
    names = labels_of(it)
    if task_label in names:
        return "task"
    if bug_label in names:
        return "bug"
    if ff_label in names:
        return "fastFollow"
    if consolidate_label in names:
        return "consolidate"
    return "task"


# issue #218, ADR-024: issue со строкой «Спека: docs/specs/NNN-<слаг>.md»
# чей файл ещё не в origin/$default_branch — спека ждёт человека
# (policies.merge блокирует агенту merge PR спеки, /plan шаг 5).
# Симметрично owner:human ниже: issue без такой строки (не из /plan, или
# спека уже была в main — ADR-009) проверке не подлежит.
#
# Контракт plan.md шаг 4 гарантирует только то, что путь спеки присутствует
# буквальным текстом в строке «Спека: …» — обёртка вокруг него
# (markdown-ссылка, бэктики, **жирный** префикс, хвост вида «(SPEC-NNN)»
# или «[SPEC-NNN: путь](url)») остаётся легальной (ADR-024). Поэтому — без
# жёсткой привязки к позиции: строка содержит литерал «Спека:» где угодно в
# строке, путь — первое вхождение docs/specs/….md в ТОЙ ЖЕ строке,
# независимо от обрамления — буквальная реализация контракта plan.md.
SPEC_LINE_MARKER = "Спека:"
SPEC_PATH_RE = re.compile(r"docs/specs/\S+?\.md")


def spec_missing(it):
    for line in (it.get("body") or "").splitlines():
        if SPEC_LINE_MARKER not in line:
            continue
        m = SPEC_PATH_RE.search(line)
        if m:
            return m.group(0) not in existing_specs
    return False


new_skips = []
new_skip_numbers = set()
already_needs_human = set()
changed = True
while changed:
    changed = False
    for it in issues:
        n = it["number"]
        if n in handled or n in new_skip_numbers or n in already_needs_human:
            continue
        if blockers(it.get("body")) & unresolved:
            # Issue уже с needs-human не была «в очереди» этого прогона —
            # её уже отдали человеку раньше. Она по-прежнему держит своих
            # зависимых заблокированными (остаётся в unresolved), но сама
            # не печатается как SKIP: иначе result=skipped завышал бы
            # счётчик пропущенных задачами, которые и так не были бы
            # взяты в этот прогон (на нём считается maxSkippedShare,
            # AC-5/#134).
            if "needs-human" in labels_of(it):
                already_needs_human.add(n)
            else:
                new_skips.append(it)
                new_skip_numbers.add(n)
            unresolved.add(n)
            changed = True

for it in new_skips:
    print(f"SKIP {it['number']} {type_of(it)}")

excluded = handled | new_skip_numbers

# blocked-on-ready (ADR-014 п.2): задача, ВСЕ открытые блокеры которой уже
# resolved_ready (ready_now этого прогона + prev_blocked_on_ready прошлых
# итераций внешнего цикла), — «на подвеске», не молча потеряна. Неподвижная
# точка ниже — тем же приёмом, что каскад SKIP выше.
#
# Эта же неподвижная точка — единственное место, где select_next собирает
# waiting_for_spec_numbers (issue #218, круг 4 ревью PR #246): `for it in
# issues` на первом же проходе (blocked_on_ready_numbers ещё пуст) проверяет
# КАЖДУЮ не-excluded/needs-human/owner:human задачу этого вызова, поэтому
# множество полно уже после первого прохода — ниже по циклу (ветка
# candidate) просто повторяет ту же проверку для выбора NEXT, не для сбора
# множества. existing_specs здесь — тот самый свежий снимок, который
# select_next уже отфетчил в начале этого вызова (строка выше по файлу) —
# отдельного снимка/копии spec_missing() для сводки больше не нужно.
resolved_ready = set(ready_now) | prev_blocked_on_ready
blocked_on_ready_numbers = set()
waiting_for_spec_numbers = set()
changed = True
while changed:
    changed = False
    for it in issues:
        n = it["number"]
        if n in excluded or n in blocked_on_ready_numbers:
            continue
        if "needs-human" in labels_of(it):
            continue
        if "owner:human" in labels_of(it):
            continue
        if spec_missing(it):
            waiting_for_spec_numbers.add(n)
            continue
        open_blockers = blockers(it.get("body")) & open_numbers
        if open_blockers and open_blockers <= resolved_ready:
            blocked_on_ready_numbers.add(n)
            resolved_ready.add(n)
            changed = True

candidate = None
for it in issues:
    n = it["number"]
    if n in excluded or n in blocked_on_ready_numbers:
        continue
    if "needs-human" in labels_of(it):
        continue
    if "owner:human" in labels_of(it):
        # Зарезервирован человеком (issue #158) — не кандидат этого прогона,
        # но и не «застрял»/«пропущен»: остаётся открытым, дальше по циклу.
        # Дальнейшие исходы (needs-human/result=) на неё не действуют.
        continue
    if spec_missing(it):
        # Спека вехи ждёт человека (issue #218, ADR-024) — тот же принцип:
        # не кандидат, но и не «застрял»/«пропущен». Уже учтена в
        # waiting_for_spec_numbers неподвижной точкой blocked-on-ready выше.
        continue
    if blockers(it.get("body")) & open_numbers:
        continue
    candidate = it
    break

for it in issues:
    if it["number"] in blocked_on_ready_numbers:
        print(f"BLOCKED_ON_READY {it['number']} {type_of(it)}")

for it in issues:
    if it["number"] in waiting_for_spec_numbers:
        print(f"WAITING_SPEC {it['number']} {type_of(it)}")

if candidate:
    sized = "large" if "size:large" in labels_of(candidate) else "-"
    print(f"NEXT {candidate['number']} {type_of(candidate)} {sized}")
else:
    print("NONE")
PYEOF
}

# find_pr_state <issue> — печатает "ready"/"draft"/"none"/"error" (поиск PR
# по префиксу ветки, различение сбоя gh от «PR не создан» — ADR-007 §2/§4).
find_pr_state() {
  local issue_num="$1" pr_json rc parsed pr_count
  pr_json=$(cd "$root" && gh pr list --state open \
    --json number,isDraft,headRefName --limit 200 2>"$work_dir/gh-pr-list.err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error'
    return
  fi
  # Усечение --limit 200 дороже здесь, чем у gh issue list: пропущенный в
  # выборке PR читается как «PR не создан» → липкий needs-human, а не
  # просто как неполный список для следующего прогона. Предупреждение —
  # один раз за прогон (issues повторяют этот вызов на каждой итерации).
  # Флаг живёт файлом в $work_dir, а не переменной: find_pr_state вызывается
  # через `$(...)` (командная подстановка = подоболочка), присваивание
  # переменной в ней не долетело бы до родительского процесса — предупреждение
  # печаталось бы на каждой итерации, не один раз за прогон (важно круга 4
  # ревью PR #141).
  if [ ! -e "$work_dir/pr_list_truncation_warned" ]; then
    pr_count=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    if [ "$pr_count" -eq 200 ] 2>/dev/null; then
      echo "adk-ralph: gh pr list вернул ровно 200 открытых PR — список мог быть" \
        "усечён лимитом; «PR не создан» не гарантирует, что искомый PR" \
        "действительно отсутствует." >&2
      : >"$work_dir/pr_list_truncation_warned"
    fi
  fi
  # rc=0 не гарантирует валидный JSON (gh мог напечатать частичный вывод) —
  # разбор, упавший сам по себе, — тот же класс факта, что и сбой gh: не
  # «PR не создан», а «не удалось узнать», иначе один и тот же баг вернулся
  # бы другим путём (issue #139, круг 2 ревью PR #141).
  parsed=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    prefix = "issue-" + sys.argv[1] + "-"
    matches = [d for d in data if d.get("headRefName", "").startswith(prefix)]
    if not matches:
        print("none")
    else:
        matches.sort(key=lambda d: d["number"])
        print("draft" if matches[-1].get("isDraft") else "ready")
except Exception:
    print("error")
' "$issue_num")
  printf '%s' "${parsed:-error}"
}

# find_pr_number <issue_num> — тот же поиск по префиксу ветки issue-<N>-
# (ADR-007 §2: наибольший номер при нескольких совпадениях), что и
# find_pr_state, но печатает номер PR ("error" при сбое/отсутствии), а не
# состояние draft/ready. Отдельная функция, не расширение find_pr_state:
# контракт find_pr_state (ready/draft/none/error) уже используют вызовы до
# этой задачи (issue #147, ADR-014) — менять его формат вывода ради одного
# нового потребителя (issue #129, merge) рискованно. Стоит ralph лишний
# `gh pr list` на каждую задачу, доходящую до merge-развилки — тот же
# компромисс, что уже принят ADR-014 (предстартовая проверка ready-PR).
find_pr_number() {
  local issue_num="$1" pr_json rc
  pr_json=$(cd "$root" && gh pr list --state open \
    --json number,headRefName --limit 200 2>"$work_dir/gh-pr-list-merge.err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error'
    return
  fi
  printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    prefix = "issue-" + sys.argv[1] + "-"
    matches = [d for d in data if d.get("headRefName", "").startswith(prefix)]
    if not matches:
        print("error")
    else:
        matches.sort(key=lambda d: d["number"])
        print(matches[-1]["number"])
except Exception:
    print("error")
' "$issue_num"
}

# ci_workflows_configured <sha> — «yes», если в запушенной голове (по SHA, не
# по рабочему дереву) в .github/workflows есть любой файл *.yml|*.yaml; «no» —
# каталога нет или таких файлов нет; «error» — git не смог прочитать дерево.
# Содержимое и триггеры не разбираются сознательно (ADR-025 п.4): любая
# неоднозначность — «настроен», -z держит пути с не-ASCII без квотирования.
ci_workflows_configured() {
  local sha="$1" listing="$work_dir/git-ls-tree-workflows.out" entry
  if ! (cd "$root" && git ls-tree -z --name-only "$sha" -- .github/workflows/) \
    >"$listing" 2>"$work_dir/git-ls-tree-workflows.err"; then
    printf 'error'
    return
  fi
  while IFS= read -r -d '' entry; do
    case "$entry" in
      *.yml|*.yaml)
        printf 'yes'
        return
        ;;
    esac
  done <"$listing"
  printf 'no'
}

ci_poll_status() {
  local pr="$1" sha="$2" body
  if ! body=$(cd "$root" && gh pr view "$pr" --json headRefOid,statusCheckRollup 2>"$work_dir/gh-pr-view-ci.err"); then
    printf 'ERROR'
    return
  fi
  printf '%s' "$body" | python3 -c '
import json, sys

def clean(text):
    return " ".join(str(text).replace(chr(34), chr(39)).split())[:80]

def classify(item):
    kind = item.get("__typename")
    if kind == "CheckRun":
        status = str(item.get("status") or "").upper()
        conclusion = str(item.get("conclusion") or "").upper()
        name = item.get("name") or "?"
        if status in ("QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"):
            return "pending", name, ""
        if status != "COMPLETED":
            return "unknown", name, "status=" + status
        if conclusion in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            return "ok", name, ""
        if conclusion in ("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"):
            return "red", name, ""
        return "unknown", name, "conclusion=" + conclusion
    if kind == "StatusContext":
        state = str(item.get("state") or "").upper()
        name = item.get("context") or "?"
        if state == "SUCCESS":
            return "ok", name, ""
        if state in ("PENDING", "EXPECTED"):
            return "pending", name, ""
        if state in ("FAILURE", "ERROR"):
            return "red", name, ""
        return "unknown", name, "state=" + state
    return "unknown", str(item.get("name") or item.get("context") or "?"), "type=" + str(kind)

try:
    data = json.load(sys.stdin)
    head = data["headRefOid"]
    rollup = data["statusCheckRollup"]
    if not isinstance(head, str) or not isinstance(rollup, list):
        raise ValueError
    results = [classify(item) for item in rollup]
except Exception:
    print("ERROR")
    sys.exit(0)

if head != sys.argv[1]:
    print("STALE_HEAD")
elif not results:
    print("NONE")
else:
    red = [clean(n) for k, n, _ in results if k == "red"]
    unknown = [clean(n + " (" + d + ")") for k, n, d in results if k == "unknown"]
    if red:
        print("RED " + ", ".join(red[:5]))
    elif unknown:
        print("UNKNOWN " + ", ".join(unknown[:5]))
    elif any(k == "pending" for k, _, _ in results):
        print("PENDING")
    else:
        print("GREEN")
' "$sha" 2>/dev/null
}

wait_ci_green() {
  local pr="$1" sha="$2" configured started elapsed status errors=0 greens=0
  configured=$(ci_workflows_configured "$sha")
  if [ "$configured" = "error" ]; then
    printf 'CI_STUCK не удалось определить, настроен ли CI (чтение .github/workflows в запушенной голове)'
    return 0
  fi
  started=$SECONDS
  echo "adk-ralph: ожидание CI PR #$pr (до ${ci_wait_seconds}s, голова ${sha:0:12})" >&2
  while :; do
    status=$(ci_poll_status "$pr" "$sha")
    elapsed=$((SECONDS - started))
    case "$status" in
      GREEN)
        errors=0
        greens=$((greens + 1))
        if [ "$greens" -ge 2 ]; then
          printf 'CI_GREEN'
          return 0
        fi
        ;;
      PENDING)
        errors=0
        greens=0
        ;;
      NONE)
        errors=0
        greens=0
        if [ "$configured" = "no" ]; then
          printf 'CI_NONE'
          return 0
        fi
        if [ "$elapsed" -ge "$ci_appear_seconds" ]; then
          printf 'CI_STUCK проверки CI не появились за %ss после push (в .github/workflows есть workflow-файл)' "$elapsed"
          return 0
        fi
        ;;
      STALE_HEAD)
        errors=0
        greens=0
        if [ "$elapsed" -ge "$ci_appear_seconds" ]; then
          printf 'CI_STUCK GitHub не показал запушенную голову PR за %ss (headRefOid не совпал с локальным HEAD)' "$elapsed"
          return 0
        fi
        ;;
      RED\ *)
        printf 'CI_STUCK CI красный: %s' "${status#RED }"
        return 0
        ;;
      UNKNOWN\ *)
        printf 'CI_STUCK неизвестное состояние проверки CI: %s' "${status#UNKNOWN }"
        return 0
        ;;
      *)
        greens=0
        errors=$((errors + 1))
        if [ "$errors" -ge 3 ]; then
          cat "$work_dir/gh-pr-view-ci.err" >&2 2>/dev/null
          printf 'CI_STUCK не удалось получить статус CI (gh pr view)'
          return 0
        fi
        ;;
    esac
    if [ "$elapsed" -ge "$ci_wait_seconds" ]; then
      printf 'CI_STUCK CI не завершился за %ss (policies.autopilot.budget.ci.maxMinutes)' "$elapsed"
      return 0
    fi
    sleep "$ci_poll_interval"
  done
}

# resolve_ready_pr <issue_num> — исход «PR ready» (issue #129,
# SPEC-003 AC-1, ADR-019): решает, мержить ли ready-PR по политике проекта,
# и при необходимости актуализирует ветку и мержит. Печатает ровно одну из
# трёх строк (тот же приём, что SKIP/BLOCKED_ON_READY у select_next — вызывающий
# код разбирает первое слово через `case`):
#   MERGED           — PR смержен, ветка удалена;
#   READY            — merge не выполнен (fail-closed на неизвестном
#                       значении конфига, human-only, human-review-required
#                       без approve) — задача остаётся в бакете «ждут
#                       человека», как и раньше этой задачи;
#   STUCK <причина>  — конфликт/красные гейты/не удалось узнать статус —
#                       задача застревает (needs-human), прогон продолжается.
#
# Канонический рецепт актуализации/merge — шаг 6 commands/work.md; отличия
# автопилота (bash, не интерактивная сессия) — шаг 3 commands/autopilot.md.
# Здесь — ТОЛЬКО отличия ralph от обоих (см. ADR-019 за полным обоснованием
# каждого пункта):
# - ralph не знает mergeStateStatus заранее и не сидит на ветке PR между
#   итерациями — конфликтность/ветка берутся явным `gh pr view`, отставание —
#   явным `git fetch` + `git rev-list origin/<ветка>..origin/<default_branch>`
#   (тот же приём, что шаг 3 /autopilot, не от HEAD; `default_branch` — та
#   же переменная, что ADR-007 §6, не хардкод "main");
# - `gh pr view --json mergeable` иногда отвечает "UNKNOWN", пока GitHub
#   считает mergeability — до 3 попыток с паузой 1с (ADR-019 §2), после чего
#   неопределённость — тоже причина застревания, не бесконечный ретрай;
# - policies.merge=human-review-required требует человеческого approve —
#   ralph берёт факт из `gh pr view --json reviewDecision` (тот же признак,
#   что канон /autopilot и bash-guard.sh).
resolve_ready_pr() {
  local issue_num="$1"
  local can_merge can_merge_rc merge_policy merge_policy_rc

  # Fail-closed на неизвестное значение — та же дисциплина, что bash-guard.sh
  # (policies.merge) и остальной разбор конфига этим скриптом (enabled выше):
  # ненулевой exit adk_config_get — не отсутствие атрибута (за это отвечает
  # exit 0 + дефолт lib/config.sh), а опечатка в значении, которую нельзя
  # молча трактовать как разрешение на merge.
  can_merge=$(adk_config_get "policies.autopilot.canMerge" "true" "true,false")
  can_merge_rc=$?
  merge_policy=$(adk_config_get "policies.merge" "agent-after-approve" \
    "agent-after-approve,human-review-required,human-only")
  merge_policy_rc=$?

  if [ "$can_merge_rc" -ne 0 ] || [ "$merge_policy_rc" -ne 0 ]; then
    printf 'READY'
    return 0
  fi
  if [ "$can_merge" != "true" ] || [ "$merge_policy" = "human-only" ]; then
    printf 'READY'
    return 0
  fi

  local pr_number pushed_sha=""
  pr_number=$(find_pr_number "$issue_num")
  if [ "$pr_number" = "error" ]; then
    printf 'STUCK не удалось определить номер PR для merge'
    return 0
  fi

  # Один вызов на mergeable+reviewDecision+headRefName (тот же приём, что
  # bash-guard.sh: adk_gh_pr_fields, lib/paths.sh) — reviewDecision нужен
  # только при human-review-required, но лишнее поле в одном запросе дешевле
  # второго отдельного вызова gh. UNKNOWN на mergeable — до 3 попыток с
  # паузой 1с (ADR-019 §2); reviewDecision в этом ретрае не участвует —
  # опрашивается той же строкой на последней попытке.
  local pr_fields mergeable review_decision pr_branch attempt=0 max_attempts=3
  while :; do
    attempt=$((attempt + 1))
    pr_fields=$(adk_gh_pr_fields "$pr_number" "" "$root" \
      "mergeable,reviewDecision,headRefName" \
      '"\(.mergeable) \(.reviewDecision) \(.headRefName)"')
    case "$pr_fields" in
      *' '*' '*)
        mergeable="${pr_fields%% *}"
        review_decision="${pr_fields#* }"
        review_decision="${review_decision%% *}"
        pr_branch="${pr_fields##* }"
        ;;
      *)
        mergeable=""
        review_decision=""
        pr_branch=""
        ;;
    esac
    if [ "$mergeable" != "UNKNOWN" ] || [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "$mergeable" ] || [ -z "$pr_branch" ]; then
    printf 'STUCK не удалось получить статус PR (gh pr view)'
    return 0
  fi

  if [ "$merge_policy" = "human-review-required" ] && [ "$review_decision" != "APPROVED" ]; then
    printf 'READY'
    return 0
  fi

  if [ "$mergeable" = "CONFLICTING" ]; then
    # "конфликт с $default_branch" — на большинстве проектов default_branch
    # это буквально "main" (текст совпадает с каноном autopilot.md), но не
    # хардкод: репозиторий с другим default branch получает точную причину,
    # той же дисциплиной, что круг 1 ревью PR #195 (origin/$default_branch
    # вместо origin/main выше).
    printf 'STUCK конфликт с %s' "$default_branch"
    return 0
  fi
  if [ "$mergeable" != "MERGEABLE" ]; then
    printf 'STUCK не удалось определить конфликтность PR (mergeable=%s)' "$mergeable"
    return 0
  fi

  if ! (cd "$root" && git fetch origin) >"$work_dir/git-fetch-merge.err" 2>&1; then
    printf 'STUCK не удалось обновить origin (git fetch)'
    return 0
  fi
  # default_branch — та же переменная, что вычисляет цикл ниже фактически
  # (ADR-007 §6, `git symbolic-ref --short refs/remotes/origin/HEAD`, не
  # хардкод "main"): она уже присвоена глобально к моменту вызова этой
  # функции (вызывается только изнутри цикла, после присваивания). Отказ
  # или пустой/нечисловой вывод rev-list — неопределённое состояние
  # отставания, не «ветка актуальна»: fail-open здесь означал бы merge без
  # актуализации и без повторного прогона гейтов (круг 1 ревью PR #195).
  local behind behind_rc
  behind=$(cd "$root" && git rev-list --count "origin/$pr_branch..origin/$default_branch" 2>/dev/null)
  behind_rc=$?
  case "$behind" in
    ''|*[!0-9]*) behind_rc=1 ;;
  esac
  if [ "$behind_rc" -ne 0 ]; then
    printf 'STUCK не удалось определить отставание ветки (git rev-list)'
    return 0
  fi

  if [ "$behind" -gt 0 ]; then
    # Способ актуализации — conventions.branchUpdate, тот же атрибут, что шаг
    # 6 /work; ненулевой exit = опечатка в конфиге, застревание задачи (не
    # остановка прогона — отличие от enabled выше, который останавливает
    # прогон до его старта, здесь же прогон уже идёт по очереди issues).
    local branch_update bu_rc
    branch_update=$(adk_config_get "conventions.branchUpdate" "rebase" "rebase,merge")
    bu_rc=$?
    if [ "$bu_rc" -ne 0 ]; then
      printf 'STUCK неизвестное значение conventions.branchUpdate в конфиге'
      return 0
    fi

    if ! (cd "$root" && gh pr checkout "$pr_number") >"$work_dir/gh-pr-checkout.err" 2>&1; then
      printf 'STUCK не удалось выполнить gh pr checkout'
      return 0
    fi

    local update_rc
    if [ "$branch_update" = "merge" ]; then
      (cd "$root" && git merge "origin/$default_branch") >"$work_dir/git-update-merge.err" 2>&1
      update_rc=$?
    else
      (cd "$root" && git rebase "origin/$default_branch") >"$work_dir/git-update-merge.err" 2>&1
      update_rc=$?
    fi
    if [ "$update_rc" -ne 0 ]; then
      if [ "$branch_update" = "merge" ]; then
        (cd "$root" && git merge --abort) >/dev/null 2>&1 || true
      else
        (cd "$root" && git rebase --abort) >/dev/null 2>&1 || true
      fi
      printf 'STUCK конфликт при актуализации'
      return 0
    fi

    # Гейты — порядок «гейты → push», как в каноне шага 6 /work: публиковать
    # неактуализированную/непроверенную голову раньше собственных гейтов
    # значило бы затем второй force-push поверх неё.
    if [ -x "$root/scripts/check" ]; then
      if ! (cd "$root" && ./scripts/check) >"$work_dir/merge-gates.log" 2>&1; then
        cat "$work_dir/merge-gates.log" >&2
        printf 'STUCK гейты красные после актуализации'
        return 0
      fi
    fi
    if [ -x "$root/scripts/test" ]; then
      if ! (cd "$root" && ./scripts/test) >"$work_dir/merge-gates.log" 2>&1; then
        cat "$work_dir/merge-gates.log" >&2
        printf 'STUCK гейты красные после актуализации'
        return 0
      fi
    fi

    if [ "$branch_update" = "merge" ]; then
      (cd "$root" && git push origin "$pr_branch") >"$work_dir/git-push-merge.err" 2>&1
    else
      (cd "$root" && git push --force-with-lease origin "$pr_branch") >"$work_dir/git-push-merge.err" 2>&1
    fi
    if [ $? -ne 0 ]; then
      cat "$work_dir/git-push-merge.err" >&2
      printf 'STUCK не удалось запушить актуализированную ветку'
      return 0
    fi

    pushed_sha=$(cd "$root" && git rev-parse HEAD 2>/dev/null)
    case "$pushed_sha" in
      ''|*[!0-9a-f]*)
        printf 'STUCK не удалось определить запушенную голову ветки (git rev-parse HEAD)'
        return 0
        ;;
    esac

    local ci_result ci_reason
    ci_result=$(wait_ci_green "$pr_number" "$pushed_sha")
    if [ "$ci_result" != "CI_GREEN" ] && [ "$ci_result" != "CI_NONE" ]; then
      ci_reason="${ci_result#CI_STUCK }"
      [ -n "$ci_reason" ] || ci_reason="не удалось дождаться CI (пустой ответ ожидания)"
      printf 'STUCK %s' "$ci_reason"
      return 0
    fi
  fi

  # Флаг слияния — производная conventions.squash × conventions.branchUpdate
  # (adk_config_merge_method, lib/config.sh), не хардкод squash (issue #129
  # DoD: «не зашивать squash»).
  # adk_merge_method (lib/config.sh) — чистая функция, печатает ровно одно
  # из трёх значений ниже (нет четвёртого случая для defensive-ветки: круг
  # 1 ревью PR #195 — defensive `*) --squash` сама была бы хардкодом,
  # которого просит избежать issue #129 DoD).
  local merge_method merge_flag
  merge_method=$(adk_config_merge_method)
  case "$merge_method" in
    squash-merge) merge_flag="--squash" ;;
    rebase-merge) merge_flag="--rebase" ;;
    merge-commit) merge_flag="--merge" ;;
  esac

  if ! (cd "$root" && gh pr merge "$pr_number" "$merge_flag" --delete-branch \
    ${pushed_sha:+--match-head-commit "$pushed_sha"}) \
    >"$work_dir/gh-pr-merge.err" 2>&1; then
    cat "$work_dir/gh-pr-merge.err" >&2
    printf 'STUCK gh pr merge не удался'
    return 0
  fi

  printf 'MERGED'
}

# mark_stuck <issue_num> <issue_type> <reason> — общий путь застревания
# задачи для обеих точек: ветки STUCK finish_ready_outcome и основного
# stuck-пути цикла (issue #209, до него ~25 строк были продублированы и уже
# расходились на практике — порядок «счётчики до журнала», круг 1 ревью
# PR #191). Метка needs-human — единственный механизм HITL: об отказе gh
# нельзя молчать (без громкого предупреждения журнал и уведомление
# утверждали бы stuck, а метки не было бы, и следующий прогон взял бы issue
# заново), но это и не блокер прогона. Отказ gh issue edit (issue #216) не
# только громкое предупреждение в stderr — он дописывается в сам $reason
# ДО того, как этот $reason уйдёт в уведомление/сводку/журнал: без этого
# все три канала молчаливо звучали бы так, будто issue штатно выведен из
# очереди меткой, хотя метка не встала и следующий прогон отберёт issue
# заново (цикл «застрял → выбран → застрял»). Счётчики — до записи в
# журнал (issue #135: сводка прогона — второй канал, которому нельзя
# молчать об этом issue, если запись в журнал откажет), затем event=task
# result=stuck, затем breaker уровня прогона (issue #134, ADR-016 §1) сразу
# после инкремента stuck_count — само срабатывание откладывается до общей
# точки цикла. Возвращает 0 — штатно; 1 — отказала запись журнала
# (journal_break уже выставил stop_reason). Решение о
# return_to_default_branch остаётся у вызывающего кода: на пути с грязным
# деревом после прерывания по бюджету дерево трогать нельзя (ADR-017 §4).
mark_stuck() {
  local issue_num="$1" issue_type="$2" reason="$3"
  (cd "$root" && gh label create needs-human >/dev/null 2>&1) || true
  if ! (cd "$root" && gh issue edit "$issue_num" --add-label needs-human) \
    >/dev/null 2>"$work_dir/gh-issue-edit.err"; then
    echo "adk-ralph: не удалось пометить issue #$issue_num меткой needs-human:" >&2
    cat "$work_dir/gh-issue-edit.err" >&2
    reason="$reason — needs-human НЕ поставлена (сбой gh issue edit), issue остаётся в очереди и будет выбран повторно"
  fi
  "$notifier" "Ralph" "issue #$issue_num застрял: $reason" || true
  stuck=$(csv_add "$stuck" "$issue_num")
  stuck_count=$((stuck_count + 1))
  stuck_summary="$stuck_summary #$issue_num ($reason)"
  if ! "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=stuck reason="$reason" $task_extra; then
    journal_break
    return 1
  fi
  if run_breaker_check_stuck; then
    run_breaker_reason="breaker: застревания за прогон"
  fi
  return 0
}

# finish_ready_outcome <issue_num> <issue_type> <reused: true|false> — общая
# точка исходов «PR ready» (issue #129, ADR-019) для обеих веток вызова,
# использующих find_pr_state в этом скрипте: предстартовой (issue уже был
# ready до запуска claude -p, ADR-014 §1, reused=true) и обычной (claude -p
# только что вывел PR в ready). Раскладывает результат resolve_ready_pr по
# счётчикам/журналу тем же порядком «счётчики до записи в журнал», что и
# остальной код этого скрипта (issue #135, круг 1 ревью PR #191): если
# "$logger" ниже откажет, задача всё равно останется в сводке/уведомлении —
# единственном оставшемся канале. Не трогает `handled` — вызывающий код
# делает это сам той же строкой, что и ветка draft/none (общий код перед
# if/else). Возвращает 0 — цикл продолжается штатно; 1 — отказала запись
# журнала или пришёл нераспознанный ответ resolve_ready_pr (journal_break/
# stop_reason уже выставлены), вызывающий код обязан прервать внешний while
# сам — bash не даёт функции `break` чужой цикл.
finish_ready_outcome() {
  local issue_num="$1" issue_type="$2" reused="$3" resolved reason

  resolved=$(resolve_ready_pr "$issue_num")

  case "$resolved" in
    MERGED)
      merged_nums=$(csv_add "$merged_nums" "$issue_num")
      merged_count=$((merged_count + 1))
      merged_list="$merged_list #$issue_num"
      if ! "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=merged $task_extra; then
        journal_break
        return 1
      fi
      ;;
    READY)
      ready_nums=$(csv_add "$ready_nums" "$issue_num")
      ready_count=$((ready_count + 1))
      ready_list="$ready_list #$issue_num"
      if [ "$reused" = "true" ]; then
        if ! "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=ready reused=true; then
          journal_break
          return 1
        fi
      elif ! "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=ready $task_extra; then
        journal_break
        return 1
      fi
      ;;
    STUCK\ *)
      reason="${resolved#STUCK }"
      # Общий stuck-путь (mark_stuck): needs-human, уведомление, счётчики,
      # журнал, breaker — тем же порядком, что и draft/none в цикле.
      if ! mark_stuck "$issue_num" "$issue_type" "$reason"; then
        return 1
      fi
      ;;
    *)
      echo "adk-ralph: неожиданный вывод resolve_ready_pr: $resolved" >&2
      stop_reason="внутренняя ошибка обработки ready-PR issue #$issue_num"
      exit_code=1
      return 1
      ;;
  esac
  return 0
}

# ── Default branch — определяется фактически, не хардкодится (issue #144,
# ADR-007 §6). `git symbolic-ref --short refs/remotes/origin/HEAD` даёт то
# же имя, что видит обычный клон после `git remote set-head origin -a`;
# локальное определение недоступно (нет origin, HEAD не выставлен,
# репозиторий свежий/нестандартный) — вторая попытка через `gh repo view`
# (issue #220 п.2). Фолбэк на "main" — только если недоступны оба способа
# (fail-closed). Вычисляется один раз до цикла — смена default branch в
# origin посреди прогона вне области этой задачи (известное ограничение,
# «Последствия» ADR-007).
default_branch=$(cd "$root" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch="${default_branch#origin/}"
if [ -z "$default_branch" ]; then
  default_branch=$(cd "$root" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
fi
default_branch="${default_branch:-main}"

# Issues, чья спека ещё не в default branch (issue #218): для итоговой
# сводки больше нет отдельного снимка/копии spec_missing() здесь (круг 3
# ревью PR #246 — снимок брался один раз на старте, до первого fetch внутри
# select_next, и печатался в конце прогона: задача могла одновременно
# попасть и в Ready, и в «Ждёт спеки»). Вместо этого waiting_for_spec_nums/
# _count/_summary заполняются ниже по циклу из строк `WAITING_SPEC <N>`,
# которые select_next печатает сама (тот же приём, что уже существующий
# BLOCKED_ON_READY) из уже отфетченного на этот конкретный вызов
# existing_specs — см. объявление переменных и неподвижную точку
# blocked-on-ready внутри select_next.

# return_to_default_branch — возврат рабочего дерева на default branch
# между итерациями: единая точка на любом выходе из цикла (обоснование и
# история — ADR-007 §6, issue #144). Отказ checkout — не best-effort:
# незакоммиченные правки слетевшего `claude -p` на ветке задачи — данные,
# потенциально нужные человеку; громкое предупреждение и остановка прогона
# честной причиной вместо force-чекаута.
return_to_default_branch() {
  local current checkout_err rc pull_err pull_rc
  # `git symbolic-ref --short HEAD` (не `git rev-parse --abbrev-ref
  # HEAD`, который на unborn-ветке печатает буквальное "HEAD" с ошибкой;
  # `git branch --show-current` тоже подошёл бы, symbolic-ref выбран как
  # уже используемый в этом файле приём). Пропуск checkout, когда мы и так уже на
  # default_branch, — не оптимизация, а необходимость: `git checkout main`
  # на unborn-ветке "main" сам по себе отказывает
  # ("pathspec 'main' did not match any file(s)"), хотя по факту дерево уже
  # там, где нужно.
  current=$(cd "$root" && git symbolic-ref --short HEAD 2>/dev/null)
  if [ "$current" != "$default_branch" ]; then
    checkout_err=$(cd "$root" && git checkout "$default_branch" 2>&1 >/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "adk-ralph: git checkout $default_branch не удался — рабочее дерево" \
        "осталось на чужой ветке (возможно, дочерний процесс оставил" \
        "незакоммиченные изменения):" >&2
      printf '%s\n' "$checkout_err" >&2
      return 1
    fi
  fi
  # `--no-rebase` (стратегия зафиксирована явно, не зависит от ambient
  # `pull.rebase`) + различение через MERGE_HEAD ниже — см. ADR-015 §2 за
  # полным обоснованием. Захватываем stdout и stderr вместе (не только
  # stderr, как у checkout_err выше): диагностика конфликта у git — в
  # stdout ("Automatic merge failed...").
  pull_err=$(cd "$root" && git pull --no-rebase 2>&1)
  pull_rc=$?
  if [ "$pull_rc" -ne 0 ]; then
    if git -C "$root" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      # Настоящий git-конфликт (MERGE_HEAD есть) — не обычный сбой `git
      # pull` без конфликта (нет origin, сеть), тот остаётся best-effort,
      # счётчик не растёт (ADR-015 §2). Прерываем merge, чтобы не оставить
      # дерево в merge-in-progress следующей итерации.
      (cd "$root" && git merge --abort) >/dev/null 2>&1 || true
      actualization_conflict_streak=$((actualization_conflict_streak + 1))
      echo "adk-ralph: git pull --no-rebase на $default_branch завершился" \
        "конфликтом слияния ($actualization_conflict_streak подряд):" >&2
      printf '%s\n' "$pull_err" >&2
      if [ "$actualization_conflict_streak" -ge "$actualization_conflict_threshold" ]; then
        actualization_breaker_tripped=1
      fi
    else
      actualization_conflict_streak=0
    fi
  else
    actualization_conflict_streak=0
  fi
  return 0
}

# run_main_gates — системный breaker «красные гейты main» (AC-5 уровня
# системы, ADR-015 §1): scripts/check и scripts/test (docs/contract.md) на
# default branch перед стартом КАЖДОЙ итерации. Отсутствие исполняемого
# файла — переходное состояние без контракта, не ошибка: гейт молча
# пропускается (тем же приёмом, что hooks/scripts/stop-test.sh).
run_main_gates() {
  local out rc
  if [ -x "$root/scripts/check" ]; then
    out=$(cd "$root" && ./scripts/check 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "adk-ralph: scripts/check на $default_branch провалился (exit $rc):" >&2
      printf '%s\n' "$out" >&2
      return 1
    fi
  fi
  if [ -x "$root/scripts/test" ]; then
    out=$(cd "$root" && ./scripts/test 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "adk-ralph: scripts/test на $default_branch провалился (exit $rc):" >&2
      printf '%s\n' "$out" >&2
      return 1
    fi
  fi
  return 0
}

# ── Бюджеты (issues #131/#132, SPEC-003 «Жёсткие бюджеты», AC-3; ADR-017) —
# в отличие от breaker'ов выше, это не реакция на содержимое очереди issues,
# а безусловные потолки: длительности и расхода токенов одной задачи и
# прогона целиком. Конфиг времени — в минутах, внутри скрипт считает целые
# секунды ($SECONDS — bash-таймер целых секунд); докс — docs/config.md.
#
# Вся валидация числовых атрибутов конфига — одна функция config_number
# (issue #210, до неё пять разнородных python-вставок с неполным набором
# проверок): isfinite против nan/inf (сравнение с nan всегда false — порог
# молча выключался бы, issue #213; у минутных бюджетов nan/inf и без
# isfinite ловил бы тот же except — явная проверка там ради осмысленной
# валидации, см. ADR-017 §3; у sizeLargeMultiplier isfinite ещё и
# защищает от трейса во вставке эффективных бюджетов), OverflowError
# против конечных, но переполняющих арифметику
# значений ("1e307"/"1e308" проходят isfinite, а minutes * 60 как float
# переполняется в inf ДО клампа — int(round(inf)) кидает OverflowError;
# без перехвата python падал бы трейсом, stdout пуст, [ … -ge "" ] молча
# всегда false — бюджет фактически отключён, круг 2 ревью PR #193), клампы
# и единый формат предупреждения. Невалидное значение — предупреждение в
# stderr и дефолт: бюджеты жёсткие по спеке, «без лимита» ими не
# выражается, ноль/отрицательное — не «выключить». Fallback — тот же парсер
# на строке дефолта из вызова: дублирующихся констант дефолтов больше нет,
# расхождение fallback'а с таблицей доки невозможно по построению.
# Верхние потолки — единственный источник для всех потребителей ниже
# (включая эффективные бюджеты size:large в цикле):
clamp_budget_seconds=1000000000       # 10**9 с (~31 год): защита 64-битной $(( ))
clamp_budget_tokens=1000000000000000  # 10**15: потолок писателя журнала (ADR-001)
clamp_stuck_threshold=1000000000000000000  # 10**18 (< 2**63-1): порог stuck
                                      # сравнивает bash ([ -ge ]) — большее
                                      # целое ломало бы его (круг 1 PR #227)
# config_number <путь> <дефолт> <режим> — печатает валидированное число.
# Режимы: nonneg_int (целое >= 0, кламп clamp_stuck_threshold),
# nonneg_float (конечное число >= 0),
# positive_minutes (конечное число минут > 0 — печатает целые СЕКУНДЫ с
# клампом [1, clamp_budget_seconds]), positive_tokens (целое > 0, кламп
# clamp_budget_tokens), multiplier_ge1 (конечное число >= 1: меньший
# множитель дал бы крупной задаче бюджет меньше типовой). Имя без
# adk_-префикса: функция локальна для ralph, префикс — конвенция экспорта
# из hooks/scripts/lib/*.sh (ADR-002).
config_number() {
  local path="$1" default="$2" mode="$3" raw
  raw=$(adk_config_get "$path" "$default")
  python3 -c '
import math, sys
path, raw, default, mode, clamp_s, clamp_t, clamp_i = sys.argv[1:8]
DESCRIPTION = {
    "nonneg_int": "не целое неотрицательное число",
    "nonneg_float": "не число",
    "positive_minutes": "не положительное число минут",
    "positive_tokens": "не положительное целое токенов",
    "multiplier_ge1": "не число >= 1",
}[mode]
def parse(text):
    if mode == "nonneg_int":
        value = int(text)
        if value < 0:
            raise ValueError
        # сравнение порога делает bash ([ -ge ]) — целое больше 2**63-1
        # ломало бы его «integer expression expected» с rc=2 (блокер
        # круга 1 ревью PR #227); счётчики прогона до клампа не дорастают
        return min(value, int(clamp_i))
    if mode == "positive_tokens":
        value = int(text)
        if value <= 0:
            raise ValueError
        return min(value, int(clamp_t))
    value = float(text)
    if not math.isfinite(value):
        raise ValueError
    if mode == "positive_minutes":
        if value <= 0:
            raise ValueError
        return min(max(1, int(round(value * 60))), int(clamp_s))
    if mode == "multiplier_ge1":
        if value < 1:
            raise ValueError
        return value
    # nonneg_float
    if value < 0:
        raise ValueError
    return value
try:
    result = parse(raw)
except (TypeError, ValueError, OverflowError):
    sys.stderr.write(
        "adk-ralph: %s=%r — %s, использован дефолт %s\n"
        % (path, raw, DESCRIPTION, default)
    )
    result = parse(default)
print(result)
' "$path" "$raw" "$default" "$mode" "$clamp_budget_seconds" "$clamp_budget_tokens" \
  "$clamp_stuck_threshold"
}

# parse_claude_tokens <файл stdout claude -p --output-format json> — сумма
# input + output + cache_creation, БЕЗ cache_read (issue #132, состав —
# ADR-001 «Расширения схемы»: cache_read на порядок больше и отражает
# кэш-политику, не объём работы). Нет файла / не JSON / нет usage —
# ненулевой exit: поле tokens не пишется, токеновый бюджет задачи не
# энфорсится, прогон продолжается (переходное состояние спеки).
parse_claude_tokens() {
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    u = data["usage"]
    total = int(u.get("input_tokens", 0)) + int(u.get("output_tokens", 0)) \
        + int(u.get("cache_creation_input_tokens", 0))
except Exception:
    sys.exit(1)
print(total)
' "$1"
}

task_budget_seconds=$(config_number "policies.autopilot.budget.task.maxMinutes" "45" positive_minutes)
run_budget_seconds=$(config_number "policies.autopilot.budget.run.maxMinutes" "240" positive_minutes)
# Снимок $SECONDS перед стартом цикла — элапсед прогона везде далее считается
# относительно этой точки, не относительно старта самого интерпретатора bash.
run_start_seconds=$SECONDS
task_token_budget=$(config_number "policies.autopilot.budget.task.maxTokens" "300000" positive_tokens)
# Множитель бюджетов задач с label size:large (issue #133, SPEC-003 AC-4):
# планировщик отличает крупное от типового, но плохо угадывает цифры —
# категория вместо числа. Валидация — общий config_number (число >= 1:
# меньший множитель дал бы крупной задаче бюджет меньше типовой —
# противоречие смыслу атрибута), иначе предупреждение и дефолт 2.
size_multiplier=$(config_number "policies.autopilot.budget.sizeLargeMultiplier" "2" multiplier_ge1)
run_token_budget=$(config_number "policies.autopilot.budget.run.maxTokens" "2000000" positive_tokens)
ci_wait_seconds=$(config_number "policies.autopilot.budget.ci.maxMinutes" "15" positive_minutes)
ci_poll_interval=$(python3 -c '
import math, sys
try:
    value = float(sys.argv[1])
    ok = math.isfinite(value) and value > 0
except ValueError:
    ok = False
print("%.3f" % value if ok else "10")
' "${ADK_RALPH_CI_POLL_SECONDS:-10}")
ci_appear_seconds="${ADK_RALPH_CI_APPEAR_SECONDS:-120}"
case "$ci_appear_seconds" in
  ''|*[!0-9]*) ci_appear_seconds=120 ;;
esac
run_tokens_used=0  # сумма расхода прогона (issue #132) — токеновая половина
                   # бюджета прогона и поле tokens= в event=run_end

# ── Цикл ──────────────────────────────────────────────────────────────────
# exit_code уже != 0 здесь, если gh issue list выше не удался или отказала
# запись event=run_start в журнал (journal_break, issue #135) —
# (stop_reason уже выставлен тем же путём) — цикл в этом случае не
# стартует вовсе, run_end/уведомление печатает общий хвост ниже.
while [ "$exit_code" -eq 0 ]; do
  # Стоп-файл (issue #130, SPEC-003 AC-2) — самая первая проверка на границе
  # итерации, раньше системного breaker'а красных гейтов main ниже и раньше
  # любого другого действия этой итерации: если файл на месте, итерация не
  # начинается вовсе. Полное обоснование приоритета при коллизии с другими
  # причинами остановки — ADR-018.
  if [ -e "$stop_file" ]; then
    stop_reason="стоп-файл"
    exit_code=1
    break
  fi

  # Сброс на каждую итерацию (issue #134, ADR-016): выставляется только
  # внутри ветки result=stuck этой же итерации, ниже.
  run_breaker_reason=""

  # Системный breaker «красные гейты main» — перед стартом КАЖДОЙ итерации,
  # раньше выбора следующей задачи (issue #135) и раньше бюджета прогона
  # ниже: красные гейты запрещают итерацию немедленно, безусловно, даже
  # если следующим шагом был бы просто SKIP/BLOCKED_ON_READY без единого
  # вызова claude. Порядок относительно бюджета прогона — тем же принципом,
  # что и actualization_breaker_tripped vs run_breaker_reason в хвосте
  # итерации ниже: системный уровень (инфраструктура прогона сломана)
  # серьёзнее, чем run-уровень (бюджеты/breaker'ы содержимого очереди),
  # поэтому при коллизии сводка обязана называть системный breaker, не
  # исчерпанный бюджет прогона (ADR-017 §2).
  if ! run_main_gates; then
    stop_reason="системный breaker: красные гейты main"
    exit_code=1
    break
  fi

  # Бюджет прогона (issue #131, ADR-017 §2) — после стоп-файла и системного
  # breaker'а, но раньше выбора следующей задачи: исчерпание не обрывает уже
  # выполняемую задачу (она обработана предыдущей итерацией до этой точки),
  # а лишь запрещает НАЧАТЬ следующую — чистая остановка, текущая задача
  # доведена до вердикта. Сравнение >= (не >): исчерпание ровно на границе
  # выбора тоже останавливает цикл.
  if [ $((SECONDS - run_start_seconds)) -ge "$run_budget_seconds" ]; then
    stop_reason="бюджет прогона по времени"
    exit_code=1
    break
  fi

  # Токеновый бюджет прогона (issue #132) — та же граница и семантика, что
  # у временного выше: чистая остановка, текущая задача уже доведена до
  # вердикта предыдущей итерацией, следующая не берётся; >= — исчерпание
  # ровно на границе тоже останавливает.
  if [ "$run_tokens_used" -ge "$run_token_budget" ]; then
    stop_reason="бюджет прогона по токенам"
    exit_code=1
    break
  fi

  select_out=$(select_next)

  # WAITING_SPEC — в отличие от SKIP/BLOCKED_ON_READY ниже (handled,
  # переживают итерации внешнего цикла), не накапливается: категория не
  # терминальна, спеку могут смержить по ходу прогона, и select_next
  # пересчитывает её заново на каждом вызове из свежего fetch (issue #218,
  # круг 4 ревью PR #246). Поэтому здесь — полная замена перед разбором
  # строк этого вызова, а не csv_add к значению прошлой итерации: к сводке
  # в конце прогона должен дойти список именно последнего вызова.
  waiting_for_spec_nums=""
  waiting_for_spec_count=0
  waiting_for_spec_summary=""

  while IFS= read -r line; do
    case "$line" in
      SKIP\ *)
        skip_num=$(printf '%s' "$line" | awk '{print $2}')
        skip_type=$(printf '%s' "$line" | awk '{print $3}')
        # Счётчики — до записи в журнал, той же логикой и по той же причине,
        # что и у result=ready/result=stuck (issue #135, круг 1 ревью PR #191:
        # если "$logger" ниже откажет, сводка/уведомление — единственный
        # оставшийся канал — не должны потерять пропущенную задачу молча).
        # До этой правки (issue #134) SKIP/BLOCKED_ON_READY обновляли счётчики
        # ПОСЛЕ записи — асимметрия с уже исправленными ready/stuck, замеченная
        # круг 1 ревью PR #191 как отдельная находка вне рамок той задачи.
        handled=$(csv_add "$handled" "$skip_num")
        skipped=$(csv_add "$skipped" "$skip_num")
        skipped_count=$((skipped_count + 1))
        skipped_summary="$skipped_summary #$skip_num"
        if ! "$logger" "$run_unit" event=task issue="$skip_num" type="$skip_type" result=skipped; then
          journal_break
          break
        fi
        ;;
      BLOCKED_ON_READY\ *)
        # ADR-014 (issue #147) — задача ждёт мерджа блокера, а не «застряла»
        # или «пропущена». handled — чтобы select_next не печатал её заново
        # на следующей итерации этого же прогона. Счётчики до записи в
        # журнал — та же симметрия с ready/stuck/skipped, что и выше.
        bor_num=$(printf '%s' "$line" | awk '{print $2}')
        bor_type=$(printf '%s' "$line" | awk '{print $3}')
        handled=$(csv_add "$handled" "$bor_num")
        blocked_on_ready_nums=$(csv_add "$blocked_on_ready_nums" "$bor_num")
        blocked_on_ready_count=$((blocked_on_ready_count + 1))
        blocked_on_ready_summary="$blocked_on_ready_summary #$bor_num"
        if ! "$logger" "$run_unit" event=task issue="$bor_num" type="$bor_type" result=blocked-on-ready; then
          journal_break
          break
        fi
        ;;
      WAITING_SPEC\ *)
        # Issue #218, круг 4 ревью PR #246: НЕ handled, в отличие от SKIP и
        # BLOCKED_ON_READY выше — спека может быть смержена по ходу прогона,
        # issue должен снова стать кандидатом на следующей же итерации без
        # отдельной отметки. Не журналируется (не result=, не аномалия —
        # симметрично owner:human, круг 1 ревью PR #246).
        ws_num=$(printf '%s' "$line" | awk '{print $2}')
        waiting_for_spec_nums=$(csv_add "$waiting_for_spec_nums" "$ws_num")
        waiting_for_spec_count=$((waiting_for_spec_count + 1))
        waiting_for_spec_summary="$waiting_for_spec_summary #$ws_num"
        ;;
    esac
  done <<<"$select_out"

  # Отказ записи журнала внутри каскада SKIP/BLOCKED_ON_READY выше уже
  # прервал внутренний read-цикл (`break` в case видит только его) — этот
  # `break` останавливает и внешний цикл, чтобы не дойти до NEXT/claude -p
  # с уже выставленным exit_code (issue #135).
  if [ "$exit_code" -ne 0 ]; then
    break
  fi

  # Breaker уровня прогона — доля пропущенных (issue #134, ADR-016 §2-3).
  # Проверяется на входе каждой итерации, не только сразу после каскада
  # SKIP выше: знаменатель доли способен впервые достичь минимума и на
  # исходе обычной ready/stuck задачи ниже по циклу (без единого нового
  # SKIP в этой итерации).
  if run_breaker_check_skipped_share; then
    stop_reason="breaker: доля пропущенных за прогон"
    exit_code=1
    break
  fi

  status_line=$(printf '%s' "$select_out" | tail -1)
  case "$status_line" in
    NONE)
      if [ "$blocked_on_ready_count" -gt 0 ]; then
        # issue #147, ADR-014: очередь НЕ пуста — есть задача(и), ждущая
        # мерджа блокера с ready-PR. Отдельная причина остановки, чтобы
        # «очередь пуста» означало ровно то, что говорит (DoD issue #147:
        # прогон не рапортует «очередь пуста», пока такая задача в подвеске).
        stop_reason="доступных задач нет: остались только задачи, заблокированные ready-PR блокера"
      else
        stop_reason="очередь пуста"
      fi
      break
      ;;
    NEXT\ *)
      issue_num=$(printf '%s' "$status_line" | awk '{print $2}')
      issue_type=$(printf '%s' "$status_line" | awk '{print $3}')
      issue_sized=$(printf '%s' "$status_line" | awk '{print $4}')
      ;;
    *)
      echo "adk-ralph: неожиданный вывод выбора задачи: $status_line" >&2
      stop_reason="внутренняя ошибка выбора задачи"
      exit_code=1
      break
      ;;
  esac

  # ── Предстартовая перепроверка состояния issue (issue #220 п.1) ─────────
  # issues_file — статичный снимок "gh issue list --state open" на старте
  # прогона (не перезапрашивается между итерациями, см. open_numbers в
  # select_next выше). merged_now вычитает из очереди только задачи,
  # смерженные ЭТИМ прогоном (ADR-019 §10) — issue, закрытый человеком
  # (или другим процессом) посреди прогона, снимком не замечен и
  # select_next выбрал бы его снова. Один дешёвый gh-вызов прямо перед
  # стартом ловит эту гонку. Сбой самого вызова (сеть, rate limit) не
  # блокирует прогон — issue обрабатывается как раньше (fail-open: пустой
  # $next_issue_state не равен "CLOSED").
  next_issue_state=$(cd "$root" && gh issue view "$issue_num" --json state -q .state 2>/dev/null)
  if [ "$next_issue_state" = "CLOSED" ]; then
    handled=$(csv_add "$handled" "$issue_num")
    closed_externally_nums=$(csv_add "$closed_externally_nums" "$issue_num")
    closed_externally_count=$((closed_externally_count + 1))
    closed_externally_summary="$closed_externally_summary #$issue_num"
    # result=closed-externally — новое значение схемы ADR-001 (аналогично
    # blocked-on-ready), не result=skipped: сознательно не участвует в
    # skipped_count/maxSkippedShare (обоснование — ADR-019 доп.).
    if ! "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=closed-externally reason="issue closed outside this run"; then
      journal_break
      break
    fi
    continue
  fi

  # Эффективные бюджеты задачи (issue #133): label size:large умножает обе
  # половины (минуты и токены) на size_multiplier; без label — базовые.
  effective_task_budget_seconds="$task_budget_seconds"
  effective_task_token_budget="$task_token_budget"
  if [ "${issue_sized:-}" = "large" ]; then
    # Один вызов на оба значения; умножение внутри try с OverflowError и
    # клампами из единого источника (clamp_budget_seconds/clamp_budget_tokens
    # у config_number, issue #210) — иначе валидный по isfinite множитель
    # вида 1e308 давал бы пустой stdout и молча выключенные бюджеты: тот же
    # класс, что чинился для бюджетов (issue #131, круг 2 ревью PR #193;
    # здесь — круг 1 ревью PR #198).
    effective_budgets=$(python3 -c '
import sys
sec, tok, m, clamp_s, clamp_t = sys.argv[1:6]
try:
    esec = min(max(1, int(round(float(sec) * float(m)))), int(clamp_s))
    etok = min(max(1, int(round(float(tok) * float(m)))), int(clamp_t))
except OverflowError:
    esec, etok = int(clamp_s), int(clamp_t)
print(esec, etok)
' "$task_budget_seconds" "$task_token_budget" "$size_multiplier" \
  "$clamp_budget_seconds" "$clamp_budget_tokens")
    effective_task_budget_seconds="${effective_budgets%% *}"
    effective_task_token_budget="${effective_budgets##* }"
  fi

  # ── Предстартовая проверка PR (ADR-014, issue #147) ──────────────────────
  # find_pr_state ДО запуска claude -p, не только после: issue с уже открытым
  # ready-PR не должен гонять work.md с нуля заново. "draft"/"none" — не
  # короткое замыкание, claude -p запускается как обычно.
  pre_pr_state=$(find_pr_state "$issue_num")

  if [ "$pre_pr_state" = "error" ]; then
    echo "adk-ralph: gh pr list не удался при разборе issue #$issue_num:" >&2
    cat "$work_dir/gh-pr-list.err" >&2
    stop_reason="gh pr list не удался при разборе issue #$issue_num"
    exit_code=1
    break
  fi

  # reused_flag — "true" отличает «issue уже был ready до этой итерации»
  # (ADR-014 §1) от «claude -p только что вывел PR в ready» — сам разбор
  # исхода (merge/ready-для-человека/stuck, issue #129) одинаков для обоих,
  # finish_ready_outcome ниже пишет reused=true в журнал только для первого
  # случая. Предстартовый "ready" пропускает claude -p целиком (pr_state
  # известен заранее), но НЕ пропускает возврат дерева/breaker-хвост цикла
  # ниже — merge (resolve_ready_pr) способен подвинуть рабочее дерево
  # (`gh pr checkout`) точно так же, как claude -p, поэтому обе ветки сходятся
  # в один и тот же общий хвост, а не расходятся на `continue` и полный
  # проход цикла, как до issue #129.
  reused_flag="false"
  budget_dirty_tree=""
  # Расход задачи (issue #132): оба поля пишутся только для задач, где
  # claude -p реально запускался этой итерацией; reused/skip/blocked-on-
  # ready остаются без них (ADR-001: поля опциональны).
  task_duration_s=""
  task_tokens=""
  task_extra=""
  if [ "$pre_pr_state" = "ready" ]; then
    reused_flag="true"
    pr_state="ready"
  else
    prompt="$(cat "$work_md")

---
Инструкция ралфа (adk-ralph.sh, issue #139, SPEC-003): выполни шаги выше
целиком для задачи issue #$issue_num. Путь к проекту: $root."

    # Бюджет задачи (issue #131, ADR-017 §1) — claude -p запускается в фоне
    # (exec в подпроцессе — $claude_pid остаётся PID'ом самого claude,
    # независимо от версии bash, а не прослойки subshell), опрос $SECONDS
    # каждые 0.2s решает, жив ли ещё процесс и не истёк ли бюджет. Превышение
    # — SIGTERM группе процессов (`-m` вокруг запуска claude -p ниже даёт
    # фоновому job'у собственный PGID == PID лидера, `kill -- "-$pid"` бьёт лидера и всех
    # потомков одним сигналом — круг 1 ревью PR #193: одиночный `kill "$pid"`
    # оставлял детей claude -p сиротами, дописывающими дерево параллельно со
    # следующей итерацией), до пяти опросов на грациозное завершение, затем
    # SIGKILL группе, только если лидер всё ещё жив (безусловный kill -9 после
    # цикла способен попасть в чужой PID, переиспользованный ОС, если процесс
    # уже был прибран раньше).
    task_iter_start=$SECONDS
    # `-m` включается ТОЛЬКО на время самого запуска (круг 2 ревью PR #193) —
    # только фактический fork ниже получает собственную группу процессов
    # (PGID == PID лидера), нужную позже для group-kill по бюджету; `set +m`
    # сразу после возвращает job control в исходное выключенное состояние для
    # всех остальных foreground-команд скрипта (`gh`, `$logger`, `$notifier`,
    # python-валидаторы) — безусловный `-m` на весь файл (круг 1) ломал им
    # Ctrl-C и переставал перенаправлять stdin фонового job'а в /dev/null.
    # Явный `</dev/null` — та же вторая причина, не подстраховка: без него
    # claude -p, запущенный под `-m`, не получил бы автоматический редирект
    # stdin, который bash даёт background job'ам только при выключенном job
    # control.
    set -m
    # --output-format json + stdout в файл (issue #132): финальный result-
    # JSON несёт usage; живого текстового вывода у -p в этом формате нет,
    # человек читает журнал и сводку. stderr не редиректится — прогресс и
    # ошибки клода остаются в консоли прогона.
    (cd "$root" || exit 1; exec claude -p --output-format json "$prompt") </dev/null >"$work_dir/claude-out.json" &
    claude_pid=$!
    set +m
    task_budget_hit=0
    # Группа с общим `2>/dev/null` (не редирект на отдельных строках) —
    # убитый SIGTERM/SIGKILL background job заставляет сам bash напечатать
    # своё системное «Terminated: 15  ( ... )» в stderr текущего процесса при
    # первой же проверке статуса задачи (kill -0/wait), не как вывод самой
    # команды kill/wait — редирект только на строке wait его не перехватывает,
    # нужна вся группа целиком (проверено эмпирически на bash 3.2 и 5).
    {
      while kill -0 "$claude_pid" 2>/dev/null; do
        if [ $((SECONDS - task_iter_start)) -ge "$effective_task_budget_seconds" ]; then
          task_budget_hit=1
          kill -TERM -- "-$claude_pid" 2>/dev/null || true
          break
        fi
        sleep 0.2
      done
      if [ "$task_budget_hit" -eq 1 ]; then
        for _ in 1 2 3 4 5; do
          kill -0 "$claude_pid" 2>/dev/null || break
          sleep 0.2
        done
        kill -0 "$claude_pid" 2>/dev/null && kill -KILL -- "-$claude_pid" 2>/dev/null
      fi
      wait "$claude_pid"
      claude_rc=$?
    } 2>/dev/null
    # claude_pid пуст вне окна жизни фонового claude -p — обработчик сигнала
    # (ralph_signal_cleanup выше) не должен пытаться добить уже собранный job.
    claude_pid=""
    task_duration_s=$((SECONDS - task_iter_start))

    if [ "$task_budget_hit" -eq 0 ]; then
      # Финальный ответ headless-процесса — обратно в консоль прогона
      # (круги 1–2 ревью PR #197): stdout теперь уходит в файл, а текст
      # .result объясняет человеку исход задачи. Печать ДО проверки
      # claude_rc: на аварийном пути (rc≠0 останавливает прогон целиком)
      # диагностика из .result нужнее всего — лимит, авторизация, credit.
      # Печатается только непустая строка (не литералы None/""); отказ
      # разбора — молча, его честно обработает ветка «usage не прочитан»
      # ниже. При прерывании по бюджету времени файл оборван — не читаем.
      python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        r = json.load(f).get("result")
    if isinstance(r, str) and r:
        print(r)
except Exception:
    pass
' "$work_dir/claude-out.json"

      # Снятие usage (issue #132) — сразу после сам-завершившегося процесса,
      # ДО проверки claude_rc ниже (issue #214: раньше это стояло после
      # ветвления по коду возврата, и usage упавшей задачи не читался вовсе —
      # реальные токены потрачены независимо от исхода claude -p, run.maxTokens
      # без этого занижен ровно на стоимость всех неуспешных задач). После
      # kill по бюджету времени (task_budget_hit=1, обрабатывается веткой
      # ниже) это неприменимо — файл может быть пустым или оборванным, там
      # расход не читается (минуты пишутся, токены нет).
      if task_tokens=$(parse_claude_tokens "$work_dir/claude-out.json"); then
        run_tokens_used=$((run_tokens_used + task_tokens))
      else
        task_tokens=""
        echo "adk-ralph: usage headless-процесса не прочитан (issue" \
          "#$issue_num) — токены не записаны, токеновый бюджет задачи не" \
          "применён." >&2
      fi
    fi

    if [ "$task_budget_hit" -eq 0 ] && [ "$claude_rc" -ne 0 ]; then
      # Сбой самого headless-процесса (не установлен/не авторизован/лимит,
      # разово споткнулся) — до find_pr_state дела не дошло, значит нет и
      # факта «PR не создан» (ADR-007 §4, тот же принцип, что ниже для gh
      # pr list). Останавливаем прогон целиком: причина обычно не
      # специфична для этого issue и повторится на следующей итерации тем
      # же образом — не штампуем needs-human вслепую по всей очереди.
      echo "adk-ralph: claude -p завершился с ошибкой (exit $claude_rc) при issue #$issue_num — прогон остановлен." >&2
      stop_reason="claude -p завершился с ошибкой (exit $claude_rc) при issue #$issue_num"
      exit_code=1
      # Возврат дерева на default branch — тот же путь, что и в конце штатной
      # итерации (issue #144, п.2): без него дерево осталось бы на ветке
      # задачи, на которую переключился claude -p до сбоя. Отказ здесь не
      # переопределяет stop_reason выше (сбой claude -p — первичная причина
      # остановки), но всё равно печатает своё громкое предупреждение.
      return_to_default_branch || true
      break
    fi

    if [ "$task_budget_hit" -eq 1 ]; then
      # Бюджет задачи по времени превышен — застревание уровня задачи (ADR-017
      # §1), НЕ остановка всего прогона в отличие от обычного сбоя claude -p
      # выше: find_pr_state не вызывается вовсе (состояние PR после прерванного
      # процесса не имеет значения — исход зафиксирован причиной budget), пути
      # ниже сходятся в тот же stuck-код, что и «PR остался черновиком»/«PR не
      # создан».
      echo "adk-ralph: claude -p превысил бюджет задачи по времени" \
        "(${effective_task_budget_seconds}s) при issue #$issue_num — процесс прерван." >&2
      # Прерванный ПОСРЕДИ работы claude -p (в отличие от штатного result=stuck
      # ниже, где процесс успел завершиться сам и work.md уже закоммитил свои
      # шаги) мог оставить незакоммиченные правки — неотслеживаемые файлы,
      # изменённые отслеживаемые (круг 1 ревью PR #193, воспроизведено
      # фикстурой с полудописанным файлом). Сам факт фиксируется здесь
      # (budget_dirty_tree), но НЕ обрывает обработку немедленно (блокер круга
      # 2 ревью PR #193): прежняя версия делала `break` прямо тут, раньше
      # needs-human/уведомления/счётчиков/event=task result=stuck — DoD issue
      # #131 не выполнялся именно на этом, самом частом в реальности пути
      # (прерванный посреди работы процесс почти всегда оставляет дерево
      # грязным), issue оставался без метки, следующий прогон брал бы его
      # заново уже на заражённом дереве. Правильный порядок: pr_state
      # остаётся "budget-exceeded", ниже отрабатывает ТОТ ЖЕ общий stuck-путь,
      # что и «PR остался черновиком»/«PR не создан» (needs-human, уведомление,
      # счётчики, event=task) — и только ПОСЛЕ него, читая budget_dirty_tree,
      # прогон останавливается целиком БЕЗ return_to_default_branch (дальше по
      # циклу, рядом с остальными breaker'ами): return_to_default_branch
      # переключает дерево на default branch безусловно, и такие правки молча
      # переехали бы на него, если не расходятся с main, — следующая итерация
      # стартовала бы уже на заражённом дереве. Дерево остаётся как есть, не
      # трогаем его ни коммитом, ни force-чекаутом (тот же принцип, что в
      # return_to_default_branch — данные потенциально ещё нужны человеку).
      budget_dirty_tree=$(cd "$root" && git status --porcelain 2>/dev/null)
      if [ -n "$budget_dirty_tree" ]; then
        echo "adk-ralph: рабочее дерево не чисто после прерывания claude -p по" \
          "бюджету задачи (issue #$issue_num) — обычный путь застревания" \
          "отработает как обычно, но прогон остановится целиком после него," \
          "дерево не тронуто." >&2
      fi
      pr_state="budget-exceeded"
    else
      # Usage (task_tokens/run_tokens_used) уже снят выше, до ветвления по
      # claude_rc (issue #132, issue #214) — здесь только его применение к
      # токеновому бюджету задачи.
      if [ -n "$task_tokens" ] && [ "$task_tokens" -gt "$effective_task_token_budget" ]; then
        # Токеновая половина жёсткого бюджета задачи (issue #132): usage
        # известен только по завершении процесса, поэтому проверка
        # post-hoc — застревание фиксируется независимо от состояния PR
        # (find_pr_state не вызывается, как и при бюджете времени): даже
        # готовый PR превысившей задачи не мержится этим прогоном.
        echo "adk-ralph: расход задачи ($task_tokens токенов) превысил" \
          "бюджет задачи ($effective_task_token_budget) при issue #$issue_num." >&2
        pr_state="token-budget-exceeded"
      else
        pr_state=$(find_pr_state "$issue_num")

        if [ "$pr_state" = "error" ]; then
          # Сбой gh pr list — не факт «PR не создан» (ADR-007 §2/§3): прогон
          # останавливается целиком, issue не логируется как обработанный.
          echo "adk-ralph: gh pr list не удался при разборе issue #$issue_num:" >&2
          cat "$work_dir/gh-pr-list.err" >&2
          stop_reason="gh pr list не удался при разборе issue #$issue_num"
          exit_code=1
          # Тот же общий путь возврата дерева, что и на break-пути claude -p выше
          # (issue #144, п.2) — claude -p к этому моменту уже отработал и мог
          # переключить дерево на ветку задачи.
          return_to_default_branch || true
          break
        fi
      fi
    fi
  fi

  # Строка расхода для журнала и сводки (issue #132) — после всех путей,
  # выставивших duration/tokens; unquoted-подстановка безопасна: значения
  # без пробелов.
  task_extra=""
  [ -n "$task_duration_s" ] && task_extra="duration=${task_duration_s}s"
  [ -n "$task_tokens" ] && task_extra="$task_extra tokens=$task_tokens"
  if [ -n "$task_duration_s" ]; then
    usage_summary="$usage_summary #$issue_num: ${task_duration_s}s/${task_tokens:-?} ток."
  fi

  handled=$(csv_add "$handled" "$issue_num")

  if [ "$pr_state" = "ready" ]; then
    # Решение «мержить/оставить человеку/застряло» — issue #129, ADR-019.
    # finish_ready_outcome сама пишет журнал и обновляет счётчики (merged/
    # ready/stuck) — возврат 1 означает отказ записи журнала или
    # нераспознанный ответ resolve_ready_pr, оба уже выставили stop_reason.
    if ! finish_ready_outcome "$issue_num" "$issue_type" "$reused_flag"; then
      return_to_default_branch || true
      break
    fi
  else
    if [ "$pr_state" = "budget-exceeded" ]; then
      reason="бюджет задачи по времени"
    elif [ "$pr_state" = "token-budget-exceeded" ]; then
      reason="бюджет задачи по токенам"
    elif [ "$pr_state" = "draft" ]; then
      reason="PR остался черновиком"
    else
      reason="PR не создан"
    fi
    # Общий stuck-путь (mark_stuck): needs-human, уведомление, счётчики до
    # журнала, event=task result=stuck, breaker. Срабатывание breaker'а
    # откладывается до общей точки ниже (после return_to_default_branch,
    # рядом с actualization_breaker_tripped) — claude -p уже отработал на
    # ветке задачи, дерево обязано вернуться на default branch прежде, чем
    # цикл остановится.
    if ! mark_stuck "$issue_num" "$issue_type" "$reason"; then
      # На грязном дереве после прерывания по бюджету задачи (ADR-017 §4)
      # инвариант «не трогать дерево» действует и здесь — отказ записи
      # журнала не повод его нарушить (осталось с круга 3 ревью PR #193).
      if [ -z "$budget_dirty_tree" ]; then
        return_to_default_branch || true
      fi
      break
    fi
  fi

  # Грязное дерево после прерывания по бюджету задачи (issue #131, ADR-017
  # §4; блокер круга 2 ревью PR #193) — обычный stuck-путь выше уже
  # отработал целиком (needs-human/уведомление/счётчики/event=task
  # result=stuck reason="бюджет задачи по времени"), DoD issue #131
  # выполнен независимо от состояния дерева. Останавливаем прогон здесь,
  # ДО return_to_default_branch ниже: checkout/pull на default branch иначе
  # молча перенёс бы незакоммиченные правки прерванного процесса на ветку
  # следующей задачи, если они не расходятся с main. Дерево остаётся как
  # есть — не тронуто ни коммитом, ни force-чекаутом.
  if [ -n "$budget_dirty_tree" ]; then
    stop_reason="бюджет задачи по времени: рабочее дерево не чисто после прерывания issue #$issue_num"
    exit_code=1
    break
  fi

  # Возврат дерева на default branch между итерациями — см.
  # return_to_default_branch выше (ADR-007 §6). Канонический рецепт — тот
  # же, что у /autopilot (commands/autopilot.md, пункт «возврат дерева»): в
  # любом исходе задачи вернуться на default branch; git pull обновляет её
  # для следующей ветки (для ветки «кандидатов нет» шаг 2 /work на
  # настоящем ручном запуске делает то же самое; при найденной существующей
  # ветке issue-<N> шаг 2 делает больше — проверяет кандидатов, актуализирует
  # найденную ветку и возвращает ready в draft перед новыми коммитами, см.
  # #169). Отказ checkout здесь не best-effort (issue #144): останавливаем
  # прогон честной причиной вместо того, чтобы продолжать очередь на чужой
  # ветке молча — return_to_default_branch уже напечатала своё
  # предупреждение в stderr.
  if ! return_to_default_branch; then
    stop_reason="не удалось вернуть дерево на $default_branch после issue #$issue_num — прогон остановлен"
    exit_code=1
    break
  fi
  if [ "$actualization_breaker_tripped" -eq 1 ]; then
    # Системный breaker «серия git-конфликтов при актуализации подряд»
    # (issue #135, SPEC-003 «Система», ADR-015) — return_to_default_branch
    # выше насчитала actualization_conflict_threshold конфликтов слияния
    # подряд при `git pull` default branch между итерациями. Проверяется
    # раньше breaker'а уровня прогона ниже — системный уровень серьёзнее
    # (ADR-015/ADR-016), хотя оба триггера в одной итерации практически не
    # пересекаются.
    stop_reason="системный breaker: серия конфликтов актуализации"
    exit_code=1
    break
  fi
  if [ -n "$run_breaker_reason" ]; then
    # Breaker уровня прогона «застревания» (issue #134, ADR-016 §1, §4) —
    # выставлен внутри ветки result=stuck выше. Проверяется здесь, ПОСЛЕ
    # return_to_default_branch и системного breaker'а: дерево уже вернулось
    # на default branch, а если на последней доступной задаче этот breaker
    # совпал с тем, что следующий select_next и так вернул бы «NONE»
    # («очередь пуста»), причина сводки — этот breaker, а не «очередь
    # пуста» — он проверяется раньше следующего select_next (ADR-016 §4:
    # системная сигнальность важнее того, что очередь и так закончилась бы).
    stop_reason="$run_breaker_reason"
    exit_code=1
    break
  fi
done

# done=<смержено> — поле уже предусмотрено базовой схемой ADR-001
# ("event=run_end done=<k> stuck=<k> skipped=<k>"); adk-ralph.sh раньше
# писал в него литеральный 0, потому что merge не был реализован (issue
# #129, ADR-019 — merged_count теперь отражает факт).
"$logger" "$run_unit" event=run_end done="$merged_count" ready="$ready_count" stuck="$stuck_count" \
  skipped="$skipped_count" blocked_on_ready="$blocked_on_ready_count" \
  closed_externally="$closed_externally_count" \
  tokens="$run_tokens_used" reason="$stop_reason" || true

summary="=== Ralph: итог прогона ===
Смержено: ${merged_list:-нет}
Ready (ждут человека): ${ready_list:-нет}
Застряло: ${stuck_summary:-нет}
Пропущено (зависимость от застрявшей задачи): ${skipped_summary:-нет}
Закрыто человеком до старта задачи: ${closed_externally_summary:-нет}
Заблокировано ready-PR блокера: ${blocked_on_ready_summary:-нет}
Зарезервировано человеком: $reserved_count
Ждёт спеки в main: ${waiting_for_spec_summary:-нет}
Расход по задачам (сек/токены):${usage_summary:- нет}
Расход прогона: $run_tokens_used ток.
Причина остановки: $stop_reason"

echo "$summary"
# Сводка дублируется локальным уведомлением (SPEC-003 «Сводка прогона и
# HITL»; DoD issue #139: «event=run_end и уведомление») — не только
# терминал и журнал. merged=$merged_count и closed_externally=$closed_externally_count
# дописаны В КОНЕЦ строки (issue #129, issue #220 п.1), а не сразу после
# "завершён:", чтобы не сдвинуть существующие assert_contains на буквальный
# префикс "ready=... stuck=... skipped=..." у фикстур, предшествующих этим
# полям (issue #139/#134/#135/#147/#130).
"$notifier" "Ralph" "Прогон завершён: ready=$ready_count stuck=$stuck_count skipped=$skipped_count blocked_on_ready=$blocked_on_ready_count merged=$merged_count closed_externally=$closed_externally_count waiting_for_spec=$waiting_for_spec_count. Причина: $stop_reason" || true

exit "$exit_code"
