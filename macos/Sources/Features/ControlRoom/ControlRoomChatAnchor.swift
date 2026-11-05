import CoreGraphics
import Foundation

/// Where the reader is, as a message identity and an offset into it
/// (DESIGN-v2 §9.2): never an array index and never a page height.
///
/// **A rule, not a scroll view.** The message list hands the frames it has
/// and the viewport's content offset; this says which message is under the
/// viewport's top edge and how far into it the reader has gone, and where to
/// put the viewport again after a row above it changed height. Keeping the
/// arithmetic here is what lets a test hold the four moments the design names
/// -- older messages prepended, Markdown measured, the window narrowed, the
/// preview sidebar opened -- without a window on screen.
enum ControlRoomChatAnchor {
    /// A message and how far the viewport's top is past that message's top.
    /// `offset` is never negative: a row that starts below the viewport's
    /// top edge (a gap above the first row) is read as an offset of zero.
    struct Anchor: Equatable {
        var id: String
        var offset: Double
    }

    /// The anchor for a viewport whose content offset is `offset`: the first
    /// row in `order` whose bottom is still below that line. `nil` when no
    /// row the view knows about reaches it (the first paint, before frames
    /// are measured).
    static func anchor(
        order: [String],
        frames: [String: CGRect],
        at offset: Double
    ) -> Anchor? {
        for id in order {
            guard let frame = frames[id] else { continue }
            if frame.maxY > offset + 0.5 {
                return Anchor(id: id, offset: max(0, offset - frame.minY))
            }
        }
        return nil
    }

    /// The content offset that puts `anchor` back where the reader left it.
    /// `nil` when that row is not measured (dropped from the window, or not
    /// made yet) -- then there is nothing honest to restore to, and the list
    /// leaves the scroll where it is rather than guessing.
    static func offset(of anchor: Anchor, frames: [String: CGRect]) -> Double? {
        guard let frame = frames[anchor.id] else { return nil }
        return frame.minY + anchor.offset
    }

    /// Whether the viewport is at the bottom, which is the only moment a new
    /// message may pull it down (DESIGN-v2 §9.2). A content shorter than the
    /// viewport is at both ends at once.
    static func isAtBottom(
        offset: Double,
        viewport: Double,
        content: Double,
        tolerance: Double = 2
    ) -> Bool {
        guard viewport > 0, content > 0 else { return true }
        return content - (offset + viewport) <= tolerance
    }

    /// Whether the reader has reached the top far enough to ask for older
    /// messages. The list asks once per arrival; the feed refuses while a
    /// page is already out.
    static func shouldLoadOlder(offset: Double, threshold: Double = 24) -> Bool {
        offset <= threshold
    }

    /// What a row list did between two of its states, as far as the reader's
    /// place is concerned. **A window that dropped rows from its front and
    /// added others is `replaced`**, not `appended`: neither end is the same
    /// list any more, and calling it an append would pull a reader in history
    /// down without asking.
    enum Change: Equatable {
        case none
        case prepended
        case appended
        case replaced
    }

    /// Why a scroll view's bounds callback happened. **Not "not programmatic
    /// means the reader"**: a Markdown row that measured from pending to
    /// rendered moves the bounds with no rows or width change, and its frames
    /// preference may arrive after the bounds.
    enum Cause: Equatable {
        case user
        case layout
        case programmatic
    }

    static func cause(
        contentChanged: Bool,
        framesChanged: Bool,
        phaseIsLayout: Bool,
        programmatic: Bool,
        userScrolling: Bool
    ) -> Cause {
        if programmatic { return .programmatic }
        // **A real live-scroll wins over every layout inference.** While a
        // restore waits for frames, a person dragging the list is reading;
        // classifying their bounds as layout would put them back.
        if userScrolling { return .user }
        if phaseIsLayout || framesChanged { return .layout }
        if contentChanged { return .layout }
        return .user
    }

    /// Whether a bottom remembered earlier may still be performed: only if
    /// the reader has not moved the list since. A layout or a programmatic
    /// scroll does not move `userEpoch`; the reader does.
    static func mayFollow(intentEpoch: UInt64, currentUserEpoch: UInt64) -> Bool {
        intentEpoch == currentUserEpoch
    }

