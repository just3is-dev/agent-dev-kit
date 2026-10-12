# ADR-028: bash-guard определяет обход гейтов по словам вызова `git commit` / `git push`, а не по подстроке

Дата: 2026-10-12
Статус: accepted <!-- accepted | superseded by ADR-XXX -->

## Контекст

`bash-guard.sh` искал два обхода гейтов подстрокой по всему тексту команды:
`git commit` + `--no-verify` и `git push … (--force|-f)` + `(origin|upstream)
 +(main|master)`. Обе стороны подстроки дырявы (issue #265, прогон на main):
`git commit -n -m x`, `-m x -n`, `-nm x`, `-a -n`, `git push origin +main`,
`git push origin HEAD:main --force`, `git push --no-verify origin foo`
проходили, а `echo 'git commit --no-verify'` и `grep -n 'git commit' f &&
echo '--no-verify'` блокировались (тот же класс, что исправлял ADR-026 для
merge). Секрет-скан запускался по подстроке `git commit` и не видел
`git -C dir commit` и `git -c k=v commit`.

## Решение

Тот же лексер, что у merge (ADR-026), — второй механизм поверх него: лексер
отдаёт слова простой команды, различитель — флаг внутри вызова. Один
источник python-кода (`ADK_INVOCATION_PY` в `lib/command-invocation.sh`,
режим `git`), функция `adk_command_git_bypass`, коды возврата как у
`adk_command_invokes_pr_merge` (0 — вызов или неоднозначность, 1 — нет, 2 —
упоминание рядом с командой вне белого списка `inert()`), находки — в
глобальной `ADK_GIT_FINDINGS` (`no-verify`, `force-push`, `push-no-verify`,
`ambiguous`, `commit`). Быстрый выход: в тексте нет `commit` и `push`.

**Вызов.** Слово `git` (по basename или динамическое слово) в любом месте
простой команды — так же ловятся `env`, `sudo`, `xargs`, `eval`, `command`,
`nohup`; перенаправления в слова не входят. Дальше глобальные опции из белого
списка (`-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace`, `--config-env`,
`--super-prefix` — со значением; `--git-dir=…` и т. п.; `-p`, `--no-pager`,
`--bare` и прочие булевы), затем подкоманда. Неизвестная опция или
динамическое слово вместо подкоманды — неоднозначность, но только если после
них есть слово `commit`/`push` (у литерального `git` с динамической
подкомандой — всегда).

**`git commit`** — блокируется `--no-verify` (в том числе `--no-verify=…` и
сокращения `--no-veri`, `--no-verif`: git их принимает) и короткий `-n` в
любой позиции и в любой склейке (`-nm`, `-anm`, `-vn`, `-nS`). Склейка читается
как у git: буква значения (`m F C c t`) забирает остаток слова или следующее
слово (`-mn` — сообщение «n», `-m -n` — сообщение «-n», `-Fa -n` — флаг
после значения), `u` и `S` — только приклеенное значение (`-Sn` — ключ «n»).
Значения длинных флагов (`--message`, `--file`, `--author`, `--date`, …,
`--pathspec-from-file`) пропускаются так же. **`--` заканчивает опции**:
`git commit -m x -- -n` — путь `-n`, а не флаг (проверено на git 2.39; такой
вызов git отвергает как неизвестный pathspec). Позиционное слово вне `--` с
`$`, `{` в начале или подстановкой внутри — неоднозначность: оно может
оказаться флагом (`"$f"`, `{-n,a}`, `$'\x2dn'`); пути с переменными пишут
после `--`.

**`git push`** — блокируется принудительная запись в `main`/`master`:
`-f` (в склейке `-fu`, `-uf`, `-nf`), `--force`, `--force-with-lease[=…]` и
сокращения от `--force-w`, либо `+`-ссылка (`+main`, `+HEAD:main`). Цель —
правая часть ссылки (`<src>:<dst>`, без двоеточия — само слово), с
нормализацией `refs/heads/` и `heads/`; `main:feature` — не цель, ссылка со
звёздочкой — цель. Принуждение действует на ссылку, если оно глобальное
(флаг) или стоит `+` именно у неё: `+feature main` разрешено. Remote — любой,
не только `origin`/`upstream`: слово remote ничего не решает, все позиционные
слова — кандидаты в ссылки (`--repo=x -f main` тоже блокируется).
`--all`/`--branches` с force и `--mirror` — запись во все ветки, то есть и в
main. Динамическое слово среди позиционных (`"$B"`, `$(git branch
--show-current)`) — неоднозначность: ссылка пишется литерально
(`git push -u origin HEAD` проходит). Флаги `--force-with-lease` без ссылки
(`git push --force-with-lease`, как в `commands/plan.md`) и штатные
`git push --force-with-lease origin <ветка>` проходят.

**`git push --no-verify`** — блокируется, отдельный текст отказа. `pre-push` —
такой же гейт качества, как `pre-commit`, и `--no-verify` обходит его тем же
способом; в процессе кита (`/work`, `/review`, `/autopilot`) он не нужен.
`-n` у push — `--dry-run`, не флаг обхода (проверено на git 2.39).

**Упоминание.** То же правило, что у merge: слово с `git … commit … (--no-verify|-n…)`
или `git … push … (force-флаг и main/master|--all|--branches, `+ссылка`,
--mirror, --no-verify)` рядом с командой вне белого списка (`bash -c`, `eval`,
`| bash`, `ssh`, `python3 -c`, запуск записанного файла, `git push`, `make`) —
отказ с тем же префиксом, что у merge, плюс причина вызова. Рядом с
инертными (`echo`, `grep`, `cat`, `git commit -m`, `git log`, `gh pr
comment`, heredoc, `adk-log.sh`) — разрешено. Сбой разбора (незакрытая
кавычка, `$(` в unquoted heredoc, исключение) — отказ с текстом про
неоднозначность, если в сыром тексте есть та же фраза.

**Секрет-скан** (бывшая строка 97) — условие запуска **расширено, не
сужено**: подстрока `git commit` ИЛИ вызов `commit` по словам. Пропущенный
скан — утёкший секрет, лишний — лишняя работа, поэтому подстрока остаётся, а
вызов по словам закрывает `git -C d commit`, `git -c k=v commit`,
`"$GIT" commit`, `git  commit` (подстрока их не видела). Переход на «только
по вызову» отклонён: `bash -c "git commit -m x"` тогда остался бы без скана
(упоминание без флага не отказ).

**Что не меняется.** Ветка merge (`deny_merge`, `check_merge_target`,
`ADK_PR_MERGE_TARGETS`), политика `policies.merge`, тексты отказов для
прямого `git commit --no-verify` и force push. Изменение поведения, которое
стоит знать: `git push -f origin main:feature` раньше блокировался
подстрокой `origin main`, теперь разрешён (цель — `feature`);
`git push -f fork main`, `git push -f origin refs/heads/main` раньше
проходили, теперь блокируются.

## Отклонено

- **Дописать регулярки** (`-[a-z]*n`, `\+main`). Каждая форма — новая дыра,
  а ложные срабатывания на упоминании остаются: это рукописный парсер по
  тексту, который ADR-026 отверг.
- **Блокировать любое `git push --force*`.** `git push --force-with-lease
  origin <ветка>` — штатная форма `/work` после rebase.
- **Ограничить remote списком `origin|upstream`.** Список — whitelist
  обхода: `fork`, URL проходили бы; в процессе кита force-push в main не
  нужен ни в какой remote.
- **Правило «`-n` где угодно после `commit`».** Ложный отказ на значении
  (`-m -n`, `-Fnotes.txt`) и после `--`; разбор значений проще и точнее.
- **Второй лексер для git.** Один источник кода: правка лексера чинит и
  merge, и git.

## Последствия

- Штатные формы проходят: `git commit -m "…"`, `-am`, `-F файл`,
  `git commit -m "$(cat <<'EOF' … EOF)"`, `git push origin <ветка>`,
  `git push -u origin HEAD`, `git push --force-with-lease origin <ветка>`.
- Новые отказы (fail-closed, цена — переписать вызов литерально): `git push
  origin "$BRANCH"`, `git commit "$f"` (пути — после `--`), `git push -f`
  с `$(…)` в ссылке, `git $SUB …`, `git --новая-опция commit …`,
  `bash -c 'git commit -n …'`, `echo 'git commit -n' | bash`,
  `git commit -m "… git commit -n …" && git push` (упоминание рядом с
  `git push`: делить на вызовы или `-F файл`).
- Фикстуры (`tests/run.sh`, блок issue #265) — таблица «команда => вид»,
  вид (allow / nv / force / pnv / amb / mention-*) сверяется по коду выхода и
  тексту отказа, для allow — пустой stderr; каждый флаг, склейка, значение,
  глобальная опция, оператор, обёртка и ссылка проверены мутацией на копии
  (отчёт в PR).

## Известные пропуски

Хук защищает от ошибок агента, а не от намеренного обхода; правил для
этих классов нет (ADR-026, «Известные пропуски»).

- **Цель не названа в словах:** `git push --force`, `git push -f origin
  HEAD`, `git push --force-with-lease` при checkout main — цель берёт git из
  конфигурации и HEAD; хук не читает состояние репозитория.
- **Удаление и зеркало без force:** `git push --delete origin main`,
  `git push origin :main`.
- **Обход хуков не через флаг:** `git -c core.hooksPath=/dev/null commit`,
  `core.hooksPath` в конфиге; `--no-verify` у других подкоманд
  (`git merge`, `git rebase`, `git am`).
- **Псевдонимы git** (`git ci -n` по `alias.ci`, `-c alias.x=commit x -n`) и
  старая форма `git-commit` — подкоманда не `commit`/`push` по слову.
- **Быстрый выход по подстроке `commit|push`:** `git com''mit -n`,
  `git pu\sh -f origin main` (подстрока их тоже не ловила).
- **Глоб, который раскроется в файл `-n`:** `git commit ?n` при файле `-n`
  в каталоге.
- **Запись файла, который исполняется другим вызовом** — класс из ADR-026.
