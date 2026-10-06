import CoreGraphics
import Foundation

/// The four modifier keys, with the bit values of `ghostty_input_mods_e`
/// (and so of what `screenshot-mouse-trigger` reads as).
struct ShotMods: OptionSet, Equatable, Hashable {
    let rawValue: UInt32

    static let shift = ShotMods(rawValue: 1)
    static let control = ShotMods(rawValue: 2)
    static let option = ShotMods(rawValue: 4)
    static let command = ShotMods(rawValue: 8)

    /// Everything else in a raw value -- caps lock, num lock, which side --
    /// is not one of these four and is dropped.
    static let all: ShotMods = [.shift, .control, .option, .command]
}

/// Modifiers held plus a double-click of the left button, anywhere on screen
/// (`dev-docs/poltergeist/screenshot.md`, 3.1).
///
/// A value that is fed every left-button press and answers whether that
/// press completed the gesture. It keeps the previous press and nothing
/// else; the clock, the position and the modifiers all come in from outside.
struct DoubleClickDetector: Equatable {
    /// The modifiers that have to be held. Empty is off: with nothing
    /// required, every double-click on the machine would match.
    var required: ShotMods
    /// The longest gap between the two presses, the system's own
    /// double-click interval.
    var interval: TimeInterval
    /// How far apart the two presses may be, along either axis.
    var distance: CGFloat

    private var previous: Press?

    private struct Press: Equatable {
        var time: TimeInterval
        var point: CGPoint
    }

    init(required: ShotMods, interval: TimeInterval, distance: CGFloat) {
        self.required = required.intersection(.all)
        self.interval = interval
        self.distance = distance
    }

    /// What a press turned out to be.
    enum Verdict: Equatable {
        /// The second of two presses: the gesture.
        case fired
        /// A press that could be the first of two.
        case first
        /// Not made with exactly the required modifiers; forgotten, and the
        /// press before it with it.
        case wrongModifiers
        /// A press this has already been fed, reported again. Nothing
        /// changes.
        case replay
    }

    /// When the latest press this was fed happened, whatever became of it.
    private var latest: TimeInterval?

    /// Feed a left-button press. `.fired` when it is the second of two
    /// presses that were both made with **exactly** the required modifiers,
    /// no later than `interval` apart and no further than `distance`.
    ///
    /// Exactly: one modifier more and it is some other program's gesture.
    /// A press with the wrong modifiers also forgets the one before it, so
    /// right-wrong-right is not a double-click.
    ///
    /// **A press that is not later than the last one fed is the same press
    /// arriving again, and is not counted.** One click can be reported more
    /// than once -- by the monitor for other applications' events and the
    /// one for our own, or delivered a second time while this application
    /// is being brought to the front by that very click -- and two reports
    /// of one press are no further apart than a double-click allows. Without
    /// this a single click fired the gesture, and a double click fired it
    /// twice. Two presses a person made are never at the same instant.
    mutating func press(at point: CGPoint, time: TimeInterval, mods: ShotMods) -> Verdict {
        if let latest, time <= latest { return .replay }
        latest = time

        guard !required.isEmpty, mods.intersection(.all) == required else {
            previous = nil
            return .wrongModifiers
        }

        if let previous {
            let elapsed = time - previous.time
            let moved = max(abs(point.x - previous.point.x), abs(point.y - previous.point.y))
            if elapsed <= interval, moved <= distance {
                // Spent: a third press starts over rather than firing again.
                self.previous = nil
                return .fired
            }
        }

        previous = Press(time: time, point: point)
        return .first
    }

    /// `press`, as whether it completed the gesture.
    mutating func leftDown(at point: CGPoint, time: TimeInterval, mods: ShotMods) -> Bool {
        press(at: point, time: time, mods: mods) == .fired
    }
}

/// A keybind trigger as the system hotkey registration wants it: a virtual
/// key code and Carbon's modifier bits.
///
/// The screenshot hotkey is registered with `RegisterEventHotKey` rather
/// than caught by the event tap the other `global:` keybinds use, because
/// that tap costs the Accessibility permission and this must not.
enum ShotHotKey {
    struct Spec: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    // Carbon's `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    static let carbonCommand: UInt32 = 0x0100
    static let carbonShift: UInt32 = 0x0200
    static let carbonOption: UInt32 = 0x0800
    static let carbonControl: UInt32 = 0x1000

    static func carbonModifiers(_ mods: ShotMods) -> UInt32 {
        var out: UInt32 = 0
        if mods.contains(.command) { out |= carbonCommand }
        if mods.contains(.shift) { out |= carbonShift }
        if mods.contains(.option) { out |= carbonOption }
        if mods.contains(.control) { out |= carbonControl }
        return out
    }

    /// The virtual key that types `codepoint` unshifted on the ANSI layout.
    ///
    /// A hotkey is registered by key position, so this is where a character
    /// sits on a US keyboard; on a layout that puts it elsewhere the hotkey
    /// is on the US position. Nil for anything not in the table -- no
    /// hotkey is better than one on a guessed key.
    static func keyCode(forUnicode codepoint: UInt32) -> UInt32? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        let lowered = String(Character(scalar)).lowercased()
        return ansi[lowered]
    }

    private static let ansi: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// The registration for `keyCode` with `mods`, or nil when there is no
    /// modifier: a bare key registered system-wide takes that key away from
    /// every other program.
    static func spec(keyCode: UInt32?, mods: ShotMods) -> Spec? {
        let mods = mods.intersection(.all)
        guard let keyCode, !mods.isEmpty else { return nil }
        return Spec(keyCode: keyCode, modifiers: carbonModifiers(mods))
    }
}
