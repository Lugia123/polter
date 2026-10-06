#!/usr/bin/env python3
"""Turn `src/input/screenshot-look.json` into the two hosts' source.

The screenshot overlay is drawn twice, by the Windows host and by the macOS
host, and is meant to be one overlay (`dev-docs/poltergeist/screenshot.md`,
9.8). It used to be drawn from two hand-written copies of the same shapes, and
five of the fifteen icons were glyphs from whichever system font each host
had: the two toolbars differed, and nothing said so.

So what it looks like is written once, as data, and this script writes it out
as

    windows/shots/src/look.rs
    macos/Sources/Features/Screenshot/ShotLook.swift

Both are committed. **Neither is edited by hand**: change the JSON, run

    python3 tools/gen-screenshot-look.py --write

and commit all three. `tools/the-screenshot-look-is-one-set.py` is red when
the three are out of step.

**Without `--write` this writes nothing**: it says whether the two files are
what the data makes, and exits 1 when they are not. Everything in `tools/`
gets run in a row by whoever is about to commit, and a generator that wrote on
every run would repair the tree a moment before the gate looked at it.

What is generated:

  * every number, colour and duration in the data, under the same names;
  * every icon as a list of parts, each a list of **move / line / cubic /
    close** commands in absolute coordinates on the 24-unit artboard. Arcs,
    rounded rectangles and ellipses are turned into cubics here, so that
    neither host has to implement the SVG path grammar -- which is exactly
    where two implementations drift apart;
  * for every icon, the box its ink covers when it is rasterised into a
    button cell at scale 1, 1.5 and 2, by the rule in `rasterise` below. Each
    host has the same rule written in its own language and a test that its
    own answer is this one. Three implementations, one table.

Run:  python3 tools/gen-screenshot-look.py            compare; write nothing
      python3 tools/gen-screenshot-look.py --write    write both files
      python3 tools/gen-screenshot-look.py --stdout   print them; write nothing
Exit: 0 when the files are (now) what the data makes; 1 otherwise.
"""

import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
DATA = os.path.join("src", "input", "screenshot-look.json")
RUST = os.path.join("windows", "shots", "src", "look.rs")
SWIFT = os.path.join("macos", "Sources", "Features", "Screenshot", "ShotLook.swift")
COMMAND = "python3 tools/gen-screenshot-look.py --write"

# The scales the ink boxes are computed at, with the button cell in pixels.
SCALES = (1.0, 1.5, 2.0)
# A cubic becomes this many straight pieces when it is rasterised.
CUBIC_STEPS = 16
# A pixel is sampled on a grid this many points on a side.
GRID = 4
DIGITS = 5


class Bad(Exception):
    pass


# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

_TOKEN = re.compile(r"([MmLlHhVvAaZz])|([-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)")


def _tokens(d):
    out = []
    at = 0
    for m in _TOKEN.finditer(d):
        gap = d[at:m.start()]
        if gap.strip(" ,\t\n"):
            raise Bad(f"cannot read {gap!r} in path {d!r}")
        at = m.end()
        out.append(m.group(1) if m.group(1) else float(m.group(2)))
    if d[at:].strip(" ,\t\n"):
        raise Bad(f"cannot read {d[at:]!r} in path {d!r}")
    return out


