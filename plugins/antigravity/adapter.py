#!/usr/bin/env python3
"""The Antigravity CLI adapter: what a role can pick from, how to start it, and who it is.

The contract is `dev-docs/poltergeist/roles.md` part eleven; the Claude Code
and Codex adapters are the other two sides of it. This file answers the same
three questions for Google's Antigravity CLI, whose program is `agy`:

    adapter.py inventory '{"version":1,"cwd":"/abs"|null,"home":"/abs"}'
        -> {"version":1,"installed":…,"options":[…],"items":[…],"notes":[…]}

    adapter.py launch '{"version":1,"cwd":…,"home":…,"polter":"/abs"|null,
                        "session":"<id>"|null,"role":{…},"cli":{…}}'
        -> {"version":1,"argv":["agy",…],"env":{},"summary":…,"notes":[…],
            "hooks":true?,"hooks_heard":"first_turn"?}

    adapter.py identify '{"version":1,"cwd":…|null,"home":…,"pid":N|null,
                          "env":{<only POLTER_AGENT_CLI, POLTER_REGISTERED>}}'
        -> {"version":1,"me":…,"session":null,"session_written_ms":null,
            "quit":null,"notes":[…]}

Task 1682. **Written from Antigravity's documentation** -- antigravity.google/
docs, and the customization guide `agy` 1.4.0 ships
(`builtin/skills/agy-customizations/`), which wins where they differ -- and
from what `agy plugin list` / `plugin disable` do to a home made for the
purpose. **No session of a running `agy` has been read yet.** What it does
not know it leaves out rather than guesses:

  * **Resume** (measured on 1.4.0): every hook names the conversation
    (`conversationId`), and `agy` prints `agy --conversation=<id>` with that
    same id when it exits. A conversation is kept as
    `~/.gemini/antigravity-cli/conversations/<id>.db`, so a launch passes
    `--conversation <id>` only when that file is there -- given one that is
    gone, the CLI may stop with the person at a shell prompt (roles.md
    11.3, the reason the Claude Code adapter checks first).
  * **A role's switches do not reach it.** There is no per-run override:
    no `-c`, no flag for a system prompt, and the switches Antigravity has --
    `disabled` and `disabledTools` in `mcp_config.json` -- are in the
    person's global file, which a role must not rewrite for everybody's
    sessions. So the role's model is passed (`--model`, documented) and its
    own arguments, and everything else is said in a note.
  * **No quit in `identify`**: no screen has been read yet to say when
    typing `/exit` is safe. Its session is the conversation record the
    process holds open, when it holds exactly one (not measured: `None`
    when it holds none).

Where Antigravity looks for skills (the shipped guide): under its global
customization root, `~/.gemini/config/skills/<name>/SKILL.md`, in the
working directory's `.agents/skills` (and `.agent/skills`), and inside its
plugins -- Polter's own among them (`~/.gemini/config/plugins/polter/`,
which `provision.sh` writes and this does not list). ⚠️ The web page said
`~/.gemini/antigravity-cli/skills/` instead; the guide `agy` carries does
not mention it, and which of the two a session loads has not been read
off one. MCP servers: `~/.gemini/config/mcp_config.json` and the working
directory's `.agents/mcp_config.json`, each a `mcpServers` object.

Three things it does not do, each checkable by reading:

  * **It never writes a file.**
  * **It never reads a value out of an `env` table**: a server is described by
    its transport and its command's file name or URL host.
  * **It never starts a session of `agy`**, which would start every MCP
    server it has. It runs `agy --help` and nothing else, for the launch
    options (see `launch_options`).

The request is the second argument (stdin when it is absent, for trying it by
hand). One JSON object on stdout; a reason on stderr and a non-zero exit when
there is no answer.
"""

import json
import os
import re
import subprocess
import sys

CONTRACT_VERSION = 1

# The server Polter registers for itself. A role that took it away would be
# a terminal that cannot report back, which looks exactly like a dead one.
POLTER_SERVER = "polter"

# What the provision puts into the polter entry's `env` so that the sidecar
# can say which CLI started it (plugins/antigravity/provision.sh).
AGENT_MARKER = "POLTER_AGENT_CLI"
ME = "antigravity"

# Where `provision.sh` puts Polter's hooks -- its Antigravity plugin,
# `~/.gemini/config/plugins/<PLUGIN_DIR>/hooks.json` -- and the name it puts
# them under.
PLUGIN_DIR = "polter"
HOOKS_KEY = "polter"

MAX_BYTES = 4 * 1024 * 1024

