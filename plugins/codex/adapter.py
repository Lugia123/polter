#!/usr/bin/env python3
"""The Codex adapter: what a role can pick from, how to start it, and who it is.

The contract is `dev-docs/poltergeist/roles.md` part eleven, and
`plugins/claude-code/adapter.py` is the other side of it that came first.
This file answers the same three questions for OpenAI's Codex CLI:

    adapter.py inventory '{"version":1,"cwd":"/abs"|null,"home":"/abs"}'
        -> {"version":1,"installed":…,"resume":true,"options":[…],"items":[…],"notes":[…]}

    adapter.py launch '{"version":1,"cwd":…,"home":…,"polter":"/abs"|null,
                        "session":"<id>"|null,"role":{…},"cli":{…}}'
        -> {"version":1,"argv":["codex",…],"env":{},"summary":…,"notes":[…],
            "hooks":true?,"hooks_heard":"first_turn"?}

    adapter.py identify '{"version":1,"cwd":…|null,"home":…,"pid":N|null,
                          "env":{<only POLTER_AGENT_CLI, POLTER_REGISTERED>}}'
        -> {"version":1,"me":…,"session":…|null,"session_written_ms":…|null,
            "quit":{…}|null,"notes":[…]}

Everything below that says "measured" was measured on codex-cli 0.163.0 with a
throwaway `CODEX_HOME` and `HOME`, a key that is not one (so every model call
was a 401 and nothing was spent), and a stand-in MCP server that wrote down
its own environment and parent (task 1667).

**How a role is applied: `-c` overrides, never a file.** Codex reads
`-c key=value` (the value parsed as TOML) on top of `config.toml` for one run.
Measured, each against a control run without it, by counting what reached the
model in the session's rollout:

  * a skill: `-c 'skills.config=[{path="<…/SKILL.md>",enabled=false}]'` takes
    it out of the list the model is given, and leaves every other skill in.
    `name=` works as well; `path=` is what is used, because a person's skill
    and a project's may share a name and only the person's is the role's to
    take (`PROJECT_SOURCES`).
  * an MCP server: `-c mcp_servers.<name>.enabled=false` -- the server is not
    started at all.
  * the role's instructions: `-c 'developer_instructions="…"'` reaches the
    model whole, newlines and quotes included. ⚠️ It *replaces* a
    `developer_instructions` the person set in `config.toml` for that run;
    their `AGENTS.md` is untouched. A note says so when they have one.
  * the model: `-m <model>`.

Where Codex looks for skills (measured: a probe skill in each place, all four
reached the model): `$CODEX_HOME/skills`, `~/.agents/skills`, and in the
working directory `.agents/skills` and `.codex/skills`. What Codex ships with
sits in `$CODEX_HOME/skills/.system`.

**Going on with a session.** A session is the UUID at the end of its rollout's
name, `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<local time>-<uuid>.jsonl`,
which is also `session_meta.session_id` on its first line and what Codex
prints as `codex resume <id>` when it exits. `codex resume [SESSION_ID]`
takes every option the bare `codex` takes (read off `--help`), so a resumed
launch is `codex resume <id> <the same options>`. The id is passed on only
when it is UUID-shaped -- anything else is a session *name* to Codex -- and
its rollout is on this machine; otherwise the launch starts a new session and
says why, for the reason the Claude Code adapter gives: `+launch` has become
the CLI by the time it would fail, and nothing is left to report it.

**Who it is (`identify`).** Codex hands a stdio MCP server a fixed short
environment -- HOME, LANG, LOGNAME, PATH, SHELL, TERM, TMPDIR, USER,
__CF_USER_TEXT_ENCODING, measured -- plus the server entry's own `env` and the
names its `env_vars` lets through. **Nothing in it says Codex, and nothing
names the session** (the binary knows `CODEX_THREAD_ID`; it does not give it
to MCP servers). So:

  * `me` is the marker the provision puts into the polter entry's `env`
    (`POLTER_AGENT_CLI=codex`), or -- for an entry written before the marker
    existed -- the sidecar's parent being a program called `codex`. Measured:
    that parent is the native Codex binary, under exec and the TUI alike (not
    the app-server daemon, and not the `node` wrapper npm installs).
  * `session` is first the rollout that process holds open (`lsof`, or
    `/proc`), when that process is the Codex TUI itself and holds exactly
    one. Measured: a Codex running its session in-process keeps its rollout
    open; one that has not had its first turn has none yet. **Not when the
    process is the app-server daemon** (`is_daemon`): signed in to a ChatGPT
    account the TUI runs its session there ("Disconnected from this task.
    Any running work continues." on exit), the daemon is the parent of
    Polter's server, and what it has open is every attached session's --
    measured, a take-over went on with another terminal's conversation that
    way. Otherwise the records are read (`by_directory`): this terminal's
    directory, and the session that started when this Codex's Polter server
    did (the sidecar says its own pid). Exactly one, or no session: a wrong
    one is worse than a new one.
  * `quit` is `/exit` (measured, task 1640: the agent leaves within seconds),
    typed only when one of the last rows is Codex's input line with nothing
    in it but its placeholder, and nothing on the screen says a turn is
    running or an approval is waiting.

Three things it does not do, each checkable by reading:

  * **It never writes a file.**
  * **It never reads a value out of an `env` table**: a server is described by
    its transport and its command's file name or URL host.
  * **It never runs `codex`.** Asking Codex would start every MCP server it
    has. Everything comes from the files it keeps.

The request is the second argument (stdin when it is absent, for trying it by
hand). One JSON object on stdout; a reason on stderr and a non-zero exit when
there is no answer.
"""

import json
import os
import re
import subprocess
import sys
import time

