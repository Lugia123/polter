import Foundation

/// A group message's text as the blocks it is drawn in (task 2799):
/// Foundation's own Markdown parser (`AttributedString(markdown:)`) grouped
/// by the `presentationIntent` it carries, so a paragraph, a heading, a list
/// item, a quote, a fenced code block and a pipe table are things the view
/// can draw as themselves instead of one `Text`.
///
/// **The parse is Foundation's, not this file's.** This type only groups and
/// copies runs, so a table here is a table because `presentationIntent` said
/// `tableHeaderRow` / `tableRow` / `tableCell` -- not because some `|`
/// characters were counted. Column alignment comes from
/// `.table(columns:)`, which the parser fills from the separator row.
///
/// **What is proved and what is not.** `PresentationIntent`, tables and
/// `TableColumn.Alignment` are all `@available(macOS 12, ...)`; this app's
/// floor is macOS 13, so the API is there at compile time. The probe behind
/// the shape was run on a newer system. That a macOS 13 *runtime* parses GFM
/// tables is not proved by it and is not claimed here.
///
/// **Nothing here touches a terminal, the core or the network.** Text that
/// is not Markdown comes out as paragraphs; source the parser refuses comes
/// out as one plain paragraph, so no message disappears. HTML stays text and
/// an image stays its alt text: the only run attributes copied are the
/// inline emphasis and the link, never anything that would fetch or run.
///
/// **Bounded by the caller.** `parse` is stateless and parses one message;
/// `Cache` is the bounded store a later feed may keep parsed messages in.
/// Neither one keeps a group's whole log.
enum ControlRoomChatMarkdown {
    /// How a column's cells sit, as the parser read the separator row.
    enum Alignment: Equatable {
        case left
        case center
        case right
    }

    /// The two list kinds.
    enum ListKind: Equatable {
        case unordered
        case ordered
    }

    /// One item of a list. `ordinal` is the number the parser gave it (1 for
    /// the first item of either kind); `depth` is 0 at the outermost level.
    struct ListItem: Equatable {
        var kind: ListKind
        var ordinal: Int
        var depth: Int
        var text: AttributedString
    }

    /// A pipe table. `header` has one entry per column, and every row in
    /// `rows` is padded to the same count: a row written `| a || c |` still
    /// has three cells, because the parser emits no run for the empty one.
    struct Table: Equatable {
        var columns: [Alignment]
        var header: [AttributedString]
        var rows: [[AttributedString]]
    }

    enum Block: Equatable {
        /// A paragraph, including a line that only wraps.
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case listItem(ListItem)
        case blockQuote(AttributedString)
        /// A fenced code block. `text` keeps its own newlines; `language` is
        /// the word after the opening fence, or nil when there was none.
        case code(language: String?, text: String)
        case table(Table)
    }

    struct Document: Equatable {
        var blocks: [Block]
        /// True when the parser refused the source and it is drawn as one
        /// plain paragraph instead.
        var usedPlainFallback: Bool
    }

    /// Parse one message. Pure: no cache, no shared state, no I/O.
    static func parse(_ source: String) -> Document {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let attributed: AttributedString
        do {
            attributed = try AttributedString(markdown: source, options: options)
        } catch {
            return plain(source)
        }
        let blocks = blocks(in: attributed)
        // Visible characters that produced no block at all are still shown,
        // and said to be the fallback rather than passed off as Markdown.
        if blocks.isEmpty, !source.isEmpty {
            return plain(source)
        }
        return Document(blocks: blocks, usedPlainFallback: false)
    }

    private static func plain(_ source: String) -> Document {
        Document(
            blocks: source.isEmpty ? [] : [.paragraph(AttributedString(source))],
            usedPlainFallback: !source.isEmpty)
    }

    // MARK: - Grouping the parser's runs

    private typealias Component = PresentationIntent.IntentType

    /// The `presentationIntent` of one run, read once. The components come
    /// innermost first, which is what makes the first match the right one.
    private struct Shape {
        var table: Component?
        var columns: [PresentationIntent.TableColumn] = []
        var row: Component?
        var rowIndex: Int?
        var isHeaderRow = false
        var cell: Component?
        var cellIndex: Int?
        var code: Component?
        var language: String?
        var heading: Component?
        var level: Int?
        var paragraph: Component?
        var quote: Component?
        var list: Component?
        var listItem: Component?
        var isOrdered = false
        var ordinal = 0
        var indentationLevel = 0

