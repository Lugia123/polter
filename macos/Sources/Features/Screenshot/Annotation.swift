import Foundation

/// One annotation: a shape, and the colour and step it is drawn with.
///
/// **Coordinates are the frozen display's, not the selection's**
/// (`dev-docs/poltergeist/screenshot.md`, 9.4): an annotation stays where
/// it was drawn when the selection is moved or resized afterwards, and is
/// made relative to the selection once, on the way out. A port of the
/// Windows host's `annot.rs`; see `PixelGeometry.swift`.
struct Annotation: Equatable {
    enum Shape: Equatable {
        /// A hollow rectangle.
        case rect(PixelRect)
        /// A hollow ellipse inscribed in the rectangle.
        case ellipse(PixelRect)
        case line(from: PixelPoint, to: PixelPoint)
        case arrow(from: PixelPoint, to: PixelPoint)
        /// A freehand line.
        case pen([PixelPoint])
        /// A freehand line four times as wide, laid over the picture like a
        /// marker rather than painted on it.
        case highlighter([PixelPoint])
        /// `at` is the top left of the first line. `size` is what the text
        /// measures in the font it is drawn in, kept so that a click can be
        /// tested against it without a font.
        case text(at: PixelPoint, text: String, size: PixelSize)
        /// A numbered circle centred on `at`, with the sentence typed after
        /// placing it. `size` is the sentence's measured size.
        case number(n: Int, at: PixelPoint, text: String, size: PixelSize)
        /// A rectangle whose contents are made unreadable.
        case mosaic(PixelRect)
    }

    struct PixelSize: Equatable {
        var w: Int
        var h: Int

        init(_ w: Int, _ h: Int) {
            self.w = w
            self.h = h
        }

        static let zero = PixelSize(0, 0)
    }

    /// Where a shape can be taken hold of to change it.
    enum Grip: Equatable {
        /// One of the eight handles of a rectangle, an ellipse or a mosaic.
        case box(PixelHandle)
        /// The start (`false`) or the end (`true`) of a line or an arrow.
        case end(Bool)
    }

    var shape: Shape
    /// Index into `ShotStyle.colours`. Unused by a mosaic.
    var colour: Int
    /// The step of whichever property the shape has: thickness, font size
    /// or block size.
    var level: Int
    /// A colour that is not one of the presets. Only an agent's annotation
    /// has one -- the toolbar offers the nine and nothing else -- and when
    /// it is set, `colour` is not what is drawn.
    var custom: ShotStyle.RGB?

    /// The colour this is drawn in.
    var rgb: ShotStyle.RGB { custom ?? ShotStyle.colour(colour) }

    // MARK: Numbers

    /// A number's circle: its radius in pixels. The diameter is one and a
    /// half times the font's height.
    static func numberRadius(level: Int, scale: Double) -> Int {
        (ShotStyle.fontPx(level: level, scale: scale) * 3 + 2) / 4
    }

    /// Where a number's sentence starts (top left), given the circle's
    /// centre: to the right of the circle by 0.3 of the font's height,
    /// centred on it vertically.
    static func captionOrigin(at: PixelPoint, level: Int, scale: Double, captionHeight: Int) -> PixelPoint {
        let font = ShotStyle.fontPx(level: level, scale: scale)
        return PixelPoint(
            at.x + numberRadius(level: level, scale: scale) + (font * 3 + 5) / 10,
            at.y - Self.half(captionHeight))
    }

    /// Division that truncates towards zero for a negative, as it does on
    /// the other host. (Swift's `/` on `Int` does too; this names it.)
    private static func half(_ value: Int) -> Int { value / 2 }

    // MARK: What it is

    /// The tool that makes this kind of annotation.
    var tool: AnnotationTool {
        switch shape {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .number: return .number
        case .mosaic: return .mosaic
        }
    }

    /// What the property row shows for it.
    var props: AnnotationTool.Props { tool.props }

    /// The stroke's width in pixels, for the shapes that have one.
    func strokePx(scale: Double) -> Int {
        let width = ShotStyle.widthPx(level: level, scale: scale)
        if case .highlighter = shape { return width * ShotStyle.highlighterFactor }
        return width
    }

