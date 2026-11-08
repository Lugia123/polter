import SwiftUI

/// The chat's own index bar (task 3002): **the one place a list with no
/// length says how much it holds**.
///
/// The message list is a fixed-height camera over a stream. Its document
/// height is whatever has been loaded so far, so the system scroller says
/// "the content got taller" -- the thumb shrinks as pages arrive even though
/// the reader's view of the conversation has not changed at all. The design's
/// model is the other way round: **ticks are the rows already loaded, and the
/// thumb is the part of them the viewport covers**. Loading more is the
/// background's business; it lengthens the bar and shortens the thumb, and
/// nothing above the list ever moves.
///
/// ⚠️ **This bar covers the loaded map and nothing else.** It never points at
/// a row that is not in `feed.rows`, so a drag cannot ask the list to scroll
/// to a message the view does not have. Reaching further back for a specific
/// message is `jumpToAnchor`'s (the feed's `around` window), not a scroll.
///
/// The arithmetic is `static` and free of any view: the thumb's height and
/// place, which row a drag lands on, how many rows one drawn tick stands for,
/// and which page a click on the bare track moves.
enum ControlRoomChatIndexBar {
    /// **The look table, named at this scope.** The three numbers below are
    /// read from it, and the alias every other file writes lives inside its
    /// own type -- a file-scope `Look` does not exist, and this enum is at
    /// file scope.
    typealias Look = ControlRoomLook

    /// **A thumb shorter than this is not grabbable**, whatever the ratio
    /// says. Below it the bar stops being draggable by hand and a night's
    /// worth of messages could not be navigated. **From the shared look
    /// table** (task 3002): the Windows host draws the same bar and reads
    /// the same number from `look.rs`, and neither source carries its own
    /// copy of it.
    static let minThumb = CGFloat(Look.Chat.barThumbMin)
    /// The drawn track's width, and the whole of its hit area: the bar must
    /// not take clicks meant for the list beside it.
    static let trackWidth = CGFloat(Look.Chat.barWidth)
    /// Between the track and the window's edge.
    static let trackInset = CGFloat(Look.Chat.barGap)
    /// The least height between two drawn ticks. **Mac-local on purpose**:
    /// Windows' chat draws no ticks, so this is not in the shared look table
    /// (which carries only the 36 / 10 / 6 the two hosts agree on).
    static let tickSpacing: CGFloat = 5


    // MARK: - The camera in tick space


    /// **Not the bar's: the feed's.** How many rows one screen covers -- the
    /// page size `publishViewportRows` writes to `feed.viewportRows`. The bar
    /// speaks points now (§23.3); this stayed in rows because its reader asks
    /// a row question ("how many rows is a screen"), not a bar one.
    ///
    /// How many rows the viewport covers, counted only over rows that have
    /// been measured. A partly visible row counts by the part that is
    /// visible, so the thumb's length moves continuously rather than a whole
    /// row at a time. `nil` when nothing overlaps -- unknown, not zero.
    ///
    /// **Frames, not `viewport / averageRowHeight`**: an estimate was tried
    /// and the thumb jittered on every scroll, because the average moved
    /// with whichever rows happened to be made.
    static func viewportTicks(
        order: [String],
        frames: [String: CGRect],
        offset: Double,
        viewport: Double
    ) -> Double? {
        guard viewport > 0 else { return nil }
        var covered: Double = 0
        for id in order {
            guard let frame = frames[id], frame.height > 0 else { continue }
            let top = max(frame.minY, offset)
            let bottom = min(frame.maxY, offset + viewport)
            if bottom > top { covered += Double(bottom - top) / Double(frame.height) }
        }
        return covered > 0 ? covered : nil
    }

    // MARK: - The bar's shape




    // MARK: - Point space (design §23.3, step one)

    /// **Points from the newest row's bottom to the viewport's top edge.**
    /// Zero is the newest message; the number grows as the reader walks into
    /// history. It is the one quantity the bar's position is built from.
    ///
    /// **One ruler**: the caller passes `documentBottom`, which is the same
    /// function `pinned`'s projection uses (`frames` first, the ruler for a
    /// row never drawn). There is no second height source here -- the whole
    /// day has been spent on what two of them cost.
    static func topPoints(documentBottom: Double, offset: Double) -> Double {
        max(0, documentBottom - offset)
    }

