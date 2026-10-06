import Foundation

// The geometry of the screenshot editor, in **whole physical pixels of one
// frozen display**: origin at that display's top left, y downwards.
//
// This file, `ShotStyle.swift`, `Annotation.swift`, `ShotPixels.swift`,
// `ShotStitcher.swift`, `ShotSidecar.swift` and `ShotEditor.swift` are a
// function-for-function port of the Windows host's `windows/shots` crate
// (`geom.rs`, `style.rs`, `annot.rs`, `pixels.rs`, `stitch.rs`, `editor.rs`).
// The two hosts are required to behave the same, item by item
// (`dev-docs/poltergeist/screenshot.md`, the second round), and the way that
// is kept true is that both compute in the same integers with the same
// rounding. **A change here that is not also made there is a divergence**,
// and nothing compares the two but the tests on each side stating the same
// numbers.

struct PixelPoint: Equatable, Hashable {
    var x: Int
    var y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    func relative(to origin: PixelPoint) -> PixelPoint {
        PixelPoint(x - origin.x, y - origin.y)
    }
}

struct PixelRect: Equatable, Hashable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    init(left: Int, top: Int, right: Int, bottom: Int) {
        self.init(left, top, right - left, bottom - top)
    }

    /// The rectangle between two corners, in whichever order.
    static func spanning(_ a: PixelPoint, _ b: PixelPoint) -> PixelRect {
        PixelRect(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y))
    }

    var right: Int { x + w }
    var bottom: Int { y + h }
    var origin: PixelPoint { PixelPoint(x, y) }
    var isEmpty: Bool { w <= 0 || h <= 0 }

    /// Left and top edges are inside, right and bottom are not.
    func contains(_ p: PixelPoint) -> Bool {
        p.x >= x && p.x < right && p.y >= y && p.y < bottom
    }

    func intersect(_ other: PixelRect) -> PixelRect? {
        let r = PixelRect(
            left: max(x, other.x), top: max(y, other.y),
            right: min(right, other.right), bottom: min(bottom, other.bottom))
        return r.isEmpty ? nil : r
    }

    /// The nearest point of the rectangle to `p`, its far edges included.
    func clamp(_ p: PixelPoint) -> PixelPoint {
        PixelPoint(min(max(p.x, x), right), min(max(p.y, y), bottom))
    }

    func relative(to origin: PixelPoint) -> PixelRect {
        PixelRect(x - origin.x, y - origin.y, w, h)
    }
}

/// The eight places a rectangle is resized from.
enum PixelHandle: Equatable, CaseIterable {
    case nw, n, ne, e, se, s, sw, w

    /// Corners first: where two are in reach of one press, the corner wins.
    static let all: [PixelHandle] = [.nw, .ne, .se, .sw, .n, .e, .s, .w]

    /// Which edges a handle moves.
    struct Edges: Equatable {
        var w = false, n = false, e = false, s = false
    }

    var edges: Edges {
        switch self {
        case .nw: return Edges(w: true, n: true)
        case .n: return Edges(n: true)
        case .ne: return Edges(n: true, e: true)
        case .e: return Edges(e: true)
        case .se: return Edges(e: true, s: true)
        case .s: return Edges(s: true)
        case .sw: return Edges(w: true, s: true)
        case .w: return Edges(w: true)
        }
    }

    func at(_ rect: PixelRect) -> PixelPoint {
        let edge = edges
        let x = edge.w ? rect.x : (edge.e ? rect.right : rect.x + rect.w / 2)
        let y = edge.n ? rect.y : (edge.s ? rect.bottom : rect.y + rect.h / 2)
        return PixelPoint(x, y)
    }
}

enum PixelGeometry {
    /// A press that travels further than this before release is a drag.
    static let dragThreshold = 4

    static func isDrag(from down: PixelPoint, to now: PixelPoint) -> Bool {
        max(abs(now.x - down.x), abs(now.y - down.y)) > dragThreshold
    }

    /// The region a drag from `down` to `now` selects, kept on the display
    /// it started on. Nil while it has no area.
    static func dragSelection(from down: PixelPoint, to now: PixelPoint, within display: PixelRect) -> PixelRect? {
        let r = PixelRect.spanning(display.clamp(down), display.clamp(now))
        return r.isEmpty ? nil : r
    }

