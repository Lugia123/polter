#!/usr/bin/env python3
"""The opencode adapter: what a role can pick from, how to start it, and who it is.

The contract is `dev-docs/poltergeist/roles.md` part eleven; the Claude Code,
Codex and Antigravity adapters are the other sides of it. This file answers
the same three questions for opencode (task 1777):

    adapter.py inventory '{"version":1,"cwd":"/abs"|null,"home":"/abs"}'
        -> {"version":1,"installed":…,"resume":true,"options":[],"items":[…],"notes":[…]}

    adapter.py launch '{"version":1,"cwd":…,"home":…,"polter":"/abs"|null,
                        "session":"<id>"|null,"role":{…},"cli":{…}}'
        -> {"version":1,"argv":["opencode",…],"env":{…},"summary":…,"notes":[…],
            "hooks":true?,"hooks_heard":"first_turn"?}

    adapter.py identify '{"version":1,"cwd":…|null,"home":…,"pid":N|null,
                          "env":{<only POLTER_AGENT_CLI, POLTER_REGISTERED>}}'
        -> {"version":1,"me":…,"session":…|null,"session_written_ms":…|null,
            "quit":null,"notes":[…]}

Read off opencode 2.0.32's source (`packages/` at v2.0.32) and measured
against that build in a scratch `HOME` (task 1806; 1.x was task 1777); the
measurements are in `test/opencode-adapter/`.

**A server of its own: `--standalone`.** By default opencode 2.0's TUI is a
client of one background service per person (`opencode serve --service`),
started by whichever TUI came first and left running after it, with *that*
TUI's environment (`state/opencode/service.json`). Measured: a second TUI
started with a different `OPENCODE_CONFIG_CONTENT` attached to the first
one's service and got none of its own -- so one terminal's role switches and
hooks would be another's, and a service the person started outside Polter
has none. `--standalone` starts a private `opencode serve --stdio` under the
TUI, with this launch's environment, which ends with it. A role whose own
arguments name a `--server` keeps it, with a note.

**How a role is applied: one environment variable, never a file.**
opencode reads `OPENCODE_CONFIG_CONTENT` -- a whole configuration, inline --
in its server process, as one layer above the person's and the project's
files (`core/src/config.ts`; only managed settings rank above it), for that
process only. So everything a role says goes into that one object:

  * **Polter's hooks**: `"plugin": ["file:///…/polter-hooks"]`, the plugin
    directory beside this file, and `POLTER_HOOK_EXE` naming the Polter it
    runs. A directory: a configured plugin path that is a file is dropped
    ("configured plugin path must be a directory", measured). The path has
    to be a `file://` URL: an inline config has no file for a relative path
    to be relative to. Measured: a path with a space in it, written as
    `%20`, loads.
  * **A skill switched off**: `"permission": {"skill": {"<name>": "deny"}}`.
    A denied skill is taken out of the list the model is given
    (`core/src/skill.ts`), not merely refused when called (measured).
  * **An MCP server switched off**: `"permission": {"<server>_*": "deny"}`.
    A tool denied for every resource is taken out of what the model is told
    it can call (`core/src/tool.ts`; measured, against the same server left
    on); the server itself still starts.
  * **Polter's own tools are never asked about**: `"polter_*": "allow"`,
    which outlasts a person's `"*": "ask"`.
  * **The role's model**: `"model": "<provider>/<model>"`. 2.0's TUI has no
    `-m`: given one, it prints its help and exits (measured).

The old `permission` shape is 2.0's still: it turns it into its own rules
(`core/src/config/normalize.ts`).

And outside it: `OPENCODE_DISABLE_AUTOUPDATE=1`. Left to itself opencode
upgrades itself in the background when it starts (`cli/src/services/
updater.ts`), and a role launch is not the moment for the binary to change
under it.

**The role's instructions go in as the first prompt** (`--prompt`, which
the TUI types and submits when it opens on a new session --
`routes/home.tsx`). opencode has no flag for a system prompt, and its
`instructions` take only files. Not on a session that is gone on with: that
conversation already has them.

**Going on with a session.** A session is `ses_…`, a row of `session_v2` in
`~/.local/share/opencode/opencode.db` (SQLite; `session` before 2.0, whose
rows 2.0 copies over); `-s <id>` opens it. The id is passed on only when it
is shaped like one and its row is on this machine; otherwise the launch
starts a new session and says why. **Never blindly**: 2.0's `-s` makes a
session of an id it does not know rather than failing, so an id from
somewhere else would be a new, empty session under an old name.

**Who it is (`identify`).** opencode hands a local MCP server its whole
environment with the entry's `environment` on top, so `me` is the marker
the provision writes there (`POLTER_AGENT_CLI=opencode`) or, for an entry
written before it, the sidecar's parent being a program called `opencode`
-- in 2.0 the private server (`opencode serve --stdio`), itself the TUI's
child and started with it. `session` is read from the database: this directory's
session that began after this opencode did, when there is exactly one. A
running opencode says its session id nowhere else -- no environment, no
file, no port unless asked for one -- and Polter's hooks say it anyway.
No `quit`: no screen of opencode's has been read to say when `/exit` is
safe to type.

Three things it does not do, each checkable by reading:

  * **It never writes a file.**
  * **It never reads a value out of an `environment` table**: a server is
    described by its type and its command's file name or URL host.
  * **It never starts a session of `opencode`**, which would start every MCP
    server it has. It runs `opencode --version`, which starts none and no
    service, with the models fetch off (`version_of` says why).

The request is the second argument (stdin when it is absent, for trying it by
hand). One JSON object on stdout; a reason on stderr and a non-zero exit when
there is no answer.
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.parse

CONTRACT_VERSION = 1

# The server Polter registers for itself. A role that took it away would be
# a terminal that cannot report back, which looks exactly like a dead one.
POLTER_SERVER = "polter"

# What the provision puts into the polter entry's `environment` so that the
# sidecar can say which CLI started it (plugins/opencode/provision.sh).
AGENT_MARKER = "POLTER_AGENT_CLI"
ME = "opencode"

# Polter's opencode plugin, a directory beside this file, and the file in it
# opencode loads.
HOOKS_DIR = "polter-hooks"
HOOKS_ENTRY = "index.js"

# The first build everything here was read off and measured on. Older, or
# a version that cannot be read: no hooks, and a note -- the rule the Claude
# Code adapter follows (adapters.md 3.1). 1.x loads no plugin of 2.0's shape
# and says none of its events (task 1806).
MIN_VERSION = (2, 0, 0)

MAX_BYTES = 4 * 1024 * 1024
VERSION_TIMEOUT = 10

# What belongs to the directory a role is started in rather than to the
# person. **A role never switches these off**: the same rule as the other
# adapters.
PROJECT_SOURCES = ("project",)

# What opencode calls a session.
SESSION_ID = re.compile(r"^ses_[A-Za-z0-9]+$")
# The role's own arguments that already choose a session.
SESSION_WORDS = ("-s", "--session", "-c", "--continue")
# And a server: a role that names one keeps it, and is not made standalone.
SERVER_WORDS = ("--server", "--standalone")
# And a first prompt.
PROMPT_WORDS = ("--prompt",)

# How far apart this opencode's start and its session's may be and still be
# taken for one another (`identify`). A session is made with the first
# message, which may come long after the start; it is never before it.
STARTED_SLACK_MS = 5 * 1000


def read_text(path, limit=256 * 1024):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


def config_home(home):
    """`~/.config/opencode`: opencode takes it from `xdg-basedir`, which is
    `$XDG_CONFIG_HOME` when that is set. The adapter is handed Polter's
    environment, not the terminal's, so the default is what it can know."""
    return os.path.join(home, ".config", "opencode")


