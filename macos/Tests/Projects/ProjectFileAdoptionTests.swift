import Testing
import Foundation
@testable import Ghostty

/// Issue #23, option C: a project saved under an older filename rule is
/// found by what it contains, and moved to the current rule's name --
/// with everything that belongs to it -- the next time it is saved.
@Suite
struct ProjectFileAdoptionTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-adoption-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The floor for the sidecars: a move that takes the file and leaves
    /// the `.prev` or the snapshot directory behind leaves an orphan that
    /// nothing will ever look for, and a snapshot directory is up to the
    /// configured limit per pane.
    @Test func adoptionMovesTheFileAndEverythingThatBelongsToIt() throws {
        let dir = try makeDirectory()
        let legacy = dir.appendingPathComponent("a:b.json")
        let target = dir.appendingPathComponent("a_b.json")
        try Data("project".utf8).write(to: legacy)
        try Data("previous".utf8).write(to: ProjectFileWriter.previousURL(for: legacy))
        let legacySnapshots = ProjectScrollback.directory(forProjectFile: legacy)
        try FileManager.default.createDirectory(at: legacySnapshots, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: legacySnapshots.appendingPathComponent("0.snap"))

        #expect(try ProjectFileAdoption.adopt(legacy, as: target) == .adopted)

        #expect(try Data(contentsOf: target) == Data("project".utf8))
        #expect(try Data(contentsOf: ProjectFileWriter.previousURL(for: target)) == Data("previous".utf8))
        let snapshot = ProjectScrollback.directory(forProjectFile: target).appendingPathComponent("0.snap")
        #expect(try Data(contentsOf: snapshot) == Data("history".utf8))
        for left in [legacy] + ProjectFileAdoption.sidecars(of: legacy) {
            #expect(!exists(left), "\(left.lastPathComponent) left behind")
        }
    }

    /// Two files claiming one name: nothing is touched, nothing is lost.
    @Test func aTakenTargetIsNeverOverwritten() throws {
        let dir = try makeDirectory()
        let legacy = dir.appendingPathComponent("a:b.json")
        let target = dir.appendingPathComponent("a_b.json")
        try Data("old".utf8).write(to: legacy)
        try Data("new".utf8).write(to: target)

        #expect(try ProjectFileAdoption.adopt(legacy, as: target) == .targetTaken)
        #expect(try Data(contentsOf: legacy) == Data("old".utf8))
        #expect(try Data(contentsOf: target) == Data("new".utf8))
    }

    /// Interrupted after the sidecars moved and before the file did: the
    /// next save finds the legacy file and finishes the job.
    @Test func anInterruptedAdoptionFinishesNextTime() throws {
        let dir = try makeDirectory()
        let legacy = dir.appendingPathComponent("a:b.json")
        let target = dir.appendingPathComponent("a_b.json")
        try Data("project".utf8).write(to: legacy)
        try Data("previous".utf8).write(to: ProjectFileWriter.previousURL(for: target))

        #expect(try ProjectFileAdoption.adopt(legacy, as: target) == .adopted)
        #expect(try Data(contentsOf: target) == Data("project".utf8))
        #expect(try Data(contentsOf: ProjectFileWriter.previousURL(for: target)) == Data("previous".utf8))
        #expect(!exists(legacy))
    }

    /// A project is found by what its file says, not by recomputing its
    /// filename: the rule's file when there is one, otherwise the older
    /// file that names it.
    @Test func locateFindsAnOlderFileByItsContents() {
        let dir = URL(fileURLWithPath: "/p")
        let legacy = (url: dir.appendingPathComponent("a:b.json"), file: ProjectFile(name: "a:b", savedAt: 0, root: nil, nextScrollback: nil))
        let other = (url: dir.appendingPathComponent("c.json"), file: ProjectFile(name: "c", savedAt: 0, root: nil, nextScrollback: nil))
        let rule = dir.appendingPathComponent("a_b.json")

        #expect(ProjectListing.locate(name: "a:b", ruleFile: rule, listed: [other, legacy]) == legacy.url)
        let current = (url: rule, file: legacy.file)
        #expect(ProjectListing.locate(name: "a:b", ruleFile: rule, listed: [legacy, current]) == rule)
        #expect(ProjectListing.locate(name: "gone", ruleFile: dir.appendingPathComponent("gone.json"), listed: [other]) == nil)
    }
}
