import CoreGraphics
import Foundation

/// The rules of `terminal_highlight` on macOS (task 1689) that need no
/// window: how the edge breathes, when the card fits, what a key does,
/// which word `front` is, and what the core is told. The design is
/// `highlight-v1/README.md`; the core's half of the interface is
/// `apprt.action.PolterHighlight`.
///
/// No AppKit and no GhosttyKit, so it can be tested without a host.
enum PolterHighlightRules {
    typealias Look = ControlRoomLook.Highlight

    // MARK: Breathing

    /// How strong the breathing edge, the card's ring and the tab are, `t`
    /// seconds after the highlight started: faintest at the start, strongest
    /// half a breath in. **The one curve both hosts draw**
    /// (`highlight-interface.md`, section 5). With reduce motion on it
    /// rests at the top and does not move.
    static func breath(at t: Double, reduceMotion: Bool) -> Double {
        let low = Look.breathLow
        let high = Look.breathHigh
        if reduceMotion { return high }
        let phase = (1 - cos(2 * Double.pi * t / Look.breathPeriod)) / 2
        return low + (high - low) * phase
    }

    /// One breath, sampled evenly, for a layer animation that repeats it:
    /// the first and the last value are the same, so the repeat has no seam.
    static func breathKeyframes(count: Int = 25) -> [Double] {
        guard count > 1 else { return [breath(at: 0, reduceMotion: false)] }
        return (0..<count).map { i in
            breath(at: Look.breathPeriod * Double(i) / Double(count - 1), reduceMotion: false)
        }
    }

    // MARK: What is drawn

    /// What the lit pane gets.
    enum Style: Equatable {
        /// Design B: the edge and the card in the middle.
        case card
        /// Design A, for a pane too small for the card: a wider edge with a
        /// glow, and a small badge at the title's end. It still breathes.
        case ring
    }

    static func style(paneSize: CGSize) -> Style {
        paneSize.width < Look.cardMinPaneWidth || paneSize.height < Look.cardMinPaneHeight ? .ring : .card
    }

    /// The card's width in a pane `paneWidth` wide: its own minimum, never
    /// more than its share of the pane.
    static func cardWidth(paneWidth: CGFloat, wanted: CGFloat) -> CGFloat {
        let most = paneWidth * Look.cardMaxWidthFraction
        return min(most, max(Look.cardMinWidth, wanted))
    }

    /// Seconds left, as the card says them: whole seconds, rounded up, so
    /// "0" is never shown while it is still lit.
    static func secondsLeft(total: Double, elapsed: Double) -> Int {
        max(0, Int((total - elapsed).rounded(.up)))
    }

    /// How much of the countdown bar is still full, 1 to 0.
    static func barFraction(total: Double, elapsed: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - elapsed / total))
    }

    // MARK: Ending

    /// Why a highlight ended, as the log line says it. Only `key` is about
    /// what the person pressed, and it never says which key.
    enum Reason: String, CaseIterable {
        case timeout, key, click, replaced, cancelled, closed
    }

    /// What a key pressed in the lit window does.
    enum KeyOutcome: Equatable {
        /// Ends the highlight and goes nowhere -- not into the worker the
        /// person did not mean to type to.
        case swallow
        /// Ends nothing and is handled as it would have been: a command or
        /// control combination is the system's and the menus' -- switching
        /// tabs with one leaves the lit tab breathing, which is the point
        /// of it (the supervisor's ruling on 2026-10-18, against the
        /// design's "any key ends it").
        case pass
    }

    /// `command` and `control` are whether either was held. A key with
    /// neither is swallowed, Esc and Return included. A modifier on its
    /// own is not a key press here: AppKit sends it as `flagsChanged`,
    /// which ends nothing.
    static func key(command: Bool, control: Bool) -> KeyOutcome {
        command || control ? .pass : .swallow
    }

    /// Whether a click in the lit window ends it: only one on the panes.
    /// A click on the tab bar or the title bar -- choosing another tab --
    /// leaves it lit, so its tab can be found again (the same ruling).
    /// `paneArea` is the window's content layout rect, which leaves both
    /// bars out.
    static func clickEnds(at point: CGPoint, paneArea: CGRect) -> Bool {
        paneArea.contains(point)
    }

    // MARK: Answering the core

    /// What the host read back after bringing the window forward.
    enum Front: String {
        case yes, minimizedRestored = "minimized_restored", refused, otherSpace = "other_space", pending, unknown
    }

    /// The word for `front`, from the readings. `waitingForWindow` is a
    /// minimised window whose coming back has not happened yet: that is
    /// read later, so the answer now is `pending` -- never `refused`.
    static func front(
        appActive: Bool,
        windowIsKey: Bool,
        onActiveSpace: Bool,
        wasMinimized: Bool,
        waitingForWindow: Bool
    ) -> Front {
        if waitingForWindow { return .pending }
        if !appActive { return .refused }
        if !onActiveSpace { return .otherSpace }
        if !windowIsKey { return .refused }
        return wasMinimized ? .minimizedRestored : .yes
    }

    /// What was changed to put it in front of the person.
    struct Switched: Equatable {
        var window = false
        var tab = false
        var stack = false
    }

    /// The `applied` answer for a highlight that was started:
    /// `{"switched":{..},"front":..,"timer":..,"replaced":h}`. `replaced` is a
    /// surface handle, 0 for none -- the core turns it into an id.
    static func shownJSON(switched: Switched, front: Front, timerRunning: Bool, replaced: UInt64) -> String {
        let s = switched
        return "{\"switched\":{\"window\":\(s.window),\"tab\":\(s.tab),\"stack\":\(s.stack)}," +
            "\"front\":\"\(front.rawValue)\",\"timer\":\"\(timerRunning ? "running" : "waiting")\"," +
            "\"replaced\":\(replaced)}"
    }

    /// The `applied` answer to `seconds = 0`.
    static func endedJSON(_ ended: Bool) -> String {
        "{\"ended\":\(ended)}"
    }

    /// A refusal the core reads as its own code (`App.polterRefusal`).
    static func refusalJSON(code: String, message: String) -> String {
        let object: [String: String] = ["code": code, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"code\":\"\(code)\"}" }
        return text
    }
}
