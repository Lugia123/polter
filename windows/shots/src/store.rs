//! Writing a new shot into the directory without overwriting one.

use crate::name::Stamp;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// How many clock readings [`write_new`] takes before giving up.
pub const ATTEMPTS: usize = 20;

/// Write `bytes` to a new `<stamp>.png` under `dir`, creating `dir` if needed,
/// and return the path.
///
/// **Never overwrites.** The name has millisecond resolution and two shots can
/// share one; the file is opened with `create_new`, and a name that is taken
/// means `pause` and ask `clock` again. `pause` is the caller's (a 1 ms sleep
/// in the host) so the test does not sleep.
pub fn write_new(
    dir: &Path,
    mut clock: impl FnMut() -> Stamp,
    mut pause: impl FnMut(),
    bytes: &[u8],
) -> io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    for _ in 0..ATTEMPTS {
        let path = dir.join(clock().png());
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(bytes) {
                    // A half-written PNG under a name startup will not touch
                    // for a week is worse than no file.
                    drop(f);
                    let _ = std::fs::remove_file(&path);
                    return Err(e);
                }
                return Ok(path);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => pause(),
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        format!("every one of {ATTEMPTS} names tried in {} was taken", dir.display()),
    ))
}

/// Write `bytes` to `dir/name`, creating `dir` if needed -- **or, when that
/// name is taken, to `<stem> 2.<ext>`, `<stem> 3.<ext>`, ... (as on macOS) -- never over a file that
/// is there**: the directory is the person's own (Downloads), and what is in
/// it was not made by this program. Returns the path written.
pub fn write_copy(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s, format!(".{e}")),
        _ => (name, String::new()),
    };
    for n in 1..=1000 {
        let file = if n == 1 { name.to_string() } else { format!("{stem} {n}{ext}") };
        let path = dir.join(file);
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut f) => {
                if let Err(e) = f.write_all(bytes) {
                    drop(f);
                    let _ = std::fs::remove_file(&path);
                    return Err(e);
                }
                return Ok(path);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, format!("a thousand names like {name} in {} were taken", dir.display())))
}

