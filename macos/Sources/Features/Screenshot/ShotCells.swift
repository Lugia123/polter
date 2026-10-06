import Foundation

/// What one cell of the toolbar looks like, and how it gets from one look
/// to the next (`dev-docs/poltergeist/screenshot.md`, 9.8.4 and 9.8.4.0).
///
/// A cell is anything on the toolbar that can be pressed: a tool, an
/// action, a colour, a step of a size. There is one way to be selected --
/// a thin ring in the accent colour with a glow -- and it is the same for
/// all of them.
enum ShotCell {
    /// What is known about a cell at a moment.
    struct State: Equatable {
        /// The pointer is over it.
        var hovered = false
        /// The mouse button went down on it and is still down.
        var pressed = false
        /// It is the current tool, colour or step, or the long screenshot
        /// under way.
        var selected = false
        /// It can be pressed: not undo with nothing to undo, not a tool
        /// while a long screenshot is being taken.
        var enabled = true
        /// It is "done", whose pressed look is a solid fill.
        var isDone = false
    }

    /// How much of each part of a cell's look is showing, 0 to 1.
    struct Look: Equatable {
        /// The plain light fill of a cell the pointer is over.
        var hover: Double = 0
        /// The hairline that goes with it. Not shown with a ring: the ring
        /// is already where it would be.
        var hairline: Double = 0
        /// The accent-tinted fill of a cell being pressed.
        var down: Double = 0
        /// The ring and its glow: pressed or selected.
        var ring: Double = 0
        /// How far the ink is from white to the accent.
        var accent: Double = 0
        /// The solid accent fill of "done" being pressed, with white ink.
        var solid: Double = 0
        /// The cell cannot be pressed: its ink is faint, and nothing else
        /// about it ever changes.
        var off = false
    }

    /// The look a cell is heading for.
    static func look(for s: State) -> Look {
        guard s.enabled else { return Look(off: true) }
        var look = Look()
        if s.pressed {
            look.ring = 1
            if s.isDone {
                look.solid = 1
            } else {
                look.down = 1
                look.accent = 1
            }
        } else if s.selected {
            look.ring = 1
            look.accent = 1
        }
        if s.hovered && !s.pressed {
            look.hover = 1
            look.hairline = look.ring > 0 ? 0 : 1
        }
        return look
    }

    /// One cell's look on its way somewhere.
    ///
    /// Each part moves in a straight line over its own time: the hover fill
    /// comes in faster than it goes out, a press shows on the frame it
    /// happens, and what a press leaves behind fades.
    struct Fade: Equatable {
        private struct Ramp: Equatable {
            var from: Double
            var to: Double
            var start: TimeInterval
            var duration: TimeInterval

            func value(at now: TimeInterval) -> Double {
                guard duration > 0 else { return to }
                let t = min(max((now - start) / duration, 0), 1)
                return from + (to - from) * t
            }

            mutating func head(for target: Double, at now: TimeInterval, over duration: TimeInterval) {
                guard target != to else { return }
                self = Ramp(from: value(at: now), to: target, start: now, duration: duration)
            }
        }

        private var hover = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var hairline = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var down = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var ring = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var accent = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var solid = Ramp(from: 0, to: 0, start: 0, duration: 0)
        private var off = false
        /// Whether the system is asked to reduce motion: then every change
        /// is at once.
        var still: Bool

        init(still: Bool = false) {
            self.still = still
        }

        /// A cell that already has `look`, with nothing on its way.
        init(showing look: Look, still: Bool = false) {
            self.still = still
            hover = Ramp(from: look.hover, to: look.hover, start: 0, duration: 0)
            hairline = Ramp(from: look.hairline, to: look.hairline, start: 0, duration: 0)
            down = Ramp(from: look.down, to: look.down, start: 0, duration: 0)
            ring = Ramp(from: look.ring, to: look.ring, start: 0, duration: 0)
            accent = Ramp(from: look.accent, to: look.accent, start: 0, duration: 0)
            solid = Ramp(from: look.solid, to: look.solid, start: 0, duration: 0)
            off = look.off
        }

        private func seconds(_ ms: Double) -> TimeInterval { still ? 0 : ms / 1000 }

        /// The cell is now to look like `look`.
        mutating func head(for look: Look, at now: TimeInterval) {
            let t = ShotLook.TransitionMs.self
            // Becoming unavailable, or available again, is at once.
            if look.off != off {
                self = Fade(showing: look, still: still)
                return
            }
            hover.head(for: look.hover, at: now, over: seconds(look.hover > 0 ? t.hoverIn : t.hoverOut))
            hairline.head(for: look.hairline, at: now, over: seconds(look.hairline > 0 ? t.hoverIn : t.hoverOut))
            // Pressing is at once; letting go fades.
            down.head(for: look.down, at: now, over: seconds(look.down > 0 ? t.press : t.release))
            solid.head(for: look.solid, at: now, over: seconds(look.solid > 0 ? t.press : t.release))
            // The ring arrives with the press. It leaves over the release
            // when it was only a press, and a little faster when another
            // cell took the selection.
            let leaving = down.to == 0 && solid.to == 0 && (down.value(at: now) > 0 || solid.value(at: now) > 0)
                ? t.release : t.deselect
            ring.head(for: look.ring, at: now, over: seconds(look.ring > 0 ? t.press : leaving))
            accent.head(for: look.accent, at: now, over: seconds(look.accent > 0 ? t.press : leaving))
        }

        func look(at now: TimeInterval) -> Look {
            Look(
                hover: hover.value(at: now), hairline: hairline.value(at: now), down: down.value(at: now),
                ring: ring.value(at: now), accent: accent.value(at: now), solid: solid.value(at: now), off: off)
        }

        /// Whether any part is still on its way at `now`.
        func isMoving(at now: TimeInterval) -> Bool {
            [hover, hairline, down, ring, accent, solid].contains { $0.value(at: now) != $0.to }
        }
    }
}
