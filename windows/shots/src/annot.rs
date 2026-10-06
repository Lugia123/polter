//! Annotations as data: the sidecar `.json` beside a shot, and the one line of
//! text pasted after the image's path.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md` §4. The point of both
//! is that what the person wrote and where they pointed reaches the program
//! as text, not as pixels to be read back out of the picture.

use crate::geom::{Point, Rect};
use crate::name::Stamp;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Annotation {
    /// A numbered circle, with the sentence typed after placing it.
    Number { n: u32, at: Point, text: String },
    /// A hollow rectangle.
    Rect { rect: Rect },
    Arrow { from: Point, to: Point },
    Text { at: Point, text: String },
    /// A freehand line.
    Pen { points: Vec<Point> },
}

impl Annotation {
    /// The same annotation in a space whose origin is `origin`: how marks
    /// made on the screen become marks on the image.
    pub fn relative_to(&self, origin: Point) -> Annotation {
        match self {
            Annotation::Number { n, at, text } => {
                Annotation::Number { n: *n, at: at.relative_to(origin), text: text.clone() }
            }
            Annotation::Rect { rect } => Annotation::Rect { rect: rect.relative_to(origin) },
            Annotation::Arrow { from, to } => {
                Annotation::Arrow { from: from.relative_to(origin), to: to.relative_to(origin) }
            }
            Annotation::Text { at, text } => Annotation::Text { at: at.relative_to(origin), text: text.clone() },
            Annotation::Pen { points } => {
                Annotation::Pen { points: points.iter().map(|p| p.relative_to(origin)).collect() }
            }
        }
    }
}

/// The number the next [`Annotation::Number`] gets: one more than the highest
/// there is, so undoing ③ makes the next one ③ again.
pub fn next_number(items: &[Annotation]) -> u32 {
    items.iter().filter_map(|a| if let Annotation::Number { n, .. } = a { Some(*n) } else { None }).max().unwrap_or(0)
        + 1
}

/// The smallest rectangle holding every point, both ends included. `None`
/// for no points.
pub fn bbox(points: &[Point]) -> Option<Rect> {
    let first = points.first()?;
    let (mut l, mut t, mut r, mut b) = (first.x, first.y, first.x, first.y);
    for p in points {
        l = l.min(p.x);
        t = t.min(p.y);
        r = r.max(p.x);
        b = b.max(p.y);
    }
    Some(Rect::from_ltrb(l, t, r + 1, b + 1))
}

/// What a shot is of.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// A window chosen by clicking it. Either name may be unknown.
    Window { app: Option<String>, title: Option<String> },
    /// A free selection.
    Region,
}

/// Everything in the sidecar that is not an annotation.
#[derive(Clone, Debug, PartialEq)]
pub struct Meta {
    /// The image's file name, without a directory.
    pub image: String,
    /// Local time the shot was taken.
    pub taken: Stamp,
    /// The local time zone's offset from UTC in minutes, east positive.
    pub utc_offset_minutes: i32,
    /// The image's width and height in pixels.
    pub size: (u32, u32),
    /// The monitor's scale factor: its DPI over 96.
    pub scale: f64,
    pub source: Source,
}

fn quoted(s: &str) -> String {
    // `to_string` on a `&str` cannot fail; the fallback is never taken.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn taken_at(t: &Stamp, offset_minutes: i32) -> String {
    let sign = if offset_minutes < 0 { '-' } else { '+' };
    let off = offset_minutes.unsigned_abs();
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}{:02}:{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second, sign, off / 60, off % 60
    )
}

