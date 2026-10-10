#!/usr/bin/env bash
# Общий хелпер для bash-guard.sh: вызывает ли Bash-команда `gh pr merge`
# (issue #260, ADR-026). Раньше хук искал фразу подстрокой по всему тексту
# команды и блокировал grep/echo/heredoc/git commit -m с её упоминанием.
#
# Использование:
#   if adk_command_invokes_pr_merge "$cmd"; then ...
#
# Код возврата 0 — команда вызывает merge или разобрать её однозначно не
# удалось (fail-closed); 1 — вызова нет. Правила — в ADR-026.
adk_command_invokes_pr_merge() {
  case "$1" in
    *merge*) ;;
    *) return 1 ;;
  esac
  local src verdict
  IFS= read -r -d '' src <<'PY' || true
import re
import sys

SIMPLE = {"grep", "egrep", "fgrep", "rg", "echo", "printf", "cat", "head",
          "tail", "wc", "sort", "uniq", "cut", "tr", "tee", "nl", "adk-log.sh"}
GIT_SUBS = {"commit", "tag", "log", "show", "notes", "diff", "grep", "status",
            "add", "stash", "branch"}
GH_GROUPS = {"pr", "issue", "api"}
RUNNERS = {"bash", "sh", "zsh", "dash", "ksh", "source", ".", "eval", "exec"}
KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "{"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
NUL = "\x00"


class Ambiguous(Exception):
    pass


def in_order(text, words):
    pos = 0
    for w in words:
        m = re.compile(r"\b" + re.escape(w) + r"\b").search(text, pos)
        if m is None:
            return False
        pos = m.end()
    return True


def mentions_merge(text):
    return any(in_order(line, ("gh", "pr", "merge")) for line in text.split("\n"))


class Frame:
    def __init__(self):
        self.units = [[]]
        self.cmd = []
        self.chars = None
        self.quoted = False

    def add(self, text, quoted=False):
        if self.chars is None:
            self.chars = []
        self.chars.append(text)
        if quoted:
            self.quoted = True

    def flush_word(self):
        if self.chars is not None:
            self.cmd.append(("".join(self.chars), self.quoted))
        self.chars = None
        self.quoted = False

    def end_cmd(self):
        self.flush_word()
        if self.cmd:
            self.units[-1].append(self.cmd)
            self.cmd = []

    def end_unit(self):
        self.end_cmd()
        if self.units[-1]:
            self.units.append([])

    def absorb(self, units):
        for u in units:
            self.units[-1].extend(u)


class Parser:
    def __init__(self, s):
        self.s = s
        self.n = len(s)
        self.i = 0
        self.pending = []

    def run(self):
        units = self.lex(False)
        if self.pending:
            raise Ambiguous()
        return units

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
                f.end_unit()
                self.i += 1
                self.read_heredocs()
            elif c == "#" and f.chars is None:
                while self.i < n and s[self.i] != "\n":
                    self.i += 1
            elif c == ";":
                f.end_unit()
                self.i += 1
            elif c == "|":
                if nxt == "|":
                    f.end_unit()
                    self.i += 2
                else:
                    f.end_cmd()
                    self.i += 2 if nxt == "&" else 1
            elif c == "&":
                prev = s[self.i - 1] if self.i else ""
                if nxt == "&":
                    f.end_unit()
                    self.i += 2
                elif prev in ("<", ">") or nxt == ">":
                    f.add(c)
                    self.i += 1
                else:
                    f.end_unit()
                    self.i += 1
            elif c == "(":
                self.i += 1
                f.absorb(self.lex(True))
            elif c == ")":
                f.end_unit()
                self.i += 1
                if nested:
                    return f.units
            elif c == "\\":
                if nxt == "\n":
                    self.i += 2
                elif nxt == "":
                    f.add("\\")
                    self.i += 1
                else:
                    f.add(nxt, True)
                    self.i += 2
            elif c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    raise Ambiguous()
                f.add(s[self.i + 1:j], True)
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
                    f.add(NUL, True)
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
                f.add(NUL, True)
            else:
                f.add(c)
                self.i += 1
        f.end_unit()
        return f.units

    def dquote(self, f):
        s, n = self.s, self.n
        f.add("", True)
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
                    f.add(nx if nx in '$`"\\' else "\\" + nx, True)
                self.i += 2
            elif c == "$" and s.startswith("$(", self.i):
                self.i += 2
                f.absorb(self.lex(True))
                f.add(NUL, True)
            elif c == "`":
                self.backtick(f)
            else:
                f.add(c, True)
                self.i += 1

    def backtick(self, f):
        s, n = self.s, self.n
        j = self.i + 1
        while j < n and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        if j >= n:
            raise Ambiguous()
        inner = Parser(s[self.i + 1:j].replace("\\`", "`"))
        f.absorb(inner.run())
        f.add(NUL, True)
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
        f.add("".join(buf), True)
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
            cmd.append((body, True))
        self.pending = []


def command_words(cmd):
    i = 0
    while i < len(cmd):
        text, quoted = cmd[i]
        if (not quoted and text in KEYWORDS) or ASSIGN.match(text):
            i += 1
        else:
            break
    return cmd[i:]


def inert_head(words):
    if not words or NUL in words[0][0]:
        return False
    name = words[0][0].rsplit("/", 1)[-1]
    if name in SIMPLE:
        return True
    if name == "git":
        k = 1
        while k < len(words):
            t = words[k][0]
            if t == "-C":
                k += 2
            elif t.startswith("-"):
                return False
            else:
                return t in GIT_SUBS
        return False
    if name == "gh":
        return len(words) > 1 and words[1][0] in GH_GROUPS
    return False


def invokes_merge(cmd):
    texts = [t for t, _ in cmd]
    for g, t in enumerate(texts):
        if t.rsplit("/", 1)[-1] != "gh" and "$" not in t and NUL not in t:
            continue
        if "pr" not in texts[g + 1:]:
            continue
        p = texts.index("pr", g + 1)
        if "merge" not in texts[p + 1:]:
            continue
        m = texts.index("merge", p + 1)
        rest = cmd[m + 1:m + 2]
        if rest and rest[0][0] in ("--help", "-h") and not rest[0][1]:
            continue
        return True
    return False


def mentions(cmd):
    return any(mentions_merge(t) for t, _ in cmd)


def head_name(cmd):
    words = command_words(cmd)
    return words[0][0].rsplit("/", 1)[-1] if words else ""


def unit_calls(unit):
    mention = False
    inert = True
    for cmd in unit:
        if invokes_merge(cmd):
            return True
        if mentions(cmd):
            mention = True
        if not inert_head(command_words(cmd)):
            inert = False
    return mention and not inert


def verdict(text):
    try:
        units = Parser(text).run()
    except Ambiguous:
        return in_order(text, ("gh", "pr", "merge"))
    if any(unit_calls(u) for u in units):
        return True
    cmds = [c for u in units for c in u]
    return any(mentions(c) for c in cmds) and any(head_name(c) in RUNNERS for c in cmds)


try:
    call = verdict(sys.argv[1])
except Exception:
    call = True
print("call" if call else "inert")
PY
  verdict=$(python3 -c "$src" "$1" 2>/dev/null) || verdict=call
  [ "$verdict" != inert ]
}
