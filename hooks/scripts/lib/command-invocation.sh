#!/usr/bin/env bash
# Общий хелпер для bash-guard.sh: вызывает ли Bash-команда `gh pr merge`
# (issue #260, ADR-026). Раньше хук искал фразу подстрокой по всему тексту
# команды и блокировал grep/echo/heredoc/git commit -m с её упоминанием.
#
# Использование (три кода возврата — if ... then трактует 2 как «нет вызова»):
#   adk_command_invokes_pr_merge "$cmd"
#   case $? in
#     1) ;;                 # вызова нет
#     2) ... ;;             # упоминание рядом с неинертной командой
#     *) ... ;;             # вызов или разобрать не удалось
#   esac
#
# Код возврата 0 — команда вызывает merge или разобрать её однозначно не
# удалось (fail-closed); 1 — вызова нет; 2 — прямого вызова не найдено, но
# фраза упомянута рядом с командой, про которую нельзя доказать, что она её
# не исполнит (fail-closed). Правила — в ADR-026.
#
# Кроме кода возврата функция выставляет глобальную переменную
# ADK_PR_MERGE_TARGETS (issue #266, ADR-027): по записи на каждый найденный
# вызов, по одной на строку. Запись — «<селектор>|<-R>»: селектор (номер, URL
# или ветка из слов вызова; пустой — PR текущей ветки, семантика gh) и
# значение -R/--repo из слов того же вызова. Запись «?» — PR не определён
# однозначно (значение флага без селектора, подстановка, неизвестный флаг,
# лишний аргумент, селектор от обёртки вроде xargs, фраза внутри строки для
# bash -c/eval). Пусто при коде 1 и 2 и при сбое разбора — вызывающий
# трактует пустое как «?».
adk_command_invokes_pr_merge() {
  ADK_PR_MERGE_TARGETS=""
  case "$1" in
    *merge*) ;;
    *) return 1 ;;
  esac
  local src verdict
  IFS= read -r -d '' src <<'PY' || true
import re
import sys

TEXT_TOOLS = {"grep", "egrep", "fgrep", "echo", "printf", "cat", "head", "tail",
              "wc", "cut", "tr", "uniq", "nl", "tee", "cd", "ls", "pwd"}
GIT_SUBS = {"commit", "tag", "log", "show", "notes", "diff", "status", "add",
            "stash", "branch"}
GH_GROUPS = {"pr", "issue", "api"}
NUL = "\x00"


class Ambiguous(Exception):
    pass


PHRASE = (r"gh\b", r"\bpr\b", r"\bmerge\b")


def in_order(text):
    pos = 0
    for pattern in PHRASE:
        m = re.compile(pattern).search(text, pos)
        if m is None:
            return False
        pos = m.end()
    return True


def mentions(cmd):
    return any(in_order(line) for word in cmd for line in word.split("\n"))


class Frame:
    def __init__(self):
        self.cmds = []
        self.cmd = []
        self.chars = None

    def add(self, text):
        if self.chars is None:
            self.chars = []
        self.chars.append(text)

    def flush_word(self):
        if self.chars is not None:
            self.cmd.append("".join(self.chars))
        self.chars = None

    def end_cmd(self):
        self.flush_word()
        if self.cmd:
            self.cmds.append(self.cmd)
            self.cmd = []

    def absorb(self, cmds):
        self.cmds.extend(cmds)


