//! A desktop notification as a WinRT toast, in the notification centre as
//! macOS has it (task 1551) -- the parts that are decisions rather than
//! calls: which way a notification goes, what the toast says, what a click
//! on it carries back, and where the picture comes from. The host
//! (`windows/host/src/toast.rs`) makes the calls; this is here so that all
//! of it is tested off Windows.
//!
//! # The identity, and what it leaves behind
//!
//! A toast belongs to an AppUserModelID the shell can resolve. Polter is a
//! directory somebody unzipped, so there is no Start menu shortcut to carry
//! one; the host registers [`AUMID`] under
//! `HKCU\Software\Classes\AppUserModelId\` instead (no administrator, and a
//! moved directory is put right at the next start). **Removing the directory
//! leaves that key**; it names Polter and a picture and nothing else, and is
//! safe to delete by hand.
//!
//! # What a click cannot do
//!
//! ⚠️ A click reaches Polter through the toast's `Activated` event, which
//! exists only while this process does. **After Polter has quit, a click on
//! one of its notifications in the notification centre does not start it**
//! -- macOS does. Doing that needs a COM activator registered for the
//! identity, which task 1551 left out on purpose.

use crate::alert::{click_of, Click};

/// The identity the host registers and shows its toasts under.
pub const AUMID: &str = "Lugia.Polter";

/// The group every Polter toast carries, so that one terminal's can be taken
/// back by its tag alone.
pub const GROUP: &str = "polter";

/// `Windows.UI.Notifications.NotificationSetting`, by its numbers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Setting {
    Enabled,
    DisabledForApplication,
    DisabledForUser,
    DisabledByGroupPolicy,
    DisabledByManifest,
}

impl Setting {
    /// `None` for a number the system has not documented: not "enabled".
    pub fn from_i32(v: i32) -> Option<Setting> {
        Some(match v {
            0 => Setting::Enabled,
            1 => Setting::DisabledForApplication,
            2 => Setting::DisabledForUser,
            3 => Setting::DisabledByGroupPolicy,
            4 => Setting::DisabledByManifest,
            _ => return None,
        })
    }
}

/// Why a notification went to the notification-area balloon instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Why {
    /// The identity could not be registered at start, so a toast would be
    /// accepted and never appear.
    NotRegistered,
    /// The notifier could not say whether toasts are allowed.
    SettingUnreadable,
    /// The person, a policy or the system turned Polter's toasts off.
    TurnedOff(Setting),
    /// `Show` returned an error.
    ShowFailed,
}

impl Why {
    /// What the log says. Not translated: a log is searched by these words.
    pub fn says(self) -> &'static str {
        match self {
            Why::NotRegistered => "the identity is not registered",
            Why::SettingUnreadable => "the notifier did not say whether toasts are allowed",
            Why::TurnedOff(Setting::DisabledForApplication) => "Polter's notifications are turned off in Settings",
            Why::TurnedOff(Setting::DisabledForUser) => "notifications are turned off for this user",
            Why::TurnedOff(Setting::DisabledByGroupPolicy) => "a group policy turns notifications off",
            Why::TurnedOff(Setting::DisabledByManifest) => "the system turned them off for this identity",
            // Not reachable through `before_show`; said anyway rather than
            // made a panic.
            Why::TurnedOff(Setting::Enabled) => "turned off while enabled (a contradiction)",
            Why::ShowFailed => "Show returned an error",
        }
    }
}

/// Which way one notification goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    Toast,
    Balloon(Why),
}

/// Before showing: a toast only with the identity registered and toasts
/// allowed. **Anything else is the balloon**, which needs nothing installed
/// -- a notification that silently goes nowhere is the one outcome this
/// exists to rule out.
pub fn before_show(registered: bool, setting: Option<Setting>) -> Route {
    if !registered {
        return Route::Balloon(Why::NotRegistered);
    }
    match setting {
        None => Route::Balloon(Why::SettingUnreadable),
        Some(Setting::Enabled) => Route::Toast,
        Some(off) => Route::Balloon(Why::TurnedOff(off)),
    }
}

/// After `Show`: it went, or it is the balloon after all.
pub fn after_show(shown: bool) -> Route {
    if shown {
        Route::Toast
    } else {
        Route::Balloon(Why::ShowFailed)
    }
}

/// Text for an XML attribute or element.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            // XML 1.0 has no way to say these at all; a terminal can send
            // them, and one would make the whole document unreadable.
            c if (c as u32) < 0x20 && c != '\n' && c != '\t' => {}
            c => out.push(c),
        }
    }
    out
}

