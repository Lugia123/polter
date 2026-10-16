#!/usr/bin/env python3
"""The Claude Code adapter: what a role can pick from, and how to start it.

Polter's core knows nothing about Claude Code. It knows that this plugin's
manifest has an `agent_cli` section, and that the file it names answers two
questions. Adding another agent CLI is another plugin with the same two
answers -- not a change to the core. `dev-docs/poltergeist/roles.md` part
eleven is the contract; this file is one side of it.

    adapter.py inventory '<request>'
        request {"version":1,"cwd":"/abs"|null,"home":"/abs"}
        stdout  {"version":1,"installed":…,"resume":true,"items":[…],"notes":[…]}

    adapter.py launch '<request>'
        request {"version":1,"cwd":…,"home":…,"polter":"/abs"|null,
                 "session":"<id>"|null,"role":{…},"cli":{…}}
        stdout  {"version":1,"argv":[…],"env":{},"summary":…,"notes":[…],"hooks":true?}

    adapter.py identify '<request>'
        request {"version":1,"cwd":…|null,"home":…,"pid":N|null,
                 "env":{<only the names plugin.json's identify_env lists>}}
        stdout  {"version":1,"me":true|false,"session":"<id>"|null,
                 "session_written_ms":N|null,"quit":{…}|null,"notes":[…]}

`identify` (task 1635) is asked about an agent that talks to Polter with no
hooks and no role launch behind it -- one somebody started by typing
`claude`. Polter's MCP sidecar is one of the programs Claude Code starts,
and Claude Code gives every one of them `CLAUDECODE=1`, `AI_AGENT=claude-code_<version>_…`
and `CLAUDE_CODE_SESSION_ID=<the session>` (measured on claude 2.1.301, by
reading a running sidecar's environment). Those three names are the
manifest's `identify_env`; the sidecar sends their values and nothing else
of its environment. So:

  * **me** when `CLAUDECODE` is `1` or `AI_AGENT` starts `claude-code`.
  * **session** is `CLAUDE_CODE_SESSION_ID` when it has a transcript here
    (`has_transcript`, the check `launch` makes before `--resume`), with the
    transcript's last write as `session_written_ms`. ⚠️ The sidecar's
    environment is the one it was started with: after a `/clear` the CLI
    is in a new session and this still names the old one. That the
    transcript stopped being written while the agent goes on is how Polter
    can tell, which is why the time is reported; this adapter does not
    decide it.
  * **quit** is `/exit`, typed only when the screen shows the input line
    empty (`❯` alone between the rules) and nothing that says a turn is
    running, a question is waiting, or a menu is open. Measured on 2.1.301:
    an idle Claude Code draws `❯` alone on its input line; a turn adds
    `esc to interrupt`; a permission question draws `Do you want` and a
    numbered `❯ 1.` menu. Anything else, and Polter does not type.

The request is the second argument (read from stdin instead when it is
absent, which is only for trying it by hand). One JSON object on stdout; a
reason on stderr and a non-zero exit when there is no answer.

Three things it deliberately does not do, and each is checkable by reading:

  * **It never writes a file.** A role is applied through launch flags that
    last one session: `--settings` (a JSON string, not a path) and
    `--disallowedTools`. The user's settings are exactly as they were.
  * **It never reads a value out of an `env` block.** MCP entries carry API
    keys there. A server is described by its name, its transport and where
    it came from.
  * **It runs `claude` for one thing only: `claude --version`**, at launch,
    to decide whether to configure hooks (below). That starts no MCP server
    and reads no settings. Everything else comes from the files Claude Code
    keeps; running the CLI to ask would start every MCP server it has.

Hooks (`dev-docs/poltergeist/adapters.md` 3.1-3.2): from Claude Code
2.1.145 on, `launch` puts nine hooks into the one `--settings` it passes, each
running `<polter> +hook --cli claude-code <event>` in exec form -- `command`
is the Polter executable and `args` the rest, so no shell reads it: on
Windows without Git Bash the shell is PowerShell, which read the sh-quoted
string as a syntax error and said so only in Claude Code's debug log (#888)
-- and answers `"hooks": true` so that Polter expects to hear from them. Older, or a version it cannot
read, or a role whose `--settings` is a file it cannot merge into, or no
`polter` path in the request: no hooks at all, and a note that says why. No
"some hooks" -- that would make the same state mean different things on
different terminals.

The status line (`dev-docs/poltergeist/control-room.md` 3.6): wherever it
configures hooks, and not on Windows, `launch` also sets `statusLine` in that
same `--settings` to `'<polter>' +statusline --cli claude-code`. Claude Code
hands a status line command how much of the account's allowance is used
(`rate_limits`, measured on 2.1.296), and that is the only place Polter can
read it. **The person's own status line still runs and still shows**: the
one this session would have used -- the role's own, else the project's local
settings, the project's, the user's -- is passed on in the environment as
`POLTER_STATUSLINE_CHAIN`, and `+statusline` runs it with the same input and
lets its output through untouched. Its other fields (`padding`, …) are kept.
With no status line of the person's to stand in for, `+statusline` writes the
row itself -- a few words on how much is used -- because Claude Code keeps a
row for a status line whatever the command prints.
The user's settings files are read and never written. Not on Windows: a
status line has no exec form, it is a line for whichever shell Claude Code
finds there, and one string is not quoted the same for all of them (#888).

Going on with a session: `inventory` says `"resume": true`, which is this
adapter telling Polter it may be handed a session, and `launch` then turns a
`session` in the request into `--resume <id>`. Measured on claude 2.1.296
with a throwaway session, hooks logging every event:

  * `claude --resume <id>` goes on with that session **under the same id**
    (`SessionStart` says `source: resume`), from the directory it was made
    in and from a sibling directory alike -- the transcript stays where it
    was, under the first directory's project.
  * `/clear` ends the session and starts another with a **new id**
    (`SessionEnd reason: clear`, then `SessionStart source: clear`).
    `/compact` keeps the id (`SessionStart source: compact`).
  * `claude --resume <an id with no transcript>` prints `No conversation
    found with session ID: …` and **exits 1 by itself**, without ever saying
    `SessionStart`. On POSIX `+launch` has replaced itself with `claude` by
    then, so nothing is left to tell Polter the launch came to nothing, and
    the person is looking at a shell prompt where a supervisor should be.

**So the session is looked for here, before the command is built**: its
transcript is `~/.claude/projects/<any project>/<id>.jsonl`. When that file
is not there -- cleaned up, another machine's, never Claude Code's id at all
-- the launch starts a new session and a note says so. A launch starts.
What this cannot see is a transcript that is there and that Claude Code will
not load; that one still ends at the shell prompt, and the control room
reports the agent as never having connected.

An id that is not a UUID is not passed on either: `--resume <words>` is a
search by title, and it opens a picker.

A role whose own arguments already choose a session (`--resume`, `-r`,
`--continue`, `-c`, `--session-id`) keeps its choice, and a note says the
one in the request was left out.

Which launch flag switches off which kind of thing was measured, not read
(claude 2.1.278, each with a control that the rest still worked):

  * a personal or project skill: `--settings {"skillOverrides":{name:"off"}}`
  * a plugin's skill (`argus:terminal`): skillOverrides does **not** reach it,
    under either spelling. `--disallowedTools "Skill(argus:terminal)"` does.
  * an MCP server: `--disallowedTools mcp__<server>` removes its tools from
    the list. For a plugin's server the name is `plugin_<plugin>_<server>`.
  * a whole installed plugin: `--settings {"enabledPlugins":{"<p>@<mk>":false}}`.
    Better than the line above where every one of its items is off, because a
    `Skill()` rule blocks the call but leaves the skill in the listing Claude
    is given. Does not reach a plugin synced from claude.ai.
  * everything Claude Code ships with: `--settings {"disableBundledSkills":true}`.
    All of them or none; they are in the binary, so they cannot be listed.

Those can change with a Claude Code release. The probe that measured them is
described next to the table in roles.md, so it can be run again.
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

# Largest file this will read. `~/.claude.json` is the big one.
MAX_BYTES = 8 * 1024 * 1024

# The first Claude Code with every hook field Polter reads: `Stop` carrying
# `background_tasks` (2.1.145), after `StopFailure` (2.1.78),
# `last_assistant_message` (2.1.47) and `PermissionRequest` (2.0.45).
# adapters.md 3.1. Older is not half-supported: it gets no hooks.
HOOKS_SINCE = (2, 1, 145)

# The hooks, in the order they are written, and the matcher each needs.
# `Notification` fires for more than waiting on the person; only these two
# kinds are passed on (`+hook` drops the rest as well).
HOOK_EVENTS = (
    ("SessionStart", None),
    ("UserPromptSubmit", None),
    ("Stop", None),
    ("StopFailure", None),
    ("PermissionRequest", None),
    ("Notification", "idle_prompt|elicitation_dialog"),
    # After every tool call, and synchronously: it is what says a turn went
    # on after an approval or an answer (task 1561), and an `async` one could
    # land after the next tool's `PermissionRequest` and take that one back.
    ("PostToolUse", None),
    # The other two ends of a tool call (task 1625): when one starts, and
    # when one ends by failing. Together with `PostToolUse` they say whether
    # a turn has a tool running in it, which is what tells a worker sitting
    # through a long build from one that has stopped. Synchronous for the
    # same reason as `PostToolUse`: an `async` start could land after its
    # own end and leave a tool counted as running.
    ("PreToolUse", None),
    ("PostToolUseFailure", None),
)

# How the person's own status line command reaches `polter +statusline`
# (`cli/statusline.zig` reads the same name).
STATUSLINE_CHAIN_ENV = "POLTER_STATUSLINE_CHAIN"

# Seconds Claude Code gives one hook. `+hook` answers in milliseconds or
# gives up; this only bounds a Polter that has stopped answering.
HOOK_TIMEOUT = 5

# How long `claude --version` may take.
VERSION_TIMEOUT = 10

# What Claude Code calls a session. Anything else given to `--resume` is a
# search by title.
SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

# Arguments with which a role has already said which session it wants.
SESSION_FLAGS = ("--resume", "-r", "--continue", "-c", "--session-id")


def read_json(path):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None, "too large to read"
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as e:
        return None, str(e)


def read_text(path, limit=256 * 1024):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


# --- skills ------------------------------------------------------------------


def frontmatter(text):
    """The `name` and `description` from a SKILL.md's frontmatter.

    Not a YAML parser, and it does not need to be one: the two keys are
    scalars, written either on one line (optionally quoted) or as a folded or
    literal block. Anything it cannot read comes back as an empty string,
    which the interface shows as "no description" rather than guessing.
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


