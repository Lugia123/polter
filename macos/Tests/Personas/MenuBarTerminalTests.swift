import Testing
@testable import Ghostty

/// Covers `PersonaMenuBar.terminalWindow` -- which terminal the menu bar's
/// `Role ▸` and direct-mentions rows are about -- without an app or a window
/// server. The windows are stand-ins; everything the choice asks of a real
/// window is one of the two closures.
///
/// What happens *after* the choice is `nil` is `PersonaMenuTests`'s: every
/// row greyed and a line saying there is no terminal here (task 588). This
/// file is about getting to `nil` only when that is true (task 589).
@MainActor
@Suite
struct MenuBarTerminalTests {
    private let library = FakeWindow("role library", terminal: false)
    private let chat = FakeWindow("conversations", terminal: false)
    private let termA = FakeWindow("terminal A", terminal: true)
    private let termB = FakeWindow("terminal B", terminal: true)

    private func pick(ordered: [FakeWindow], key: FakeWindow?, main: FakeWindow?) -> FakeWindow? {
        PersonaMenuBar.terminalWindow(
            ordered: ordered, key: key, main: main,
            isTerminal: { $0.terminal }, isShowing: { $0.showing })
    }

    // MARK: Unchanged

    /// The positive control. A focused terminal is the answer, even with
    /// another terminal in front of it in the window list -- otherwise the
    /// fix would have traded "nobody" for "somebody else".
    @Test func aFocusedTerminalIsStillTheAnswer() {
        #expect(pick(ordered: [termB, termA], key: termA, main: termA) === termA)
    }

    // MARK: Task 589

    /// The defect. An ordinary titled window of this app that is not a
    /// terminal is key and, being ordinary, main as well -- so
    /// `keyWindow ?? mainWindow` was that window twice and the rows pointed
    /// at nobody, while the terminal sat right behind it.
    @Test func withTheRoleLibraryInFrontTheTerminalBehindItIsTheAnswer() {
        #expect(pick(ordered: [library, termA], key: library, main: library) === termA)
    }

    /// A panel can be key without being main; then main is the terminal.
    @Test func aKeyPanelLeavesTheMainTerminal() {
        #expect(pick(ordered: [library, termB, termA], key: library, main: termA) === termA)
    }

    /// Behind several things, the frontmost terminal -- the one nearest to
    /// what the user is looking at -- not whichever is first in some other
    /// order.
    @Test func behindSeveralWindowsTheFrontmostTerminalWins() {
        #expect(pick(ordered: [library, chat, termB, termA], key: library, main: library) === termB)
    }

    // MARK: Still nobody

    /// A minimised terminal, or one on another Space, is not one the user is
    /// looking at. Acting on it would be worse than a grey row.
    @Test func aTerminalThatIsNotShowingIsNotTheAnswer() {
        let hidden = FakeWindow("minimised", terminal: true, showing: false)
        #expect(pick(ordered: [library, hidden], key: library, main: library) == nil)
    }

    @Test func withNoTerminalAtAllThereIsNone() {
        #expect(pick(ordered: [library, chat], key: library, main: library) == nil)
        #expect(pick(ordered: [], key: nil, main: nil) == nil)
    }
}

/// A window, as far as `terminalWindow` can tell.
final class FakeWindow: CustomStringConvertible {
    let description: String
    let terminal: Bool
    let showing: Bool

    init(_ name: String, terminal: Bool, showing: Bool = true) {
        description = name
        self.terminal = terminal
        self.showing = showing
    }
}
