import AppKit
import SwiftUI

/// How small the control room's window can be made: a size of the window's
/// own, which nothing drawn in it changes.
///
/// **It used to be whatever the content said.** A hosting view tells its
/// window the least size its content can be drawn at, and works that out at
/// the least width -- where the right-hand side has almost none. A sentence
/// there that may not be squeezed upright
/// (`fixedSize(horizontal: false, vertical: true)`) is then one character
/// to a line, and the "least" height is the length of the sentence: 1564
/// points for a group with a project and no supervisor, so that selecting
/// one pushed the window off the bottom of the screen and it stayed there
/// (task 1502; the sentence and its window were in the build before it,
/// 225c8860b, too).
///
/// So the content is not asked. What does not fit on the right-hand side
/// scrolls there (`ControlRoomDetailMessage`).
enum ControlRoomWindowSize {
    /// The least size of the window's content. What the content itself
    /// came to wherever no sentence was in the way: the list's width and a
    /// sliver of the right-hand side across, a few rows down.
    static let least = CGSize(width: 460, height: 548)

    /// Make `content` what `window` shows, with the window's least size its
    /// own and not the content's.
    ///
    /// **The hosting view is put inside the window's content view, not made
    /// it.** One that is the content view sets the window's least size
    /// itself -- to what its content asks, or with nothing asked to no
    /// least size at all, over whatever the window was given (read off a
    /// window: 0 by 0 after `contentMinSize` had been set). Inside a plain
    /// view it sets nothing.
    static func install<Content: View>(_ content: NSHostingView<Content>, in window: NSWindow) {
        content.sizingOptions = []
        let holder = NSView(frame: window.contentView?.bounds ?? NSRect(origin: .zero, size: least))
        content.frame = holder.bounds
        content.autoresizingMask = [.width, .height]
        holder.addSubview(content)
        window.contentView = holder
        window.contentMinSize = least
    }
}
