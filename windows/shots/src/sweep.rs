//! Which old files startup deletes from the shots directory.
//!
//! **The directory is not necessarily ours.** `screenshot-directory` can point
//! it at any folder, so the rule is the narrow one the specification states:
//! a `.png` whose name [`crate::name::parse`] recognises and whose
//! modification time is more than seven days old, and the `.json` of the same
//! stem with it. Everything else in the directory is left alone however old
//! it is -- including subdirectories, whatever they are called.

use crate::name::{parse, Kind};
use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, SystemTime};

/// Seven days.
pub const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// One regular file in the directory: its name and how long ago it was
/// modified. A file modified in the future has age zero.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub age: Duration,
}

/// The names to delete.
///
///  * A recognised `.png` older than `max_age` goes.
///  * A recognised `.json` goes **with its `.png`**: when that `.png` is going,
///    whatever the `.json`'s own age, so a shot is never left half there.
///  * A recognised `.json` with no `.png` beside it is an orphan and is judged
///    by its own age.
///  * The tiles of a long screenshot (`<stem>-<n>.png`) follow the same two
///    rules as the `.json`.
///  * Nothing else is ever named.
pub fn plan(entries: &[Entry], max_age: Duration) -> Vec<String> {
    let ours: Vec<(&Entry, &str, Kind)> =
        entries.iter().filter_map(|e| parse(&e.name).map(|(stem, kind)| (e, stem, kind))).collect();
    let pngs: HashSet<&str> = ours.iter().filter(|o| o.2 == Kind::Png).map(|o| o.1).collect();
    let old_pngs: HashSet<&str> =
        ours.iter().filter(|o| o.2 == Kind::Png && o.0.age > max_age).map(|o| o.1).collect();
    ours.iter()
        .filter(|(e, stem, kind)| match kind {
            Kind::Png => old_pngs.contains(stem),
            // A sidecar and the tiles of a long screenshot belong to their
            // shot: they go when it goes, and alone they go by their own age.
            Kind::Json | Kind::Tile if pngs.contains(stem) => old_pngs.contains(stem),
            Kind::Json | Kind::Tile => e.age > max_age,
        })
        .map(|(e, _, _)| e.name.clone())
        .collect()
}

/// What a sweep did, for the log line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Names deleted.
    pub deleted: Vec<String>,
    /// Regular files looked at, ours or not.
    pub seen: usize,
    /// Names [`plan`] chose that could not be deleted, with the reason.
    pub failed: Vec<(String, String)>,
}

