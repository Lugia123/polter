//! The control room calling the person (task 1505; the design's section 9):
//! the words of the notification, which cards count as in sight, and what
//! the control room tells the core about where the person is.
//!
//! **Whether, when and how often are the core's** (`src/poltergeist/
//! ControlNotify.zig`). This host is told "call now, about this group" and
//! says it. The macOS host's half is `ControlRoomAlert.swift`, the same
//! rules: the same JSON to the core, the same "wholly above the bottom".

use crate::layout::ListLayout;
use crate::n_;

/// The three waits that call the person, as the core names them
/// (`ghostty_control_room_alert_kind_e`, in that order).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    NeedsApproval,
    NeedsAnswer,
    Failed,
}

impl Kind {
    /// The C enum's value; `None` for one this host does not know.
    pub fn from_c(v: i32) -> Option<Kind> {
        Some(match v {
            0 => Kind::NeedsApproval,
            1 => Kind::NeedsAnswer,
            2 => Kind::Failed,
            _ => return None,
        })
    }

    /// The title's msgid; `{}` is the group.
    pub fn title(self) -> &'static str {
        match self {
            Kind::NeedsApproval => n_("{} is waiting for your approval"),
            Kind::NeedsAnswer => n_("{} is waiting for your answer"),
            Kind::Failed => n_("{} has stopped on an error"),
        }
    }
}

/// The notification's title, through the host's translation `tr`.
pub fn title(kind: Kind, group: &str, tr: impl Fn(&str) -> String) -> String {
    tr(kind.title()).replacen("{}", group, 1)
}

/// The body: what it waits on, with the worker's name when it is a worker;
/// and how many more of the same supervisor's groups wait, since one
/// supervisor is one notification.
pub fn body(who: &str, text: &str, more: u32, tr: impl Fn(&str) -> String) -> String {
    let said = text.trim();
    let mut lines: Vec<String> = Vec::new();
    match (who.is_empty(), said.is_empty()) {
        (true, true) => {}
        (true, false) => lines.push(said.to_string()),
        (false, true) => lines.push(who.to_string()),
        (false, false) => lines.push(format!("{who}: {said}")),
    }
    if more == 1 {
        lines.push(tr(n_("1 more group of the same supervisor is waiting too.")));
    } else if more > 1 {
        lines.push(tr(n_("{} more groups of the same supervisor are waiting too.")).replacen("{}", &more.to_string(), 1));
    }
    lines.join("\n")
}

/// The rows whose whole card is on screen: wholly above the list's bottom.
/// The list does not scroll -- rows past the bottom are cut off -- so this
/// is what "the card is in sight" is. In the list's own order: the order is
/// the core's, and this only filters it.
pub fn in_sight(layout: &ListLayout) -> Vec<String> {
    layout.rows.iter().filter(|(_, r)| r.h > 0.0 && r.y + r.h <= layout.height).map(|(id, _)| id.clone()).collect()
}

/// The control room's half of where the person is.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Presence {
    pub in_front: bool,
    pub cards: Vec<String>,
}

impl Presence {
    /// `{"in_front":bool,"cards":[...]}`, as `ghostty_app_control_presence`
    /// reads it. The cards in the order given; the core reads them as a set.
    pub fn json(&self) -> String {
        let names: Vec<String> = self.cards.iter().map(|c| quote(c)).collect();
        format!("{{\"in_front\":{},\"cards\":[{}]}}", self.in_front, names.join(","))
    }
}

fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Remembers what was last said, so the same thing is not said twice.
#[derive(Clone, Debug, Default)]
pub struct Reporter {
    said: Option<Presence>,
}

impl Reporter {
    /// The JSON to send for `now`, or `None` when it is what was said last.
    /// Out of front, no card is in sight, whatever the list holds.
    pub fn report(&mut self, now: Presence) -> Option<String> {
        let mut now = now;
        if !now.in_front {
            now.cards.clear();
        }
        // The same cards in another order are the same sight: compared as
        // sets, because an order here would be this host's to decide.
        if let Some(said) = &self.said {
            let same: std::collections::HashSet<&String> = said.cards.iter().collect();
            let now_set: std::collections::HashSet<&String> = now.cards.iter().collect();
            if said.in_front == now.in_front && same == now_set {
                return None;
            }
        }
        let json = now.json();
        self.said = Some(now);
        Some(json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::Rect;

    fn id(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn the_title_names_the_group_and_says_what_it_waits_for() {
        let t: Vec<String> = [Kind::NeedsApproval, Kind::NeedsAnswer, Kind::Failed].iter().map(|k| title(*k, "web-app", id)).collect();
        assert!(t.iter().all(|s| s.contains("web-app")));
        assert_eq!(t[0], "web-app is waiting for your approval");
        assert_ne!(t[0], t[1]);
        assert_ne!(t[1], t[2]);
        assert_eq!(Kind::from_c(0), Some(Kind::NeedsApproval));
        assert_eq!(Kind::from_c(2), Some(Kind::Failed));
        assert_eq!(Kind::from_c(3), None);
    }

    #[test]
    fn the_body_names_the_worker_and_says_how_many_more_groups_wait() {
        assert_eq!(body("worker-core", "may I push?", 0, id), "worker-core: may I push?");
        assert_eq!(body("", " may I push? \n", 0, id), "may I push?");
        assert_eq!(body("worker-core", "", 0, id), "worker-core");
        assert_eq!(body("", "", 0, id), "");
        assert_eq!(body("", "x", 1, id), "x\n1 more group of the same supervisor is waiting too.");
        assert_eq!(body("", "x", 3, id), "x\n3 more groups of the same supervisor are waiting too.");
    }

    #[test]
    fn a_card_is_in_sight_when_it_is_wholly_above_the_bottom() {
        let r = |y: f64| Rect { x: 0.0, y, w: 100.0, h: 40.0 };
        let lay = ListLayout {
            width: 300.0,
            height: 100.0,
            header: r(0.0),
            rows: vec![(id("web"), r(10.0)), (id("api"), r(50.0)), (id("docs"), r(90.0))],
            fits: Vec::new(),
            separator: r(0.0),
            quiet_header: r(0.0),
            notice: None,
        };
        // `api` ends exactly at the bottom and is in; `docs` is cut off.
        // In the list's order.
        assert_eq!(in_sight(&lay), vec![id("web"), id("api")]);
    }

    #[test]
    fn presence_is_said_once_for_each_change_and_as_the_core_reads_it() {
        let mut rep = Reporter::default();
        let first = rep.report(Presence { in_front: true, cards: vec![id("web"), id("a \"q\"")] }).unwrap();
        assert_eq!(first, r#"{"in_front":true,"cards":["web","a \"q\""]}"#);
        assert_eq!(rep.report(Presence { in_front: true, cards: vec![id("a \"q\""), id("web")] }), None);
        // Behind something else: no card is in sight, whatever is listed.
        assert_eq!(rep.report(Presence { in_front: false, cards: vec![id("web")] }).as_deref(), Some(r#"{"in_front":false,"cards":[]}"#));
        assert_eq!(rep.report(Presence { in_front: false, cards: vec![] }), None);
    }
}