/// Where shots go: `configured` (`screenshot-directory`) when it is set,
/// with a leading `~/` or `~\` replaced by `home`; otherwise `default`.
///
/// An empty value is unset. `~` that cannot be expanded because there is no
/// `home` falls back to `default` rather than creating a directory literally
/// named `~` under wherever the process happens to be running.
pub fn directory(configured: Option<&str>, home: Option<&Path>, default: Option<PathBuf>) -> Option<PathBuf> {
    let Some(value) = configured.map(str::trim).filter(|v| !v.is_empty()) else {
        return default;
    };
    let rest = if value == "~" {
        Some("")
    } else {
        value.strip_prefix("~/").or_else(|| value.strip_prefix("~\\"))
    };
    match (rest, home) {
        (None, _) => Some(PathBuf::from(value)),
        (Some(""), Some(home)) => Some(home.to_path_buf()),
        (Some(rest), Some(home)) => Some(home.join(rest)),
        (Some(_), None) => default,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A fresh directory under the system temp directory, removed on drop.
    pub(crate) struct Scratch(pub PathBuf);
    impl Scratch {
        pub(crate) fn new(tag: &str) -> Self {
            use std::sync::atomic::{AtomicU32, Ordering};
            static N: AtomicU32 = AtomicU32::new(0);
            let p = std::env::temp_dir().join(format!(
                "polter-shots-{tag}-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&p);
            Scratch(p)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn the_directory_is_the_configured_one_or_the_default() {
        let home = Path::new("/home/u");
        let default = || Some(PathBuf::from("/state/polter/shots"));
        assert_eq!(directory(None, Some(home), default()), default());
        assert_eq!(directory(Some(""), Some(home), default()), default());
        assert_eq!(directory(Some("  "), Some(home), default()), default());
        assert_eq!(directory(Some("/work/proj/shots"), Some(home), default()), Some("/work/proj/shots".into()));
        assert_eq!(directory(Some("/work/proj/shots"), None, None), Some("/work/proj/shots".into()));
        assert_eq!(directory(None, Some(home), None), None);
    }

    #[test]
    fn a_leading_tilde_is_the_home_directory() {
        let home = Path::new("/home/u");
        let default = || Some(PathBuf::from("/state/polter/shots"));
        assert_eq!(directory(Some("~/shots"), Some(home), default()), Some(home.join("shots")));
        assert_eq!(directory(Some("~\\shots"), Some(home), default()), Some(home.join("shots")));
        assert_eq!(directory(Some("~"), Some(home), default()), Some(home.to_path_buf()));
        // Only a leading `~/`: `~user` and a tilde inside a name are literal.
        assert_eq!(directory(Some("~other/shots"), Some(home), default()), Some("~other/shots".into()));
        assert_eq!(directory(Some("/a/~/b"), Some(home), default()), Some("/a/~/b".into()));
        // No home to expand it with: the default, not a directory named `~`.
        assert_eq!(directory(Some("~/shots"), None, default()), default());
    }

    fn at(milli: u16) -> Stamp {
        Stamp { year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, milli }
    }

    #[test]
    fn it_creates_the_directory_and_writes_the_bytes() {
        let s = Scratch::new("write");
        let dir = s.0.join("polter").join("shots");
        let p = write_new(&dir, || at(123), || {}, b"png").unwrap();
        assert_eq!(p, dir.join("20261006-153012-123.png"));
        assert_eq!(std::fs::read(&p).unwrap(), b"png");
    }

    #[test]
    fn a_taken_name_is_not_overwritten() {
        let s = Scratch::new("taken");
        let first = write_new(&s.0, || at(123), || {}, b"first").unwrap();
        let mut ms = 122;
        let mut pauses = 0;
        let second = write_new(
            &s.0,
            || {
                ms += 1;
                at(ms)
            },
            || pauses += 1,
            b"second",
        )
        .unwrap();
        assert_eq!(std::fs::read(&first).unwrap(), b"first");
        assert_eq!(second, s.0.join("20261006-153012-124.png"));
        assert_eq!(pauses, 1);
    }

    #[test]
    fn a_clock_that_never_moves_is_an_error_not_a_loop() {
        let s = Scratch::new("stuck");
        write_new(&s.0, || at(5), || {}, b"first").unwrap();
        let mut asked = 0;
        let e = write_new(
            &s.0,
            || {
                asked += 1;
                at(5)
            },
            || {},
            b"second",
        )
        .unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(asked, ATTEMPTS);
        assert_eq!(std::fs::read(s.0.join("20261006-153012-005.png")).unwrap(), b"first");
    }

    /// #1197 item 9: the copy in Downloads never replaces what is there.
    #[test]
    fn a_copy_never_replaces_a_file_that_is_there() {
        let dir = std::env::temp_dir().join(format!("polter-copy-{}-{}", std::process::id(), line!()));
        let _ = std::fs::remove_dir_all(&dir);
        let first = write_copy(&dir, "shot.png", b"one").unwrap();
        let second = write_copy(&dir, "shot.png", b"two").unwrap();
        let third = write_copy(&dir, "shot.png", b"three").unwrap();
        assert_eq!(first.file_name().unwrap(), "shot.png");
        assert_eq!(second.file_name().unwrap(), "shot 2.png");
        assert_eq!(third.file_name().unwrap(), "shot 3.png");
        assert_eq!(std::fs::read(&first).unwrap(), b"one", "the first is untouched");
        assert_eq!(std::fs::read(&third).unwrap(), b"three");
        let bare = write_copy(&dir, "noext", b"x").unwrap();
        assert_eq!(write_copy(&dir, "noext", b"y").unwrap().file_name().unwrap(), "noext 2");
        assert_eq!(bare.file_name().unwrap(), "noext");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
