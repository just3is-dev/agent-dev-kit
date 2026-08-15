---
description: Взять задачу (issue) в работу: ветка → тесты → код → гейты → PR → ревью
argument-hint: "[номер issue; по умолчанию следующий незаблокированный из текущего milestone]"
---

Выполни одну задачу от issue до PR с вердиктом ревьюера.

Нотация ниже: `<N>` — номер issue, `<PR>` — номер pull request.

1. **Выбери задачу.** `$ARGUMENTS` — номер issue, иначе возьми через
   `gh issue list --state open` следующий незаблокированный issue текущего
   milestone (зависимости «Blocked by #N» с незакрытыми N пропускай).
   Прочитай issue целиком — он самодостаточен. Непонятен DoD — остановись
   и спроси пользователя, не додумывай.
   **Определи тип задачи по label** — label единственный источник типа,
   из текста issue тип не выводится (SPEC-002). Возьми labels issue
   (`gh issue view <N> --json labels`) и сопоставь с labels типов из
   конфига проекта (отсутствие конфига или атрибута = дефолт,
   см. docs/config.md):
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh types.task.label type:task`,
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh types.bug.label type:bug`,
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh types.fastFollow.label type:fast-follow`,
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh types.consolidate.label type:consolidate`.
   Совпавший label задаёт тип. Нет label или ни один label не совпал с
   типами — тип `task` (безопасный дефолт). Тип определяет правила
   реализации (шаг 3), commitType заголовка PR (шаг 5) и пишется в журнал
   (`type=<тип>` — имя типа из конфига: task|bug|fastFollow|consolidate,
   расширение схемы ADR-001; по нему `/stats` режет агрегаты). Залогируй
   старт: `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-log.sh issue-<N>
   event=start issue=<N> type=<тип> || true` (журнал — наблюдаемость,
   не гейт: провал записи не блокирует задачу).
2. **Подготовь ветку.** Обнови main (`git pull`), создай
   `issue-<N>-<слаг>`. Одна задача = одна ветка = один PR.
3. **Реализуй по скиллу tdd:** DoD → падающие тесты → минимальная
   реализация → зелёные `./scripts/check` и `./scripts/test`. Если DoD
   ссылается на критерий приёмки спеки (AC-N) — тест, закрывающий этот
   пункт, помечается тем же номером AC (конвенция тегирования — skills/tdd);
   если этот AC в спеке помечен аннотацией `(ждёт #N)` — сними её в том же
   PR: тест появился, «ждать» больше нечего.
   **Примени правила типа задачи** (тип — из шага 1):
   - `task` — тесты по DoD помечаются AC-тегами, как выше;
   - `bug` — первый шаг всегда падающий репро-тест, воспроизводящий баг
     по шагам из тела issue; без воспроизведения фикс не начинается.
     Поля тела «Воспроизведение» / «Ожидаемое» / «Фактическое» /
     «Сбежал от: <гейт>» обязательны — если их нет, репро строить не из
     чего: остановись и спроси пользователя, как с непонятным DoD;
   - `fastFollow` — источник задачи — вердикт ревью PR #N (поле
     «Источник» в теле issue): исправь ровно то, на что указал вердикт;
   - `consolidate` — рефакторинг: наблюдаемое поведение не меняется,
     существующие тесты остаются зелёными без правок.

   Выходишь за рамки issue — стоп:
   лишнее не делай; найденное попутно оформи предложением нового issue
   в отчёте, а не правкой «заодно».

   **План оказался неверен** (задача нереализуема как поставлена, конфликтует
   с другой, спека не учла найденное в коде) — остановись. Не подгоняй
   реализацию под ошибочный план и не «доделывай как понял»: покажи
   пользователю проблему и предложи правку спеки/плана; после апрува обнови
   issue и спеку (в том же PR), затем продолжай.
