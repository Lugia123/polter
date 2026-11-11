//! v8 (3178): same OKLCH/sRGB formula as ControlRoomPerfColor.swift.
use crate::level::Level;
use crate::look::{perf_load as band, Rgba, Theme};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    None,
    Warn1,
    Warn2,
    Stopped,
}
impl Event {
    pub fn priority(self) -> f64 {
        match self {
            Self::None => band::PRIORITY_NONE,
            Self::Warn1 => band::PRIORITY_WARN1,
            Self::Warn2 => band::PRIORITY_WARN2,
            Self::Stopped => band::PRIORITY_STOPPED,
        }
    }
}
pub fn highest(events: &[Event]) -> Event {
    events.iter().copied().fold(
        Event::None,
        |a, b| if b.priority() > a.priority() { b } else { a },
    )
}
pub fn event(level: Level) -> Event {
    match level {
        Level::Killed => Event::Stopped,
        Level::Warn1 => Event::Warn1,
        Level::Warn2 | Level::Warn3 | Level::Warn4 | Level::Withheld => Event::Warn2,
        _ => Event::None,
    }
}
pub fn load(fraction: f64) -> Rgba {
    let p = if fraction.is_finite() {
        fraction.clamp(0.0, 1.0)
    } else {
        0.0
    };
    let t = p.powf(band::POWER);
    let l = band::L0 + (band::L1 - band::L0) * t;
    let c = band::C0 + (band::C1 - band::C0) * t;
    let h = band::HUE.to_radians();
    let (a, b) = (c * h.cos(), c * h.sin());
    let x = (l + 0.3963377774 * a + 0.2158037573 * b).powi(3);
    let y = (l - 0.1055613458 * a - 0.0638541728 * b).powi(3);
    let z = (l - 0.0894841775 * a - 1.2914855480 * b).powi(3);
    let byte = |v: f64| {
        let s = if v <= 0.0031308 {
            12.92 * v
        } else {
            1.055 * v.powf(1.0 / 2.4) - 0.055
        };
        (s.clamp(0.0, 1.0) * 255.0).round() as u8
    };
    Rgba {
        r: byte(4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z),
        g: byte(-1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z),
        b: byte(-0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z),
        a: 1.0,
    }
}
pub fn paint(fraction: Option<f64>, ev: Event, theme: &Theme) -> Rgba {
    match ev {
        Event::Warn1 => theme.perf_event_warn1,
        Event::Warn2 => theme.perf_event_warn2,
        Event::Stopped => theme.perf_event_stopped,
        Event::None => fraction.map(load).unwrap_or(theme.level_ok),
    }
}

pub fn curve_event(fraction: f64, warnings: &[f64], stopped: bool) -> Event {
    let mut events = if stopped {
        vec![Event::Stopped]
    } else {
        Vec::new()
    };
    for (i, &threshold) in warnings.iter().enumerate() {
        if fraction >= threshold {
            events.push(if i == 0 { Event::Warn1 } else { Event::Warn2 });
        }
    }
    highest(&events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::DARK;
    #[test]
    fn v8_3178_sqrt_samples_and_monotonic_load() {
        let expected = [
            [158, 158, 158],
            [139, 171, 205],
            [130, 176, 224],
            [122, 180, 238],
            [115, 182, 250],
        ];
        for (i, rgb) in expected.iter().enumerate() {
            let c = load(i as f64 / 4.0);
            assert_eq!(
                [c.r, c.g, c.b],
                *rgb,
                "3178 sqrt load colour at quarter sample {i}"
            );
        }
        let mut old = load(0.0);
        for i in 1..=1000 {
            let c = load(i as f64 / 1000.0);
            assert!(
                c.r <= old.r && c.b >= old.b,
                "3178 load red decreases and blue increases"
            );
            old = c;
        }
    }
    #[test]
    fn v8_3178_events_choose_highest_not_first() {
        assert_eq!(
            highest(&[Event::Warn1, Event::Warn2, Event::Stopped]),
            Event::Stopped,
            "3178 interrupted beats crossed warning 2"
        );
        assert_eq!(curve_event(0.6, &[0.25, 0.5], false), Event::Warn2);
        assert_eq!(curve_event(0.3, &[0.25, 0.5], false), Event::Warn1);
        assert_eq!(curve_event(0.6, &[0.25, 0.5], true), Event::Stopped);
        for (event, rgb) in [
            (Event::Warn1, [232, 193, 90]),
            (Event::Warn2, [240, 138, 75]),
            (Event::Stopped, [252, 79, 78]),
        ] {
            let c = paint(Some(0.5), event, &DARK);
            assert_eq!([c.r, c.g, c.b], rgb);
            assert_eq!(c.a, 1.0);
        }
    }
    #[test]
    fn v8_3178_old_reply_uses_legacy_grey_without_a_load() {
        let old = crate::perf::decode(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/testdata/resources-day.json"
        )))
        .unwrap();
        assert_eq!(old.machine.physical_bytes, None);
        assert!(old.grid.panes.iter().all(|p| p.load_fractions.is_empty()));
        assert!(old.cards.iter().all(|c| c.load_fraction.is_none()));
        assert_eq!(paint(None, Event::None, &DARK), DARK.level_ok);
    }
    #[test]
    fn v8_3178_new_fields_decode_without_changing_legacy_fraction() {
        let fixture = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/testdata/resources-day.json"
        ));
        let text=fixture.replacen("\"machine\": {","\"machine\": {\"physical_bytes\":34359738368,",1)
            .replacen("\"line_at\": null","\"load_fraction\":0.25,\"load_cap\":\"physical\",\"memory_warn_fractions\":[0.1,0.2],\"stopped_at_ms\":123,\"line_at\": null",1)
            .replacen("\"cells\": [","\"load_fractions\":[0.25],\"cells\": [",1);
        let old = crate::perf::decode(fixture).unwrap();
        let new = crate::perf::decode(&text).unwrap();
        assert_eq!(new.machine.physical_bytes, Some(34359738368));
        assert_eq!(new.cards[0].load_fraction, Some(0.25));
        assert_eq!(
            new.cards[0].dial, old.cards[0].dial,
            "3178 additive fields preserve legacy kill-line fraction"
        );
        assert_eq!(new.grid.panes[0].load_fractions[0], Some(0.25));
    }
    #[test]
    fn v8_3178_actual_legend_shapes_have_no_text_or_event_edge() {
        use crate::{
            layout::Rect,
            perf_scene::{legend_swatch, Draw},
            scene::Item,
        };
        for level in [
            Level::None,
            Level::Ok,
            Level::Warn1,
            Level::Warn2,
            Level::Killed,
        ] {
            let shapes = legend_swatch(
                level,
                Rect {
                    x: 0.0,
                    y: 0.0,
                    w: 144.0,
                    h: 12.0,
                },
                &DARK,
                DARK.perf_card,
                1.0,
            );
            assert!(
                shapes.iter().all(|d| matches!(
                    d,
                    Draw::Item(Item::Fill { .. } | Item::Round { edge: None, .. })
                )),
                "3178 legend swatches contain only colour geometry, never text"
            );
        }
    }
}
