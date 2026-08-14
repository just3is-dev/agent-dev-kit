#!/usr/bin/env bash
# PreToolUse(Bash): запрещает команды, обходящие гейты качества,
# и блокирует коммиты, в изменениях которых похоже на секреты.
set -u

payload=$(cat)
. "$(cd "$(dirname "$0")" && pwd)/lib/json-field.sh"
. "$(cd "$(dirname "$0")" && pwd)/lib/config.sh"
cmd=$(json_field "$payload" "tool_input.command" "")
[ -n "$cmd" ] || exit 0

deny() {
  echo "$1" >&2
  exit 2
}

# Рабочая директория команды. Корень сессии (CLAUDE_PROJECT_DIR) может не быть
# репозиторием (сессия открыта выше, проект подключён дополнительной
# директорией), поэтому кандидаты в порядке достоверности: явный `cd` в самой
# команде → cwd сессии из payload хука → корень сессии → PWD хука.
hook_cwd=$(json_field "$payload" "cwd" "")
cd_prefix=""
case "$cmd" in
  cd\ *) cd_prefix=$(printf '%s' "$cmd" | sed -E 's/^cd +//; s/ *(&&|;|\|).*$//' | tr -d '"'"'"'') ;;
esac

git_root=""
for d in "$cd_prefix" "$hook_cwd" "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    git_root="$d"
    break
  fi
done

if printf '%s' "$cmd" | grep -q 'git commit' && printf '%s' "$cmd" | grep -q -- '--no-verify'; then
  deny "Запрещено: git commit --no-verify обходит гейты качества. Найди и устрани причину падения проверок."
fi

if printf '%s' "$cmd" | grep -Eq 'git push[^|;&]*( --force| -f)\b' \
  && printf '%s' "$cmd" | grep -Eq '(^| )(origin|upstream) +(main|master)\b'; then
  deny "Запрещено: force push в main/master."
fi

# Политика merge: только PR, прошедший ревью. Ready — единственный путь
# после вердикта APPROVE (draft ставится при создании, ready — ревью-процессом),
# поэтому "не draft" = машинное доказательство апрува.
# ADK_GUARD_PR_STATE=draft|ready|unknown — тестовый обход сетевого вызова.
if printf '%s' "$cmd" | grep -Eq 'gh +pr +merge'; then
  state="${ADK_GUARD_PR_STATE:-}"
  if [ -z "$state" ]; then
    prnum=$(printf '%s' "$cmd" | grep -Eo 'gh +pr +merge +[0-9]+' | grep -Eo '[0-9]+' | head -1)
    repo_flag=$(printf '%s' "$cmd" | grep -Eo -- '(-R|--repo)[= ][^ ]+' | head -1 | sed -E 's/^(-R|--repo)[= ]//')
    if [ -n "$repo_flag" ]; then
      isdraft=$(gh pr view ${prnum:+"$prnum"} -R "$repo_flag" --json isDraft -q .isDraft 2>/dev/null) || isdraft=""
    elif [ -n "$git_root" ]; then
      isdraft=$(cd "$git_root" && gh pr view ${prnum:+"$prnum"} --json isDraft -q .isDraft 2>/dev/null) || isdraft=""
    else
      isdraft=""
    fi
    case "$isdraft" in
      false) state="ready" ;;
      true)  state="draft" ;;
      *)     state="unknown" ;;
    esac
  fi
  case "$state" in
    ready) ;;
    draft) deny "Запрещено: PR ещё черновик — merge возможен только после вердикта APPROVE (в ready PR переводит ревью-процесс, не merge-намерение)." ;;
    *) deny "Запрещено: статус PR проверить не удалось (нет git-репозитория в контексте команды или gh недоступен) — merge только для PR со статусом ready. Подсказка: выполняй merge из директории репозитория или с флагом -R owner/repo." ;;
  esac
fi

