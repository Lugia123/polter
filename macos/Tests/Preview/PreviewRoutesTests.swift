import Foundation
import Testing

@testable import Ghostty

/// The `polter-file://` routes (`PreviewRoutes`), held to the same table the
/// Windows crate is held to (task 2628, #2140 M1/W1).
///
/// **This file and `windows/preview-route/src/lib.rs` run
/// `test/fixtures/preview-routes.tsv` row for row**, the shape
/// `ProjectFilenameTableTests` uses for its three readers: the two hosts are
/// two languages, each can be green on its own, and nothing here looks at
/// both at once.
struct PreviewRoutesTests {
    typealias Routes = PreviewRoutes

    private static let token = "9f2c0a1b4d5e6f708192a3b4c5d6e7f8"

    /// The rows of the shared table, as `(case, verdict, token, rel, url)`.
    ///
    /// ⚠️ Read by splitting on the tab and **not** by trimming whitespace: two
    /// of the five columns are empty for a refusal, and dropping them turns
    /// every refused row into a three-column one. That is why `url` is the
    /// last column: a row whose `url` is empty would end in tabs, so the empty
    /// request is asserted in `refusalsThatDoNotNeedARowOfTheTable` instead.
    ///
    /// ⚠️ **And the count is checked against the table's own `# rows:` line.**
    /// Two implementations that agree on every row they read also agree after
    /// somebody deletes a row from the table -- "the two hosts match" is not
    /// "this case is still being tested", and the refusals are the rows most
    /// likely to be trimmed. The Windows reader holds the same line.
    private static func rows() throws -> [(String, String, String, String, String)] {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("test/fixtures/preview-routes.tsv")
        let text = try String(contentsOf: path, encoding: .utf8)
        var out: [(String, String, String, String, String)] = []
        var declared: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // The declared count, as `project-filenames.tsv` writes it. String
            // surgery rather than a regular expression: this file is compiled
            // in a package whose Swift language mode is not this file's to
            // choose, and a literal `/…/` is a syntax error in the modes that
            // predate it.
            if line.hasPrefix("# rows:") {
                let digits = line.dropFirst("# rows:".count)
                    .trimmingCharacters(in: .whitespaces)
                declared = Int(digits)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("case\t") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try #require(f.count == 5, "the table row \(line) does not have five columns")
            out.append((f[0], f[1], f[2], f[3], f[4]))
        }
        #expect(declared != nil, "test/fixtures/preview-routes.tsv: no `# rows:` line to check against")
        #expect(out.count == declared, "the table declares \(declared.map(String.init) ?? "nothing") rows and \(out.count) were read")
        #expect(!out.isEmpty, "no rows, so nothing was checked")
        return out
    }

    @Test func everyRowOfTheSharedTableIsTheRoute() throws {
        for (name, verdict, token, rel, url) in try Self.rows() {
            switch Routes.resolve(url) {
            case .success(let route):
                #expect(verdict == "ok", "\(name): \(url) was served and the table says \(verdict)")
                #expect(route.token == token, "\(name): the ticket")
                #expect(route.rel == rel, "\(name): the path asked of the ticket")
            case .failure(let refusal):
                #expect(verdict == refusal.word, "\(name): \(url) was refused as \(refusal)")
            }
        }
    }

    /// The refusals asserted here as well as in the table, because the table is
    /// a file both hosts read and a case edited in it would move both sides at
    /// once. These do not move with it.
    @Test func refusalsThatDoNotNeedARowOfTheTable() {
        #expect(Routes.resolve("") == .failure(.otherScheme), "the empty request")
        #expect(Routes.resolve("polter-file://\(Self.token)/../etc/passwd") == .failure(.outside))
        #expect(Routes.resolve("polter-file://\(Self.token)/%2e%2e/etc/passwd") == .failure(.outside))
        #expect(Routes.resolve("polter-file://not-a-token/x") == .failure(.badToken))
        #expect(Routes.resolve("https://example.com/x") == .failure(.otherScheme))
    }

