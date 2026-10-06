import Foundation

/// Which part of a display's frozen picture is shown sharp, and how it gets
/// from one answer to the next (`dev-docs/poltergeist/screenshot.md`,
/// 9.8.7).
///
/// Everything outside the sharp part is the picture out of focus
/// (`ShotBlur`). There is never more than one sharp rectangle a display is
/// heading for; while it changes from one window to another there are two
/// for a moment, one fading in and one fading out.
enum ShotVeil {
    /// What a display's sharp part is.
    enum Focus: Equatable {
        /// Nothing: the whole display is out of focus. A display the
        /// pointer is not on and the selection is not on.
        case nothing
        /// A rectangle the person chose or is choosing: the selection, or
        /// the one being dragged out. It is sharp at once and follows the
        /// drag frame by frame.
        case region(PixelRect)
        /// The window the pointer is over, before there is a selection, or
        /// the whole display when it is over no window. It fades in.
        case window(PixelRect)

        var rect: PixelRect? {
            switch self {
            case .nothing: return nil
            case let .region(r), let .window(r): return r
            }
        }
    }

    /// What display `index` shows sharp.
    ///
    /// The selection or the region being dragged, on the display it is on;
    /// otherwise the window under the pointer; otherwise, on the display
    /// the pointer is on, everything -- there is no window to choose, and a
    /// screen that is all out of focus is one nobody can choose a region
    /// on.
    static func focus(
        display index: Int, whole: PixelRect,
        selection: (display: Int, rect: PixelRect)?,
        forming: (display: Int, rect: PixelRect)?,
        hover: (display: Int, rect: PixelRect)?,
        pointerDisplay: Int?
    ) -> Focus {
        if let selection { return selection.display == index ? .region(selection.rect) : .nothing }
        if let forming { return forming.display == index ? .region(forming.rect) : .nothing }
        if let hover { return hover.display == index ? .window(hover.rect) : .nothing }
        return pointerDisplay == index ? .window(whole) : .nothing
    }

    /// A rectangle of sharp picture and how much of it shows: 1 is the
    /// picture as it is, 0 is none of it.
    struct Layer: Equatable {
        var rect: PixelRect
        var alpha: Double
    }

    /// One display's sharp part over time.
    struct Fade: Equatable {
        private struct Part: Equatable {
            var rect: PixelRect
            /// A region the person is holding, which neither fades in nor
            /// fades out.
            var isRegion: Bool
            /// What it showed when it was last told where to go, and when
            /// that was.
            var from: Double
            var to: Double
            var start: TimeInterval
        }

        private(set) var focus: Focus = .nothing
        private var parts: [Part] = []
        /// How long a window takes to come into focus or go out of it, in
        /// seconds. Zero when the system is asked to reduce motion.
        var duration: TimeInterval

        init(duration: TimeInterval) {
            self.duration = max(duration, 0)
        }

        private func alpha(of part: Part, at now: TimeInterval) -> Double {
            guard duration > 0 else { return part.to }
            let t = min(max((now - part.start) / duration, 0), 1)
            return part.from + (part.to - part.from) * t
        }

        /// The display's sharp part is now `next`.
        ///
        /// A region is sharp at once and gone at once: it is under the
        /// person's hand, and one that faded would leave a trail behind
        /// every frame of a drag. A window fades in, and a window that is no
        /// longer the one fades out -- from however sharp it was at that
        /// moment, so a change made halfway through another carries on from
        /// there.
        mutating func set(_ next: Focus, at now: TimeInterval) {
            guard next != focus else { return }
            var kept: [Part] = []
            var arriving: Double = 0
            let before = parts
            for part in before where !part.isRegion {
                let shown = alpha(of: part, at: now)
                if case let .window(rect) = next, rect == part.rect {
                    // Already on screen: carry on to full from here.
                    arriving = shown
                } else if shown > 0 {
                    kept.append(Part(rect: part.rect, isRegion: false, from: shown, to: 0, start: now))
                }
            }
            switch next {
            case .nothing:
                break
            case let .region(rect):
                kept.append(Part(rect: rect, isRegion: true, from: 1, to: 1, start: now))
            case let .window(rect):
                kept.append(Part(rect: rect, isRegion: false, from: arriving, to: 1, start: now))
            }
            parts = kept
            focus = next
        }

        /// What to draw sharp at `now`, least recent first. The rectangle
        /// in focus is last, so it is on top of anything leaving.
        func layers(at now: TimeInterval) -> [Layer] {
            var leaving: [Layer] = []
            var staying: [Layer] = []
            for part in parts {
                let a = alpha(of: part, at: now)
                guard a > 0 else { continue }
                if part.to == 1 {
                    staying.append(Layer(rect: part.rect, alpha: a))
                } else {
                    leaving.append(Layer(rect: part.rect, alpha: a))
                }
            }
            return leaving + staying
        }

        /// Whether anything is still on its way at `now`: there are more
        /// frames to draw without anybody moving the mouse.
        func isMoving(at now: TimeInterval) -> Bool {
            parts.contains { alpha(of: $0, at: now) != $0.to }
        }

        /// Drop what has finished leaving.
        mutating func settle(at now: TimeInterval) {
            let before = parts
            parts = before.filter { !($0.to == 0 && alpha(of: $0, at: now) <= 0) }
        }

        /// Every rectangle that is, or is on its way to being, anything
        /// but out of focus: what has to be painted again while this moves.
        var touched: [PixelRect] { parts.map(\.rect) }
    }

    /// The smallest rectangle holding all of `rects`, grown by `ring` and
    /// cut to `whole`; nil when there are none or nothing of them is on the
    /// display.
    static func dirty(_ rects: [PixelRect], ring: Int, within whole: PixelRect) -> PixelRect? {
        var box: PixelRect?
        for r in rects where r.w > 0 && r.h > 0 {
            box = box.map {
                PixelRect(
                    left: min($0.x, r.x), top: min($0.y, r.y),
                    right: max($0.right, r.right), bottom: max($0.bottom, r.bottom))
            } ?? r
        }
        guard let box else { return nil }
        return PixelRect(
            left: box.x - ring, top: box.y - ring, right: box.right + ring, bottom: box.bottom + ring
        ).intersect(whole)
    }
}