    static func change(from old: [String], to new: [String]) -> Change {
        if old == new { return .none }
        if old.isEmpty { return new.isEmpty ? .none : .appended }
        guard new.count >= old.count else { return .replaced }
        if new.prefix(old.count).elementsEqual(old) { return .appended }
        if new.suffix(old.count).elementsEqual(old) { return .prepended }
        return .replaced
    }

    /// **The reader's place is frozen before a layout change, not after.**
    /// A bounds callback during a prepend, a Markdown measurement or a
    /// narrower window arrives with new frames and an old offset; reading
    /// the anchor then overwrites the reader's position with a different
    /// message. This keeper decides which callbacks may move the anchor:
    ///
    ///  * a user scroll (no layout change, no programmatic scroll);
    ///  * never a layout or a programmatic scroll;
    ///  * a layout change freezes the anchor last read from the user, and the
    ///    view restores that frozen anchor once the new frames are known.
    ///
    /// Coordinates are one system throughout: row frames are the scroll
    /// content's, `y` is the clip view's content origin, and the restore
    /// target is a content origin.
    struct Keeper: Equatable {
        private(set) var anchor: Anchor?
        private(set) var frozen: Anchor?
        private(set) var restoring = false
        private(set) var layoutEpoch: UInt64 = 0
        private(set) var userEpoch: UInt64 = 0
        private(set) var programmatic = 0

        /// A bounds callback. `framesChanged` says the row frames are not the
        /// ones the last callback saw; such a movement is layout, not the
        /// reader. Returns whether this callback may move the anchor.
        mutating func bounds(
            y: Double,
            order: [String],
            frames: [String: CGRect],
            framesChanged: Bool,
            programmatic isProgrammatic: Bool
        ) -> Bool {
            guard !isProgrammatic, !framesChanged else { return false }
            // **A real movement ends a restore.** A reader who grabs the list
            // while it is being put back is reading, and a restore that
            // ignored them would fight the scroll they are making.
            restoring = false
            frozen = nil
            if let next = ControlRoomChatAnchor.anchor(order: order, frames: frames, at: y) {
                anchor = next
            }
            userEpoch &+= 1
            return true
        }

        /// The view is putting the list back itself: the bounds callback it
        /// causes is not the reader. Registered **before** the scroll call,
        /// so a synchronous callback sees it.
        mutating func willScrollProgrammatically() {
            programmatic &+= 1
        }

        /// That callback arrived.
        mutating func consumeProgrammaticCallback() {
            if programmatic > 0 { programmatic -= 1 }
        }

        /// The scroll moved nothing, so no callback will come.
        mutating func cancelProgrammatic() {
            if programmatic > 0 { programmatic -= 1 }
        }

        /// A follow or an explicit "latest" replaces a pending restore.
        mutating func cancelRestore() {
            restoring = false
            frozen = nil
        }

        /// A layout change is about to happen: freeze where the reader was.
        mutating func layoutWillChange() {
            layoutEpoch &+= 1
            if let anchor {
                frozen = anchor
                restoring = true
            }
        }

        /// Seed the keeper from a position the page kept across a tab switch.
        mutating func seed(_ anchor: Anchor) {
            self.anchor = anchor
        }

        func restoreTarget(frames: [String: CGRect]) -> Double? {
            guard restoring, let frozen else { return nil }
            return ControlRoomChatAnchor.offset(of: frozen, frames: frames)
        }

        mutating func restored() {
            restoring = false
            frozen = nil
        }
    }

    /// Whether a probe view may attach its observer, and to what. **One
    /// observer, one clip view**: a view moved between windows schedules an
    /// attach per move, and an older queued one must not attach to a scroll
    /// view the newer move has already left.
    struct AttachLedger: Equatable {
        private(set) var generation: UInt64 = 0
        private(set) var attached: String?

        mutating func moved(inWindow: Bool) -> UInt64 {
            generation &+= 1
            attached = nil
            return generation
        }

        func mayAttach(generation: UInt64, inWindow: Bool, clip: String) -> Bool {
            inWindow && generation == self.generation && attached != clip
        }

        @discardableResult
        mutating func attached(_ clip: String, generation: UInt64) -> Bool {
            guard generation == self.generation else { return false }
            attached = clip
            return true
        }

        mutating func detach() {
            attached = nil
        }

        /// A queued attach from before this moment can no longer attach.
        mutating func invalidate() {
            generation &+= 1
            attached = nil
        }
    }
}