def skills_in(directory, source, prefix=""):
    """Every `<directory>/<skill>/SKILL.md`, as inventory items."""
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
        name = prefix + (fm.get("name") or entry)
        items.append({
            "kind": "skill",
            "id": "skill:" + name,
            "name": name,
            "description": fm.get("description", ""),
            "source": source,
        })
    return items


def synced_buckets(directory):
    """The per-account folders under `<directory>/synced`.

    What claude.ai syncs down sits one level deeper than everything else:
    `skills/synced/<account>/<skill>/SKILL.md`, and
    `plugins/synced/<account>/<plugin>/.claude-plugin/plugin.json`. A walk
    that stops at `skills/<skill>` sees `synced` as a folder with no
    `SKILL.md` and steps over it -- and what the inventory never sees, a
    role can never switch off. Measured 2026-09-27: a supervisor role that
    switched off all twenty of this machine's own skills left all twelve
    synced ones and the seven skills of the synced `design` plugin on.

    `synced` is an ordinary name and could be somebody's own skill or
    plugin. If it looks like one it is one, and it has no buckets.
    """
    root = os.path.join(directory, "synced")
    if os.path.isfile(os.path.join(root, "SKILL.md")):
        return []
    if os.path.isfile(os.path.join(root, ".claude-plugin", "plugin.json")):
        return []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    out = []
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(root, name)
        if os.path.isdir(path):
            out.append(path)
    return out


