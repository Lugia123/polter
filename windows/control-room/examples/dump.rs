//! Print what this crate makes of a snapshot, in the form
//! `tools/control-room-hosts-agree.py` compares with the macOS host's.
//!
//!     cargo run -q -p polter-control-room --example dump -- <snapshot.json> <height>
//!
//! One fact a line. The macOS side prints the same lines from
//! `ControlRoomList.swift`; any line that differs is the two hosts
//! disagreeing about what one snapshot looks like.

use polter_control_room::json::quote;
use polter_control_room::layout::{self, ListLayout, Rect};
use polter_control_room::list::{self, Detail, List, Row};
use polter_control_room::pulse::{self, Scope};
use polter_control_room::snapshot;

fn rect(name: &str, r: Rect) {
    println!("rect {name} x={:.3} y={:.3} w={:.3} h={:.3}", r.x, r.y, r.w, r.h);
}

fn row(section: &str, r: &Row) {
    // Untranslated on both sides: the sentence is the same English key
    // the macOS host starts from.
    let detail = match &r.detail {
        Detail::Reason(text) => text.clone(),
        Detail::SameAs(other) => list::fill(list::msg::SAME_SUPERVISOR, other),
    };
    let waited = r.waited_min.map_or("-".to_string(), |m| m.to_string());
    // The two moments go with the terminal: with no terminal behind the
    // row there is nothing an act would hand back.
    let since = r.terminal.as_ref().map_or("-".to_string(), |_| r.since_ms.to_string());
    let event = r.terminal.as_ref().and(r.event_ms).map_or("-".to_string(), |m| m.to_string());
    println!(
        "row section={section} id={} shown={} word={} detail={} code={} waited={waited} others={} \
         terminal={} since={since} event={event}",
        r.id,
        r.shown.name(),
        quote(&r.word),
        quote(&detail),
        r.detail_is_code,
        r.others,
        r.terminal.as_deref().unwrap_or("-")
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: dump <snapshot.json> <height>");
        std::process::exit(2);
    }
    let text = std::fs::read_to_string(&args[1]).expect("the snapshot can be read");
    let height: f64 = args[2].parse().expect("the height is a number");

    let snap = match snapshot::decode(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("the snapshot does not decode: {e:?}");
            std::process::exit(1);
        }
    };
    let l = List::from_snapshot(&snap);

    println!("count waiting={} quiet={}", l.waiting_count, l.quiet_count);
    for r in &l.waiting {
        row("waiting", r);
    }
    for r in &l.quiet {
        row("quiet", r);
    }

    // Which glyph breathes: with nothing in front, and with each tab that
    // holds a waiting terminal in front -- asked, as a host asks, with the
    // window that tab is in.
    let mut fronts: Vec<Option<(&str, Option<&str>)>> = vec![None];
    let mut windows: Vec<&str> = Vec::new();
    for p in &snap.pulses {
        if let Some(tab) = p.tab.as_deref() {
            if !fronts.iter().flatten().any(|(t, _)| *t == tab) {
                fronts.push(Some((tab, p.window.as_deref())));
            }
        }
        if let Some(window) = p.window.as_deref() {
            if !windows.contains(&window) {
                windows.push(window);
            }
        }
    }
    // And a window none of them is in.
    windows.push("0x00000000000000ff");
    println!("pulses {}", snap.pulses.len());
    for front in &fronts {
        let tab = front.map(|(t, _)| t);
        let window = front.and_then(|(_, w)| w);
        let row = pulse::pulsing_row(&snap.pulses, window, tab).and_then(|name| l.row(name));
        println!("pulse list showing={} rows={}", tab.unwrap_or("-"), row.map_or("-", |r| r.id.as_str()));
    }
    for window in &windows {
        for front in &fronts {
            let tab = front.map(|(t, _)| t);
            let p = pulse::pulsing(&snap.pulses, Some(window), tab, Scope::Window);
            println!(
                "pulse window={window} showing={} terminal={} tab={}",
                tab.unwrap_or("-"),
                p.map_or("-", |p| p.terminal.as_str()),
                p.and_then(|p| p.tab.as_deref()).unwrap_or("-")
            );
        }
    }

    let lay = ListLayout::new(&l, height);
    println!("size w={:.3} h={:.3}", lay.width, lay.height);
    rect("header", lay.header);
    for (id, r) in &lay.rows {
        rect(&format!("row:{id}"), *r);
    }
    rect("separator", lay.separator);
    rect("quiet_header", lay.quiet_header);
    rect("band_header", lay.band_header);
    for (n, lane) in lay.lanes.iter().enumerate() {
        rect(&format!("lane:{n}"), *lane);
    }
    rect("axis", lay.axis);

    let band = &l.band;
    println!(
        "band start_ms={} now_ms={} start_label={} total_min={} lanes={}",
        band.start_ms,
        band.now_ms,
        quote(&band.start_label),
        band.total_min,
        band.lanes.len()
    );
    for (n, lane) in band.lanes.iter().enumerate() {
        println!("lane {n} name={} spans={}", quote(&lane.name), lane.spans.len());
        for s in &lane.spans {
            println!("span lane={n} from_ms={} to_ms={} ongoing={}", s.from_ms, s.to_ms, s.ongoing);
        }
        let track = layout::track_width(lay.lanes.get(n).map_or(0.0, |r| r.w));
        println!("track lane={n} w={track:.3}");
        for g in layout::segments(lane, band, track) {
            println!("segment lane={n} x={:.3} w={:.3} ongoing={}", g.x, g.w, g.ongoing);
        }
    }

    // Where the arrow keys take the selection, from every row and from none.
    let ids: Vec<Option<String>> =
        std::iter::once(None).chain(l.rows().map(|r| Some(r.id.clone()))).collect();
    for from in &ids {
        for step in [-1i64, 1] {
            let to = list::move_selection(&l, from.as_deref(), step).unwrap_or("-");
            println!("move from={} step={step} to={to}", from.as_deref().unwrap_or("-"));
        }
    }
}