/// The sidecar `.json`, version 1. `items` are in image pixels.
///
/// Keys are written in the specification's order, which is why this is
/// assembled by hand; every string goes through `serde_json` for escaping.
/// A window's `app` or `title` that is unknown **or empty** is left out, not
/// written as `""`.
pub fn sidecar(meta: &Meta, items: &[Annotation]) -> String {
    let mut source = String::from("{\"kind\": ");
    match &meta.source {
        Source::Region => source.push_str("\"region\""),
        Source::Window { app, title } => {
            source.push_str("\"window\"");
            for (key, value) in [("app", app), ("title", title)] {
                if let Some(v) = value.as_deref().filter(|v| !v.is_empty()) {
                    source.push_str(&format!(", \"{key}\": {}", quoted(v)));
                }
            }
        }
    }
    source.push('}');

    let lines: Vec<String> = items
        .iter()
        .map(|a| match a {
            Annotation::Number { n, at, text } => format!(
                "{{\"n\": {n}, \"type\": \"number\", \"at\": [{}, {}], \"text\": {}}}",
                at.x, at.y, quoted(text)
            ),
            Annotation::Rect { rect: r } => format!(
                "{{\"type\": \"rect\", \"rect\": [{}, {}, {}, {}], \"text\": \"\"}}",
                r.x, r.y, r.w, r.h
            ),
            Annotation::Arrow { from, to } => format!(
                "{{\"type\": \"arrow\", \"from\": [{}, {}], \"to\": [{}, {}]}}",
                from.x, from.y, to.x, to.y
            ),
            Annotation::Text { at, text } => {
                format!("{{\"type\": \"text\", \"at\": [{}, {}], \"text\": {}}}", at.x, at.y, quoted(text))
            }
            Annotation::Pen { points } => {
                let r = bbox(points).unwrap_or(Rect::new(0, 0, 0, 0));
                format!("{{\"type\": \"pen\", \"bbox\": [{}, {}, {}, {}]}}", r.x, r.y, r.w, r.h)
            }
        })
        .collect();
    let annotations =
        if lines.is_empty() { "[]".to_string() } else { format!("[\n    {}\n  ]", lines.join(",\n    ")) };

    // `{:?}` on an `f64` always shows a fraction: 2.0, 1.25.
    let scale = if meta.scale.is_finite() && meta.scale > 0.0 { meta.scale } else { 1.0 };
    format!(
        "{{\n  \"version\": 1,\n  \"image\": {},\n  \"taken_at\": {},\n  \"size\": [{}, {}],\n  \
         \"scale\": {:?},\n  \"source\": {},\n  \"annotations\": {}\n}}\n",
        quoted(&meta.image),
        quoted(&taken_at(&meta.taken, meta.utc_offset_minutes)),
        meta.size.0,
        meta.size.1,
        scale,
        source,
        annotations
    )
}

/// The words of the pasted line, so each host can supply its own language.
///
/// **One field per msgid in `src/input/screenshot.zig`**, which is where the
/// two hosts' wording is kept the same; the comments give the English msgid
/// and the Chinese it is translated to.
#[derive(Clone, Copy, Debug)]
pub struct Labels<'a> {
    /// `Screenshot annotations` / `截图标注`
    pub header: &'a str,
    /// `Text` / `文字`
    pub text: &'a str,
    /// `Box` / `框`
    pub rect: &'a str,
    /// `Arrow` / `箭头`
    pub arrow: &'a str,
    /// `Pen` / `画笔`
    pub pen: &'a str,
    /// Between two annotations: `; ` / `；`
    pub separator: &'a str,
    /// After the last annotation and before the path: `. See ` / `。详见 `.
    /// Its spaces are part of it.
    pub see: &'a str,
}

/// The specification's own wording, as `po/zh_CN.po` has it.
pub const ZH: Labels<'static> = Labels {
    header: "截图标注",
    text: "文字",
    rect: "框",
    arrow: "箭头",
    pen: "画笔",
    separator: "；",
    see: "。详见 ",
};

/// The msgids themselves.
pub const EN: Labels<'static> = Labels {
    header: "Screenshot annotations",
    text: "Text",
    rect: "Box",
    arrow: "Arrow",
    pen: "Pen",
    separator: "; ",
    see: ". See ",
};

/// ①…⑳, then `(21)`.
fn circled(n: u32) -> String {
    match n {
        1..=20 => char::from_u32(0x2460 + n - 1).map(String::from).unwrap_or_default(),
        _ => format!("({n})"),
    }
}

/// `text` with every control character turned into a space.
///
/// **This is what keeps the line one line.** It is pasted at a prompt, and a
/// newline typed into a caption would otherwise submit half the line.
fn flat(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>().trim().to_string()
}

