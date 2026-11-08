import AppKit
import SwiftUI

/// One group message's Markdown, drawn block by block (task 2799): paragraphs
/// and headings, list items, quotes, fenced code that scrolls inside its own
/// block, and a pipe table drawn as a real table -- header row, column
/// alignment and empty cells included.
///
/// **It draws a `Document` it was handed and parses nothing itself.** The
/// parse is `ControlRoomChatMarkdown.parse`, done once by whoever owns the
/// message and may keep it in that type's bounded `Cache`. Parsing in
/// `body` would run again on every layout pass, which section 9 of the
/// design is explicit about.
///
/// **Wired into the real page** (task 2800 C2b-1): each message row in
/// `ControlRoomNativeChatView` hands this view the document its feed's
/// `ControlRoomChatMarkdownStore` parsed, so the chat page draws tables,
/// lists, headings, quotes and code as themselves. The row keeps its author,
/// role and stable display id around this block face.
///
/// **Sizes come from `ControlRoomLook`.** Body text, list markers, code and
/// table cells are all `ControlRoomLook.Font.body`, the design's 13-point
/// floor; nothing here invents a smaller size. Colours are the system's
/// (`.primary`, `.secondary`, their low opacities) so this slice adds no
/// colour to the look tables.
///
/// **Wide things scroll inside themselves.** A code line and a wide table
/// scroll horizontally in their own block instead of widening the message
/// column, and no row is dropped: a long table is long, it is not clipped.
///
/// **...and the block must not take the group's wheel with it** (2026-11-09,
/// reported from a real group: the pointer over a fenced block stopped the
/// page scrolling entirely). A `ScrollView(.horizontal)` is an
/// `NSScrollView`, and an `NSScrollView` keeps every wheel event that lands
/// on it -- vertical ones included -- so the reader who put the pointer on a
/// code block could not scroll the history at all. The block's scroller is
/// therefore `ControlRoomChatBlockScroll` below, which hands a
/// predominantly vertical event to the enclosing (chat) scroll view.
struct ControlRoomChatMarkdownView: View {
    var document: ControlRoomChatMarkdown.Document
    /// A located search result's matches, as the page worked them out from
    /// the core's offsets. Nil for every row that is not the located one.
    var highlight: ControlRoomChatDisplayHighlight.Plan?
    /// A link in the body. The chat page decides whether it is a file
    /// reference (through the core) or an external URL (opened normally).
    var onLink: ((URL) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    private var bodyFont: Font { .system(size: ControlRoomLook.Font.body) }

    var body: some View {
        // **Computed once per draw, not per block**: the blocks' visible
        // texts are the same strings the drawing below reads, and the
        // match list is indexed by block and by cell.
        let marks = highlight.map {
            ControlRoomChatDisplayHighlight.matches(
                in: ControlRoomChatDisplayHighlight.blocksText(document), plan: $0)
        } ?? []
        let ink = ControlRoomLook.theme(scheme).searchHit.color
        let hitInk = ControlRoomLook.theme(scheme).searchHitText.color
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { entry in
                block(entry.element, index: entry.offset, marks: marks, ink: ink, hitInk: hitInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let onLink else { return .systemAction }
            onLink(url)
            return .handled
        })
    }

    @ViewBuilder
    private func block(
        _ block: ControlRoomChatMarkdown.Block,
        index: Int,
        marks: [ControlRoomChatDisplayHighlight.Match],
        ink: Color,
        hitInk: Color
    ) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.marked(text, block: index, text: 0, marks: marks, ink: ink, hitText: hitInk))
                .font(bodyFont)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(Self.marked(text, block: index, text: 0, marks: marks, ink: ink, hitText: hitInk))
                .font(.system(size: ControlRoomLook.Font.body, weight: headingWeight(level)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.kind == .ordered ? "\(item.ordinal)." : "•")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(Self.marked(item.text, block: index, text: 0, marks: marks, ink: ink, hitText: hitInk))
                    .font(bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(item.depth) * 12)

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: ControlRoomLook.Line.hairline * 4)
                Text(Self.marked(text, block: index, text: 0, marks: marks,
                                 ink: ink, hitText: hitInk))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language)
                        .font(bodyFont)
                        .foregroundStyle(.secondary)
                }
                ControlRoomChatBlockScroll {
                    Text(Self.marked(AttributedString(text), block: index, text: 0,
                                marks: marks, ink: ink, hitText: hitInk))
                        .font(.system(size: ControlRoomLook.Font.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: ControlRoomLook.Radius.row))

        case .table(let tableValue):
            table(tableValue, index: index, marks: marks, ink: ink, hitInk: hitInk)
        }
    }

    /// The block's text with the core's matches marked. **Cells count as
    /// text**: a table's cells are drawn separately, so a match in one is
    /// applied to that cell's own `AttributedString` and to no other.
    /// Character offsets are used because that is what the drawn text has in
    /// common with the string the mapper searched; the byte offsets stopped
    /// at `ControlRoomChatDisplayHighlight`.
    /// The block's text with the located hit's matches marked: the design's
    /// `search_hit` ground under the design's `search_hit_text` word.
    ///
    /// ⚠️ **The foreground is not decoration; without it SwiftUI draws no
    /// ground.** Measured on the real app, one message and one needle (task
    /// 2994, 2026-11-06):
    ///
    /// | run carries | yellow pixels |
    /// |---|---|
    /// | `backgroundColor` only | **0** |
    /// | `backgroundColor` + `foregroundColor = .red` | **784** |
    /// | `backgroundColor` + `foregroundColor = .primary` (same colour as the body) | **0** |
    ///
    /// So it is not enough to set *a* foreground: it has to be a **different**
    /// colour from the text around it. `searchHitText` is that colour --
    /// `#F2CC60` on `#23272D`, `#7A4B00` on light -- and it is the design's
    /// `--search-hl-fg`, the value Windows already draws the found word in.
    /// Mac had never consumed it until this line.
    static func marked(
        _ text: AttributedString,
        block: Int,
        text textIndex: Int,
        marks: [ControlRoomChatDisplayHighlight.Match],
        ink: Color,
        hitText: Color
    ) -> AttributedString {
        var out = text
        let plain = String(text.characters)
        for match in marks where match.block == block && match.text == textIndex {
            let lower = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: match.range.upperBound)
            guard let start = out.characters.index(
                    out.startIndex, offsetBy: lower, limitedBy: out.endIndex),
                  let end = out.characters.index(
                    out.startIndex, offsetBy: upper, limitedBy: out.endIndex),
                  start < end
            else { continue }
            out[start..<end].backgroundColor = ink
            out[start..<end].foregroundColor = hitText
        }
        return out
    }

    /// A `Grid` so a column is a column: each cell is in the same column as
    /// the cells above and below it, and a header row is one row across, not
    /// a paragraph that happens to be first. The whole grid scrolls
    /// horizontally when it is wider than the message column; a cell wraps
    /// at 220 points so a long paragraph in a cell is readable rather than
    /// one very long line.
    private func table(
        _ table: ControlRoomChatMarkdown.Table,
        index: Int,
        marks: [ControlRoomChatDisplayHighlight.Match],
        ink: Color,
        hitInk: Color
    ) -> some View {
        ControlRoomChatBlockScroll {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(Array(0..<table.columns.count), id: \.self) { column in
                            cell(Self.marked(cell(table.header, column),
                                        block: index, text: column,
                                        marks: marks, ink: ink, hitText: hitInk),
                                 alignment: table.columns[column], header: true)
                        }
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(Array(0..<table.columns.count), id: \.self) { column in
                            // The header's cells come first in the mapper's
                            // order, then the rows' -- one cell, one text.
                            let cellIndex = table.header.count
                                + row.offset * table.columns.count + column
                            cell(Self.marked(cell(row.element, column),
                                        block: index, text: cellIndex,
                                        marks: marks, ink: ink, hitText: hitInk),
                                 alignment: table.columns[column], header: false)
                        }
                    }
                }
            }
            .background(Color.secondary.opacity(0.04))
            .overlay(
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.15),
                                  lineWidth: ControlRoomLook.Line.hairline))
            // The block is hosted in an `NSHostingView` of its own, so the
            // page's `.textSelection(.enabled)` does not reach it.
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A cell's text, or an empty one when a hand-made `Table` is short of
    /// its column count; `parse` never produces that, this only keeps the
    /// view from indexing past the end.
    private func cell(_ row: [AttributedString], _ column: Int) -> AttributedString {
        column < row.count ? row[column] : AttributedString()
    }

    private func cell(_ text: AttributedString,
                      alignment: ControlRoomChatMarkdown.Alignment,
                      header: Bool) -> some View {
        Text(text)
            .font(.system(size: ControlRoomLook.Font.body,
                          weight: header ? .semibold : .regular))
            .multilineTextAlignment(textAlignment(alignment))
            .frame(minWidth: 44,
                   maxWidth: 220,
                   minHeight: ControlRoomLook.Font.body * ControlRoomLook.Font.lineHeightUi,
                   alignment: frameAlignment(alignment))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(header ? Color.secondary.opacity(0.10) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: ControlRoomLook.Line.hairline)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: ControlRoomLook.Line.hairline)
            }
    }

    /// A heading is layered inside the message, not made a page title: the
    /// size stays the body size and only the weight changes with the level.
    private func headingWeight(_ level: Int) -> Font.Weight {
        switch level {
        case 1, 2: return .semibold
        default: return .medium
        }
    }

    private func textAlignment(_ alignment: ControlRoomChatMarkdown.Alignment) -> TextAlignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(_ alignment: ControlRoomChatMarkdown.Alignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - A block's own scroller

/// **A wide block scrolls sideways inside itself, and nowhere else**
/// (2026-11-09, task 3078).
///
/// `ScrollView(.horizontal)` was the whole implementation, and it is an
/// `NSScrollView` -- which keeps every wheel event that lands on it, a
/// vertical one included. So a pointer resting on a fenced code block or a
/// pipe table took the page's scrolling away: the reader could not move the
/// group at all without first moving the mouse off the block.
///
/// The scroller is ours instead. The block's content is hosted in an
/// `NSHostingView`, the block's height is asked of that host (`sizeThatFits`)
/// rather than guessed, and a **predominantly vertical** wheel is handed to
/// `enclosingScrollView` -- the chat's own scroll view, which records and
/// scrolls it exactly as if the wheel had landed there, phases and momentum
/// untouched. A sideways wheel stays here.
private struct ControlRoomChatBlockScroll<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> ControlRoomChatBlockScrollView {
        let view = ControlRoomChatBlockScrollView()
        view.content = hosted
        return view
    }

    func updateNSView(_ view: ControlRoomChatBlockScrollView, context: Context) {
        view.content = hosted
    }

    /// **Left-aligned even when the block is wider than its text.** The host
    /// is as wide as the widest of the content and the clip; a `Text` with
    /// `fixedSize(horizontal:)` is narrower than that whenever the block does
    /// not need to scroll, and SwiftUI's default placement inside the host is
    /// the centre -- which put short code blocks in the middle of their box
    /// (seen on the real app 2026-11-09, the `struct Place` block).
    private var hosted: AnyView {
        AnyView(content.frame(maxWidth: .infinity, alignment: .leading))
    }

    /// **The width is the column's; the height is the content's.** Nothing
    /// here scrolls vertically, so a taller-than-content block would mean an
    /// empty band and a shorter one would clip a table row.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: ControlRoomChatBlockScrollView,
        context: Context
    ) -> CGSize? {
        let natural = view.naturalSize
        let height = natural.height > 0 ? natural.height : (proposal.height ?? 0)
        return CGSize(width: proposal.width ?? natural.width, height: height)
    }
}