    /// **The bridge's surface, said as an absence.** A method that is not one
    /// of the eight is `nil`, and these six are the ones a page must not be
    /// able to reach even by guessing the name.
    @Test func aPageCannotWriteAndTheNamesThatSaySoAreNotCalls() {
        for forbidden in ["write", "create", "delete", "rename", "exec", "fetch"] {
            #expect(PreviewCall.parse(forbidden) == nil, "\(forbidden) is not a call a page may make")
        }
        for call in PreviewCall.allCases {
            #expect(PreviewCall.parse(call.name) == call)
        }
        // The eight names themselves, spelled out: a name changed in
        // `rawValue` to something a page does not know is a call nobody can
        // make, and this is the only place that would go red for it.
        #expect(PreviewCall.allCases.map(\.name)
                == ["info", "read", "readRel", "openPath", "watch", "look", "propose", "dirty"])
    }

    @Test func aTokenIsHexAndExactlyHex() {
        #expect(Routes.isToken(Self.token))
        #expect(!Routes.isToken(Self.token.uppercased()), "upper case is another string to the core")
        #expect(!Routes.isToken(String(Self.token.dropLast())), "short")
        #expect(!Routes.isToken(Self.token + "0"), "long")
        #expect(!Routes.isToken("9f2c0a1b4d5e6f708192a3b4c5d6e7gz"), "not hex")
        #expect(!Routes.isToken(""))
    }

    /// The rows of `test/fixtures/preview-types.tsv`, as `(path, type)`.
    ///
    /// **The Content-Type table is the second thing this host and the Windows
    /// host must agree on**, and the one where they disagreed until
    /// 2026-11-01: `.css` was `text/css` there and `text/plain` here, `.json`
    /// `application/json` there and `text/plain` here, and both hosts send
    /// `X-Content-Type-Options: nosniff`, so the difference was a stylesheet
    /// that rendered on one machine and printed on the other. The Windows
    /// implementation now *is* `polter_preview_route::content_type` (one copy,
    /// in a crate that compiles on any machine); this host cannot call it, so
    /// the table is the only thing that holds the two together.
    ///
    /// ⚠️ The same two traps as `rows()` above: split on the tab and not on
    /// whitespace, and a third column that is **never empty** so no row ends
    /// in a tab and can be trimmed into a two-column one.
    private static func typeRows() throws -> [(String, String)] {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("test/fixtures/preview-types.tsv")
        let text = try String(contentsOf: path, encoding: .utf8)
        var out: [(String, String)] = []
        var declared: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# rows:") {
                declared = Int(line.dropFirst("# rows:".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("path\t") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try #require(f.count == 3, "the type row \(line) does not have three columns")
            out.append((f[0], f[1]))
        }
        #expect(declared != nil, "test/fixtures/preview-types.tsv: no `# rows:` line to check against")
        #expect(out.count == declared, "the table declares \(declared.map(String.init) ?? "nothing") rows and \(out.count) were read")
        #expect(!out.isEmpty, "no rows, so nothing was checked")
        return out
    }

    @Test func everyRowOfTheSharedTypeTableIsTheContentType() throws {
        for (path, want) in try Self.typeRows() {
            #expect(Routes.contentType(of: path) == want, "\(path): the Content-Type")
        }
    }

    /// The two extensions the hosts disagreed on, and the four shapes of "no
    /// extension" that are where the two standard libraries could part.
    /// Asserted here as well as in the table, because a case edited in the
    /// table would move both hosts at once.
    ///
    /// ⚠️ **The plugin page's table is a different one and keeps `text/css`
    /// and `application/json`** (`PluginPage.contentType`): a plugin page is a
    /// program loading its own resources, and a preview is a person reading a
    /// file whose scripts do not run.
    @Test func aStylesheetAndAJSONDocumentAreTextAPersonReads() {
        #expect(Routes.contentType(of: "site.css") == "text/plain; charset=utf-8")
        #expect(Routes.contentType(of: "data.json") == "text/plain; charset=utf-8")
        #expect(Routes.contentType(of: "index.html") == "text/html; charset=utf-8")
        #expect(Routes.contentType(of: "file.") == "application/octet-stream")
        #expect(Routes.contentType(of: ".gitignore") == "application/octet-stream")
        #expect(Routes.contentType(of: "a.d/b") == "application/octet-stream")
        #expect(Routes.contentType(of: "LICENSE") == "application/octet-stream")
    }
}