    /// The topmost window under `p` -- `windows` is front to back -- and the
    /// part of it that is on the display.
    static func pickWindow(_ windows: [PixelRect], at p: PixelPoint, within display: PixelRect) -> (index: Int, visible: PixelRect)? {
        guard let i = windows.firstIndex(where: { $0.contains(p) }),
              let visible = windows[i].intersect(display) else { return nil }
        return (i, visible)
    }

    enum Hit: Equatable {
        case handle(PixelHandle)
        case inside
        case outside
    }

    /// What a press at `p` takes hold of on the selection `rect`.
    static func hit(_ rect: PixelRect, at p: PixelPoint, grip: Int) -> Hit {
        for handle in PixelHandle.all {
            let c = handle.at(rect)
            if abs(p.x - c.x) <= grip && abs(p.y - c.y) <= grip { return .handle(handle) }
        }
        return rect.contains(p) ? .inside : .outside
    }

    /// `rect` with the edges `handle` moves taken to `to`, inside `bounds`.
    /// Dragged past the opposite edge it turns over; it is never thinner
    /// than one pixel.
    static func resize(_ rect: PixelRect, dragging handle: PixelHandle, to point: PixelPoint, within bounds: PixelRect) -> PixelRect {
        let to = bounds.clamp(point)
        let edge = handle.edges
        var l = rect.x, t = rect.y, r = rect.right, b = rect.bottom
        if edge.w { l = to.x }
        if edge.e { r = to.x }
        if edge.n { t = to.y }
        if edge.s { b = to.y }
        let (left, right) = atLeastOne(min(l, r), max(l, r), bounds.x, bounds.right)
        let (top, bottom) = atLeastOne(min(t, b), max(t, b), bounds.y, bounds.bottom)
        return PixelRect(left: left, top: top, right: right, bottom: bottom)
    }

    private static func atLeastOne(_ lo: Int, _ hi: Int, _ min: Int, _ max: Int) -> (Int, Int) {
        if hi > lo { return (lo, hi) }
        if lo < max { return (lo, lo + 1) }
        // Tuples compare by their first member, as they do on the other host.
        let a = (max - 1, max), b = (min, min + 1)
        return a.0 > b.0 || (a.0 == b.0 && a.1 >= b.1) ? a : b
    }

    /// `rect` moved by `delta` without changing size, stopped at `bounds`.
    static func move(_ rect: PixelRect, by delta: PixelPoint, within bounds: PixelRect) -> PixelRect {
        let x = max(min(rect.x + delta.x, bounds.right - rect.w), bounds.x)
        let y = max(min(rect.y + delta.y, bounds.bottom - rect.h), bounds.y)
        return PixelRect(x, y, rect.w, rect.h)
    }

    /// Where a bar of `size` goes: under the selection, right edges aligned;
    /// above when there is no room under; inside its bottom edge when there
    /// is room for neither.
    static func toolbarOrigin(for selection: PixelRect, bar size: (w: Int, h: Int), within display: PixelRect, gap: Int) -> PixelPoint {
        let y: Int
        if selection.bottom + gap + size.h <= display.bottom {
            y = selection.bottom + gap
        } else if selection.y - gap - size.h >= display.y {
            y = selection.y - gap - size.h
        } else {
            y = selection.bottom - gap - size.h
        }
        let x = max(min(selection.right - size.w, display.right - size.w), display.x)
        return PixelPoint(x, y)
    }

    /// The three corners of an arrow's head: the tip, then the two barbs.
    /// Nil for an arrow of no length.
    static func arrowHead(from: PixelPoint, to: PixelPoint, size: Int) -> [PixelPoint]? {
        let dx = Double(to.x - from.x), dy = Double(to.y - from.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length != 0 else { return nil }
        let ux = dx / length, uy = dy / length
        let size = Double(size)
        let bx = Double(to.x) - ux * size, by = Double(to.y) - uy * size
        let px = -uy * size / 2, py = ux * size / 2
        func at(_ x: Double, _ y: Double) -> PixelPoint { PixelPoint(Int(x.rounded()), Int(y.rounded())) }
        return [to, at(bx + px, by + py), at(bx - px, by - py)]
    }
}
