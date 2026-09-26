import Testing
import Foundation
@testable import Ghostty

/// The macOS consumer of `test/fixtures/project-filenames.tsv`, the one
/// table the three implementations of the project filename rule are all
/// held to (issue #23). The Zig and Rust implementations run the same rows
/// in their own tests.
@Suite
struct ProjectFilenameTableTests {
    private struct Row {
        let input: String
        let expected: String?
        let draft: Bool
        let note: String
    }

    private static let tableURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../test/fixtures/project-filenames.tsv")
        .standardized

    private func hexBytes(_ hex: Substring) throws -> [UInt8] {
        try stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return try #require(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16))
        }
    }

    /// Failable on purpose: a row that isn't valid UTF-8 is a broken table,
    /// not something to quietly turn into U+FFFD and compare.
    private func utf8(_ bytes: [UInt8]) throws -> String {
        try #require(String(bytes: bytes, encoding: .utf8), "row is not valid UTF-8")
    }

    private func table() throws -> (declared: Int, rows: [Row]) {
        let text = try String(contentsOf: Self.tableURL, encoding: .utf8)
        var declared: Int?
        var rows: [Row] = []
        // By `isNewline`, not by "\n": Swift reads "\r\n" as one Character,
        // so splitting a Windows checkout on "\n" yields one line.
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                if line.hasPrefix("# rows: ") { declared = Int(line.dropFirst("# rows: ".count)) }
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 4, "malformed row: \(line)")
            let expected: String? = fields[1] == "ERR:InvalidName"
                ? nil
                : try utf8(hexBytes(fields[1]))
            rows.append(Row(
                input: try utf8(hexBytes(fields[0])),
                expected: expected,
                draft: fields[2] == "draft",
                note: String(fields[3])))
        }
        return (try #require(declared, "no '# rows: N' line"), rows)
    }

    /// Every `ok` row, byte for byte. Draft rows are read and counted but
    /// not asserted -- see the table's header.
    @Test func everyRowOfTheSharedTable() throws {
        let (declared, rows) = try table()
        var asserted = 0
        var drafts = 0
        for row in rows {
            if row.draft {
                drafts += 1
                continue
            }
            #expect(ProjectFilename.forNewFile(named: row.input) == row.expected, "\(row.note)")
            asserted += 1
        }
        // A reader that found no rows must not pass.
        #expect(asserted + drafts == declared)
        #expect(asserted > 0)
    }
}