/// The toast: the title, the terminal's name -- macOS's subtitle -- and the
/// body, each its own line, with Polter's picture when there is one.
/// **Never without text**: a title with no body is an ordinary notification,
/// and the title stands in for the body then, as on the balloon.
pub fn xml(title: &str, subtitle: Option<&str>, body: &str, logo: Option<&str>, launch: &str) -> String {
    let mut lines: Vec<&str> = Vec::new();
    let body = if body.trim().is_empty() { title } else { body };
    if !title.trim().is_empty() {
        lines.push(title);
    }
    if let Some(s) = subtitle.filter(|s| !s.trim().is_empty()) {
        lines.push(s);
    }
    if body != title || lines.is_empty() {
        lines.push(body);
    }
    let texts: String = lines.iter().map(|l| format!("<text>{}</text>", esc(l))).collect();
    let image = logo
        .map(|p| format!("<image placement=\"appLogoOverride\" src=\"{}\"/>", esc(p)))
        .unwrap_or_default();
    format!(
        "<toast launch=\"{}\"><visual><binding template=\"ToastGeneric\">{texts}{image}</binding></visual></toast>",
        esc(launch)
    )
}

/// What a click on one toast is to do, carried in its `launch` attribute:
/// the same three facts the balloon remembers for its last one
/// (`alert::click_of`), so every toast keeps its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub group: Option<String>,
    pub terminal: u64,
    pub frame: isize,
}

impl Launch {
    /// `t=<hex>;f=<decimal>;g=<group, %-escaped>`. The group goes last and
    /// escaped, so whatever a group is called cannot end a field early.
    pub fn encode(&self) -> String {
        let mut s = format!("t={:x};f={}", self.terminal, self.frame);
        if let Some(g) = &self.group {
            s.push_str(";g=");
            for b in g.bytes() {
                if b.is_ascii_alphanumeric() || b"-_.".contains(&b) {
                    s.push(b as char);
                } else {
                    s.push_str(&format!("%{b:02X}"));
                }
            }
        }
        s
    }

    /// `None` for anything `encode` did not write.
    pub fn decode(s: &str) -> Option<Launch> {
        let mut out = Launch { group: None, terminal: 0, frame: 0 };
        let (mut saw_t, mut saw_f) = (false, false);
        for field in s.split(';') {
            let (k, v) = field.split_once('=')?;
            match k {
                "t" => {
                    out.terminal = u64::from_str_radix(v, 16).ok()?;
                    saw_t = true;
                }
                "f" => {
                    out.frame = v.parse().ok()?;
                    saw_f = true;
                }
                "g" => {
                    let mut bytes = Vec::new();
                    let raw = v.as_bytes();
                    let mut i = 0;
                    while i < raw.len() {
                        if raw[i] == b'%' {
                            let hex = std::str::from_utf8(raw.get(i + 1..i + 3)?).ok()?;
                            bytes.push(u8::from_str_radix(hex, 16).ok()?);
                            i += 3;
                        } else {
                            bytes.push(raw[i]);
                            i += 1;
                        }
                    }
                    out.group = Some(String::from_utf8(bytes).ok()?);
                }
                _ => return None,
            }
        }
        (saw_t && saw_f).then_some(out)
    }

    /// Where the click goes: the balloon's rule, unchanged (task 1538).
    pub fn click(&self) -> Click {
        click_of(self.group.as_deref(), self.terminal, self.frame)
    }
}

/// The tag one terminal's toasts carry, so they can be taken back when the
/// person goes to it. At most 64 characters, the system's limit: 16 here.
pub fn tag(terminal: u64) -> String {
    format!("{terminal:016x}")
}