/// Delete what [`plan`] names from `dir`. A directory that does not exist is
/// an empty report, not an error: nothing has been saved yet.
///
/// Only regular files are considered. A directory or a symlink named like a
/// shot is not something this crate wrote.
pub fn sweep(dir: &Path, now: SystemTime, max_age: Duration) -> std::io::Result<Report> {
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Report::default()),
        Err(e) => return Err(e),
    };
    let mut entries = Vec::new();
    for item in read {
        let Ok(item) = item else { continue };
        // `DirEntry::metadata` does not follow symlinks.
        let Ok(meta) = item.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(name) = item.file_name().to_str().map(str::to_owned) else { continue };
        // No modification time means no evidence it is old: skip it.
        let Ok(modified) = meta.modified() else { continue };
        let age = now.duration_since(modified).unwrap_or(Duration::ZERO);
        entries.push(Entry { name, age });
    }
    let mut report = Report { seen: entries.len(), ..Report::default() };
    for name in plan(&entries, max_age) {
        match std::fs::remove_file(dir.join(&name)) {
            Ok(()) => report.deleted.push(name),
            Err(e) => report.failed.push((name, e.to_string())),
        }
    }
    report.deleted.sort();
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::tests::Scratch;

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    fn e(name: &str, days: u64) -> Entry {
        Entry { name: name.to_string(), age: DAY * days as u32 }
    }

    fn planned(entries: &[Entry]) -> Vec<String> {
        let mut p = plan(entries, MAX_AGE);
        p.sort();
        p
    }

    #[test]
    fn an_old_shot_goes_with_its_json() {
        let got = planned(&[e("20260901-000000-000.png", 8), e("20260901-000000-000.json", 8)]);
        assert_eq!(got, ["20260901-000000-000.json", "20260901-000000-000.png"]);
    }

    #[test]
    fn an_old_file_that_is_not_named_like_a_shot_is_kept() {
        let got = planned(&[
            e("20260901-000000-000.png", 8),
            e("holiday.png", 400),
            e("notes.json", 400),
            e("IMG_20260901-000000-000.png", 400),
            e("20260901-000000-000.PNG", 400),
            e("20260901-000000-000.png.bak", 400),
            e("20260901-000000-000.txt", 400),
        ]);
        assert_eq!(got, ["20260901-000000-000.png"]);
    }

    #[test]
    fn a_recent_shot_is_kept() {
        assert!(planned(&[e("20261005-000000-000.png", 6), e("20261005-000000-000.json", 6)]).is_empty());
    }

    #[test]
    fn exactly_seven_days_is_not_yet_older_than_seven_days() {
        let at = |age| vec![Entry { name: "20260901-000000-000.png".into(), age }];
        assert!(plan(&at(MAX_AGE), MAX_AGE).is_empty());
        assert_eq!(plan(&at(MAX_AGE + Duration::from_secs(1)), MAX_AGE).len(), 1);
    }

    #[test]
    fn a_json_follows_its_png_not_its_own_age() {
        // The png is recent, the json somehow older: the shot stays whole.
        assert!(planned(&[e("20261005-000000-000.png", 1), e("20261005-000000-000.json", 30)]).is_empty());
        // The png is old, the json was touched yesterday: the shot goes whole.
        let got = planned(&[e("20260901-000000-000.png", 30), e("20260901-000000-000.json", 1)]);
        assert_eq!(got, ["20260901-000000-000.json", "20260901-000000-000.png"]);
    }

    #[test]
    fn a_long_screenshots_tiles_go_with_it() {
        let got = planned(&[
            e("20260901-000000-000.png", 8),
            e("20260901-000000-000.json", 8),
            e("20260901-000000-000-1.png", 8),
            e("20260901-000000-000-2.png", 1),
            // Another shot's, recent, and a stranger numbered the same way.
            e("20261005-000000-000-1.png", 30),
            e("20261005-000000-000.png", 1),
            e("holiday-1.png", 400),
        ]);
        assert_eq!(
            got,
            ["20260901-000000-000-1.png", "20260901-000000-000-2.png", "20260901-000000-000.json", "20260901-000000-000.png"]
        );
        // Tiles whose shot is gone are judged by their own age.
        assert_eq!(planned(&[e("20260901-000000-000-1.png", 8), e("20260901-000000-000-2.png", 2)]), ["20260901-000000-000-1.png"]);
    }

    #[test]
    fn an_orphan_json_is_judged_by_its_own_age() {
        assert_eq!(planned(&[e("20260901-000000-000.json", 8)]), ["20260901-000000-000.json"]);
        assert!(planned(&[e("20261005-000000-000.json", 2)]).is_empty());
    }

    fn put(dir: &Path, name: &str, now: SystemTime, days: u64) {
        let p = dir.join(name);
        std::fs::write(&p, b"x").unwrap();
        let f = std::fs::OpenOptions::new().write(true).open(&p).unwrap();
        f.set_modified(now - DAY * days as u32).unwrap();
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> =
            std::fs::read_dir(dir).unwrap().map(|d| d.unwrap().file_name().into_string().unwrap()).collect();
        v.sort();
        v
    }

    #[test]
    fn on_disk_the_old_shot_goes_and_the_old_stranger_stays() {
        let s = Scratch::new("sweep");
        std::fs::create_dir_all(&s.0).unwrap();
        let now = SystemTime::now();
        put(&s.0, "20260928-101010-001.png", now, 8);
        put(&s.0, "20260928-101010-001.json", now, 8);
        put(&s.0, "20261005-101010-002.png", now, 1);
        put(&s.0, "holiday.png", now, 8);
        put(&s.0, "report.json", now, 8);
        // A directory named like a shot, with a file in it: not ours.
        let sub = s.0.join("20260101-000000-000.png");
        std::fs::create_dir(&sub).unwrap();
        put(&sub, "20260101-000000-000.png", now, 300);

        let r = sweep(&s.0, now, MAX_AGE).unwrap();

        assert_eq!(r.deleted, ["20260928-101010-001.json", "20260928-101010-001.png"]);
        assert_eq!(r.seen, 5);
        assert!(r.failed.is_empty());
        assert_eq!(
            names(&s.0),
            ["20260101-000000-000.png", "20261005-101010-002.png", "holiday.png", "report.json"]
        );
        assert_eq!(names(&sub), ["20260101-000000-000.png"]);
    }

    #[test]
    fn a_directory_that_does_not_exist_is_nothing_to_do() {
        let s = Scratch::new("absent");
        assert_eq!(sweep(&s.0.join("shots"), SystemTime::now(), MAX_AGE).unwrap(), Report::default());
    }
}
