import Testing
import Foundation
@testable import Ghostty

/// A project's colour (task 1796): the key in its file, the colour a new
/// project is given, and the mark's glow it is drawn with.
@Suite
struct ProjectColorTests {
    private func file(color: String?, format: Int = 3) -> Data {
        let key = color.map { ",\"color\":\($0)" } ?? ""
        return Data(
            "{\"format\":\(format),\"name\":\"p\",\"saved_at\":1,\"root\":{\"kind\":\"moved-to-windows\"}\(key),\"windows\":[]}".utf8)
    }

    // MARK: The file

    @Test func everyProjectColourReadsBackAndIsWrittenAfterTheGroup() throws {
        for tone in ProjectTone.order {
            let read = try ProjectFile.decode(from: file(color: "\"\(tone.name)\""))
            #expect(read.color == tone)
            let bytes = String(decoding: try read.encoded(), as: UTF8.self)
            #expect(bytes.contains(",\"color\":\"\(tone.name)\",\"windows\""), "\(bytes)")
        }
    }

    /// Purple is the supervisor's; none is written by leaving the key out;
    /// anything else is no colour this build knows. Read as no colour, the
    /// next save would drop the one the user chose.
    @Test func anythingButAProjectColourIsDamaged() {
        for bad in ["\"purple\"", "\"none\"", "\"magenta\"", "\"\"", "5", "null"] {
            #expect(throws: (any Error).self, "\(bad)") { try ProjectFile.decode(from: file(color: bad)) }
        }
    }

    @Test func noKeyIsNoColourAndNoColourWritesNoKey() throws {
        let read = try ProjectFile.decode(from: file(color: nil))
        #expect(read.color == .none)
        #expect(!String(decoding: try read.encoded(), as: UTF8.self).contains("color"))
    }

    /// Before format 3 there was no such key, whatever is there.
    @Test func aFormat2FileHasNoColour() throws {
        #expect(try ProjectFile.decode(from: file(color: "\"teal\"", format: 2)).color == .none)
    }

    /// A save that changes only the colour is written: "nothing but the
    /// time changed" would have kept the colour off the disk.
    @Test func aChangedColourIsAWrite() throws {
        let old = try ProjectFile.decode(from: file(color: nil))
        let outcome = ProjectFileWriter.plan(writing: old.with(color: .green), over: try old.encoded(), keeping: .onLayoutChange)
        #expect(outcome == .written(rotated: false))
        #expect(ProjectFileWriter.plan(writing: old, over: try old.encoded(), keeping: .onLayoutChange) == .unchanged)
    }

    // MARK: The colour a project is given

    @Test func nothingUsedIsBlueAndTheOrderFollowsAfter() {
        var used: [PaneColor] = []
        for want in ProjectTone.order {
            let got = ProjectTone.pick(used: used)
            #expect(got == want, "after \(used)")
            used.append(got)
        }
        #expect(ProjectTone.pick(used: used) == .blue)
    }

    @Test func theLeastUsedWinsAndTiesGoToTheEarlier() {
        #expect(ProjectTone.pick(used: [.blue, .blue, .orange]) == .green)
        #expect(ProjectTone.pick(used: [.blue, .orange, .green, .pink, .teal, .yellow, .red, .graphite, .blue]) == .orange)
        #expect(ProjectTone.pick(used: [.orange]) == .blue)
        #expect(ProjectTone.pick(used: [.purple, .purple, .none]) == .blue)
    }

    @Test func aProjectMayBeEveryPaneColourButNoneAndPurple() {
        #expect(PaneColor.allCases.filter { !ProjectTone.order.contains($0) } == [.none, .purple])
        for c in PaneColor.allCases {
            #expect((ProjectTone.named(c.name) != nil) == ProjectTone.order.contains(c), "\(c)")
        }
    }

    // MARK: The mark

    @Test func theGlowIsRoundStrongestOffTheMarkAndNoneAtItsEdge() {
        let g = ProjectMark.glow(scale: 2, strength: 1)
        let n = g.side
        #expect(n == Int(((ControlRoomLook.Status.artboard + 2 * g.reach) * 2).rounded(.up)))
        for y in 0..<n {
            for x in 0..<n {
                #expect(abs(g.at(x, y) - g.at(n - 1 - x, y)) < 1e-9)
                #expect(abs(g.at(x, y) - g.at(x, n - 1 - y)) < 1e-9)
            }
        }
        for i in 0..<n {
            #expect(g.at(i, 0) < 1e-3 && g.at(0, i) < 1e-3)
        }
        let mid = n / 2
        let core = Int((g.reach + ControlRoomLook.Status.artboard / 2) * 2)
        let outside = Int((g.reach - ControlRoomLook.ProjectMark.coreGap - 0.75) * 2)
        #expect(g.at(mid, core) < g.at(mid, outside))
        #expect(g.at(mid, core) > 0)
        #expect(g.a.allSatisfy { $0 <= ControlRoomLook.ProjectMark.glowStrength + 1e-9 })
    }

    @Test func aWeakerStateIsAWeakerGlow() {
        let full = ProjectMark.glow(scale: 1, strength: 1).total
        let rest = ProjectMark.glow(scale: 1, strength: ProjectMark.strength(.rest, dark: true)).total
        #expect(abs(rest / full - ControlRoomLook.ProjectMark.restDark) < 1e-9)
    }

    @Test func theFrontPageIsDrawnLastAndCutsTheBackOne() {
        #expect(ProjectMark.shapes.map(\.level) == [1, 0, 0, 1, 0])
    }
}