CONTRACT_VERSION = 1

# A launch the role's own words contradict (task 2679). Answered the way
# every other refusal here is: the reason on stderr, a non-zero exit, and no
# `argv` at all -- so nothing half-built is ever run. `+launch` prints it as
# "Codex could not build the command: …".
class Refused(Exception):
    pass

# The server Polter registers for itself. A role that took it away would be
# a terminal that cannot report back, which looks exactly like a dead one.
POLTER_SERVER = "polter"

# What the provision puts into the polter entry's `env` so that the sidecar
# can say which CLI started it (plugins/codex/provision.sh).
AGENT_MARKER = "POLTER_AGENT_CLI"

MAX_BYTES = 4 * 1024 * 1024

# What Codex calls a session when it is not a name.
SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
ROLLOUT = re.compile(r"^rollout-.*-(" + SESSION_ID.pattern + r")\.jsonl$")

# A server name Codex accepts, and so one a `-c mcp_servers.<name>…` path can
# carry without quoting.
SERVER_NAME = re.compile(r"^[A-Za-z0-9_-]+$")

# Arguments with which a role has already said which session it wants.
SESSION_WORDS = ("resume", "fork", "--last")

# What belongs to the directory a role is started in rather than to the
# person. **A role never switches these off**: a role is written in the
# settings window, which has no directory, so they can never be in its
# `except`, and a role whose default is off would take every one of them away
# in every project. The same rule as the Claude Code adapter.
PROJECT_SOURCES = ("project",)


def read_text(path, limit=256 * 1024):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


def codex_home(home):
    """`$CODEX_HOME`, else `<home>/.codex` -- the rule Codex itself follows."""
    value = os.environ.get("CODEX_HOME")
    if value:
        return value
    return os.path.join(home, ".codex")


# --- skills ------------------------------------------------------------------


def frontmatter(text):
    """`name` and `description` from a SKILL.md's frontmatter.

    The same reading as the Claude Code adapter's: one-line scalars, quoted
    or not, and folded or literal blocks. Anything else is an empty string.
    """
    if not text or not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    lines = text[3:end].split("\n")
    out = {}
    i = 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", lines[i])
        i += 1
        if not m:
            continue
        key, value = m.group(1), m.group(2).strip()
        if value in (">", "|", ">-", "|-", ">+", "|+"):
            block = []
            while i < len(lines) and (lines[i].startswith(" ") or lines[i].strip() == ""):
                block.append(lines[i].strip())
                i += 1
            joiner = "\n" if value.startswith("|") else " "
            value = joiner.join(b for b in block).strip()
        elif len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out[key] = value
    return out


def skills_in(directory, source):
    """Every `<directory>/<skill>/SKILL.md`, as items that still carry their
    file (`_path`, taken off before anything is printed)."""
    items = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return items
    for entry in names:
        if entry.startswith("."):
            continue
        path = os.path.join(directory, entry, "SKILL.md")
        text = read_text(path)
        if text is None:
            continue
        fm = frontmatter(text)
        name = fm.get("name") or entry
        items.append({
            "kind": "skill",
            "id": "skill:" + name,
            "name": name,
            "description": fm.get("description", ""),
            "source": source,
            "_path": path,
        })
    return items


# --- config.toml -------------------------------------------------------------


def toml_string(value):
    """`value` as a TOML basic string.

    JSON's escapes are TOML's, with two exceptions this takes care of: DEL
    must be escaped in TOML and JSON leaves it, and JSON writes a character
    outside the BMP as a surrogate pair, which TOML forbids -- so non-ASCII
    is written as itself (`ensure_ascii=False`).
    """
    return json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")


def toml_scalar(text):
    """The value of a `key = value` line: a string, a boolean, or None.

    Only what is asked of it -- `command`, `url`, `enabled`,
    `developer_instructions` -- and only in the forms Codex itself writes.
    Arrays, inline tables and multi-line strings are None: the caller does
    not need them.
    """
    text = text.strip()
    if text.startswith('"""') or text.startswith("'''"):
        return None
    if text.startswith('"'):
        m = re.match(r'^"((?:[^"\\]|\\.)*)"', text)
        if not m:
            return None
        try:
            return json.loads('"' + m.group(1) + '"')
        except ValueError:
            return m.group(1)
    if text.startswith("'"):
        end = text.find("'", 1)
        return text[1:end] if end > 0 else None
    word = re.match(r"^([A-Za-z]+)", text)
    if word and word.group(1) in ("true", "false"):
        return word.group(1) == "true"
    return None


def header_path(inner):
    """`mcp_servers."a b"` -> ["mcp_servers", "a b"], or None."""
    parts = []
    rest = inner.strip()
    while rest:
        if rest[0] == '"':
            m = re.match(r'^"((?:[^"\\]|\\.)*)"', rest)
            if not m:
                return None
            parts.append(m.group(1))
            rest = rest[m.end():]
        elif rest[0] == "'":
            end = rest.find("'", 1)
            if end < 0:
                return None
            parts.append(rest[1:end])
            rest = rest[end + 1:]
        else:
            m = re.match(r"^[A-Za-z0-9_-]+", rest)
            if not m:
                return None
            parts.append(m.group(0))
            rest = rest[m.end():]
        rest = rest.lstrip()
        if rest.startswith("."):
            rest = rest[1:].lstrip()
        elif rest:
            return None
    return parts


