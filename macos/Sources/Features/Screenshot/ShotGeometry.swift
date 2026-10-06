import CoreGraphics

/// The geometry of picking a region of a frozen screen
/// (`dev-docs/poltergeist/screenshot.md`, 3.2).
///
/// Everything here is in **points with the origin at the top left of one
/// display and y growing downwards** -- the coordinates of the overlay view
/// that covers that display -- until `pixelRect` turns a selection into the
/// pixels of the captured image. CoreGraphics only, no views, so that each
/// rule can be tested on its own.
enum ShotGeometry {
    /// A press that moves further than this before release is a drag, and
    /// draws a region; one that does not is a click, and picks the window
    /// under it.
    static let dragThreshold: CGFloat = 4

    /// How close to a handle a press has to be to take hold of it.
    static let handleSlop: CGFloat = 6

    /// The space between a selection and its toolbar.
    static let toolbarGap: CGFloat = 8

    // MARK: Click or drag

    /// Whether a press at `start` released (or currently) at `end` has
    /// travelled far enough to be a drag: **more than** the threshold along
    /// either axis.
    static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        max(abs(end.x - start.x), abs(end.y - start.y)) > dragThreshold
    }

    // MARK: Regions

    /// The rectangle between two corners, kept inside `bounds`.
    ///
    /// A drag that leaves the display is clamped to it rather than carried
    /// onto the next one: a selection belongs to the display it started on.
    static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        let a = clamp(a, to: bounds)
        let b = clamp(b, to: bounds)
        return CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(p.x, bounds.minX), bounds.maxX),
            y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: Windows

    /// A window on the frozen screen, in this display's coordinates.
    struct Window: Equatable {
        var frame: CGRect
        var app: String?
        var title: String?
    }

    /// The topmost window under `point`, with the part of its frame that is
    /// on this display.
    ///
    /// `windows` is front to back, the order the window server lists them
    /// in, so the first hit is the one the person can see at that point. A
    /// window partly off the display is selected as far as the display goes.
    static func window(
        at point: CGPoint,
        in windows: [Window],
        within bounds: CGRect
    ) -> (window: Window, visible: CGRect)? {
        for window in windows {
            guard window.frame.contains(point) else { continue }
            let visible = window.frame.intersection(bounds)
            guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { continue }
            return (window, visible)
        }
        return nil
    }

    // MARK: Handles

    /// The eight places a selection can be resized from, clockwise from the
    /// top left.
    enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Which edges this handle moves.
        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    static func point(of handle: Handle, on rect: CGRect) -> CGPoint {
        let x: CGFloat = handle.movesLeft ? rect.minX : (handle.movesRight ? rect.maxX : rect.midX)
        let y: CGFloat = handle.movesTop ? rect.minY : (handle.movesBottom ? rect.maxY : rect.midY)
        return CGPoint(x: x, y: y)
    }

    /// The handle a press at `point` takes hold of, if it is near one. When
    /// a selection is small enough for two to be in reach, the nearer wins.
    static func handle(at point: CGPoint, on rect: CGRect, slop: CGFloat = handleSlop) -> Handle? {
        var best: (handle: Handle, distance: CGFloat)?
        for handle in Handle.allCases {
            let p = self.point(of: handle, on: rect)
            let distance = max(abs(p.x - point.x), abs(p.y - point.y))
            guard distance <= slop else { continue }
            if best == nil || distance < best!.distance { best = (handle, distance) }
        }
        return best?.handle
    }

    /// `rect` with the edges `handle` moves taken to `point`, inside `bounds`.
    ///
    /// Dragging an edge past the opposite one turns the selection inside out
    /// rather than stopping: the result is always a proper rectangle.
    static func resize(
        _ rect: CGRect,
        dragging handle: Handle,
        to point: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        let p = clamp(point, to: bounds)
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left = p.x }
        if handle.movesRight { right = p.x }
        if handle.movesTop { top = p.y }
        if handle.movesBottom { bottom = p.y }
        return CGRect(
            x: min(left, right), y: min(top, bottom),
            width: abs(right - left), height: abs(bottom - top))
    }

    /// `rect` moved by `delta` without changing size, stopped at the edges
    /// of `bounds`.
    static func move(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: rect.minX + delta.width, y: rect.minY + delta.height)
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }

    // MARK: Toolbar

    enum ToolbarPlacement: Equatable {
        case below, above, inside
    }

    /// Where a toolbar of `size` goes: under the selection, its right edge on
    /// the selection's; above when there is no room under; inside the
    /// selection's bottom edge when there is room for neither (a selection
    /// the full height of the display).
    static func toolbar(
        size: CGSize,
        for selection: CGRect,
        within bounds: CGRect,
        gap: CGFloat = toolbarGap
    ) -> (origin: CGPoint, placement: ToolbarPlacement) {
        let placement: ToolbarPlacement
        let y: CGFloat
        if selection.maxY + gap + size.height <= bounds.maxY {
            placement = .below
            y = selection.maxY + gap
        } else if selection.minY - gap - size.height >= bounds.minY {
            placement = .above
            y = selection.minY - gap - size.height
        } else {
            placement = .inside
            y = selection.maxY - gap - size.height
        }
        // Right-aligned, then pulled back onto the display.
        var x = selection.maxX - size.width
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        return (CGPoint(x: x, y: y), placement)
    }

    // MARK: Pixels

    /// A selection in points as a rectangle of whole pixels of the captured
    /// image, which is `scale` pixels to the point.
    ///
    /// Each **edge** is rounded, not the origin and the size: rounding the
    /// size separately can put the far edge a pixel away from where the
    /// selection was drawn, and two selections sharing an edge would then
    /// overlap or leave a gap.
    static func pixelRect(_ rect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let left = min(max((rect.minX * scale).rounded(), 0), imageSize.width)
        let top = min(max((rect.minY * scale).rounded(), 0), imageSize.height)
        let right = min(max((rect.maxX * scale).rounded(), 0), imageSize.width)
        let bottom = min(max((rect.maxY * scale).rounded(), 0), imageSize.height)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
