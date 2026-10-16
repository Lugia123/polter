#!/usr/bin/env python3
"""Every string a shipped plugin shows on its settings page has a Chinese
translation in that plugin's `i18n/zh-Hans.json`.

# Why

A person with a Chinese interface opened Settings > Plugins > Claude Code
and read it in English: the description, every field's title and help, and
the choices `yes` / `no` / `user` / `local` (task 1636). Both hosts already
laid a plugin's own `i18n/<lang>.json` over its manifest -- only the chat
archive shipped one, and nothing said the other seven did not. Every test
of the page runs on a plugin fixture or in English, where the manifest's
words *are* the text, so the gap was green everywhere.

# What it checks

For each plugin `src/build/GhosttyResources.zig` ships (its `shipped` list,
so a plugin added there is covered without a second list here; `_sdk` and
anything else starting `_` is not a plugin):

  1. `plugin.json`'s `name` and `description`, and for every parameter in
     `params.properties` its `title`, its `description` and every value of
     its `enum`, has a non-empty counterpart in `i18n/zh-Hans.json`
     (`name`, `description`, `params.<name>.title`, `.description`,
     `.choices.<value>`). A proper noun may be the same as the English --
     "Claude Code" stays "Claude Code" -- but it has to be written down, so
     that "not translated yet" and "deliberately the same" are not the
     same silence.
  2. The sidecar names nothing the manifest does not have: a parameter or
     a choice that is gone from the manifest is a translation nobody will
     see, and usually means the manifest changed and the translation did
     not.

A value of an `enum` is what the settings file holds and what the plugin
reads; it is never translated, only named (`choices`).

Finding no shipped plugin is a failure, not a pass.

NOT CHECKED: that the translation is right or reads well; languages other
than zh-Hans; a plugin's own web page (`ui/`), which translates itself;
`agent_cli.label`, which is the CLI's product name on the role picker.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "src/build/GhosttyResources.zig"
PLUGINS = ROOT / "plugins"


def shipped_keys():
    try:
        text = RESOURCES.read_text(encoding="utf-8")
    except OSError:
        return None
    m = re.search(r"const shipped = \[_\]\[\]const u8\{(.*?)\};", text, re.S)
    if not m:
        return None
    return [k for k in re.findall(r'"([^"]+)"', m.group(1)) if not k.startswith("_")]


def nonempty(v):
    return isinstance(v, str) and v.strip() != ""


def check(key):
    """Returns (strings checked, problems)."""
    problems = []
    try:
        manifest = json.loads((PLUGINS / key / "plugin.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return 0, [f"{key}: plugin.json unreadable: {e}"]
    side_path = PLUGINS / key / "i18n" / "zh-Hans.json"
    try:
        side = json.loads(side_path.read_text(encoding="utf-8"))
    except OSError:
        side = None
    except ValueError as e:
        return 0, [f"{key}: i18n/zh-Hans.json will not parse ({e}); both hosts then show the English"]
    if side is None:
        side = {}
        problems.append(f"{key}: no i18n/zh-Hans.json -- the whole page is English on a Chinese machine")
    if not isinstance(side, dict):
        return 0, [f"{key}: i18n/zh-Hans.json is not an object"]

    checked = 0
    for field in ("name", "description"):
        if nonempty(manifest.get(field)):
            checked += 1
            if not nonempty(side.get(field)):
                problems.append(f"{key}: `{field}` has no Chinese: {manifest[field][:70]!r}")

    props = ((manifest.get("params") or {}).get("properties") or {})
    side_params = side.get("params") or {}
    if not isinstance(side_params, dict):
        problems.append(f"{key}: `params` in the sidecar is not an object")
        side_params = {}
    for name, spec in props.items():
        if not isinstance(spec, dict):
            continue
        sp = side_params.get(name) or {}
        for field in ("title", "description"):
            if nonempty(spec.get(field)):
                checked += 1
                if not nonempty(sp.get(field)):
                    problems.append(f"{key}: params.{name}.{field} has no Chinese: {spec[field][:70]!r}")
        values = [v for v in (spec.get("enum") or []) if isinstance(v, str)]
        choices = sp.get("choices") or {}
        for v in values:
            checked += 1
            if not nonempty(choices.get(v)):
                problems.append(f"{key}: params.{name} shows the value {v!r} with no Chinese name (choices.{v})")
        for v in choices:
            if v not in values:
                problems.append(f"{key}: params.{name}.choices names {v!r}, which the manifest's enum does not have")
    for name in side_params:
        if name not in props:
            problems.append(f"{key}: the sidecar translates params.{name}, which the manifest does not have")
    return checked, problems


def main():
    keys = shipped_keys()
    if keys is None:
        print(f"FAIL: could not read the shipped plugin list from {RESOURCES.relative_to(ROOT)}")
        return 1
    if not keys:
        print("FAIL: the shipped plugin list is empty -- nothing was checked")
        return 1
    total = 0
    problems = []
    for key in keys:
        n, p = check(key)
        total += n
        problems += p
    for p in problems:
        print(f"  {p}")
    if total == 0:
        print(f"FAIL: {len(keys)} shipped plugins and not one visible string found -- nothing was checked")
        return 1
    if problems:
        print(f"FAIL: {len(problems)} problem(s) in {len(keys)} shipped plugins ({total} visible strings)")
        return 1
    print(f"ok: {len(keys)} shipped plugins, {total} visible strings, every one has a zh-Hans translation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
