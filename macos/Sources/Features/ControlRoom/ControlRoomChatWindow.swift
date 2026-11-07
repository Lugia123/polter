import CoreGraphics
import Foundation

/// **The list's window, in points** (task 3016 R4, amended by review C and
/// two real-machine reds).
///
/// The document the lazy list is handed is not the history: it is a window
/// the reader carries. Ten screens above and below the viewport stay drawn
/// and twelve screens is where a row stops being part of it. **A step
/// fills the whole deficit up to one screen** -- the five rows of a slow
/// scroll are the natural size, not a hard cap: with a fixed five rows a
/// fast scroll grew the deficit faster than each 230 pt step could close it
/// and inserted on every callback, dozens a second (the 2026-11-07 red).
///
/// **Screens and rows are two units, and the constants here are in points.**
/// A screen of 16 pt rows and a screen of 300 pt rows are both one screen;
/// a row count is only how many rows one step may move. A margin measured
/// in rows would be 250 rows on one group and 13 on another (review C, M5).
///
/// **What this file decides, and what it does not.** It answers "how many
/// rows in, how many out, and how many to ask for" from the view's reading
/// and the feed's counts. It moves nothing: the view applies the answer
/// through the feed's `feedOlder`/`releaseOlder`, one rows update per call.
enum ControlRoomChatWindow {
    /// **How deep the window is, and how big one step may be** (the
    /// 2026-11-07 capacity red: a fast scroll outran a five-screen margin).
    ///
    /// **An insertion is invisible because of where it happens, not because
    /// of how many rows it carries**: ten screens away from the viewport, a
    /// three-screen step is as unseen as five rows. So the margin is ten
    /// screens and a step may take three.
    static let marginScreens = 10.0
    /// Twelve screens is where a row stops being part of the window. The
    /// dead band between the two absorbs a step's floor without ever
    /// releasing what a step just fed.
    static let retainScreens = 12.0
    /// The first screen is fetched whole: twelve screens, one request,
    /// because the reader has not scrolled yet and there is nothing to pace.
    /// **Aligned with the margin**: a smaller first screen would open the
    /// group already short.
    static let firstScreenScreens = 12.0
    /// A row height to assume before anything has been measured: 800 pt of
    /// pane over the feed's own `defaultViewportRows`. The view replaces it
    /// with the median of the heights it has seen.
    static let defaultRowHeight = 50.0
    /// **A request is made as soon as the buffer is short of the margin,
    /// and carries at least this many rows**: a round trip is the expensive
    /// part, so the refill starts at the first shortfall and asks for a good
    /// slice -- not when the apron is already empty.
    static let requestFloor = 40
    /// The core's own ceiling (`chat_history_begin`'s `limit`).
    static let maxRequestRows = 200

    /// **The viewport's top edge as it really is** (real-machine red,
    /// 2026-11-06): the clip origin, or the document's end while pinned.
    ///
    /// **Never the camera's projection.** The camera says where a projection
    /// should put the viewport; reading it back as this rule's input was a
    /// closed loop: one swallowed inverse froze `top`, every tick then saw
    /// "not enough above", inserted older rows, and the reader scrolling
    /// towards the newest was walked back to the oldest. A rule about how
    /// much page is left must read the page the reader is actually on.
    static func viewportTop(
        pinned: Bool,
        content: Double,
        viewport: Double,
        offset: Double
    ) -> Double {
        pinned ? max(0, content - viewport) : offset
    }

    /// **The document's height, from the rows themselves first** (the
    /// 2026-11-07 red, the page that never reached the bottom).
    ///
    /// The scroll view's own `documentView.frame.height` and the cached
    /// content height are **not this number**: a page that opens has 192 rows
    /// in the frames and a scroll view still reporting 24, and a pinned
    /// projection that asks "is the document taller than the viewport?" of
    /// the 24 waits for a number that is not going to move. `LazyVStack`
    /// measures the rows it makes, so the last measured row's bottom is the
    /// document's height; before any row is measured there is nothing but
    /// the scroll view's own word.
    ///
    /// **The tallest measured bottom, not the last row's frame**: the last
    /// row of a window is usually the far end of the history, which the lazy
    /// stack does not make until the reader is near it.
    static func documentHeight(
        order: [String],
        frames: [String: CGRect],
        live: Double
    ) -> Double {
        if let last = order.last, let frame = frames[last] {
            return Double(frame.maxY)
        }
        let measured = order.compactMap { frames[$0]?.maxY }.max()
        if let measured { return Double(measured) }
        return live
    }

