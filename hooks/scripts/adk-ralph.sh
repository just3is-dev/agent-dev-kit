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
# Тесты: hooks/scripts/adk-ralph.sh стабами claude/gh на суженном PATH,
# журнал — $ADK_LOGS_DIR, уведомления — $ADK_NOTIFY_FILE (notify-send.sh),
# конфиг — $ADK_CONFIG_FILE (lib/config.sh) — все три уже поддержаны
# переиспользуемыми хелперами, ralph не добавляет своего механизма.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" # sourcing lib/config.sh тянет lib/paths.sh следом

root=$(adk_project_root)
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
work_md="$plugin_root/commands/work.md"

# ── Политика: enabled=false — отказ старта без единого побочного эффекта ────
# (журнал не начат, gh не вызван) — читается до любых других действий.
# Ненулевой exit adk_config_get (опечатка в значении, не отсутствие
# файла/атрибута — за это lib/config.sh отвечает exit 0) — fail-closed, как
# ralph обязан вести себя со всем, что читает из конфига (issue #129, к
# нему же готовит эта же дисциплина): не запускаемся при неясной политике,
# а не молча трактуем как дефолтное "включено".
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

logs_dir=$(adk_logs_dir "$root")
run_unit="autopilot-$(date +%Y-%m-%d)"
logger="$SCRIPT_DIR/adk-log.sh"
notifier="$SCRIPT_DIR/notify-send.sh"

task_label=$(adk_config_get "types.task.label" "type:task")
bug_label=$(adk_config_get "types.bug.label" "type:bug")
ff_label=$(adk_config_get "types.fastFollow.label" "type:fast-follow")
consolidate_label=$(adk_config_get "types.consolidate.label" "type:consolidate")

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
issues_file="$work_dir/issues.json"

"$logger" "$run_unit" event=run_start || true

issue_fetch_limit=100
if ! (cd "$root" && gh issue list --state open --json number,labels,body --limit "$issue_fetch_limit") \
  >"$issues_file" 2>"$work_dir/gh-issue-list.err"; then
  echo "adk-ralph: gh issue list не удался:" >&2
  cat "$work_dir/gh-issue-list.err" >&2
  exit 1
fi
fetched_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$issues_file" 2>/dev/null || echo 0)
if [ "$fetched_count" -eq "$issue_fetch_limit" ] 2>/dev/null; then
  echo "adk-ralph: gh issue list вернул ровно $issue_fetch_limit открытых issues —" \
    "список мог быть усечён лимитом, «очередь пуста» в конце прогона не гарантирует," \
    "что открытых issues действительно не осталось." >&2
fi

# ── Состояние прогона ─────────────────────────────────────────────────────
handled=""  # issue-номера, по которым уже записана строка event=task
stuck=""    # issue-номера, застрявшие в этом прогоне (needs-human поставлен)
skipped=""  # issue-номера, пропущенные в этом прогоне (зависимость от stuck)
ready_count=0
stuck_count=0
skipped_count=0
ready_list=""
stuck_summary=""
skipped_summary=""
stop_reason=""
exit_code=0

csv_add() { # csv_add <csv> <значение> — печатает csv с добавленным значением
  if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s,%s' "$1" "$2"; fi
}

# select_next — один проход: печатает 0+ строк "SKIP <N> <type>" (каскад
# пропуска зависимостей от уже застрявших/пропущенных в этом прогоне задач,
# до неподвижной точки — переход по цепочке зависимостей), затем ровно одну
# строку "NEXT <N> <type>" (следующая задача к исполнению) либо "NONE"
# (доступных задач не осталось).
select_next() {
  python3 - "$issues_file" "$handled" "$stuck" "$skipped" \
    "$task_label" "$bug_label" "$ff_label" "$consolidate_label" <<'PYEOF'
import json, re, sys

issues_file, handled_csv, stuck_csv, skipped_csv = sys.argv[1:5]
task_label, bug_label, ff_label, consolidate_label = sys.argv[5:9]


def csv_ints(s):
    return {int(x) for x in s.split(",") if x}


handled = csv_ints(handled_csv)
unresolved = csv_ints(stuck_csv) | csv_ints(skipped_csv)

with open(issues_file) as f:
    issues = json.load(f)
issues.sort(key=lambda it: it["number"])

open_numbers = {it["number"] for it in issues}


def blockers(body):
    out = set()
    for m in re.finditer(r"Blocked by\s+((?:#\d+[,\s]*)+)", body or ""):
        out.update(int(x) for x in re.findall(r"\d+", m.group(1)))
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
changed = True
while changed:
    changed = False
    for it in issues:
        n = it["number"]
        if n in handled or n in new_skip_numbers:
            continue
        if blockers(it.get("body")) & unresolved:
            new_skips.append(it)
            new_skip_numbers.add(n)
            unresolved.add(n)
            changed = True

for it in new_skips:
    print(f"SKIP {it['number']} {type_of(it)}")

excluded = handled | new_skip_numbers
candidate = None
for it in issues:
    n = it["number"]
    if n in excluded:
        continue
    if "needs-human" in labels_of(it):
        continue
    if blockers(it.get("body")) & open_numbers:
        continue
    candidate = it
    break

if candidate:
    print(f"NEXT {candidate['number']} {type_of(candidate)}")
else:
    print("NONE")
PYEOF
}

