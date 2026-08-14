# Конфигурация процесса (`adk.config.json`)

Спека: [SPEC-002](specs/002-process-config.md). Конфиг — плоский набор
независимых атрибутов в корне проекта, `adk.config.json`. Профилей и
пресетов в рантайме нет — пресеты существуют только как ярлыки ответов в
диалоге `/project-init`.

Читатель — `hooks/scripts/lib/config.sh` (sourceable для хуков) и его
CLI-обёртка `hooks/scripts/adk-config.sh` (для инструкций команд).
**Отсутствие файла или отдельного атрибута = дефолт этого атрибута.**
Это не просто дефолт по вкусу — каждый дефолт ниже осознанно выбран так,
чтобы воспроизводить сегодняшнее поведение кита. Проект без
`adk.config.json` ведёт себя ровно так же, как до появления конфига.

Битый JSON в файле трактуется как отсутствие файла (дефолт, exit 0) —
конфиг никогда не роняет хук.

Атрибуты типа `bool` читатель печатает как `true`/`false` (строчными) —
и когда значение взято из файла, и когда это дефолт: одна и та же
величина не должна выглядеть по-разному в зависимости от источника.

## Неизвестное значение атрибута

Для атрибутов с закрытым списком значений (enum) читатель принимает
необязательный третий параметр — список допустимых значений. Если
значение в файле есть, но не входит в этот список, читатель **не**
молча использует дефолт как ни в чём не бывало: он печатает дефолт,
но завершается с exit 1 и пишет предупреждение в stderr. Отличие от
случая «атрибута нет» важно: у части атрибутов (например
`policies.merge`) дефолт умышленно самый разрешающий — это
обратная совместимость, а не то же самое, что опечатка в значении.
Опечатку нельзя молча трактовать как то же самое осознанное
разрешение — так дефолт разрешал бы опасное действие втихую.
Вызывающий (хук или команда), которому важна разница, обязан проверять
exit-код; тот, кому не важна (значение не из закрытого списка), может
использовать только stdout, как и раньше.

## Таблица атрибутов

### `policies` — кто и что может

| Атрибут | Тип / допустимые значения | Дефолт | Какое сегодняшнее поведение воспроизводит |
|---|---|---|---|
| `policies.merge` | `agent-after-approve` \| `human-review-required` \| `human-only` | `agent-after-approve` | Ready-PR мержит кто угодно, включая `/autopilot`, — сегодня ничего это не ограничивает. |
| `policies.review.maxRounds` | число | `2` | `/work` и `/autopilot` останавливаются и зовут человека после двух кругов ревью без APPROVE (см. `commands/work.md`, шаг 6). |
| `policies.review.humanApprovalRequired` | bool | `false` | Вердикт даёт reviewer-агент; человек не обязан approve'ить PR отдельно. |
| `policies.autopilot.enabled` | bool | `true` | `/autopilot` стартует без ограничений; `false` — отказ старта без побочных эффектов (читается в `commands/autopilot.md`, «Политика прогона»). |
| `policies.autopilot.canMerge` | bool | `true` | `/autopilot` мержит ready-PR сам (`gh pr merge --squash --delete-branch`); `false` — ready-PR собираются в список «ждут человека» (`result=ready`, ADR-003). |
| `policies.autopilot.maxTasksPerRun` | число | `5` | Лимит задач `/autopilot` за прогон; аргумент команды его переопределяет (`commands/autopilot.md`, «Параметры»). |

`policies.merge` энфорсится хуком bash-guard (SPEC-002 AC-2): `human-only`
— merge из агентских сессий блокируется всегда; `human-review-required` —
сверх проверки ready требуется человеческий approve на PR
(`reviewDecision == APPROVED`); неизвестное значение атрибута блокирует
merge (fail-closed, см. «Неизвестное значение атрибута» выше). Важно про
`human-review-required`: GitHub заполняет `reviewDecision` только когда в
репозитории ревью обязательно (branch protection required reviews /
CODEOWNERS) — без этого поле пустое даже при живом approve, и merge будет
блокироваться всегда; включайте политику вместе с серверным требованием
ревью.

### `conventions` — как выглядит история

| Атрибут | Тип / допустимые значения | Дефолт | Какое сегодняшнее поведение воспроизводит |
|---|---|---|---|
| `conventions.squash` | bool | `true` | Squash уже внедрён как дефолт в командах и серверно (см. «Решённые вопросы» SPEC-002). |
| `conventions.branchUpdate` | `rebase` \| `merge` | `rebase` | Дефолт спеки; сегодня кит не актуализирует ветки автоматически (это AC-8, отдельная задача) — значение определяет будущее поведение при его появлении. |
| `conventions.commitStyle` | `conventional` \| `plain` | `plain` | Заголовки PR сегодня — «глагол + результат (#N)», не формат `<type>(scope): summary` (`commands/work.md`, шаг 5). |
| `conventions.language` | строка (код языка) | `ru` | Промпты и коммуникация кита сегодня на русском. |
| `conventions.branchPattern` | строка-шаблон с `{n}`/`{slug}` | `issue-{n}-{slug}` | Дефолт из самой спеки; совпадает с сегодняшним `commands/work.md` (шаг 2). |
| `conventions.attribution` | bool | `true` | Trailer `Co-Authored-By` сегодня добавляется в коммиты по умолчанию (стандартное поведение агента), конфиг не отключает это неявно. |
| `conventions.externalTitleLint` | bool | `false` | Отключает локальную валидацию заголовка PR при `commitStyle=conventional` (issue #47, AC-5), если у проекта уже есть серверный линтер (commit-lint, PR-title-check) — переизобретать его не нужно (раздел «Границы» SPEC-002). Дефолт `false`: локальная валидация, когда она появится, включена. |

### `types` — типизация work items

Четыре дефолтных типа. Ключ — имя типа (`task`, `bug`, `fastFollow`,
`consolidate`), значение — объект с полями `label`, `commitType`,
`requiredFields`. Отсутствие label у issue сегодня и после появления
типов трактуется как `task` (безопасный дефолт, «Решённые вопросы»
SPEC-002). `types.task.label` читает `/plan`: при создании issues он
создаёт этот label в репозитории и вешает на каждый issue (AC-4,
issue #45). `/work` читает labels issue, определяет тип по совпадению с
`types.<имя>.label` (нет label или label неизвестен — тип `task`),
применяет правила типа на реализации и ставит `commitType` типа в
заголовок PR (AC-4, issue #46).

| Тип | `label` | `commitType` | `requiredFields` |
|---|---|---|---|
| `task` | `type:task` | `feat` | `Контекст`, `Сделать`, `DoD` (с AC-ссылками и «Зависимости») |
| `bug` | `type:bug` | `fix` | `Воспроизведение`, `Ожидаемое`, `Фактическое`, `Сбежал от: <гейт>` |
| `fastFollow` | `type:fast-follow` | `fix` | `Источник: вердикт ревью PR #N` |
| `consolidate` | `type:consolidate` | `refactor` | — (спека не задаёт обязательных полей сверх текста задачи) |

## Пример

```json
{
  "policies": {
    "merge": "human-review-required",
    "review": { "maxRounds": 3, "humanApprovalRequired": true },
    "autopilot": { "enabled": true, "canMerge": false, "maxTasksPerRun": 3 }
  },
  "conventions": {
    "squash": true,
    "branchUpdate": "rebase",
    "commitStyle": "conventional",
    "attribution": true
  }
}
```

Незаданные атрибуты (в примере — `conventions.language`,
`conventions.branchPattern`, весь блок `types` и т.д.) берут дефолт из
таблицы выше.
