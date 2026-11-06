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
    /// **A thumb shorter than this is not grabbable**, whatever the ratio
    /// says. Below it the bar stops being draggable by hand and a night's
    /// worth of messages could not be navigated.
    static let minThumb: CGFloat = 36
    /// The drawn track's width, and the whole of its hit area: the bar must
    /// not take clicks meant for the list beside it.
    static let trackWidth: CGFloat = 10
    /// Between the track and the window's edge.
    static let trackInset: CGFloat = 6
    /// The least height between two drawn ticks.
    static let tickSpacing: CGFloat = 5

    /// Where the bar is, for one map and one camera.
    struct Geometry: Equatable {
        var trackH: CGFloat
        var thumbH: CGFloat
        var thumbY: CGFloat
        /// How many loaded rows one drawn tick and one drag step stand for.
        var step: Int
    }

    // MARK: - The camera in tick space

    /// The viewport's top edge as a continuous tick position: the index of
    /// the row under it plus how far into that row the reader has gone.
    /// `nil` when no row has been measured, which is "not known yet", not
    /// "at the top".
    static func topTick(
        order: [String],
        frames: [String: CGRect],
        offset: Double,
        viewport: Double
    ) -> Double? {
        guard viewport > 0 else { return nil }
        for (index, id) in order.enumerated() {
            guard let frame = frames[id], frame.maxY > offset + 0.5 else { continue }
            let into = frame.height > 0 ? (offset - frame.minY) / frame.height : 0
            return Double(index) + min(1, max(0, into))
        }
        return nil
    }

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

    /// How many loaded rows share one drawn tick. The track can only show
    /// `trackH / tickSpacing` marks; past that a mark stands for a run of
    /// rows and a drag moves in those steps.
    ///
    /// **Computed once, in `geometry()`**: the drawn ticks and a drag's
    /// snapping both read `Geometry.step`, so a tick can never stand for a
    /// different number of rows than a drag moves.
    static func step(totalTicks: Int, trackH: CGFloat) -> Int {
        guard totalTicks > 0, trackH > 0 else { return 1 }
        let capacity = max(1, Int(floor(trackH / tickSpacing)))
        guard totalTicks > capacity else { return 1 }
        return Int((Double(totalTicks) / Double(capacity)).rounded(.up))
    }

    /// The thumb's height: the viewport's share of the loaded map, held to
    /// `minThumb` and never taller than the track.
    static func thumbHeight(
        totalTicks: Int,
        viewportTicks: Double,
        trackH: CGFloat
    ) -> CGFloat {
        guard trackH > 0 else { return 0 }
        guard totalTicks > 0 else { return trackH }
        let covered = min(Double(totalTicks), max(0, viewportTicks))
        let ratio = CGFloat(covered / Double(totalTicks))
        return min(trackH, max(minThumb, trackH * ratio))
    }

    /// **Continuous, never snapped to a whole row**: the thumb's top is a
    /// position in the space of "viewport tops", from the first row's top to
    /// the last position at which the viewport is still full. At the very
    /// bottom the thumb sits at the end of its travel, which is what makes
    /// "at the bottom" look like the bottom.
    static func geometry(
        totalTicks: Int,
        viewportTicks: Double,
        topTick: Double,
        trackH: CGFloat
    ) -> Geometry {
        let thumbH = thumbHeight(
            totalTicks: totalTicks, viewportTicks: viewportTicks, trackH: trackH)
        let travel = max(0, trackH - thumbH)
        let span = max(1, Double(totalTicks) - max(0, viewportTicks))
        let fraction = min(1, max(0, topTick / span))
        return Geometry(
            trackH: trackH,
            thumbH: thumbH,
            thumbY: travel * CGFloat(fraction),
            step: step(totalTicks: totalTicks, trackH: trackH)
        )
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

    /// The row a drag position asks for: the fraction of the travel mapped
    /// to the map's rows, then rounded to a drawn step. `totalTicks - 1` is
    /// the last row's own index, so the end of the travel is the newest
    /// message and not a row past it.
    static func seekIndex(fraction: Double, totalTicks: Int, step: Int) -> Int {
        guard totalTicks > 0 else { return 0 }
        let last = totalTicks - 1
        let raw = Int((min(1, max(0, fraction)) * Double(last)).rounded())
        // The caller passes `Geometry.step`; the guard is only against a
        // hand-written zero, which would otherwise divide.
        let size = max(1, step)
        guard size > 1 else { return raw }
        let snapped = Int((Double(raw) / Double(size)).rounded()) * size
        return min(last, max(0, snapped))
    }

    /// A click on the bare track: which page it moves, `-1` up, `+1` down, and
    /// `0` when it landed on the thumb (that is a drag, not a page).
    static func page(forY y: CGFloat, thumbY: CGFloat, thumbH: CGFloat) -> Int {
        if y < thumbY { return -1 }
        if y > thumbY + thumbH { return 1 }
        return 0
    }

    /// Where the drawn ticks go, as fractions of the track: evenly spread, one
    /// per `step` rows, the ends included so the map's edges can be read.
    static func tickFractions(totalTicks: Int, step: Int) -> [Double] {
        guard totalTicks > 0 else { return [] }
        let size = max(1, step)
        let count = Int((Double(totalTicks) / Double(size)).rounded(.up))
        guard count > 1 else { return [0] }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }

    /// The bubble's words: the row's number in the map, and its clock when the
    /// row has one. No message body, no author.
    static func bubbleText(index: Int, time: String) -> String {
        let number = "#\(index + 1)"
        return time.isEmpty ? number : "\(number)  \(time)"
    }
}