def synced_plugins_in(bucket):
    """`<bucket>/<plugin>/` for each plugin claude.ai synced down.

    Listed whatever `enabledPlugins` says, which is the one place this
    departs from an installed plugin. Measured 2026-09-27: `design` is
    `false` there and its seven skills were in the session anyway -- the
    switch that settings file holds is for plugins installed from a
    marketplace, and a synced plugin does not go through it.
    """
    out = []
    try:
        names = sorted(os.listdir(bucket))
    except OSError:
        return out
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(bucket, name)
        if os.path.isfile(os.path.join(path, ".claude-plugin", "plugin.json")):
            out.append((name, path))
    return out


# --- MCP servers -----------------------------------------------------------


def tool_prefix_name(name):
    """What Claude Code puts between `mcp__` and `__` for a server.

    Characters outside `[A-Za-z0-9_-]` become `_` -- which is how a server
    called "claude.ai Claude Docs" shows up as `claude_ai_Claude_Docs`.
    """
    return re.sub(r"[^A-Za-z0-9_-]", "_", name)


def describe_server(spec):
    """How a server is reached, in words, with nothing secret in them.

    The command's own file name and a URL's host. Not the arguments -- a
    token passed as `--api-key xyz` is an argument -- and never `env`.
    """
    if not isinstance(spec, dict):
        return ""
    url = spec.get("url") or spec.get("httpUrl")
    if isinstance(url, str) and url:
        m = re.match(r"^[a-z]+://([^/?#]+)", url)
        host = m.group(1) if m else url
        host = host.split("@")[-1]
        return "%s · %s" % (spec.get("type") or "http", host)
    command = spec.get("command")
    if isinstance(command, str) and command:
        return "stdio · %s" % os.path.basename(command)
    return ""