/// The block's horizontal scroller: **vertical goes out, sideways stays in.**
final class ControlRoomChatBlockScrollView: NSScrollView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    /// What the content needs at its own width. Its height is the block's
    /// height: this scroll view never moves vertically, by design.
    var naturalSize: CGSize {
        var fit = host.fittingSize
        // The first question can arrive before the host has laid its content
        // out (SwiftUI asks for a size the moment the representable is made),
        // and an empty answer here would be a zero-height block.
        if fit.height <= 0 {
            host.layoutSubtreeIfNeeded()
            fit = host.fittingSize
        }
        return CGSize(width: max(1, fit.width), height: max(0, fit.height))
    }

    var content: AnyView {
        get { host.rootView }
        set {
            host.rootView = newValue
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        borderType = .noBorder
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        documentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ControlRoomChatBlockScrollView is made in code")
    }

    override func layout() {
        super.layout()
        let natural = naturalSize
        let size = NSSize(width: max(natural.width, contentView.bounds.width),
                          height: natural.height)
        if host.frame.origin != .zero || host.frame.size != size {
            host.frame = NSRect(origin: .zero, size: size)
        }
    }

    /// **A predominantly vertical wheel is the page's, not the block's.**
    /// `enclosingScrollView` walks up to the chat's scroll view; when there
    /// is none (a block shown outside the page) the event stays here, which
    /// is what it did before this existed.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}
