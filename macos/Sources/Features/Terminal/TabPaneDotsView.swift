import SwiftUI

/// The dots on a window tab (task 1699, `TabDots`): the supervisor's flag,
/// then a dot for every other pane of the tab given a colour, in columns of
/// two, then `+N` for those there was no room for. While a terminal of the
/// tab is lit (`terminal_highlight`, task 1689), an accent ring round them
/// breathes with the pane -- round the room of one dot when there are none.
/// Every number is the look table's (`TabDots`, `WindowTab`).
struct TabPaneDotsView: View {
    typealias Look = ControlRoomLook

    var drawn: TabDots.Drawn
    /// Whether a terminal of this tab is lit.
    var lit: Bool

    @ObservedObject private var highlight = PolterHighlightShown.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let d = Look.TabDots.self
        let glyph = CGFloat(Look.WindowTab.glyph)
        let pad = CGFloat(d.ringGap + d.ring)
        HStack(spacing: CGFloat(d.plusGap)) {
            HStack(spacing: CGFloat(d.flagGap)) {
                if let (flag, colour) = drawn.flag, let ink = colour.dot(theme) {
                    PaneSupervisorMark(lowered: flag == .lowered)
                        .fill(ink.color)
                        .frame(width: glyph, height: glyph)
                }
                if drawn.dots.isEmpty {
                    // Lit with no dots: the ring goes round an empty room.
                    if drawn.flag == nil, lit {
                        Color.clear.frame(width: CGFloat(d.dot), height: CGFloat(d.dot))
                    }
                } else {
                    dots(theme)
                }
            }
            // Room for the ring: above and below always, so the tab's
            // height never moves; at the sides only while lit, so an unlit
            // tab's dots are as wide as `TabDots.Drawn.width` says.
            .padding(.vertical, pad)
            .padding(.horizontal, lit ? pad : 0)
            .overlay {
                if lit {
                    PolterHighlightBreathing(since: highlight.breathingSince) { a in
                        Capsule(style: .continuous)
                            .inset(by: CGFloat(d.ring) / 2)
                            .stroke(Color.accentColor.opacity(a), lineWidth: CGFloat(d.ring))
                    }
                }
            }
            if drawn.plus > 0 {
                Text("+\(drawn.plus)")
                    .font(.system(size: CGFloat(Look.Font.min)))
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    /// Columns of two, top then bottom; one dot alone sits in the middle.
    private func dots(_ theme: Look.Theme) -> some View {
        let d = Look.TabDots.self
        let size = CGFloat(d.dot)
        let columns = stride(from: 0, to: drawn.dots.count, by: 2).map { Array(drawn.dots[$0..<min($0 + 2, drawn.dots.count)]) }
        return HStack(spacing: CGFloat(d.gap)) {
            ForEach(columns.indices, id: \.self) { c in
                VStack(spacing: CGFloat(d.gap)) {
                    ForEach(columns[c].indices, id: \.self) { r in
                        Circle()
                            .fill(columns[c][r].dot(theme)?.color ?? .clear)
                            .frame(width: size, height: size)
                    }
                }
                .frame(height: drawn.dots.count == 1 ? size : CGFloat(Look.WindowTab.glyph), alignment: .top)
            }
        }
        .frame(height: CGFloat(Look.WindowTab.glyph))
    }
}
