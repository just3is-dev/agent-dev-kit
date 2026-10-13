#!/usr/bin/env bash
# Общие хелперы для bash-guard.sh: разбор Bash-команды на вызовы одним
# лексером на python3 (ADK_INVOCATION_PY, ниже). Две функции поверх него:
# adk_command_invokes_pr_merge — вызывает ли команда `gh pr merge` (issue
# #260, ADR-026, ADR-027) и adk_command_git_bypass — содержит ли она вызов
# `git commit` с --no-verify/-n или `git push` с принудительной записью в
# main/master либо с --no-verify (issue #265, ADR-028). Раньше хук искал
# фразы подстрокой по всему тексту команды: блокировал grep/echo/heredoc/
# git commit -m с упоминанием и пропускал короткие формы флагов.
IFS= read -r -d '' ADK_INVOCATION_PY <<'PY' || true
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


class Redir(str):
    pass


class Glued(str):
    pass


ASCII_DIGITS = re.compile(r"[0-9]+\Z")


PHRASE = (r"gh\b", r"\bpr\b", r"\bmerge\b")


def in_order(text):
    pos = 0
    for pattern in PHRASE:
        m = re.compile(pattern).search(text, pos)
        if m is None:
            return False
        pos = m.end()
    return True


def words(cmd):
    return [w for w in cmd if not isinstance(w, Redir)]


def mentions(cmd):
    return any(in_order(line) for word in cmd for line in word.split("\n"))


class Frame:
    def __init__(self):
        self.cmds = []
        self.cmd = []
        self.chars = None
        self.redir = False

    def add(self, text):
        if self.chars is None:
            self.chars = []
        self.chars.append(text)

    def flush_word(self, glued=False):
        if self.chars is not None:
            word = "".join(self.chars)
            kind = Redir if self.redir else Glued if glued and ASCII_DIGITS.match(word) else str
            self.cmd.append(kind(word))
            self.redir = False
        self.chars = None

    def end_cmd(self):
        self.flush_word()
        self.redir = False
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
            if c in " \t":
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
                if nxt == "&":
                    f.end_cmd()
                    self.i += 2
                elif nxt == ">":
                    self.redirect(f)
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
                f.flush_word(True)
                f.redir = True
                self.i += 3
            elif c == "<" and nxt == "<":
                self.heredoc_op(f)
            elif c in "<>" and nxt == "(":
                self.i += 2
                f.absorb(self.lex(True))
                f.add(NUL)
            elif c in "<>":
                self.redirect(f)
            else:
                f.add(c)
                self.i += 1
        f.end_cmd()
        return f.cmds

    def redirect(self, f):
        s, n = self.s, self.n
        f.flush_word(True)
        if s[self.i] == "&":
            self.i += 1
        op = s[self.i]
        self.i += 1
        nxt = s[self.i] if self.i < n else ""
        if (op == ">" and nxt in (">", "|", "&")) or (op == "<" and nxt in (">", "&")):
            self.i += 1
        f.redir = True

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
        escaped = False
        while True:
            if j >= n:
                raise Ambiguous()
            if s[j] == "\\" and j + 1 < n:
                buf.append(s[j + 1])
                escaped = True
                j += 2
            elif s[j] == "'":
                break
            else:
                buf.append(s[j])
                j += 1
        f.add("".join(buf))
        if escaped:
            f.add(NUL)
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
        f.flush_word(True)
        literal = False
        buf = []
        while self.i < n and s[self.i] not in " \t\n;&|()<>":
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
            cmd.append(Redir(body))
        self.pending = []


VALUE_FLAGS = {"-t", "--subject", "-b", "--body", "-F", "--body-file",
               "--match-head-commit", "-A", "--author-email", "-R", "--repo"}
BOOL_FLAGS = {"--admin", "--auto", "-d", "--delete-branch", "--disable-auto",
              "-m", "--merge", "-r", "--rebase", "-s", "--squash", "-h", "--help"}
REPO_FLAGS = {"-R", "--repo"}
TRANSPARENT = {"env", "command", "sudo", "time"}
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
ODD_CHARS = re.compile(r"[^\S \t\n]|[\x01-\x08\x0e-\x1f\x7f-\x9f]")
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


def scan(args):
    positional, repos, k = [], [], 0
    while k < len(args):
        word = args[k]
        k += 1
        if isinstance(word, Glued):
            if positional:
                continue
            raise Ambiguous()
        if ODD_CHARS.search(word):
            raise Ambiguous()
        if not word.startswith("-") or len(word) < 2:
            positional.append(word)
            continue
        for flag, value in split_flag(word):
            if flag in VALUE_FLAGS:
                if value is None:
                    if k >= len(args):
                        raise Ambiguous()
                    value = args[k]
                    k += 1
                    if isinstance(value, Glued):
                        raise Ambiguous()
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
    cmd = words(cmd)
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
    cmd = words(cmd)
    if not cmd:
        return True
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


