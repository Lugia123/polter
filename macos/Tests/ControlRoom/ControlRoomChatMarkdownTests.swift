import Foundation
import Testing
@testable import Ghostty

struct ChatMarkdownTests {
    typealias Markdown = ControlRoomChatMarkdown
    typealias Block = ControlRoomChatMarkdown.Block

    // MARK: - Tables

    @Test func testATableKeepsItsHeaderAlignmentEmptyCellsAndEscapedPipes() {
        let source = """
        | 名字 | 值 | 备注 |
        |:---|---:|:---:|
        | 中文 | 1 | |
        | a\\|b | `x\\|y` | 末尾 |
        """
        let document = Markdown.parse(source)
        #expect(document.blocks.count == 1)
        guard let first = document.blocks.first, case .table(let table) = first else {
            Issue.record("the only block is not a table: \(document.blocks)")
            return
        }
        #expect(table.columns == [.left, .right, .center])
        #expect(table.header.map { String($0.characters) } == ["名字", "值", "备注"])
        #expect(table.rows.count == 2)
        // A row written with an empty cell keeps that cell: three columns,
        // the third one empty, not two cells and a missing column.
        #expect(table.rows[0].map { String($0.characters) } == ["中文", "1", ""])
        // An escaped pipe is text in its cell; it does not split the row.
        #expect(String(table.rows[1][0].characters) == "a|b")
        // The same inside inline code: GFM's escape wins over the pipe.
        #expect(String(table.rows[1][1].characters) == "x|y")
        #expect(String(table.rows[1][2].characters) == "末尾")
    }

    @Test func testATableRowShorterThanItsHeaderIsPaddedWithEmptyCells() {
        let source = """
        | a | b | c |
        |---|---|---|
        | 1 |
        """
        let document = Markdown.parse(source)
        guard let first = document.blocks.first, case .table(let table) = first else {
            Issue.record("the only block is not a table: \(document.blocks)")
            return
        }
        #expect(table.rows.count == 1)
        #expect(table.rows[0].map { String($0.characters) } == ["1", "", ""])
    }

    @Test func testABrokenTableStillKeepsEveryCharacter() {
        // No blank line before the following text and an unclosed code span:
        // every line is still shown somewhere rather than one being dropped
        // because the table was not well formed.
        let source = """
        | 只有表头 |
        |---|
        未闭合的 `code
        **未闭合
        """
        let document = Markdown.parse(source)
        let joined = document.blocks.map(markdownText).joined(separator: "\n")
        #expect(joined.contains("只有表头"))
        #expect(joined.contains("未闭合的 `code"))
        #expect(joined.contains("**未闭合"))
    }

    // MARK: - Code

    @Test func testAFencedBlockIsCodeWithItsLanguageAndThePipesInItStayText() {
        let source = """
        前面的段落

        ```swift
        let x = 1 | 0
        | not | a table |
        ```

        后面的段落
        """
        let document = Markdown.parse(source)
        let codes: [(String?, String)] = document.blocks.compactMap { block in
            guard case .code(let language, let text) = block else { return nil }
            return (language, text)
        }
        #expect(codes.count == 1)
        #expect(codes.first?.0 == "swift")
        #expect(codes.first?.1.contains("let x = 1 | 0") == true)
        #expect(codes.first?.1.contains("| not | a table |") == true)
    }

    @Test func testAFenceWithoutALanguageHasNoLanguage() {
        let source = "```\nplain\n```"
        let document = Markdown.parse(source)
        guard let first = document.blocks.first, case .code(let language, let text) = first else {
            Issue.record("the only block is not code: \(document.blocks)")
            return
        }
        #expect(language == nil)
        #expect(text.contains("plain"))
    }

    // MARK: - Paragraphs, headings, lists, quotes, inline styles

    @Test func testParagraphsHeadingsListsAndQuotesComeOutAsThemselves() {
        let source = """
        # 标题

        段落 **粗** [链接](https://example.com) `code`

        - 一
        - 二

        1. 甲
        2. 乙

        > 引用
        """
        let document = Markdown.parse(source)

        let headings: [(Int, String)] = document.blocks.compactMap { block in
            guard case .heading(let level, let text) = block else { return nil }
            return (level, String(text.characters))
        }
        #expect(headings.count == 1)
        #expect(headings.first?.0 == 1)
        #expect(headings.first?.1 == "标题")

        let items: [Markdown.ListItem] = document.blocks.compactMap { block in
            guard case .listItem(let item) = block else { return nil }
            return item
        }
        #expect(items.map { String($0.text.characters) } == ["一", "二", "甲", "乙"])
        #expect(items.map(\.kind) == [.unordered, .unordered, .ordered, .ordered])
        #expect(items.map(\.ordinal) == [1, 2, 1, 2])

        let quotes = document.blocks.compactMap { block -> String? in
            guard case .blockQuote(let text) = block else { return nil }
            return String(text.characters)
        }
        #expect(quotes == ["引用"])
    }

