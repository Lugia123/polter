import SwiftUI

/// The chat's own index bar (task 3081, design §29.7): **the one place a list
/// with no length says how much it holds**.
///
/// The bar's position and arithmetic are lines now: **line 1 is the newest,
/// `total` is the loaded line count, and `fill` is how many lines one screen
/// covers**. The thumb is the share `fill / total`; a drag maps onto
/// `[1, total - fill + 1]`. That arithmetic lives in
/// `ControlRoomChatLineBar`; this file keeps the look constants and the two
/// pure gestures the bar's view needs.
///
/// ⚠️ **This bar covers the loaded map and nothing else.** It never points at
/// a line that is not in the plan, so a drag cannot ask the list to scroll
/// past the loaded content. Reaching further back for a specific message is
/// `jumpToAnchor`'s (the feed's `around` window), not a scroll.
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

    /// **The line at the viewport's bottom edge**, `1` = the newest (design
    /// §29.7). The bar's one position.
    var b: Int
    /// The loaded line count: every plan row, boundary marks included.
    var totalLines: Int
    /// How many lines fill one viewport: the thumb's length and the clamp.
    var fillLines: Int
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
    /// The clock of the message a **line** is in, or `""`.
    var time: (Int) -> String
    /// The line a drag asks for. Called on every step and once more on
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
    @State private var bubbleLine: Int?
    @State private var hovering = false

    /// A drag is in progress (or a window is being paged): the bubble is
    /// shown even after the pointer moves off the track.
    private var holding: Bool { drag != nil }

    /// The line the hover bubble describes: the bar's own position.
    private var bubbleAnchorLine: Int {
        max(1, b)
    }

    /// What the bubble says, and `nil` when it should not be there at all.
    /// **A failure outranks the row's clock**: with no loading row, this is
    /// the only place the reader learns the edge could not be read.
    private var bubbleWords: String? {
        guard holding || hovering else { return nil }
        if drag == nil, let notice { return notice }
        guard let line = bubbleLine else { return notice }
        return ControlRoomChatIndexBar.bubbleText(time: time(line))
    }

    private var geometry: ControlRoomChatLineBar.Geometry {
        ControlRoomChatLineBar.geometry(
            b: b,
            totalLines: totalLines,
            fillLines: fillLines,
            trackH: trackH,
            minThumb: ControlRoomChatIndexBar.minThumb,
            tickSpacing: ControlRoomChatIndexBar.tickSpacing
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
                bubbleLine = bubbleAnchorLine
            } else if drag == nil {
                bubbleLine = nil
            }
        }
        // **A different map**: a drag aimed at the old one is abandoned, and
        // the thumb is already drawn at its new place (no animation).
        .onChange(of: mapEpoch) { _ in
            drag = nil
            lastSeek = nil
            bubbleLine = holding ? bubbleAnchorLine : nil
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
                    let line = ControlRoomChatLineBar.seekLine(
                        fraction: fraction,
                        totalLines: totalLines,
                        fillLines: fillLines,
                        stepLines: shape.stepLines
                    )
                    bubbleLine = line
                    guard line != lastSeek else { return }
                    lastSeek = line
                    onSeek(line)
                }
                .onEnded { _ in
                    // **A second look on release**, with the frames the drag's
                    // own scrolling measured: the seek is asked again so the
                    // list can correct where an unmeasured row landed.
                    if drag == .thumb, let line = lastSeek { onSeek(line) }
                    drag = nil
                    lastSeek = nil
                    if !hovering { bubbleLine = nil }
                }
        )
    }

    @ViewBuilder
    private func ticks(_ shape: ControlRoomChatLineBar.Geometry) -> some View {
        let fractions = ControlRoomChatLineBar.tickFractions(
            totalLines: totalLines, fillLines: fillLines, stepLines: shape.stepLines)
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