def servers_from(block, source, prefix="", description=""):
    items = []
    if not isinstance(block, dict):
        return items
    for name in sorted(block):
        wire = tool_prefix_name(prefix + name)
        items.append({
            "kind": "mcp",
            "id": "mcp:" + wire,
            "name": name,
            "description": description,
            "detail": describe_server(block[name]),
            "source": source,
            "locked": wire == POLTER_SERVER,
        })
    return items


# --- plugins -----------------------------------------------------------------


def enabled_plugins(home, cwd, notes):
    """`name@marketplace` -> install path, for the plugins switched on.

    A plugin that is installed and switched off is already absent from every
    session, so a role has nothing to decide about it and it is not listed.
    """
    settings, err = read_json(os.path.join(home, ".claude", "settings.json"))
    if err:
        notes.append("Could not read ~/.claude/settings.json: " + err)
    enabled = {}
    if isinstance(settings, dict) and isinstance(settings.get("enabledPlugins"), dict):
        enabled.update(settings["enabledPlugins"])
    if cwd:
        for local in ("settings.json", "settings.local.json"):
            project, _ = read_json(os.path.join(cwd, ".claude", local))
            if isinstance(project, dict) and isinstance(project.get("enabledPlugins"), dict):
                enabled.update(project["enabledPlugins"])

    installed, err = read_json(os.path.join(home, ".claude", "plugins", "installed_plugins.json"))
    if err:
        notes.append("Could not read the installed plugin list: " + err)
    out = {}
    if not isinstance(installed, dict) or not isinstance(installed.get("plugins"), dict):
        return out
    for key, entries in installed["plugins"].items():
        if enabled.get(key) is not True or not isinstance(entries, list):
            continue
        # A plugin can be installed more than once (user scope, and a
        # project scope elsewhere). The user-scope entry, or the one for this
        # project, is the one this session would load.
        chosen = None
        for e in entries:
            if not isinstance(e, dict):
                continue
            if e.get("scope") == "user" or (cwd and e.get("projectPath") == cwd):
                chosen = e
        if chosen and isinstance(chosen.get("installPath"), str):
            out[key] = chosen["installPath"]
    return out


def plugin_items(key, path):
    name = key.split("@", 1)[0]
    manifest, _ = read_json(os.path.join(path, ".claude-plugin", "plugin.json"))
    manifest = manifest if isinstance(manifest, dict) else {}
    about = manifest.get("description") if isinstance(manifest.get("description"), str) else ""
    source = "plugin:" + name

    items = skills_in(os.path.join(path, "skills"), source, prefix=name + ":")

    servers = manifest.get("mcpServers")
    if isinstance(servers, str):
        servers, _ = read_json(os.path.join(path, servers))
    if not isinstance(servers, dict):
        mcp_json, _ = read_json(os.path.join(path, ".mcp.json"))
        if isinstance(mcp_json, dict):
            servers = mcp_json.get("mcpServers", mcp_json)
    items += servers_from(servers, source, prefix="plugin_%s_" % name, description=about)

    for item in items:
        item["group"] = name
        item["group_description"] = about
    return items


