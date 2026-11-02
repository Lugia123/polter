import AppKit
import Foundation

/// The control room's preview sidebar: which key press means what (task 2645,
/// #2140 M3; the design's `INTERACTION.md` §一 怎么打开 and §三 键盘一览).
///
/// **What the sidebar *is* is not decided here.** Its state is
/// `PreviewSlot`'s -- one key, `controlRoomSidebarKey`, which the chat page
/// and the working-directories page both name, which is how the design's
/// 「右栏只有一个『当前文件』」 is one `Store` and not a mechanism. What it
/// draws is `PanePreviewPanel`'s. What is here is the one thing neither of
/// those can answer: **a key and its modifiers mean which of these**, given
/// what has the keyboard.
///
/// **Decisions, not a key handler.** The window's content view asks these
/// (`ControlRoomController.onKeyEquivalent`) and does what they say, exactly
/// as it asks `ControlRoomRules.tabIndex` for "go to tab N". They are
/// arithmetic on a key and a modifier mask because a rule written inside an
/// `NSEvent` callback cannot be run without a window: the chat page and the
/// window controller are both outside the package the logic tests build
/// (`tools/mac-logic-tests.json`), so a condition that lived in either could
/// only ever be checked on a running application -- and "the key did nothing"
/// and "the key was never wired" look the same from there.
///
/// # Why ⌘\ is not a binding in the configuration
///
/// Every other product key in this repository is a `Binding` in the core, so
/// that a person can change it and `ghostty_config_keybind` lists it. This one
/// is deliberately not: it is the control room window's own, taken in the one
/// place that window already takes keys (`onKeyEquivalent`), and the
/// supervisor's ruling of 2026-11-02 recorded that trade -- cheap, exact in
/// scope, and free of a new action's six landing places across Zig, the C
/// header and the Rust FFI (`src/input/Binding.zig`, `src/apprt/action.zig`,
/// `include/ghostty.h`, `windows/host/src/ffi.rs` and the two hosts' action
/// switches). ⚠️ **The price is real and is not to be described as support**:
/// the key cannot be rebound, and a `keybind = cmd+\=...` in a config file
/// does nothing to it.
enum ControlRoomSidebar {
    /// The sidebar's own name in the store. Reached through `PreviewSlot`
    /// rather than spelled here: a second literal equal to the first is a
    /// second place to be wrong in, and nothing notices when one of the two
    /// is edited.
    static let key = PreviewSlot.controlRoomSidebarKey

    /// Which side of the chat page the keyboard is standing on. The design
    /// treats the sidebar as one more pane of the cell
    /// (「预览就当它是这个格子里多出来的一格」), so walking between the two is
    /// the same act as walking between two splits -- which is why it takes
    /// the same chord, and why nothing new had to be invented for it.
    enum Side: Equatable {
        /// The chat itself: the group's `polter +chat` terminal.
        case chat
        /// The file preview beside it.
        case preview
    }

    /// What a key press asks for.
    enum Wanted: Equatable {
        /// Open the sidebar if it is closed and close it if it is open.
        case toggle
        /// Stand on this side of the chat page.
        case focus(Side)
        /// Not one of ours. **Said rather than left to a caller's `else`**:
        /// the press goes on to whatever would have had it, and a wildcard
        /// arm is where "we did not handle this" quietly becomes "we ate it".
        case no
    }

    /// The character ⌘\ types, and the key it is on.
    ///
    /// ⚠️ **Two readings, because either one alone is wrong** -- and this was
    /// a real defect rather than a precaution (task 2662, measured on the
    /// user's own machine, whose input source is
    /// `com.apple.keylayout.PinyinKeyboard`):
    ///
    ///  * **`characters` is the one that carries ⌘\.** AppKit asks the layout
    ///    what the key prints *ignoring* the modifiers for
    ///    `charactersIgnoringModifiers` and *applying* them for `characters`
    ///    -- and the Pinyin layout defines that key's unmodified glyph as `、`
    ///    (U+3001), so that field reads `、` while `characters` is still the
    ///    base-layout `\` (U+005C) that this chord is named after. The old
    ///    code compared the first field, matched nothing on that machine, and
    ///    the sidebar silently never opened.
    ///  * **`keyCode` is the physical key**: 42, the ANSI backslash key, the
    ///    same number whatever the keycaps say. It is the fallback for a
    ///    layout whose ⌘-modified `characters` is neither `\` nor anything
    ///    else this file could name -- the field above is a *convention*
    ///    about what a layout prints under ⌘, and a layout is not obliged to
    ///    follow it.
    ///
    /// **Either one matching is enough.** ⇧ is still refused by the *flag* and
    /// not by the character: Shift turns this key into `|` on the ASCII layout
    /// and into `｜` (U+FF5C) on this one, and both of those come with keyCode
    /// 42 -- so a rule that matched on the key alone would take ⇧⌘\, which is
    /// somebody else's. The `shift` guard in `wanted` is what refuses it, and
    /// that guard is load-bearing rather than belt-and-braces.
    static let backslash = "\\"
    /// The ANSI backslash key's physical position. Named because "42" in a
    /// comparison says nothing about what it is.
    static let backslashKey: UInt16 = 42

    /// What the two arrows are. They are function keys, not characters:
    /// AppKit reports the left and right arrows as U+F702 and U+F703 in
    /// `charactersIgnoringModifiers`, which is why they are named here rather
    /// than written as the arrows a person sees.
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"