class Parser:
    def __init__(self, s):
        self.s = s
        self.n = len(s)
        self.i = 0
        self.pending = []

    def run(self):
        cmds = self.lex(False)
        if self.pending:
            raise Ambiguous()
        return cmds

    def lex(self, nested):
        f = Frame()
        s, n = self.s, self.n
        while True:
            if self.i >= n:
                if nested:
                    raise Ambiguous()
                break
            c = s[self.i]
            nxt = s[self.i + 1] if self.i + 1 < n else ""
            if c in " \t\r":
                f.flush_word()
                self.i += 1
            elif c == "\n":
                f.end_cmd()
                self.i += 1
                self.read_heredocs()
            elif c == "#" and f.chars is None:
                while self.i < n and s[self.i] != "\n":
                    self.i += 1
            elif c == ";":
                f.end_cmd()
                self.i += 1
            elif c == "|":
                f.end_cmd()
                self.i += 2 if nxt in ("|", "&") else 1
            elif c == "&":
                prev = s[self.i - 1] if self.i else ""
                if nxt == "&":
                    f.end_cmd()
                    self.i += 2
                elif prev in ("<", ">") or nxt == ">":
                    f.add(c)
                    self.i += 1
                else:
                    f.end_cmd()
                    self.i += 1
            elif c == "(":
                self.i += 1
                f.absorb(self.lex(True))
            elif c == ")":
                f.end_cmd()
                self.i += 1
                if nested:
                    return f.cmds
            elif c == "\\":
                if nxt == "\n":
                    self.i += 2
                elif nxt == "":
                    f.add("\\")
                    self.i += 1
                else:
                    f.add(nxt)
                    self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise Ambiguous()
                f.add(s[self.i + 1:j])
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.dquote(f)
            elif c == "`":
                self.backtick(f)
            elif c == "$":
                if nxt == "(":
                    self.i += 2
                    f.absorb(self.lex(True))
                    f.add(NUL)
                elif nxt == "'":
                    self.ansi_c(f)
                else:
                    f.add("$")
                    self.i += 1
            elif c == "<" and s.startswith("<<<", self.i):
                f.add("<<<")
                self.i += 3
            elif c == "<" and nxt == "<":
                self.heredoc_op(f)
            elif c in "<>" and nxt == "(":
                self.i += 2
                f.absorb(self.lex(True))
                f.add(NUL)
            else:
                f.add(c)
                self.i += 1
        f.end_cmd()
        return f.cmds

    def dquote(self, f):
        s, n = self.s, self.n
        f.add("")
        while True:
            if self.i >= n:
                raise Ambiguous()
            c = s[self.i]
            if c == '"':
                self.i += 1
                return
            if c == "\\" and self.i + 1 < n:
                nx = s[self.i + 1]
                if nx != "\n":
                    f.add(nx if nx in '$`"\\' else "\\" + nx)
                self.i += 2
            elif c == "$" and s.startswith("$(", self.i):
                self.i += 2
                f.absorb(self.lex(True))
                f.add(NUL)
            elif c == "`":
                self.backtick(f)
            else:
                f.add(c)
                self.i += 1

    def backtick(self, f):
        s, n = self.s, self.n
        j = self.i + 1
        while j < n and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        if j >= n:
            raise Ambiguous()
        f.absorb(Parser(s[self.i + 1:j].replace("\\`", "`")).run())
        f.add(NUL)
        self.i = j + 1

    def ansi_c(self, f):
        s, n = self.s, self.n
        j = self.i + 2
        buf = []
        while True:
            if j >= n:
                raise Ambiguous()
            if s[j] == "\\" and j + 1 < n:
                buf.append(s[j + 1])
                j += 2
            elif s[j] == "'":
                break
            else:
                buf.append(s[j])
                j += 1
        f.add("".join(buf))
        self.i = j + 1

    def heredoc_op(self, f):
        s, n = self.s, self.n
        self.i += 2
        strip = False
        if self.i < n and s[self.i] == "-":
            strip = True
            self.i += 1
        while self.i < n and s[self.i] in " \t":
            self.i += 1
        f.flush_word()
        f.add("<<")
        f.flush_word()
        literal = False
        buf = []
        while self.i < n and s[self.i] not in " \t\r\n;&|()<>":
            ch = s[self.i]
            if ch in "'\"":
                j = s.find(ch, self.i + 1)
                if j < 0:
                    raise Ambiguous()
                buf.append(s[self.i + 1:j])
                literal = True
                self.i = j + 1
            elif ch == "\\":
                if self.i + 1 >= n:
                    raise Ambiguous()
                buf.append(s[self.i + 1])
                literal = True
                self.i += 2
            else:
                buf.append(ch)
                self.i += 1
        delim = "".join(buf)
        if not delim:
            raise Ambiguous()
        self.pending.append((f.cmd, delim, strip, literal))

    def read_heredocs(self):
        s, n = self.s, self.n
        for cmd, delim, strip, literal in self.pending:
            lines = []
            while True:
                if self.i >= n:
                    raise Ambiguous()
                j = s.find("\n", self.i)
                end = n if j < 0 else j
                line = s[self.i:end]
                self.i = n if j < 0 else j + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            body = "\n".join(lines)
            if not literal and ("$(" in body or "`" in body):
                raise Ambiguous()
            cmd.append(body)
        self.pending = []


