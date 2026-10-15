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
    /// - `controlRoom`: this is the terminal itself, shown on the control
    ///   room's right-hand side (task 1566). The control room is not a split
    ///   and nothing in it is dragged, **whatever `drag-handle` says**:
    ///   `always` included.
    /// - `split`: its tab has more than one pane. With `auto` a tab of one
    ///   pane -- a stack included -- cannot be picked up, by a handle or by
    ///   a title, fullscreen or not: it moves by its tab (task 1566). It
    ///   used to keep the handle unless the window was fullscreen.
    static func place(setting: Setting, titled: Bool, lent: Bool, controlRoom: Bool, split: Bool) -> Place {
        guard !lent, !controlRoom else { return .none }
        let allowed = switch setting {
        case .always: true
        case .never: false
        case .auto: split
        }
        guard allowed else { return .none }
        return titled ? .title : .handle
    }

    /// What a pane's title does, when the pane has one.
    enum TitleGrip: Equatable {
        /// Held and moved, it drags the pane; clicked, it focuses it.
        case drag
        /// Clicked, it focuses the pane. It does not drag, and the pointer
        /// over it is not a hand: nothing suggests a drag that will not come.
        case click
        /// Nothing at all.
        case none
    }

    /// What the title of a titled pane does (task 1514).
    ///
    /// **`drag-handle` decides whether a pane is dragged, not whether its
    /// title can be clicked.** The click used to ride on the drag layer, so
    /// with `never` -- and with `auto` in a tab of one pane -- there was no
    /// layer and a click on the title did nothing, while the
    /// same click with `auto` focused the pane. Only a lent pane's
    /// placeholder takes no click: its terminal is in the control room.
    static func titleGrip(setting: Setting, lent: Bool, split: Bool) -> TitleGrip {
        guard !lent else { return .none }
        return place(setting: setting, titled: true, lent: false, controlRoom: false, split: split) == .title
            ? .drag : .click
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