def _arc(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """An SVG elliptical arc as cubics: a list of (c1x, c1y, c2x, c2y, x, y)."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [(x1, y1, x2, y2, x2, y2)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        k = math.sqrt(lam)
        rx, ry = rx * k, ry * k
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(num / den, 0.0))
    if bool(large) == bool(sweep):
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    pieces = max(int(math.ceil(abs(dt) / (math.pi / 2) - 1e-9)), 1)
    step = dt / pieces
    k = 4 / 3 * math.tan(step / 4)
    out = []
    for i in range(pieces):
        a, b = t1 + i * step, t1 + (i + 1) * step

        def pt(t):
            return (cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp,
                    cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp)

        def dv(t):
            return (-rx * math.sin(t) * cp - ry * math.cos(t) * sp,
                    -rx * math.sin(t) * sp + ry * math.cos(t) * cp)

        p0, p3 = pt(a), pt(b)
        d0, d3 = dv(a), dv(b)
        out.append((p0[0] + k * d0[0], p0[1] + k * d0[1], p3[0] - k * d3[0], p3[1] - k * d3[1], p3[0], p3[1]))
    # The last point is the one that was asked for, not one a cosine away.
    last = out[-1]
    out[-1] = (last[0], last[1], last[2], last[3], x2, y2)
    return out


def commands_of_path(d):
    """An SVG path (M L H V A Z, either case) as absolute M / L / C / Z."""
    toks = _tokens(d)
    out = []
    i = 0
    x = y = sx = sy = 0.0
    cmd = None

    def take(n):
        nonlocal i
        vals = toks[i:i + n]
        if len(vals) != n or any(isinstance(v, str) for v in vals):
            raise Bad(f"path {d!r}: {cmd} wants {n} numbers")
        i += n
        return vals

    while i < len(toks):
        if isinstance(toks[i], str):
            cmd = toks[i]
            i += 1
            if cmd in "Zz":
                out.append(("Z",))
                x, y = sx, sy
                continue
        elif cmd is None:
            raise Bad(f"path {d!r} starts with a number")
        elif cmd in "Zz":
            raise Bad(f"path {d!r}: a number after Z")
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            a, b = take(2)
            x, y = (x + a, y + b) if rel else (a, b)
            sx, sy = x, y
            out.append(("M", x, y))
            cmd = "l" if rel else "L"
        elif c == "L":
            a, b = take(2)
            x, y = (x + a, y + b) if rel else (a, b)
            out.append(("L", x, y))
        elif c == "H":
            (a,) = take(1)
            x = x + a if rel else a
            out.append(("L", x, y))
        elif c == "V":
            (a,) = take(1)
            y = y + a if rel else a
            out.append(("L", x, y))
        elif c == "A":
            rx, ry, phi, large, sweep, a, b = take(7)
            ex, ey = (x + a, y + b) if rel else (a, b)
            for seg in _arc(x, y, rx, ry, phi, large, sweep, ex, ey):
                out.append(("C",) + seg)
            x, y = ex, ey
        else:
            raise Bad(f"path {d!r}: {cmd} is not a command this reads")
    return out


def commands_of_part(part):
    shapes = [k for k in ("d", "rect", "ellipse") if k in part]
    if len(shapes) != 1:
        raise Bad(f"a part needs exactly one of d / rect / ellipse: {part!r}")
    if "d" in part:
        cmds = commands_of_path(part["d"])
    elif "rect" in part:
        x, y, w, h, r = part["rect"]
        if r > 0:
            d = (f"M{x + r} {y}H{x + w - r}A{r} {r} 0 0 1 {x + w} {y + r}V{y + h - r}"
                 f"A{r} {r} 0 0 1 {x + w - r} {y + h}H{x + r}A{r} {r} 0 0 1 {x} {y + h - r}"
                 f"V{y + r}A{r} {r} 0 0 1 {x + r} {y}Z")
        else:
            d = f"M{x} {y}H{x + w}V{y + h}H{x}Z"
        cmds = commands_of_path(d)
    else:
        cx, cy, rx, ry = part["ellipse"]
        cmds = commands_of_path(
            f"M{cx + rx} {cy}A{rx} {ry} 0 1 1 {cx - rx} {cy}A{rx} {ry} 0 1 1 {cx + rx} {cy}Z")
    # What is written out is what is drawn: round first, rasterise second.
    return [(c[0],) + tuple(round(v, DIGITS) + 0.0 for v in c[1:]) for c in cmds]


# --------------------------------------------------------------------------
# The rasteriser. The two hosts have this rule in their own languages
# (`windows/shots/src/icon.rs`, `ShotIconRaster.swift`); the arithmetic is
# written in the same order in all three.
# --------------------------------------------------------------------------

def polylines(cmds, f, off):
    """Each subpath as a list of points in pixels, and whether it was closed."""
    subs = []
    cur = None
    for c in cmds:
        if c[0] == "M":
            cur = [[(c[1] * f + off, c[2] * f + off)], False]
            subs.append(cur)
        elif c[0] == "L":
            cur[0].append((c[1] * f + off, c[2] * f + off))
        elif c[0] == "C":
            x0, y0 = cur[0][-1]
            x1, y1 = c[1] * f + off, c[2] * f + off
            x2, y2 = c[3] * f + off, c[4] * f + off
            x3, y3 = c[5] * f + off, c[6] * f + off
            for s in range(1, CUBIC_STEPS + 1):
                t = s / CUBIC_STEPS
                u = 1.0 - t
                a = u * u * u
                b = 3.0 * u * u * t
                cc = 3.0 * u * t * t
                d = t * t * t
                cur[0].append((a * x0 + b * x1 + cc * x2 + d * x3, a * y0 + b * y1 + cc * y2 + d * y3))
        else:
            cur[1] = True
    return subs


def _segments(subs, close_all):
    segs = []
    for pts, closed in subs:
        for i in range(len(pts) - 1):
            segs.append((pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]))
        if (closed or close_all) and len(pts) > 1:
            segs.append((pts[-1][0], pts[-1][1], pts[0][0], pts[0][1]))
    return segs


def _dist2(px, py, seg):
    x1, y1, x2, y2 = seg
    dx, dy = x2 - x1, y2 - y1
    ll = dx * dx + dy * dy
    t = 0.0
    if ll > 0.0:
        t = ((px - x1) * dx + (py - y1) * dy) / ll
        if t < 0.0:
            t = 0.0
        elif t > 1.0:
            t = 1.0
    ex, ey = x1 + t * dx - px, y1 + t * dy - py
    return ex * ex + ey * ey


def _inside(px, py, edges):
    odd = False
    for x1, y1, x2, y2 in edges:
        if (y1 > py) != (y2 > py):
            if px < (x2 - x1) * (py - y1) / (y2 - y1) + x1:
                odd = not odd
    return odd


def rasterise(parts, cell, scale, points, artboard):
    """The icon's alpha, `cell` x `cell`, row by row, 0..255.

    The artboard is `points * scale` pixels on a side, centred in the cell.
    A pixel's coverage by a part is the share of its GRID x GRID sample points
    that are inside the fill (even-odd) or within half the stroke width of
    the path -- which is what a stroke with round caps and joins is. Parts
    are laid over one another in order.
    """
    f = points * scale / artboard
    off = (cell - points * scale) / 2.0
    alpha = [0.0] * (cell * cell)
    for part in parts:
        subs = polylines(part["cmds"], f, off)
        fill = part["paint"] in ("fill", "fill+stroke")
        stroke = part["paint"] in ("stroke", "fill+stroke")
        half = part["width"] * f / 2.0 if stroke else 0.0
        half2 = half * half
        outline = _segments(subs, False)
        edges = _segments(subs, True) if fill else []
        xs = [p[0] for pts, _ in subs for p in pts]
        ys = [p[1] for pts, _ in subs for p in pts]
        x_lo = max(int(math.floor(min(xs) - half)), 0)
        x_hi = min(int(math.ceil(max(xs) + half)), cell)
        y_lo = max(int(math.floor(min(ys) - half)), 0)
        y_hi = min(int(math.ceil(max(ys) + half)), cell)
        opacity = part["opacity"]
        for py in range(y_lo, y_hi):
            for px in range(x_lo, x_hi):
                # A shortcut that changes nothing: no sample point is further
                # than 0.531 from the pixel's centre, so a centre that is
                # further than that from every edge decides all of them.
                cx, cy = px + 0.5, py + 0.5
                near = min(_dist2(cx, cy, s) for s in (edges if fill else outline))
                if stroke and fill:
                    near = min(near, min(_dist2(cx, cy, s) for s in outline))
                hits = None
                reach = half + 0.54
                if fill:
                    if near > reach * reach:
                        hits = GRID * GRID if _inside(cx, cy, edges) else 0
                elif near > reach * reach:
                    hits = 0
                elif half > 0.54 and near < (half - 0.54) * (half - 0.54):
                    hits = GRID * GRID
                if hits is None:
                    hits = 0
                    for j in range(GRID):
                        for i in range(GRID):
                            sx = px + (i + 0.5) / GRID
                            sy = py + (j + 0.5) / GRID
                            inside = fill and _inside(sx, sy, edges)
                            if not inside and stroke:
                                for s in outline:
                                    if _dist2(sx, sy, s) <= half2:
                                        inside = True
                                        break
                            if inside:
                                hits += 1
                if hits:
                    cov = hits / (GRID * GRID) * opacity
                    k = py * cell + px
                    alpha[k] = alpha[k] + cov * (1.0 - alpha[k])
    return [int(math.floor(a * 255.0 + 0.5)) for a in alpha]


def ink_box(mask, cell):
    """(x, y, w, h, count) of the pixels at least half covered; zeros if none."""
    x0, y0, x1, y1, n = cell, cell, -1, -1, 0
    for y in range(cell):
        row = y * cell
        for x in range(cell):
            if mask[row + x] >= 128:
                n += 1
                if x < x0:
                    x0 = x
                if x > x1:
                    x1 = x
                if y < y0:
                    y0 = y
                if y > y1:
                    y1 = y
    if n == 0:
        return (0, 0, 0, 0, 0)
    return (x0, y0, x1 - x0 + 1, y1 - y0 + 1, n)


def outline_box(parts):
    """The ink's box on the artboard, in units: (left, top, right, bottom)."""
    l = t = float("inf")
    r = b = float("-inf")
    for part in parts:
        half = part["width"] / 2.0 if part["paint"] in ("stroke", "fill+stroke") else 0.0
        for pts, _ in polylines(part["cmds"], 1.0, 0.0):
            for x, y in pts:
                l, t = min(l, x - half), min(t, y - half)
                r, b = max(r, x + half), max(b, y + half)
    return (l, t, r, b)


def px(points, scale):
    """Points to pixels, the way both hosts do it: rounded, never less than 1."""
    return max(int(math.floor(points * scale + 0.5)), 1)


# --------------------------------------------------------------------------
# Reading the data
# --------------------------------------------------------------------------

def load(root=ROOT):
    path = os.path.join(root, DATA)
    if not os.path.isfile(path):
        raise Bad(f"{DATA} is not in the tree")
    try:
        data = json.load(open(path, encoding="utf-8"))
    except ValueError as e:
        raise Bad(f"{DATA} is not JSON: {e}")
    grid = data.get("icon_grid") or {}
    for k in ("artboard", "live_min", "live_max", "stroke", "points"):
        if k not in grid:
            raise Bad(f"{DATA}: icon_grid.{k} is missing")
    icons = []
    seen = set()
    for raw in data.get("icons") or []:
        key = raw.get("key")
        if not key or not re.fullmatch(r"[a-z][a-z0-9]*", key) or key in seen:
            raise Bad(f"{DATA}: an icon's key is missing, repeated or not a plain word: {key!r}")
        seen.add(key)
        parts = []
        for p in raw.get("parts") or []:
            paint = p.get("paint")
            if paint not in ("stroke", "fill", "fill+stroke"):
                raise Bad(f"{DATA}: icon {key}: paint is {paint!r}")
            parts.append({
                "paint": paint,
                "width": float(p.get("width", grid["stroke"])) if paint != "fill" else 0.0,
                "opacity": float(p.get("opacity", 1)),
                "cmds": commands_of_part(p),
            })
        if not parts:
            raise Bad(f"{DATA}: icon {key} has no parts")
        icons.append({"key": key, "name": raw.get("name", ""), "parts": parts})
    if not icons:
        raise Bad(f"{DATA} holds no icons")
    for group in ("toolbar_icons", "font_icons"):
        for key in data.get(group) or []:
            if key not in seen:
                raise Bad(f"{DATA}: {group} names {key!r}, which is not an icon")
    for icon in icons:
        icon["ink"] = []
        for scale in SCALES:
            cell = px(data["size"]["button"], scale)
            mask = rasterise(icon["parts"], cell, scale, grid["points"], grid["artboard"])
            icon["ink"].append((scale, cell) + ink_box(mask, cell))
    return data, icons


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

def num(v):
    """A float the way both languages read it back exactly."""
    s = repr(round(float(v), DIGITS) + 0.0)
    return s if ("." in s or "e" in s or "inf" in s) else s + ".0"


def camel(name):
    head, *rest = name.split("_")
    return head + "".join(w[:1].upper() + w[1:] for w in rest)


def rgb(hexs):
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})", hexs or "")
    if not m:
        raise Bad(f"{DATA}: {hexs!r} is not #RRGGBB")
    n = int(m.group(1), 16)
    return (n >> 16) & 255, (n >> 8) & 255, n & 255


