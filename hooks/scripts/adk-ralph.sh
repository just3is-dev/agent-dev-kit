#!/usr/bin/env bash
# Ralph-цикл SPEC-003 (docs/specs/003-autonomy.md): выполняет очередь issues
# свежими headless-процессами `claude -p`, без интерактивной сессии — память
# между итерациями держат git/issues/журнал, не контекст модели. Запускается
# вручную из корня проекта: hooks/scripts/adk-ralph.sh
#
# issue #139 — только базовый цикл (AC-1) и запрет
# --dangerously-skip-permissions (AC-7). Бюджеты, стоп-файл, breaker и merge
# ready-PR — следующие задачи плана (issues #129-138, SPEC-003): эта версия
# после ready-PR всегда собирает задачу в список «ждут человека»
# (result=ready, ADR-003), никогда не мержит.
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
# Тесты: hooks/scripts/adk-ralph.sh стабами claude/gh на суженном PATH,
# журнал — $ADK_LOGS_DIR, уведомления — $ADK_NOTIFY_FILE (notify-send.sh),
# конфиг — $ADK_CONFIG_FILE (lib/config.sh) — все три уже поддержаны
# переиспользуемыми хелперами, ralph не добавляет своего механизма.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" # sourcing lib/config.sh тянет lib/paths.sh следом

root=$(adk_project_root)
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# Экспорт обязателен: без него дочерний headless-процесс `claude -p` (строка
# ~317) не наследует CLAUDE_PLUGIN_ROOT при штатном ручном запуске (шапка
# файла), где переменная не выставлена вовсе — а commands/work.md, которым
# инструктируется этот процесс, содержит 10+ мест вида
# ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/... (блокер круга 4 ревью PR #141).
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

run_unit="autopilot-$(date +%Y-%m-%d)"
logger="$SCRIPT_DIR/adk-log.sh"
notifier="$SCRIPT_DIR/notify-send.sh"

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
blocked_on_ready_nums=""  # issue-номера, уже отнесённые к blocked-on-ready в
                          # этом прогоне (подмножество handled) — тот же
                          # приём, что ready_nums: переживает итерации
                          # внешнего цикла и передаётся в select_next, чтобы
                          # неподвижная точка resolved_ready не забывала уже
                          # найденные blocked-on-ready задачи (круг 2 ревью
                          # PR #186, issue #147)
ready_count=0
stuck_count=0
skipped_count=0
blocked_on_ready_count=0  # задачи, заблокированные ready-но-не-смерженным
                          # блокером этого прогона (ADR-014, issue #147)
ready_list=""
stuck_summary=""
skipped_summary=""
blocked_on_ready_summary=""
stop_reason=""
exit_code=0

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
issues_file="$work_dir/issues.json"

"$logger" "$run_unit" event=run_start || true

