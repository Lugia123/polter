//! What a shot's file is called: `YYYYMMDD-HHMMSS-mmm.png`, local time.
//!
//! **The name is also the only mark of ownership.** `screenshot-directory`
//! lets a person point the directory anywhere, including at a folder full of
//! their own pictures, and startup deletes old files from it. [`parse`] is
//! what stands between that cleanup and those pictures, so it accepts exactly
//! what [`Stamp::png`] and [`Stamp::json`] produce and nothing looser.

/// A local wall-clock time to the millisecond. The host fills it from
/// `GetLocalTime`; this crate has no clock of its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
    pub milli: u16,
}

impl Stamp {
    /// `20261006-153012-123`.
    ///
    /// Every field is reduced to its width first. A clock that hands back a
    /// five-digit year or `milli = 1000` would otherwise produce a name
    /// [`parse`] refuses -- a file this crate wrote and will never clean up.
    pub fn stem(&self) -> String {
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}",
            self.year % 10000,
            self.month % 100,
            self.day % 100,
            self.hour % 100,
            self.minute % 100,
            self.second % 100,
            self.milli % 1000
        )
    }

    pub fn png(&self) -> String {
        format!("{}.png", self.stem())
    }

    pub fn json(&self) -> String {
        format!("{}.json", self.stem())
    }
}

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// How far local time is ahead of UTC, in minutes, from one reading of each
/// (`GetLocalTime` and `GetSystemTime`, taken back to back).
///
/// Rounded to the minute, because the two readings are a few microseconds
/// apart and can fall either side of a second.
pub fn utc_offset_minutes(local: &Stamp, utc: &Stamp) -> i32 {
    let secs = |t: &Stamp| {
        days(t.year as i64, t.month as i64, t.day as i64) * 86400
            + t.hour as i64 * 3600
            + t.minute as i64 * 60
            + t.second as i64
    };
    let diff = secs(local) - secs(utc);
    ((diff + diff.signum() * 30) / 60) as i32
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Png,
    Json,
    /// One piece of a long screenshot: `<stem>-<n>.png`.
    Tile,
}

/// The file name of tile `n` (counted from 1) of the shot `image` -- the
/// shot's own file name with `-<n>` before the extension.
pub fn tile(image: &str, n: usize) -> String {
    format!("{}-{n}.png", image.strip_suffix(".png").unwrap_or(image))
}