    /// How much of the viewport is over the document. A document shorter than
    /// the viewport covers all of it, which is what `min` says.
    static func viewportPoints(
        viewport: Double, documentBottom: Double, offset: Double
    ) -> Double {
        min(max(0, viewport), topPoints(documentBottom: documentBottom, offset: offset))
    }

    /// **The high-water mark, in points.** `top` is where the reader is now;
    /// `previous` is the deepest they have ever been. **Only ever grows** --
    /// reaching 100 keeps 100, and coming back to the newest does not shrink
    /// it.
    ///
    /// **No viewport term**, deliberately: at the very top of the document
    /// `top` already equals the whole document (`documentBottom - 0`), and
    /// the thumb's travel is `total - viewport`. Adding the viewport here
    /// would make the total one screen longer than the document.
    static func reached(previous: Double, top: Double) -> Double {
        max(previous, top)
    }

    /// **Whether a replaced map is still the same document** (review M, Q3).
    ///
    /// The high-water mark belongs to the **group**, not to the map: a locate
    /// -- or a drag to a place that was not loaded -- swaps the whole map
    /// inside one group, and zeroing on every `.replaced` threw the reader's
    /// depth away the moment they searched for something. A different group
    /// is a different document, and only that starts the mark again.
    static func keepsReached(mapGroup: String?, newGroup: String?) -> Bool {
        guard let mapGroup, let newGroup else { return false }
        return mapGroup == newGroup
    }

    /// **Points per drawn tick.** The track can show `trackH / tickSpacing`
    /// marks; past that one mark stands for a run of points and a drag moves
    /// in those steps. Row space said "N rows a step"; this says points, and
    /// the two are only equal while every row is the same height -- which is
    /// exactly what the old number assumed and the document does not.
    static func stepPoints(totalPoints: Double, trackH: CGFloat) -> Double {
        guard totalPoints > 0, trackH > 0 else { return 1 }
        let capacity = max(1, Double(Int(floor(trackH / tickSpacing))))
        guard totalPoints > capacity else { return 1 }
        return (totalPoints / capacity).rounded(.up)
    }

    static func thumbHeightPoints(
        totalPoints: Double,
        viewportPoints: Double,
        trackH: CGFloat
    ) -> CGFloat {
        guard trackH > 0 else { return 0 }
        guard totalPoints > 0 else { return trackH }
        let covered = min(totalPoints, max(0, viewportPoints))
        let ratio = CGFloat(covered / totalPoints)
        return min(trackH, max(minThumb, trackH * ratio))
    }

    /// Where the bar is, in point space.
    struct PointGeometry: Equatable {
        var trackH: CGFloat
        var thumbH: CGFloat
        var thumbY: CGFloat
        /// Points one drawn tick and one drag step stand for.
        var step: Double
    }

    /// **`depthPoints` is measured from the newest; the bar's travel from the
    /// oldest.** So the numerator is `totalPoints - depthPoints`, not
    /// `depthPoints`: at the newest edge the thumb must sit at the end of its
    /// travel, and at the deepest point reached it must sit at the start.
    static func geometryPoints(
        totalPoints: Double,
        viewportPoints: Double,
        depthPoints: Double,
        trackH: CGFloat
    ) -> PointGeometry {
        let thumbH = thumbHeightPoints(
            totalPoints: totalPoints, viewportPoints: viewportPoints, trackH: trackH)
        let travel = max(0, trackH - thumbH)
        let span = max(1, totalPoints - max(0, viewportPoints))
        let fromOldest = max(0, min(span, totalPoints - depthPoints))
        let fraction = min(1, max(0, fromOldest / span))
        return PointGeometry(
            trackH: trackH,
            thumbH: thumbH,
            thumbY: travel * CGFloat(fraction),
            step: stepPoints(totalPoints: totalPoints, trackH: trackH)
        )
    }