GROUPS = ("size", "glass", "transition_ms", "text_box", "annotation")


def rust(data, icons):
    o = []
    w = o.append
    w("//! What the screenshot overlay looks like: sizes, colours, durations and")
    w("//! the icons' paths (`dev-docs/poltergeist/screenshot.md`, 9.8).")
    w("//!")
    w("//! **GENERATED. Do not edit this file.** It is written from")
    w(f"//! `{DATA}` by `{COMMAND}`;")
    w("//! change the data and run that. `tools/the-screenshot-look-is-one-set.py`")
    w("//! fails when this file is not what the data says. The macOS host has the")
    w("//! same data as `ShotLook.swift`, written by the same run.")
    w("")
    w("// Lengths are logical points unless a name says otherwise.")
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
    w("")
    w("/// One step of a path, in units of the icon's artboard.")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub enum Cmd {")
    w("    Move(f64, f64),")
    w("    Line(f64, f64),")
    w("    /// Two control points and the end.")
    w("    Cubic(f64, f64, f64, f64, f64, f64),")
    w("    Close,")
    w("}")
    w("")
    w("#[derive(Clone, Copy, Debug, PartialEq, Eq)]")
    w("pub enum Paint {")
    w("    Stroke,")
    w("    Fill,")
    w("    /// Filled, and stroked in the same colour to round its corners.")
    w("    FillAndStroke,")
    w("}")
    w("")
    w("/// One shape of an icon. Parts are drawn in order, one over another.")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub struct Part {")
    w("    pub paint: Paint,")
    w("    /// The stroke's width in artboard units; 0 for a fill.")
    w("    pub width: f64,")
    w("    pub opacity: f64,")
    w("    pub cmds: &'static [Cmd],")
    w("}")
    w("")
    w("/// Where an icon's ink is when it is drawn into a button cell: the box of")
    w("/// the pixels at least half covered, and how many there are.")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub struct Ink {")
    w("    pub scale: f64,")
    w("    /// The cell's side in pixels.")
    w("    pub cell: i32,")
    w("    pub x: i32,")
    w("    pub y: i32,")
    w("    pub w: i32,")
    w("    pub h: i32,")
    w("    pub count: i32,")
    w("}")
    w("")
    w("#[derive(Clone, Copy, Debug, PartialEq)]")
    w("pub struct Icon {")
    w("    pub key: &'static str,")
    w("    /// The English name, a msgid of `src/input/screenshot.zig`.")
    w("    pub name: &'static str,")
    w("    pub parts: &'static [Part],")
    w("    /// What the generator's own rasteriser made of it; the test of this")
    w("    /// crate's rasteriser is that it makes the same.")
    w("    pub ink: &'static [Ink],")
    w("}")
    w("")
    g = data["icon_grid"]
    w("/// The grid the icons are drawn on.")
    w("pub mod icon_grid {")
    for k in ("artboard", "live_min", "live_max", "stroke", "points"):
        w(f"    pub const {k.upper()}: f64 = {num(g[k])};")
    w("}")
    for group in GROUPS:
        w("")
        w(f"pub mod {group} {{")
        for k, v in data[group].items():
            w(f"    pub const {k.upper()}: f64 = {num(v)};")
        w("}")
    w("")
    w("pub mod levels {")
    for k, v in data["levels"].items():
        w(f"    pub const {k.upper()}: [f64; {len(v)}] = [{', '.join(num(x) for x in v)}];")
    w("}")
    w("")
    w("pub mod colour {")
    w("    use super::Rgba;")
    for k, v in data["colour"].items():
        r, gg, b = rgb(v.get("hex"))
        w(f"    pub const {k.upper()}: Rgba = Rgba {{ r: 0x{r:02X}, g: 0x{gg:02X}, b: 0x{b:02X}, a: {num(v['alpha'])} }};")
    w("}")
    w("")
    paint = {"stroke": "Paint::Stroke", "fill": "Paint::Fill", "fill+stroke": "Paint::FillAndStroke"}
    for icon in icons:
        for n, part in enumerate(icon["parts"]):
            w(f"const {icon['key'].upper()}_{n}: &[Cmd] = &[")
            for c in part["cmds"]:
                if c[0] == "M":
                    w(f"    Cmd::Move({num(c[1])}, {num(c[2])}),")
                elif c[0] == "L":
                    w(f"    Cmd::Line({num(c[1])}, {num(c[2])}),")
                elif c[0] == "C":
                    w(f"    Cmd::Cubic({', '.join(num(v) for v in c[1:])}),")
                else:
                    w("    Cmd::Close,")
            w("];")
    w("")
    w("/// Every icon, in the order of the data file.")
    w("pub const ICONS: &[Icon] = &[")
    for icon in icons:
        w("    Icon {")
        w(f"        key: \"{icon['key']}\",")
        w(f"        name: \"{icon['name']}\",")
        w("        parts: &[")
        for n, part in enumerate(icon["parts"]):
            w(f"            Part {{ paint: {paint[part['paint']]}, width: {num(part['width'])}, "
              f"opacity: {num(part['opacity'])}, cmds: {icon['key'].upper()}_{n} }},")
        w("        ],")
        w("        ink: &[")
        for scale, cell, x, y, ww, hh, cnt in icon["ink"]:
            w(f"            Ink {{ scale: {num(scale)}, cell: {cell}, x: {x}, y: {y}, w: {ww}, h: {hh}, count: {cnt} }},")
        w("        ],")
        w("    },")
    w("];")
    w("")
    for group in ("toolbar_icons", "font_icons"):
        keys = data[group]
        w(f"pub const {group.upper()}: [&str; {len(keys)}] = [{', '.join(chr(34) + k + chr(34) for k in keys)}];")
    w("")
    w("/// The icon called `key`, if there is one.")
    w("pub fn icon(key: &str) -> Option<&'static Icon> {")
    w("    ICONS.iter().find(|i| i.key == key)")
    w("}")
    return "\n".join(o) + "\n"


def swift(data, icons):
    o = []
    w = o.append
    w("// swiftlint:disable all")
    w("//")
    w("// GENERATED. Do not edit this file. It is written from")
    w(f"// `{DATA}` by `{COMMAND}`;")
    w("// change the data and run that. `tools/the-screenshot-look-is-one-set.py`")
    w("// fails when this file is not what the data says. The Windows host has the")
    w("// same data as `windows/shots/src/look.rs`, written by the same run.")
    w("")
    w("import Foundation")
    w("")
    w("/// What the screenshot overlay looks like: sizes, colours, durations and")
    w("/// the icons' paths (`dev-docs/poltergeist/screenshot.md`, 9.8). Lengths are")
    w("/// logical points unless a name says otherwise.")
    w("enum ShotLook {")
    w("    /// A colour and how much of it there is.")
    w("    struct RGBA: Equatable {")
    w("        var r: UInt8")
    w("        var g: UInt8")
    w("        var b: UInt8")
    w("        /// 0 to 1.")
    w("        var a: Double")
    w("    }")
    w("")
    w("    /// One step of a path, in units of the icon's artboard.")
    w("    enum Cmd: Equatable {")
    w("        case move(Double, Double)")
    w("        case line(Double, Double)")
    w("        /// Two control points and the end.")
    w("        case cubic(Double, Double, Double, Double, Double, Double)")
    w("        case close")
    w("    }")
    w("")
    w("    enum Paint: Equatable {")
    w("        case stroke")
    w("        case fill")
    w("        /// Filled, and stroked in the same colour to round its corners.")
    w("        case fillAndStroke")
    w("    }")
    w("")
    w("    /// One shape of an icon. Parts are drawn in order, one over another.")
    w("    struct Part: Equatable {")
    w("        var paint: Paint")
    w("        /// The stroke's width in artboard units; 0 for a fill.")
    w("        var width: Double")
    w("        var opacity: Double")
    w("        var cmds: [Cmd]")
    w("    }")
    w("")
    w("    /// Where an icon's ink is when it is drawn into a button cell: the box")
    w("    /// of the pixels at least half covered, and how many there are.")
    w("    struct Ink: Equatable {")
    w("        var scale: Double")
    w("        /// The cell's side in pixels.")
    w("        var cell: Int")
    w("        var x: Int")
    w("        var y: Int")
    w("        var w: Int")
    w("        var h: Int")
    w("        var count: Int")
    w("    }")
    w("")
    w("    struct Icon: Equatable {")
    w("        var key: String")
    w("        /// The English name, a msgid of `src/input/screenshot.zig`.")
    w("        var name: String")
    w("        var parts: [Part]")
    w("        /// What the generator's own rasteriser made of it; the test of")
    w("        /// `ShotIconRaster` is that it makes the same.")
    w("        var ink: [Ink]")
    w("    }")
    w("")
    g = data["icon_grid"]
    w("    /// The grid the icons are drawn on.")
    w("    enum IconGrid {")
    for k in ("artboard", "live_min", "live_max", "stroke", "points"):
        w(f"        static let {camel(k)}: Double = {num(g[k])}")
    w("    }")
    names = {"size": "Size", "glass": "Glass", "transition_ms": "TransitionMs", "text_box": "TextBox",
             "annotation": "Annotation"}
    for group in GROUPS:
        w("")
        w(f"    enum {names[group]} {{")
        for k, v in data[group].items():
            w(f"        static let {camel(k)}: Double = {num(v)}")
        w("    }")
    w("")
    w("    enum Levels {")
    for k, v in data["levels"].items():
        w(f"        static let {camel(k)}: [Double] = [{', '.join(num(x) for x in v)}]")
    w("    }")
    w("")
    w("    enum Colour {")
    for k, v in data["colour"].items():
        r, gg, b = rgb(v.get("hex"))
        w(f"        static let {camel(k)} = RGBA(r: 0x{r:02X}, g: 0x{gg:02X}, b: 0x{b:02X}, a: {num(v['alpha'])})")
    w("    }")
    w("")
    paint = {"stroke": ".stroke", "fill": ".fill", "fill+stroke": ".fillAndStroke"}
    w("    /// Every icon, in the order of the data file.")
    w("    static let icons: [Icon] = [")
    for icon in icons:
        w("        Icon(")
        w(f"            key: \"{icon['key']}\",")
        w(f"            name: \"{icon['name']}\",")
        w("            parts: [")
        for part in icon["parts"]:
            w(f"                Part(paint: {paint[part['paint']]}, width: {num(part['width'])}, "
              f"opacity: {num(part['opacity'])}, cmds: [")
            for c in part["cmds"]:
                if c[0] == "M":
                    w(f"                    .move({num(c[1])}, {num(c[2])}),")
                elif c[0] == "L":
                    w(f"                    .line({num(c[1])}, {num(c[2])}),")
                elif c[0] == "C":
                    w(f"                    .cubic({', '.join(num(v) for v in c[1:])}),")
                else:
                    w("                    .close,")
            w("                ]),")
        w("            ],")
        w("            ink: [")
        for scale, cell, x, y, ww, hh, cnt in icon["ink"]:
            w(f"                Ink(scale: {num(scale)}, cell: {cell}, x: {x}, y: {y}, w: {ww}, h: {hh}, count: {cnt}),")
        w("            ]),")
    w("    ]")
    w("")
    for group in ("toolbar_icons", "font_icons"):
        keys = data[group]
        w(f"    static let {camel(group)}: [String] = [{', '.join(chr(34) + k + chr(34) for k in keys)}]")
    w("")
    w("    /// The icon called `key`, if there is one.")
    w("    static func icon(_ key: String) -> Icon? {")
    w("        icons.first { $0.key == key }")
    w("    }")
    w("}")
    w("")
    w("// swiftlint:enable all")
    return "\n".join(o) + "\n"


def generate(root=ROOT):
    """{relative path: text} for both generated files."""
    data, icons = load(root)
    return {RUST: rust(data, icons), SWIFT: swift(data, icons)}, data, icons


def main():
    try:
        files, _, icons = generate()
    except Bad as e:
        print(f"FAIL: {e}")
        return 1
    if "--stdout" in sys.argv[1:]:
        for path, text in files.items():
            print(f"===== {path}")
            sys.stdout.write(text)
        return 0
    if "--write" not in sys.argv[1:]:
        stale = []
        for path, text in files.items():
            full = os.path.join(ROOT, path)
            if not os.path.isfile(full) or open(full, encoding="utf-8", newline="").read() != text:
                stale.append(path)
        if stale:
            print(f"FAIL: not what {DATA} makes: {', '.join(stale)}. Run `{COMMAND}`.")
            return 1
        print(f"OK: both generated files are what {DATA} makes ({len(icons)} icons). Nothing was written.")
        return 0
    for path, text in files.items():
        full = os.path.join(ROOT, path)
        with open(full, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"wrote {path} ({len(text.encode('utf-8'))} bytes)")
    print(f"{len(icons)} icons from {DATA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