        init(_ intent: PresentationIntent?) {
            guard let intent else { return }
            indentationLevel = intent.indentationLevel
            for component in intent.components {
                switch component.kind {
                case .table(let columns):
                    if table == nil {
                        table = component
                        self.columns = columns
                    }
                case .tableHeaderRow:
                    if row == nil {
                        row = component
                        isHeaderRow = true
                    }
                case .tableRow(let index):
                    if row == nil {
                        row = component
                        rowIndex = index
                    }
                case .tableCell(let column):
                    if cell == nil {
                        cell = component
                        cellIndex = column
                    }
                case .codeBlock(let hint):
                    if code == nil {
                        code = component
                        if let hint, !hint.isEmpty { language = hint }
                    }
                case .header(let level):
                    if heading == nil {
                        heading = component
                        self.level = level
                    }
                case .paragraph:
                    if paragraph == nil { paragraph = component }
                case .blockQuote:
                    if quote == nil { quote = component }
                case .orderedList:
                    if list == nil {
                        list = component
                        isOrdered = true
                    }
                case .unorderedList:
                    if list == nil { list = component }
                case .listItem(let ordinal):
                    if listItem == nil {
                        listItem = component
                        self.ordinal = ordinal
                    }
                case .thematicBreak:
                    break
                }
            }
        }
    }

    private enum OpenKind: Equatable {
        case paragraph
        case heading(level: Int)
        case listItem(kind: ListKind, ordinal: Int, depth: Int)
        case blockQuote
    }

    /// The paragraph-like block a run belongs to, and the identity it is
    /// grouped by. A list item is grouped by the item, so a loose item's two
    /// paragraphs stay one item.
    private static func openKind(_ shape: Shape) -> (OpenKind, Int)? {
        if let item = shape.listItem {
            let kind: ListKind = shape.isOrdered ? .ordered : .unordered
            return (.listItem(kind: kind, ordinal: shape.ordinal, depth: shape.indentationLevel),
                    item.identity)
        }
        if let heading = shape.heading {
            return (.heading(level: shape.level ?? 1), heading.identity)
        }
        if shape.quote != nil, let paragraph = shape.paragraph {
            return (.blockQuote, paragraph.identity)
        }
        if let paragraph = shape.paragraph {
            return (.paragraph, paragraph.identity)
        }
        return nil
    }

    private struct OpenParagraph {
        var key: Int
        var kind: OpenKind
        var paragraphKey: Int
        var text: AttributedString
    }

    private static func block(_ open: OpenParagraph) -> Block {
        switch open.kind {
        case .paragraph:
            return .paragraph(open.text)
        case .heading(let level):
            return .heading(level: level, text: open.text)
        case .listItem(let kind, let ordinal, let depth):
            return .listItem(ListItem(kind: kind, ordinal: ordinal, depth: depth, text: open.text))
        case .blockQuote:
            return .blockQuote(open.text)
        }
    }

