import Foundation
import Testing
@testable import Ghostty

/// What a sidecar says about where its screenshot was taken
/// (`dev-docs/poltergeist/screenshot.md`, section 11).
struct ShotContextTests {
    // MARK: Git

    @Test func aCleanRepositoryIsItsCommitAndNotDirty() {
        let status = """
        # branch.oid 3d65ad0c7e1f4b2a9c8d7e6f5a4b3c2d1e0f9a8b
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0

        """
        #expect(ShotContext.git(fromStatus: status) == .init(head: "3d65ad0", dirty: false))
    }

    @Test func anyTrackedChangeIsDirty() {
        let head = "# branch.oid 3d65ad0c7e1f4b2a9c8d7e6f5a4b3c2d1e0f9a8b\n# branch.head main\n"
        let changed = "1 .M N... 100644 100644 100644 abc def src/a.zig\n"
        let renamed = "2 R. N... 100644 100644 100644 abc def R100 b.zig\ta.zig\n"
        let unmerged = "u UU N... 100644 100644 100644 100644 a b c d.zig\n"
        for line in [changed, renamed, unmerged] {
            #expect(ShotContext.git(fromStatus: head + line) == .init(head: "3d65ad0", dirty: true), "\(line)")
        }
        // The change may come before the header is finished being read.
        #expect(ShotContext.git(fromStatus: changed + head) == .init(head: "3d65ad0", dirty: true))
    }

    @Test func aDetachedHeadIsStillACommit() {
        let status = "# branch.oid 0123456789abcdef0123456789abcdef01234567\n# branch.head (detached)\n"
        #expect(ShotContext.git(fromStatus: status) == .init(head: "0123456", dirty: false))
    }

    @Test func whatIsNotAnAnswerIsNoAnswer() {
        #expect(ShotContext.git(fromStatus: "") == nil)
        #expect(ShotContext.git(fromStatus: "fatal: not a git repository\n") == nil)
        // A repository with no commit yet.
        #expect(ShotContext.git(fromStatus: "# branch.oid (initial)\n# branch.head main\n") == nil)
        #expect(ShotContext.git(fromStatus: "# branch.oid 3d65a\n") == nil, "too short to be a commit")
        #expect(ShotContext.git(fromStatus: "# branch.oid 3d65adz0c7e1f4b2\n") == nil)
        // Changes with no header say nothing about which commit.
        #expect(ShotContext.git(fromStatus: "1 .M N... 100644 100644 100644 abc def a\n") == nil)
    }

    @Test func untrackedFilesAreNotAskedAbout() {
        let arguments = ShotContext.gitArguments(cwd: "/tmp/a b")
        #expect(arguments == ["-C", "/tmp/a b", "status", "--porcelain=v2", "--branch", "--untracked-files=no"])
        #expect(ShotContext.headLength == 7)
    }

    @Test func gitIsLookedForOnlyWhereItIsNotTheSystemsStub() {
        let clt = "/Library/Developer/CommandLineTools/usr/bin/git"
        let brew = "/opt/homebrew/bin/git"
        #expect(ShotContext.gitExecutable { _ in false } == nil)
        #expect(ShotContext.gitExecutable { $0 == brew } == brew)
        #expect(ShotContext.gitExecutable { $0 == brew || $0 == clt } == clt, "the first that is there")
        // `/usr/bin/git` offers to install developer tools when there are
        // none; it is never asked.
        #expect(ShotContext.gitExecutable { $0 == "/usr/bin/git" } == nil)
        var asked: [String] = []
        _ = ShotContext.gitExecutable {
            asked.append($0)
            return false
        }
        #expect(asked.count == 4)
        #expect(!asked.contains("/usr/bin/git"))
    }

    // MARK: The previous screenshot

    private func sidecar(image: String, app: String?, title: String?) -> String {
        let meta = ShotSidecar.Meta(
            image: image,
            taken: .init(year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, utcOffsetMinutes: 480),
            width: 10, height: 10, scale: 2,
            source: .window(
                app: app, title: title, pid: 1, windowRect: nil, selectionRect: PixelRect(0, 0, 10, 10)))
        return ShotSidecar.json(meta, items: [])
    }

    @Test func anEarlierSidecarSaysWhatItWasOf() {
        let text = sidecar(image: "20261006-153012-123.png", app: "Safari", title: "a \"quoted\" title")
        #expect(ShotContext.earlier(fromSidecar: text)
            == .init(image: "20261006-153012-123.png", app: "Safari", title: "a \"quoted\" title"))
        let region = ShotSidecar.json(
            ShotSidecar.Meta(
                image: "20261006-153012-124.png",
                taken: .init(year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12, utcOffsetMinutes: 0),
                width: 10, height: 10, scale: 1,
                source: .region(selectionRect: PixelRect(0, 0, 10, 10))),
            items: [])
        #expect(ShotContext.earlier(fromSidecar: region) == .init(image: "20261006-153012-124.png", app: nil, title: nil))
        #expect(ShotContext.earlier(fromSidecar: "not json") == nil)
        #expect(ShotContext.earlier(fromSidecar: "{\"source\": {\"app\": \"Safari\"}}") == nil, "no image, nothing to point at")
        #expect(ShotContext.earlier(fromSidecar: "[1, 2]") == nil)
    }

    @Test func thePreviousScreenshotIsTheNewestEarlierOneOfTheSameWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        try write("20261006-100000-000.json", sidecar(image: "20261006-100000-000.png", app: "Safari", title: "Docs"))
        try write("20261006-110000-000.json", sidecar(image: "20261006-110000-000.png", app: "Safari", title: "Docs"))
        try write("20261006-120000-000.json", sidecar(image: "20261006-120000-000.png", app: "Safari", title: "Other"))
        try write("20261006-140000-000.json", sidecar(image: "20261006-140000-000.png", app: "Safari", title: "Docs"))
        // Not one of ours, though it says it is the same window and newer.
        try write("notes.json", sidecar(image: "20261006-125900-000.png", app: "Safari", title: "Docs"))
        try write("20261006-123000-000.json", "garbage")

        func previous(_ app: String?, _ title: String?) -> String? {
            ShotContext.previous(app: app, title: title, before: "20261006-130000-000.png", in: directory)
        }
        #expect(previous("Safari", "Docs") == "20261006-110000-000.png")
        #expect(previous("Safari", "Other") == "20261006-120000-000.png")
        #expect(previous("Safari", "Nothing") == nil)
        #expect(previous("Safari", nil) == nil)
        #expect(previous(nil, "Docs") == nil)
        #expect(ShotContext.previous(
            app: "Safari", title: "Docs", before: "20261006-130000-000.png",
            in: directory.appendingPathComponent("missing")) == nil)
    }
}