    /// The rectangle everything this annotation draws falls inside.
    func bounds(scale: Double) -> PixelRect {
        func grow(_ r: PixelRect, _ by: Int) -> PixelRect {
            PixelRect(r.x - by, r.y - by, r.w + by * 2, r.h + by * 2)
        }
        let half = (strokePx(scale: scale) + 1) / 2
        let empty = PixelRect(0, 0, 0, 0)

        switch shape {
        case let .rect(r), let .ellipse(r):
            return grow(r, half)
        case let .mosaic(r):
            return r
        case let .line(from, to):
            return grow(Self.bbox([from, to]) ?? empty, half)
        case let .arrow(from, to):
            // An arrow's head is five widths long and as wide.
            return grow(Self.bbox([from, to]) ?? empty, strokePx(scale: scale) * 5)
        case let .pen(points), let .highlighter(points):
            return grow(Self.bbox(points) ?? empty, half)
        case let .text(at, _, size):
            return PixelRect(at.x, at.y, size.w, size.h)
        case let .number(_, at, _, size):
            let r = Self.numberRadius(level: level, scale: scale)
            let circle = PixelRect(at.x - r, at.y - r, r * 2, r * 2)
            if size.w <= 0 { return circle }
            let c = Self.captionOrigin(at: at, level: level, scale: scale, captionHeight: size.h)
            return PixelRect(
                left: min(circle.x, c.x), top: min(circle.y, c.y),
                right: max(circle.right, c.x + size.w), bottom: max(circle.bottom, c.y + size.h))
        }
    }

    // MARK: Clicking on it

    /// Whether a click at `p` lands on this annotation.
    ///
    /// **By the stroke, not by the bounding box** (9.4): the inside of a
    /// hollow rectangle is not the rectangle, and something drawn inside it
    /// has to stay clickable. A thin line is given a few pixels either side
    /// so that it can be hit at all. Text and numbers are hit anywhere in
    /// their box; a mosaic anywhere in its rectangle.
    func hit(_ p: PixelPoint, scale: Double) -> Bool {
        let reach = max(Double(strokePx(scale: scale)) / 2, 4 * scale)
        func onPath(_ points: [PixelPoint]) -> Bool {
            if points.count == 1 { return Self.distance(p, points[0]) <= reach }
            guard points.count >= 2 else { return false }
            for i in 0..<(points.count - 1) where Self.distanceToSegment(p, points[i], points[i + 1]) <= reach {
                return true
            }
            return false
        }

        switch shape {
        case let .rect(r):
            let a = r.origin, b = PixelPoint(r.right, r.y)
            let c = PixelPoint(r.right, r.bottom), d = PixelPoint(r.x, r.bottom)
            return onPath([a, b, c, d, a])
        case let .ellipse(r):
            return Self.distanceToEllipse(p, r) <= reach
        case let .line(from, to), let .arrow(from, to):
            return onPath([from, to])
        case let .pen(points), let .highlighter(points):
            return onPath(points)
        case .text, .number, .mosaic:
            return bounds(scale: scale).contains(p)
        }
    }

    /// Whether `p` is inside this annotation's outline when that outline is
    /// all it has: a hollow rectangle or ellipse. Not a hit (`hit` is by the
    /// stroke, so that what is drawn inside stays clickable), but where the
    /// shape *is* once it is the selected one -- the pointer over it is a
    /// hand, and a press there carries it (task 1198). False for everything
    /// else: those are hit anywhere they are, or on their line.
    func interiorContains(_ p: PixelPoint) -> Bool {
        switch shape {
        case let .rect(r):
            return r.contains(p)
        case let .ellipse(r):
            let a = Double(r.w) / 2, b = Double(r.h) / 2
            guard a > 0, b > 0 else { return false }
            let x = Double(p.x) - (Double(r.x) + a), y = Double(p.y) - (Double(r.y) + b)
            return (x / a) * (x / a) + (y / b) * (y / b) <= 1
        default:
            return false
        }
    }

