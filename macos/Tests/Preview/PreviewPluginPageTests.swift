import Foundation
import Testing

@testable import Ghostty

/// A preview plugin's own page: where it is and what may be served out of it
/// (`PreviewPluginPage`, task 2779 S7B).
///
/// **The fence is the part that matters.** Everything else here is a table;
/// `fencedFile` is the one rule that decides whether a page may read a file
/// at all, and it is tested against a real directory with a real symlink out
/// of it, because the escape it guards against is a filesystem fact and not
/// a string one.
struct PreviewPluginPageTests {
    typealias Page = PreviewPluginPage

    /// A page is served over its own scheme, keyed by the plugin's key --
    /// **not the settings page's scheme**, which is a different page with a
    /// different bridge in it.
    @Test func aPageIsItsOwnOriginByItsPluginKey() {
        let at = Page.Location(key: "edit-text", root: "/opt/p", page: "page/index.html")
        #expect(at.url?.absoluteString == "polter-plugin-page://edit-text/page/index.html")
        #expect(Page.scheme != "polter-plugin", "the settings page's scheme was reused")
        #expect(Page.scheme != "polter-file", "a plugin page is not a ticket's route")
    }

    /// The types are a *page's*: a stylesheet is a stylesheet and a manifest
    /// is JSON, because the engine has to be told what a page's own
    /// resources are. (A previewed file's table answers the opposite way on
    /// purpose -- a `.rs` is `text/plain` there so it is read, not run.)
    @Test func aPagesOwnResourcesAreServedAsWhatTheyAre() {
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/index.html")) == "text/html; charset=utf-8")
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/a.css")) == "text/css; charset=utf-8")
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/a.js")) == "text/javascript; charset=utf-8")
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/a.json")) == "application/json; charset=utf-8")
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/a.woff2")) == "font/woff2")
        #expect(Page.contentType(of: URL(fileURLWithPath: "/p/a.bin")) == "application/octet-stream")
    }

    /// **Nothing the page can reach.** The file's bytes arrive through
    /// `window.polter`, so there is no reason for the page to open a
    /// connection -- and no reason for its policy to name the ticket's
    /// route, which would be a second way to read a file.
    @Test func thePolicyNamesNoNetworkAndNoTicketRoute() {
        #expect(Page.policy.contains("connect-src 'none'"))
        #expect(!Page.policy.contains("polter-file:"), "the ticket's route was allowed to the page")
        #expect(Page.policy.contains("default-src 'self'"))
    }

    /// Every way a path leaves the plugin's directory, refused. The fence is
    /// checked on the resolved path, so `..` and a symlink are the same kind
    /// of escape and are tested the same way.
    @Test func nothingOutsideThePluginsDirectoryIsServed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        // Inside: served.
        #expect(Page.fencedFile(root: root.path, path: "/page/index.html")?.lastPathComponent == "index.html")
        // An empty path is the plugin's own `index.html`, the same rule a
        // settings page has (`PluginPageBridge.resolve`).
        #expect(Page.fencedFile(root: root.path, path: "/")?.lastPathComponent == "index.html")
        #expect(Page.fencedFile(root: root.path, path: "")?.lastPathComponent == "index.html")
        #expect(Page.fencedFile(root: root.path, path: "/index.html")?.lastPathComponent == "index.html")

        for escape in ["/../outside.txt", "/page/../../outside.txt", "/link-out.txt",
                       "/.hidden/../../../etc/passwd"] {
            #expect(Page.fencedFile(root: root.path, path: escape) == nil, "at \(escape)")
        }

        // A root that is not absolute is not a root to join anything onto.
        #expect(Page.fencedFile(root: "relative/dir", path: "/page/index.html") == nil)
        #expect(Page.fencedFile(root: "", path: "/page/index.html") == nil)
    }

    /// A **symlink inside the plugin** pointing out of it is the escape a
    /// string check would miss: `.standardizedFileURL` collapses `..` but
    /// does not follow a link, and only `resolvingSymlinksInPath` does.
    @Test func aSymlinkOutOfThePluginIsRefused() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).txt")
        try "the host's own business".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link-out.txt"), withDestinationURL: target)

        #expect(Page.fencedFile(root: root.path, path: "/link-out.txt") == nil)
    }

    /// A directory is not a page: the page is loaded, not listed.
    @Test func aDirectoryIsNotServedAsAPage() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Page.fencedFile(root: root.path, path: "/page") == nil)
        #expect(Page.fencedFile(root: root.path, path: "/page/nothing-here.html") == nil)
    }

    /// A plugin directory with one page in it, in a temp directory of its
    /// own -- so the symlink test has somewhere real to point out of. There
    /// is an `index.html` at the root as well as one under `page/`, because
    /// an empty request path means the plugin's own `index.html`.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-plugin-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("page"), withIntermediateDirectories: true)
        try "<!doctype html>".write(
            to: root.appendingPathComponent("page/index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html>".write(
            to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "not a page".write(
            to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        return root
    }
}