/// The stem and kind of a file name this crate could have written, or `None`
/// for anything else.
///
/// Exact, on purpose: ASCII digits only, the two hyphens where they belong, a
/// lowercase extension. `IMG_20261006-153012-123.png`, `…-123.PNG`,
/// `…-123 (1).png` and `…-123.png.bak` are all somebody else's.
///
/// A `.png` may carry one more part, `-` and one to three digits: a tile of
/// a long screenshot. The stem returned for it is the shot's, without that
/// part.
pub fn parse(file_name: &str) -> Option<(&str, Kind)> {
    let (rest, json) = if let Some(s) = file_name.strip_suffix(".png") {
        (s, false)
    } else if let Some(s) = file_name.strip_suffix(".json") {
        (s, true)
    } else {
        return None;
    };
    if !rest.is_ascii() || rest.len() < 19 {
        return None;
    }
    let (stem, tail) = rest.split_at(19);
    let shaped = stem.bytes().enumerate().all(|(i, c)| match i {
        8 | 15 => c == b'-',
        _ => c.is_ascii_digit(),
    });
    let numbered = |t: &str| {
        t.strip_prefix('-').is_some_and(|d| (1..=3).contains(&d.len()) && d.bytes().all(|c| c.is_ascii_digit()))
    };
    let kind = match (tail, json) {
        ("", false) => Kind::Png,
        ("", true) => Kind::Json,
        (t, false) if numbered(t) => Kind::Tile,
        _ => return None,
    };
    shaped.then_some((stem, kind))
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: Stamp = Stamp { year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, milli: 123 };

    #[test]
    fn the_name_is_the_specified_shape() {
        assert_eq!(T.png(), "20261006-153012-123.png");
        assert_eq!(T.json(), "20261006-153012-123.json");
    }

    #[test]
    fn small_fields_are_zero_padded() {
        let t = Stamp { year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5, milli: 6 };
        assert_eq!(t.png(), "20260102-030405-006.png");
    }

    #[test]
    fn a_name_this_crate_writes_is_one_it_recognises() {
        assert_eq!(parse(&T.png()), Some(("20261006-153012-123", Kind::Png)));
        assert_eq!(parse(&T.json()), Some(("20261006-153012-123", Kind::Json)));
    }

    #[test]
    fn an_out_of_range_clock_still_writes_a_recognised_name() {
        let t = Stamp { year: 12026, month: 255, day: 255, hour: 255, minute: 255, second: 255, milli: 1000 };
        assert!(parse(&t.png()).is_some(), "{}", t.png());
    }

    fn t(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) -> Stamp {
        Stamp { year, month, day, hour, minute, second, milli: 0 }
    }

    #[test]
    fn the_utc_offset_is_local_minus_utc() {
        assert_eq!(utc_offset_minutes(&t(2026, 10, 6, 15, 30, 12), &t(2026, 10, 6, 7, 30, 12)), 480);
        assert_eq!(utc_offset_minutes(&t(2026, 10, 6, 4, 0, 0), &t(2026, 10, 6, 7, 30, 0)), -210);
        assert_eq!(utc_offset_minutes(&T, &T), 0);
    }

    #[test]
    fn the_utc_offset_survives_the_date_changing_between_the_two() {
        // 01:00 on the 1st in +08:00 is 17:00 on the last day of the month before.
        assert_eq!(utc_offset_minutes(&t(2026, 3, 1, 1, 0, 0), &t(2026, 2, 28, 17, 0, 0)), 480);
        assert_eq!(utc_offset_minutes(&t(2028, 3, 1, 1, 0, 0), &t(2028, 2, 29, 17, 0, 0)), 480, "leap year");
        assert_eq!(utc_offset_minutes(&t(2027, 1, 1, 3, 0, 0), &t(2026, 12, 31, 19, 0, 0)), 480);
        assert_eq!(utc_offset_minutes(&t(2026, 12, 31, 19, 0, 0), &t(2027, 1, 1, 0, 0, 0)), -300);
    }

    #[test]
    fn two_readings_a_second_apart_are_the_same_offset() {
        assert_eq!(utc_offset_minutes(&t(2026, 10, 6, 15, 30, 13), &t(2026, 10, 6, 7, 30, 12)), 480);
        assert_eq!(utc_offset_minutes(&t(2026, 10, 6, 15, 29, 59), &t(2026, 10, 6, 7, 30, 0)), 480);
        assert_eq!(utc_offset_minutes(&t(2026, 10, 6, 3, 59, 59), &t(2026, 10, 6, 7, 30, 0)), -210);
    }

    #[test]
    fn a_long_screenshots_tiles_are_recognised_as_that_shots() {
        assert_eq!(tile(&T.png(), 1), "20261006-153012-123-1.png");
        assert_eq!(tile(&T.png(), 12), "20261006-153012-123-12.png");
        assert_eq!(parse("20261006-153012-123-1.png"), Some(("20261006-153012-123", Kind::Tile)));
        assert_eq!(parse("20261006-153012-123-999.png"), Some(("20261006-153012-123", Kind::Tile)));
        for other in [
            "20261006-153012-123-.png",
            "20261006-153012-123-1234.png",
            "20261006-153012-123-1a.png",
            "20261006-153012-123-1.json",
            "20261006-153012-123-1-2.png",
            "20261006-153012-123_1.png",
        ] {
            assert_eq!(parse(other), None, "{other:?}");
        }
    }

    #[test]
    fn other_peoples_files_are_not_recognised() {
        for other in [
            "photo.png",
            "IMG_20261006-153012-123.png",
            "20261006-153012-123.PNG",
            "20261006-153012-123.jpg",
            "20261006-153012-123.png.bak",
            "20261006-153012-123 (1).png",
            "20261006-153012-12.png",
            "20261006-153012-1234.png",
            "20261006_153012_123.png",
            "2026100６-153012-123.png",
            "20261006-153012-123",
            ".png",
            "",
        ] {
            assert_eq!(parse(other), None, "{other:?}");
        }
    }
}
