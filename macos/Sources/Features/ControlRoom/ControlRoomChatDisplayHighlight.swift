import Foundation

/// Maps a search hit's **raw UTF-8 byte ranges** onto the rendered text of a
/// message (DESIGN-v2 §10.1).
///
/// The core's `Hit` names the bytes of the stored Markdown:
/// `snippet_start` in the message and `ranges` inside the snippet. The view
/// draws a `Document` whose markers the parser removed, so the mapping has to
/// find the **same matched text** in the rendered blocks.
///
/// **This is a display mapping, not a second search.** The matched substrings
/// come only from the core's ranges; the mapper decodes escapes/entities for
/// comparison and never matches other text.
///
/// **The core's position decides which occurrence is meant.** A query is a
/// literal substring, so a message may hold the same word twice; a mapper
/// that looked for "the first `x`" in each block would draw the same match
/// twice and leave the second one dark. Each needle therefore carries the
/// **rank** of its match among the occurrences before it in the message --
/// counted on the decoded source at the core's own byte offset -- and the
/// rendered scan takes that occurrence and no other. A span the rendered
/// text cannot represent (for example one containing Markdown markers, or
/// markup the parser dropped) is simply not highlighted: moving the
/// highlight to a different word would be worse than having none. The
/// locate's whole-row highlight remains.
enum ControlRoomChatDisplayHighlight {
    /// The decoded matched substring, and which occurrence of it in the
    /// message the core meant (0-based).
    struct Needle: Equatable {
        var text: String
        var rank: Int
    }

    /// The matched substrings, in the core's order.
    struct Plan: Equatable {
        var needles: [Needle]
    }

    /// One match in a block's visible text. `block` and `text` index the
    /// shape `blocksText` returns: one entry per block, and one text per
    /// cell for a table.
    struct Match: Equatable {
        var block: Int
        var text: Int
        var range: Range<String.Index>
    }

    /// The plan for one hit against its own message. Nil when the hit is for
    /// another message or its byte offsets do not land on scalar boundaries.
    static func plan(
        message: ControlRoomChatData.Message,
        hit: ControlRoomChatSearch.Hit
    ) -> Plan? {
        guard hit.message.anchor == message.anchor else { return nil }
        let text = Array(message.text.utf8)
        let boundaries = scalarBoundaries(message.text)
        let start = Int(hit.snippetStart)
        guard boundaries.contains(start) else { return nil }
        let source = Decoded(message.text)
        var needles: [Needle] = []
        for range in hit.ranges {
            let a = start + Int(range.start)
            let b = start + Int(range.end)
            guard a < b, b <= text.count,
                  boundaries.contains(a), boundaries.contains(b),
                  let da = source.charOffset(atByte: a),
                  let db = source.charOffset(atByte: b), da < db
            else { return nil }
            let needle = String(source.chars[da..<db])
            guard !needle.isEmpty else { return nil }
            // **The core's offset, not the document's order**: how many
            // times this text already appeared before the match decides
            // which occurrence is drawn.
            let rank = occurrences(of: needle, in: String(source.chars[0..<da]))
            needles.append(Needle(text: needle, rank: rank))
        }
        return needles.isEmpty ? nil : Plan(needles: needles)
    }

    /// The matches in the rendered blocks. **Rank is absolute**: each needle
    /// names the nth occurrence of its text across the blocks in drawing
    /// order, so two occurrences of one word are two matches. A needle whose
    /// rank the rendered text cannot reach is dropped, never moved to a
    /// nearer occurrence.
    static func matches(
        in blocks: [[String]],
        plan: Plan
    ) -> [Match] {
        var out: [Match] = []
        for needle in plan.needles where !needle.text.isEmpty {
            var seen = 0
            search: for (blockIndex, texts) in blocks.enumerated() {
                for (textIndex, text) in texts.enumerated() {
                    var from = text.startIndex
                    while from < text.endIndex,
                          let found = text.range(of: needle.text, range: from..<text.endIndex) {
                        if seen == needle.rank {
                            out.append(Match(block: blockIndex, text: textIndex, range: found))
                            break search
                        }
                        seen += 1
                        from = found.upperBound
                    }
                }
            }
        }
        return out
    }

    /// Blocks' visible texts in drawing order: one entry per block, one text
    /// per cell for a table.
    static func blocksText(_ document: ControlRoomChatMarkdown.Document) -> [[String]] {
        document.blocks.map { block in
            switch block {
            case .paragraph(let text), .heading(_, let text), .blockQuote(let text):
                return [String(text.characters)]
            case .listItem(let item):
                return [String(item.text.characters)]
            case .code(_, let text):
                return [text]
            case .table(let table):
                var cells = table.header.map { String($0.characters) }
                for row in table.rows {
                    cells.append(contentsOf: row.map { String($0.characters) })
                }
                return cells
            }
        }
    }

    // MARK: - Reading the stored spelling

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var from = text.startIndex
        while from < text.endIndex,
              let found = text.range(of: needle, range: from..<text.endIndex) {
            count += 1
            from = found.upperBound
        }
        return count
    }

    /// The stored text with backslash escapes and the common entities
    /// decoded, and the byte offset each decoded character starts at. Two
    /// ways Markdown's stored spelling differs from the drawn characters;
    /// decoding is for comparison only.
    private struct Decoded {
        var chars: [Character] = []
        /// Source UTF-8 byte boundary -> decoded character offset. Only
        /// scalar boundaries are recorded; every offset the core may name is
        /// one (`scalarBoundaries`).
        private var offsets: [Int: Int] = [:]

        init(_ source: String) {
            let source = Array(source)
            var byte = 0
            var i = 0
            while i < source.count {
                offsets[byte] = chars.count
                if source[i] == "\\", i + 1 < source.count {
                    chars.append(source[i + 1])
                    byte += utf8Count(source[i]) + utf8Count(source[i + 1])
                    i += 2
                    offsets[byte] = chars.count
                    continue
                }
                if source[i] == "&", let end = entityEnd(source, i),
                   let decoded = decodeEntity(String(source[i...end])) {
                    chars.append(contentsOf: decoded)
                    byte += utf8Count(source[i...end])
                    i = end + 1
                    offsets[byte] = chars.count
                    continue
                }
                chars.append(source[i])
                byte += utf8Count(source[i])
                i += 1
                offsets[byte] = chars.count
            }
            offsets[byte] = chars.count
        }

        func charOffset(atByte byte: Int) -> Int? { offsets[byte] }

        private func utf8Count(_ character: Character) -> Int {
            String(character).utf8.count
        }

        private func utf8Count(_ characters: ArraySlice<Character>) -> Int {
            characters.reduce(0) { $0 + utf8Count($1) }
        }
    }

    private static func entityEnd(_ s: [Character], _ start: Int) -> Int? {
        var j = start + 1
        while j < s.count, j - start <= 10 {
            if s[j] == ";" { return j }
            j += 1
        }
        return nil
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity {
        case "&amp;": return "&"
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        case "&#39;", "&apos;": return "'"
        case "&nbsp;": return "\u{00A0}"
        default: return nil
        }
    }

    private static func scalarBoundaries(_ text: String) -> Set<Int> {
        var offsets: Set<Int> = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += String(scalar).utf8.count
            offsets.insert(offset)
        }
        return offsets
    }
}
