#!/usr/bin/env python3
"""The Claude Code adapter: what a role can pick from, and how to start it.

Polter's core knows nothing about Claude Code. It knows that this plugin's
manifest has an `agent_cli` section, and that the file it names answers two
questions. Adding another agent CLI is another plugin with the same two
answers -- not a change to the core. `dev-docs/poltergeist/roles.md` part
eleven is the contract; this file is one side of it.

    adapter.py inventory '<request>'
        request {"version":1,"cwd":"/abs"|null,"home":"/abs"}
        stdout  {"version":1,"installed":…,"items":[…],"notes":[…]}

    adapter.py launch '<request>'
        request {"version":1,"cwd":…,"home":…,"role":{…},"cli":{…}}
        stdout  {"version":1,"argv":[…],"env":{},"summary":…,"notes":[…]}

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
  * **It never runs `claude`.** Everything comes from the files Claude Code
    keeps; running the CLI to ask would start every MCP server it has.

Which launch flag switches off which kind of thing was measured, not read
(claude 2.1.278, each with a control that the rest still worked):

  * a personal or project skill: `--settings {"skillOverrides":{name:"off"}}`
  * a plugin's skill (`argus:terminal`): skillOverrides does **not** reach it,
    under either spelling. `--disallowedTools "Skill(argus:terminal)"` does.
  * an MCP server: `--disallowedTools mcp__<server>` removes its tools from
    the list. For a plugin's server the name is `plugin_<plugin>_<server>`.

Those can change with a Claude Code release. The probe that measured them is
described next to the table in roles.md, so it can be run again.
"""

import json
import os
import re
import sys

CONTRACT_VERSION = 1

# The server Polter registers for itself. A role that took it away would be
# a terminal that cannot report back, which looks exactly like a dead one.
POLTER_SERVER = "polter"

# Largest file this will read. `~/.claude.json` is the big one.
MAX_BYTES = 8 * 1024 * 1024


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

    items += skills_in(os.path.join(home, ".claude", "skills"), "user")
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

    # The same id twice (a project skill shadowing a user one of the same
    # name) is one switch at launch, so it is one row here.
    seen = set()
    unique = []
    for item in items:
        if item["id"] in seen:
            continue
        seen.add(item["id"])
        unique.append(item)

    notes.append("Connectors added in claude.ai are not listed: they are not kept on this machine.")
    return {
        "version": CONTRACT_VERSION,
        "installed": on_path("claude") is not None,
        "items": unique,
        "notes": notes,
    }


def enabled(selection, item_id):
    """Whether a role leaves this item on: its default, flipped by `except`."""
    default = selection.get("default", True) is not False
    return default != (item_id in (selection.get("except") or []))


def launch(req):
    role = req.get("role") or {}
    cli = req.get("cli") or {}
    inv = inventory(req)

    overrides = {}
    denied = []
    off = {"skill": 0, "mcp": 0}
    for item in inv["items"]:
        if item.get("locked"):
            continue
        selection = cli.get("skills" if item["kind"] == "skill" else "mcp") or {}
        if enabled(selection, item["id"]):
            continue
        off[item["kind"]] += 1
        if item["kind"] == "mcp":
            denied.append("mcp__" + item["id"][len("mcp:"):])
        elif item["source"].startswith("plugin:"):
            denied.append("Skill(%s)" % item["name"])
        else:
            overrides[item["name"]] = "off"

    notes = inv["notes"]
    extra, settings = split_settings([a for a in (cli.get("args") or []) if isinstance(a, str)], notes)

    # ⚠️ **One `--settings`, never two.** Measured: given twice, the second
    # replaces the first rather than merging with it, so a role whose extra
    # arguments carry their own `--settings` would silently switch every one
    # of these skills back on. The role's own keys are merged into the
    # user's object; the user's `skillOverrides` are kept alongside.
    if overrides:
        merged = dict(settings.get("skillOverrides") or {})
        merged.update(overrides)
        settings["skillOverrides"] = merged

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
    argv += extra

    return {
        "version": CONTRACT_VERSION,
        "argv": argv,
        "env": {},
        "summary": "%d skill(s) and %d MCP server(s) switched off" % (off["skill"], off["mcp"]),
        "notes": notes,
    }


def split_settings(args, notes):
    """Take every `--settings <json>` out of `args`, merged into one object.

    A `--settings` that names a file rather than carrying JSON is left where
    it was and said out loud: it will replace the role's own settings, and
    the person who wrote it is the one who can fix that.
    """
    rest, settings = [], {}
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
            notes.append("The extra --settings names a file, so it replaces the role's "
                         "skill settings instead of adding to them. Put the JSON inline.")
        i += step
    return rest, settings


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in ("inventory", "launch"):
        sys.stderr.write("usage: adapter.py inventory|launch '<request json>'\n")
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
    answer = inventory(req) if sys.argv[1] == "inventory" else launch(req)
    sys.stdout.write(json.dumps(answer, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
