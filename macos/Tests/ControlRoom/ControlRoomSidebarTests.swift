import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The control room's preview sidebar: which key press means what (task 2645,
/// #2140 M3).
///
/// **Why these are here and not in a view.** The chat page and the window
/// controller that would otherwise hold these conditions are both outside the
/// package this suite is built into (`tools/mac-logic-tests.json`: both import
/// `GhosttyKit`), so a rule written inside either could only be checked on a
/// running application -- where "the chord did nothing" and "the chord was
/// never wired" are the same reading. Everything below runs with no app, no
/// window and no terminal, against the same source text the app compiles.
///
/// `@MainActor` because the last group of tests makes AppKit views (never a
/// window): a stand-in for "something the person is typing into", which is
/// what `ControlRoomSidebar.textHasKeyboard` takes.
@MainActor
struct ControlRoomSidebarTests {
    typealias Sidebar = ControlRoomSidebar
    typealias Slot = PreviewSlot

    private let cmd: UInt = 1 << 20
    private let option: UInt = 1 << 19
    private let shift: UInt = 1 << 17
    private let control: UInt = 1 << 18

    /// A press of `key` with `modifiers`, on the chat page, with nothing
    /// typing: the shape every case below starts from and then spoils.
    private func wanted(
        _ key: String,
        _ modifiers: UInt,
        onChatPage: Bool = true,
        textHasKeyboard: Bool = false
    ) -> Sidebar.Wanted {
        Sidebar.wanted(characters: key, modifiers: modifiers, onChatPage: onChatPage,
                       textHasKeyboard: textHasKeyboard)
    }

    // MARK: ⌘\

    @Test func commandBackslashAsksForTheToggle() {
        #expect(wanted(Sidebar.backslash, cmd) == .toggle)
    }

    /// **The whole control room, not only the chat page**: the right-hand
    /// side has one sidebar and not one per page (the supervisor's ruling of
    /// 2026-11-02).
    @Test func theToggleIsAskedForOnEveryPage() {
        for page in [true, false] {
            #expect(wanted(Sidebar.backslash, cmd, onChatPage: page) == .toggle)
        }
    }

    /// **A text box keeps the arrows and not the backslash.** This is the
    /// distinction the isolation turns on: no text view on this system binds
    /// ⌘\ to anything, so taking it costs an editor nothing -- while taking
    /// ⌘← would cost it the caret.
    @Test func aTextBoxDoesNotStopTheToggle() {
        #expect(wanted(Sidebar.backslash, cmd, textHasKeyboard: true) == .toggle)
    }

    @Test func anotherModifierOnTheBackslashIsNotOurs() {
        #expect(wanted(Sidebar.backslash, cmd | shift) == .no)
        #expect(wanted(Sidebar.backslash, cmd | control) == .no)
        #expect(wanted(Sidebar.backslash, cmd | option) == .no)
    }

    /// Shift turns the backslash into a `|`, so the character alone would
    /// catch ⇧⌘\ -- and the flag alone would catch it too. Both are checked
    /// because either one of them could be the only one that works.
    @Test func shiftChangesTheCharacterAsWellAsTheFlag() {
        #expect(wanted("|", cmd | shift) == .no)
        #expect(wanted("|", cmd) == .no)
    }

    @Test func theBackslashWithNoCommandIsNotOurs() {
        #expect(wanted(Sidebar.backslash, 0) == .no)
        #expect(wanted(Sidebar.backslash, option) == .no)
    }

    // MARK: ⌘⌥← / ⌘⌥→

    @Test func theTwoArrowsWalkBetweenTheChatAndTheSidebar() {
        #expect(wanted(Sidebar.rightArrow, cmd | option) == .focus(.preview))
        #expect(wanted(Sidebar.leftArrow, cmd | option) == .focus(.chat))
    }

    /// **⌘⌥←/→ is `goto_split` everywhere in the application.** On a page with
    /// no chat there is nothing here to walk to, and answering anything but
    /// `.no` would swallow the chord there.
    @Test func anotherPageLeavesTheArrowsAlone() {
        #expect(wanted(Sidebar.rightArrow, cmd | option, onChatPage: false) == .no)
        #expect(wanted(Sidebar.leftArrow, cmd | option, onChatPage: false) == .no)
    }

    /// The isolation itself: with a text box holding the keyboard the arrows
    /// are the caret's and not the page's, in both directions.
    @Test func aTextBoxKeepsBothArrows() {
        #expect(wanted(Sidebar.rightArrow, cmd | option, textHasKeyboard: true) == .no)
        #expect(wanted(Sidebar.leftArrow, cmd | option, textHasKeyboard: true) == .no)
    }

