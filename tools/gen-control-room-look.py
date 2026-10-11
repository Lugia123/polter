#!/usr/bin/env python3
"""Turn `src/input/control-room-look.json` into the two hosts' source.

The control room is drawn twice, by the macOS host and by the Windows host,
and is meant to be one thing (`dev-docs/poltergeist/control-room.md`, 3.5).
So what it looks like is written once, as data, and this script writes it out
as

    windows/control-room/src/look.rs
    macos/Sources/Features/ControlRoom/ControlRoomLook.swift

Both are committed. **Neither is edited by hand**: change the JSON, run

    python3 tools/gen-control-room-look.py --write

and commit all three. `tools/the-control-room-look-is-one-set.py` is red when
the three are out of step.

This is the screenshot overlay's arrangement (`gen-screenshot-look.py`), and
only the arrangement: the control room does not use that overlay's look. It
is a second script beside that one and not an extension of it because nearly
all of that one is about icons -- turning SVG paths into cubics and
rasterising them -- and the control room's glyphs are the system's symbols,
so there is nothing here for that code to do; and because the two tables have
different shapes (this one has a light and a dark value for every colour).

**Without `--write` this writes nothing**: it says whether the two files are
what the data makes, and exits 1 when they are not. Everything in `tools/`
gets run in a row by whoever is about to push, and a generator that wrote on
every run would repair the tree a moment before the gate looked at it.

What is generated, under the data's own names:

  * `numbers`: one namespace per group, the same in both themes;
  * `themed` and `colors`: the fields of a `Theme`, with a light and a dark
    value of it;
  * `text_on`: per surface, the colour a status word is written in, already
    looked up for each theme;
  * `strings`: the system symbols' names;
  * the names of everything still marked `tentative`.

Run:  python3 tools/gen-control-room-look.py              compare; write nothing
      python3 tools/gen-control-room-look.py --write      write both files
      python3 tools/gen-control-room-look.py --stdout     print them; write nothing
      python3 tools/gen-control-room-look.py --contrast   the contrast table; a report, exit 0
Exit: 0 when the files are (or were made) what the data says; 1 otherwise.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

DATA = "src/input/control-room-look.json"
RUST = "windows/control-room/src/look.rs"
SWIFT = "macos/Sources/Features/ControlRoom/ControlRoomLook.swift"
COMMAND = "python3 tools/gen-control-room-look.py --write"
GATE = "tools/the-control-room-look-is-one-set.py"

COLOR = re.compile(r"^#([0-9A-Fa-f]{6})(?:@(0|1|0?\.\d+))?$")
NAME = re.compile(r"^[a-z][a-z0-9]*(_[a-z0-9]+)*$")


class Bad(Exception):
    """The data cannot be turned into source. The message says what and where."""


# --------------------------------------------------------------- reading

def is_meta(key):
    return key.startswith("_")


def colour(text, where):
    m = COLOR.match(text) if isinstance(text, str) else None
    if not m:
        raise Bad(f"{where}: {text!r} is not a colour (`#RRGGBB` or `#RRGGBB@a`).")
    h = m.group(1)
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), float(m.group(2) or 1))


def scalar(v, where):
    if isinstance(v, bool) or (isinstance(v, (int, float)) and not isinstance(v, bool)):
        return v
    raise Bad(f"{where}: {v!r} is not a number or a true/false.")


def doc_of(entry):
    d = entry.get("doc") if isinstance(entry, dict) else None
    return " ".join(d) if isinstance(d, list) else d


def load(root):
    """The data as a list of things to emit. Raises `Bad`."""
    path = os.path.join(root, DATA)
    if not os.path.isfile(path):
        raise Bad(f"{DATA} is not in the tree, so there is nothing to generate from.")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError as e:
        raise Bad(f"{DATA} is not JSON: {e}")

    sources = data.get("sources") or {}
    seen = set()
    tentative = []

    def name(key, where):
        if not NAME.match(key):
            raise Bad(f"{where}: `{key}` is not a lower_snake_case name.")
        return key

    def src(entry, default, where):
        s = (entry.get("src") if isinstance(entry, dict) else None) or default
        if not s:
            raise Bad(f"{where} names no source (`src`, or a `_src` on its group).")
        if s not in sources:
            raise Bad(f"{where}: source `{s}` is not in `sources`.")
        return s

    def note_tentative(entry, full, where):
        t = entry.get("tentative") if isinstance(entry, dict) else None
        if t is None:
            return None
        if not isinstance(t, dict) or "alt" not in t or not t.get("why"):
            raise Bad(f"{where}: `tentative` needs the other candidate (`alt`) and a `why`.")
        tentative.append(full)
        return t

    # numbers: [(group, doc, [(name, value, doc, src, tentative)])]
    groups = []
    for g, body in (data.get("numbers") or {}).items():
        name(g, "numbers")
        items = []
        for k, entry in body.items():
            if is_meta(k):
                continue
            where = f"numbers.{g}.{k}"
            name(k, where)
            if isinstance(entry, dict) and "v" not in entry:
                raise Bad(f"{where} has no value (`v`).")
            v = scalar(entry["v"] if isinstance(entry, dict) else entry, where)
            full = f"{g}.{k}"
            items.append((k, v, doc_of(entry), src(entry, body.get("_src"), where),
                          note_tentative(entry, full, where)))
        if not items:
            raise Bad(f"numbers.{g} is empty.")
        d = body.get("_doc")
        groups.append((g, " ".join(d) if isinstance(d, list) else d, items))

    # theme fields: [(name, kind, light, dark, doc, src)]
    fields = []

    def field(k, kind, light, dark, doc, s):
        if k in seen:
            raise Bad(f"`{k}` is a theme field twice.")
        seen.add(k)
        fields.append((k, kind, light, dark, doc, s))

    themed = data.get("themed") or {}
    for k, entry in themed.items():
        if is_meta(k):
            continue
        where = f"themed.{k}"
        name(k, where)
        if not isinstance(entry, dict) or "light" not in entry or "dark" not in entry:
            raise Bad(f"{where} needs a `light` and a `dark`.")
        note_tentative(entry, k, where)
        field(k, "number", float(scalar(entry["light"], where)), float(scalar(entry["dark"], where)),
              doc_of(entry), src(entry, themed.get("_src"), where))

    colors = data.get("colors") or {}
    palette = {}
    for k, entry in colors.items():
        if is_meta(k):
            continue
        where = f"colors.{k}"
        name(k, where)
        if not isinstance(entry, dict) or "light" not in entry or "dark" not in entry:
            raise Bad(f"{where} needs a `light` and a `dark`.")
        note_tentative(entry, k, where)
        palette[k] = (colour(entry["light"], where), colour(entry["dark"], where))
        field(k, "color", palette[k][0], palette[k][1], doc_of(entry), src(entry, colors.get("_src"), where))

    # text_on: per surface, a colour already looked up for each theme.
    rule = data.get("text_on")
    words = []
    if rule is not None:
        where = "text_on"
        s = src(rule, rule.get("_src"), where)
        role, fallback = rule.get("role"), rule.get("fallback")
        for k in (role, fallback):
            if k not in palette:
                raise Bad(f"{where}: `{k}` is not a colour.")
        if note_tentative(rule, f"text_on.{role}", where) is None and "tentative" in rule:
            raise Bad(f"{where}: `tentative` is empty.")
        for surface, entry in (rule.get("surfaces") or {}).items():
            w = f"{where}.surfaces.{surface}"
            name(surface, w)
            if entry.get("surface") not in palette:
                raise Bad(f"{w}: surface `{entry.get('surface')}` is not a colour.")
            picks = []
            for theme in ("light", "dark"):
                pick = entry.get(theme)
                if pick not in (role, fallback):
                    raise Bad(f"{w}.{theme}: `{pick}` is neither `{role}` nor `{fallback}`.")
                picks.append(pick)
            words.append((surface, entry["surface"], picks[0], picks[1]))
            field(f"{role}_on_{surface}", "color",
                  palette[picks[0]][0], palette[picks[1]][1],
                  f"The status word on this surface: `{picks[0]}` when light, `{picks[1]}` when dark.", s)
        if not words:
            raise Bad("text_on lists no surfaces.")

    strings = []
    for g, body in (data.get("strings") or {}).items():
        name(g, "strings")
        items = []
        for k, v in body.items():
            if is_meta(k):
                continue
            name(k, f"strings.{g}.{k}")
            if not isinstance(v, str) or not v:
                raise Bad(f"strings.{g}.{k} is not a string.")
            items.append((k, v))
        src(body, body.get("_src"), f"strings.{g}")
        d = body.get("_doc")
        strings.append((g, " ".join(d) if isinstance(d, list) else d, items))

    if not groups or not fields:
        raise Bad(f"{DATA} has no numbers or no colours: there is nothing to generate.")

    return {
        "data": data, "sources": sources, "groups": groups, "fields": fields,
        "strings": strings, "tentative": tentative, "palette": palette, "words": words,
    }


# --------------------------------------------------------------- writing

def camel(s, first_upper=False):
    parts = s.split("_")
    head = parts[0].capitalize() if first_upper else parts[0]
    return head + "".join(p.capitalize() for p in parts[1:])


def num(v):
    """A number as both languages write a floating-point literal."""
    f = float(v)
    return repr(f) if f != int(f) or abs(f) >= 1e15 else f"{int(f)}.0"


def comment(o, prefix, doc, source, tentative=None):
    lines = []
    if doc:
        lines.append(doc)
    if tentative:
        alt = tentative["alt"]
        alt = ("true" if alt else "false") if isinstance(alt, bool) else alt
        lines.append(f"TENTATIVE (other candidate: {alt}). {tentative['why']}")
    lines.append(f"Source: {source}.")
    for line in lines:
        o.append(f"{prefix} {line}")


def rust(d):
    o = []
    w = o.append
    w("//! What the control room looks like: sizes, colours, durations")
    w("//! (`dev-docs/poltergeist/control-room.md`, 3.5).")
    w("//!")
    w("//! **GENERATED. Do not edit this file.** It is written from")
    w(f"//! `{DATA}` by `{COMMAND}`;")
    w(f"//! change the data and run that. `{GATE}`")
    w("//! fails when this file is not what the data says. The macOS host has the")
    w("//! same data as `ControlRoomLook.swift`, written by the same run.")
    w("//!")
    w("//! Lengths are logical points and times are seconds. These are readings off")
    w("//! the design, not off a product.")
    w("")
    w("/// A colour and how much of it there is.")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub struct Rgba {")
    w("    pub r: u8,")
    w("    pub g: u8,")
    w("    pub b: u8,")
    w("    /// 0 to 1.")
    w("    pub a: f64,")
    w("}")
    for g, doc, items in d["groups"]:
        w("")
        if doc:
            w(f"/// {doc}")
        w(f"pub mod {g} {{")
        for k, v, kdoc, s, t in items:
            comment(o, "    ///", kdoc, d["sources"][s], t)
            if isinstance(v, bool):
                w(f"    pub const {k.upper()}: bool = {'true' if v else 'false'};")
            else:
                w(f"    pub const {k.upper()}: f64 = {num(v)};")
        w("}")
    for g, doc, items in d["strings"]:
        w("")
        if doc:
            w(f"/// {doc}")
        w(f"pub mod {g} {{")
        for k, v in items:
            w(f"    pub const {k.upper()}: &str = {json.dumps(v)};")
        w("}")
    w("")
    w("/// Everything that has a light value and a dark one.")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub struct Theme {")
    w("    pub dark: bool,")
    for k, kind, _, _, doc, s in d["fields"]:
        comment(o, "    ///", doc, d["sources"][s])
        w(f"    pub {k}: {'Rgba' if kind == 'color' else 'f64'},")
    w("}")
    for which, idx in (("LIGHT", 2), ("DARK", 3)):
        w("")
        w(f"pub const {which}: Theme = Theme {{")
        w(f"    dark: {'true' if idx == 3 else 'false'},")
        for f in d["fields"]:
            v = f[idx]
            if f[1] == "color":
                w(f"    {f[0]}: Rgba {{ r: {v[0]}, g: {v[1]}, b: {v[2]}, a: {num(v[3])} }},")
            else:
                w(f"    {f[0]}: {num(v)},")
        w("};")
    w("")
    w("/// The theme for an appearance.")
    w("pub const fn theme(dark: bool) -> &'static Theme {")
    w("    if dark {")
    w("        &DARK")
    w("    } else {")
    w("        &LIGHT")
    w("    }")
    w("}")
    w("")
    w("/// What is in this file on the supervisor's say and not yet the user's.")
    w("/// Each is one value in the data; ruling on it is one edit there.")
    w("pub const TENTATIVE: &[&str] = &[")
    for t in d["tentative"]:
        w(f"    {json.dumps(t)},")
    w("];")
    return "\n".join(o) + "\n"


def swift(d):
    o = []
    w = o.append
    w("// swiftlint:disable all")
    w("//")
    w("// GENERATED. Do not edit this file. It is written from")
    w(f"// `{DATA}` by `{COMMAND}`;")
    w(f"// change the data and run that. `{GATE}`")
    w("// fails when this file is not what the data says. The Windows host has the")
    w(f"// same data as `{RUST}`, written by the same run.")
    w("")
    w("import Foundation")
    w("")
    w("/// What the control room looks like: sizes, colours, durations")
    w("/// (`dev-docs/poltergeist/control-room.md`, 3.5). Lengths are logical points")
    w("/// and times are seconds. These are readings off the design, not off a product.")
    w("enum ControlRoomLook {")
    w("    /// A colour and how much of it there is.")
    w("    struct RGBA: Equatable {")
    w("        var r: UInt8")
    w("        var g: UInt8")
    w("        var b: UInt8")
    w("        /// 0 to 1.")
    w("        var a: Double")
    w("    }")
    for g, doc, items in d["groups"]:
        w("")
        if doc:
            w(f"    /// {doc}")
        w(f"    enum {camel(g, True)} {{")
        for k, v, kdoc, s, t in items:
            comment(o, "        ///", kdoc, d["sources"][s], t)
            if isinstance(v, bool):
                w(f"        static let {camel(k)}: Bool = {'true' if v else 'false'}")
            else:
                w(f"        static let {camel(k)}: Double = {num(v)}")
        w("    }")
    for g, doc, items in d["strings"]:
        w("")
        if doc:
            w(f"    /// {doc}")
        w(f"    enum {camel(g, True)} {{")
        for k, v in items:
            w(f"        static let {camel(k)}: String = {json.dumps(v)}")
        w("    }")
    w("")
    w("    /// Everything that has a light value and a dark one.")
    w("    struct Theme: Equatable {")
    w("        var dark: Bool")
    for k, kind, _, _, doc, s in d["fields"]:
        comment(o, "        ///", doc, d["sources"][s])
        w(f"        var {camel(k)}: {'RGBA' if kind == 'color' else 'Double'}")
    w("    }")
    for which, idx in (("light", 2), ("dark", 3)):
        w("")
        w(f"    static let {which} = Theme(")
        w(f"        dark: {'true' if idx == 3 else 'false'},")
        rows = []
        for f in d["fields"]:
            v = f[idx]
            if f[1] == "color":
                rows.append(f"        {camel(f[0])}: RGBA(r: {v[0]}, g: {v[1]}, b: {v[2]}, a: {num(v[3])})")
            else:
                rows.append(f"        {camel(f[0])}: {num(v)}")
        w(",\n".join(rows))
        w("    )")
    w("")
    w("    /// The theme for an appearance.")
    w("    static func theme(dark: Bool) -> Theme {")
    w("        dark ? Self.dark : Self.light")
    w("    }")
    w("")
    w("    /// What is in this file on the supervisor's say and not yet the user's.")
    w("    /// Each is one value in the data; ruling on it is one edit there.")
    w("    static let tentative: [String] = [")
    for t in d["tentative"]:
        w(f"        {json.dumps(t)},")
    w("    ]")
    w("}")
    w("")
    w("#if canImport(AppKit)")
    w("import AppKit")
    w("")
    w("extension ControlRoomLook {")
    w("    /// The theme for what a view is being drawn in right now.")
    w("    static func theme(for appearance: NSAppearance) -> Theme {")
    w("        theme(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)")
    w("    }")
    w("}")
    w("#endif")
    return "\n".join(o) + "\n"


def generate(root):
    """({path: text}, the loaded data). Raises `Bad`."""
    d = load(root)
    return {RUST: rust(d), SWIFT: swift(d)}, d


# --------------------------------------------------------------- contrast

def luminance(c):
    def lin(u):
        u /= 255.0
        return u / 12.92 if u <= 0.04045 else ((u + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def contrast_rows(d):
    """Every declared pair in both themes:
    (theme, surface, kind, role, the colour actually used, ratio, bar). Raises `Bad`."""
    spec = d["data"].get("contrast") or {}
    pal = d["palette"]
    word = {surface: (light, dark) for _, surface, light, dark in d["words"]}
    role_of_word = (d["data"].get("text_on") or {}).get("role")
    rows = []
    for pair in spec.get("pairs") or []:
        on = pair.get("on")
        if on not in pal:
            raise Bad(f"contrast: surface `{on}` is not a colour.")
        for kind in ("text", "large", "glyph"):
            bar = spec.get(kind)
            for role in pair.get(kind) or []:
                for t, theme in enumerate(("light", "dark")):
                    used = role
                    if role == "problem_word":
                        if on not in word:
                            raise Bad(f"contrast: `problem_word` on `{on}`, which `text_on` does not list.")
                        used = word[on][t]
                    if used not in pal:
                        raise Bad(f"contrast: `{used}` is not a colour.")
                    fg, bg = pal[used][t], pal[on][t]
                    if fg[3] != 1 or bg[3] != 1:
                        raise Bad(f"contrast: `{used}` on `{on}` is not opaque; a contrast needs two solid colours.")
                    rows.append((theme, on, kind, role, used, ratio(fg, bg), bar))
    if role_of_word:
        # The same word left red everywhere, so the report shows what `text_on` is for.
        for _, surface, _, _ in d["words"]:
            for t, theme in enumerate(("light", "dark")):
                rows.append((theme, surface, "text", f"{role_of_word} (if left red)", role_of_word,
                             ratio(pal[role_of_word][t], pal[surface][t]), spec.get("text")))
    return rows


def contrast_report(d):
    rows = contrast_rows(d)
    out = ["| theme | surface | kind | what | drawn in | contrast | needs | |", "|---|---|---|---|---|---:|---:|---|"]
    below = []
    for theme, on, kind, role, used, r, bar in rows:
        short = r < bar
        out.append(f"| {theme} | {on} | {kind} | {role} | {used} | {r:.2f} | {bar} | {'BELOW' if short else ''} |")
        if short:
            below.append(f"{theme}: {role} ({used}) on {on} is {r:.2f}, needs {bar} ({kind})")
    out.append("")
    out.append(f"{len(rows)} pairs; {len(below)} below the line:")
    out.extend(f"  {b}" for b in below)
    return "\n".join(out) + "\n"


# --------------------------------------------------------------- main

def main(argv):
    try:
        files, d = generate(ROOT)
        if "--contrast" in argv:
            sys.stdout.write(contrast_report(d))
            return 0
    except Bad as e:
        print(f"FAIL: {e}")
        return 1

    if "--stdout" in argv:
        for path, text in files.items():
            sys.stdout.write(f"=== {path}\n{text}")
        return 0

    if "--write" in argv:
        for path, text in files.items():
            full = os.path.join(ROOT, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            print(f"wrote {path}")
        return 0

    stale = []
    for path, text in files.items():
        full = os.path.join(ROOT, path)
        have = open(full, encoding="utf-8", newline="").read() if os.path.isfile(full) else None
        if have != text:
            stale.append(path)
    if stale:
        print(f"FAIL: not what {DATA} makes: {', '.join(stale)}. Run `{COMMAND}`.")
        return 1
    print(f"OK: {len(files)} generated files are what {DATA} makes. Nothing written.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