# --- what is not on disk -----------------------------------------------------

# Claude Code's own skills -- `/code-review`, `/run`, `/init`, `/artifact-design`
# and a dozen more. They live in the binary, so no walk of any directory can
# list them, and a written-out list of their names would go stale with every
# release. `disableBundledSkills` takes all of them at once, so they are one
# row rather than a dozen. Measured 2026-09-27 (claude 2.1.283): with it on,
# `keybindings-help` is `Unknown skill: keybindings-help` while the user's own
# `ponytail` still runs.
#
# The id cannot collide with a real skill: those are `skill:<name>`, and a
# directory whose name starts with `.` is skipped before it is ever read.
BUNDLED_ITEM = {
    "kind": "skill",
    "id": "skill:.bundled",
    "name": "Claude Code's own skills",
    "description": "Everything Claude Code ships with: /code-review, /run, /init, /loop and the rest. All of them or none.",
    "source": "claude-code",
}


# --- the two questions -------------------------------------------------------


def on_path(binary):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(d, binary)
        if d and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # The login shell's PATH is not always this process's. These are where
    # the official installer and npm put it.
    for candidate in ("~/.local/bin/claude", "~/.claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        full = os.path.expanduser(candidate)
        if os.path.isfile(full) and os.access(full, os.X_OK):
            return full
    return None


def inventory(req):
    home = req.get("home") or os.path.expanduser("~")
    cwd = req.get("cwd") or None
    notes = []
    items = []

    items.append(BUNDLED_ITEM)

    skills_root = os.path.join(home, ".claude", "skills")
    items += skills_in(skills_root, "user")
    for bucket in synced_buckets(skills_root):
        items += skills_in(bucket, "claude.ai")
    if cwd:
        items += skills_in(os.path.join(cwd, ".claude", "skills"), "project")

    config, err = read_json(os.path.join(home, ".claude.json"))
    if err:
        notes.append("Could not read ~/.claude.json: " + err)
    if isinstance(config, dict):
        items += servers_from(config.get("mcpServers"), "user")
        if cwd and isinstance(config.get("projects"), dict):
            project = config["projects"].get(cwd)
            if isinstance(project, dict):
                items += servers_from(project.get("mcpServers"), "local")
    if cwd:
        shared, _ = read_json(os.path.join(cwd, ".mcp.json"))
        if isinstance(shared, dict):
            items += servers_from(shared.get("mcpServers"), "project")

    for key, path in sorted(enabled_plugins(home, cwd, notes).items()):
        items += plugin_items(key, path)
    # After the installed ones: where the same plugin is both installed and
    # synced, the installed entry is the one already described, and the
    # de-duplication below keeps whichever came first.
    for bucket in synced_buckets(os.path.join(home, ".claude", "plugins")):
        for name, path in synced_plugins_in(bucket):
            items += plugin_items(name, path)

    # The same id twice (a project skill shadowing a user one of the same
    # name) is one switch at launch, so it is one row here. Whichever came
    # first keeps its place -- except that a project's item takes the row
    # from anything else's: in that directory it is the one Claude Code
    # uses, and it is the one `launch` must leave alone (`PROJECT_SOURCES`).
    at = {}
    unique = []
    for item in items:
        i = at.get(item["id"])
        if i is None:
            at[item["id"]] = len(unique)
            unique.append(item)
        elif item["source"] in PROJECT_SOURCES and unique[i]["source"] not in PROJECT_SOURCES:
            unique[i] = item

    notes.append("Connectors added in claude.ai are not listed: they are not kept on this machine.")
    return {
        "version": CONTRACT_VERSION,
        "installed": on_path("claude") is not None,
        # `launch` goes on with a session it is handed (`session_to_resume`).
        "resume": True,
        "items": unique,
        "notes": notes,
    }


# What belongs to the directory a role is launched in rather than to the
# person: `<cwd>/.claude/skills`, `<cwd>/.mcp.json`, and `~/.claude.json`'s
# `projects[<cwd>].mcpServers`. **A role never switches these off.** A role
# is written in the settings window, which has no directory, so these never
# appear there and can never be in a role's `except`: a role whose default is
# off would take away every one of them in every project it is started in,
# and nobody could have said otherwise. They are the project's, visible only
# in that directory; the role has no say over them.
PROJECT_SOURCES = ("project", "local")


def enabled(selection, item_id):
    """Whether a role leaves this item on: its default, flipped by `except`."""
    default = selection.get("default", True) is not False
    return default != (item_id in (selection.get("except") or []))


def launch(req):
    role = req.get("role") or {}
    cli = req.get("cli") or {}
    inv = inventory(req)

    notes = inv["notes"]

    # A plugin all of whose items are off is switched off whole, rather than
    # item by item. It is a better off: `--disallowedTools` blocks the call but
    # leaves every one of those skills in the listing Claude is given, so a
    # role that took away sixteen of them still paid for sixteen descriptions
    # and the agent still answered "I have these". `enabledPlugins` makes them
    # `Unknown skill` and takes the plugin's MCP tools with them.
    #
    # Measured 2026-09-27 (claude 2.1.283), each with a control:
    #   * `{"enabledPlugins":{"argus@argus-plugins":false}}` -> calling
    #     `argus:agent-inventory` is `Unknown skill`, and no `mcp__plugin_argus_*`
    #     tool is there; `kairos:…` in the same run still runs.
    #   * `{"enabledPlugins":{}}` leaves `argus:…` running, so what the role
    #     passes is **merged into** the user's `enabledPlugins`, not put in
    #     place of it. A role that named one plugin does not switch off the rest.
    #   * A synced plugin ignores it under both `design` and
    #     `design@<marketplace>`; those stay item by item.
    plugin_keys = {}
    for key in enabled_plugins(req.get("home") or os.path.expanduser("~"),
                               req.get("cwd") or None, []):
        plugin_keys[key.split("@", 1)[0]] = key
    whole = {}
    for group, key in plugin_keys.items():
        members = [i for i in inv["items"] if i.get("group") == group and not i.get("locked")]
        if not members:
            continue
        if all(not enabled(cli.get("skills" if i["kind"] == "skill" else "mcp") or {}, i["id"])
               for i in members):
            whole[key] = members

    off_whole = set()
    for members in whole.values():
        for item in members:
            off_whole.add(item["id"])

    overrides = {}
    denied = []
    bundled_off = False
    off = {"skill": 0, "mcp": 0}
    for item in inv["items"]:
        if item.get("locked"):
            continue
        # The project's own, not the role's to take (`PROJECT_SOURCES`).
        if item["source"] in PROJECT_SOURCES:
            continue
        selection = cli.get("skills" if item["kind"] == "skill" else "mcp") or {}
        if enabled(selection, item["id"]):
            continue
        off[item["kind"]] += 1
        if item["id"] in off_whole:
            continue
        if item["id"] == BUNDLED_ITEM["id"]:
            bundled_off = True
        elif item["kind"] == "mcp":
            denied.append("mcp__" + item["id"][len("mcp:"):])
        elif item["source"].startswith("plugin:"):
            denied.append("Skill(%s)" % item["name"])
        else:
            overrides[item["name"]] = "off"

    extra, settings, settings_file = split_settings(
        [a for a in (cli.get("args") or []) if isinstance(a, str)], notes)

    # ⚠️ **One `--settings`, never two.** Measured: given twice, the second
    # replaces the first rather than merging with it, so a role whose extra
    # arguments carry their own `--settings` would silently switch every one
    # of these skills back on. The role's own keys are merged into the
    # user's object; the user's `skillOverrides` are kept alongside.
    if overrides:
        merged = dict(settings.get("skillOverrides") or {})
        merged.update(overrides)
        settings["skillOverrides"] = merged
    if whole:
        merged = dict(settings.get("enabledPlugins") or {})
        for key in sorted(whole):
            merged[key] = False
        settings["enabledPlugins"] = merged
    if bundled_off:
        settings["disableBundledSkills"] = True

    hooks = hooks_for(req, settings_file, notes)
    if hooks:
        merged = dict(settings.get("hooks") or {}) if isinstance(settings.get("hooks"), dict) else {}
        for event, entries in hooks.items():
            before = merged.get(event)
            merged[event] = (list(before) if isinstance(before, list) else []) + entries
        settings["hooks"] = merged

    env = {}
    if hooks and os.name != "nt":
        settings["statusLine"], env = status_line_for(req, settings)

    argv = ["claude"]
    if settings:
        argv += ["--settings", json.dumps(settings, ensure_ascii=False)]
    if denied:
        argv += ["--disallowedTools"] + denied
    model = cli.get("model") or role.get("model")
    if model:
        argv += ["--model", model]
    instructions = role.get("instructions")
    if instructions:
        argv += ["--append-system-prompt", instructions]
    session = session_to_resume(req, extra, notes)
    if session:
        argv += ["--resume", session]
    argv += extra

    answer = {
        "version": CONTRACT_VERSION,
        "argv": argv,
        "env": env,
        "summary": "%d skill(s) and %d MCP server(s) switched off" % (off["skill"], off["mcp"]),
        "notes": notes,
    }
    if hooks:
        answer["hooks"] = True
    return answer


def has_transcript(home, session):
    """Whether Claude Code has a transcript for `session` on this machine.

    `~/.claude/projects/<project>/<session>.jsonl`, under whichever project:
    a session is gone on with from a directory other than the one it was
    made in (measured, see the top of this file), so the launch directory
    is not the place to look.
    """
    root = os.path.join(home, ".claude", "projects")
    try:
        names = os.listdir(root)
    except OSError:
        return False
    for name in names:
        if os.path.isfile(os.path.join(root, name, session + ".jsonl")):
            return True
    return False


def session_to_resume(req, extra, notes):
    """The session id to pass as `--resume`, or None with a note saying why.

    None without a note when the request names no session: that is a new
    session being asked for, not one that could not be gone on with.
    """
    session = req.get("session")
    if not isinstance(session, str) or not session:
        return None
    new = "so this starts a new session."
    for a in extra:
        if a in SESSION_FLAGS or a.split("=", 1)[0] in SESSION_FLAGS:
            notes.append("The role's own arguments already choose a session (%s), so the last "
                         "session is not passed on." % a.split("=", 1)[0])
            return None
    if not SESSION_ID.fullmatch(session):
        notes.append("The last session's id is not one Claude Code gives a session, " + new)
        return None
    home = req.get("home") or os.path.expanduser("~")
    if not has_transcript(home, session):
        notes.append("The last session (%s) is no longer on this machine, %s" % (session, new))
        return None
    notes.append("Going on with the last session (%s)." % session)
    return session


def claude_version():
    """`claude --version` as a tuple, or `(None, why)`."""
    exe = on_path("claude") or "claude"
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True,
                           timeout=VERSION_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None, "could not run claude --version"
    m = re.match(r"\s*(\d+)\.(\d+)\.(\d+)", p.stdout or "")
    if p.returncode != 0 or not m:
        return None, "claude --version did not say a version"
    return tuple(int(g) for g in m.groups()), None


def hooks_for(req, settings_file, notes):
    """The `hooks` block to add, or None with a note saying why not."""
    screen = "so this terminal is watched by its screen alone."
    if settings_file:
        notes.append("Hooks are not configured: the role's --settings is a file, and the "
                     "hooks can only be added to settings given inline -- " + screen)
        return None
    polter = req.get("polter")
    if not isinstance(polter, str) or not polter:
        notes.append("Hooks are not configured: this launch did not say where Polter is, " + screen)
        return None
    version, why = claude_version()
    if version is None:
        notes.append("Hooks are not configured: %s, %s" % (why, screen))
        return None
    if version < HOOKS_SINCE:
        notes.append("Hooks are not configured: Claude Code %s is older than %s, the first "
                     "version whose hooks Polter reads, %s"
                     % (".".join(map(str, version)), ".".join(map(str, HOOKS_SINCE)), screen))
        return None
    out = {}
    for event, matcher in HOOK_EVENTS:
        entry = {"hooks": [{
            "type": "command",
            "command": polter,
            "args": ["+hook", "--cli", "claude-code", event],
            "timeout": HOOK_TIMEOUT,
        }]}
        if matcher:
            entry = {"matcher": matcher, "hooks": entry["hooks"]}
        out[event] = [entry]
    return out


def own_status_line(value):
    """`value` when it is a status line Claude Code would run, else None."""
    if not isinstance(value, dict) or value.get("type") != "command":
        return None
    command = value.get("command")
    if not isinstance(command, str) or not command:
        return None
    return value


def status_line_for(req, settings):
    """The `statusLine` to set, and the environment that goes with it.

    Ours stands where the person's would have been, carrying every field of
    theirs but the command; theirs is found the way Claude Code would have
    found it and handed on by name. `hooks_for` has already said yes, so
    there is a `polter` and the settings are inline.
    """
    own = own_status_line(settings.get("statusLine"))
    if own is None:
        home = req.get("home") or os.path.expanduser("~")
        cwd = req.get("cwd") or None
        files = []
        if cwd:
            files.append(os.path.join(cwd, ".claude", "settings.local.json"))
            files.append(os.path.join(cwd, ".claude", "settings.json"))
        files.append(os.path.join(home, ".claude", "settings.json"))
        for path in files:
            value, _ = read_json(path)
            own = own_status_line(value.get("statusLine") if isinstance(value, dict) else None)
            if own is not None:
                break
    line = dict(own) if own is not None else {}
    line["type"] = "command"
    line["command"] = "'%s' +statusline --cli claude-code" % req["polter"].replace("'", "'\\''")
    env = {STATUSLINE_CHAIN_ENV: own["command"]} if own is not None else {}
    return line, env


def split_settings(args, notes):
    """Take every `--settings <json>` out of `args`, merged into one object.

    A `--settings` that names a file rather than carrying JSON is left where
    it was and said out loud: it will replace the role's own settings, and
    the person who wrote it is the one who can fix that.
    """
    rest, settings, named_file = [], {}, False
    i = 0
    while i < len(args):
        a = args[i]
        value = None
        if a == "--settings" and i + 1 < len(args):
            value, step = args[i + 1], 2
        elif a.startswith("--settings="):
            value, step = a[len("--settings="):], 1
        if value is None:
            rest.append(a)
            i += 1
            continue
        try:
            parsed = json.loads(value)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict):
            settings.update(parsed)
        else:
            rest += args[i:i + step]
            named_file = True
            notes.append("The extra --settings names a file, so it replaces the role's "
                         "skill settings instead of adding to them. Put the JSON inline.")
        i += step
    return rest, settings, named_file


