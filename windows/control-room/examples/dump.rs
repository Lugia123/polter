//! Print what this crate makes of a snapshot, in the form
//! `tools/control-room-hosts-agree.py` compares with the macOS host's.
//!
//!     cargo run -q -p polter-control-room --example dump -- <snapshot.json> <height>
//!
//! One fact a line. The macOS side prints the same lines from
//! `ControlRoomList.swift`; any line that differs is the two hosts
//! disagreeing about what one snapshot looks like.

use polter_control_room::json::quote;
use polter_control_room::layout::{ListLayout, Rect};
use polter_control_room::list::{self, Detail, List, Row};
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
    println!(
        "row section={section} id={} shown={} word={} detail={} code={} waited={waited} others={}",
        r.id,
        r.shown.name(),
        quote(&r.word),
        quote(&detail),
        r.detail_is_code,
        r.others
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

    println!("now_ms {}", l.now_ms);
    println!("count waiting={} quiet={}", l.waiting_count, l.quiet_count);
    for r in &l.waiting {
        row("waiting", r);
    }
    for r in &l.quiet {
        row("quiet", r);
    }

    // With no lanes: the macOS host does not draw the band from the
    // snapshot yet, and with none the two layouts are the same question.
    let lay = ListLayout::with_lanes(&l, height, 0);
    println!("size w={:.3} h={:.3}", lay.width, lay.height);
    rect("header", lay.header);
    for (id, r) in &lay.rows {
        rect(&format!("row:{id}"), *r);
    }
    rect("separator", lay.separator);
    rect("quiet_header", lay.quiet_header);
    rect("band_header", lay.band_header);
    rect("axis", lay.axis);

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