issue_fetch_limit=100
if ! (cd "$root" && gh issue list --state open --json number,labels,body --limit "$issue_fetch_limit") \
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
# строку "NEXT <N> <type>" (следующая задача к исполнению) либо "NONE"
# (доступных задач не осталось).
select_next() {
  python3 - "$issues_file" "$handled" "$stuck" "$skipped" "$ready_nums" \
    "$blocked_on_ready_nums" \
    "$task_label" "$bug_label" "$ff_label" "$consolidate_label" <<'PYEOF'
import json, re, sys

issues_file, handled_csv, stuck_csv, skipped_csv, ready_csv, prev_bor_csv = sys.argv[1:7]
task_label, bug_label, ff_label, consolidate_label = sys.argv[7:11]


def csv_ints(s):
    return {int(x) for x in s.split(",") if x}


handled = csv_ints(handled_csv)
unresolved = csv_ints(stuck_csv) | csv_ints(skipped_csv)
ready_now = csv_ints(ready_csv)
prev_blocked_on_ready = csv_ints(prev_bor_csv)

with open(issues_file) as f:
    issues = json.load(f)
issues.sort(key=lambda it: it["number"])

open_numbers = {it["number"] for it in issues}


def blockers(body):
    out = set()
    for m in re.finditer(r"Blocked by\s+([^\n]*)", body or ""):
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

# issue #147, ADR-014 (круг 1 ревью PR #186): задача с открытым, но
# resolved_ready блокером — «на подвеске», не молча потеряна (см. ADR-014
# п.2). resolved_ready = issue, ставшие ready ЭТИМ прогоном (ready_now), плюс
# уже найденные blocked-on-ready (в этом вызове — цикл до неподвижности ниже,
# тем же приёмом, что каскад SKIP выше; И между вызовами — prev_blocked_on_ready,
# накопленный в bash аналогично ready_nums: без этого задача, отнесённая к
# blocked-on-ready на прошлой итерации внешнего цикла, уже в `handled` →
# исключена из резолва следующего вызова → её зависимые молча теряются, круг
# 2 ревью PR #186). ВСЕ открытые блокеры задачи должны быть resolved_ready
# (не «хотя бы один» — иначе задача с одним ready- и одним нетронутым
# блокером ложно считалась бы «на подвеске»).
resolved_ready = set(ready_now) | prev_blocked_on_ready
blocked_on_ready_numbers = set()
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
    if blockers(it.get("body")) & open_numbers:
        continue
    candidate = it
    break

for it in issues:
    if it["number"] in blocked_on_ready_numbers:
        print(f"BLOCKED_ON_READY {it['number']} {type_of(it)}")

if candidate:
    print(f"NEXT {candidate['number']} {type_of(candidate)}")
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

# ── Default branch — определяется фактически, не хардкодится (issue #144,
# ADR-007 §6). `git symbolic-ref --short refs/remotes/origin/HEAD` даёт то
# же имя, что видит обычный клон после `git remote set-head origin -a`;
# фолбэк на "main", если определить не удалось (нет origin, HEAD не
# выставлен, репозиторий свежий/нестандартный). Вычисляется один раз до
# цикла — смена default branch в origin посреди прогона вне области этой
# задачи (известное ограничение самохостинга, ADR-007 §6).
default_branch=$(cd "$root" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch="${default_branch#origin/}"
default_branch="${default_branch:-main}"

# return_to_default_branch — возврат рабочего дерева на default branch между
# итерациями (ADR-007 §6; блокер круга 6 ревью PR #141 + issue #144).
# commands/work.md разворачивает каждую задачу на собственной ветке
# (issue-<N>-<слаг>) и не возвращает дерево обратно — без явного возврата
# здесь вторая и последующие задачи прогона стартовали бы `claude -p` на
# ветке предыдущей задачи, а не на default branch. Единая точка вызова на
# любом выходе из цикла — в конце штатной итерации и на break-путях сбоя
# `claude -p` / `gh pr list` (issue #144: до этой правки возврат был только
# в конце итерации, break-пути пропускали его целиком).
#
# Отказ checkout — не best-effort, в отличие от `git pull` ниже: дочерний
# headless-процесс мог оставить незакоммиченный трекаемый файл на ветке
# задачи (`claude -p` слетел посреди работы, не успел закоммитить/убрать за
# собой) — тогда checkout отказывает, и молчаливое "|| true" оставляло бы
# дерево на чужой ветке, а следующая итерация стартовала бы на ней же
# молча (issue #144, было тихим до этой правки). Громкое предупреждение в
# stderr — тот же класс, что уже есть для `gh issue edit --add-label` ниже;
# вызывающий код останавливает прогон честной причиной вместо того, чтобы
# самому гадать, какую ветку/состояние восстанавливать (данные потенциально
# ещё нужны человеку — не наше дело отбрасывать их force-чекаутом).
return_to_default_branch() {
  local current checkout_err rc
  # `git symbolic-ref --short HEAD` (не `git rev-parse --abbrev-ref HEAD`)
  # — единственный способ узнать текущую ветку, который не падает на
  # unborn-ветке (репозиторий без единого коммита, HEAD ещё ни на что не
  # указывает): rev-parse в этом случае возвращает ошибку и буквальную
  # строку "HEAD" в stdout. Пропуск checkout, когда мы и так уже на
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
  (cd "$root" && git pull >/dev/null 2>&1) || true
  return 0
}

# ── Цикл ──────────────────────────────────────────────────────────────────
# exit_code уже != 0 здесь только если gh issue list выше не удался
# (stop_reason уже выставлен тем же путём) — цикл в этом случае не
# стартует вовсе, run_end/уведомление печатает общий хвост ниже.
while [ "$exit_code" -eq 0 ]; do
  select_out=$(select_next)

  while IFS= read -r line; do
    case "$line" in
      SKIP\ *)
        skip_num=$(printf '%s' "$line" | awk '{print $2}')
        skip_type=$(printf '%s' "$line" | awk '{print $3}')
        "$logger" "$run_unit" event=task issue="$skip_num" type="$skip_type" result=skipped || true
        handled=$(csv_add "$handled" "$skip_num")
        skipped=$(csv_add "$skipped" "$skip_num")
        skipped_count=$((skipped_count + 1))
        skipped_summary="$skipped_summary #$skip_num"
        ;;
      BLOCKED_ON_READY\ *)
        # ADR-014 (issue #147) — задача ждёт мерджа блокера, а не «застряла»
        # или «пропущена». handled — чтобы select_next не печатал её заново
        # на следующей итерации этого же прогона.
        bor_num=$(printf '%s' "$line" | awk '{print $2}')
        bor_type=$(printf '%s' "$line" | awk '{print $3}')
        "$logger" "$run_unit" event=task issue="$bor_num" type="$bor_type" result=blocked-on-ready || true
        handled=$(csv_add "$handled" "$bor_num")
        blocked_on_ready_nums=$(csv_add "$blocked_on_ready_nums" "$bor_num")
        blocked_on_ready_count=$((blocked_on_ready_count + 1))
        blocked_on_ready_summary="$blocked_on_ready_summary #$bor_num"
        ;;
    esac
  done <<<"$select_out"

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
      ;;
    *)
      echo "adk-ralph: неожиданный вывод выбора задачи: $status_line" >&2
      stop_reason="внутренняя ошибка выбора задачи"
      exit_code=1
      break
      ;;
  esac

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

  if [ "$pre_pr_state" = "ready" ]; then
    # reused=true отличает «уже был ready» от «стал ready в этом запуске»
    # (ADR-014) — сам result тот же, что у обычного исхода ниже.
    "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=ready reused=true || true
    handled=$(csv_add "$handled" "$issue_num")
    ready_nums=$(csv_add "$ready_nums" "$issue_num")
    ready_count=$((ready_count + 1))
    ready_list="$ready_list #$issue_num"
    continue
  fi

  prompt="$(cat "$work_md")

