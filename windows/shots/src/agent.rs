//! The host's half of the agent screenshot tools, minus the screen.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §10.1. The core
//! checks permission, validates paths and annotations, and sends the host one
//! JSON request; the host answers with one JSON result or a refusal. This
//! module is everything between those two that does not touch a window:
//! reading the request, working out which rectangle of which display is
//! meant, which rectangles must be painted black, and writing the answer.
//!
//! **Coordinates in requests and answers are physical pixels inside one
//! display**, with a `display` index beside them; index 0 is the primary.
//! Everything else in this crate is in virtual-screen pixels, so the
//! conversion is here, in one place, in both directions.

use crate::annot::{Item, Shape};
use crate::editor::Measure;
use crate::geom::{Point, Rect};
use crate::style;

/// A refusal: what the host could not do, in a word the core passes on and a
/// sentence for the agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(code: &'static str, message: impl Into<String>) -> Refusal {
        Refusal { code, message: message.into() }
    }

    /// `{"code": …, "message": …}`.
    pub fn json(&self) -> String {
        format!("{{\"code\": {}, \"message\": {}}}", quoted(self.code), quoted(&self.message))
    }
}

fn quoted(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

/// What is to be captured.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Display { index: usize },
    Window { id: u64 },
    /// A rectangle in the pixels of display `display`.
    Region { display: usize, rect: Rect },
    /// The window of the terminal the action was addressed to.
    Terminal,
}

/// Who asked, as the core reports it; written into the sidecar and the log.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Caller {
    pub agent_terminal: String,
    /// The caller's own terminal and, when known, its directory.
    pub terminal: Option<(String, Option<String>)>,
}

/// An annotation as it arrives: in the pixels of the result image, with any
/// colour. Text is not measured yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Raw(serde_json::Value);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    Directory,
    Windows,
    Capture { target: Target, annotations: Vec<Raw>, caller: Caller },
    Annotate { path: String, annotations: Vec<Raw>, caller: Caller },
    Long { target: Target, pages: u32, caller: Caller },
}

impl Request {
    /// The operation's name, for the log.
    pub fn op(&self) -> &'static str {
        match self {
            Request::Directory => "directory",
            Request::Windows => "windows",
            Request::Capture { .. } => "capture",
            Request::Annotate { .. } => "annotate",
            Request::Long { .. } => "long",
        }
    }
}

fn bad(what: impl Into<String>) -> Refusal {
    // The core validates before it sends, so this is the two halves
    // disagreeing about the contract, not something an agent did.
    Refusal::new("BadRequest", format!("The host could not read the request: {}.", what.into()))
}

fn int(v: &serde_json::Value, what: &str) -> Result<i64, Refusal> {
    v.as_i64().ok_or_else(|| bad(format!("{what} is not a whole number")))
}

fn rect_of(v: &serde_json::Value, what: &str) -> Result<Rect, Refusal> {
    let a = v.as_array().filter(|a| a.len() == 4).ok_or_else(|| bad(format!("{what} is not [x, y, w, h]")))?;
    let n: Result<Vec<i64>, Refusal> = a.iter().map(|x| int(x, what)).collect();
    let n = n?;
    Ok(Rect::new(n[0] as i32, n[1] as i32, n[2] as i32, n[3] as i32))
}

fn point_of(v: &serde_json::Value, what: &str) -> Result<Point, Refusal> {
    let a = v.as_array().filter(|a| a.len() == 2).ok_or_else(|| bad(format!("{what} is not [x, y]")))?;
    Ok(Point::new(int(&a[0], what)? as i32, int(&a[1], what)? as i32))
}

fn target_of(v: &serde_json::Value) -> Result<Target, Refusal> {
    match v["kind"].as_str() {
        Some("display") => Ok(Target::Display { index: int(&v["index"], "target.index")?.max(0) as usize }),
        Some("window") => Ok(Target::Window {
            id: v["window_id"].as_u64().ok_or_else(|| bad("target.window_id is not a window id"))?,
        }),
        Some("region") => Ok(Target::Region {
            display: int(&v["display"], "target.display")?.max(0) as usize,
            rect: rect_of(&v["rect"], "target.rect")?,
        }),
        Some("terminal") => Ok(Target::Terminal),
        other => Err(bad(format!("target.kind is {other:?}"))),
    }
}

fn caller_of(v: &serde_json::Value) -> Caller {
    let text = |x: &serde_json::Value| x.as_str().filter(|s| !s.is_empty()).map(str::to_owned);
    Caller {
        agent_terminal: text(&v["agent_terminal"]).unwrap_or_default(),
        terminal: text(&v["terminal"]["id"]).map(|id| (id, text(&v["terminal"]["cwd"]))),
    }
}

/// Read the request the core sent.
pub fn parse(spec: &str) -> Result<Request, Refusal> {
    let v: serde_json::Value = serde_json::from_str(spec).map_err(|e| bad(format!("it is not JSON ({e})")))?;
    let annotations = || -> Vec<Raw> {
        v["annotations"].as_array().map(|a| a.iter().cloned().map(Raw).collect()).unwrap_or_default()
    };
    match v["op"].as_str() {
        Some("directory") => Ok(Request::Directory),
        Some("windows") => Ok(Request::Windows),
        Some("capture") => Ok(Request::Capture {
            target: target_of(&v["target"])?,
            annotations: annotations(),
            caller: caller_of(&v["meta"]),
        }),
        Some("annotate") => Ok(Request::Annotate {
            path: v["path"].as_str().filter(|p| !p.is_empty()).ok_or_else(|| bad("path is missing"))?.to_string(),
            annotations: annotations(),
            caller: caller_of(&v["meta"]),
        }),
        Some("long") => {
            let target = target_of(&v["target"])?;
            if !matches!(target, Target::Window { .. } | Target::Region { .. }) {
                return Err(bad("a long screenshot's target must be a window or a region"));
            }
            let pages = int(&v["pages"], "pages")?;
            if !(1..=20).contains(&pages) {
                return Err(bad(format!("pages is {pages}, not 1 to 20")));
            }
            Ok(Request::Long { target, pages: pages as u32, caller: caller_of(&v["meta"]) })
        }
        other => Err(bad(format!("op is {other:?}"))),
    }
}