    @Test func anArrowWithOneModifierIsSomebodyElses() {
        // ⌘←/→ is beginning and end of line to every text view.
        #expect(wanted(Sidebar.leftArrow, cmd) == .no)
        #expect(wanted(Sidebar.rightArrow, cmd) == .no)
        // ⌥←/→ is a word backwards and forwards.
        #expect(wanted(Sidebar.leftArrow, option) == .no)
        // And the end of the world.
        #expect(wanted(Sidebar.leftArrow, cmd | option | control) == .no)
        #expect(wanted(Sidebar.leftArrow, cmd | option | shift) == .no)
    }

    /// Modifiers this does not care about must not turn a match into a miss:
    /// the caller intersects with the four it knows, and this says so.
    @Test func theFourModifiersThatMatterAreTheOnlyOnesCompared() {
        let capsLock: UInt = 1 << 16
        let numericPad: UInt = 1 << 21
        #expect(wanted(Sidebar.backslash, cmd | capsLock | numericPad) == .toggle)
        #expect(wanted(Sidebar.rightArrow, cmd | option | capsLock | numericPad) == .focus(.preview))
    }

    @Test func aKeyThatIsNeitherIsLeftAlone() {
        for key in ["a", "\\n", " ", "\u{F700}", ""] {
            #expect(wanted(key, cmd) == .no)
            #expect(wanted(key, cmd | option) == .no)
        }
    }

    // MARK: What counts as typing

    /// The group-name field, the preview plugin's web editor, and the chat:
    /// `ControlRoomSidebar.textHasKeyboard`.
    ///
    /// **The third case is the one that was missed** and is why `inWebView`
    /// exists: a `contenteditable` inside a `WKWebView` leaves AppKit's first
    /// responder as the *web view's content view*, which is not an `NSText`
    /// -- measured by the test seat on a real window (`firstResponder =
    /// WKWebView`, `is NSText = false`), not assumed here.
    ///
    /// ⚠️ **What is tested is the rule, not the reading**: whether a given
    /// responder really is inside a web view is `ControlRoomController`'s
    /// (`isInWebView`, which walks the superview chain because the first
    /// responder is normally the content view rather than the web view),
    /// and that file is outside this package. So the wiring of the second
    /// input source still rests on the real machine; what is pinned here is
    /// that a `true` there does change the answer.
    @Test func aFieldATextViewAndAWebEditorAllCountAsTyping() {
        #expect(Sidebar.textHasKeyboard(NSTextView(), inWebView: false) == true)
        #expect(Sidebar.textHasKeyboard(NSTextField(), inWebView: false) == true)
        #expect(Sidebar.textHasKeyboard(NSView(), inWebView: true) == true)
        // And nil is "nothing is typing", which is what a window with no
        // first responder at all answers.
        #expect(Sidebar.textHasKeyboard(nil, inWebView: false) == false)
    }

    /// A terminal is not a text box: the chat holds the keyboard through its
    /// own `SurfaceView`, which is none of these, so ⌘\ and the arrows work
    /// with the keyboard in the chat -- which is what the ruling asks for.
    @Test func aTerminalIsNotATextBox() {
        #expect(Sidebar.textHasKeyboard(NSView(), inWebView: false) == false)
        #expect(wanted(Sidebar.backslash, cmd, textHasKeyboard: false) == .toggle)
        #expect(wanted(Sidebar.rightArrow, cmd | option, textHasKeyboard: false) == .focus(.preview))
    }

    /// And the answer is what the arrows obey: told "typing", both chords on
    /// the arrows are left alone.
    @Test func whatCountsAsTypingIsWhatTheArrowsObey() {
        let typing = Sidebar.textHasKeyboard(NSTextView(), inWebView: false)
        #expect(wanted(Sidebar.rightArrow, cmd | option, textHasKeyboard: typing) == .no)
        let inWeb = Sidebar.textHasKeyboard(NSView(), inWebView: true)
        #expect(wanted(Sidebar.rightArrow, cmd | option, textHasKeyboard: inWeb) == .no)
        // ⌘\ is not one of these and goes through anyway.
        #expect(wanted(Sidebar.backslash, cmd, textHasKeyboard: typing) == .toggle)
        #expect(wanted(Sidebar.backslash, cmd, textHasKeyboard: inWeb) == .toggle)
    }

    // MARK: The modifiers that matter

