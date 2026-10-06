import Foundation
import Testing
@testable import Ghostty

/// The file rules of `dev-docs/poltergeist/screenshot.md`, section 5.
struct ShotStoreTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    /// 2026-10-06 15:30:12.123 UTC.
    private func date(millis: Int = 123) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 6, hour: 15, minute: 30, second: 12,
            nanosecond: millis * 1_000_000 + 500_000))!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL, modified: Date) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    // MARK: Directory

    @Test func theDefaultDirectoryIsUnderTheStateHome() {
        let withXDG = ShotStore.directory(
            configured: nil, environment: ["XDG_STATE_HOME": "/state"], home: home)
        #expect(withXDG.path == "/state/polter/shots")

        let withoutXDG = ShotStore.directory(configured: nil, environment: [:], home: home)
        #expect(withoutXDG.path == "/Users/someone/.local/state/polter/shots")

        // Set and empty is unset, as it is for every other state directory.
        let emptyXDG = ShotStore.directory(
            configured: nil, environment: ["XDG_STATE_HOME": ""], home: home)
        #expect(emptyXDG.path == "/Users/someone/.local/state/polter/shots")
    }

    @Test func aConfiguredDirectoryWinsAndATildeIsHome() {
        let env = ["XDG_STATE_HOME": "/state"]
        let absolute = ShotStore.directory(configured: "/work/project/shots", environment: env, home: home)
        #expect(absolute.path == "/work/project/shots")

        let tilde = ShotStore.directory(configured: "~/project/shots", environment: env, home: home)
        #expect(tilde.path == "/Users/someone/project/shots")

        // An empty value is no value, not the current directory.
        let empty = ShotStore.directory(configured: "", environment: env, home: home)
        #expect(empty.path == "/state/polter/shots")
    }

    // MARK: Names

    @Test func theNameIsLocalTimeToTheMillisecond() {
        #expect(ShotStore.stem(for: date(), timeZone: utc) == "20261006-153012-123")

        // The same instant, eight hours east.
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        #expect(ShotStore.stem(for: date(), timeZone: shanghai) == "20261006-233012-123")

        // Zero-padded, and the last millisecond of a second stays three digits.
        #expect(ShotStore.stem(for: date(millis: 7), timeZone: utc) == "20261006-153012-007")
        #expect(ShotStore.stem(for: date(millis: 999), timeZone: utc) == "20261006-153012-999")
    }

    @Test func aNameWeWriteIsANameWeRecognise() {
        let stem = ShotStore.stem(for: date(), timeZone: utc)
        #expect(ShotStore.isOurs(stem + ".png"))
        #expect(ShotStore.isOurs(stem + ".json"))
    }

    @Test func aNameThatOnlyLooksLikeOursIsNotOurs() {
        let notOurs = [
            "holiday.png",
            "20261006-153012-123.jpg",
            "20261006-153012-123.PNG",
            "20261006-153012-123",
            "20261006-153012-12.png",
            "20261006-153012-1234.png",
            "20261006_153012_123.png",
            "2026100a-153012-123.png",
            "x20261006-153012-123.png",
            "20261006-153012-123.png.bak",
            "20261006-153012-123 copy.png",
            // Digits, but not ASCII ones.
            "２０２６１００６-153012-123.png",
            ".png",
            "",
        ]
        for name in notOurs {
            #expect(!ShotStore.isOurs(name), "\(name) was taken for one of ours")
        }
    }

    @Test func aLongScreenshotsTilesAreOursToo() {
        let image = ShotStore.stem(for: date(), timeZone: utc) + ".png"
        #expect(ShotStore.tileName(of: image, 1) == "20261006-153012-123-1.png")
        #expect(ShotStore.tileName(of: image, 12) == "20261006-153012-123-12.png")
        for n in [1, 9, 10, 99, 100, 999] {
            #expect(ShotStore.isOurs(ShotStore.tileName(of: image, n)), "tile \(n)")
        }
        let notOurs = [
            // Only a picture has tiles.
            "20261006-153012-123-1.json",
            "20261006-153012-123-.png",
            "20261006-153012-123-1000.png",
            "20261006-153012-123-1a.png",
            "20261006-153012-123-a.png",
            "20261006-153012-123_1.png",
            "20261006-153012-123-1-2.png",
            "20261006-153012-123--1.png",
            "20261006-153012-123-１.png",
        ]
        for name in notOurs {
            #expect(!ShotStore.isOurs(name), "\(name) was taken for one of ours")
        }
    }

    @Test func theToolMemoryIsBesideTheDefaultDirectoryWhateverIsConfigured() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ShotStore.toolPrefsURL(environment: [:], home: home).path
            == "/Users/someone/.local/state/polter/shot-tools.json")
        #expect(ShotStore.toolPrefsURL(environment: ["XDG_STATE_HOME": "/var/state"], home: home).path
            == "/var/state/polter/shot-tools.json")
    }

    // MARK: Cleanup

    @Test func onlyOurOldFilesExpire() {
        let now = date()
        let day: TimeInterval = 24 * 60 * 60
        let old = now.addingTimeInterval(-8 * day)
        let recent = now.addingTimeInterval(-6 * day)

        let entries: [ShotStore.Entry] = [
            .init(name: "20260928-101010-001.png", modified: old),
            .init(name: "20260928-101010-001.json", modified: old),
            .init(name: "20260930-101010-001.png", modified: recent),
            // Old, and not ours: the user's own file in a directory they
            // pointed `screenshot-directory` at.
            .init(name: "holiday.png", modified: old),
            .init(name: "notes.json", modified: old),
            // Ours by name, but a directory.
            .init(name: "20260927-101010-001.png", modified: old, isRegularFile: false),
        ]

        #expect(ShotStore.expired(entries, now: now) == [
            "20260928-101010-001.png",
            "20260928-101010-001.json",
        ])
    }

    @Test func aFileExactlyAWeekOldIsKept() {
        let now = date()
        let week = ShotStore.maxAge
        let onTheLine = [ShotStore.Entry(name: "20260929-153012-123.png", modified: now.addingTimeInterval(-week))]
        #expect(ShotStore.expired(onTheLine, now: now).isEmpty)

        let justOver = [ShotStore.Entry(name: "20260929-153012-123.png", modified: now.addingTimeInterval(-week - 1))]
        #expect(ShotStore.expired(justOver, now: now) == ["20260929-153012-123.png"])
    }

    @Test func cleanupDeletesOurOldFilesAndLeavesEverythingElse() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)

        try touch(dir.appendingPathComponent("20260928-101010-001.png"), modified: old)
        try touch(dir.appendingPathComponent("20260928-101010-001.json"), modified: old)
        try touch(dir.appendingPathComponent("20261006-101010-001.png"), modified: now)
        try touch(dir.appendingPathComponent("holiday.png"), modified: old)

        let removed = ShotStore.cleanup(directory: dir, now: now).sorted()
        #expect(removed == ["20260928-101010-001.json", "20260928-101010-001.png"])

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["20261006-101010-001.png", "holiday.png"])
    }

    @Test func cleaningADirectoryThatIsNotThereIsNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotstore-missing-\(UUID().uuidString)")
        #expect(ShotStore.cleanup(directory: missing).isEmpty)
    }

    // MARK: Writing

    @Test func aWrittenFileIsOwnerOnlyInAnOwnerOnlyDirectory() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("a/b", isDirectory: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let url = try ShotStore.write(png: png, to: dir, date: date(), timeZone: utc)

        #expect(url.lastPathComponent == "20261006-153012-123.png")
        #expect(try Data(contentsOf: url) == png)

        let filePerms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(filePerms == 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
    }

    @Test func twoWritesInOneMillisecondAreTwoFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try ShotStore.write(png: Data([1]), to: dir, date: date(), timeZone: utc)
        let second = try ShotStore.write(png: Data([2]), to: dir, date: date(), timeZone: utc)

        #expect(first.lastPathComponent == "20261006-153012-123.png")
        #expect(second.lastPathComponent == "20261006-153012-124.png")
        // The first one's path may already be in a terminal: it is untouched.
        #expect(try Data(contentsOf: first) == Data([1]))
    }

    @Test func aStemWhoseSidecarExistsIsTaken() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir.appendingPathComponent("20261006-153012-123.json"), modified: Date())

        let url = try ShotStore.write(png: Data([1]), to: dir, date: date(), timeZone: utc)
        #expect(url.lastPathComponent == "20261006-153012-124.png")
    }
}