/// The largest PNG inside an `.ico` -- the 256-pixel one `make-icon.sh`
/// stores as PNG. A toast's picture has to be a file the shell can read, and
/// a `.ico` is not one of the kinds it takes. `None` when there is none.
pub fn png_in_ico(ico: &[u8]) -> Option<&[u8]> {
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if ico.len() < 6 || ico[0..4] != [0, 0, 1, 0] {
        return None;
    }
    let count = u16::from_le_bytes([ico[4], ico[5]]) as usize;
    let mut best: Option<(u32, &[u8])> = None;
    for i in 0..count {
        let e = ico.get(6 + i * 16..6 + i * 16 + 16)?;
        let side = if e[0] == 0 { 256 } else { u32::from(e[0]) };
        let len = u32::from_le_bytes([e[8], e[9], e[10], e[11]]) as usize;
        let at = u32::from_le_bytes([e[12], e[13], e[14], e[15]]) as usize;
        let data = ico.get(at..at.checked_add(len)?)?;
        if data.starts_with(PNG) && best.is_none_or(|(b, _)| side > b) {
            best = Some((side, data));
        }
    }
    best.map(|(_, d)| d)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **The three ways back to the balloon, and the one way to a toast.**
    #[test]
    fn a_toast_only_when_registered_and_allowed() {
        assert_eq!(before_show(true, Some(Setting::Enabled)), Route::Toast);
        assert_eq!(before_show(false, Some(Setting::Enabled)), Route::Balloon(Why::NotRegistered));
        assert_eq!(before_show(true, None), Route::Balloon(Why::SettingUnreadable));
        for off in [
            Setting::DisabledForApplication,
            Setting::DisabledForUser,
            Setting::DisabledByGroupPolicy,
            Setting::DisabledByManifest,
        ] {
            assert_eq!(before_show(true, Some(off)), Route::Balloon(Why::TurnedOff(off)), "{off:?}");
        }
        // Not registered wins over everything: no toast can appear then.
        assert_eq!(before_show(false, None), Route::Balloon(Why::NotRegistered));
    }

    #[test]
    fn a_failed_show_is_the_balloon() {
        assert_eq!(after_show(true), Route::Toast);
        assert_eq!(after_show(false), Route::Balloon(Why::ShowFailed));
    }

    #[test]
    fn the_settings_numbers_are_the_systems() {
        assert_eq!(Setting::from_i32(0), Some(Setting::Enabled));
        assert_eq!(Setting::from_i32(1), Some(Setting::DisabledForApplication));
        assert_eq!(Setting::from_i32(4), Some(Setting::DisabledByManifest));
        // An undocumented number is not "enabled".
        assert_eq!(Setting::from_i32(5), None);
        assert_eq!(Setting::from_i32(-1), None);
    }

    #[test]
    fn the_toast_has_three_lines_and_escapes_them() {
        let x = xml("Done <1>", Some("build & test"), "it \"worked\"", Some("C:\\p\\polter.png"), "t=1;f=2");
        assert!(x.contains("<text>Done &lt;1&gt;</text><text>build &amp; test</text><text>it &quot;worked&quot;</text>"), "{x}");
        assert!(x.contains("src=\"C:\\p\\polter.png\""), "{x}");
        assert!(x.contains("launch=\"t=1;f=2\""), "{x}");
        assert!(x.contains("template=\"ToastGeneric\""));
    }

    #[test]
    fn a_toast_is_never_without_text() {
        // No body: the title stands in once, not twice.
        let x = xml("Done", None, "", None, "");
        assert_eq!(x.matches("<text>").count(), 1, "{x}");
        assert!(x.contains("<text>Done</text>"));
        // No title: the body alone.
        let x = xml("", Some("  "), "hello", None, "");
        assert_eq!(x.matches("<text>").count(), 1, "{x}");
        assert!(!x.contains("<image"));
        // A control character a terminal sent does not break the document.
        assert!(!xml("a\u{1}b", None, "c", None, "").contains('\u{1}'));
    }

    #[test]
    fn a_launch_comes_back_as_it_went() {
        for l in [
            Launch { group: None, terminal: 0, frame: 0 },
            Launch { group: Some("polter".into()), terminal: 0xabc, frame: 12345 },
            Launch { group: Some("a;g=b%c 群".into()), terminal: u64::MAX, frame: -1 },
        ] {
            assert_eq!(Launch::decode(&l.encode()), Some(l.clone()), "{}", l.encode());
        }
        assert_eq!(Launch::decode(""), None);
        assert_eq!(Launch::decode("t=1"), None);
        assert_eq!(Launch::decode("t=zz;f=1"), None);
        assert_eq!(Launch::decode("t=1;f=1;x=2"), None);
    }

    #[test]
    fn a_click_goes_where_the_balloons_does() {
        let l = Launch { group: Some("g".into()), terminal: 7, frame: 3 };
        assert_eq!(l.click(), click_of(Some("g"), 7, 3));
        let l = Launch { group: None, terminal: 7, frame: 3 };
        assert_eq!(l.click(), click_of(None, 7, 3));
    }

    #[test]
    fn the_tag_is_short_enough() {
        assert_eq!(tag(u64::MAX).len(), 16);
        assert_eq!(tag(1), "0000000000000001");
    }

    /// Off the icon the host is built with, so the picture a toast shows is
    /// the one Windows shows everywhere else.
    #[test]
    fn the_shipped_icon_has_a_png_in_it() {
        let ico = include_bytes!("../../host/polter.ico");
        let png = png_in_ico(ico).expect("polter.ico carries a PNG");
        assert!(png.starts_with(b"\x89PNG"));
        // The 256 one: width at bytes 16..20 of the IHDR.
        assert_eq!(u32::from_be_bytes([png[16], png[17], png[18], png[19]]), 256);
        assert_eq!(png_in_ico(b"not an icon"), None);
        assert_eq!(png_in_ico(&[0, 0, 1, 0, 1, 0]), None);
    }
}
