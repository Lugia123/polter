//! Where a window of a project opens.

use polter_projectfile::{Frame, Origin};

/// A rectangle on the screens, measured as this host measures them: from
/// the top left of the primary screen, `y` growing downwards, in the
/// pixels `GetWindowRect` answers in.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    fn max_x(self) -> f64 {
        self.x + self.width
    }

    fn max_y(self) -> f64 {
        self.y + self.height
    }

    fn contains(self, other: Rect) -> bool {
        other.x >= self.x && other.y >= self.y && other.max_x() <= self.max_x() && other.max_y() <= self.max_y()
    }

    /// How much of `other` is inside this one.
    fn overlap(self, other: Rect) -> f64 {
        let w = self.max_x().min(other.max_x()) - self.x.max(other.x);
        let h = self.max_y().min(other.max_y()) - self.y.max(other.y);
        if w > 0.0 && h > 0.0 {
            w * h
        } else {
            0.0
        }
    }
}

/// The frame to open a window at, or none to let it open where a new
/// window would.
///
/// The file records where the window *was* and nothing else. The screen it
/// was on may be gone, smaller, or somewhere else, so the frame is brought
/// back onto a screen that is there: untouched when one of `screens` (each
/// the part of a screen a window may use -- its work area) holds all of it;
/// otherwise moved onto the screen that holds the most of it -- the first,
/// when none holds any -- and made no bigger than that screen.
///
/// None when nothing was recorded (every window of a format 1 file), when
/// it was measured from the other corner (a file written on macOS: the
/// numbers are not a place here), and when it is not a rectangle.
///
/// **A screen whose scale has changed since the save is not allowed for.**
/// The file has four numbers and no scale, so the frame is taken as the
/// pixels it was, and brought back onto a screen like any other. A window
/// saved on a screen at 100% and opened on one at 150% is the same pixels
/// across and so holds fewer columns; it is not made bigger to match. (暂定:
/// the alternative needs the scale in the file, which is three
/// implementations' to change together.)
pub fn frame(stored: Option<Frame>, screens: &[Rect]) -> Option<Rect> {
    let stored = stored.filter(|f| f.origin == Origin::TopLeft)?;
    // Written this way round so that a number that is not one fails it too.
    if !(stored.width >= 1.0 && stored.height >= 1.0) || !stored.x.is_finite() || !stored.y.is_finite() {
        return None;
    }
    let rect = Rect { x: stored.x, y: stored.y, width: stored.width, height: stored.height };
    if screens.is_empty() || screens.iter().any(|s| s.contains(rect)) {
        return Some(rect);
    }

    let mut screen = screens[0];
    for candidate in &screens[1..] {
        if candidate.overlap(rect) > screen.overlap(rect) {
            screen = *candidate;
        }
    }
    let width = rect.width.min(screen.width);
    let height = rect.height.min(screen.height);
    Some(Rect {
        x: rect.x.max(screen.x).min(screen.max_x() - width),
        y: rect.y.max(screen.y).min(screen.max_y() - height),
        width,
        height,
    })
}

/// Where the pages of one window of a project go when none of them is open.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Place {
    /// A window of their own: at this frame, or -- none -- where any new
    /// window goes.
    OwnWindow(Option<Rect>),
    /// Tabs of a window that is there already.
    Tabs(Home),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Home {
    /// The window the caller named: the control room's rule for where a
    /// tab it opens goes.
    Named,
    /// The terminal window the person is in.
    Current,
}

/// Where a window of a project opens.
///
/// - **A window whose frame was recorded opens as its own window**, at that
///   frame brought back onto a screen (`frame`). Where a person put a
///   window is what a project is asked to remember.
/// - **A window with no frame opens as tabs of the window the person is
///   in** -- every project from before frames were recorded, until it is
///   next saved, and that is how those always opened. With no terminal
///   window to go into it is a window of its own, wherever a new window
///   goes. "No frame" is everything `frame` answers none to: one recorded
///   from the other corner is not a place here.
/// - Each window by its own frame: a file with one of each opens one of
///   each.
/// - **Opened from the control room, the first window goes where the
///   control room says a tab it opens goes** (`Named`), frame or none; the
///   rest by the rules above.
pub fn place(stored: Option<Frame>, is_first_window: bool, home_is_named: bool, has_current_window: bool, screens: &[Rect]) -> Place {
    if is_first_window && home_is_named {
        return Place::Tabs(Home::Named);
    }
    if let Some(rect) = frame(stored, screens) {
        return Place::OwnWindow(Some(rect));
    }
    if has_current_window {
        Place::Tabs(Home::Current)
    } else {
        Place::OwnWindow(None)
    }
}

/// A window's frame as the file records it: measured from the top left,
/// which says it is this host's.
pub fn stored(rect: Rect) -> Frame {
    Frame { origin: Origin::TopLeft, x: rect.x, y: rect.y, width: rect.width, height: rect.height }
}