    /// What the view knows about the list, in **points**.
    struct Reading: Equatable {
        /// The viewport's top edge, in the document's coordinates.
        var top: Double
        var viewport: Double
        /// The document's height.
        var content: Double
        /// The first kept row's top, in the document's coordinates.
        var loadedTop: Double
        /// A row's height, for turning a point deficit into rows.
        var rowHeight: Double = ControlRoomChatWindow.defaultRowHeight
    }

    /// **One action per tick.** The document was made to breathe between 67
    /// and 123 rows by a tick that could feed *and* release, sometimes the
    /// same side (real-machine red, 2026-11-06): a feed of five rows and a
    /// release of fourteen, fifty milliseconds apart, for ever. A tick now
    /// answers with exactly one of these; anything else waits for the next
    /// one.
    enum Step: Equatable {
        case none
        case intakeOlder(Int)
        case intakeNewer(Int)
        case releaseOlder(Int)
        case releaseNewer(Int)

        var isAction: Bool { self != .none }
    }

    /// One tick's answer. The requests are not document changes and travel
    /// beside the steps.
    ///
    /// **A feed and an eviction are two independent things** (the capacity
    /// model): the feed keeps the drawn margin, the eviction bounds the far
    /// end. They are on opposite sides by construction -- a side cannot be
    /// short and over-full at once (the dead band) -- so both may run in one
    /// tick without cancelling each other. **At most one of each.**
    struct Decision: Equatable {
        /// The intake (feeding), which moves the camera row and owes a
        /// compensation.
        var feed: Step = .none
        /// The eviction at the far end, which never moves the camera row.
        var evict: Step = .none
        var requestOlderRows = 0
        var requestNewerRows = 0
        /// **A side cannot be short and over-full at once.** When it is, the
        /// inputs disagreed (one stale, one live) -- the view says so and
        /// only the intake is kept.
        var contradictory = false

        var isEmpty: Bool {
            feed == .none && evict == .none
                && requestOlderRows == 0 && requestNewerRows == 0
        }
    }

    /// **How tall a row is, for turning points into rows: the document's own
    /// average.**
    ///
    /// **Not `Reading.rowHeight`, which is a median of the few rows that have
    /// been measured** -- and those are the ones near the viewport. The rows
    /// an eviction acts on are a dozen screens away and have never been laid
    /// out, so their heights are exactly the ones no median has seen. The
    /// 2026-11-07 red: a document one row tall reported 46 pt; the tick after
    /// it held 191 rows of 108 pt, and 46 pt turned that 2 000 pt surplus
    /// into "191 rows", released every one, and the tick after fed them back
    /// -- every 5 ms, for ever.
    ///
    /// Every row in the document is `content - loadedTop` points over the row
    /// count, so the average is right even when no far row has ever been
    /// measured, and it is what both bounds of an eviction must be
    /// expressed in for the margin between them to mean anything.
    static func averageRowHeight(_ reading: Reading, rows: Int) -> Double {
        let total = reading.content - reading.loadedTop
        guard rows > 0, total > 0 else { return max(1, reading.rowHeight) }
        let average = total / Double(rows)
        guard average.isFinite, average >= 1 else { return max(1, reading.rowHeight) }
        return average
    }