def data_home(home):
    return os.path.join(home, ".local", "share", "opencode")


# --- skills ------------------------------------------------------------------


def frontmatter(text):
    """`name` and `description` from a SKILL.md's frontmatter: one-line
    scalars, quoted or not, and folded or literal blocks -- the same reading
    as the other adapters'."""
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
    """Every `<directory>/**/SKILL.md`, as items. opencode looks at any depth
    (`skills/**/SKILL.md`) and needs both `name` and `description`; a
    SKILL.md without them it skips, and so does this."""
    items = []
    if not os.path.isdir(directory):
        return items
    for dirpath, dirnames, files in os.walk(directory, followlinks=True):
        dirnames.sort()
        if "SKILL.md" not in files:
            continue
        fm = frontmatter(read_text(os.path.join(dirpath, "SKILL.md")))
        name, description = fm.get("name"), fm.get("description")
        if not name or not description:
            continue
        items.append({
            "kind": "skill",
            "id": "skill:" + name,
            "name": name,
            "description": description,
            "source": source,
        })
    return items


def skill_dirs(home, cwd):
    """Where opencode 2.0 looks, in the order it looks -- a later one of the
    same name wins: the person's `.claude` and `.agents`, the project's
    (`core/src/config/plugin/compatibility.ts`), then opencode's own
    configuration directories (`core/src/config/plugin/skill.ts`)."""
    out = [(os.path.join(home, ".claude", "skills"), "user"),
           (os.path.join(home, ".agents", "skills"), "user")]
    if cwd:
        out += [(os.path.join(cwd, ".claude", "skills"), "project"),
                (os.path.join(cwd, ".agents", "skills"), "project")]
    for sub in ("skill", "skills"):
        out.append((os.path.join(config_home(home), sub), "user"))
    if cwd:
        for sub in ("skill", "skills"):
            out.append((os.path.join(cwd, ".opencode", sub), "project"))
    return out