# --- Конвенция заголовка PR (SPEC-002, AC-5): при commitStyle=conventional
# заголовок PR — будущее сообщение squash-коммита в main, единственная точка
# контроля конвенции (веточные коммиты squash схлопывает, их не проверяем).
# Формат: <commitType>[(scope)]: <суть> (#N), commitType обязан
# соответствовать типу issue #N (label issue → types.*.commitType конфига).
# Не вмешиваемся: при plain (дефолт — проект без конфига ведёт себя как
# сегодня) и при conventions.externalTitleLint=true (серверный линтер
# заголовков уже есть — не переизобретаем, «Границы» SPEC-002).
# Недоступность gh или issue не блокирует ложно: формат проверяется всегда
# (сети не требует), сверка commitType с label'ом при недоступности
# пропускается. ADK_GUARD_ISSUE_LABELS — тестовый обход сетевого вызова
# (по образцу ADK_GUARD_PR_STATE): CSV labels issue; пустая строка —
# labels нет; "unavailable" — gh/issue недоступны.
if printf '%s' "$cmd" | grep -Eq 'gh +pr +(create|edit)'; then
  cfg_root="${git_root:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  style=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.commitStyle plain conventional,plain)
  ext_lint=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get conventions.externalTitleLint false)
  if [ "$style" = "conventional" ] && [ "$ext_lint" != "true" ]; then
    # Заголовок из --title/-t, принадлежащего именно вызову gh pr create/edit
    # (gh в командной позиции: начало строки или после ;, &&, ||, |, &;
    # перевод строки — тоже разделитель команд). Тело heredoc (<<MARKER …
    # MARKER) — данные, не команды. Не удалось разобрать строку (непарная
    # кавычка), не нашли вызов/флаг (интерактив, --fill, упоминание в доке)
    # или в заголовке нераскрытая shell-подстановка ($VAR, $(...), `...`) —
    # fail-open: проверять нечего, ложный блок хуже пропуска (issue #47).
    title=$(python3 -c '
import re, shlex, sys
lines, heredoc_end = [], None
for ln in sys.argv[1].split("\n"):
    if heredoc_end is not None:
        if ln.strip() == heredoc_end:
            heredoc_end = None
        continue
    m = re.search(r"<<-?\s*([\x27\"]?)(\w+)\1", ln)
    if m:
        heredoc_end = m.group(2)
    lines.append(ln)
seps = {"&&", "||", ";", "|", "&"}
title = ""
for ln in lines:
    try:
        toks = shlex.split(ln)
    except ValueError:
        continue
    at_start, i, n = True, 0, len(toks)
    while i < n:
        t = toks[i]
        if t in seps or t.endswith(";"):
            at_start = True
            i += 1
            continue
        if at_start and t == "gh" and toks[i + 1:i + 2] == ["pr"] \
                and toks[i + 2:i + 3] and toks[i + 2] in ("create", "edit"):
            j = i + 3
            while j < n and toks[j] not in seps and not toks[j].endswith(";"):
                a = toks[j]
                if a in ("--title", "-t") and j + 1 < n:
                    title = toks[j + 1]
                    j += 1
                elif a.startswith("--title="):
                    title = a[len("--title="):]
                j += 1
            i = j
            continue
        at_start = False
        i += 1
if "$" in title or "`" in title:
    title = ""
print(title)
' "$cmd")
    if [ -n "$title" ]; then
      if ! printf '%s' "$title" | grep -Eq '\(#[0-9]+\)$'; then
        deny "Запрещено: conventions.commitStyle=conventional — заголовок PR обязан заканчиваться ссылкой на issue «(#N)» (он станет сообщением squash-коммита в main). Получено: «$title»."
      fi
      issue_n=$(printf '%s' "$title" | grep -Eo '\(#[0-9]+\)$' | grep -Eo '[0-9]+')
      if [ -n "${ADK_GUARD_ISSUE_LABELS+x}" ]; then
        labels="$ADK_GUARD_ISSUE_LABELS"
      elif [ -n "$git_root" ] \
        && labels_raw=$(cd "$git_root" && gh issue view "$issue_n" --json labels -q '.labels[].name' 2>/dev/null); then
        labels=$(printf '%s' "$labels_raw" | tr '\n' ',')
      else
        labels="unavailable"
      fi
      # Вердикт по карте типов: дефолтные четыре (docs/config.md), поверх —
      # переопределения и кастомные типы из types.* конфига (только label и
      # commitType — остальные поля типов гейту не нужны). Формат заголовка
      # проверяется от известных commitType (алфавит не ограничивается);
      # labels=unavailable — сверка с label пропускается, формат остаётся.
      types_json=$(CLAUDE_PROJECT_DIR="$cfg_root" adk_config_get types "{}")
      verdict=$(python3 -c '
import json, re, sys
types_json, labels_csv, title = sys.argv[1:4]
types = {
    "task": {"label": "type:task", "commitType": "feat"},
    "bug": {"label": "type:bug", "commitType": "fix"},
    "fastFollow": {"label": "type:fast-follow", "commitType": "fix"},
    "consolidate": {"label": "type:consolidate", "commitType": "refactor"},
}
try:
    cfg = json.loads(types_json)
except Exception:
    cfg = {}
if isinstance(cfg, dict):
    for name, o in cfg.items():
        if isinstance(o, dict):
            t = types.setdefault(name, {})
            for k in ("label", "commitType"):
                if isinstance(o.get(k), str):
                    t[k] = o[k]
commit_types = sorted({t["commitType"] for t in types.values() if t.get("commitType")})
m = re.match(r"^(\S+?)(\([^)]*\))?: .+", title)
if not m or m.group(1) not in commit_types:
    print("format " + "|".join(commit_types))
    sys.exit(0)
if labels_csv == "unavailable":
    print("ok")
    sys.exit(0)
labels = [l.strip() for l in labels_csv.split(",") if l.strip()]
label_map = {t["label"]: t["commitType"] for t in types.values() if t.get("label") and t.get("commitType")}
matched = [l for l in labels if l in label_map]
expected = label_map[matched[0]] if matched else types["task"]["commitType"]
if m.group(1) == expected:
    print("ok")
else:
    # expected — последним: commitType из конфига может содержать пробел,
    # последнее поле read забирает остаток строки целиком
    print("mismatch %d %s %s" % (1 if matched else 0, m.group(1), expected))
' "$types_json" "$labels" "$title")
      case "$verdict" in
        ok) ;;
        format\ *)
          deny "Запрещено: conventions.commitStyle=conventional — заголовок PR обязан иметь формат «<commitType>[(scope)]: <суть> (#N)», где commitType — один из: ${verdict#format }. Получено: «$title»." ;;
        mismatch\ *)
          read -r _ vt_has vt_got vt_exp <<VERDICT_EOF