def read_config(path, notes, label):
    """What this adapter needs from a `config.toml`.

    `{"servers": {name: {"command"?, "url"?, "enabled"?}}, "top": {key: value}}`.
    Not a TOML parser: table headers, and `key = <string|bool>` lines under
    them. A line it cannot read is skipped; a header it cannot read is said in
    a note, because a server under it would otherwise be missing without a
    word. Python before 3.11 has no `tomllib`, and the Mac's own python3 is
    3.9, so this cannot lean on one.
    """
    out = {"servers": {}, "top": {}}
    try:
        if os.path.getsize(path) > MAX_BYTES:
            notes.append("Could not read %s: too large to read" % label)
            return out
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except FileNotFoundError:
        return out
    except OSError as e:
        notes.append("Could not read %s: %s" % (label, e))
        return out

    table = []
    unread = 0
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[["):
            table = None
            continue
        if line.startswith("["):
            close = line.rfind("]")
            parts = header_path(line[1:close]) if close > 0 else None
            if parts is None:
                unread += 1
                table = None
            else:
                table = parts
            continue
        if table is None:
            continue
        m = re.match(r'^((?:[A-Za-z0-9_-]+|"[^"]*")(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"))*)\s*=\s*(.*)$', line)
        if not m:
            continue
        # A dotted key is a table path of its own: `mcp_servers.x.command`
        # on the root table is the same server as `[mcp_servers.x]`.
        path = table + (header_path(m.group(1)) or [])
        value = toml_scalar(m.group(2))
        if len(path) == 1:
            out["top"][path[0]] = value
        elif len(path) == 3 and path[0] == "mcp_servers" and path[2] in ("command", "url", "enabled"):
            out["servers"].setdefault(path[1], {})[path[2]] = value
        elif len(path) >= 2 and path[0] == "mcp_servers":
            out["servers"].setdefault(path[1], {})
    if unread:
        notes.append("%s: %d table header(s) could not be read and were skipped." % (label, unread))
    return out


def describe_server(spec):
    """How a server is reached, with nothing secret in it."""
    url = spec.get("url")
    if isinstance(url, str) and url:
        m = re.match(r"^[a-z]+://([^/?#]+)", url)
        host = m.group(1) if m else url
        return "http · %s" % host.split("@")[-1]
    command = spec.get("command")
    if isinstance(command, str) and command:
        return "stdio · %s" % os.path.basename(command)
    return ""


def servers_from(config, source):
    items = []
    for name in sorted(config["servers"]):
        spec = config["servers"][name]
        # Switched off in the person's own config: already out of every
        # session, nothing for a role to decide.
        if spec.get("enabled") is False:
            continue
        items.append({
            "kind": "mcp",
            "id": "mcp:" + name,
            "name": name,
            "description": "",
            "detail": describe_server(spec),
            "source": source,
            "locked": name == POLTER_SERVER,
        })
    return items


# --- the three questions -----------------------------------------------------


def on_path(binary):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(d, binary)
        if d and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # The login shell's PATH is not always this process's. These are where
    # npm and Homebrew put it.
    for candidate in ("/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"):
        full = os.path.expanduser(candidate)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


def gather(req):
    """Every item, still carrying `_path` on skills, and the notes."""
    home = req.get("home") or os.path.expanduser("~")
    cwd = req.get("cwd") or None
    chome = codex_home(home)
    notes = []
    items = []

    items += skills_in(os.path.join(chome, "skills"), "user")
    items += skills_in(os.path.join(home, ".agents", "skills"), "user")
    items += skills_in(os.path.join(chome, "skills", ".system"), "codex")
    if cwd:
        items += skills_in(os.path.join(cwd, ".agents", "skills"), "project")
        items += skills_in(os.path.join(cwd, ".codex", "skills"), "project")

    config = read_config(os.path.join(chome, "config.toml"), notes, "config.toml")
    items += servers_from(config, "user")
    if cwd:
        project = read_config(os.path.join(cwd, ".codex", "config.toml"), notes, ".codex/config.toml")
        items += servers_from(project, "project")
    return items, notes, config


def public(item):
    return {k: v for k, v in item.items() if not k.startswith("_")}


def inventory(req):
    items, notes, _ = gather(req)

    # One id is one switch: a person's skill and a project's of the same name
    # are one row, and the project's takes it (it is the one a launch leaves
    # alone, `PROJECT_SOURCES`).
    at = {}
    unique = []
    for item in items:
        i = at.get(item["id"])
        if i is None:
            at[item["id"]] = len(unique)
            unique.append(item)
        elif item["source"] in PROJECT_SOURCES and unique[i]["source"] not in PROJECT_SOURCES:
            unique[i] = item

    notes.append("Codex plugins and apps are not listed: a role cannot switch them off from the command line.")
    return {
        "version": CONTRACT_VERSION,
        "installed": on_path("codex") is not None,
        "resume": True,
        "options": launch_options(codex_help()),
        "items": [public(i) for i in unique],
        "notes": notes,
    }


BINARY = "codex"
# (key, label, flag): the remaining value-taking option, measured on 0.163.
# `approval` is not here any more -- it is one drop-down with more than one
# kind of answer, built in `launch_options` (task 2679).
OPTION_FLAGS = [
    ("sandbox", "Sandbox", "--sandbox"),
]

# **One question, four answers** (task 2679). `--approve-for-me`,
# `--dangerously-bypass-approvals-and-sandbox` and `--ask-for-approval <x>`
# are all answers to "who approves what", and they are all offered by the
# one `approval` drop-down, so a person sees one answer at a time rather
# than three controls that can disagree. The two value-less flags come
# first, Polter's own default at the top; the `--ask-for-approval` values
# are what a role written before 0.166 picked, and they stay offered and
# stay shown, so such a role reads back as what it is instead of as the
# default it never chose.
#
# Measured on codex-cli 0.166.0, each flag against a control run: shown by
# its own `--help`, and taken by `codex` and `codex resume <id>` alike.
APPROVAL_FLAGS = [
    ("approve-for-me", "--approve-for-me"),
    ("bypass", "--dangerously-bypass-approvals-and-sandbox"),
]
# Polter's default, and only where this Codex's `--help` lists it: a role
# that picked nothing gets it, and a Codex without the flag offers no
# default at all, so it runs exactly as it did.
DEFAULT_APPROVAL = "approve-for-me"
# The two `--ask-for-approval` policies, where a sandbox is the person's to
# pick. The two flags above each bring their own sandbox and are measured
# to: `--approve-for-me` is the workspace-write sandbox, the bypass runs
# with none. So a sandbox picked beside either is not applied -- said in a
# note, never dropped in silence (task 2679).
MANUAL_APPROVALS = ("on-request", "never")

# Launch options (task 1677): the unattended settings a role picks per CLI,
# as a drop-down rather than as words typed into "extra arguments". Only the
# values **this** CLI's own `--help` lists are offered, so a value an older or
# newer version does not take is never one to pick; a help that could not be
# read offers none, and says so. The role's `cli.options` is
# `{"<key>": "<value>"}`; `apply_options` turns it into flags.
HELP_TIMEOUT = 10


def help_text(binary):
    """`<binary> --help`, or None. Reads a usage text; starts no session."""
    exe = on_path(binary) or binary
    try:
        p = subprocess.run([exe, "--help"], capture_output=True, text=True,
                           timeout=HELP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 and p.stdout else None


_HELP = []


def codex_help():
    """`help_text(BINARY)`, read once per request: a launch asks it twice
    (the options and `--no-daemon`), and on Windows each read starts node."""
    if not _HELP:
        _HELP.append(help_text(BINARY))
    return _HELP[0]


def takes_flag(text, flag):
    """Whether `--help` lists `flag` as an option of its own."""
    return re.search(r"^\s*(-\w, )?%s\b" % re.escape(flag), text or "", re.M) is not None


def flag_values(text, flag):
    """The values `--help` lists for `flag`, in its order; [] when it lists none.

    Three shapes, all measured: Claude Code 2.1.302 writes
    `(choices: "a", "b", …)` across lines; Codex 0.163 writes
    `[possible values: a, b]` for `--sandbox` and a `- value: …` list for
    `--ask-for-approval`."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"\s*(-\w, )?%s\b" % re.escape(flag), line):
            start = i
            break
    if start is None:
        return []
    block = [lines[start]]
    for line in lines[start + 1:]:
        if re.match(r"\s*-{1,2}[A-Za-z]", line) and not re.match(r"\s*- [\w-]+:", line):
            break
        block.append(line)
    joined = " ".join(block)
    m = re.search(r"choices:\s*((?:\"[^\"]+\"\s*,?\s*)+)", joined)
    if m:
        return re.findall(r"\"([^\"]+)\"", m.group(1))
    m = re.search(r"\[possible values:\s*([^\]]+)\]", joined)
    if m:
        return [v.strip() for v in m.group(1).split(",") if v.strip()]
    return [m.group(1) for m in (re.match(r"\s*- ([\w-]+):", l) for l in block) if m]


def flag_aliases(text, flag):
    """The short spellings `--help` gives `flag` (`-s, --sandbox`): the same
    flag to the CLI, so the same flag to `apply_options`."""
    for line in text.splitlines():
        m = re.match(r"\s*((?:-\w, )+)%s\b" % re.escape(flag), line)
        if m:
            return [a.strip() for a in m.group(1).split(",") if a.strip()]
    return []


def launch_options(text):
    """The `options` an inventory offers, from a `--help` text.

    `approval` is one drop-down with three kinds of answer in it (task
    2679): the two value-less flags, in `APPROVAL_FLAGS`' order, then the
    values `--ask-for-approval` lists, in its order. Each value carries the
    arguments that give it, which is what lets one option offer answers
    whose argv shapes differ. `sandbox` is unchanged: only the sandbox a
    person picks by hand.
    """
    text = text or ""
    out = []
    values = []
    for value, flag in APPROVAL_FLAGS:
        if takes_flag(text, flag):
            values.append({"value": value, "args": [flag]})
    for v in flag_values(text, "--ask-for-approval"):
        values.append({"value": v, "args": ["--ask-for-approval", v]})
    if values:
        entry = {"key": "approval", "label": "Approval", "flag": "--ask-for-approval",
                 "aliases": flag_aliases(text, "--ask-for-approval"), "values": values}
        # Polter's own default, and only where this Codex takes it: a role
        # that picked nothing gets it, and a Codex without the flag offers
        # no default at all (`apply_options` reads `default` this way).
        if takes_flag(text, APPROVAL_FLAGS[0][1]):
            entry["default"] = DEFAULT_APPROVAL
        out.append(entry)
    for key, label, flag in OPTION_FLAGS:
        vals = flag_values(text, flag)
        if vals:
            out.append({"key": key, "label": label, "flag": flag,
                        "aliases": flag_aliases(text, flag),
                        "values": [{"value": v, "args": [flag, v]} for v in vals]})
    return out


def approval_answer(extra):
    """What the role's own extra arguments say about approvals, as
    `(flags, policy, sandbox)`.

    `flags` are the value-less ones it gives: `approve-for-me`, `bypass`.
    `policy` is whether it gives `--ask-for-approval`/`-a`, `sandbox`
    whether it gives `--sandbox`/`-s` -- long and short, bare and `=value`.
    """
    flags = [value for value, flag in APPROVAL_FLAGS if flag in extra]
    policy = any(_gives(a, "--ask-for-approval", "-a") for a in extra)
    sandbox = any(_gives(a, "--sandbox", "-s") for a in extra)
    return flags, policy, sandbox


def _gives(a, flag, short):
    return (a == flag or a.startswith(flag + "=")
            or a == short or a.startswith(short + "="))


def approval_clash(extra):
    """Why these extra arguments cannot all be honoured (task 2679), or None.

    `--approve-for-me`, `--dangerously-bypass-approvals-and-sandbox`,
    `--ask-for-approval` and `--sandbox` are four answers to one question --
    who approves what, in which sandbox -- and Codex documents no precedence
    between them. **Measured on 0.166.0**: `--approve-for-me
    --dangerously-bypass-approvals-and-sandbox`, and `--approve-for-me -s
    read-only`, are each *accepted* (exit 0), so which of them wins is not
    something to read off a run. Choosing one would be choosing a privilege
    level for the person -- `bypass` is the one this Codex's own help calls
    EXTREMELY DANGEROUS -- so a launch that says two different things in the
    same place is refused, with what to remove, rather than resolved.
    """
    flags, policy, sandbox = approval_answer(extra)
    if len(flags) > 1:
        return ("The extra arguments give %s and %s; they cannot both be how "
                "approvals are handled. Keep the one you want."
                % (flag_for(flags[0]), flag_for(flags[1])))
    if flags and policy:
        return ("The extra arguments give %s and --ask-for-approval; they cannot both "
                "be how approvals are handled. Keep the one you want." % flag_for(flags[0]))
    if flags and sandbox:
        return ("The extra arguments give %s and --sandbox; %s brings its own sandbox. "
                "Keep the one you want." % (flag_for(flags[0]), flag_for(flags[0])))
    return None


def flag_for(value):
    """The flag one of `APPROVAL_FLAGS`' values is, or the value itself."""
    for v, flag in APPROVAL_FLAGS:
        if v == value:
            return flag
    return value


def apply_options(cli, extra, notes):
    """The flags the role's `cli.options` stand for, in the order they go on
    the command line.

    **`approval` is one answer at a time** (task 2679), decided in this
    order -- and exactly one of these happens:

      * the extra arguments say anything about approvals or sandboxes: the
        role's words on the command line win. Nothing is added, and a picked
        value is left out with a note -- **so the drop-down and the command
        line never say different things without the note saying so**;
      * else the role picked one: its own flag goes on. A legacy role's
        `on-request` / `never` is a value like any other, so such a role
        reads back and runs as what it is written as, instead of being shown
        as the default it never chose;
      * else Polter's default, `--approve-for-me` -- automatic review in the
        workspace-write sandbox, which is what an unattended role wants. A
        Codex whose `--help` does not list it gets nothing, with a note, so
        an older Codex runs exactly as it did.

    **A sandbox takes effect only beside a manual policy.** Measured:
    `--approve-for-me` is the workspace-write sandbox and the bypass runs
    with none, so a sandbox that was picked is left out -- with a note, never
    dropped in silence -- when the answer above is one of those two. That is
    the one place the drop-down shows something the run does not use, and the
    note is what says it.
    """
    picked = cli.get("options")
    if not isinstance(picked, dict):
        picked = {}
    offered = {o["key"]: o for o in launch_options(codex_help())}
    args = []

    extra_flags, extra_policy, extra_sandbox = approval_answer(extra)
    picked_approval = picked.get("approval")
    approval = offered.get("approval")

    # 1. What answers "who approves what", and where that answer comes from.
    # **Polter's default is a last resort, not a first word**: the role's own
    # words -- a pick, or the extra arguments -- keep exactly what they say.
    # A role that picked a sandbox and no approval is such a case: adding
    # `--approve-for-me` on top would bring the workspace-write sandbox and
    # take that sandbox away, so the default is withheld and the note says
    # so. (The window says the same thing under the two drop-downs.)
    said_by_extra = flag_for(extra_flags[0]) if extra_flags else (
        "--ask-for-approval" if extra_policy else ("--sandbox" if extra_sandbox else None))
    source = None
    effective = None
    if said_by_extra is not None:
        source, effective = "extra", extra_flags[0] if extra_flags else None
    elif picked_approval is not None:
        source, effective = "role", picked_approval
    elif "sandbox" in picked:
        source = "sandbox"
    else:
        source = "default"
        effective = approval.get("default") if approval else None
        if effective is None:
            notes.append("No approval setting was added: this Codex does not take "
                         "--approve-for-me (its --help does not list it).")
            source = None

    # 2. The flag for it, from wherever the answer came.
    if source in ("role", "default"):
        hit = next((v for v in (approval or {}).get("values", []) if v["value"] == effective), None)
        if hit is None:
            notes.append('Launch option approval="%s" is not a value this version takes; left out.'
                         % effective)
            source, effective = None, None
        else:
            args += list(hit["args"])
    elif source == "extra":
        if picked_approval is not None:
            notes.append('Launch option "approval" left out: the extra arguments already give %s.'
                         % said_by_extra)
        elif said_by_extra != flag_for(DEFAULT_APPROVAL):
            # No default was added because the role's own arguments decide.
            # Said, so that a drop-down's answer and the command line are not
            # two different things in silence.
            notes.append("No approval setting was added: the role's own %s decides."
                         % said_by_extra)
    elif source == "sandbox":
        notes.append("No approval setting was added: the role picked a sandbox, and "
                     "--approve-for-me would bring its own.")

    for key, value in picked.items():
        if key == "approval":
            continue
        o = offered.get(key)
        if o is None:
            notes.append('Launch option "%s" is not one this version offers; left out.' % key)
            continue
        if key == "sandbox" and effective is not None and effective not in MANUAL_APPROVALS:
            notes.append('Launch option "sandbox" left out: %s brings its own sandbox.'
                         % flag_for(effective))
            continue
        if gives_flag(extra, [o["flag"]] + o["aliases"]):
            notes.append('Launch option "%s" left out: the extra arguments already give %s.' % (key, o["flag"]))
            continue
        hit = next((v for v in o["values"] if v["value"] == value), None)
        if hit is None:
            notes.append('Launch option %s="%s" is not a value this version takes; left out.' % (key, value))
            continue
        args += hit["args"]
    return args


def gives_flag(extra, spellings):
    """Whether the extra arguments already give one of `spellings`, alone or
    as `--flag=value` (a short one as `-s=value` too, which clap takes)."""
    for a in extra:
        for f in spellings:
            if a == f or a.startswith(f + "="):
                return True
    return False


def enabled(selection, item_id):
    """Whether a role leaves this item on: its default, flipped by `except`."""
    default = selection.get("default", True) is not False
    return default != (item_id in (selection.get("except") or []))


def rollout_of(chome, session):
    """The rollout file of `session` on this machine, or None."""
    root = os.path.join(chome, "sessions")
    suffix = "-" + session + ".jsonl"
    for dirpath, _, files in os.walk(root):
        for name in files:
            if name.startswith("rollout-") and name.endswith(suffix):
                return os.path.join(dirpath, name)
    return None


def session_to_resume(req, extra, notes):
    session = req.get("session")
    if session is None:
        return None
    if any(a in SESSION_WORDS for a in extra):
        notes.append("The role's own arguments choose a session; session %s was left out." % session)
        return None
    if not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        notes.append("%s is not a Codex session id; starting a new session." % session)
        return None
    home = req.get("home") or os.path.expanduser("~")
    if rollout_of(codex_home(home), session) is None:
        notes.append("Session %s is not on this machine any more; starting a new session." % session)
        return None
    return session


def hook_args(req, notes):
    """The `-c` arguments that wire Codex's hooks to Polter, or [] with a
    note saying why there are none.

    They are `plugins/codex/hooks.py`'s (task 1668), not this file's: which
    events, and how a hook is trusted, belong with the code that reads what
    they send. Anything wrong on that side -- no such file yet, an exception,
    an answer that is not a list of strings -- is no hooks at all, never some.
    """
    polter = req.get("polter")
    if not isinstance(polter, str) or not polter:
        notes.append("No Polter path in the request, so no hooks.")
        return []
    # No `__pycache__` written into the plugin's own directory: it is part of
    # what ships, and inside an app bundle it is not this script's to write.
    sys.dont_write_bytecode = True
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import hooks  # noqa: E402 -- beside this file, task 1668
    except Exception:
        return []
    finally:
        sys.path.pop(0)
    try:
        args = hooks.hook_args(polter, windows=os.name == "nt")
    except Exception as e:
        notes.append("Hooks were left out: %s" % e)
        return []
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        notes.append("Hooks were left out: hooks.py did not answer a list of strings.")
        return []
    return args


def launch(req):
    role = req.get("role") or {}
    cli = req.get("cli") or {}
    items, notes, config = gather(req)
    notes.append("Codex plugins and apps are not listed: a role cannot switch them off from the command line.")

    project_ids = {i["id"] for i in items if i["source"] in PROJECT_SOURCES}
    off_paths = []
    off_servers = []
    off = {"skill": 0, "mcp": 0}
    counted = set()
    for item in items:
        if item.get("locked") or item["source"] in PROJECT_SOURCES:
            continue
        selection = cli.get("skills" if item["kind"] == "skill" else "mcp") or {}
        if enabled(selection, item["id"]):
            continue
        if item["kind"] == "skill":
            # The person's skill of the same name as the project's: in this
            # directory the project's is the one the id stands for.
            if item["id"] in project_ids:
                continue
            off_paths.append(item["_path"])
        else:
            if not SERVER_NAME.match(item["name"]):
                notes.append('MCP server "%s" has a name a -c path cannot carry; it was left on.' % item["name"])
                continue
            off_servers.append(item["name"])
        if item["id"] not in counted:
            counted.add(item["id"])
            off[item["kind"]] += 1

    extra = [a for a in (cli.get("args") or []) if isinstance(a, str)]

    # Two answers to "who approves what" in the role's own words are refused
    # before anything is built (task 2679): see `approval_clash`.
    clash = approval_clash(extra)
    if clash is not None:
        raise Refused(clash)

    opts = []
    if off_paths:
        entries = ",".join("{path=%s,enabled=false}" % toml_string(p) for p in off_paths)
        opts += ["-c", "skills.config=[%s]" % entries]
    for name in off_servers:
        opts += ["-c", "mcp_servers.%s.enabled=false" % name]
    model = cli.get("model") or role.get("model")
    if model:
        opts += ["-m", model]
    instructions = role.get("instructions")
    if instructions:
        if isinstance(config["top"].get("developer_instructions"), str):
            notes.append("The role's instructions stand in for the developer_instructions in config.toml for this session.")
        opts += ["-c", "developer_instructions=" + toml_string(instructions)]
    hooks = hook_args(req, notes)
    opts += hooks
    opts += apply_options(cli, extra, notes)

    session = session_to_resume(req, extra, notes)
    # **Always in its own process** (task 1667). Codex 0.163 signed in to a
    # ChatGPT account otherwise runs the session in the shared app-server
    # daemon, and then everything Polter relies on belongs to the daemon:
    # the hooks run with the daemon's environment (so a hook from one
    # terminal can name another), the MCP server outlives the TUI, and the
    # session record is not the TUI's to hold. Today a `-c` on the command
    # line happens to keep it out of the daemon (`config_exclusion`, read by
    # task 1668); `--no-daemon` says it outright, so a later Codex that
    # changes that rule does not quietly change this. Accepted by `codex` and
    # `codex resume` alike (0.163, checked against an unknown flag).
    #
    # **Only when this Codex's `--help` lists it** (task 1712). It came in
    # with the daemon; 0.154 has neither, refuses the flag as an unexpected
    # argument and exits, and a role -- a resume too -- never started.
    # Left out when the help could not be read as well: a flag that kills
    # the launch is the worse guess than a session that may share a daemon.
    daemon = []
    text = codex_help()
    if takes_flag(text, "--no-daemon"):
        daemon = ["--no-daemon"]
    elif text is None:
        notes.append("Could not read codex --help, so --no-daemon was left out; signed in to a ChatGPT account, this session may run in Codex's shared background server.")
    else:
        notes.append("This Codex does not take --no-daemon (its --help does not list it), so it was left out.")
    argv = ["codex"] + (["resume", session] if session else []) + daemon + opts + extra

    answer = {
        "version": CONTRACT_VERSION,
        "argv": argv,
        "env": {},
        "summary": "%d skill(s) and %d MCP server(s) switched off" % (off["skill"], off["mcp"]),
        "notes": notes,
    }
    if hooks:
        answer["hooks"] = True
        # Codex says SessionStart with the first turn, not when it starts
        # (task 1668), so silence before then is not a missing hook.
        answer["hooks_heard"] = "first_turn"
    return answer


# Codex at rest draws its input line as `› ` and a placeholder, one of these
# two sentences (both in the 0.163.0 binary, side by side); with text in it
# the line is that text, and no quit is typed over it. A turn adds a row
# `• Working (7s • esc to interrupt)`; an MCP approval is `Allow the polter
# MCP server to run tool "me"?` over a `› 1. Allow` menu and a row ending
# `enter to submit | esc to cancel`. Read off real Codex screens in the test
# session (tasks 1640 and 1656); nothing here is guessed.
QUIT = {
    "text": "/exit",
    "ready": {
        "line": ["\u203a Ask Codex to do anything", "\u203a Ask a follow-up question", "\u203a"],
        "none_of": ["esc to interrupt", "esc to cancel", "Allow the ",
                    "\u203a 1.", "\u203a 2.", "\u203a 3.", "\u203a 4."],
    },
}


def exe_of(pid):
    """The executable of process `pid`, or None."""
    link = "/proc/%d/exe" % pid
    if os.path.exists("/proc/%d" % pid):
        try:
            return os.readlink(link)
        except OSError:
            return None
    try:
        out = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True,
                             text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    value = out.stdout.strip()
    return value or None


def open_files(pid):
    """The paths process `pid` has open, or None when that cannot be read."""
    fd_dir = "/proc/%d/fd" % pid
    if os.path.isdir(fd_dir):
        paths = []
        try:
            for fd in os.listdir(fd_dir):
                try:
                    paths.append(os.readlink(os.path.join(fd_dir, fd)))
                except OSError:
                    pass
        except OSError:
            return None
        return paths
    try:
        out = subprocess.run(["lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return [line[1:] for line in out.stdout.split("\n") if line.startswith("n")]


def is_codex(path):
    name = os.path.basename(path or "").lower()
    return name in ("codex", "codex.exe")


# How far back a session record is looked for by directory, and how close
# a session's start has to be to the start of this Codex's Polter server to
# be taken as this Codex's.
BY_DIRECTORY_DAYS = 1
STARTED_TOGETHER_MS = 30 * 1000


def session_meta(path):
    """`(cwd, started_ms)` from a rollout's first line; either may be None."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            first = f.readline(MAX_BYTES)
        meta = json.loads(first)
    except (OSError, ValueError):
        return None, None
    payload = meta.get("payload") if isinstance(meta, dict) else None
    if not isinstance(payload, dict):
        return None, None
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    return cwd, iso_ms(payload.get("timestamp"))


def iso_ms(value):
    """`2026-10-16T19:37:54.058Z` as Unix milliseconds, or None."""
    if not isinstance(value, str):
        return None
    m = re.match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?Z$", value)
    if not m:
        return None
    import calendar
    secs = calendar.timegm(tuple(int(m.group(i)) for i in range(1, 7)) + (0, 0, 0))
    frac = (m.group(7) or "0")[:3].ljust(3, "0")
    return secs * 1000 + int(frac)


def uuid_ms(session):
    """The milliseconds a UUIDv7 carries in its first 48 bits, or None.
    Codex's session ids are v7 (`01a14638-8e88-7…`)."""
    hexpart = session.replace("-", "")
    if len(hexpart) != 32 or hexpart[12] != "7":
        return None
    return int(hexpart[:12], 16)


def same_dir(a, b):
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except (OSError, ValueError):
        return a == b


def written_ms(path):
    # Nanoseconds, floored to milliseconds: the same number .NET gives from
    # the same file (adapter.ps1), where a float times 1000 can be one off.
    try:
        return os.stat(path).st_mtime_ns // 1000000
    except OSError:
        return None


def started_ms(pid, now_ms):
    """When process `pid` started, Unix milliseconds to the second, or None."""
    try:
        out = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$", out)
    if not m:
        return None
    days, hours, mins, secs = (int(g) if g else 0 for g in m.groups())
    return now_ms - ((days * 24 + hours) * 3600 + mins * 60 + secs) * 1000


def command_of(pid):
    """The command line of process `pid`, or ''."""
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        pass
    try:
        return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def is_daemon(pid):
    """Whether `pid` is Codex's shared app-server daemon, which runs the
    sessions of every TUI that attaches to it."""
    return " app-server" in " " + command_of(pid)


def by_directory(chome, cwd, sidecar_started, now_ms):
    """`(session, written_ms, note)` for this terminal's session, found in
    the records by directory and by when it started -- or no session.

    **Why this is needed** (task 1667). Signed in to a ChatGPT account, the
    Codex TUI runs its session in the shared app-server daemon: Polter's MCP
    server is the daemon's child, and the daemon holds every session it
    runs. So the records are read: those written in the last day whose
    `session_meta.cwd` is this terminal's directory.

    **Wrong is worse than none.** Measured in the test session: two Codex in
    one directory, and a take-over went on with the other one's
    conversation. One directory is not enough to tell sessions apart, so
    the session is also matched by **when it started**: a Codex session
    starts Polter's MCP server as it starts, so the record whose
    `session_meta.timestamp` is within `STARTED_TOGETHER_MS` of when this
    sidecar started is this one. Exactly one such record, or no session. A
    session gone on with by hand (`codex resume`) started long before its
    sidecar and is not named -- a new session, which the take-over says.

    **Without a time for the sidecar, none** (task 1749). This used to name
    the one record when a directory had exactly one -- and before this
    session's own record exists (Codex writes it with the first turn), the
    one record there is another Codex's, which a take-over would have gone
    on with. Polter sends the sidecar's pid on every system now, so this is
    a sidecar that could not be timed, not a platform.
    """
    root = os.path.join(chome, "sessions")
    cutoff = now_ms - BY_DIRECTORY_DAYS * 24 * 3600 * 1000
    found = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            m = ROLLOUT.match(name)
            if not m:
                continue
            path = os.path.join(dirpath, name)
            w = written_ms(path)
            if w is None or w < cutoff:
                continue
            c, started = session_meta(path)
            if c is not None and same_dir(c, cwd):
                found.append((w, m.group(1), started if started is not None else uuid_ms(m.group(1))))
    if not found:
        return None, None, "No Codex session record in this directory was written in the last day."
    if sidecar_started is None:
        return None, None, ("%d Codex session record(s) in this directory and no start of this Codex's "
                            "Polter server to match one to, so none is named." % len(found))
    near = [f for f in found if f[2] is not None and abs(f[2] - sidecar_started) <= STARTED_TOGETHER_MS]
    if len(near) == 1:
        return near[0][1], near[0][0], ("Named by directory and start: the Codex session here that "
                                        "started when this Codex started Polter's server.")
    if not near:
        return None, None, ("No Codex session in this directory started when this Codex started "
                            "Polter's server (it may be going on with an older one), so none is named.")
    return None, None, ("%d Codex sessions in this directory started within %ds of this one, so which "
                        "is this one is not known." % (len(near), STARTED_TOGETHER_MS // 1000))


def identify(req):
    env = req.get("env") if isinstance(req.get("env"), dict) else {}
    pid = req.get("pid") if isinstance(req.get("pid"), int) and req.get("pid") > 0 else None
    sidecar = req.get("sidecar_pid") if isinstance(req.get("sidecar_pid"), int) and req.get("sidecar_pid") > 0 else None
    cwd = req.get("cwd") if isinstance(req.get("cwd"), str) and req.get("cwd") else None
    home = req.get("home") or os.path.expanduser("~")
    notes = []

    marked = env.get(AGENT_MARKER) == "codex"
    parent = exe_of(pid) if pid else None
    me = marked or is_codex(parent)
    if not me:
        return {"version": 1, "me": False, "session": None, "session_written_ms": None,
                "quit": None, "notes": []}

    session = None
    written = None
    if pid is None:
        notes.append("No process to look at.")
    elif not is_codex(parent):
        notes.append("The program that started Polter's server is not Codex itself.")
    elif is_daemon(pid):
        # What the daemon has open is every attached session's, not this
        # one's: measured, a take-over named another terminal's session.
        notes.append("Codex runs this session in its app-server daemon.")
    else:
        files = open_files(pid)
        found = []
        for path in files or []:
            m = ROLLOUT.match(os.path.basename(path))
            if m:
                found.append((path, m.group(1)))
        if files is None:
            notes.append("Could not read which files Codex has open.")
        elif not found:
            notes.append("Codex has no session record open.")
        elif len(found) > 1:
            notes.append("Codex has %d session records open, so which is this one is not known." % len(found))
        else:
            written, session = written_ms(found[0][0]), found[0][1]
    if session is None:
        if cwd is None:
            notes.append("No directory to look for its session in, so it is not known.")
        else:
            now_ms = int(time.time() * 1000)
            sidecar_started = started_ms(sidecar, now_ms) if sidecar else None
            session, written, note = by_directory(codex_home(home), cwd, sidecar_started, now_ms)
            notes.append(note)
    return {"version": 1, "me": True, "session": session, "session_written_ms": written,
            "quit": QUIT, "notes": notes}


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in ("inventory", "launch", "identify"):
        sys.stderr.write("usage: adapter.py inventory|launch|identify '<request json>'\n")
        return 2
    raw = sys.argv[2] if len(sys.argv) == 3 else sys.stdin.read()
    try:
        req = json.loads(raw) if raw.strip() else {}
    except ValueError as e:
        sys.stderr.write("the request is not JSON: %s\n" % e)
        return 2
    if not isinstance(req, dict):
        sys.stderr.write("the request is not a JSON object\n")
        return 2
    try:
        answer = {"inventory": inventory, "launch": launch, "identify": identify}[sys.argv[1]](req)
    except Refused as e:
        sys.stderr.write("%s\n" % e)
        return 1
    sys.stdout.write(json.dumps(answer, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