# --- opencode.json -----------------------------------------------------------


def read_json(path, notes, label):
    """The object in `path`, `{}` when there is none, and a note when there is
    one that cannot be read -- a server under it would otherwise be missing
    without a word."""
    try:
        if os.path.getsize(path) > MAX_BYTES:
            notes.append("Could not read %s: too large to read" % label)
            return {}
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    except OSError as e:
        notes.append("Could not read %s: %s" % (label, e))
        return {}
    if not text.strip():
        return {}
    try:
        value = json.loads(text)
    except ValueError as e:
        notes.append("Could not read %s: %s" % (label, e))
        return {}
    if not isinstance(value, dict):
        notes.append("Could not read %s: not a JSON object" % label)
        return {}
    return value


def describe_server(spec):
    """How a server is reached, with nothing secret in it."""
    url = spec.get("url")
    if spec.get("type") == "remote" and isinstance(url, str) and url:
        m = re.match(r"^[a-z]+://([^/?#]+)", url)
        host = m.group(1) if m else url
        return "http · %s" % host.split("@")[-1]
    command = spec.get("command")
    if isinstance(command, list) and command and isinstance(command[0], str):
        return "stdio · %s" % os.path.basename(command[0])
    return ""


def servers_from(config, source):
    items = []
    servers = config.get("mcp")
    if not isinstance(servers, dict):
        return items
    for name in sorted(servers):
        spec = servers[name]
        if not isinstance(spec, dict):
            continue
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


def config_files(home, cwd):
    """The configuration files that name MCP servers, the person's and then
    the project's (`core/src/config/discovery.ts`: `opencode.json` and
    `opencode.jsonc`; 2.0 reads no `config.json`). ⚠️ `.jsonc` is not read
    here: a file with comments in it would need a JSONC reader, and a guess
    at one is a server listed wrongly."""
    out = [(os.path.join(config_home(home), "opencode.json"), "user", "opencode.json")]
    if cwd:
        out.append((os.path.join(cwd, "opencode.json"), "project", "opencode.json (project)"))
    return out


# --- the three questions -----------------------------------------------------


