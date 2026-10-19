//! The colour a project is given beside others (task 1796), one line a
//! case, for `tools/control-room-hosts-agree.py`: it runs this after the
//! control room's dump and compares the lines with the macOS dump's, which
//! has the same cases in the same order.

use polter_projectfile::PaneColor;
use polter_projects::tone;

/// The colours the other projects have: the same list as the macOS dump's
/// `projectToneCases`.
const CASES: &[&[&str]] = &[
    &[],
    &["blue"],
    &["blue", "orange"],
    &["blue", "blue", "orange"],
    &["orange"],
    &["purple", "purple"],
    &["graphite", "red", "yellow", "teal", "pink", "green", "orange"],
    &["blue", "orange", "green", "pink", "teal", "yellow", "red", "graphite"],
    &["blue", "orange", "green", "pink", "teal", "yellow", "red", "graphite", "blue", "green"],
];

fn main() {
    println!("project_tone order={}", tone::ORDER.iter().map(|c| c.name()).collect::<Vec<_>>().join(","));
    for used in CASES {
        let used: Vec<PaneColor> = used.iter().map(|n| PaneColor::from_name(n).expect("a colour")).collect();
        let said = if used.is_empty() { "-".to_string() } else { used.iter().map(|c| c.name()).collect::<Vec<_>>().join(",") };
        println!("project_tone used={said} pick={}", tone::pick(&used).name());
    }
}