// ------------------------------------------------------------ annotations

fn level_of(value: i64, steps: impl Iterator<Item = u32>, what: &str) -> Result<u8, Refusal> {
    steps
        .enumerate()
        .find(|(_, s)| *s as i64 == value)
        .map(|(i, _)| i as u8)
        .ok_or_else(|| bad(format!("{what} is {value}, which is not one of the steps")))
}

/// `#RRGGBB` as a palette index when it is one of the nine, and as itself
/// otherwise.
fn colour_of(v: &serde_json::Value) -> Result<(u8, Option<(u8, u8, u8)>), Refusal> {
    let s = v.as_str().ok_or_else(|| bad("color is missing"))?;
    let hex = s.strip_prefix('#').filter(|h| h.len() == 6 && h.is_ascii()).ok_or_else(|| bad("color is not #RRGGBB"))?;
    let part = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|_| bad("color is not #RRGGBB"));
    let rgb = (part(0)?, part(2)?, part(4)?);
    match style::COLOURS.iter().position(|c| *c == rgb) {
        Some(i) => Ok((i as u8, None)),
        None => Ok((0, Some(rgb))),
    }
}

/// The annotations of a request as this crate's own, moved from the result
/// image's pixels to wherever the image's top-left corner is (`origin`), with
/// text measured at `scale`.
pub fn items(raw: &[Raw], origin: Point, scale: f64, m: &dyn Measure) -> Result<Vec<Item>, Refusal> {
    let mut out = Vec::with_capacity(raw.len());
    for (i, Raw(v)) in raw.iter().enumerate() {
        let what = |field: &str| format!("annotation {i} {field}");
        let kind = v["type"].as_str().unwrap_or_default();
        let stroke = || level_of(int(&v["width"], &what("width"))?, style::WIDTHS.into_iter(), &what("width"));
        let font = || level_of(int(&v["font_size"], &what("font_size"))?, style::FONTS.into_iter(), &what("font_size"));
        let points = || -> Result<Vec<Point>, Refusal> {
            let a = v["points"].as_array().filter(|a| a.len() >= 2).ok_or_else(|| bad(what("points")))?;
            a.iter().map(|p| point_of(p, &what("points"))).collect()
        };
        let text = || v["text"].as_str().unwrap_or_default().replace("\r\n", "\n");
        let (shape, level, coloured) = match kind {
            "rect" => (Shape::Rect(rect_of(&v["rect"], &what("rect"))?), stroke()?, true),
            "ellipse" => (Shape::Ellipse(rect_of(&v["rect"], &what("rect"))?), stroke()?, true),
            "line" => (
                Shape::Line { from: point_of(&v["from"], &what("from"))?, to: point_of(&v["to"], &what("to"))? },
                stroke()?,
                true,
            ),
            "arrow" => (
                Shape::Arrow { from: point_of(&v["from"], &what("from"))?, to: point_of(&v["to"], &what("to"))? },
                stroke()?,
                true,
            ),
            "pen" => (Shape::Pen(points()?), stroke()?, true),
            "highlighter" => (Shape::Highlighter(points()?), stroke()?, true),
            "text" => {
                let level = font()?;
                let text = text();
                let size = m.text(&text, style::font_px(level, scale));
                (Shape::Text { at: point_of(&v["at"], &what("at"))?, text, size }, level, true)
            }
            "number" => {
                let level = font()?;
                let text = text();
                let size = if text.is_empty() { (0, 0) } else { m.text(&text, style::font_px(level, scale)) };
                let n = v["n"].as_u64().ok_or_else(|| bad(what("n")))? as u32;
                (Shape::Number { n, at: point_of(&v["at"], &what("at"))?, text, size }, level, true)
            }
            "mosaic" => {
                let block = int(&v["block"], &what("block"))?;
                let level = level_of(block, style::MOSAIC.into_iter().map(|m| m.0), &what("block"))?;
                (Shape::Mosaic(rect_of(&v["rect"], &what("rect"))?), level, false)
            }
            other => return Err(bad(format!("annotation {i} has type {other:?}"))),
        };
        let (colour, rgb) = if coloured { colour_of(&v["color"])? } else { (0, None) };
        out.push(Item { shape, colour, level, rgb }.moved(origin.x, origin.y));
    }
    Ok(out)
}

// ---------------------------------------------------------------- displays

/// A monitor, as the host enumerated it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DisplayInfo {
    /// Its rectangle on the virtual screen.
    pub rect: Rect,
    pub scale: f64,
    pub primary: bool,
}

/// The displays in the order the tools number them: **the primary first**,
/// the rest as enumerated. Index 0 is promised to be the primary (§10.1),
/// and the system does not promise to enumerate it first.
pub fn ordered(mut displays: Vec<DisplayInfo>) -> Vec<DisplayInfo> {
    // A stable sort keeps the rest in the order they came.
    displays.sort_by_key(|d| !d.primary);
    displays
}

/// A top-level window, as the host enumerated it, topmost first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowInfo {
    pub id: u64,
    pub app: Option<String>,
    pub title: Option<String>,
    pub pid: Option<u32>,
    /// Its bounds on the virtual screen.
    pub rect: Rect,
}

/// The display a window is counted on: the one its centre is on, or failing
/// that the one it overlaps most, or the first.
pub fn display_of(displays: &[DisplayInfo], rect: Rect) -> usize {
    let centre = Point::new(rect.x + rect.w / 2, rect.y + rect.h / 2);
    if let Some(i) = displays.iter().position(|d| d.rect.contains(centre)) {
        return i;
    }
    let area = |d: &DisplayInfo| d.rect.intersect(rect).map_or(0i64, |r| r.w as i64 * r.h as i64);
    displays.iter().enumerate().max_by_key(|(i, d)| (area(d), std::cmp::Reverse(*i))).map_or(0, |(i, _)| i)
}