    /// **The one rule.** `aboveRows`/`belowRows` are what is loaded outside
    /// the document; `documentAbove`/`documentBelow` are how many rows the
    /// document has either side of the camera, so an eviction can never take
    /// the row the reader is standing on.
    ///
    /// **Every distance here is drawn points, never loaded points.** An
    /// eviction measured from `drawn + apron` would take rows the reader
    /// cannot see while the rows they can see are still there to be taken
    /// from, and the tick after would have to feed them back (the
    /// 2026-11-07 red).
    ///
    /// **Nothing is decided without a viewport** (review C, M5): before the
    /// probe attaches, `viewport` is zero and every threshold would be zero
    /// with it. The view asks again when the first reading arrives.
    static func decide(
        _ reading: Reading,
        aboveRows: Int,
        belowRows: Int,
        documentAbove: Int,
        documentBelow: Int,
        hasEarlier: Bool,
        hasNewer: Bool
    ) -> Decision {
        var out = Decision()
        let viewport = reading.viewport
        guard viewport > 0, reading.content > 0 else { return out }
        let rowsAbove = max(0, documentAbove)
        let rowsBelow = max(0, documentBelow)
        // **The ruler is the whole document's average row**, camera row and
        // both sides included: it is the only height that knows about the far
        // rows as well as the near ones.
        let height = averageRowHeight(reading, rows: rowsAbove + 1 + rowsBelow)
        let margin = marginScreens * viewport
        let retain = retainScreens * viewport
        let above = max(0, reading.top - reading.loadedTop)
        let below = max(0, reading.content - (reading.top + viewport))

        // **The buffer is everything loaded on a side of the viewport** --
        // what is drawn there plus the apron behind it. A fast scroll spends
        // more, so the intake spends more of the apron, and the request
        // refills the apron as soon as the *loaded* side is short; that is
        // what keeps the buffer from being eaten through (the 2026-11-07
        // capacity model). **An insertion is invisible because of where it
        // happens** -- the document's edge, ten screens from the viewport --
        // not because of how many rows it carries.
        let bufferAbove = above + Double(aboveRows) * height
        let bufferBelow = below + Double(belowRows) * height
        var intakeOlder = 0
        var intakeNewer = 0
        var releaseOlder = 0
        var releaseNewer = 0

        // **The drawn margin is what the reader sees; the apron is the
        // reservoir behind it.** The intake spends the reservoir to keep the
        // drawn margin at the margin -- the amount is what the reader just
        // consumed, never a fixed row count -- and a request goes out as soon
        // as the *loaded* side (drawn + reservoir) is short, so the
        // reservoir never runs dry.
        if above < margin {
            // **The whole drawn shortfall, in one rows change.**
            if aboveRows > 0 {
                intakeOlder = min(
                    Int(((margin - above) / height).rounded(.up)),
                    aboveRows
                )
            }
        }
        if bufferAbove < margin, hasEarlier {
            out.requestOlderRows = requestRows((margin - bufferAbove) / height)
        }
        if above > retain, rowsAbove > 0 {
            // **Dequeue is the mirror: the whole excess, down to retain, in
            // one rows change.** A release may never take the side under the
            // margin (taking it under is how one tick's release became the
            // next tick's intake), and **both bounds are drawn points over
            // the same ruler**, so the margin between them is real even when
            // the ruler is wrong about any one row.
            let excess = Int(((above - retain) / height).rounded(.up))
            let room = Int(((above - margin) / height).rounded(.down))
            releaseOlder = max(
                0, min(rowsAbove, min(max(excess, 1), max(room, 0)))
            )
            // **The invariant, in code**: what a release takes from a side
            // leaves that side at least the margin. Both bounds use one
            // ruler, so only an edit that separates them can break this --
            // which is what the assertion is for.
            assert(
                Double(releaseOlder) * height <= above - margin + 0.001,
                "a release of \(releaseOlder) leaves \(above - Double(releaseOlder) * height) of \(margin)"
            )
        }
        if below < margin {
            if belowRows > 0 {
                intakeNewer = min(
                    Int(((margin - below) / height).rounded(.up)),
                    belowRows
                )
            }
        }
        if bufferBelow < margin, hasNewer {
            out.requestNewerRows = requestRows((margin - bufferBelow) / height)
        }
        if below > retain, rowsBelow > 0 {
            let excess = Int(((below - retain) / height).rounded(.up))
            let room = Int(((below - margin) / height).rounded(.down))
            releaseNewer = max(
                0, min(rowsBelow, min(max(excess, 1), max(room, 0)))
            )
            assert(
                Double(releaseNewer) * height <= below - margin + 0.001,
                "a release of \(releaseNewer) leaves \(below - Double(releaseNewer) * height) of \(margin)"
            )
        }

        // **One side cannot be short and over-full at once.** If it is, the
        // two numbers this rule was given came from different moments; say
        // so and trust the feed, not the eviction.
        if intakeOlder > 0, releaseOlder > 0 {
            out.contradictory = true
            releaseOlder = 0
        }
        if intakeNewer > 0, releaseNewer > 0 {
            out.contradictory = true
            releaseNewer = 0
        }

        // **At most one feed and one eviction per tick.** They are on
        // opposite sides by construction, so running both cannot cancel
        // them; running only one starves the other: feeding first piled the
        // far end up (497 rows in the 2026-11-07 fixture), evicting first
        // let the drawn margin fall to nothing while a scroll kept the far
        // side one row over retain.
        if intakeOlder > 0 {
            out.feed = .intakeOlder(intakeOlder)
        } else if intakeNewer > 0 {
            out.feed = .intakeNewer(intakeNewer)
        }
        if releaseOlder > 0 {
            out.evict = .releaseOlder(releaseOlder)
        } else if releaseNewer > 0 {
            out.evict = .releaseNewer(releaseNewer)
        }
        return out
    }