$verdict
VERDICT_EOF
          if [ "$vt_has" = "1" ]; then
            deny "Запрещено: commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — по label issue ожидается «$vt_exp». Формат: «<commitType>[(scope)]: <суть> (#N)»."
          else
            deny "Запрещено: commitType «$vt_got» в заголовке PR не соответствует типу issue #$issue_n — у issue нет label типа, он трактуется как task, ожидается «$vt_exp» (или проставь issue label типа). Формат: «<commitType>[(scope)]: <суть> (#N)»."
          fi ;;
      esac
    fi
  fi
fi

# --- Секрет-гейт: перед git commit сканируем изменения на ключи и .env ---
if printf '%s' "$cmd" | grep -q 'git commit' && [ -n "$git_root" ]; then
  secret_re='sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

  hits=$( (git -C "$git_root" diff HEAD 2>/dev/null; git -C "$git_root" diff --cached 2>/dev/null) \
    | grep '^+' | grep -v '^+++' | grep -E "$secret_re" | head -3 || true)

  if [ -z "$hits" ]; then
    while IFS= read -r uf; do
      [ -n "$uf" ] || continue
      f="$git_root/$uf"
      [ -f "$f" ] || continue
      [ "$(wc -c < "$f")" -lt 1000000 ] || continue
      h=$(grep -E "$secret_re" "$f" 2>/dev/null | head -3 || true)
      if [ -n "$h" ]; then
        hits="$uf: $h"
        break
      fi
    done <<EOF
$(git -C "$git_root" ls-files --others --exclude-standard 2>/dev/null | head -200)
EOF
  fi

  env_staged=$(git -C "$git_root" diff --cached --name-only 2>/dev/null \
    | grep -E '(^|/)\.env(\.[^/]+)?$' | grep -v '\.env\.example' || true)

  if [ -n "$hits" ]; then
    deny "Запрещено: в изменениях найдено похожее на секрет (ключ/токен). Убери секрет в переменные окружения (.env, не коммитится) и перегенерируй скомпрометированный ключ. Найдено:
$hits"
  fi
  if [ -n "$env_staged" ]; then
    deny "Запрещено: в коммит попадает файл окружения ($env_staged). Файлы .env не коммитятся; для примера используй .env.example без реальных значений."
  fi
fi

exit 0