/// The rectangle of the virtual screen a target means, and the display it is
/// on -- always inside that one display, because a capture is of one.
pub fn resolve(
    target: Target,
    displays: &[DisplayInfo],
    windows: &[WindowInfo],
    terminal_window: Option<u64>,
) -> Result<(usize, Rect), Refusal> {
    let display = |index: usize| {
        displays.get(index).ok_or_else(|| {
            Refusal::new(
                "NoSuchDisplay",
                format!("There is no display {index}; screenshot_windows lists {} display(s).", displays.len()),
            )
        })
    };
    let window = |id: u64| {
        let w = windows.iter().find(|w| w.id == id).ok_or_else(|| {
            Refusal::new(
                "NoSuchWindow",
                format!("There is no window {id} now; it may have closed. Call screenshot_windows again."),
            )
        })?;
        let index = display_of(displays, w.rect);
        let on = display(index)?.rect;
        let rect = w.rect.intersect(on).ok_or_else(|| {
            Refusal::new("BadRegion", format!("Window {id} is not on any display (it may be minimised)."))
        })?;
        Ok((index, rect))
    };
    match target {
        Target::Display { index } => Ok((index, display(index)?.rect)),
        Target::Window { id } => window(id),
        Target::Terminal => window(terminal_window.ok_or_else(|| {
            Refusal::new("NoSuchWindow", "That terminal is not in a window that is on screen.")
        })?),
        Target::Region { display: index, rect } => {
            let on = display(index)?.rect;
            let wanted = Rect::new(rect.x + on.x, rect.y + on.y, rect.w, rect.h);
            let rect = wanted.intersect(on).ok_or_else(|| {
                Refusal::new(
                    "BadRegion",
                    format!(
                        "The rectangle {:?} has no area inside display {index}, which is {} by {} pixels.",
                        [rect.x, rect.y, rect.w, rect.h],
                        on.w,
                        on.h
                    ),
                )
            })?;
            Ok((index, rect))
        }
    }
}

/// The rectangles to paint black in a capture of `capture` (virtual screen),
/// given where the shielded panes are (virtual screen): each cut to the
/// capture and moved into the result image's pixels. A pane that does not
/// reach into the capture is not in the list.
///
/// **Whether another window covers a pane is not asked** (§10.1): a pane that
/// is covered is painted black too. Judging that wrongly once is the pane's
/// contents in an agent's hands; painting too much costs a black rectangle.
pub fn redactions(shielded_panes: &[Rect], capture: Rect) -> Vec<Rect> {
    shielded_panes
        .iter()
        .filter_map(|p| p.intersect(capture))
        .map(|r| r.relative_to(capture.origin()))
        .collect()
}

// ----------------------------------------------------------------- answers

fn rect_json(r: &Rect) -> String {
    format!("[{}, {}, {}, {}]", r.x, r.y, r.w, r.h)
}

/// `{"directory": …}`.
pub fn directory_json(directory: &str) -> String {
    format!("{{\"directory\": {}}}", quoted(directory))
}

/// The answer to `windows`: the displays, and the windows front to back,
/// each on the display its centre is on with its rectangle in that display's
/// pixels (it may run off it).
///
/// **Never half an answer.** When the whole list does not fit in `cap` bytes
/// the windows are cut from the back and `"truncated": true` is added; what
/// is returned always parses.
pub fn windows_json(displays: &[DisplayInfo], windows: &[WindowInfo], cap: usize) -> String {
    let display_entries: Vec<String> = displays
        .iter()
        .enumerate()
        .map(|(i, d)| {
            format!(
                "{{\"index\": {i}, \"size\": [{}, {}], \"scale\": {:?}, \"primary\": {}}}",
                d.rect.w,
                d.rect.h,
                if d.scale.is_finite() && d.scale > 0.0 { d.scale } else { 1.0 },
                d.primary
            )
        })
        .collect();
    let window_entries: Vec<String> = windows
        .iter()
        .map(|w| {
            let index = display_of(displays, w.rect);
            let origin = displays.get(index).map_or(Point::new(0, 0), |d| d.rect.origin());
            let mut parts = vec![format!("\"window_id\": {}", w.id)];
            let named = |key: &str, v: &Option<String>| {
                v.as_deref().filter(|s| !s.is_empty()).map(|s| format!("\"{key}\": {}", quoted(s)))
            };
            parts.extend(named("app", &w.app));
            parts.extend(named("title", &w.title));
            parts.extend(w.pid.map(|p| format!("\"pid\": {p}")));
            parts.push(format!("\"display\": {index}"));
            parts.push(format!("\"rect\": {}", rect_json(&w.rect.relative_to(origin))));
            format!("{{{}}}", parts.join(", "))
        })
        .collect();
    let build = |n: usize| {
        format!(
            "{{\"displays\": [{}], \"windows\": [{}]{}}}",
            display_entries.join(", "),
            window_entries[..n].join(", "),
            if n < window_entries.len() { ", \"truncated\": true" } else { "" }
        )
    };
    let mut n = window_entries.len();
    let mut answer = build(n);
    while answer.len() > cap && n > 0 {
        n -= 1;
        answer = build(n);
    }
    answer
}

/// The answer to `capture` and `annotate`.
pub fn capture_json(path: &str, json: &str, size: (u32, u32)) -> String {
    format!("{{\"path\": {}, \"json\": {}, \"size\": [{}, {}]}}", quoted(path), quoted(json), size.0, size.1)
}

/// Why a long screenshot stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stopped {
    /// It scrolled the pages it was asked for.
    Pages,
    /// The page stopped moving.
    Bottom,
    /// The picture reached the height limit.
    Limit,
}

