//! A chat row's date and time, apart from the window.
//!
//! The host turns an epoch millisecond into local calendar fields
//! (`SystemTimeToTzSpecificLocalTime`) and hands them here. **Nothing in
//! this module knows a timezone**: comparing two rows' local day is a
//! comparison of the fields the host already resolved, so DST and the
//! person's own clock are the platform's answer, not a guess here.
//!
//! The words a row shows around these values -- the channel tag, the
//! viewer's "today" -- stay in the host, where the catalogue is.

/// One message's local calendar fields.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Parts {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
}

/// A day compared as YYYYMMDD; equal keys are the same local day.
pub fn day_key(p: &Parts) -> i64 {
    i64::from(p.year) * 10_000 + i64::from(p.month) * 100 + i64::from(p.day)
}

/// `YYYY-MM-DD`, the date divider's own text.
pub fn date_label(p: &Parts) -> String {
    format!("{:04}-{:02}-{:02}", p.year, p.month, p.day)
}

/// `HH:MM:SS`, the message header's own text.
pub fn time_label(p: &Parts) -> String {
    format!("{:02}:{:02}:{:02}", p.hour, p.minute, p.second)
}

/// Whether `cur` starts a new local day after `prev`. `None` (no earlier
/// row) starts one.
pub fn starts_day(prev: Option<i64>, cur: i64) -> bool {
    prev != Some(cur)
}

/// A message's source: the group's own conversation, or one task's channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    Group,
    Task(u64),
}

pub fn channel_of(channel: u64) -> Channel {
    if channel == 0 {
        Channel::Group
    } else {
        Channel::Task(channel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parts(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Parts {
        Parts {
            year,
            month,
            day,
            hour,
            minute,
            second,
        }
    }

    #[test]
    fn a_day_is_compared_by_its_local_fields_and_a_time_is_not_a_clock_read() {
        let before = parts(2026, 11, 4, 23, 59, 59);
        let after = parts(2026, 11, 5, 0, 0, 1);
        assert_eq!(day_key(&before), 20261104);
        assert_eq!(day_key(&after), 20261105);
        assert!(starts_day(Some(day_key(&before)), day_key(&after)));
        assert!(!starts_day(Some(day_key(&after)), day_key(&after)));
        assert!(starts_day(None, day_key(&after)));
        assert_eq!(date_label(&after), "2026-11-05");
        assert_eq!(time_label(&before), "23:59:59");
    }

    #[test]
    fn zero_is_the_group_channel_and_anything_else_names_a_task() {
        assert_eq!(channel_of(0), Channel::Group);
        assert_eq!(channel_of(2781), Channel::Task(2781));
    }
}