QUIT = {
    "text": "/exit",
    "ready": {
        "line": ["\u276f", ">"],
        "none_of": ["esc to interrupt", "Do you want", "\u276f 1.", "\u276f 2.", "Press Ctrl-C again",
                    "Enter to confirm", "Esc to cancel"],
    },
}


def identify(req):
    """Whether the CLI that started a sidecar is Claude Code, and its session."""
    env = req.get("env") if isinstance(req.get("env"), dict) else {}
    agent = env.get("AI_AGENT") if isinstance(env.get("AI_AGENT"), str) else ""
    me = env.get("CLAUDECODE") == "1" or agent.startswith("claude-code")
    if not me:
        return {"version": 1, "me": False, "session": None, "session_written_ms": None,
                "quit": None, "notes": []}
    notes = []
    session = env.get("CLAUDE_CODE_SESSION_ID")
    written = None
    if not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        notes.append("Claude Code did not say which session it is in.")
        session = None
    else:
        home = req.get("home") or os.path.expanduser("~")
        path = transcript_of(home, session)
        if path is None:
            notes.append("Session %s has no transcript on this machine." % session)
            session = None
        else:
            try:
                written = int(os.path.getmtime(path) * 1000)
            except OSError:
                written = None
    return {"version": 1, "me": True, "session": session, "session_written_ms": written,
            "quit": QUIT, "notes": notes}


def transcript_of(home, session):
    """The transcript file of `session`, under whichever project, or None."""
    root = os.path.join(home, ".claude", "projects")
    try:
        names = os.listdir(root)
    except OSError:
        return None
    for name in names:
        path = os.path.join(root, name, session + ".jsonl")
        if os.path.isfile(path):
            return path
    return None


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