/// The answer to `long`. `tiles` are full paths, each with its `y` and
/// height in the whole picture.
pub fn long_json(
    path: &str,
    json: &str,
    size: (u32, u32),
    tiles: &[(String, u32, u32)],
    pages: u32,
    stopped: Stopped,
) -> String {
    let tiles: Vec<String> = tiles
        .iter()
        .map(|(image, y, h)| format!("{{\"image\": {}, \"y\": {y}, \"height\": {h}}}", quoted(image)))
        .collect();
    let stopped = match stopped {
        Stopped::Pages => "pages",
        Stopped::Bottom => "bottom",
        Stopped::Limit => "limit",
    };
    format!(
        "{{\"path\": {}, \"json\": {}, \"size\": [{}, {}], \"tiles\": [{}], \"pages\": {pages}, \"stopped\": \"{stopped}\"}}",
        quoted(path),
        quoted(json),
        size.0,
        size.1,
        tiles.join(", ")
    )
}

// ---------------------------------------------------------------- previous

/// The file name of the last shot of the same window: among `earlier` --
/// `(image file name, app, title)` read from the sidecars in the directory --
/// the latest one named before `image` whose app and title are both `app`
/// and `title`. **Both must be known**: a shot whose app or title could not
/// be read is not "the same window" as anything, and two windows that both
/// have no title are not each other.
pub fn previous(
    earlier: &[(String, Option<String>, Option<String>)],
    image: &str,
    app: Option<&str>,
    title: Option<&str>,
) -> Option<String> {
    let (app, title) = (app.filter(|a| !a.is_empty())?, title.filter(|t| !t.is_empty())?);
    let (app, title) = (Some(app), Some(title));
    earlier
        .iter()
        .filter(|(name, a, t)| name.as_str() < image && a.as_deref() == app && t.as_deref() == title)
        .map(|(name, _, _)| name.as_str())
        .max()
        .map(str::to_owned)
}

/// The app and title a sidecar records for its shot, for [`previous`], with
/// the image's file name. `None` for text that is not a sidecar.
pub fn identity(sidecar: &str) -> Option<(String, Option<String>, Option<String>)> {
    let v: serde_json::Value = serde_json::from_str(sidecar).ok()?;
    let text = |x: &serde_json::Value| x.as_str().filter(|s| !s.is_empty()).map(str::to_owned);
    Some((text(&v["image"])?, text(&v["source"]["app"]), text(&v["source"]["title"])))
}

/// The sidecar of an annotated copy (§10.1): the original's `source`,
/// `display`, `scale` and `redacted` carried over as they are, its
/// annotations followed by the new ones, `by` the agent, `previous` the
/// original image. `original` is the original's sidecar, when it has one.
pub fn annotated_sidecar(
    original: Option<&str>,
    original_image: &str,
    meta: &crate::annot::Meta,
    new_items: &[Item],
) -> String {
    let fresh = crate::annot::sidecar(meta, new_items);
    // No sidecar beside the original (a pasted image), or one that does not
    // parse: nothing is carried over, and nothing is made up in its place.
    let old = original
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        .unwrap_or(serde_json::Value::Null);
    // Start from the document this crate writes for the new file, and put
    // the original's parts into it.
    let mut doc: serde_json::Value = match serde_json::from_str(&fresh) {
        Ok(d) => d,
        Err(_) => return fresh,
    };
    for key in ["source", "display", "scale", "redacted", "appearance"] {
        match old.get(key) {
            Some(v) if !v.is_null() => doc[key] = v.clone(),
            _ => {
                if let Some(map) = doc.as_object_mut() {
                    // What the original did not record, the copy does not
                    // invent -- except the scale, which every sidecar has.
                    if key != "scale" {
                        map.remove(key);
                    }
                }
            }
        }
    }
    let mut annotations = old["annotations"].as_array().cloned().unwrap_or_default();
    annotations.extend(doc["annotations"].as_array().cloned().unwrap_or_default());
    doc["annotations"] = serde_json::Value::Array(annotations);
    doc["previous"] = serde_json::Value::String(original_image.to_string());
    serde_json::to_string_pretty(&doc).map(|s| s + "\n").unwrap_or(fresh)
}

/// `terminal.git` (screenshot.md §11) from what git printed: `head` is
/// `git rev-parse HEAD`'s answer cut to its first seven characters, the
/// same on both hosts whatever `core.abbrev` says; `changes` is `git status
/// --porcelain --untracked-files=no`, so the tree is dirty when a tracked
/// file differs and not because a file nobody added is lying in it. `None`
/// when `head` is no commit id.
pub fn git_state(head: &str, changes: &str) -> Option<(String, bool)> {
    let head = head.trim();
    if head.len() < 7 || !head.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    // An untracked line, should one be given anyway, is not a change.
    let dirty = changes.lines().any(|l| !l.trim().is_empty() && !l.starts_with("??"));
    Some((head[..7].to_string(), dirty))
}

