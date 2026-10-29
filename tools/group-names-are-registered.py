#!/usr/bin/env python3
"""Everything filed under a group's name is listed in `group_stores.zig`.

A group's name is its identity, so renaming one means finding every place
that used the old name. The failure that costs is the place nobody listed: it
raises no error, goes on using the old name, and months later a group's
history turns out to be in two halves. `group_rename` therefore works from a
list (`src/poltergeist/group_stores.zig`: `Root`, `Stream`, `Table`,
`Handle`) with a `switch` that has no `else`, so adding to the list without
saying what a rename does to the new entry does not compile.

What the compiler cannot see is a place that was never added to the list. The
types close one of the doors (a `daylog.GroupTree` has a required `owner:
Root`). This closes the others, by listing what is allowed to hold a group's
name and refusing anything else:

  1. A file may only declare a `group: []const u8` field or parameter if it
     is in GROUP_NAME_FILES, with the reason.
  2. A file may only hold a `daylog.GroupTree` if it is in TREE_FILES.
  3. A struct field that is a hash map, in src/poltergeist or App.zig, must
     be in MAP_FIELDS. A map keyed by a group's name is a table in memory
     that a rename has to re-key; if you added one, it belongs in
     `group_stores.Table` and in `App.chatRename`, and then here.

**Green says only that nothing new has appeared.** The first run of this
gate recorded what was there; the list below is that record plus the reason
for each entry. `--self-test` (also run first by every normal run) plants an
offender in a scratch tree and checks the gate goes red on it, so a gate that
has silently stopped looking cannot report green.

Exit 0 and `scanned N files` with N > 0, or non-zero.
"""

import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# -- what is allowed, and why -------------------------------------------------