    @Test func testInlineEmphasisLinkAndCodeAreKeptOnTheirOwnText() {
        let source = "段落 **粗** [链接](https://example.com) `code`"
        let document = Markdown.parse(source)
        guard let paragraph = document.blocks.first,
              case .paragraph(let text) = paragraph else {
            Issue.record("the only block is not a paragraph: \(document.blocks)")
            return
        }
        let runs = markdownRuns(text)
        #expect(runs.contains { $0.text == "粗" && $0.stronglyEmphasized })
        #expect(runs.contains { $0.text == "链接" && $0.link == URL(string: "https://example.com") })
        #expect(runs.contains { $0.text == "code" && $0.code })
    }

    // MARK: - Old and broken text

    @Test func testPlainTextIsShownWholeWithItsOwnLines() {
        let source = "第一行中文\n第二行 plain text\n第三次"
        let document = Markdown.parse(source)
        #expect(!document.usedPlainFallback)
        let joined = document.blocks.map(markdownText).joined(separator: "\n")
        #expect(joined.contains("第一行中文"))
        #expect(joined.contains("第二行 plain text"))
        #expect(joined.contains("第三次"))
    }

    @Test func testEmptySourceHasNoBlocks() {
        let document = Markdown.parse("")
        #expect(document.blocks.isEmpty)
        #expect(!document.usedPlainFallback)
    }

    // MARK: - Nothing runs, nothing is fetched

    @Test func testHTMLStaysTextAndAnImageStaysItsAltText() {
        let source = """
        <b>粗体</b> <script>alert(1)</script>

        ![图](https://example.com/a.png)
        """
        let document = Markdown.parse(source)
        let joined = document.blocks.map(markdownText).joined(separator: "\n")
        // Not interpreted as HTML: the tags are the message's own words.
        #expect(joined.contains("<script>alert(1)</script>"))
        #expect(joined.contains("图"))
        // The image is its alt text; its URL is not text and not a link.
        #expect(!joined.contains("example.com/a.png"))
        for block in document.blocks {
            for run in markdownAttributedRuns(block) {
                #expect(run.url?.absoluteString != "https://example.com/a.png")
            }
        }
    }

    // MARK: - The bounded store

    @Test func testTheCacheForgetsTheOldestBeyondItsEntryBudget() {
        var cache = Markdown.Cache(maxEntries: 2, maxBytes: 1_000_000)
        let a = Markdown.Cache.Key(group: "polter", anchor: "persisted:1", version: 1)
        let b = Markdown.Cache.Key(group: "polter", anchor: "persisted:2", version: 1)
        let c = Markdown.Cache.Key(group: "polter", anchor: "persisted:3", version: 1)
        _ = cache.document(for: a, text: "甲")
        _ = cache.document(for: b, text: "乙")
        #expect(cache.count == 2)
        _ = cache.document(for: c, text: "丙")
        #expect(cache.count == 2)
        #expect(!cache.contains(a))
        #expect(cache.contains(b))
        #expect(cache.contains(c))
    }

    @Test func testTheCacheForgetsTheLeastRecentlyUsed() {
        var cache = Markdown.Cache(maxEntries: 2, maxBytes: 1_000_000)
        let a = Markdown.Cache.Key(group: "polter", anchor: "persisted:1", version: 1)
        let b = Markdown.Cache.Key(group: "polter", anchor: "persisted:2", version: 1)
        let c = Markdown.Cache.Key(group: "polter", anchor: "persisted:3", version: 1)
        _ = cache.document(for: a, text: "甲")
        _ = cache.document(for: b, text: "乙")
        _ = cache.document(for: a, text: "甲")  // a is in use again
        _ = cache.document(for: c, text: "丙")
        #expect(cache.contains(a))
        #expect(!cache.contains(b))
        #expect(cache.contains(c))
    }

    @Test func testTheCacheKeepsWithinItsByteBudgetAndDoesNotKeepOversizedText() {
        // Three bytes for each of these characters; a budget of four holds
        // one of them, never two.
        var cache = Markdown.Cache(maxEntries: 10, maxBytes: 4)
        let a = Markdown.Cache.Key(group: "polter", anchor: "persisted:1", version: 1)
        let b = Markdown.Cache.Key(group: "polter", anchor: "persisted:2", version: 1)
        _ = cache.document(for: a, text: "甲")
        #expect(cache.count == 1)
        #expect(cache.residentBytes == 3)
        _ = cache.document(for: b, text: "乙")
        #expect(cache.count == 1)
        #expect(!cache.contains(a))
        #expect(cache.residentBytes == 3)

        // Source larger than the whole budget is returned but not kept.
        var tiny = Markdown.Cache(maxEntries: 10, maxBytes: 2)
        _ = tiny.document(for: a, text: "甲乙")
        #expect(tiny.count == 0)
        #expect(tiny.residentBytes == 0)
    }