def on_path(binary):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(d, binary)
        if d and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # The login shell's PATH is not always this process's. Homebrew's and the
    # install script's (`~/.opencode/bin`) places. Only for `opencode`.
    if binary != "opencode":
        return None
    for candidate in ("/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "~/.opencode/bin/opencode"):
        full = os.path.expanduser(candidate)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


def gather(req):
    home = req.get("home") or os.path.expanduser("~")
    cwd = req.get("cwd") or None
    notes = []
    items = []
    for directory, source in skill_dirs(home, cwd):
        items += skills_in(directory, source)
    for path, source, label in config_files(home, cwd):
        items += servers_from(read_json(path, notes, label), source)
    for jsonc in (os.path.join(config_home(home), "opencode.jsonc"),
                  os.path.join(cwd, "opencode.jsonc") if cwd else None):
        if jsonc and os.path.isfile(jsonc):
            notes.append("%s is not read: its MCP servers are not listed, and a role cannot switch them off." % jsonc)
    return items, notes


def unique_items(items):
    """One id is one switch. A later skill of the same name wins, as in
    opencode; the project's row of a server takes it, as in the others."""
    at = {}
    out = []
    for item in items:
        i = at.get(item["id"])
        if i is None:
            at[item["id"]] = len(out)
            out.append(item)
        elif item["kind"] == "skill" or (item["source"] in PROJECT_SOURCES
                                          and out[i]["source"] not in PROJECT_SOURCES):
            out[i] = item
    return out


def serves_here(exe, version):
    """Whether the opencode on this machine is one this plugin starts.

    **This plugin serves 1.x, and only 1.x** (task 2237). 2.x has a plugin of
    its own (`plugins/opencode-v2`), and on a machine running it this one
    answers `"serves": false` so that the control room says "the other major
    version is installed" rather than "not installed" -- two different things
    for the person to do about them, and neither of them a switch.

    No exe, no version to judge, and `installed` has already said the true
    thing; a version that could not be read is *not knowing* rather than
    knowing it is wrong, and is served.
    """
    if exe is None or version is None:
        return True
    return version < MIN_VERSION


def inventory(req):
    items, notes = gather(req)
    # ⚠️ **This runs `opencode --version`**, which the inventory did not use
    # to. That is the price of `serves`: whether the program on PATH is one
    # this plugin starts is not readable off the file system. It is the call
    # `launch` already makes -- models fetch and autoupdate off, no session
    # and no service started (`version_of`) -- and it is asked whatever the
    # version turns out to be, because this one has to say *no* as well as
    # yes. See `plugins/opencode-v2/adapter.py`, which reads the same field.
    exe = on_path("opencode")
    version = version_of(exe) if exe else None
    serves = serves_here(exe, version)
    if exe is not None and not serves:
        notes.append(
            "opencode %s is on this machine, and this plugin starts 1.x only. "
            "The plugin for the version that is here is the one that serves it."
            % ".".join(map(str, version)))
    return {
        "version": CONTRACT_VERSION,
        "installed": exe is not None,
        "serves": serves,
        "resume": True,
        "options": [],
        "items": unique_items(items),
        "notes": notes,
    }


def enabled(selection, item_id):
    """Whether a role leaves this item on: its default, flipped by `except`."""
    default = selection.get("default", True) is not False
    return default != (item_id in (selection.get("except") or []))


def tool_prefix(server):
    """The prefix opencode gives an MCP server's tools: the name with every
    character but letters, digits, `_` and `-` made `_`, and `_`
    (`mcp/index.ts`, `sanitizedClientName`)."""
    return re.sub(r"[^a-zA-Z0-9_-]", "_", server) + "_"


def version_of(exe):
    """`opencode --version` as a tuple, or None."""
    # **Not as harmless as it reads** (task 1781, measured on 1.2.10 against
    # a proxy that wrote down every connection): `opencode --version` loaded
    # the models list from models.dev before it answered, which the fetch
    # off stops. On 2.0 (task 1806, measured in a scratch `HOME`) it starts
    # no service and loads no plugin, but it makes opencode's directories
    # and adds a "cli starting" line to `log/opencode.log` each time, fetch
    # off or not -- it is run once a launch, not in a loop. It prints
    # `opencode v2.0.32`; 1.x printed the bare number. (`opencode session
    # list` runs the person's plugins, so nothing here runs it.)
    env = dict(os.environ, OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1")
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True, env=env,
                           stdin=subprocess.DEVNULL, timeout=VERSION_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", p.stdout or "")
    return tuple(int(g) for g in m.groups()) if p.returncode == 0 and m else None


def hooks_dir():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), HOOKS_DIR)


def hooks_ready(polter, version, notes):
    """Whether this launch can have Polter's hooks: a Polter to run, the
    plugin beside this file, and an opencode they were measured on."""
    if not isinstance(polter, str) or not polter:
        notes.append("No Polter path in the request, so opencode is started without Polter's hooks.")
        return False
    if not os.path.isfile(os.path.join(hooks_dir(), HOOKS_ENTRY)):
        notes.append("Polter's opencode plugin (%s) is missing, so opencode is started without its hooks." % HOOKS_DIR)
        return False
    if version is None:
        notes.append("Could not read opencode's version, so it is started without Polter's hooks.")
        return False
    if version < MIN_VERSION:
        notes.append("opencode %s is older than %s, the first Polter's hooks were measured on; started without them."
                     % (".".join(map(str, version)), ".".join(map(str, MIN_VERSION))))
        return False
    return True


