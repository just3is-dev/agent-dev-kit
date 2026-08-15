#!/usr/bin/env bash
# Сводка по журналу прогонов: агрегаты по issue-<N>.jsonl (файл журнала на
# единицу работы, см. adk-log.sh). Использование: adk-stats.sh
# Читает $ADK_LOGS_DIR либо <корень проекта>/.adk/logs/. Схема событий,
# которую ожидает агрегация (event=start/review/outcome, поля round/verdict/
# result/reason/type/timestamp) — docs/adr/001-journal-event-schema.md; её же
# обязаны писать /work и /autopilot.
# Пустой или отсутствующий каталог журнала — exit 0 с сообщением, без
# агрегатов. Битые строки (невалидный JSON, JSON не-объект, оборванная
# multibyte UTF-8 последовательность) пропускаются с предупреждением в
# stderr, не роняют скрипт.
set -u

. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
root=$(adk_project_root)
logs_dir=$(adk_logs_dir "$root")

shopt -s nullglob
issue_files=("$logs_dir"/issue-*.jsonl)
shopt -u nullglob

if [ ! -d "$logs_dir" ]; then
  echo "Журнал пуст: каталог $logs_dir не найден, записей ещё нет."
  exit 0
fi

if [ "${#issue_files[@]}" -eq 0 ]; then
  shopt -s nullglob
  autopilot_files=("$logs_dir"/autopilot-*.jsonl)
  shopt -u nullglob
  if [ "${#autopilot_files[@]}" -eq 0 ]; then
    echo "Журнал пуст: в $logs_dir нет ни одной записи."
  else
    echo "В журнале нет ни одной задачи (issue-*.jsonl) — только записи" \
      "прогонов autopilot (autopilot-*.jsonl), которые /stats пока не агрегирует."
  fi
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
in_progress = 0
for path in paths:
    rounds = 0
    max_round = 0
    outcome = None
    last_ts = None
    valid_any = False
    # тип задачи — последнее непустое поле type среди событий файла
    # (обычно совпадает в start и outcome); строки без поля — старая
    # схема до расширения ADR-001, такие задачи считаются task
    task_type = "task"
    # errors="replace": строка, оборванная посреди multibyte UTF-8 (типичный
    # исход обрыва процесса при записи в журнал), не должна ронять скрипт
    # UnicodeDecodeError-ом — она станет невалидным JSON и будет пропущена
    # ниже как битая строка, как и любой другой мусор в журнале.
    with open(path, encoding="utf-8", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if not isinstance(ev, dict):
                    raise ValueError("строка не JSON-объект")
            except Exception:
                print(
                    f"adk-stats: {os.path.basename(path)}:{lineno}: "
                    "битая строка пропущена (не JSON-объект)",
                    file=sys.stderr,
                )
                continue
            valid_any = True
            event = ev.get("event")
            if event == "review":
                rounds += 1
                try:
                    max_round = max(max_round, int(ev.get("round", 0)))
                except (TypeError, ValueError):
                    pass
            elif event == "outcome":
                outcome = ev
            ev_type = ev.get("type")
            if isinstance(ev_type, str) and ev_type:
                task_type = ev_type
            ts = ev.get("timestamp")
            if ts:
                last_ts = ts
    if not valid_any:
        # файл целиком без единой валидной строки — не считается задачей
        continue
    if outcome is None:
        # задача ещё в работе (есть start/review, но нет итога) — не
        # завершена, поэтому не участвует в агрегатах по завершённым задачам
        in_progress += 1
        continue
    # число кругов ревью — максимум поля round, если оно проставлено (устойчиво
    # к дублирующей записи одного круга в append-only журнале), иначе — число
    # строк event=review
    round_count = max_round if max_round > 0 else rounds
    result = outcome.get("result") or "unknown"
    reason = outcome.get("reason")
    ts_for_week = outcome.get("timestamp") or last_ts
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
            "rounds": round_count,
            "result": result,
            "reason": reason,
            "type": task_type,
            "week": week,
        }
    )

if not tasks:
    if in_progress:
        # журнал НЕ пуст — есть start/review, просто ни одна задача ещё не
        # получила event=outcome. Говорить "журнал пуст" здесь вводит в
        # заблуждение (самый частый случай — только что начатый /work) и
        # подталкивает /stats к неверному выводу "записей ещё нет, сводить
        # нечего" (commands/stats.md, п.3).
        print(
            "Завершённых задач ещё нет: событие outcome не записано ни для "
            f"одной задачи. В работе (без итога): {in_progress}."
        )
    else:
        # in_progress тоже 0 → ни для одного файла не нашлось ни одной
        # валидной строки (valid_any=False для каждого): файлы физически
        # есть (issue_files непуст — гейт в adk-stats.sh выше), но целиком
        # из битых строк или пустые. Это не то же самое, что реально пустой
        # журнал (каталога/файлов нет вовсе) — не называть это "Журнал пуст".
        print(
            "Файлы есть, валидных записей нет: ни в одном issue-*.jsonl "
            "не нашлось ни одной строки, которая была бы валидным JSON-"
            "объектом."
        )
    sys.exit(0)

total = len(tasks)
avg_rounds = sum(t["rounds"] for t in tasks) / total
stuck = [t for t in tasks if t["result"] == "stuck"]
stuck_rate = (len(stuck) / total) * 100

reasons = collections.Counter(
    (t["reason"] if isinstance(t["reason"], str) and t["reason"] else "причина не указана")
    for t in stuck
)

weekly = collections.defaultdict(lambda: {"tasks": 0, "rounds": 0})
for t in tasks:
    key = t["week"] or "без даты"
    weekly[key]["tasks"] += 1
    weekly[key]["rounds"] += t["rounds"]

print(f"Всего задач: {total}")
if in_progress:
    print(f"В работе (без итога, в агрегаты ниже не входят): {in_progress}")
print(f"Средние круги ревью: {avg_rounds:.1f}")
print(f"Доля застреваний: {stuck_rate:.0f}% ({len(stuck)}/{total})")
if reasons:
    print("Причины застреваний:")
    for reason, count in reasons.most_common():
        print(f"  - {reason}: {count}")

by_type = collections.defaultdict(lambda: {"tasks": 0, "rounds": 0})
for t in tasks:
    by_type[t["type"]]["tasks"] += 1
    by_type[t["type"]]["rounds"] += t["rounds"]
print("Разрез по типам (количество / средние круги ревью):")
for typ in sorted(by_type):
    d = by_type[typ]
    print(f"  - {typ}: задач {d['tasks']}, среднее кругов {d['rounds'] / d['tasks']:.1f}")
print("Динамика по неделям (задач / средние круги ревью):")
for week in sorted(weekly):
    d = weekly[week]
    avg_week_rounds = d["rounds"] / d["tasks"] if d["tasks"] else 0
    print(f"  - {week}: задач {d['tasks']}, среднее кругов {avg_week_rounds:.1f}")
PYEOF