    /// **The depth a drag position asks for**: the fraction of the travel
    /// mapped back onto `[viewport, total]`, snapped to a drawn step. The
    /// result is a `topPoints` value -- the same space the projection reads.
    static func seekDepth(
        fraction: Double,
        totalPoints: Double,
        viewportPoints: Double,
        step: Double
    ) -> Double {
        let span = max(0, totalPoints - max(0, viewportPoints))
        let away = min(1, max(0, fraction)) * span
        let raw = totalPoints - away
        let size = max(1, step)
        let snapped = (raw / size).rounded() * size
        return min(totalPoints, max(viewportPoints, snapped))
    }

    /// Where the drawn ticks go, as fractions of the track, one per `step`
    /// points, the ends included.
    static func tickFractionsPoints(totalPoints: Double, step: Double) -> [Double] {
        guard totalPoints > 0 else { return [] }
        let size = max(1, step)
        let count = Int((totalPoints / size).rounded(.up))
        guard count > 1 else { return [0] }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }

    // MARK: - Dragging

    /// The part of the travel a finger at `y` asks for. The thumb is centred
    /// under the finger so a grab anywhere on it does not jump.
    static func dragFraction(y: CGFloat, thumbH: CGFloat, trackH: CGFloat) -> Double {
        let travel = max(0, trackH - thumbH)
        guard travel > 0 else { return 0 }
        let top = min(travel, max(0, y - thumbH / 2))
        return Double(top / travel)
    }


    /// A click on the bare track: which page it moves, `-1` up, `+1` down, and
    /// `0` when it landed on the thumb (that is a drag, not a page).
    static func page(forY y: CGFloat, thumbY: CGFloat, thumbH: CGFloat) -> Int {
        if y < thumbY { return -1 }
        if y > thumbY + thumbH { return 1 }
        return 0
    }


    /// The bubble's words: the row's number in the map, and its clock when the
    /// row has one. No message body, no author.
    /// **What the bubble says in point space**: the row's clock, and nothing
    /// else. A point is not a message, so there is no `#n` to show -- the
    /// caller hands in the nearest row's time (`time(atDepth:)`).
    static func bubbleText(time: String) -> String {
        time
    }
}

/// The bar itself. An overlay laid over the chat's trailing edge: it takes no
/// room from the list, never becomes first responder, and its hit area is the
/// track's width and nothing else.
struct ControlRoomChatIndexBarView: View {
    typealias Look = ControlRoomLook

    /// **The bar's total, in points** (design §23.3): the document's own
    /// depth today, the reader's high-water mark in the next step.
    var totalPoints: Double
    /// The viewport's top as points below the newest row's bottom
    /// (`topPoints`), not as a row tick -- the two are only equal while
    /// every row is the same height.
    var depthPoints: Double
    /// How much of the viewport is over the document (`viewportPoints`).
    var viewportPoints: Double
    var trackH: CGFloat
    var theme: Look.Theme
    /// **The map's identity.** When the window is replaced rather than
    /// extended, the rows are a different map: a drag in flight was aimed at
    /// the old one and is abandoned, and the thumb jumps to its new place
    /// with no animation.
    var mapEpoch: UInt64
    /// A page that could not be read, said quietly at the top of the track
    /// and in the bubble. Nil when there is nothing to say.
    var notice: String?
    /// The clock of the row nearest to a **depth** (points below the newest),
    /// or `""`.
    var time: (Double) -> String
    /// The row a drag asks for. Called on every step and once more on
    /// release -- **a correction, never a load**: picks are only ever made by
    /// the top and bottom edges.
    var onSeek: (Double) -> Void
    /// `-1` or `+1`: one page of the list, from a click on the bare track.
    var onPage: (Int) -> Void

    private enum Drag: Equatable {
        case thumb
        case page
    }

    @State private var drag: Drag?
    @State private var lastSeek: Double?
    @State private var bubbleDepth: Double?
    @State private var hovering = false

    /// A drag is in progress (or a window is being paged): the bubble is
    /// shown even after the pointer moves off the track.
    private var holding: Bool { drag != nil }

    /// The depth under the viewport's top edge, for the hover bubble.
    private var topDepth: Double {
        max(0, depthPoints)
    }

    /// What the bubble says, and `nil` when it should not be there at all.
    /// **A failure outranks the row's clock**: with no loading row, this is
    /// the only place the reader learns the edge could not be read.
    private var bubbleWords: String? {
        guard holding || hovering else { return nil }
        if drag == nil, let notice { return notice }
        guard let depth = bubbleDepth else { return notice }
        return ControlRoomChatIndexBar.bubbleText(time: time(depth))
    }