    private static func blocks(in attributed: AttributedString) -> [Block] {
        // A key the parser cannot have used, for a run with no block
        // container: its text is kept as a paragraph rather than dropped.
        let noContainer = Int.min

        var blocks: [Block] = []
        var open: OpenParagraph?
        var code: (key: Int, language: String?, text: String)?
        var table: TableBuilder?

        func flushCode() {
            if let code {
                blocks.append(.code(language: code.language, text: code.text))
            }
            code = nil
        }
        func flushParagraph() {
            if let open { blocks.append(Self.block(open)) }
            open = nil
        }
        func flushTable() {
            if var table {
                blocks.append(.table(table.build()))
            }
            table = nil
        }

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let shape = Shape(run.presentationIntent)
            let piece = inline(from: run, text: text)

            if let tableComponent = shape.table {
                flushParagraph()
                flushCode()
                if table?.identity != tableComponent.identity {
                    flushTable()
                    table = TableBuilder(
                        identity: tableComponent.identity,
                        columns: shape.columns.map { alignment($0.alignment) })
                }
                if let row = shape.row, let column = shape.cellIndex {
                    table?.add(text: piece, row: row.identity,
                               isHeader: shape.isHeaderRow, column: column)
                }
                continue
            }

            if let codeComponent = shape.code {
                flushTable()
                flushParagraph()
                if var current = code, current.key == codeComponent.identity {
                    current.text += text
                    code = current
                } else {
                    flushCode()
                    code = (codeComponent.identity, shape.language, text)
                }
                continue
            }

            if let (kind, key) = openKind(shape) {
                flushTable()
                flushCode()
                let paragraphKey = shape.paragraph?.identity ?? key
                if var current = open, current.key == key {
                    // A loose list item: the next paragraph of the same item
                    // starts on a new line rather than running on.
                    if current.paragraphKey != paragraphKey {
                        current.text.append(AttributedString("\n"))
                        current.paragraphKey = paragraphKey
                    }
                    current.text.append(piece)
                    open = current
                } else {
                    flushParagraph()
                    open = OpenParagraph(
                        key: key, kind: kind, paragraphKey: paragraphKey, text: piece)
                }
                continue
            }

            flushTable()
            flushCode()
            if var current = open, case .paragraph = current.kind, current.key == noContainer {
                current.text.append(piece)
                open = current
            } else {
                flushParagraph()
                open = OpenParagraph(
                    key: noContainer, kind: .paragraph,
                    paragraphKey: noContainer, text: piece)
            }
        }