---
Инструкция ралфа (adk-ralph.sh, issue #139, SPEC-003): выполни шаги выше
целиком для задачи issue #$issue_num. Путь к проекту: $root."

  (cd "$root" && claude -p "$prompt")
  claude_rc=$?
  if [ "$claude_rc" -ne 0 ]; then
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

  handled=$(csv_add "$handled" "$issue_num")

  if [ "$pr_state" = "ready" ]; then
    "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=ready || true
    ready_nums=$(csv_add "$ready_nums" "$issue_num")
    ready_count=$((ready_count + 1))
    ready_list="$ready_list #$issue_num"
  else
    if [ "$pr_state" = "draft" ]; then
      reason="PR остался черновиком"
    else
      reason="PR не создан"
    fi
    (cd "$root" && gh label create needs-human >/dev/null 2>&1) || true
    if ! (cd "$root" && gh issue edit "$issue_num" --add-label needs-human) \
      >/dev/null 2>"$work_dir/gh-issue-edit.err"; then
      # needs-human — единственный механизм HITL для этой задачи: молчать
      # об отказе нельзя. Не останавливаем весь прогон за это (в отличие
      # от сбоя gh pr list выше) — но без громкого предупреждения журнал
      # и уведомление утверждали бы stuck, а метки не было бы, и
      # следующий прогон взял бы issue заново.
      echo "adk-ralph: не удалось пометить issue #$issue_num меткой needs-human:" >&2
      cat "$work_dir/gh-issue-edit.err" >&2
    fi
    "$notifier" "Ralph" "issue #$issue_num застрял: $reason" || true
    "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=stuck reason="$reason" || true
    stuck=$(csv_add "$stuck" "$issue_num")
    stuck_count=$((stuck_count + 1))
    stuck_summary="$stuck_summary #$issue_num ($reason)"
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
done

"$logger" "$run_unit" event=run_end done=0 ready="$ready_count" stuck="$stuck_count" \
  skipped="$skipped_count" blocked_on_ready="$blocked_on_ready_count" reason="$stop_reason" || true

summary="=== Ralph: итог прогона ===
Ready (ждут человека): ${ready_list:-нет}
Застряло: ${stuck_summary:-нет}
Пропущено (зависимость от застрявшей задачи): ${skipped_summary:-нет}
Заблокировано ready-PR блокера: ${blocked_on_ready_summary:-нет}
Зарезервировано человеком: $reserved_count
Причина остановки: $stop_reason"

echo "$summary"
# Сводка дублируется локальным уведомлением (SPEC-003 «Сводка прогона и
# HITL»; DoD issue #139: «event=run_end и уведомление») — не только
# терминал и журнал.
"$notifier" "Ralph" "Прогон завершён: ready=$ready_count stuck=$stuck_count skipped=$skipped_count blocked_on_ready=$blocked_on_ready_count. Причина: $stop_reason" || true

exit "$exit_code"