# opencode's table of sessions, by the version that made the database:
# 2.0's first, then 1.x's (which 2.0 copies into its own on first start, so
# a database with both has the same sessions in each). The columns read
# here -- id, directory, parent_id, time_created, time_updated -- are the
# same in both.
SESSION_TABLES = ("session_v2", "session")


def session_rows(home, sql, args):
    """Rows from opencode's database, read-only, or None when it cannot be
    read. `sql` names its table `{t}`, which is the first of
    `SESSION_TABLES` the database has. Never written: `mode=ro`, and
    opencode's own write-ahead log is left to opencode."""
    path = os.path.join(data_home(home), "opencode.db")
    if not os.path.isfile(path):
        return None
    try:
        uri = "file:%s?mode=ro" % urllib.parse.quote(path)
        con = sqlite3.connect(uri, uri=True, timeout=2)
        try:
            have = {r[0] for r in con.execute("select name from sqlite_master where type = 'table'")}
            table = next((t for t in SESSION_TABLES if t in have), None)
            if table is None:
                return None
            return con.execute(sql.format(t=table), args).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return None


def session_to_resume(req, extra, notes):
    """The session to go on with, or None with a note saying why not."""
    session = req.get("session")
    if session is None:
        return None
    if any(a in SESSION_WORDS or a.startswith("--session=") for a in extra):
        notes.append("The role's own arguments choose a session; session %s was left out." % session)
        return None
    if not isinstance(session, str) or not SESSION_ID.match(session):
        notes.append("%s is not an opencode session id; starting a new one." % session)
        return None
    home = req.get("home") or os.path.expanduser("~")
    rows = session_rows(home, "select id from {t} where id = ?", (session,))
    if rows is None:
        notes.append("opencode's sessions could not be read; starting a new session instead of %s." % session)
        return None
    if not rows:
        notes.append("Session %s is not on this machine any more; starting a new one." % session)
        return None
    return session


def launch(req):
    role = req.get("role") or {}
    cli = req.get("cli") or {}
    notes = []
    items, gather_notes = gather(req)
    notes += gather_notes

    # What the role switches off. A person's skill of the same name as the
    # project's is the project's in this directory, and a role never
    # switches that off.
    project_ids = {i["id"] for i in items if i["source"] in PROJECT_SOURCES}
    permission = {"%s*" % tool_prefix(POLTER_SERVER): "allow"}
    skills_off = {}
    servers_off = 0
    seen = set()
    for item in unique_items(items):
        if item.get("locked") or item["id"] in project_ids or item["id"] in seen:
            continue
        seen.add(item["id"])
        selection = cli.get("skills" if item["kind"] == "skill" else "mcp") or {}
        if enabled(selection, item["id"]):
            continue
        if item["kind"] == "skill":
            skills_off[item["name"]] = "deny"
        else:
            permission["%s*" % tool_prefix(item["name"])] = "deny"
            servers_off += 1
    if skills_off:
        permission["skill"] = skills_off

    exe = on_path("opencode")
    version = version_of(exe) if exe else None
    # 1.x has neither `--standalone` nor a service to keep away from, and
    # takes its model as `-m`; 2.0 has no `-m`. **Each refuses the other's
    # flag outright**: 1.x's arguments are `yargs(...).strict()`
    # (`src/index.ts` at v1.2.10), and 2.0 given `-m` prints its help and
    # exits (measured) -- either way nothing starts. So a version that
    # cannot be read gets neither flag, and its model goes in the
    # configuration, which both read (task 1806).
    v2 = version is not None and version >= MIN_VERSION
    v1 = version is not None and not v2

    extra = [a for a in (cli.get("args") or []) if isinstance(a, str)]
    opts = []
    if v2 and any(a in SERVER_WORDS or a.startswith("--server=") for a in extra):
        notes.append("The role's own arguments choose opencode's server; it is not started --standalone, "
                     "so a shared server's configuration and hooks are that server's.")
    elif v2:
        opts.append("--standalone")
    elif version is None:
        notes.append("opencode's version could not be read, so it is started without --standalone, which 1.x "
                     "refuses: on 2.0 it then shares the background service, and that server's configuration.")
    model = cli.get("model") or role.get("model")
    if model and v1:
        opts += ["-m", model]
    session = session_to_resume(req, extra, notes)
    if session:
        opts += ["-s", session]

    instructions = role.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        if session:
            notes.append("Going on with a session: the role's instructions are already in it, so they are not sent again.")
        elif any(a in PROMPT_WORDS or a.startswith("--prompt=") for a in extra):
            notes.append("The role's own arguments give a first prompt; the role's instructions are not sent.")
        else:
            opts += ["--prompt", instructions]

    hooks = hooks_ready(req.get("polter"), version, notes)

    content = {"$schema": "https://opencode.ai/config.json", "permission": permission}
    if model and not v1:
        content["model"] = model
    env = {"OPENCODE_DISABLE_AUTOUPDATE": "1"}
    if hooks:
        content["plugin"] = ["file://" + urllib.parse.quote(hooks_dir())]
        env["POLTER_HOOK_EXE"] = req["polter"]
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps(content, ensure_ascii=False, separators=(",", ":"))

    answer = {
        "version": CONTRACT_VERSION,
        "argv": ["opencode"] + opts + extra,
        "env": env,
        "summary": "nothing switched off" if not (skills_off or servers_off)
        else "%d skill(s) and %d MCP server(s) switched off" % (len(skills_off), servers_off),
        "notes": notes,
    }
    if hooks:
        answer["hooks"] = True
        # A session is made with its first message, and so is the first
        # event about it (`session.created`): an opencode nobody has typed
        # into says nothing, however long it sits (measured).
        answer["hooks_heard"] = "first_turn"
    return answer


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


