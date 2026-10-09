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
    "src/App.zig": "the host: takes a group's name from a request and finds the group",
    "src/cli/chat.zig": "the chat page: names groups to the socket; holds no storage",
    "src/poltergeist/Chat.zig": "the table of groups (group_stores.Table.chat_groups)",
    "src/poltergeist/ChatLog.zig": "the record and the stream (group_stores.Root.chat, Stream.*)",
    "src/poltergeist/Feed.zig": "an event in flight to plugins; not stored",
    "src/poltergeist/GroupLog.zig": "group.json inside chat/<group>/ (group_stores.Root.chat)",
    "src/poltergeist/GroupRename.zig": "the rename itself",
    "src/poltergeist/StatsLog.zig": "stats/<group>/ and the last-written clock (Root.stats, Table.stats_last)",
    "src/poltergeist/TaskLog.zig": "tasks/<group>/ (group_stores.Root.tasks)",
    "src/poltergeist/Tasks.zig": "the group field of every task (group_stores.Table.task_group_field)",
    "src/poltergeist/daylog.zig": "the tree of per-name directories; its group parameter is the path segment",
    "src/poltergeist/group_stores.zig": "the list itself",
    "src/poltergeist/notes.zig": "builds one sentence about a group; stores nothing",
    "src/poltergeist/rpc.zig": "the request/response surface: groups are named by callers",
    "src/poltergeist/wire.zig": "parses the request fields",
    "src/poltergeist/Transcript.zig": "terminals, not groups: its `group`-like parameters are the daylog path segment",
}

TREE_FILES = {
    "src/poltergeist/ChatLog.zig",
    "src/poltergeist/TaskLog.zig",
    "src/poltergeist/StatsLog.zig",
    "src/poltergeist/GroupLog.zig",
    "src/poltergeist/daylog.zig",
    "src/poltergeist/group_stores.zig",
    "src/poltergeist/GroupRename.zig",
}

# (file, field name) -> what it is
MAP_FIELDS = {
    ("src/poltergeist/Chat.zig", "groups"): "keyed by group name: group_stores.Table.chat_groups",
    ("src/poltergeist/StatsLog.zig", "last"): "keyed by group name: group_stores.Table.stats_last",
    ("src/poltergeist/Server.zig", "tokens"): "keyed by token, not by group",
    ("src/poltergeist/Bus.zig", "entries"): "keyed by terminal id",
    ("src/poltergeist/Bus.zig", "turns"): "keyed by terminal id",
    ("src/poltergeist/Chat.zig", "members"): "keyed by terminal id, inside one group",
    ("src/poltergeist/PersonaStore.zig", "states"): "keyed by terminal id",
    ("src/poltergeist/PersonaStore.zig", "launches"): "keyed by terminal id",
    ("src/poltergeist/PersonaStore.zig", "standings"): "keyed by terminal id",
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
