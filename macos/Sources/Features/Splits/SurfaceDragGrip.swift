import Foundation

/// Where a pane is picked up to be dragged to another split, tab or window
/// (task 1508).
///
/// Before panes had titles the only place was the small handle at the top
/// middle of the terminal (`SurfaceGrabHandle`). A pane that wears a frame
/// now has a title, and the title is where it is picked up; the handle is
/// for the panes that have none. Nothing in this file touches a view.
enum SurfaceDragGrip {
    /// `drag-handle`, as this needs it.
    enum Setting {
        case always, auto, never
    }

    /// Where the pane can be picked up, if anywhere.
    enum Place: Equatable {
        /// By its title.
        case title
        /// By the handle at the top middle of the terminal.
        case handle
        /// Not at all.
        case none
    }

    /// Where the pane is picked up.
    ///
    /// - `titled`: it wears a frame with a title (`PaneFrame.drawn` is not nil).
    /// - `lent`: its terminal is on the control room's right-hand side and
    ///   the pane shows a placeholder, which had no handle either.
    /// - `fullscreen`, `split`: its window is fullscreen; its tab has more
    ///   than one pane. With `auto` a fullscreen tab of one pane cannot be
    ///   picked up, by a handle or by a title.
    static func place(setting: Setting, titled: Bool, lent: Bool, fullscreen: Bool, split: Bool) -> Place {
        guard !lent else { return .none }
        let allowed = switch setting {
        case .always: true
        case .never: false
        case .auto: !fullscreen || split
        }
        guard allowed else { return .none }
        return titled ? .title : .handle
    }

    /// How far the pointer has to move, held down on a title, before it is
    /// a drag and not a click. The handle has none: it does nothing else.
    static let titleDragThreshold: CGFloat = 4

    /// Whether the pointer, held down at `start`, has gone far enough to
    /// `now` to be a drag.
    static func isDrag(from start: CGPoint, to now: CGPoint, threshold: CGFloat) -> Bool {
        hypot(now.x - start.x, now.y - start.y) >= threshold
    }
}
