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
/// **Not wired into the page yet.** This is the block face on its own: the
/// chat feed, the container and the row that carries author and time are not
/// touched by this slice, so nothing here claims the chat page draws
/// Markdown -- only that a message's text, handed to this view, is drawn
/// this way.
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
struct ControlRoomChatMarkdownView: View {
    var document: ControlRoomChatMarkdown.Document

    private var bodyFont: Font { .system(size: ControlRoomLook.Font.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { entry in
                block(entry.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ block: ControlRoomChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(bodyFont)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(text)
                .font(.system(size: ControlRoomLook.Font.body, weight: headingWeight(level)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.kind == .ordered ? "\(item.ordinal)." : "•")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(item.text)
                    .font(bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(item.depth) * 12)

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: ControlRoomLook.Line.hairline * 4)
                Text(text)
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
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
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
            table(tableValue)
        }
    }

    /// A `Grid` so a column is a column: each cell is in the same column as
    /// the cells above and below it, and a header row is one row across, not
    /// a paragraph that happens to be first. The whole grid scrolls
    /// horizontally when it is wider than the message column; a cell wraps
    /// at 220 points so a long paragraph in a cell is readable rather than
    /// one very long line.
    private func table(_ table: ControlRoomChatMarkdown.Table) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !table.header.isEmpty {
                    GridRow {
                        ForEach(Array(0..<table.columns.count), id: \.self) { column in
                            cell(cell(table.header, column),
                                 alignment: table.columns[column], header: true)
                        }
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(Array(0..<table.columns.count), id: \.self) { column in
                            cell(cell(row.element, column),
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