    @Test func testTheCacheHandsBackTheSameParseItKept() {
        var cache = Markdown.Cache()
        let key = Markdown.Cache.Key(group: "polter", anchor: "persisted:7", version: 1)
        let first = cache.document(for: key, text: "| a | b |\n|---|---|\n| 1 | 2 |")
        let second = cache.document(for: key, text: "| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(first == second)
        guard case .table(let table)? = first.blocks.first else {
            Issue.record("the cached document lost its table: \(first.blocks)")
            return
        }
        #expect(table.rows.count == 1)
    }

    /// The version is the message's `contentVersion`, a `UInt64` on the
    /// wire: the top of the range is a version, not a value to narrow.
    @Test func testTheCacheKeyKeepsTheWholeUInt64Version() {
        var cache = Markdown.Cache()
        let top = Markdown.Cache.Key(group: "polter", anchor: "persisted:7", version: .max)
        let oneLess = Markdown.Cache.Key(group: "polter", anchor: "persisted:7", version: .max - 1)
        let kept = cache.document(for: top, text: "顶格版本")
        #expect(cache.document(top) == kept)
        #expect(cache.document(oneLess) == nil)
    }

    @Test func testTwoGroupsWithTheSameAnchorAndVersionDoNotShareAnEntry() {
        var cache = Markdown.Cache()
        // The same anchor and version in two groups are not the same
        // message: a `seq` of 1 exists in every group.
        let alpha = Markdown.Cache.Key(group: "alpha", anchor: "persisted:1", version: 1)
        let beta = Markdown.Cache.Key(group: "beta", anchor: "persisted:1", version: 1)
        let first = cache.document(for: alpha, text: "甲的正文")
        let second = cache.document(for: beta, text: "乙的正文")
        #expect(cache.count == 2)
        #expect(markdownText(first.blocks[0]) == "甲的正文")
        #expect(markdownText(second.blocks[0]) == "乙的正文")
        #expect(first != second)
    }

    @Test func testLiveAndPersistedAnchorsInOneGroupDoNotShareAnEntry() {
        var cache = Markdown.Cache()
        // The same group and the same visible position, said apart by the
        // anchor: a live message and a persisted one are two messages.
        let live = Markdown.Cache.Key(group: "polter", anchor: "live:12", version: 1)
        let persisted = Markdown.Cache.Key(group: "polter", anchor: "persisted:12", version: 1)
        let first = cache.document(for: live, text: "刚刚说的")
        let second = cache.document(for: persisted, text: "落盘的")
        #expect(cache.count == 2)
        #expect(markdownText(first.blocks[0]) == "刚刚说的")
        #expect(markdownText(second.blocks[0]) == "落盘的")
        #expect(first != second)
    }
}

// MARK: - Reading a document in a test

/// The words of one block, with table cells separated so a test can say a
/// cell is a cell.
private func markdownText(_ block: ControlRoomChatMarkdown.Block) -> String {
    switch block {
    case .paragraph(let text), .blockQuote(let text):
        return String(text.characters)
    case .heading(_, let text):
        return String(text.characters)
    case .listItem(let item):
        return String(item.text.characters)
    case .code(_, let text):
        return text
    case .table(let table):
        var cells = table.header.map { String($0.characters) }
        for row in table.rows {
            cells += row.map { String($0.characters) }
        }
        return cells.joined(separator: "|")
    }
}

private struct MarkdownRun {
    var text: String
    var stronglyEmphasized: Bool
    var code: Bool
    var link: URL?
}

private func markdownRuns(_ text: AttributedString) -> [MarkdownRun] {
    markdownAttributedRuns(text).map { run in
        MarkdownRun(
            text: String(text[run.range].characters),
            stronglyEmphasized: run.style?.contains(.stronglyEmphasized) == true,
            code: run.style?.contains(.code) == true,
            link: run.url)
    }
}

/// Every run of a block's text, however many `AttributedString`s the block
/// keeps.
private func markdownAttributedRuns(
    _ block: ControlRoomChatMarkdown.Block
) -> [(range: Range<AttributedString.Index>, style: InlinePresentationIntent?, url: URL?)] {
    switch block {
    case .paragraph(let text), .blockQuote(let text):
        return markdownAttributedRuns(text)
    case .heading(_, let text):
        return markdownAttributedRuns(text)
    case .listItem(let item):
        return markdownAttributedRuns(item.text)
    case .code, .table:
        return []
    }
}

private func markdownAttributedRuns(
    _ text: AttributedString
) -> [(range: Range<AttributedString.Index>, style: InlinePresentationIntent?, url: URL?)] {
    text.runs.map { run in
        (range: run.range,
         style: run.inlinePresentationIntent,
         url: run.link)
    }
}