GROUP_NAME_FILES = {
    "src/poltergeist/Alarms.zig": "a supervisor's alarms (task 2148): each names its group; group_stores.Table.alarms, re-keyed by App.chatRename and dropped with the group",
    "src/App.zig": "the host: takes a group's name from a request and finds the group",
    "src/cli/chat.zig": "the chat page: names groups to the socket; holds no storage",
    "src/cli/launch.zig": "`+launch --group=` (task 1844): says the name to the socket once, in a `launched_for_group` event, before the CLI starts; holds no storage. The host keeps it by terminal (App.launch_groups) only until that agent is heard, and a group renamed or deleted in between is judged as no group by that name and not joined",
    "src/poltergeist/Chat.zig": "the table of groups (group_stores.Table.chat_groups)",
    "src/poltergeist/ChatLog.zig": "the record and the stream (group_stores.Root.chat, Stream.*)",
    "src/poltergeist/ControlAsk.zig": "the control room's last ask of each group's supervisor, keyed by the group's name (group_stores.Table.control_asks): dropped on delete, re-keyed on rename",
    "src/poltergeist/ControlAct.zig": "a request from the control room: carries a group's name to Chat and GroupLog; stores nothing",
    "src/poltergeist/ControlFix.zig": "the control room's Fix button: carries a group's name to the post it makes; what it keeps (`Sent`) is keyed by the terminal told, the terminals that failed and when, not by name -- a rename neither loses a press nor needs re-keying",
    "src/poltergeist/ControlNotify.zig": "decides the control room's notifications from the snapshot's rows; the group's name only rides along to be said and clicked, and what it keeps (`done`) is keyed by terminal, kind and moment, not by name -- a rename neither re-sends nor loses anything",
    "src/poltergeist/ControlRoom.zig": "works a snapshot out of Chat and the task panel on every change; keeps nothing by name between two of them",
    "src/poltergeist/Feed.zig": "an event in flight to plugins; not stored",
    "src/poltergeist/GroupLog.zig": "group.json inside chat/<group>/ (group_stores.Root.chat)",
    "src/poltergeist/GroupRename.zig": "the rename itself",
    "src/poltergeist/MentionRetry.zig": "mentions waiting to be typed again, each naming its group (group_stores.Table.mention_retries)",
    "src/poltergeist/Reclaim.zig": "the groups each terminal of an earlier run never left, as values (group_stores.Table.reclaim_groups): renamed with their group, dropped on delete, held in memory until claimed (task 1978)",
    "src/poltergeist/ResourceNames.zig": "the group each pane in the resource history was in, as a value (group_stores.Table.resource_names): renamed with its group, dropped on delete, written to resources/names.json at the next reading",
    "src/poltergeist/ResourcePage.zig": "the performance page's answer: says the group's name back to the host; stores nothing",
    "src/poltergeist/Overall.zig": "one reading of Polter's own processes (task 2149): a chat row carries the group name its chat was started with, and a dead row is kept for 24 hours -- so the name is not gone by the next reading. It is a table rename must re-key: group_stores.Table.overall_rows, renamed by Overall.renameGroup and dropped by Overall.forgetGroup. Rows are also re-read by name on every sample, which covers a chat restarted under a new name but not a renamed group whose chat surface is still the one started before it",
    "src/poltergeist/OverallRead.zig": "works out which terminal is a chat and which process a sidecar, from arguments (task 2149); the name crosses it as a parameter and is copied into the reading, which stores nothing by it",
    "src/poltergeist/OverallPage.zig": "`resource_overview`'s answer (task 2149): says the group's name back to the caller and matches a name against rows handed in on each call; stores nothing",
    "src/poltergeist/TaskPage.zig": "the task page's answer: says the group's name back to the host; stores nothing",
    "src/poltergeist/StatsLog.zig": "stats/<group>/ and the last-written clock (Root.stats, Table.stats_last)",
    "src/poltergeist/TaskLog.zig": "tasks/<group>/ (group_stores.Root.tasks)",
    "src/poltergeist/Tasks.zig": "the group field of every task (group_stores.Table.task_group_field)",
    "src/poltergeist/daylog.zig": "the tree of per-name directories; its group parameter is the path segment",
    "src/poltergeist/group_stores.zig": "the list itself",
    "src/poltergeist/notes.zig": "builds one sentence about a group; stores nothing",
    "src/poltergeist/Projects.zig": "works out the tie between groups and projects from views handed in on each call; holds no group by name. What it keeps is the host's last statement, where a project file's `group` is the host's word and is put right by an order (set_group) after a rename, not re-keyed",
    "src/poltergeist/Session.zig": "looks a group up by name in a session snapshot already read (supervisorDirIn); files nothing under the name. The snapshot is written whole from Chat after every change, so it carries whatever names Chat holds; one written before a rename simply has no entry for the new name, and the lookup finds nothing",
    "src/poltergeist/worktree.zig": "encodes a group's name into a worktree branch/path segment (groupSegment, task 2433 S4b); stores nothing by name",
    "src/poltergeist/rpc.zig": "the request/response surface: groups are named by callers",
    "src/poltergeist/wire.zig": "parses the request fields",
    "src/poltergeist/Transcript.zig": "terminals, not groups: its `group`-like parameters are the daylog path segment",
    "src/poltergeist/SessionLog.zig": "sessions/<group>/ (group_stores.Root.sessions); what it reads back carries the name it was filed under",
    "src/poltergeist/Records.zig": "works out which transcripts belong to which group from a SessionLog record already read; stores nothing by name",
    "src/poltergeist/RecordTools.zig": "the record tools: a group's name is a scope a caller asks about and is matched against a SessionLog record already read; stores nothing by name",
}

TREE_FILES = {
    "src/poltergeist/ChatLog.zig",
    "src/poltergeist/TaskLog.zig",
    "src/poltergeist/StatsLog.zig",
    "src/poltergeist/GroupLog.zig",
    "src/poltergeist/daylog.zig",
    "src/poltergeist/group_stores.zig",
    "src/poltergeist/GroupRename.zig",
    "src/poltergeist/SessionLog.zig",
}

