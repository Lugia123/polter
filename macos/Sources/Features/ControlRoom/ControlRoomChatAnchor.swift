import CoreGraphics
import Foundation

/// The chat list's rules: where a row is, where the viewport is in it, and
/// who moved it (task 3016's camera model).
///
/// **The camera is the truth; the pixel offset is its projection.** The list
/// hands the frames it has and the viewport's content offset; `place` turns
/// one into the other, `y(of:)` turns it back, and only a callback the reader
/// caused may move it. A row inserted above, a Markdown row measuring late, a
/// narrower window: every one of those changes frames and none of them
/// changes the camera -- the view re-projects instead.
enum ControlRoomChatAnchor {
    /// What a row list did between two of its states, as far as the reader's
    /// place is concerned.
    ///
    /// **`moved` is the sliding window** (task 3016 R4): rows left the
    /// document at one end (into the feed's apron) and others came in at
    /// either end. It is *not* `replaced` -- the rows the reader is standing
    /// among are the same rows, and a replacement would throw the frames
    /// away and re-measure the screen (review C, M4). `replaced` is kept for
    /// a window that really is another map: a locate's around page, a
    /// session change, a restart.
    enum Change: Equatable {
        case none
        /// Rows went in front, nothing else changed.
        case prepended
        /// Rows went on the end, nothing else changed.
        case appended
        /// The window slid or was trimmed: a contiguous run is still there,
        /// the ends are not what they were.
        case moved
        /// Another map: no contiguous run of the old rows is in the new.
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

    /// Who a bounds callback belongs to, from every signal the view has.
    ///
    /// **A reader who just moved the list wins over every layout inference.**
    /// `userScrolling` is the live-scroll notification, which covers the
    /// gesture while the fingers are on the trackpad. **It does not cover
    /// what follows**: a trackpad's momentum after `didEndLiveScroll` posts
    /// no live scroll, and neither does a plain mouse wheel. `readerRecently`
    /// is the second signal -- a `.scrollWheel` event that reached this
    /// scroll view, momentum included. Without it, a momentum callback
    /// carrying a lazily measured row's growth was called layout, `atBottom`
    /// was still the stale true, and the list was put back at the bottom
    /// under the reader's hand -- "it only scrolls down" (task 2999 ③,
    /// modelled against the real keeper).
    static func cause(
        contentChanged: Bool,
        framesChanged: Bool,
        phaseIsLayout: Bool,
        programmatic: Bool,
        userScrolling: Bool,
        readerRecently: Bool = false
    ) -> Cause {
        // **A real live-scroll, or a wheel, wins over a programmatic match
        // as well as over every layout inference** (real-machine red,
        // 2026-11-06). A y that happens to equal one this view once aimed at
        // does not make the callback ours: the reader's own signal explains
        // it, and treating it as ours skipped `camera.bounds` -- one frozen
        // camera, then a window that kept feeding older rows under a reader
        // scrolling the other way. A compensation whose callback arrives
        // under a hand is harmless to re-read: its y is where the camera
        // already is, so the place it writes back is the same place.
        if userScrolling || readerRecently { return .user }
        if programmatic { return .programmatic }
        if phaseIsLayout || framesChanged { return .layout }
        if contentChanged { return .layout }
        return .user
    }