    private var geometry: ControlRoomChatIndexBar.PointGeometry {
        ControlRoomChatIndexBar.geometryPoints(
            totalPoints: totalPoints,
            viewportPoints: viewportPoints,
            depthPoints: depthPoints,
            trackH: trackH
        )
    }

    var body: some View {
        let shape = geometry
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: ControlRoomChatIndexBar.trackWidth / 2)
                .fill(theme.textSecondary.color.opacity(0.10))
                .frame(width: ControlRoomChatIndexBar.trackWidth, height: trackH)
            ticks(shape)
            if notice != nil {
                // **The top of the track says "there is more, and it could
                // not be read"**: the boundary row that used to say it is
                // gone, and this moves nothing.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.searchTargetEdge.color.opacity(0.8))
                    .frame(width: ControlRoomChatIndexBar.trackWidth, height: 3)
            }
            RoundedRectangle(cornerRadius: ControlRoomChatIndexBar.trackWidth / 2)
                .fill(theme.textSecondary.color.opacity(drag == nil ? 0.45 : 0.65))
                .frame(width: ControlRoomChatIndexBar.trackWidth, height: shape.thumbH)
                .offset(y: shape.thumbY)
        }
        .frame(width: ControlRoomChatIndexBar.trackWidth, height: trackH)
        .overlay(alignment: .trailing) {
            if let words = bubbleWords {
                bubble(words)
                    .fixedSize()
                    .offset(x: -(ControlRoomChatIndexBar.trackWidth + 8),
                            y: shape.thumbY + shape.thumbH / 2)
                    .allowsHitTesting(false)
            }
        }
        // **The track's width and nothing else**: a bar that took the space
        // beside it would swallow clicks meant for a message.
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                bubbleDepth = topDepth
            } else if drag == nil {
                bubbleDepth = nil
            }
        }
        // **A different map**: a drag aimed at the old one is abandoned, and
        // the thumb is already drawn at its new place (no animation).
        .onChange(of: mapEpoch) { _ in
            drag = nil
            lastSeek = nil
            bubbleDepth = holding ? topDepth : nil
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil {
                        let page = ControlRoomChatIndexBar.page(
                            forY: value.startLocation.y,
                            thumbY: shape.thumbY,
                            thumbH: shape.thumbH
                        )
                        if page == 0 {
                            drag = .thumb
                        } else {
                            drag = .page
                            onPage(page)
                        }
                    }
                    guard drag == .thumb else { return }
                    let fraction = ControlRoomChatIndexBar.dragFraction(
                        y: value.location.y, thumbH: shape.thumbH, trackH: trackH)
                    let depth = ControlRoomChatIndexBar.seekDepth(
                        fraction: fraction,
                        totalPoints: totalPoints,
                        viewportPoints: viewportPoints,
                        step: shape.step
                    )
                    bubbleDepth = depth
                    guard depth != lastSeek else { return }
                    lastSeek = depth
                    onSeek(depth)
                }
                .onEnded { _ in
                    // **A second look on release**, with the frames the drag's
                    // own scrolling measured: the seek is asked again so the
                    // list can correct where an unmeasured row landed.
                    if drag == .thumb, let depth = lastSeek { onSeek(depth) }
                    drag = nil
                    lastSeek = nil
                    if !hovering { bubbleDepth = nil }
                }
        )
    }

    @ViewBuilder
    private func ticks(_ shape: ControlRoomChatIndexBar.PointGeometry) -> some View {
        let fractions = ControlRoomChatIndexBar.tickFractionsPoints(
            totalPoints: totalPoints, step: shape.step)
        ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
            Rectangle()
                .fill(theme.textSecondary.color.opacity(0.22))
                .frame(width: ControlRoomChatIndexBar.trackWidth - 4, height: 0.5)
                .offset(y: CGFloat(fraction) * trackH)
        }
    }

    private func bubble(_ words: String) -> some View {
        Text(words)
            .font(.system(size: Look.Font.min))
            .monospacedDigit()
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.terminalBackground.color)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.textSecondary.color.opacity(0.25),
                            lineWidth: Look.Line.hairline)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}