# (file, field name) -> what it is
MAP_FIELDS = {
    ("src/poltergeist/Alarms.zig", "heard"): "keyed by terminal id, not a group: when each terminal was last heard from (task 2148)",
    ("src/poltergeist/Chat.zig", "groups"): "keyed by group name: group_stores.Table.chat_groups",
    ("src/poltergeist/ControlAsk.zig", "asks"): "keyed by group name: group_stores.Table.control_asks",
    ("src/poltergeist/StatsLog.zig", "last"): "keyed by group name: group_stores.Table.stats_last",
    ("src/poltergeist/Server.zig", "tokens"): "keyed by token, not by group",
    ("src/poltergeist/Projects.zig", "settled"): "keyed by terminal id",
    ("src/poltergeist/Projects.zig", "by_terminal"): "keyed by terminal id: SeatJudged, which agent in a supervisor's pane was judged (task 1795)",
    ("src/poltergeist/ControlFix.zig", "stamps"): "keyed by a hash of the terminal told, the terminals that failed and their moments (stampOf), not by group",
    ("src/poltergeist/ControlNotify.zig", "done"): "keyed by the waiting terminal, its kind and the moment it started (Signature), not by group",
    ("src/poltergeist/Bus.zig", "entries"): "keyed by terminal id",
    ("src/poltergeist/Identities.zig", "entries"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "turns"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "asks"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "pending_tools"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "raises"): "keyed by terminal id",
    ("src/poltergeist/Chat.zig", "members"): "keyed by terminal id, inside one group",
    ("src/poltergeist/PersonaStore.zig", "states"): "keyed by terminal id",
    ("src/poltergeist/PersonaStore.zig", "launches"): "keyed by terminal id",
    ("src/poltergeist/PersonaStore.zig", "launchers"): "keyed by terminal id",
    ("src/poltergeist/PersonaStore.zig", "standings"): "keyed by terminal id",
    ("src/poltergeist/TerminalMeta.zig", "last"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "pending_limits"): "keyed by terminal id: the supervisor whose launch asked for the lines, taken by its next worker (task 1993)",
    ("src/poltergeist/ResourceHistory.zig", "slots"): "keyed by terminal id: each pane's open half hour (task 1993)",
    ("src/poltergeist/Reclaim.zig", "by_session"): "keyed by CLI and agent session id",
    ("src/poltergeist/Reclaim.zig", "groups"): "keyed by terminal id; group names are values in it: group_stores.Table.reclaim_groups",
    ("src/poltergeist/ResourceNames.zig", "entries"): "keyed by terminal id; the group's name is a value in it: group_stores.Table.resource_names",
    ("src/poltergeist/ResourceHistory.zig", "gone"): "keyed by terminal id: panes closed since a reading last named them (task 2015)",
    ("src/poltergeist/ResourcePage.zig", "entries"): "keyed by terminal id: which agent session each terminal ran, as the hash of the CLI and the session id (SessionTable, task 2234). A group's name is not in it -- a rename neither loses a row nor re-keys one",
}

FIELD_GROUP = re.compile(r"^\s*(pub\s+)?group\s*:\s*\[\]const u8")
GROUP_PARAM = re.compile(r"\bgroup\s*:\s*\[\]const u8")
TREE_USE = re.compile(r"daylog\.(Group)?Tree\b|\bGroupTree\b")
MAP_FIELD = re.compile(r"^(?:pub\s+)?(\w+)\s*:\s*std\.(?:StringHashMap|StringArrayHashMap|AutoHashMap|HashMap)\w*\(")
MAP_FIELD_INDENT = re.compile(r"^    (?:pub\s+)?(\w+)\s*:\s*std\.(?:StringHashMap|StringArrayHashMap|AutoHashMap|HashMap)\w*\(.*=\s*\.empty")