VALUE_FLAGS = {"-t", "--subject", "-b", "--body", "-F", "--body-file",
               "--match-head-commit", "-A", "--author-email", "-R", "--repo"}
BOOL_FLAGS = {"--admin", "--auto", "-d", "--delete-branch", "--disable-auto",
              "-m", "--merge", "-r", "--rebase", "-s", "--squash", "-h", "--help"}
REPO_FLAGS = {"-R", "--repo"}
TRANSPARENT = {"env", "command", "sudo", "time"}
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
SELECTOR = re.compile(r"[A-Za-z0-9#][A-Za-z0-9._/:@#+-]*\Z")
REPO = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){1,2}\Z")


def split_flag(word):
    if word.startswith("--") and len(word) > 2:
        name, eq, value = word.partition("=")
        return [(name, value if eq else None)]
    flags = []
    for j in range(1, len(word)):
        flag = "-" + word[j]
        if flag in VALUE_FLAGS:
            flags.append((flag, word[j + 1:] or None))
            break
        flags.append((flag, None))
    return flags


def scan(words):
    positional, repos, k = [], [], 0
    while k < len(words):
        word = words[k]
        k += 1
        if not word.startswith("-") or len(word) < 2:
            positional.append(word)
            continue
        for flag, value in split_flag(word):
            if flag in VALUE_FLAGS:
                if value is None:
                    if k >= len(words):
                        raise Ambiguous()
                    value = words[k]
                    k += 1
                if flag in REPO_FLAGS:
                    repos.append(value)
            elif flag not in BOOL_FLAGS or value is not None:
                raise Ambiguous()
    return positional, repos


def merge_target(cmd, g, p, m):
    try:
        before, before_repos = scan(cmd[g + 1:p] + cmd[p + 1:m])
        positional, repos = scan(cmd[m + 1:])
    except Ambiguous:
        return "?"
    repos = before_repos + repos
    if before or len(positional) > 1 or len(repos) > 1:
        return "?"
    selector = positional[0] if positional else ""
    repo = repos[0] if repos else ""
    if (selector and not SELECTOR.match(selector)) or (repo and not REPO.match(repo)):
        return "?"
    if not selector and not all(ASSIGN.match(w) or w in TRANSPARENT for w in cmd[:g]):
        return "?"
    return selector + "|" + repo


def merge_call(cmd):
    for g, w in enumerate(cmd):
        if w.rsplit("/", 1)[-1] != "gh" and "$" not in w and NUL not in w:
            continue
        if "pr" not in cmd[g + 1:]:
            continue
        p = cmd.index("pr", g + 1)
        if "merge" not in cmd[p + 1:]:
            continue
        m = cmd.index("merge", p + 1)
        if cmd[m + 1:m + 2] in (["--help"], ["-h"]):
            continue
        return merge_target(cmd, g, p, m)
    return None


def inert(cmd):
    head = cmd[0]
    if NUL in head:
        return False
    if head in TEXT_TOOLS or head.rsplit("/", 1)[-1] == "adk-log.sh":
        return True
    if head == "git":
        k = 1
        while k < len(cmd):
            if cmd[k] == "-C":
                k += 2
            elif cmd[k].startswith("-"):
                return False
            else:
                return cmd[k] in GIT_SUBS
        return False
    if head == "gh":
        return len(cmd) > 1 and cmd[1] in GH_GROUPS
    return False


def verdict(text):
    try:
        cmds = Parser(text).run()
    except Ambiguous:
        return ("call" if in_order(text) else "inert"), []
    calls = [t for t in map(merge_call, cmds) if t is not None]
    mention = any(mentions(c) for c in cmds)
    quiet = all(inert(c) for c in cmds)
    if calls:
        return "call", calls + (["?"] if mention and not quiet else [])
    if not mention:
        return "inert", []
    return ("inert" if quiet else "mention"), []


try:
    kind, targets = verdict(sys.stdin.buffer.read().decode("utf-8", "surrogateescape"))
    print("\n".join([kind] + targets))
except Exception:
    print("call")
PY
  verdict=$(printf '%s' "$1" | python3 -c "$src" 2>/dev/null) || verdict=call
  case "$verdict" in
    *$'\n'*) ADK_PR_MERGE_TARGETS="${verdict#*$'\n'}"; verdict="${verdict%%$'\n'*}" ;;
  esac
  case "$verdict" in
    inert) return 1 ;;
    mention) return 2 ;;
    *) return 0 ;;
  esac
}