/// The bar itself. An overlay laid over the chat's trailing edge: it takes no
/// room from the list, never becomes first responder, and its hit area is the
/// track's width and nothing else.
struct ControlRoomChatIndexBarView: View {
    typealias Look = ControlRoomLook

    var totalTicks: Int
    /// The viewport's top as a continuous tick position (see `topTick`).
    var topTick: Double
    /// How many rows the viewport covers (`viewportTicks`).
    var viewportTicks: Double
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
    /// The clock of the row at an index, or `""`.
    var time: (Int) -> String
    /// The row a drag asks for. Called on every step and once more on
    /// release -- **a correction, never a load**: picks are only ever made by
    /// the top and bottom edges.
    var onSeek: (Int) -> Void
    /// `-1` or `+1`: one page of the list, from a click on the bare track.
    var onPage: (Int) -> Void

    private enum Drag: Equatable {
        case thumb
        case page
    }

    @State private var drag: Drag?
    @State private var lastSeek: Int?
    @State private var bubbleIndex: Int?
    @State private var hovering = false

    /// A drag is in progress (or a window is being paged): the bubble is
    /// shown even after the pointer moves off the track.
    private var holding: Bool { drag != nil }

    /// The row under the viewport's top edge, for the hover bubble.
    private var topRow: Int {
        guard totalTicks > 0 else { return 0 }
        return min(totalTicks - 1, max(0, Int(topTick.rounded())))
    }

    /// What the bubble says, and `nil` when it should not be there at all.
    /// **A failure outranks the row's clock**: with no loading row, this is
    /// the only place the reader learns the edge could not be read.
    private var bubbleWords: String? {
        guard holding || hovering else { return nil }
        if drag == nil, let notice { return notice }
        guard let index = bubbleIndex else { return notice }
        return ControlRoomChatIndexBar.bubbleText(index: index, time: time(index))
    }

    private var geometry: ControlRoomChatIndexBar.Geometry {
        ControlRoomChatIndexBar.geometry(
            totalTicks: totalTicks,
            viewportTicks: viewportTicks,
            topTick: topTick,
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
                bubbleIndex = topRow
            } else if drag == nil {
                bubbleIndex = nil
            }
        }
        // **A different map**: a drag aimed at the old one is abandoned, and
        // the thumb is already drawn at its new place (no animation).
        .onChange(of: mapEpoch) { _ in
            drag = nil
            lastSeek = nil
            bubbleIndex = holding ? topRow : nil
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
                    let index = ControlRoomChatIndexBar.seekIndex(
                        fraction: fraction, totalTicks: totalTicks, step: shape.step)
                    bubbleIndex = index
                    guard index != lastSeek else { return }
                    lastSeek = index
                    onSeek(index)
                }
                .onEnded { _ in
                    // **A second look on release**, with the frames the drag's
                    // own scrolling measured: the seek is asked again so the
                    // list can correct where an unmeasured row landed.
                    if drag == .thumb, let index = lastSeek { onSeek(index) }
                    drag = nil
                    lastSeek = nil
                    if !hovering { bubbleIndex = nil }
                }
        )
    }

    @ViewBuilder
    private func ticks(_ shape: ControlRoomChatIndexBar.Geometry) -> some View {
        let fractions = ControlRoomChatIndexBar.tickFractions(
            totalTicks: totalTicks, step: shape.step)
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
