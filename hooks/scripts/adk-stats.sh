#!/usr/bin/env bash
# Сводка по журналу прогонов: агрегаты по issue-<N>.jsonl (файл журнала на
# единицу работы, см. adk-log.sh). Использование: adk-stats.sh
# Читает $ADK_LOGS_DIR либо <корень проекта>/.adk/logs/. Схема событий,
# которую ожидает агрегация (event=start/review/outcome, поля round/verdict/
# result/reason/timestamp) — docs/adr/001-journal-event-schema.md; её же
# обязаны писать /work и /autopilot.
# Пустой или отсутствующий каталог журнала — exit 0 с сообщением, без
# агрегатов. Битые (невалидный JSON) строки пропускаются с предупреждением
# в stderr, не роняют скрипт.
set -u

root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$root" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
fi

if [ -n "${ADK_LOGS_DIR:-}" ]; then
  logs_dir="$ADK_LOGS_DIR"
else
  logs_dir="$root/.adk/logs"
fi

shopt -s nullglob
issue_files=("$logs_dir"/issue-*.jsonl)
shopt -u nullglob

if [ ! -d "$logs_dir" ] || [ "${#issue_files[@]}" -eq 0 ]; then
  echo "Журнал пуст: в $logs_dir нет ни одной завершённой задачи (issue-*.jsonl)."
  exit 0
fi

python3 - "${issue_files[@]}" <<'PYEOF'
import json
import sys
import os
import collections
import datetime

paths = sys.argv[1:]

tasks = []
for path in paths:
    rounds = 0
    outcome = None
    last_ts = None
    valid_any = False
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                print(
                    f"adk-stats: {os.path.basename(path)}:{lineno}: "
                    "битая строка пропущена (не JSON)",
                    file=sys.stderr,
                )
                continue
            valid_any = True
            event = ev.get("event")
            if event == "review":
                rounds += 1
            elif event == "outcome":
                outcome = ev
            ts = ev.get("timestamp")
            if ts:
                last_ts = ts
    if not valid_any:
        # файл целиком без единой валидной строки — не считается задачей
        continue
    result = outcome.get("result") if outcome else "unknown"
    reason = outcome.get("reason") if outcome else None
    ts_for_week = (outcome.get("timestamp") if outcome else None) or last_ts
    week = None
    if ts_for_week:
        try:
            dt = datetime.datetime.strptime(ts_for_week, "%Y-%m-%dT%H:%M:%SZ")
            iso_year, iso_week, _ = dt.isocalendar()
            week = f"{iso_year}-W{iso_week:02d}"
        except Exception:
            week = None
    tasks.append(
        {
            "file": os.path.basename(path),
            "rounds": rounds,
            "result": result,
            "reason": reason,
            "week": week,
        }
    )

if not tasks:
    print("Журнал пуст: ни одна из записей issue-*.jsonl не содержит валидных событий.")
    sys.exit(0)

total = len(tasks)
avg_rounds = sum(t["rounds"] for t in tasks) / total
stuck = [t for t in tasks if t["result"] == "stuck"]
stuck_rate = (len(stuck) / total) * 100

reasons = collections.Counter(
    (t["reason"] or "причина не указана") for t in stuck
)

weekly = collections.defaultdict(lambda: {"tasks": 0, "rounds": 0})
for t in tasks:
    key = t["week"] or "без даты"
    weekly[key]["tasks"] += 1
    weekly[key]["rounds"] += t["rounds"]

print(f"Всего задач: {total}")
print(f"Средние круги ревью: {avg_rounds:.1f}")
print(f"Доля застреваний: {stuck_rate:.0f}% ({len(stuck)}/{total})")
if reasons:
    print("Причины застреваний:")
    for reason, count in reasons.most_common():
        print(f"  - {reason}: {count}")
print("Динамика по неделям (задач / средние круги ревью):")
for week in sorted(weekly):
    d = weekly[week]
    avg_week_rounds = d["rounds"] / d["tasks"] if d["tasks"] else 0
    print(f"  - {week}: задач {d['tasks']}, среднее кругов {avg_week_rounds:.1f}")
PYEOF