# find_pr_state <issue> — печатает "ready"/"draft"/"none"/"error". "error" —
# сам вызов gh не удался (сеть, лимит, протухший токен): это НЕ факт
# «PR не создан», отсутствие фактов не равно факту отсутствия. Смешивать их
# нельзя — задача ложно получила бы needs-human (метка липкая, следующий
# прогон её не подхватит) за сбой самого gh, а не за реальное состояние PR.
find_pr_state() {
  local issue_num="$1" pr_json rc
  pr_json=$(cd "$root" && gh pr list --state open \
    --json number,isDraft,headRefName --limit 200 2>"$work_dir/gh-pr-list.err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error'
    return
  fi
  printf '%s' "$pr_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
prefix = "issue-" + sys.argv[1] + "-"
matches = [d for d in data if d.get("headRefName", "").startswith(prefix)]
if not matches:
    print("none")
else:
    matches.sort(key=lambda d: d["number"])
    print("draft" if matches[-1].get("isDraft") else "ready")
' "$issue_num"
}

# ── Цикл ──────────────────────────────────────────────────────────────────
while :; do
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
    esac
  done <<<"$select_out"

  status_line=$(printf '%s' "$select_out" | tail -1)
  case "$status_line" in
    NONE)
      stop_reason="очередь пуста"
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

  prompt="$(cat "$work_md")

---
Инструкция ралфа (adk-ralph.sh, issue #139, SPEC-003): выполни шаги выше
целиком для задачи issue #$issue_num. Путь к проекту: $root."

  (cd "$root" && claude -p "$prompt")

  pr_state=$(find_pr_state "$issue_num")

  if [ "$pr_state" = "error" ]; then
    # Отсутствие фактов — не факт отсутствия: сбой самого gh (сеть, лимит,
    # токен) не значит «PR не создан». Не штампуем needs-human вслепую —
    # останавливаем прогон целиком, задача не логируется как обработанная
    # (её ещё предстоит взять заново следующим прогоном).
    echo "adk-ralph: gh pr list не удался при разборе issue #$issue_num:" >&2
    cat "$work_dir/gh-pr-list.err" >&2
    stop_reason="gh pr list не удался"
    exit_code=1
    break
  fi

  handled=$(csv_add "$handled" "$issue_num")

  if [ "$pr_state" = "ready" ]; then
    "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=ready || true
    ready_count=$((ready_count + 1))
    ready_list="$ready_list #$issue_num"
  else
    if [ "$pr_state" = "draft" ]; then
      reason="PR остался черновиком"
    else
      reason="PR не создан"
    fi
    (cd "$root" && gh label create needs-human >/dev/null 2>&1) || true
    (cd "$root" && gh issue edit "$issue_num" --add-label needs-human >/dev/null 2>&1) || true
    "$notifier" "Ralph" "issue #$issue_num застрял: $reason" || true
    "$logger" "$run_unit" event=task issue="$issue_num" type="$issue_type" result=stuck reason="$reason" || true
    stuck=$(csv_add "$stuck" "$issue_num")
    stuck_count=$((stuck_count + 1))
    stuck_summary="$stuck_summary #$issue_num ($reason)"
  fi
done

"$logger" "$run_unit" event=run_end done=0 ready="$ready_count" stuck="$stuck_count" \
  skipped="$skipped_count" reason="$stop_reason" || true

summary="=== Ralph: итог прогона ===
Ready (ждут человека): ${ready_list:-нет}
Застряло: ${stuck_summary:-нет}
Пропущено (зависимость от застрявшей задачи): ${skipped_summary:-нет}
Причина остановки: $stop_reason"

echo "$summary"
# Сводка дублируется локальным уведомлением (SPEC-003 «Сводка прогона и
# HITL»; DoD issue #139: «event=run_end и уведомление») — не только
# терминал и журнал.
"$notifier" "Ralph" "Прогон завершён: ready=$ready_count stuck=$stuck_count skipped=$skipped_count. Причина: $stop_reason" || true

exit "$exit_code"