    /// **One set of modifiers for the whole file**, and the caller uses this
    /// one rather than writing the four again
    /// (`ControlRoomController.sidebarTakesKey`). Two spellings of one set is
    /// the same defect the single `controlRoomSidebarKey` prevents, one
    /// field over -- and this one was found by reading, not by a test.
    @Test func theModifierSetIsOneThing() {
        #expect(Sidebar.relevant == [.command, .option, .shift, .control])
        // The ones that must NOT be in it: these arrive on ordinary presses
        // and intersecting them away is what keeps a match a match.
        #expect(!Sidebar.relevant.contains(.capsLock))
        #expect(!Sidebar.relevant.contains(.numericPad))
        #expect(!Sidebar.relevant.contains(.function))
    }

    /// And they come off a real event's mask the way the caller takes them
    /// off: what is left is the four, whatever else the keyboard had on it.
    @Test func theFourAreWhatSurvivesTheIntersection() {
        let capsLock: UInt = 1 << 16
        let numericPad: UInt = 1 << 21
        let all = cmd | option | shift | control | capsLock | numericPad
        let taken = NSEvent.ModifierFlags(rawValue: all).intersection(Sidebar.relevant).rawValue
        #expect(taken == (cmd | option | shift | control))
    }

    // MARK: Where the keyboard goes

    /// Opening puts it in the sidebar; closing brings it back to the chat.
    /// The design says 「关掉以后，键盘回到这个格子的终端里」, and a sidebar
    /// that closed leaving the keyboard inside a view nobody draws is a
    /// window where typing goes nowhere.
    @Test func openingGoesInAndClosingComesBackOut() {
        #expect(Sidebar.side(opened: true) == .preview)
        #expect(Sidebar.side(opened: false) == .chat)
    }

    // MARK: The cell both pages name

    /// **One key for the whole right-hand side**, which is how 「右栏只有一
    /// 个『当前文件』」 is the store that was already there. The chat page and
    /// the working-directories page both name this constant.
    @Test func theSidebarIsOneCellAndTheToggleReachesIt() {
        var store = Slot.Store()
        #expect(store.state(Sidebar.key).open == false)
        let opened = store.toggleSidebar()
        #expect(opened == true)
        #expect(store.state(Sidebar.key).open == true)
        #expect(store.state(Slot.controlRoomSidebarKey).open == true)
    }

    /// ⚠️ **And it is not a surface's id.** A terminal pane names itself by
    /// its surface's UUID, so the sidebar's name must have a shape no UUID
    /// has -- otherwise a pane could take the sidebar's state, or the other
    /// way round, and the design's 终端格里的预览是那一个格子自己的 would
    /// quietly stop being true.
    @Test func theSidebarsNameIsNotShapedLikeAUUID() {
        let uuid = UUID().uuidString
        #expect(Sidebar.key != uuid)
        #expect(UUID(uuidString: Sidebar.key) == nil)
        #expect(Sidebar.key == Slot.controlRoomSidebarKey)
    }

    @Test func theToggleFlipsAndNeverOnlyOpens() {
        var store = Slot.Store()
        let first = store.toggleSidebar()
        let second = store.toggleSidebar()
        #expect(first == true)
        #expect(second == false)
        #expect(store.state(Sidebar.key).open == false)
    }

    /// Closing keeps the file, as it does for a pane's own preview: the
    /// design's 「再按一次「文件」按钮，或者 ⌘\」 reopens what was closed. A
    /// toggle that cleared the cell would reopen on an empty panel.
    @Test func theToggleLeavesTheFileWhereItWas() {
        var store = Slot.Store()
        store.setFile(Sidebar.key, rel: "src/a.zig", token: String(repeating: "a", count: 32))
        _ = store.toggleSidebar()
        _ = store.toggleSidebar()
        #expect(store.state(Sidebar.key).rel == "src/a.zig")
        #expect(store.state(Sidebar.key).token == String(repeating: "a", count: 32))
    }

    /// A pane's cell is its own: the sidebar's flag must not reach one, and a
    /// pane's must not reach the sidebar's.
    @Test func aPanesCellIsNotTheSidebars() {
        var store = Slot.Store()
        // One pane, named once: a second `UUID()` here would be a second
        // pane, and the reading below would be of a cell nobody wrote.
        let pane = UUID().uuidString
        store.set(pane, open: true)
        #expect(store.state(Sidebar.key).open == false)
        _ = store.toggleSidebar()
        #expect(store.state(Sidebar.key).open == true)
        #expect(store.state(pane).open == true)
    }
}