    /// The modifiers that mean anything to these three keys. Everything else
    /// -- Caps Lock, Fn, the numeric keypad bit -- is not the person's asking
    /// for anything and must not turn a match into a miss.
    static let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    /// Whether what holds the keyboard now is something the person is typing
    /// into, so that the two arrows are the caret's and not this page's.
    ///
    /// **Two ways to be one, and the second is the one that was missed.** A
    /// field, a text view and anything that descends from them answer
    /// `NSText` (the group-name field's editor is an `NSTextView`; the field
    /// itself is checked too, the way `ControlRoomListView.isText` does it,
    /// because a field that is not being edited is still the keyboard's).
    /// **A web view is not one of those**: the preview plugin's editor is a
    /// `contenteditable` inside a `WKWebView`, and AppKit makes the
    /// *`WKWebView`* the first responder, not an `NSText` -- measured, not
    /// assumed (the test seat built a real window, loaded a `contenteditable`
    /// and focused it: `firstResponder = WKWebView`, `is NSText = false`).
    /// So a `WKWebView` holding it counts as typing, or the arrows would be
    /// taken out of the editor.
    ///
    /// ⚠️ **`inWebView` is handed in rather than worked out here**, and that
    /// is deliberate: deciding it means naming `WKWebView` and walking a
    /// responder chain, and this file is compiled into a package with no
    /// app (`tools/mac-logic-tests.json`). The controller -- which is
    /// outside that package and may import WebKit -- answers it; what is
    /// here is the rule that uses the answer, which is the half worth a
    /// test.
    ///
    /// ⚠️ **And it is asked of the two arrows only, never of ⌘\**
    /// (`wanted` says why): no text view on this system binds ⌘\ to
    /// anything, so taking it costs a text box nothing.
    static func textHasKeyboard(_ responder: NSResponder?, inWebView: Bool) -> Bool {
        responder is NSText || responder is NSTextField || inWebView
    }

    /// The keys ⌘\ and ⌘⌥←/→ mean, given what has the keyboard.
    ///
    /// # A text box keeps the arrows, and only the arrows
    ///
    /// ⚠️ **⌘← and ⌘→ are "beginning of line" and "end of line" to every text
    /// view on this system** (⌘⌥←/→ are "the word before" and "the word
    /// after"), so a window that took them would be a window where the caret
    /// could not be moved. The design states it for the editor (「在编辑时，Esc
    /// 先退出编辑」) and the supervisor's ruling of 2026-11-02 states it in both
    /// directions, for every text box the control room has: the group-name
    /// field, the preview plugin's editor, the chat's own input.
    ///
    /// **It is asked of the two arrows and never of ⌘\**, and the distinction
    /// is the whole difference between the two keys: no text view on this
    /// system binds ⌘\ to anything, so taking it costs a text box nothing --
    /// while taking ⌘← would cost it the caret. A rule that answered one for
    /// both would be a sidebar that could not be closed from the editor, or an
    /// editor whose caret could not reach the start of its line.
    ///
    /// **And it is a fact about what has the keyboard, not about what is drawn
    /// on screen**: the group's chat is a terminal and a terminal is not an
    /// `NSText`, so `textHasKeyboard` is false with the keyboard in it and ⌘\
    /// works there -- which is what the same ruling asks for
    /// (「焦点在终端内部输入时不受影响」 is about a text box, not a terminal).
    /// The caller hands this the two facts it has; this file never learns what
    /// a window is.
    ///
    /// # The keys
    ///
    ///  * **⌘\** -- `toggle`, anywhere in the control room: the chat page, the
    ///    working-directories page, the supervisor's page. Which page is in
    ///    front does not matter, because the right-hand side has one sidebar
    ///    and not one per page.
    ///  * **⌘⌥→ / ⌘⌥←** -- `focus`, **on the chat page only**, and only when
    ///    no text box has the keyboard. That is the page with something on
    ///    both sides to walk between; on the others the chord is left alone, so
    ///    that it keeps meaning what it means everywhere else in the
    ///    application (⌥⌘←/→ is `goto_split`, and on a page with no sidebar
    ///    there is nowhere here for it to go).
    ///
    /// Anything with Ctrl or Shift on it is `no`: ⌃⌘\ and ⇧⌘\ are somebody
    /// else's, and a person holding an extra modifier is not asking for the
    /// plain chord. **⇧⌘\ is refused by the flag and no longer by the
    /// character**: since the key's *position* is now one of the two things
    /// that match (`backslashKey` says why), the character is no longer what
    /// is standing between ⇧⌘\ and the toggle -- Shift turns this key into `|`
    /// on the ASCII layout and `｜` on this one, and both of those arrive on
    /// keyCode 42. The `shift` guard above is what refuses it, and it is
    /// load-bearing rather than the second of two readings.
    static func wanted(
        characters: String,
        keyCode: UInt16,
        modifiers: UInt,
        onChatPage: Bool,
        textHasKeyboard: Bool
    ) -> Wanted {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.shift)
        else { return .no }

        if !flags.contains(.option) {
            return characters == backslash || keyCode == backslashKey ? .toggle : .no
        }

        guard onChatPage, !textHasKeyboard else { return .no }
        switch characters {
        case rightArrow: return .focus(.preview)
        case leftArrow: return .focus(.chat)
        default: return .no
        }
    }

    /// Where the keyboard stands after the toggle has left the sidebar at
    /// `opened`: inside the preview when it just opened, and back out on the
    /// chat when it just closed.
    ///
    /// **Stated, because it is the half that silently goes wrong.** The
    /// design says 「关掉以后，键盘回到这个格子的终端里」 -- and a sidebar that
    /// closed with the keyboard still inside something no longer drawn is a
    /// window where typing goes nowhere, while every flag about the sidebar
    /// reads correctly. `ControlRoomChatContainer.takeKeyboard` exists for
    /// the same reason one page over, and this is that rule as a value: the
    /// caller pairs it with the one thing this file cannot do, which is move
    /// a window's first responder.
    static func side(opened: Bool) -> Side { opened ? .preview : .chat }
}