GIT_VALUE_GLOBALS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                     "--config-env", "--super-prefix"}
GIT_EQ_GLOBALS = {"--git-dir", "--work-tree", "--namespace", "--config-env",
                  "--super-prefix", "--exec-path"}
GIT_BOOL_GLOBALS = {"-p", "--paginate", "-P", "--no-pager", "--bare",
                    "--no-replace-objects", "--no-lazy-fetch",
                    "--no-optional-locks", "--no-advice", "--literal-pathspecs",
                    "--glob-pathspecs", "--noglob-pathspecs",
                    "--icase-pathspecs"}
SUB_VALUE_SHORT = {"commit": "mFCct", "push": "o"}
SUB_OPTIONAL_SHORT = {"commit": "uS", "push": ""}
SUB_VALUE_LONG = {
    "commit": {"--message", "--file", "--author", "--date", "--reuse-message",
               "--reedit-message", "--fixup", "--squash", "--cleanup",
               "--template", "--trailer", "--pathspec-from-file"},
    "push": {"--repo", "--receive-pack", "--exec", "--push-option",
             "--recurse-submodules"},
}
LONG_NAME = re.compile(r"--[A-Za-z0-9-]+\Z")
MAIN_BRANCHES = {"main", "master"}
ESCAPE = re.compile(r"\\(?:x([0-9A-Fa-f]{1,2})|([0-7]{1,3})|.)", re.S)
GIT_WORD = re.compile(r"(?<![\w.-])git\b")
COMMIT_WORD = re.compile(r"\bcommit\b")
PUSH_WORD = re.compile(r"\bpush\b")
LONG_NO_VERIFY = re.compile(r"(?<![\w-])--no-v")
SHORT_N = re.compile(r"(?<![\w-])-[A-Za-z]*n[A-Za-z]*(?![\w-])")
FORCE_TOKEN = re.compile(r"(?<![\w-])(?:--for|-[A-Za-z]*f[A-Za-z]*(?![\w-]))|(?<![\w+])\+\S")
MIRROR_TOKEN = re.compile(r"(?<![\w-])--mirror")
BRANCH_TOKEN = re.compile(
    r"(?<![\w./-])(?:refs/heads/|heads/)?(?:main|master)(?![\w./-])|(?<![\w-])--(?:all|branches)(?![\w-])|(?:heads/|:)\*")


def dynamic(word):
    return "$" in word or NUL in word


def abbrev(name, full, least):
    return len(name) >= least and full.startswith(name)


def scan_args(sub, args):
    shorts, longs, before, after = set(), set(), [], []
    value_short = SUB_VALUE_SHORT[sub]
    optional_short = SUB_OPTIONAL_SHORT[sub]
    value_long = SUB_VALUE_LONG[sub]
    options_done = False
    k = 0
    while k < len(args):
        word = args[k]
        k += 1
        if options_done:
            after.append(word)
        elif word == "-" or not word.startswith("-"):
            before.append(word)
        elif word == "--":
            options_done = True
        elif word.startswith("--"):
            name, eq, _ = word.partition("=")
            if not LONG_NAME.match(name):
                return None
            longs.add(name[2:])
            if name in value_long and not eq:
                k += 1
        else:
            for j in range(1, len(word)):
                ch = word[j]
                if not ch.isascii() or not ch.isalnum():
                    return None
                if ch in value_short:
                    if j + 1 == len(word):
                        k += 1
                    break
                if ch in optional_short:
                    break
                shorts.add(ch)
    return shorts, longs, before, after


def commit_hits(args):
    scanned = scan_args("commit", args)
    if scanned is None:
        return ["ambiguous"]
    shorts, longs, before, _ = scanned
    if "n" in shorts or any(abbrev(name, "no-verify", 1) for name in longs):
        return ["no-verify"]
    if any(NUL in word or word[:1] in ("$", "{") for word in before):
        return ["ambiguous"]
    return []


def push_hits(args):
    scanned = scan_args("push", args)
    if scanned is None:
        return ["ambiguous"]
    shorts, longs, before, after = scanned
    hits = []
    if any(abbrev(name, "no-verify", 1) for name in longs):
        hits.append("push-no-verify")
    mirror = any(abbrev(name, "mirror", 1) for name in longs)
    force = "f" in shorts or any(abbrev(name, "force-with-lease", 5) for name in longs)
    wide = any(abbrev(name, "all", 1) or abbrev(name, "branches", 1) for name in longs)
    forced = mirror or (force and wide)
    unknown = False
    for ref in before + after:
        if dynamic(ref) or "{" in ref:
            unknown = True
            continue
        plus = ref.startswith("+")
        src, _, dst = ref[1:].partition(":") if plus else ref.partition(":")
        dst = dst or src
        for prefix in ("refs/heads/", "heads/"):
            if dst.startswith(prefix):
                dst = dst[len(prefix):]
        if (force or plus) and (dst in MAIN_BRANCHES or "*" in dst):
            forced = True
    if forced:
        hits.append("force-push")
    if unknown:
        hits.append("ambiguous")
    return hits