# What belongs to the directory a role is started in rather than to the
# person. The same rule as the other two adapters: a role never switches
# these off.
PROJECT_SOURCES = ("project",)

# Said on every inventory and launch: the reason the role's switches are
# shown and do nothing.
NO_SWITCHES = ("Antigravity CLI has no way to leave a skill or an MCP server out of one session; "
               "a role's switches for it are kept, and do not change what the agent has.")


def read_text(path, limit=256 * 1024):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


# --- skills ------------------------------------------------------------------


def frontmatter(text):
    """`name` and `description` from a SKILL.md's frontmatter.

    The same reading as the other adapters': one-line scalars, quoted or not,
    and folded or literal blocks. Anything else is an empty string.
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
    """Every `<directory>/<skill>/SKILL.md`, as items."""
    items = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return items
    for entry in names:
        if entry.startswith("."):
            continue
        text = read_text(os.path.join(directory, entry, "SKILL.md"))
        if text is None:
            continue
        fm = frontmatter(text)
        # `name` is optional in Antigravity's skills; the folder's name
        # stands in for it ("docs/skills").
        name = fm.get("name") or entry
        items.append({
            "kind": "skill",
            "id": "skill:" + name,
            "name": name,
            "description": fm.get("description", ""),
            "source": source,
        })
    return items


# --- mcp_config.json ---------------------------------------------------------


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
    url = spec.get("serverUrl")
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
    servers = config.get("mcpServers")
    if not isinstance(servers, dict):
        return items
    for name in sorted(servers):
        spec = servers[name]
        if not isinstance(spec, dict):
            continue
        # Switched off in the person's own config: already out of every
        # session, nothing for a role to decide.
        if spec.get("disabled") is True:
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
    # The login shell's PATH is not always this process's. The installer's
    # default is `~/.local/bin/agy` ("docs/getting-started"). Only for `agy`:
    # asked for anything else, these would name the wrong program.
    if binary != "agy":
        return None
    for candidate in ("~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"):
        full = os.path.expanduser(candidate)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


def gather(req):
    home = req.get("home") or os.path.expanduser("~")
    cwd = req.get("cwd") or None
    notes = []
    items = []

    items += skills_in(os.path.join(home, ".gemini", "config", "skills"), "user")
    if cwd:
        items += skills_in(os.path.join(cwd, ".agents", "skills"), "project")
        items += skills_in(os.path.join(cwd, ".agent", "skills"), "project")

    config = read_json(os.path.join(home, ".gemini", "config", "mcp_config.json"), notes, "mcp_config.json")
    items += servers_from(config, "user")
    if cwd:
        project = read_json(os.path.join(cwd, ".agents", "mcp_config.json"), notes, ".agents/mcp_config.json")
        items += servers_from(project, "project")
    return items, notes


def inventory(req):
    items, notes = gather(req)

    # One id is one switch; the project's row takes it, as in the others.
    at = {}
    unique = []
    for item in items:
        i = at.get(item["id"])
        if i is None:
            at[item["id"]] = len(unique)
            unique.append(item)
        elif item["source"] in PROJECT_SOURCES and unique[i]["source"] not in PROJECT_SOURCES:
            unique[i] = item

    notes.append(NO_SWITCHES)
    notes.append("Antigravity plugins are not listed: a role cannot switch them off from the command line.")
    return {
        "version": CONTRACT_VERSION,
        "installed": on_path("agy") is not None,
        "resume": True,
        "options": launch_options(help_text()),
        "items": unique,
        "notes": notes,
    }


def enabled(selection, item_id):
    """Whether a role leaves this item on: its default, flipped by `except`."""
    default = selection.get("default", True) is not False
    return default != (item_id in (selection.get("except") or []))


def hooks_installed(home, polter, notes):
    """Whether Polter's hooks, pointing at this Polter, will run: they are in
    Polter's Antigravity plugin -- the only place they can be, there being no
    per-run way to add one -- and the plugin is on. `provision.sh` writes
    them when its `hooks` setting is yes."""
    if not isinstance(polter, str) or not polter:
        notes.append("No Polter path in the request, so its hooks are not counted on.")
        return False
    plugin = os.path.join(home, ".gemini", "config", "plugins", PLUGIN_DIR)
    # Without its manifest the directory is not a plugin, and nothing in it
    # is loaded (measured: `agy plugin list` lists nothing).
    if not os.path.isfile(os.path.join(plugin, "plugin.json")):
        return False
    mine = read_json(os.path.join(plugin, "hooks.json"), notes, "Polter's hooks.json").get(HOOKS_KEY)
    if not isinstance(mine, dict):
        return False
    text = json.dumps(mine)
    if not ("+hook --cli antigravity" in text and polter in text):
        return False
    # Switched off in Antigravity (`agy plugin disable polter`, or its
    # settings): `config.json`'s `plugins.<directory>.enabled`, measured.
    state = (read_json(os.path.join(home, ".gemini", "config", "config.json"), notes, "config.json")
             .get("plugins") or {})
    entry = state.get(PLUGIN_DIR) if isinstance(state, dict) else None
    if isinstance(entry, dict) and entry.get("enabled") is False:
        notes.append("Polter's Antigravity plugin is switched off in Antigravity, so its hooks will not run.")
        return False
    return True


def launch(req):
    role = req.get("role") or {}
    cli = req.get("cli") or {}
    home = req.get("home") or os.path.expanduser("~")
    items, notes = gather(req)

    # What the role would have switched off, counted so the note can say how
    # much did not happen.
    # A person's skill of the same name as the project's is the project's in
    # this directory, and a role never switches that off.
    project_ids = {i["id"] for i in items if i["source"] in PROJECT_SOURCES}
    off = {"skill": 0, "mcp": 0}
    counted = set()
    for item in items:
        if item.get("locked") or item["id"] in project_ids or item["id"] in counted:
            continue
        selection = cli.get("skills" if item["kind"] == "skill" else "mcp") or {}
        if not enabled(selection, item["id"]):
            counted.add(item["id"])
            off[item["kind"]] += 1
    if off["skill"] or off["mcp"]:
        notes.append("The role switches off %d skill(s) and %d MCP server(s); %s"
                     % (off["skill"], off["mcp"], NO_SWITCHES))

    if role.get("instructions"):
        notes.append("Antigravity CLI takes no instructions on its command line, so the role's were not passed.")


    extra = [a for a in (cli.get("args") or []) if isinstance(a, str)]
    opts = []
    model = cli.get("model") or role.get("model")
    if model:
        opts += ["--model", model]
    opts += apply_options(cli, extra, notes)
    session = session_to_resume(req, extra, notes)
    if session:
        opts += ["--conversation", session]

    argv = ["agy"] + opts + extra
    answer = {
        "version": CONTRACT_VERSION,
        "argv": argv,
        "env": {},
        "summary": "nothing switched off" if not (off["skill"] or off["mcp"])
        else "%d skill(s) and %d MCP server(s) left on" % (off["skill"], off["mcp"]),
        "notes": notes,
    }
    if hooks_installed(home, req.get("polter"), notes):
        answer["hooks"] = True
        # Whether `SessionStart` comes when the program starts or with the
        # first turn is not documented. Waiting for the first turn is the
        # side on which a hook that comes early costs nothing, and one that
        # comes late is not reported missing.
        answer["hooks_heard"] = "first_turn"
    return answer


# --- launch options (task 1677) ----------------------------------------------
#
# The unattended setting a role picks per CLI, as a drop-down rather than as
# words typed into "extra arguments" -- what the Claude Code and Codex
# adapters offer as `permission_mode` and `approval`/`sandbox`. Antigravity's
# is `--mode`, whose values its `--help` gives in brackets after the
# sentence (measured on 1.4.0:
# `--mode   Set the agent execution mode for this session (accept-edits,
# auto, plan)`). Only the values **this** `agy` lists are offered; a help
# that could not be read offers none.
#
# `agy --help` starts no session and no MCP server, and writes nothing
# (measured on 1.4.0: no `~/.gemini` was made by it in a home without one).
OPTION_FLAGS = [("mode", "Execution mode", "--mode")]
HELP_TIMEOUT = 10


def help_text():
    """`agy --help`, or None."""
    exe = on_path("agy")
    if exe is None:
        return None
    try:
        p = subprocess.run([exe, "--help"], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=HELP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    # agy writes its usage to stderr (measured on 1.4.2: stdout empty, the
    # `--mode` line on stderr), so stderr is read when stdout says nothing.
    return p.stdout or p.stderr or None


def flag_values(text, flag):
    """The values `--help` lists for `flag` -- the bracketed, comma-separated
    words at the end of its line -- in its order; [] when it lists none."""
    for line in (text or "").splitlines():
        if re.match(r"\s*%s\s" % re.escape(flag), line):
            m = re.search(r"\(([\w-]+(?:,\s*[\w-]+)+)\)\s*$", line)
            return [v.strip() for v in m.group(1).split(",")] if m else []
    return []


def launch_options(text):
    """The `options` an inventory offers, from a `--help` text."""
    out = []
    for key, label, flag in OPTION_FLAGS:
        values = flag_values(text, flag)
        if values:
            out.append({"key": key, "label": label, "flag": flag, "aliases": [],
                        "values": [{"value": v, "args": [flag, v]} for v in values]})
    return out


def apply_options(cli, extra, notes):
    """The flags the role's `cli.options` stand for. A value this `agy` does
    not list is left out with a note; so is an option whose flag the role's
    extra arguments already give, because those are the role's words too."""
    picked = cli.get("options") or {}
    if not isinstance(picked, dict) or not picked:
        return []
    offered = {o["key"]: o for o in launch_options(help_text())}
    args = []
    for key, value in picked.items():
        o = offered.get(key)
        if o is None:
            notes.append('Launch option "%s" is not one this version offers; left out.' % key)
            continue
        if any(a == o["flag"] or a.startswith(o["flag"] + "=") for a in extra):
            notes.append('Launch option "%s" left out: the extra arguments already give %s.' % (key, o["flag"]))
            continue
        hit = next((v for v in o["values"] if v["value"] == value), None)
        if hit is None:
            notes.append('Launch option %s="%s" is not a value this version takes; left out.' % (key, value))
            continue
        args += hit["args"]
    return args


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