    private static func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// How far `p` is from the segment `a`-`b`.
    static func distanceToSegment(_ p: PixelPoint, _ a: PixelPoint, _ b: PixelPoint) -> Double {
        let vx = Double(b.x - a.x), vy = Double(b.y - a.y)
        let len2 = vx * vx + vy * vy
        if len2 == 0 { return distance(p, a) }
        let raw = (Double(p.x - a.x) * vx + Double(p.y - a.y) * vy) / len2
        let t = min(max(raw, 0), 1)
        let cx = Double(a.x) + t * vx, cy = Double(a.y) + t * vy
        let dx = Double(p.x) - cx, dy = Double(p.y) - cy
        return (dx * dx + dy * dy).squareRoot()
    }

    /// How far `p` is from the outline of the ellipse inscribed in `r`,
    /// measured along the line from the centre through `p`. Exact for a
    /// circle and close enough for a click everywhere else.
    private static func distanceToEllipse(_ p: PixelPoint, _ r: PixelRect) -> Double {
        let a = Double(r.w) / 2, b = Double(r.h) / 2
        guard a > 0, b > 0 else { return .infinity }
        let x = Double(p.x) - (Double(r.x) + a), y = Double(p.y) - (Double(r.y) + b)
        let radius = (x * x + y * y).squareRoot()
        let k = ((x / a) * (x / a) + (y / b) * (y / b)).squareRoot()
        if k == 0 { return min(a, b) }
        return abs(radius - radius / k)
    }

    /// The topmost annotation under `p`: the last one drawn that the point
    /// hits.
    static func hitTest(_ items: [Annotation], at p: PixelPoint, scale: Double) -> Int? {
        items.lastIndex { $0.hit(p, scale: scale) }
    }

    // MARK: Moving and reshaping

    /// The same annotation moved by `(dx, dy)`.
    func moved(dx: Int, dy: Int) -> Annotation {
        func m(_ p: PixelPoint) -> PixelPoint { PixelPoint(p.x + dx, p.y + dy) }
        func mr(_ r: PixelRect) -> PixelRect { PixelRect(r.x + dx, r.y + dy, r.w, r.h) }
        let moved: Shape
        switch shape {
        case let .rect(r): moved = .rect(mr(r))
        case let .ellipse(r): moved = .ellipse(mr(r))
        case let .mosaic(r): moved = .mosaic(mr(r))
        case let .line(from, to): moved = .line(from: m(from), to: m(to))
        case let .arrow(from, to): moved = .arrow(from: m(from), to: m(to))
        case let .pen(points): moved = .pen(points.map(m))
        case let .highlighter(points): moved = .highlighter(points.map(m))
        case let .text(at, text, size): moved = .text(at: m(at), text: text, size: size)
        case let .number(n, at, text, size): moved = .number(n: n, at: m(at), text: text, size: size)
        }
        return Annotation(shape: moved, colour: colour, level: level, custom: custom)
    }

    /// The same annotation in a space whose origin is `origin`.
    func relative(to origin: PixelPoint) -> Annotation {
        moved(dx: -origin.x, dy: -origin.y)
    }

    /// Where this annotation can be reshaped from: eight handles for a
    /// rectangle, an ellipse and a mosaic, the two ends of a line and an
    /// arrow, and nowhere for the rest -- they only move.
    var grips: [(grip: Grip, at: PixelPoint)] {
        switch shape {
        case let .rect(r), let .ellipse(r), let .mosaic(r):
            return PixelHandle.all.map { (.box($0), $0.at(r)) }
        case let .line(from, to), let .arrow(from, to):
            return [(.end(false), from), (.end(true), to)]
        default:
            return []
        }
    }

    /// The grip within `reach` pixels of `p`, if any.
    func grip(at p: PixelPoint, reach: Int) -> Grip? {
        grips.first { abs(p.x - $0.at.x) <= reach && abs(p.y - $0.at.y) <= reach }?.grip
    }

    /// Bounds a reshape is never stopped by.
    private static let everywhere = PixelRect(-(1 << 29), -(1 << 29), 1 << 30, 1 << 30)