    /// **Which of the five things happened to the list.** A contiguous run
    /// of the old rows surviving in the new one, with the rest added or
    /// removed at the ends, is a window move -- **not a replacement**
    /// (review C, M4): the sliding window trims and feeds on every few
    /// screens, and treating each of those as a new map would clear the
    /// frames and re-measure the screen at the same rate.
    ///
    /// Row ids are unique within a list, which is what makes the run easy
    /// to find: the first and the last old id still in the new list bound
    /// it, and everything outside it must be an end.
    static func change(from old: [String], to new: [String]) -> Change {
        if old == new { return .none }
        if old.isEmpty { return new.isEmpty ? .none : .appended }
        guard !new.isEmpty else { return .replaced }
        let present = Set(new)
        guard let oldStart = old.firstIndex(where: present.contains),
              let oldEnd = old.lastIndex(where: present.contains),
              let newStart = new.firstIndex(of: old[oldStart]),
              let newEnd = new.firstIndex(of: old[oldEnd])
        else { return .replaced }
        let kept = Array(old[oldStart...oldEnd])
        guard newEnd - newStart + 1 == kept.count,
              Array(new[newStart...newEnd]) == kept
        else { return .replaced }
        // A row that left the middle of the kept run is not a window move:
        // the surviving ids would bound a run that no longer matches.
        let addedFront = newStart
        let addedBack = new.count - 1 - newEnd
        let droppedFront = oldStart
        let droppedBack = old.count - 1 - oldEnd
        if addedFront == 0, droppedFront == 0, droppedBack == 0, addedBack > 0 {
            return .appended
        }
        if addedBack == 0, droppedBack == 0, droppedFront == 0, addedFront > 0 {
            return .prepended
        }
        return .moved
    }

    /// Whether the viewport is at the bottom. A content shorter than the
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