# --- sessions ------------------------------------------------------------------

# A conversation id: what every hook says as `conversationId` and what
# `--conversation` takes (measured: a UUID on 1.4.0).
SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
RECORD = re.compile(r"^(" + SESSION_ID.pattern + r")\.db$")
# The role's own arguments that already choose a conversation.
SESSION_WORDS = ("--conversation", "-c", "--continue")


def records_dir(home):
    return os.path.join(home, ".gemini", "antigravity-cli", "conversations")


def session_to_resume(req, extra, notes):
    """The conversation to go on with, or None with a note saying why not."""
    session = req.get("session")
    if session is None:
        return None
    if any(a in SESSION_WORDS or a.startswith("--conversation=") for a in extra):
        notes.append("The role's own arguments choose a conversation; session %s was left out." % session)
        return None
    if not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        notes.append("%s is not an Antigravity conversation id; starting a new one." % session)
        return None
    home = req.get("home") or os.path.expanduser("~")
    if not os.path.isfile(os.path.join(records_dir(home), session + ".db")):
        notes.append("Conversation %s is not on this machine any more; starting a new one." % session)
        return None
    return session


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
    # `lsof` is in /usr/sbin on macOS, which a PATH handed down by a GUI
    # application need not have.
    lsof = on_path("lsof") or "/usr/sbin/lsof"
    try:
        out = subprocess.run([lsof, "-a", "-p", str(pid), "-Fn"], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return [line[1:] for line in out.stdout.split("\n") if line.startswith("n")]


def held_session(pid, home):
    """The one conversation record `pid` holds open, as (id, written ms), or
    None when it holds none or more than one."""
    files = open_files(pid) if pid else None
    if not files:
        return None
    base = os.path.realpath(records_dir(home))
    found = set()
    for path in files:
        if os.path.dirname(os.path.realpath(path)) != base:
            continue
        m = RECORD.match(os.path.basename(path))
        if m:
            found.add((m.group(1), path))
    if len(found) != 1:
        return None
    session, path = found.pop()
    try:
        written = int(os.path.getmtime(path) * 1000)
    except OSError:
        written = None
    return session, written


def is_agy(path):
    name = os.path.basename(path or "").lower()
    return name in ("agy", "agy.exe")


def identify(req):
    env = req.get("env") if isinstance(req.get("env"), dict) else {}
    pid = req.get("pid") if isinstance(req.get("pid"), int) and req.get("pid") > 0 else None

    # The marker first: it is another CLI's (`codex`) as often as it is
    # this one's, and a marker that names another CLI is a no, whatever
    # the parent is called.
    marker = env.get(AGENT_MARKER)
    if marker is not None:
        me = marker == ME
    else:
        me = bool(pid) and is_agy(exe_of(pid))
    if not me:
        return {"version": 1, "me": False, "session": None, "session_written_ms": None,
                "quit": None, "notes": []}
    home = req.get("home") or os.path.expanduser("~")
    held = held_session(pid, home)
    if held is None:
        return {"version": 1, "me": True, "session": None, "session_written_ms": None, "quit": None,
                "notes": ["Which conversation this is could not be told: it holds no single record open."]}
    return {"version": 1, "me": True, "session": held[0], "session_written_ms": held[1], "quit": None,
            "notes": []}


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