/// The one line pasted after the image's path, or `None` when there are no
/// annotations and so nothing to say. Shapes with no words still make a line:
/// where they are is the information.
///
/// `[截图标注 1280×800] ① (412,96) 这个按钮没对齐；文字 (60,500) 间距太大；框
/// (380,80,240,44)；箭头 (100,300)→(220,340)。详见 <json path>`
pub fn line(size: (u32, u32), items: &[Annotation], json_path: &str, l: &Labels) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let with = |head: String, text: &str| {
        let text = flat(text);
        if text.is_empty() {
            head
        } else {
            format!("{head} {text}")
        }
    };
    let parts: Vec<String> = items
        .iter()
        .map(|a| match a {
            Annotation::Number { n, at, text } => with(format!("{} ({},{})", circled(*n), at.x, at.y), text),
            Annotation::Text { at, text } => with(format!("{} ({},{})", l.text, at.x, at.y), text),
            Annotation::Rect { rect: r } => format!("{} ({},{},{},{})", l.rect, r.x, r.y, r.w, r.h),
            Annotation::Arrow { from, to } => {
                format!("{} ({},{})→({},{})", l.arrow, from.x, from.y, to.x, to.y)
            }
            Annotation::Pen { points } => {
                let r = bbox(points).unwrap_or(Rect::new(0, 0, 0, 0));
                format!("{} ({},{},{},{})", l.pen, r.x, r.y, r.w, r.h)
            }
        })
        .collect();
    Some(format!(
        "[{} {}×{}] {}{}{}",
        l.header,
        size.0,
        size.1,
        parts.join(l.separator),
        l.see,
        flat(json_path)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: fn(i32, i32) -> Point = Point::new;

    /// The specification's example, §4.1 and §4.2.
    fn example() -> Vec<Annotation> {
        vec![
            Annotation::Number { n: 1, at: P(412, 96), text: "这个按钮没对齐".into() },
            Annotation::Rect { rect: Rect::new(380, 80, 240, 44) },
            Annotation::Arrow { from: P(100, 300), to: P(220, 340) },
            Annotation::Text { at: P(60, 500), text: "间距太大".into() },
            Annotation::Pen { points: vec![P(10, 10), P(89, 30), P(40, 49)] },
        ]
    }

    fn meta(source: Source) -> Meta {
        Meta {
            image: "20261006-153012-123.png".into(),
            taken: Stamp { year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, milli: 123 },
            utc_offset_minutes: 480,
            size: (1280, 800),
            scale: 2.0,
            source,
        }
    }

    #[test]
    fn the_sidecar_is_the_specified_document() {
        let source = Source::Window { app: Some("Google Chrome".into()), title: Some("…".into()) };
        let expected = r#"{
  "version": 1,
  "image": "20261006-153012-123.png",
  "taken_at": "2026-10-06T15:30:12+08:00",
  "size": [1280, 800],
  "scale": 2.0,
  "source": {"kind": "window", "app": "Google Chrome", "title": "…"},
  "annotations": [
    {"n": 1, "type": "number", "at": [412, 96], "text": "这个按钮没对齐"},
    {"type": "rect", "rect": [380, 80, 240, 44], "text": ""},
    {"type": "arrow", "from": [100, 300], "to": [220, 340]},
    {"type": "text", "at": [60, 500], "text": "间距太大"},
    {"type": "pen", "bbox": [10, 10, 80, 40]}
  ]
}
"#;
        assert_eq!(sidecar(&meta(source), &example()), expected);
    }

    #[test]
    fn the_sidecar_parses_as_json_whatever_was_typed() {
        let nasty = "a \"quoted\" \\ back\nslash\tand } ] , \u{1}";
        let items = vec![
            Annotation::Text { at: P(1, 2), text: nasty.into() },
            Annotation::Number { n: 2, at: P(3, 4), text: nasty.into() },
        ];
        let source = Source::Window { app: Some(nasty.into()), title: Some(nasty.into()) };
        let v: serde_json::Value = serde_json::from_str(&sidecar(&meta(source), &items)).unwrap();
        assert_eq!(v["annotations"][0]["text"], nasty);
        assert_eq!(v["annotations"][1]["text"], nasty);
        assert_eq!(v["annotations"][1]["n"], 2);
        assert_eq!(v["source"]["app"], nasty);
        assert_eq!(v["source"]["title"], nasty);
        assert_eq!(v["version"], 1);
        assert_eq!(v["size"], serde_json::json!([1280, 800]));
    }

    #[test]
    fn a_window_name_that_is_unknown_or_empty_is_left_out() {
        let v = |source| -> serde_json::Value { serde_json::from_str(&sidecar(&meta(source), &[])).unwrap() };
        let w = v(Source::Window { app: None, title: Some(String::new()) });
        assert_eq!(w["source"], serde_json::json!({"kind": "window"}));
        let w = v(Source::Window { app: Some("notepad".into()), title: None });
        assert_eq!(w["source"], serde_json::json!({"kind": "window", "app": "notepad"}));
        let r = v(Source::Region);
        assert_eq!(r["source"], serde_json::json!({"kind": "region"}));
        assert_eq!(r["annotations"], serde_json::json!([]));
    }

    #[test]
    fn the_time_carries_its_offset_and_the_scale_its_fraction() {
        let mut m = meta(Source::Region);
        m.utc_offset_minutes = -210;
        m.scale = 1.25;
        let v: serde_json::Value = serde_json::from_str(&sidecar(&m, &[])).unwrap();
        assert_eq!(v["taken_at"], "2026-10-06T15:30:12-03:30");
        assert!(sidecar(&m, &[]).contains("\"scale\": 1.25,"));
        m.utc_offset_minutes = 0;
        m.scale = f64::NAN;
        assert!(sidecar(&m, &[]).contains("+00:00"));
        assert!(sidecar(&m, &[]).contains("\"scale\": 1.0,"));
    }

    #[test]
    fn marks_made_on_the_screen_land_on_the_image() {
        // The selection's top-left corner on a monitor left of the primary.
        let origin = P(-3000, 100);
        let on_screen = vec![
            Annotation::Number { n: 1, at: P(-2588, 196), text: "x".into() },
            Annotation::Rect { rect: Rect::new(-2620, 180, 240, 44) },
            Annotation::Arrow { from: P(-2900, 400), to: P(-2780, 440) },
            Annotation::Text { at: P(-2940, 600), text: "y".into() },
            Annotation::Pen { points: vec![P(-2990, 110), P(-2911, 149)] },
        ];
        let on_image: Vec<Annotation> = on_screen.iter().map(|a| a.relative_to(origin)).collect();
        assert_eq!(
            on_image,
            vec![
                Annotation::Number { n: 1, at: P(412, 96), text: "x".into() },
                Annotation::Rect { rect: Rect::new(380, 80, 240, 44) },
                Annotation::Arrow { from: P(100, 300), to: P(220, 340) },
                Annotation::Text { at: P(60, 500), text: "y".into() },
                Annotation::Pen { points: vec![P(10, 10), P(89, 49)] },
            ]
        );
    }

    #[test]
    fn the_line_is_the_specified_sentence() {
        // The specification's sentence lists the same marks in another order
        // and has no pen; this is its order of annotations, pen included.
        let got = line((1280, 800), &example(), r"C:\shots\20261006-153012-123.json", &ZH).unwrap();
        assert_eq!(
            got,
            "[截图标注 1280×800] ① (412,96) 这个按钮没对齐；框 (380,80,240,44)；\
             箭头 (100,300)→(220,340)；文字 (60,500) 间距太大；画笔 (10,10,80,40)。\
             详见 C:\\shots\\20261006-153012-123.json"
        );
    }

    #[test]
    fn the_line_in_english_is_the_one_the_core_documents() {
        // `src/input/screenshot.zig`'s own example, with its msgids.
        let items = [
            Annotation::Number { n: 1, at: P(412, 96), text: "misaligned".into() },
            Annotation::Text { at: P(60, 500), text: "too wide".into() },
            Annotation::Rect { rect: Rect::new(380, 80, 240, 44) },
            Annotation::Arrow { from: P(100, 300), to: P(220, 340) },
        ];
        assert_eq!(
            line((1280, 800), &items, "<json>", &EN).unwrap(),
            "[Screenshot annotations 1280×800] ① (412,96) misaligned; Text (60,500) too wide; \
             Box (380,80,240,44); Arrow (100,300)→(220,340). See <json>"
        );
    }

    #[test]
    fn no_annotations_is_no_line_but_shapes_without_words_are_one() {
        assert_eq!(line((10, 10), &[], "x.json", &ZH), None);
        let shapes = [Annotation::Rect { rect: Rect::new(1, 2, 3, 4) }];
        assert_eq!(line((10, 10), &shapes, "x.json", &ZH).unwrap(), "[截图标注 10×10] 框 (1,2,3,4)。详见 x.json");
    }

    #[test]
    fn a_caption_with_a_newline_in_it_does_not_break_the_line() {
        let items = [
            Annotation::Text { at: P(1, 2), text: "first\r\nsecond\tthird\u{1b}[0m".into() },
            Annotation::Number { n: 1, at: P(3, 4), text: "\n".into() },
        ];
        let got = line((10, 10), &items, "x.json", &ZH).unwrap();
        assert!(!got.chars().any(char::is_control), "{got:?}");
        assert_eq!(got, "[截图标注 10×10] 文字 (1,2) first  second third [0m；① (3,4)。详见 x.json");
    }

    #[test]
    fn numbers_are_circled_up_to_twenty() {
        let n = |n| Annotation::Number { n, at: P(0, 0), text: String::new() };
        let got = line((1, 1), &[n(2), n(20), n(21)], "j", &ZH).unwrap();
        assert_eq!(got, "[截图标注 1×1] ② (0,0)；⑳ (0,0)；(21) (0,0)。详见 j");
    }

    #[test]
    fn the_next_number_follows_the_highest_and_comes_back_after_an_undo() {
        let mut items = example();
        assert_eq!(next_number(&[]), 1);
        assert_eq!(next_number(&items), 2);
        items.push(Annotation::Number { n: 2, at: P(0, 0), text: String::new() });
        assert_eq!(next_number(&items), 3);
        items.pop();
        assert_eq!(next_number(&items), 2);
    }

    #[test]
    fn a_bounding_box_includes_both_ends() {
        assert_eq!(bbox(&[P(10, 10), P(89, 30), P(40, 49)]), Some(Rect::new(10, 10, 80, 40)));
        assert_eq!(bbox(&[P(5, 6)]), Some(Rect::new(5, 6, 1, 1)));
        assert_eq!(bbox(&[]), None);
    }
}