        flushTable()
        flushCode()
        flushParagraph()
        return blocks
    }

    /// The text of one run with only what a `Text` may draw: emphasis, code,
    /// a link. `presentationIntent` (the block path) and `imageURL` (a
    /// reference that would fetch) are not copied.
    private static func inline(from run: AttributedString.Runs.Run, text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlinePresentationIntent = run.inlinePresentationIntent
        piece.link = run.link
        return piece
    }

    private static func alignment(_ column: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch column {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        @unknown default: return .left
        }
    }

    /// A table's rows as they arrive. Rows are told apart by identity, and
    /// each one is padded to the table's column count when it closes, so an
    /// empty cell is a cell and not a missing column.
    private struct TableBuilder {
        var identity: Int
        var columns: [Alignment]
        var header: [AttributedString]?
        var rows: [[AttributedString]] = []
        private var openRowKey: Int?
        private var openIsHeader = false
        private var openRow: [AttributedString] = []

        mutating func add(text: AttributedString, row key: Int, isHeader: Bool, column: Int) {
            if openRowKey != key {
                closeRow()
                openRowKey = key
                openIsHeader = isHeader
                openRow = []
            }
            while openRow.count <= column {
                openRow.append(AttributedString())
            }
            openRow[column].append(text)
        }

        mutating func build() -> Table {
            closeRow()
            let empty = AttributedString()
            let header = self.header ?? columns.map { _ in empty }
            return Table(columns: columns, header: header, rows: rows)
        }

        private mutating func closeRow() {
            guard openRowKey != nil else { return }
            var row = openRow
            while row.count < columns.count {
                row.append(AttributedString())
            }
            if openIsHeader, header == nil {
                header = row
            } else {
                rows.append(row)
            }
            openRow = []
            openRowKey = nil
            openIsHeader = false
        }
    }

    // MARK: - A bounded store

    /// Parsed messages kept for the rows on screen, bounded twice -- by
    /// count and by the source bytes they stand for -- and forgetting the
    /// least recently used first. It never holds a whole log: the caller
    /// says which messages are wanted and this keeps no more than the
    /// budgets below. The two budgets are design targets to be measured
    /// (task 2793, section 9), not limits on what the disk keeps.
    struct Cache {
        /// Which message, and which version of its text.
        ///
        /// **The message is not a `seq`.** A group's `seq` restarts with the
        /// core, a persisted message is read by `log_seq` while a live one
        /// may have none yet, and two groups both have a `seq` of 1. So the
        /// identity is `group` plus `anchor`: `anchor` is opaque here, the
        /// core supplies one string for a persisted message, another for a
        /// live one and another for a legacy position, and this type neither
        /// parses it nor makes one out of the text. `version` moves when the
        /// same message is rewritten.
        struct Key: Hashable {
            var group: String
            var anchor: String
            /// The message's own `contentVersion`, which is a `UInt64` on the
            /// wire. Kept at its full width: narrowing, `bitPattern` mapping
            /// or 0-for-failure would make two versions one key.
            var version: UInt64
        }

        private struct Entry {
            var document: Document
            var bytes: Int
        }

        let maxEntries: Int
        let maxBytes: Int
        private var entries: [Key: Entry] = [:]
        private var order: [Key] = []
        /// Keys the feed is actually using now. **A pinned entry is never
        /// the one a background parse evicts**; it leaves the cache only when
        /// its demand is released, and then only as an ordinary LRU entry
        /// when the budget needs the room.
        private var pinned: Set<Key> = []
        private(set) var residentBytes = 0

        var count: Int { entries.count }

        init(maxEntries: Int = 200, maxBytes: Int = 4 * 1024 * 1024) {
            self.maxEntries = max(0, maxEntries)
            self.maxBytes = max(0, maxBytes)
        }

        func contains(_ key: Key) -> Bool {
            entries[key] != nil
        }

        /// The parsed message, from the store or parsed now. A document too
        /// large for the whole budget is returned but not kept.
        mutating func document(for key: Key, text: String) -> Document {
            if let entry = entries[key] {
                touch(key)
                return entry.document
            }
            let document = ControlRoomChatMarkdown.parse(text)
            keep(document, text: text, for: key)
            return document
        }

        /// What is kept for `key`, or nil. **Reads only**: no parse, no LRU
        /// move -- a view asks this from `body`, and reading is not using.
        func document(_ key: Key) -> Document? {
            entries[key]?.document
        }

        /// Pin every key the feed is using, and unpin the rest. The set may
        /// name a key whose document is not parsed yet: it is pinned when it
        /// arrives, so a completion from another row cannot evict it first.
        mutating func setPinned(_ keys: Set<Key>) {
            pinned = keys
        }

        mutating func pin(_ key: Key) {
            pinned.insert(key)
        }

        mutating func unpin(_ key: Key) {
            pinned.remove(key)
        }

        func isPinned(_ key: Key) -> Bool {
            pinned.contains(key)
        }

        /// Keep `document` for `key`, charged the source's UTF-8 bytes.
        /// False when the source alone is over the byte budget, or when the
        /// cache is full of pinned entries and has no room for this one: the
        /// caller may show it from its own row, but this store did not keep
        /// it.
        @discardableResult
        mutating func keep(
            _ document: Document,
            text: String,
            for key: Key,
            pinned isPinned: Bool = false
        ) -> Bool {
            let bytes = text.utf8.count
            guard maxEntries > 0, maxBytes > 0, bytes <= maxBytes else { return false }
            if let existing = entries.removeValue(forKey: key) {
                residentBytes -= existing.bytes
                order.removeAll { $0 == key }
                pinned.remove(key)
            }
            entries[key] = Entry(document: document, bytes: bytes)
            order.append(key)
            residentBytes += bytes
            if isPinned { pinned.insert(key) }
            evictNonPinned()

            // Full of pinned entries: **do not evict one of them**. The new
            // entry is the one that did not fit.
            if entries.count > maxEntries || residentBytes > maxBytes {
                if let dropped = entries.removeValue(forKey: key) {
                    residentBytes -= dropped.bytes
                    order.removeAll { $0 == key }
                    pinned.remove(key)
                }
                return false
            }
            return true
        }

        mutating func removeAll() {
            entries.removeAll()
            order.removeAll()
            residentBytes = 0
        }

        private mutating func touch(_ key: Key) {
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            order.append(key)
        }

        /// Make room by forgetting the least recently used **unpinned**
        /// entry. When everything left is pinned, stop: being over budget is
        /// the caller's answer to give, not a reason to drop a row that is
        /// on screen.
        private mutating func evictNonPinned() {
            while entries.count > maxEntries || residentBytes > maxBytes {
                guard let index = order.firstIndex(where: { !pinned.contains($0) }) else { break }
                let key = order.remove(at: index)
                if let removed = entries.removeValue(forKey: key) {
                    residentBytes -= removed.bytes
                }
                pinned.remove(key)
            }
        }
    }
}