    /// **What an insertion above the viewport owes it, in points**: the rows
    /// that went in, at the document's own average height.
    ///
    /// **Not a projection to the camera's row.** An insertion puts ten
    /// screens of rows between the reader and that row, so the lazy stack
    /// never makes it, its frame never arrives, and a compensation waiting
    /// for that frame waits for ever. That is what the real machine did on
    /// 2026-11-07: 99 rows in, six points of scroll, a hundred rows of slide
    /// -- on every tick, all the way back through the history. The rows that
    /// went in arrive as one rows change and come from the same stream as the
    /// document around them, so the document's average is their ruler: the
    /// error is a fraction of a row, not eleven screens.
    static func insertedPoints(rows: Int, rowHeight: Double) -> Double {
        max(0, Double(rows)) * max(1, rowHeight)
    }

    /// **Where the viewport's top goes after an insertion**: where it was,
    /// plus what the rows above the reader took up.
    static func compensatedTop(offset: Double, rows: Int, rowHeight: Double) -> Double {
        offset + insertedPoints(rows: rows, rowHeight: rowHeight)
    }

    /// **Which amount the debt is paid with: the document's own growth, and
    /// only an estimate when there is no growth to read.**
    ///
    /// The estimate is a whole batch at the document's average, and **the
    /// row that went in is not the average row** (the 2026-11-07 red, third
    /// round: one 72 pt row went in where the document averaged 92 -- 20 pt
    /// of over-scroll, an amount that moves the viewport's top edge into the
    /// next row). Eighteen of those a second is the small jump the person
    /// saw; twenty points is invisible, but a row edge is not.
    ///
    /// `grown` is zero (or a hair) before the layout has the rows, and that
    /// is what "wait" means here: no amount beats a wrong one.
    static func compensationAmount(grown: Double, estimate: Double) -> Double {
        grown > 0.5 ? grown : estimate
    }

    /// **What is left of a debt after its first instalment** -- the part
    /// paid in the turn the rows changed, before anything was drawn. A debt
    /// paid in full leaves nothing to scroll, and one paid short corrects by
    /// the difference; it is never paid twice.
    static func compensationRemainder(amount: Double, paid: Double) -> Double {
        amount - paid
    }

    /// **The request size**: the rows the margin is missing, with a floor so
    /// one round trip brings back more than a handful, and the core's own
    /// ceiling on top.
    static func requestRows(_ missing: Double) -> Int {
        let rounded = Int(missing.rounded(.up))
        return min(maxRequestRows, max(requestFloor, rounded))
    }

    /// How many rows the first screen asks for: twelve screens of the rows
    /// the pane has been measured to show. **Before the probe attaches** the
    /// count is the conservative default, and the feed asks with it -- the
    /// alternative is waiting for a measurement that a first screen is what
    /// produces.
    static func firstScreenRows(viewportRows: Int) -> Int {
        let rows = Int((firstScreenScreens * Double(max(1, viewportRows))).rounded(.up))
        return min(maxRequestRows, max(1, rows))
    }
}