4. **Неочевидные решения** по ходу — ADR (скилл adr), в том же PR.
5. **PR — черновиком.** Коммить логическими шагами. `git push -u origin
   <ветка>`, затем `gh pr create --draft`. **Заголовок PR — это будущий
   squash-коммит в main** (merge делается со squash), по нему история main
   читается как чейнджлог. Заголовок получает `commitType` типа задачи
   (шаг 1) — прочитай его из конфига:
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh types.<тип>.commitType <дефолт>`
   (дефолты: task → `feat`, bug → `fix`, fastFollow → `fix`,
   consolidate → `refactor`). При `conventions.commitStyle=conventional`
   формат заголовка — `<commitType>[(scope)]: <суть> (#N)` (фактический
   заголовок PR после `gh pr create`/`gh pr edit` сверяет
   PostToolUse-хук pr-title-check, AC-5 SPEC-002); при `plain` (дефолт) —
   «глагол + результат (#N)». Тело: `Closes #N`, что сделано,
   какие тесты это доказывают, ссылки на ADR. Никаких «попутных» изменений
   в PR. Draft — это механическая защита: GitHub не даёт смержить черновик,
   поэтому PR не переводится в ready ничем, кроме шага 6.
6. **Ревью.** Запусти reviewer-агента (agent-dev-kit:reviewer), передав ему
   номер issue и PR. Вердикт запость комментарием в PR (`gh pr comment`),
   затем залогируй круг (номер круга — начиная с 1, считая с этого прогона
   ревью): `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-log.sh issue-<N>
   event=review round=<номер круга> verdict=<APPROVE|REQUEST_CHANGES> ||
   true`. APPROVE — перед переводом в ready проверь актуальность ветки
   (AC-8 SPEC-002). Факт отставания бери из git, а не из GitHub-статусов
   (`mergeStateStatus=BEHIND` GitHub отдаёт только при включённом
   `required_status_checks.strict`): `git fetch origin &&
   git rev-list --count HEAD..origin/main` — счётчик больше нуля значит
   BEHIND, ветка отстала. Конфликтность — `gh pr view <PR> --json
   mergeable`: `CONFLICTING` — конфликт с main, остановись и позови
   пользователя, конфликт разрешает человек; `UNKNOWN` — GitHub ещё
   считает mergeability, повтори запрос. Отставшую ветку актуализируй
   способом из конфига
   (`${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh
   conventions.branchUpdate rebase rebase,merge`; ненулевой exit = опечатка
   в конфиге, остановись; fetch уже сделан выше): `rebase` (дефолт) —
   перебазируй (`git rebase origin/main`), затем `git push
   --force-with-lease origin <ветка PR>`; `merge` — влей main в ветку
   (`git merge origin/main`), затем `git push origin <ветка PR>`.
   Конфликт при самой актуализации (rebase останавливается, merge не
   применяется) — прерви её (`git rebase --abort` / `git merge --abort`),
   остановись и позови пользователя, как при `CONFLICTING`. После
   актуализации обязательно перегони гейты (`./scripts/check`,
   `./scripts/test`) и дождись зелёного CI: переводить PR в ready без
   перегона гейтов после актуализации запрещено — зелёные проверки
   отставшей ветки относятся к устаревшему состоянию кода. Ветка
   актуальна и гейты зелёные —
   переведи PR из черновика: `gh pr ready <PR>`; только этот шаг делает
   merge возможным. REQUEST_CHANGES — PR остаётся draft:
   исправь блокеры и «важно», прогони гейты, запусти ревью повторно
   (залогировав второй круг тем же способом); после двух кругов без
   APPROVE — остановись и позови пользователя (PR оставь черновиком —
   решение о ready принимает человек; продолжение обычно через команду
   /review, она авторизует дополнительный круг).
7. **Итог.** Перед отчётом залогируй итог по схеме ADR-001
   (docs/adr/001-journal-event-schema.md): `event=outcome`, результат
   (`result=merged` — PR переведён в ready после APPROVE, дальнейший
   merge делает человек/`/autopilot`; или `result=stuck`), причина при
   `stuck` (число кругов ревью отдельным полем не логируется — агрегатор
   `adk-stats.sh` считает их сам из строк `event=review` этого же
   журнала), длительность от старта (разница между текущим временем и
   `timestamp` **последней** строки с `event=start` в журнале `issue-<N>`
   — если `/work` по этой задаче запускался повторно, самая ранняя
   строка не годится) и размер диффа (`git diff main... --shortstat`).
   `reason` обычно содержит пробелы — заключай в кавычки, как `diff`:
   `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-log.sh issue-<N>
   event=outcome type=<тип> result=<merged|stuck>
   [reason="<причина, только при result=stuck>"]
   duration=<сек>s diff="<вывод git diff main... --shortstat>" || true`
   (`type` — тот же тип задачи, что в `event=start` шага 1).
   **Отчёт пользователю:** ссылка на PR, вердикт ревьюера, что осталось
   до merge — формулировка по политике
   (`${CLAUDE_PLUGIN_ROOT}/hooks/scripts/adk-config.sh policies.merge
   agent-after-approve`): при `agent-after-approve` merge сделает человек
   или /autopilot (в обоих случаях только ready-PR после APPROVE); при
   `human-review-required` и `human-only` пиши «PR готов к ревью коллеги»
   — не «смержено» и не «будет смержено автоматически»: merge при этих
   политиках делает только человек.