def code_lines(path):
    """Lines of a Zig file with comments stripped; tests are skipped."""
    out = []
    in_test = False
    depth = 0
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            stripped = line.split("//")[0] if "//" in line else line
            if not in_test and re.match(r'^test\b', line):
                in_test = True
                depth = 0
            if in_test:
                depth += stripped.count("{") - stripped.count("}")
                if depth <= 0 and "}" in stripped:
                    in_test = False
                continue
            out.append((n, stripped.rstrip("\n")))
    return out


def zig_files(root):
    for base in ("src/poltergeist", "src"):
        d = os.path.join(root, base)
        # No such directory is "nothing to scan", which main() refuses by
        # name; it must not be a crash, which says nothing.
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".zig"):
                yield f"{base}/{name}"
    cli = os.path.join(root, "src/cli")
    if os.path.isdir(cli):
        for name in sorted(os.listdir(cli)):
            if name.endswith(".zig"):
                yield f"src/cli/{name}"


def check(root):
    problems = []
    seen = set()
    scanned = 0
    for rel in zig_files(root):
        if rel in seen:
            continue
        seen.add(rel)
        # Only the poltergeist package, App.zig and the chat CLI hold groups.
        if not (rel.startswith("src/poltergeist/") or rel in ("src/App.zig",) or rel.startswith("src/cli/")):
            continue
        scanned += 1
        lines = code_lines(os.path.join(root, rel))

        if any(GROUP_PARAM.search(t) for _, t in lines) and rel not in GROUP_NAME_FILES:
            n = next(n for n, t in lines if GROUP_PARAM.search(t))
            problems.append(
                f"{rel}:{n}: takes a group's name (`group: []const u8`) but is not in GROUP_NAME_FILES. "
                "If it files anything under that name, add the store to src/poltergeist/group_stores.zig "
                "and handle it in group_rename; then list the file here with the reason."
            )

        if rel not in TREE_FILES:
            for n, t in lines:
                if TREE_USE.search(t):
                    problems.append(
                        f"{rel}:{n}: uses daylog.GroupTree (a tree of per-group directories) but is not in TREE_FILES. "
                        "Add a value to group_stores.Root, handle it in GroupRename, then list the file here."
                    )

        if rel.startswith("src/poltergeist/") or rel == "src/App.zig":
            for n, t in lines:
                m = MAP_FIELD_INDENT.match(t) or MAP_FIELD.match(t)
                if m and (rel, m.group(1)) not in MAP_FIELDS and rel != "src/App.zig":
                    problems.append(
                        f"{rel}:{n}: a new hash-map field `{m.group(1)}`. If it is keyed by a group's name it is a "
                        "table a rename must re-key: add it to group_stores.Table and App.chatRename, then to MAP_FIELDS here "
                        "(or to MAP_FIELDS with a reason if it is not)."
                    )
    return scanned, problems


def self_test():
    """Plant offenders in a scratch tree; the gate must be red on each."""
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "src/poltergeist"))
        os.makedirs(os.path.join(d, "src/cli"))
        with open(os.path.join(d, "src/App.zig"), "w") as f:
            f.write("pub const x = 1;\n")
        with open(os.path.join(d, "src/poltergeist/Newstore.zig"), "w") as f:
            f.write(
                "const daylog = @import(\"daylog.zig\");\n"
                "tree: daylog.GroupTree,\n"
                "by_group: std.StringHashMapUnmanaged(u8) = .empty,\n"
                "pub fn put(self: *Newstore, group: []const u8) void {}\n"
            )
        scanned, problems = check(d)
        kinds = {p.split(": ", 1)[1].split(" ")[0] for p in problems}
        wanted = 3
        if scanned == 0 or len(problems) < wanted:
            print(f"self-test: the gate did not go red on a planted offender ({len(problems)} of {wanted} found)")
            return False
    return True


def main():
    if not self_test():
        return 1
    if "--self-test" in sys.argv:
        print("self-test ok")
        return 0
    scanned, problems = check(ROOT)
    for p in problems:
        print(p)
    print(f"scanned {scanned} files")
    if scanned == 0:
        print("scanned nothing; a gate that looks at nothing is not green")
        return 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