/// The terminal id as the agent tools write it: `0x` and sixteen hex digits.
/// The core answers 0 for "no terminal", and that is no id at all.
pub fn terminal_id(raw: u64) -> Option<String> {
    (raw != 0).then(|| format!("0x{raw:016x}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annot::{By, Meta, Source};
    use crate::name::Stamp;

    struct Fake;
    impl Measure for Fake {
        fn text(&self, text: &str, font_px: i32) -> (i32, i32) {
            (text.chars().count() as i32 * 10, font_px)
        }
    }

    /// The primary 2560x1440 at 100%, and a 3840x2160 at 200% to its left.
    fn displays() -> Vec<DisplayInfo> {
        ordered(vec![
            DisplayInfo { rect: Rect::new(-3840, -200, 3840, 2160), scale: 2.0, primary: false },
            DisplayInfo { rect: Rect::new(0, 0, 2560, 1440), scale: 1.0, primary: true },
        ])
    }

    fn window(id: u64, rect: Rect) -> WindowInfo {
        WindowInfo { id, app: Some("notepad".into()), title: Some(format!("w{id}")), pid: Some(100 + id as u32), rect }
    }

    #[test]
    fn the_primary_display_is_index_zero_however_it_was_enumerated() {
        let d = displays();
        assert!(d[0].primary);
        assert_eq!(d[0].rect, Rect::new(0, 0, 2560, 1440));
        assert_eq!(d[1].rect.x, -3840);
        // Already first: nothing moves; the others keep their order.
        let three = ordered(vec![
            DisplayInfo { rect: Rect::new(0, 0, 10, 10), scale: 1.0, primary: false },
            DisplayInfo { rect: Rect::new(10, 0, 10, 10), scale: 1.0, primary: false },
            DisplayInfo { rect: Rect::new(20, 0, 10, 10), scale: 1.0, primary: true },
        ]);
        assert_eq!(three.iter().map(|d| d.rect.x).collect::<Vec<_>>(), [20, 0, 10]);
    }

    #[test]
    fn each_request_is_read() {
        assert_eq!(parse(r#"{"op": "directory"}"#), Ok(Request::Directory));
        assert_eq!(parse(r#"{"op": "windows"}"#), Ok(Request::Windows));
        let capture = parse(
            r##"{"op": "capture", "target": {"kind": "region", "display": 1, "rect": [10, 20, 300, 200]},
                "annotations": [{"type": "mosaic", "rect": [0, 0, 50, 50], "block": 12}],
                "meta": {"by": "agent", "agent_terminal": "0xa1", "terminal": {"id": "0xa1", "cwd": "/w"}}}"##,
        )
        .unwrap();
        let Request::Capture { target, annotations, caller } = capture else { panic!("not a capture") };
        assert_eq!(target, Target::Region { display: 1, rect: Rect::new(10, 20, 300, 200) });
        assert_eq!(annotations.len(), 1);
        assert_eq!(caller, Caller { agent_terminal: "0xa1".into(), terminal: Some(("0xa1".into(), Some("/w".into()))) });

        let targets = [
            (r#"{"kind": "display", "index": 0}"#, Target::Display { index: 0 }),
            (r#"{"kind": "window", "window_id": 123}"#, Target::Window { id: 123 }),
            (r#"{"kind": "terminal"}"#, Target::Terminal),
        ];
        for (text, expected) in targets {
            let r = parse(&format!(r#"{{"op": "capture", "target": {text}, "annotations": [], "meta": {{}}}}"#));
            assert!(matches!(r, Ok(Request::Capture { target, .. }) if target == expected), "{text}");
        }
        let annotate = parse(r#"{"op": "annotate", "path": "C:\\s\\a.png", "annotations": [], "meta": {}}"#).unwrap();
        assert!(matches!(annotate, Request::Annotate { ref path, .. } if path == "C:\\s\\a.png"));
        let long = parse(r#"{"op": "long", "target": {"kind": "window", "window_id": 5}, "pages": 3, "meta": {}}"#);
        assert!(matches!(long, Ok(Request::Long { target: Target::Window { id: 5 }, pages: 3, .. })));
    }

    #[test]
    fn a_request_the_host_cannot_read_is_refused_not_guessed_at() {
        for spec in [
            "not json",
            r#"{"op": "erase"}"#,
            r#"{"op": "capture", "target": {"kind": "moon"}}"#,
            r#"{"op": "capture", "target": {"kind": "region", "display": 0, "rect": [1, 2, 3]}}"#,
            r#"{"op": "capture", "target": {"kind": "window"}}"#,
            r#"{"op": "annotate", "annotations": []}"#,
            r#"{"op": "long", "target": {"kind": "display", "index": 0}, "pages": 2}"#,
            r#"{"op": "long", "target": {"kind": "terminal"}, "pages": 2}"#,
            r#"{"op": "long", "target": {"kind": "window", "window_id": 5}, "pages": 0}"#,
            r#"{"op": "long", "target": {"kind": "window", "window_id": 5}, "pages": 21}"#,
            r#"{"op": "long", "target": {"kind": "window", "window_id": 5}}"#,
        ] {
            let r = parse(spec);
            assert!(matches!(&r, Err(e) if e.code == "BadRequest"), "{spec}: {r:?}");
        }
        let refusal = parse("{").unwrap_err();
        let v: serde_json::Value = serde_json::from_str(&refusal.json()).unwrap();
        assert_eq!(v["code"], "BadRequest");
        assert!(v["message"].as_str().unwrap().contains("not JSON"));
    }

    #[test]
    fn a_target_becomes_a_rectangle_on_one_display() {
        let d = displays();
        let w = [window(7, Rect::new(100, 100, 800, 600)), window(8, Rect::new(-3000, 0, 1000, 500))];
        assert_eq!(resolve(Target::Display { index: 0 }, &d, &w, None), Ok((0, Rect::new(0, 0, 2560, 1440))));
        assert_eq!(resolve(Target::Display { index: 1 }, &d, &w, None), Ok((1, Rect::new(-3840, -200, 3840, 2160))));
        assert_eq!(resolve(Target::Window { id: 7 }, &d, &w, None), Ok((0, Rect::new(100, 100, 800, 600))));
        assert_eq!(resolve(Target::Window { id: 8 }, &d, &w, None), Ok((1, Rect::new(-3000, 0, 1000, 500))));
        // A region is in its display's own pixels.
        let region = Target::Region { display: 1, rect: Rect::new(10, 20, 300, 200) };
        assert_eq!(resolve(region, &d, &w, None), Ok((1, Rect::new(-3830, -180, 300, 200))));
        // The terminal's window, when the host found one.
        assert_eq!(resolve(Target::Terminal, &d, &w, Some(7)), Ok((0, Rect::new(100, 100, 800, 600))));
    }

    #[test]
    fn a_window_or_region_running_off_its_display_is_cut_to_it() {
        let d = displays();
        // Centre on the primary, left part hanging onto the other display.
        let w = [window(7, Rect::new(-200, 100, 1000, 600))];
        assert_eq!(resolve(Target::Window { id: 7 }, &d, &w, None), Ok((0, Rect::new(0, 100, 800, 600))));
        let region = Target::Region { display: 0, rect: Rect::new(2500, 1400, 500, 500) };
        assert_eq!(resolve(region, &d, &w, None), Ok((0, Rect::new(2500, 1400, 60, 40))));
    }

    #[test]
    fn what_is_not_there_is_refused_by_name() {
        let d = displays();
        let w = [window(7, Rect::new(100, 100, 800, 600))];
        let code = |t| resolve(t, &d, &w, None).unwrap_err().code;
        assert_eq!(code(Target::Display { index: 2 }), "NoSuchDisplay");
        assert_eq!(code(Target::Window { id: 99 }), "NoSuchWindow");
        assert_eq!(code(Target::Terminal), "NoSuchWindow");
        assert_eq!(code(Target::Region { display: 5, rect: Rect::new(0, 0, 10, 10) }), "NoSuchDisplay");
        assert_eq!(code(Target::Region { display: 0, rect: Rect::new(5000, 0, 10, 10) }), "BadRegion");
        assert_eq!(code(Target::Region { display: 0, rect: Rect::new(0, 0, 0, 10) }), "BadRegion");
        // A window wholly off every display (minimised windows report so).
        let off = [window(7, Rect::new(-32000, -32000, 160, 28))];
        assert_eq!(resolve(Target::Window { id: 7 }, &d, &off, None).unwrap_err().code, "BadRegion");
    }

    #[test]
    fn shielded_panes_are_blacked_out_where_they_reach_into_the_capture() {
        let capture = Rect::new(100, 100, 800, 600);
        let panes = [
            Rect::new(200, 200, 300, 200),  // inside
            Rect::new(50, 50, 100, 100),    // over the top-left corner
            Rect::new(2000, 2000, 50, 50),  // elsewhere
            Rect::new(100, 700, 800, 10),   // just below: touches nothing
        ];
        assert_eq!(redactions(&panes, capture), [Rect::new(100, 100, 300, 200), Rect::new(0, 0, 50, 50)]);
        assert!(redactions(&[], capture).is_empty());
    }

    #[test]
    fn annotations_arrive_in_image_pixels_and_are_moved_to_the_screen() {
        let raw = match parse(
            r##"{"op": "capture", "target": {"kind": "display", "index": 0}, "meta": {}, "annotations": [
                {"type": "rect", "rect": [10, 20, 30, 40], "color": "#E62828", "width": 2},
                {"type": "ellipse", "rect": [1, 2, 3, 4], "color": "#123456", "width": 10},
                {"type": "line", "from": [0, 0], "to": [5, 5], "color": "#FFFFFF", "width": 1},
                {"type": "arrow", "from": [0, 0], "to": [5, 5], "color": "#2F6FED", "width": 4},
                {"type": "pen", "points": [[1, 1], [2, 2], [3, 1]], "color": "#E62828", "width": 6},
                {"type": "highlighter", "points": [[1, 1], [9, 1]], "color": "#FFD400", "width": 4},
                {"type": "text", "at": [7, 8], "text": "héllo\r\nworld", "color": "#1A1A1A", "font_size": 24},
                {"type": "number", "n": 3, "at": [9, 9], "text": "", "color": "#E62828", "font_size": 14},
                {"type": "mosaic", "rect": [0, 0, 64, 64], "block": 32}
            ]}"##,
        )
        .unwrap()
        {
            Request::Capture { annotations, .. } => annotations,
            other => panic!("{other:?}"),
        };
        let got = items(&raw, Point::new(100, 1000), 2.0, &Fake).unwrap();
        let it = |shape, colour, level, rgb| Item { shape, colour, level, rgb };
        let p = Point::new;
        assert_eq!(got[0], it(Shape::Rect(Rect::new(110, 1020, 30, 40)), 0, 1, None));
        assert_eq!(got[1], it(Shape::Ellipse(Rect::new(101, 1002, 3, 4)), 0, 4, Some((0x12, 0x34, 0x56))), "any colour");
        assert_eq!(got[2], it(Shape::Line { from: p(100, 1000), to: p(105, 1005) }, 8, 0, None));
        assert_eq!(got[3], it(Shape::Arrow { from: p(100, 1000), to: p(105, 1005) }, 5, 2, None));
        assert_eq!(got[4], it(Shape::Pen(vec![p(101, 1001), p(102, 1002), p(103, 1001)]), 0, 3, None));
        assert_eq!(got[5], it(Shape::Highlighter(vec![p(101, 1001), p(109, 1001)]), 2, 2, None));
        // 24 pt at 200% is 48 px; the measurer was asked at that size.
        let text = Shape::Text { at: p(107, 1008), text: "héllo\nworld".into(), size: (110, 48) };
        assert_eq!(got[6], it(text, 7, 2, None));
        assert_eq!(got[7], it(Shape::Number { n: 3, at: p(109, 1009), text: String::new(), size: (0, 0) }, 0, 0, None));
        assert_eq!(got[8], it(Shape::Mosaic(Rect::new(100, 1000, 64, 64)), 0, 4, None));
    }

    #[test]
    fn an_annotation_that_is_not_what_the_contract_says_is_refused() {
        let one = |text: &str| {
            let v: serde_json::Value = serde_json::from_str(text).unwrap();
            items(&[Raw(v)], Point::new(0, 0), 1.0, &Fake)
        };
        for text in [
            r##"{"type": "rect", "rect": [1, 2, 3, 4], "color": "#E62828", "width": 3}"##,
            r##"{"type": "rect", "rect": [1, 2, 3, 4], "color": "red", "width": 2}"##,
            r##"{"type": "rect", "rect": [1, 2, 3, 4], "color": "#E6282", "width": 2}"##,
            r##"{"type": "rect", "rect": [1, 2, 3], "color": "#E62828", "width": 2}"##,
            r##"{"type": "text", "at": [1, 2], "text": "x", "color": "#E62828", "font_size": 15}"##,
            r##"{"type": "pen", "points": [[1, 1]], "color": "#E62828", "width": 2}"##,
            r##"{"type": "mosaic", "rect": [1, 2, 3, 4], "block": 10}"##,
            r##"{"type": "number", "at": [1, 2], "text": "", "color": "#E62828", "font_size": 14}"##,
            r##"{"type": "blur", "rect": [1, 2, 3, 4]}"##,
        ] {
            let r = one(text);
            assert!(matches!(&r, Err(e) if e.code == "BadRequest"), "{text}: {r:?}");
        }
        // A mosaic needs no colour.
        assert!(one(r#"{"type": "mosaic", "rect": [1, 2, 3, 4], "block": 8}"#).is_ok());
    }

    #[test]
    fn the_windows_answer_is_in_each_displays_own_pixels() {
        let d = displays();
        let w = [
            window(7, Rect::new(100, 100, 800, 600)),
            WindowInfo { id: 8, app: None, title: Some(String::new()), pid: None, rect: Rect::new(-3000, 0, 1000, 500) },
        ];
        let v: serde_json::Value = serde_json::from_str(&windows_json(&d, &w, 65536)).unwrap();
        assert_eq!(
            v["displays"],
            serde_json::json!([
                {"index": 0, "size": [2560, 1440], "scale": 1.0, "primary": true},
                {"index": 1, "size": [3840, 2160], "scale": 2.0, "primary": false}
            ])
        );
        assert_eq!(
            v["windows"][0],
            serde_json::json!({"window_id": 7, "app": "notepad", "title": "w7", "pid": 107, "display": 0, "rect": [100, 100, 800, 600]})
        );
        // On the left display, whose origin is (-3840, -200); what is
        // unknown is left out.
        assert_eq!(v["windows"][1], serde_json::json!({"window_id": 8, "display": 1, "rect": [840, 200, 1000, 500]}));
        assert!(v.get("truncated").is_none());
    }

    #[test]
    fn a_list_too_long_for_the_buffer_is_cut_and_says_so_and_still_parses() {
        let d = displays();
        let many: Vec<WindowInfo> = (0..400).map(|i| window(i, Rect::new(10, 10, 100, 100))).collect();
        let whole = windows_json(&d, &many, usize::MAX);
        assert!(whole.len() > 4096);
        let cut = windows_json(&d, &many, 4096);
        assert!(cut.len() <= 4096);
        let v: serde_json::Value = serde_json::from_str(&cut).expect("a cut answer is still JSON");
        assert_eq!(v["truncated"], true);
        let kept = v["windows"].as_array().unwrap().len();
        assert!(kept > 0 && kept < 400);
        assert_eq!(v["windows"][0]["window_id"], 0, "cut from the back: the front-most stay");
        assert_eq!(v["displays"].as_array().unwrap().len(), 2);
        // A buffer too small for even one window still gets a document.
        let none: serde_json::Value = serde_json::from_str(&windows_json(&d, &many, 10)).unwrap();
        assert_eq!(none["windows"].as_array().unwrap().len(), 0);
        assert_eq!(none["truncated"], true);
    }

    #[test]
    fn the_capture_and_long_answers_are_the_specified_documents() {
        let c: serde_json::Value = serde_json::from_str(&capture_json("C:\\s\\a.png", "C:\\s\\a.json", (800, 600))).unwrap();
        assert_eq!(c, serde_json::json!({"path": "C:\\s\\a.png", "json": "C:\\s\\a.json", "size": [800, 600]}));
        let tiles = [("C:\\s\\a-1.png".to_string(), 0, 1800), ("C:\\s\\a-2.png".to_string(), 1680, 900)];
        let l: serde_json::Value =
            serde_json::from_str(&long_json("C:\\s\\a.png", "C:\\s\\a.json", (800, 2580), &tiles, 2, Stopped::Bottom)).unwrap();
        assert_eq!(l["tiles"][1], serde_json::json!({"image": "C:\\s\\a-2.png", "y": 1680, "height": 900}));
        assert_eq!((l["pages"].as_u64(), l["stopped"].as_str()), (Some(2), Some("bottom")));
        assert_eq!(serde_json::from_str::<serde_json::Value>(&directory_json("C:\\a b\\shots")).unwrap()["directory"], "C:\\a b\\shots");
        for (s, word) in [(Stopped::Pages, "pages"), (Stopped::Limit, "limit")] {
            assert!(long_json("p", "j", (1, 1), &[], 1, s).contains(&format!("\"stopped\": \"{word}\"")));
        }
    }

    #[test]
    fn the_previous_shot_is_the_latest_earlier_one_of_the_same_window() {
        let e = |name: &str, app: &str, title: &str| (name.to_string(), Some(app.to_string()), Some(title.to_string()));
        let earlier = vec![
            e("20261006-100000-000.png", "chrome", "Docs"),
            e("20261006-110000-000.png", "chrome", "Docs"),
            e("20261006-113000-000.png", "chrome", "Mail"),
            e("20261006-130000-000.png", "chrome", "Docs"),
            ("20261006-114000-000.png".to_string(), None, None),
        ];
        let p = |image: &str, app, title| previous(&earlier, image, app, title);
        assert_eq!(p("20261006-120000-000.png", Some("chrome"), Some("Docs")), Some("20261006-110000-000.png".into()));
        assert_eq!(p("20261006-120000-000.png", Some("chrome"), Some("Mail")), Some("20261006-113000-000.png".into()));
        assert_eq!(p("20261006-120000-000.png", Some("notepad"), Some("Docs")), None);
        assert_eq!(p("20261006-090000-000.png", Some("chrome"), Some("Docs")), None, "nothing earlier");
        assert_eq!(p("20261006-120000-000.png", None, None), None, "a region is not the same window as another region");
    }

    #[test]
    fn a_window_with_no_title_is_not_the_same_window_as_another_with_none() {
        let earlier = vec![
            ("20261006-100000-000.png".to_string(), Some("chrome".to_string()), None),
            ("20261006-101000-000.png".to_string(), Some("chrome".to_string()), Some(String::new())),
            ("20261006-102000-000.png".to_string(), None, Some("Docs".to_string())),
        ];
        let p = |app, title| previous(&earlier, "20261006-120000-000.png", app, title);
        assert_eq!(p(Some("chrome"), None), None);
        assert_eq!(p(Some("chrome"), Some("")), None);
        assert_eq!(p(None, Some("Docs")), None);
        assert_eq!(p(Some(""), Some("Docs")), None);
    }

    #[test]
    fn a_sidecars_identity_is_read_back() {
        let text = r#"{"version": 2, "image": "20261006-100000-000.png", "source": {"kind": "window", "app": "chrome", "title": "Docs"}}"#;
        assert_eq!(identity(text), Some(("20261006-100000-000.png".into(), Some("chrome".into()), Some("Docs".into()))));
        let region = r#"{"image": "a.png", "source": {"kind": "region"}}"#;
        assert_eq!(identity(region), Some(("a.png".into(), None, None)));
        assert_eq!(identity("not json"), None);
        assert_eq!(identity("{}"), None);
    }

    fn meta() -> Meta {
        Meta {
            image: "20261006-120000-000.png".into(),
            taken: Stamp { year: 2026, month: 10, day: 6, hour: 12, minute: 0, second: 0, milli: 0 },
            utc_offset_minutes: 480,
            size: (800, 600),
            scale: 1.0,
            by: By::Agent { terminal: "0xa1".into() },
            display: None,
            appearance: None,
            source: Source::Region { selection_rect: Rect::new(0, 0, 800, 600) },
            terminal: None,
            previous: None,
            tiles: Vec::new(),
            redacted: Vec::new(),
        }
    }

    #[test]
    fn an_annotated_copy_carries_the_originals_record_and_adds_to_it() {
        let original = r##"{
          "version": 2, "image": "20261006-110000-000.png", "scale": 1.5, "by": "user",
          "display": {"index": 1, "size": [3840, 2160], "scale": 1.5},
          "source": {"kind": "window", "app": "chrome", "title": "Docs", "selection_rect": [5, 6, 800, 600]},
          "redacted": [[10, 10, 50, 50]],
          "annotations": [{"type": "rect", "rect": [1, 2, 3, 4], "text": "", "color": "#E62828", "width": 2}]
        }"##;
        let new = [Item { shape: Shape::Mosaic(Rect::new(0, 0, 40, 40)), colour: 0, level: 1, rgb: None }];
        let text = annotated_sidecar(Some(original), "20261006-110000-000.png", &meta(), &new);
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["image"], "20261006-120000-000.png");
        assert_eq!(v["by"], "agent");
        assert_eq!(v["agent_terminal"], "0xa1");
        assert_eq!(v["previous"], "20261006-110000-000.png");
        assert_eq!(v["scale"], 1.5);
        assert_eq!(v["source"]["app"], "chrome");
        assert_eq!(v["source"]["selection_rect"], serde_json::json!([5, 6, 800, 600]));
        assert_eq!(v["display"]["index"], 1);
        assert_eq!(v["redacted"], serde_json::json!([[10, 10, 50, 50]]), "what was blacked out stays on record");
        let a = v["annotations"].as_array().unwrap();
        assert_eq!(a.len(), 2);
        assert_eq!((a[0]["type"].as_str(), a[1]["type"].as_str()), (Some("rect"), Some("mosaic")));
    }

    #[test]
    fn an_annotated_copy_of_a_picture_with_no_sidecar_does_not_invent_one() {
        let new = [Item { shape: Shape::Mosaic(Rect::new(0, 0, 40, 40)), colour: 0, level: 1, rgb: None }];
        for original in [None, Some("not json")] {
            let v: serde_json::Value =
                serde_json::from_str(&annotated_sidecar(original, "20261006-110000-000.png", &meta(), &new)).unwrap();
            assert_eq!(v["annotations"].as_array().unwrap().len(), 1);
            assert_eq!(v["by"], "agent");
            assert_eq!(v["previous"], "20261006-110000-000.png");
            assert!(v.get("source").is_none(), "what the picture is of was never recorded, so it is not stated");
            assert!(v.get("display").is_none());
            assert_eq!(v["scale"], 1.0);
        }
        // A sidecar with no display and no redaction: the copy has neither.
        let bare = r#"{"version": 2, "image": "a.png", "scale": 2.0, "source": {"kind": "region"}, "annotations": []}"#;
        let v: serde_json::Value = serde_json::from_str(&annotated_sidecar(Some(bare), "a.png", &meta(), &new)).unwrap();
        assert!(v.get("display").is_none() && v.get("redacted").is_none());
        assert_eq!(v["source"], serde_json::json!({"kind": "region"}));
        assert_eq!(v["scale"], 2.0);
    }

    #[test]
    fn a_terminal_id_is_sixteen_hex_digits_and_zero_is_none() {
        assert_eq!(terminal_id(0), None);
        assert_eq!(terminal_id(0xa1).as_deref(), Some("0x00000000000000a1"));
        assert_eq!(terminal_id(0x17e4d641c31cf7f6).as_deref(), Some("0x17e4d641c31cf7f6"));
    }

    #[test]
    fn git_is_seven_characters_of_head_and_dirty_only_for_tracked_files() {
        let full = "75d681dbc0123456789abcdef0123456789abcde\n";
        assert_eq!(git_state(full, ""), Some(("75d681d".into(), false)));
        assert_eq!(git_state(full, " M windows/host/src/shot.rs\n"), Some(("75d681d".into(), true)));
        assert_eq!(git_state(full, "A  new.rs\n"), Some(("75d681d".into(), true)));
        // Untracked files alone do not make the tree dirty.
        assert_eq!(git_state(full, "?? notes.txt\n?? tmp/\n"), Some(("75d681d".into(), false)));
        assert_eq!(git_state(full, "?? notes.txt\n M a.rs\n"), Some(("75d681d".into(), true)));
        assert_eq!(git_state(full, "\n  \n"), Some(("75d681d".into(), false)));
        // A longer abbreviation is cut to seven as well; less than seven, or
        // not a commit id, is no answer.
        assert_eq!(git_state("75d681dbc", ""), Some(("75d681d".into(), false)));
        assert_eq!(git_state("75d681", ""), None);
        assert_eq!(git_state("", " M a.rs"), None);
        assert_eq!(git_state("fatal: not a git repository", ""), None);
    }
}