def git_calls(cmd):
    cmd = words(cmd)
    hits, commit_seen = [], False
    for g, word in enumerate(cmd):
        if word.rsplit("/", 1)[-1] != "git" and not dynamic(word):
            continue
        k = g + 1
        while k < len(cmd):
            x = cmd[k]
            if isinstance(x, Glued):
                k += 1
            elif x in GIT_VALUE_GLOBALS:
                k += 2
            elif x in GIT_BOOL_GLOBALS or ("=" in x and x.split("=", 1)[0] in GIT_EQ_GLOBALS):
                k += 1
            else:
                break
        sub = cmd[k] if k < len(cmd) else None
        if sub == "commit":
            commit_seen = True
            hits += commit_hits(cmd[k + 1:])
            break
        if sub == "push":
            hits += push_hits(cmd[k + 1:])
            break
    return hits, commit_seen


def git_push_head(cmd):
    cmd = words(cmd)
    k = 1
    while k < len(cmd) and cmd[k] == "-C":
        k += 2
    return k < len(cmd) and cmd[0] == "git" and cmd[k] == "push"


def text_kinds(text):
    text = ESCAPE.sub(lambda m: chr(int(m.group(1), 16)) if m.group(1) else
                      chr(int(m.group(2), 8) & 0xFF) if m.group(2) else " ", text)
    kinds = []
    if GIT_WORD.search(text) is None:
        return kinds
    if COMMIT_WORD.search(text) and (LONG_NO_VERIFY.search(text) or SHORT_N.search(text)):
        kinds.append("no-verify")
    if PUSH_WORD.search(text):
        if LONG_NO_VERIFY.search(text):
            kinds.append("push-no-verify")
        if MIRROR_TOKEN.search(text) or (FORCE_TOKEN.search(text) and BRANCH_TOKEN.search(text)):
            kinds.append("force-push")
    return kinds


def git_verdict(text):
    try:
        cmds = Parser(text).run()
    except Ambiguous:
        if text_kinds(text):
            return "call", ["ambiguous"]
        return "inert", ["commit"] if COMMIT_WORD.search(text) else []
    hits, commit_seen = [], False
    for c in cmds:
        found, seen = git_calls(c)
        hits += found
        commit_seen = commit_seen or seen
    if hits:
        return "call", sorted(set(hits))
    extra = ["commit"] if commit_seen else []
    if all(inert(c) or git_push_head(c) for c in cmds):
        return "inert", extra
    kinds = text_kinds(text)
    return ("mention", kinds) if kinds else ("inert", extra)


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
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if sys.argv[1:] == ["git"]:
        kind, reasons = git_verdict(text)
        print("\n".join([kind] + reasons))
    else:
        kind, targets = verdict(text)
        print("\n".join([kind] + targets))
except Exception:
    print("call\nambiguous" if sys.argv[1:] == ["git"] else "call")
PY

# Вызывает ли Bash-команда `gh pr merge` (issue #260, ADR-026, ADR-027).
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
  local verdict
  verdict=$(printf '%s' "$1" | python3 -c "$ADK_INVOCATION_PY" merge 2>/dev/null) || verdict=call
  case "$verdict" in
    *$'\n'*) ADK_PR_MERGE_TARGETS="${verdict#*$'\n'}"; verdict="${verdict%%$'\n'*}" ;;
  esac
  case "$verdict" in
    inert) return 1 ;;
    mention) return 2 ;;
    *) return 0 ;;
  esac
}

# Вызывает ли команда `git commit` с --no-verify/-n или `git push` с
# принудительной записью в main/master либо с --no-verify (issue #265,
# ADR-028). Тот же лексер, что у merge, но он отдаёт слова простой команды,
# а различитель — флаг внутри вызова. Коды возврата как у
# adk_command_invokes_pr_merge: 0 — вызов обхода или разобрать однозначно не
# удалось (fail-closed), 1 — обхода нет, 2 — упоминание обхода рядом с
# командой вне белого списка (fail-closed).
#
# Глобальная ADK_GIT_FINDINGS — находки, по одной на строку: no-verify
# (git commit --no-verify/-n), force-push (принудительная запись в
# main/master), push-no-verify, ambiguous (флаг, ссылка или подкоманда не
# читаются из слов однозначно) и commit — в команде есть вызов git commit
# (секрет-скан, он нужен и при коде 1). Пусто при быстром выходе; пустое при
# коде 0 (сбой python3) вызывающий трактует как ambiguous.
adk_command_git_bypass() {
  ADK_GIT_FINDINGS=""
  case "$1" in
    *commit*|*push*) ;;
    *) return 1 ;;
  esac
  local verdict
  verdict=$(printf '%s' "$1" | python3 -c "$ADK_INVOCATION_PY" git 2>/dev/null) || verdict=call
  case "$verdict" in
    *$'\n'*) ADK_GIT_FINDINGS="${verdict#*$'\n'}"; verdict="${verdict%%$'\n'*}" ;;
  esac
  case "$verdict" in
    inert) return 1 ;;
    mention) return 2 ;;
    *) return 0 ;;
  esac
}