def is_opencode(path):
    name = os.path.basename(path or "").lower()
    return name in ("opencode", "opencode.exe")


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


def by_directory(home, cwd, since_ms):
    """`(session, updated_ms, note)`: this directory's one top-level session
    begun since this opencode started, or no session. **Wrong is worse than
    none**: two in one directory since then, and none is named."""
    rows = session_rows(home,
                        "select id, time_updated from {t} where directory = ? and parent_id is null "
                        "and time_created >= ? order by time_created", (cwd, since_ms - STARTED_SLACK_MS))
    if rows is None:
        return None, None, "opencode's sessions could not be read."
    if not rows:
        return None, None, ("No opencode session in this directory began after this opencode started "
                            "(a session is made with its first message, or this one goes on with an older one).")
    if len(rows) > 1:
        return None, None, ("%d opencode sessions in this directory began after this opencode started, "
                            "so which is this one is not known." % len(rows))
    return rows[0][0], rows[0][1], "Named by directory and start."


def identify(req):
    env = req.get("env") if isinstance(req.get("env"), dict) else {}
    pid = req.get("pid") if isinstance(req.get("pid"), int) and req.get("pid") > 0 else None
    cwd = req.get("cwd") if isinstance(req.get("cwd"), str) and req.get("cwd") else None
    home = req.get("home") or os.path.expanduser("~")

    # The marker first: a marker that names another CLI is a no, whatever
    # the parent is called.
    marker = env.get(AGENT_MARKER)
    me = marker == ME if marker is not None else bool(pid) and is_opencode(exe_of(pid))
    if not me:
        return {"version": 1, "me": False, "session": None, "session_written_ms": None,
                "quit": None, "notes": []}

    # When this opencode started: its own process when Polter names it, else
    # the Polter server it started (`sidecar_pid`), which is all Windows has
    # (task 1781). The server starts with opencode or with its first message
    # -- either way not after the session it serves, give or take
    # `STARTED_SLACK_MS`.
    sidecar = req.get("sidecar_pid") if isinstance(req.get("sidecar_pid"), int) and req.get("sidecar_pid") > 0 else None
    notes = []
    session = written = None
    if pid is None and sidecar is None:
        notes.append("No process to look at, so its session is not known.")
    elif cwd is None:
        notes.append("No directory to look for its session in, so it is not known.")
    else:
        now_ms = int(time.time() * 1000)
        since = started_ms(pid if pid is not None else sidecar, now_ms)
        if since is None:
            notes.append("When this opencode started could not be read, so its session is not named.")
        else:
            session, written, note = by_directory(home, cwd, since)
            notes.append(note)
    return {"version": 1, "me": True, "session": session, "session_written_ms": written,
            "quit": None, "notes": notes}


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
    answer = {"inventory": inventory, "launch": launch, "identify": identify}[sys.argv[1]](req)
    sys.stdout.write(json.dumps(answer, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