    /// **Whether the located row is really on screen**: its frame has been
    /// measured and it overlaps the viewport.
    ///
    /// **A locate arriving is not the moment to draw the eye to it** (task
    /// 2999 ④). `locate(anchor:)` publishes the anchor at once, while the
    /// rows are still the old window that is about to be replaced.
    static func locatedIsInView(
        located: String,
        frames: [String: CGRect],
        offset: Double,
        viewport: Double
    ) -> Bool {
        guard viewport > 0, let frame = frames[located] else { return false }
        return frame.maxY > offset && frame.minY < offset + viewport
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

/// **The group chat's camera** (task 3016): the row under the viewport's top
/// edge and how far into it the reader is -- never a pixel offset, never an
/// array index.
///
/// The rules live here, away from the view, so the moments the design names
/// can be held by a test without a window on screen: a prepended page, a
/// Markdown row measuring late, a narrower window, the reader taking over,
/// and a jump to a row the lazy stack has not made yet.
enum ControlRoomChatCamera {
    /// A row and how far past its top the viewport's top edge is, **in
    /// points**. Not a fraction of the row: a long message re-measured taller
    /// must keep the reader on the same words (R1-9). The offset can be past
    /// the row's height when the top edge sits in the gap below it.
    struct Place: Equatable {
        var id: String
        var offset: Double
    }

    /// What the projection should do, in **three kinds of answer**: scroll
    /// somewhere, ask for a row, or say why nothing can be done yet. `wait`
    /// and `fallback` are "I do not know yet" and "I know it is gone" -- two
    /// different answers that a bool could not tell apart.
    enum Projection: Equatable {
        /// The place's row is measured: put `y` at the top.
        case scroll(Double)
        /// The row is in `rows` but the lazy stack has not made it: ask for
        /// it by name, then project from the frames that follow (R1-3).
        case scrollTo(String)
        /// Pin to the bottom. Requires `pinIsAvailable` (R1-6).
        case pin
        /// Waiting, with no scroll. **`nil` means "there is no camera yet"**
        /// (an empty map, or an unpinned view with no place): a different
        /// state from "this known row is waiting to be measured", which names
        /// the row. The two must not share one value.
        case wait(String?)
        /// **The place's row is gone** (trim, a locate's new window, a
        /// session change, `clearWindow`, a clamped origin). The answer is a
        /// place on the nearest measured row **keeping an offset inside it**,
        /// or nil when there is none -- and it is always an answer, never
        /// `wait` (R1-4). The offset is what stops a fallback jumping half a
        /// viewport (M2).
        case fallback(Place?)
    }

    /// The camera and what projection is still owed for it.
    struct State: Equatable {
        var place: Place?
        var pinned: Bool
        var owed: Projection?

        init(place: Place? = nil, pinned: Bool = true, owed: Projection? = nil) {
            self.place = place
            self.pinned = pinned
            self.owed = owed
        }

        /// **The inverse: a bounds callback may write the place only when the
        /// reader caused it.** Everything else -- a measured row, a replaced
        /// window, the view's own scroll -- leaves the camera alone, because
        /// the correction is made *from* it. Returns whether it wrote.
        ///
        /// **`pinned` here only means "a reader moved, so the old bottom is
        /// no longer owed".** The view follows it with `pinned(after:atBottom:
        /// was:)` to learn whether the reader actually landed on the bottom;
        /// the pair must be applied in that order (task 3016 R1-7).
        @discardableResult
        mutating func bounds(
            cause: ControlRoomChatAnchor.Cause,
            y: Double,
            order: [String],
            frames: [String: CGRect]
        ) -> Bool {
            guard writesPlace(cause: cause) else { return false }
            if let next = ControlRoomChatCamera.place(
                order: order, frames: frames, at: y
            ) {
                place = next
            }
            // **A hand on the list voids every projection it interrupted.**
            owed = nil
            pinned = false
            return true
        }
    }

    /// **The inverse's rule: the last row whose top is at or above `y`.**
    /// Windows' `anchor` uses the same one, and it is the lossless choice:
    ///
    /// * inside a row: that row, offset = y - top (0 ..< row height);
    /// * in the 10 pt gap below a row: **still that row**, offset = y - top
    ///   (row height ..< row height + gap) -- the distance is kept, and
    ///   `top + offset` restores y exactly;
    /// * above the first measured row (the list's 12 pt top padding): the
    ///   first measured row with a **negative** offset, which projects back to
    ///   the same point. No negative offset comes out of the loop above -- a
    ///   row is only chosen there when its top is at or above y.
    ///
    /// **The `break` assumes measured rows are monotonically lower in
    /// `order`.** An unmeasured row is skipped, so if row 3 has no frame and
    /// row 4 is at or above y, row 4 is chosen even though the top edge is
    /// physically in row 3's stretch: this frame has no basis for row 3, and
    /// the next frames preference is what answers it. That is deliberate, not
    /// a missed case.
    ///
    /// `nil` only when nothing is measured at all.
    static func place(order: [String], frames: [String: CGRect], at y: Double) -> Place? {
        var result: Place?
        for id in order {
            guard let frame = frames[id] else { continue }
            if Double(frame.minY) <= y {
                result = Place(id: id, offset: y - Double(frame.minY))
            } else {
                // Later measured rows start lower still: nothing after this
                // can satisfy the rule.
                break
            }
        }
        if result != nil { return result }
        // Above every measured row: the first one, distance kept negative.
        for id in order {
            guard let frame = frames[id] else { continue }
            return Place(id: id, offset: y - Double(frame.minY))
        }
        return nil
    }

    /// **The projection: camera → pixels.** `nil` when the row is not
    /// measured (the view waits for frames rather than guessing).
    static func y(of place: Place, frames: [String: CGRect]) -> Double? {
        guard let frame = frames[place.id] else { return nil }
        return Double(frame.minY) + place.offset
    }

    /// The decision the view applies. It reads no pixel offset.
    ///
    /// **Pinning does not need any row height** (the Windows host's rule):
    /// `scroll to max` against a document the lazy stack has estimated is
    /// good enough, and every frames change pins again. That is why the first
    /// screen never has to wait for the last row to be measured -- and why a
    /// new message arriving does not scroll to its top first (MF1).
    ///
    /// `pending` is a jump whose map is still on its way (M1): a place naming
    /// it must wait, not fall back -- "not loaded yet" is not "gone".
    static func projection(
        state: State,
        order: [String],
        frames: [String: CGRect],
        content: Double,
        viewport: Double,
        centre: Double,
        near: Int? = nil,
        pending: String? = nil
    ) -> Projection {
        if state.pinned {
            guard pinIsAvailable(content: content, viewport: viewport) else {
                // Nothing to pin to yet (an empty or short map).
                return .wait(nil)
            }
            return .pin
        }
        guard let place = state.place else { return .wait(nil) }
        if let y = y(of: place, frames: frames) { return .scroll(y) }
        if let pending, pending == place.id, !order.contains(pending) {
            // **A jump still on its way** (M1): the row is not in the map
            // yet, and that is not the fallback's question.
            return .wait(pending)
        }
        if order.contains(place.id) {
            // **Only a real jump asks the lazy stack by name** (MF1). A row
            // that merely is not measured yet (a width change's fresh map,
            // a live message below a pinned viewport) waits for the frames
            // it is about to get; seeking would scroll to the row's top and
            // then scroll again.
            return pending == place.id ? .scrollTo(place.id) : .wait(place.id)
        }
        return .fallback(
            fallbackPlace(centre: centre, order: order, frames: frames, near: near)
        )
    }

    /// The fallback's place: the measured row nearest the viewport's **top
    /// edge**, with the reader's offset inside that row kept. Using the
    /// viewport's middle and scrolling to the row's top was a half-screen
    /// jump on every fallback (M2).
    /// `near` is the camera's own place in the order, when it still has
    /// one. **The fallback may only land near it**: the whole table's
    /// nearest row is how a sparse map -- only early rows measured -- walked
    /// a reader back to the beginning (2026-11-07).
    static func fallbackPlace(
        centre: Double,
        order: [String],
        frames: [String: CGRect],
        near: Int? = nil
    ) -> Place? {
        guard let id = fallbackRow(centre: centre, order: order, frames: frames, near: near),
              let frame = frames[id]
        else { return nil }
        let offset = min(
            max(0, centre - Double(frame.minY)),
            Double(frame.height)
        )
        return Place(id: id, offset: offset)
    }

    /// Which measured row the fallback lands on. **Near the camera when it
    /// has an index**, by the viewport's y otherwise.
    static func fallbackRow(
        centre: Double,
        order: [String],
        frames: [String: CGRect],
        near: Int? = nil
    ) -> String? {
        let present = Set(order)
        let measured = frames.filter { present.contains($0.key) }
        guard !measured.isEmpty else { return nil }
        if let near {
            let target = min(max(0, near), max(0, order.count - 1))
            return measured.keys.min { a, b in
                let ia = order.firstIndex(of: a).map { abs($0 - target) } ?? Int.max
                let ib = order.firstIndex(of: b).map { abs($0 - target) } ?? Int.max
                return ia < ib
            }
        }
        return measured.min {
            abs(Double($0.value.midY) - centre)
                < abs(Double($1.value.midY) - centre)
        }?.key
    }

    /// The inverse's gate (R1-2 / the old `mayRestore`). **Nothing is
    /// projected under a hand that is on the list.**
    static func mayProject(userScrolling: Bool, readerRecently: Bool) -> Bool {
        !userScrolling && !readerRecently
    }

    /// The inverse's gate, as a rule about the cause alone.
    static func writesPlace(cause: ControlRoomChatAnchor.Cause) -> Bool {
        cause == .user
    }

    /// **A projection owed against a version of the frames may only be
    /// answered by a newer one.** A replaced window's preference arrives
    /// after the rows changed; projecting from the old map is projecting to a
    /// place that does not exist any more (R1-12).
    static func mayAnswer(framesEpoch: UInt64, waitingSince: UInt64) -> Bool {
        framesEpoch > waitingSince
    }

    /// Whether the bottom can be pinned at all (R1-6, revised by MF1): the
    /// document must be taller than the viewport. **No row needs to be
    /// measured** -- `scroll to max` is the bottom of the estimated document,
    /// and the next frames change pins again. A short (or empty) map has no
    /// bottom to travel to and waits.
    static func pinIsAvailable(content: Double, viewport: Double) -> Bool {
        content > 0 && content > viewport
    }

    /// A target the view sent, and **the frames that were on screen when it
    /// sent it**. A y means nothing without the map it was computed from
    /// (review C, M3): five rows go in or out every few screens now, and a
    /// stale target from the previous map is exactly where the reader's
    /// next scroll arrives, so a bare y would be matched by the reader's
    /// own movement.
    struct ScrollExpectation: Equatable {
        var y: Double
        var epoch: UInt64
    }

    /// **Whether a bounds callback belongs to the view's own scroll** (MF2,
    /// tightened by review C's M3). A callback is the view's when it lands
    /// on a target sent **from the same frames map**; a target from an older
    /// map is dropped rather than matched, because the map it was computed
    /// in no longer exists.
    static func programmaticCallback(
        inScrollCall: Bool,
        seekInFlight: Bool,
        y: Double,
        epoch: UInt64,
        expectations: inout [ScrollExpectation]
    ) -> Bool {
        expectations.removeAll { $0.epoch != epoch }
        if let index = expectations.firstIndex(where: { abs($0.y - y) <= 1 }) {
            expectations.remove(at: index)
            return true
        }
        return inScrollCall || seekInFlight
    }

    /// **Whether a locate has settled its landing** (M5). It has once the
    /// target's own window is in place (`context != nil`) or the feed has
    /// said the target is not in it (`locateTrouble`). Without this a target
    /// outside its window was never "landed", so every rows change asked for
    /// the same `around` again -- one core request per round.
    static func locateSettled(
        targetInRows: Bool,
        hasContext: Bool,
        trouble: Bool
    ) -> Bool {
        targetInRows || hasContext || trouble
    }

    /// **Whether the lower edge of a located window may ask for a newer page**
    /// (M4). **Only on the reader's own input.** A pinned viewport re-pins on
    /// every page, and asking from that programmatic callback walks the whole
    /// remaining history one request at a time.
    static func newerIsDue(wants: Bool, fromInput: Bool) -> Bool {
        wants && fromInput
    }

    /// **`pinned` after a callback.** Only the reader changes it: reaching
    /// the bottom is following again, leaving it is reading history. A layout
    /// or the view's own scroll changes nothing (R1-7).
    /// **Only a hand on the list pins or unpins it.**
    ///
    /// `cause` is the wrong question on its own: it **falls back to `.user`**
    /// for a callback none of its tests explains, and the first layout after
    /// a page opens is exactly such a callback -- the clip is at `offset = 1`
    /// of 22 277 and no scroll of the view's has landed. Reading that as the
    /// reader put the viewport at the top (`atBottom = false`) unpinned the
    /// page before its own bottom projection ran, so it opened somewhere in
    /// the middle of the history and every later decision was taken from
    /// there (2026-11-07).
    ///
    /// The reader's own signals are `userScrolling` and the wheel window;
    /// `hand` is those, not `cause == .user`.
    static func pinned(
        after cause: ControlRoomChatAnchor.Cause,
        atBottom: Bool,
        was: Bool,
        hand: Bool
    ) -> Bool {
        guard cause == .user, hand else { return was }
        return atBottom
    }

    /// The measured row nearest a point in content coordinates. **The
    /// fallback's answer**: an offset can be legal and still fall in a
    /// stretch a `LazyVStack` never instantiated, so a lost place moves to a
    /// row that really has a frame -- not to the bottom, which throws the
    /// reader's place away.
    ///
    /// **Only rows still in `order` count.** `frames` may hold the old
    /// coordinates of rows that have since left the window -- a trim is
    /// exactly the reason this fallback runs -- and landing on one of those
    /// would project into a place that no longer exists.
    static func nearestMeasured(
        centre: Double,
        order: [String],
        frames: [String: CGRect]
    ) -> String? {
        let present = Set(order)
        return frames
            .filter { present.contains($0.key) }
            .min {
                abs(Double($0.value.midY) - centre) < abs(Double($1.value.midY) - centre)
            }?.key
    }

}
