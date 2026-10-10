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
adk_command_invokes_pr_merge() {
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
LOG_SCRIPT = "adk-log.sh"
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


def invokes_merge(cmd):
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
        return True
    return False


def inert(cmd):
    head = cmd[0]
    if NUL in head:
        return False
    if head in TEXT_TOOLS or head.rsplit("/", 1)[-1] == LOG_SCRIPT:
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
        return "call" if in_order(text) else "inert"
    if any(invokes_merge(c) for c in cmds):
        return "call"
    if not any(mentions(c) for c in cmds):
        return "inert"
    return "inert" if all(inert(c) for c in cmds) else "mention"


try:
    result = verdict(sys.stdin.buffer.read().decode("utf-8", "surrogateescape"))
except Exception:
    result = "call"
print(result)
PY
  verdict=$(printf '%s' "$1" | python3 -c "$src" 2>/dev/null) || verdict=call
  case "$verdict" in
    inert) return 1 ;;
    mention) return 2 ;;
    *) return 0 ;;
  esac
}