    /// The same annotation with `grip` dragged to `to`. A grip that is not
    /// this shape's changes nothing.
    func reshaped(_ grip: Grip, to: PixelPoint) -> Annotation {
        let reshaped: Shape
        switch (shape, grip) {
        case let (.rect(r), .box(h)):
            reshaped = .rect(PixelGeometry.resize(r, dragging: h, to: to, within: Self.everywhere))
        case let (.ellipse(r), .box(h)):
            reshaped = .ellipse(PixelGeometry.resize(r, dragging: h, to: to, within: Self.everywhere))
        case let (.mosaic(r), .box(h)):
            reshaped = .mosaic(PixelGeometry.resize(r, dragging: h, to: to, within: Self.everywhere))
        case let (.line(from, end), .end(isEnd)):
            reshaped = isEnd ? .line(from: from, to: to) : .line(from: to, to: end)
        case let (.arrow(from, end), .end(isEnd)):
            reshaped = isEnd ? .arrow(from: from, to: to) : .arrow(from: to, to: end)
        default:
            reshaped = shape
        }
        return Annotation(shape: reshaped, colour: colour, level: level, custom: custom)
    }

    /// Whether the shape is too small to be worth keeping: a rectangle,
    /// ellipse or mosaic under two pixels either way, a line of no length,
    /// a freehand stroke of a single point, a text with nothing in it.
    var isDegenerate: Bool {
        switch shape {
        case let .rect(r), let .ellipse(r), let .mosaic(r):
            return r.w < 2 || r.h < 2
        case let .line(from, to), let .arrow(from, to):
            return from == to
        case let .pen(points), let .highlighter(points):
            return points.count < 2
        case let .text(_, text, _):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number:
            return false
        }
    }

    // MARK: Drawing aids

    /// The number the next numbered circle gets: one more than the highest
    /// there is, so undoing ③ makes the next one ③ again, and deleting ②
    /// from the middle does not renumber anything.
    static func nextNumber(_ items: [Annotation]) -> Int {
        let highest = items.compactMap { item -> Int? in
            if case let .number(n, _, _, _) = item.shape { return n }
            return nil
        }.max() ?? 0
        return highest + 1
    }

    /// The smallest rectangle holding every point, both ends included. Nil
    /// for no points.
    static func bbox(_ points: [PixelPoint]) -> PixelRect? {
        guard let first = points.first else { return nil }
        var l = first.x, t = first.y, r = first.x, b = first.y
        for p in points {
            l = min(l, p.x)
            t = min(t, p.y)
            r = max(r, p.x)
            b = max(b, p.y)
        }
        return PixelRect(left: l, top: t, right: r + 1, bottom: b + 1)
    }

    /// A line or arrow from `from` towards `to`, turned to the nearest
    /// multiple of 45 degrees and kept the same length (shift held while
    /// drawing).
    static func snap45(from: PixelPoint, to: PixelPoint) -> PixelPoint {
        let dx = Double(to.x - from.x), dy = Double(to.y - from.y)
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 { return to }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return PixelPoint(
            from.x + Int((length * cos(angle)).rounded()),
            from.y + Int((length * sin(angle)).rounded()))
    }

    /// The corner opposite `from` of the square a drag towards `to` makes
    /// (shift held while drawing a rectangle or an ellipse): the longer of
    /// the two sides, in the drag's direction on each axis.
    static func squareCorner(from: PixelPoint, to: PixelPoint) -> PixelPoint {
        let side = max(abs(to.x - from.x), abs(to.y - from.y))
        func sign(_ d: Int) -> Int { d < 0 ? -1 : 1 }
        return PixelPoint(from.x + side * sign(to.x - from.x), from.y + side * sign(to.y - from.y))
    }

    /// The annotations that reach into `selection`, moved into the image's
    /// coordinates. Ones wholly outside are left out; ones partly outside
    /// keep their true geometry, so a coordinate can be negative or past
    /// the image's size -- the picture is cut at the edge, the description
    /// is not bent to it.
    static func exported(_ items: [Annotation], selection: PixelRect, scale: Double) -> [Annotation] {
        items
            .filter { $0.bounds(scale: scale).intersect(selection) != nil }
            .map { $0.relative(to: selection.origin) }
    }
}
