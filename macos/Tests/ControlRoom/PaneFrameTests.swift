import Foundation
import Testing
@testable import Ghostty

/// Which frame a pane of a split wears, and whether it wears one at all
/// (`PaneFrame`).
struct PaneFrameTests {
    typealias Place = PaneFrame.Place
    typealias Drawn = PaneFrame.Drawn
    typealias Title = PaneFrame.Title

    /// The core's own fixture: seven supervisors, three workers and two
    /// terminals nobody minds.
    private func terminals() throws -> [ControlRoomSnapshot.Terminal] {
        let snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: ControlRoomListTests.fixture())
        return try #require(snapshot.terminals)
    }

    private let split = Place(enabled: true, quickTerminal: false, alone: false)
    private let alone = Place(enabled: true, quickTerminal: false, alone: true)

    private let supervisor = "0x00000000000000a1"
    private let worker = "0x00000000000000b1"
    private let waitingShell = "0x00000000000000c1"
    private let shell = "0x00000000000000c2"

    // MARK: Which of the three

    @Test func theFixtureSaysWhichFrameEveryTerminalWears() throws {
        let kinds = try terminals().map(\.pane)
        #expect(kinds == [
            .supervisor, .supervisor, .supervisor, .supervisor, .supervisor, .supervisor, .supervisor,
            .worker, .worker, .worker, .plain, .plain,
        ])
    }

    @Test func aPaneWearsTheFrameTheCoreNamesForItsTerminal() throws {
        let all = try terminals()
        let a = PaneFrame.drawn(terminal: supervisor, ownName: "", at: split, in: all)
        #expect(a?.wears == .supervisor)
        let b = PaneFrame.drawn(terminal: worker, ownName: "", at: split, in: all)
        #expect(b?.wears == .worker)
        let c = PaneFrame.drawn(terminal: shell, ownName: "", at: split, in: all)
        #expect(c?.wears == .plain)
    }

    @Test func theTitleIsTheTerminalsOwnNameGlyphAndWord() throws {
        let all = try terminals()
        let b = PaneFrame.drawn(terminal: worker, ownName: "not this", at: split, in: all)
        #expect(b?.title == Title(name: "web-app worker", shown: .needsYou, word: "等批准"))
        // Not the first one listed, and not another terminal's.
        let c = PaneFrame.drawn(terminal: shell, ownName: "not this", at: split, in: all)
        #expect(c?.title == Title(name: "zsh", shown: .none, word: ""))
    }

    @Test func anOrdinaryTerminalThatWaitsSaysSo() throws {
        let c = PaneFrame.drawn(terminal: waitingShell, ownName: "", at: split, in: try terminals())
        #expect(c == Drawn(wears: .plain, title: Title(name: "zsh — ~/work", shown: .needsYou, word: "等批准")))
    }

    // MARK: Alone in its tab

    @Test func anOrdinaryTerminalAloneInItsTabWearsNothing() throws {
        let c = PaneFrame.drawn(terminal: shell, ownName: "zsh", at: alone, in: try terminals())
        #expect(c == nil)
    }

    @Test func aSupervisorWearsItsFrameEvenAlone() throws {
        let a = PaneFrame.drawn(terminal: supervisor, ownName: "", at: alone, in: try terminals())
        #expect(a?.wears == .supervisor)
    }

    @Test func aWorkerWearsItsFrameEvenAlone() throws {
        let b = PaneFrame.drawn(terminal: worker, ownName: "", at: alone, in: try terminals())
        #expect(b?.wears == .worker)
    }

    // MARK: Off, and the quick terminal

    @Test func withTheSettingOffNothingIsFramed() throws {
        let all = try terminals()
        for place in [Place(enabled: false, quickTerminal: false, alone: false),
                      Place(enabled: false, quickTerminal: false, alone: true)] {
            for id in [supervisor, worker, shell] {
                let drawn = PaneFrame.drawn(terminal: id, ownName: "zsh", at: place, in: all)
                #expect(drawn == nil)
            }
        }
    }

    @Test func theQuickTerminalIsNeverFramed() throws {
        let all = try terminals()
        let place = Place(enabled: true, quickTerminal: true, alone: false)
        for id in [supervisor, worker, shell] {
            let drawn = PaneFrame.drawn(terminal: id, ownName: "zsh", at: place, in: all)
            #expect(drawn == nil)
        }
    }

    // MARK: A terminal the snapshot does not list

    @Test func aTerminalTheCoreHasNotListedIsAnOrdinaryOneUnderItsOwnName() throws {
        let all = try terminals()
        let unknown = PaneFrame.drawn(terminal: "0x00000000000000ff", ownName: "fish", at: split, in: all)
        #expect(unknown == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "")))
        let noID = PaneFrame.drawn(terminal: nil, ownName: "fish", at: split, in: all)
        #expect(noID == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "")))
        let noSnapshot = PaneFrame.drawn(terminal: supervisor, ownName: "fish", at: split, in: nil)
        #expect(noSnapshot == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "")))
        // And alone, that is nothing.
        let unknownAlone = PaneFrame.drawn(terminal: nil, ownName: "fish", at: alone, in: all)
        #expect(unknownAlone == nil)
    }

    @Test func aSnapshotFromBeforeTheCoreSaidWhichFrameDrawsAnOrdinaryOne() throws {
        let json = Data(#"{"id":"0x01","title":"old","shown":"working","text":"在干活"}"#.utf8)
        let old = try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        #expect(old.pane == nil)
        let drawn = PaneFrame.drawn(terminal: "0x01", ownName: "", at: split, in: [old])
        #expect(drawn == Drawn(wears: .plain, title: Title(name: "old", shown: .working, word: "在干活")))
    }

    @Test func aFrameTheHostDoesNotKnowIsAnErrorNotAnOrdinaryTerminal() {
        let json = Data(#"{"id":"0x01","title":"t","shown":"none","text":"","pane":"stacked"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        }
    }

    // MARK: The ground

    @Test func theGroundShowsAsSoonAsOnePaneIsFramed() {
        let framed = Drawn(wears: .worker, title: Title(name: "w", shown: .none, word: ""))
        #expect(PaneFrame.groundShows([nil, framed]))
        #expect(PaneFrame.groundShows([framed]))
        #expect(!PaneFrame.groundShows([nil]))
        #expect(!PaneFrame.groundShows([nil, nil]))
        #expect(!PaneFrame.groundShows([]))
    }

    // MARK: The word for what it is

    @Test func anOrdinaryTerminalHasNoWordForWhatItIs() {
        #expect(PaneFrame.roleWord(.plain) == nil)
        #expect(PaneFrame.roleWord(.supervisor) != nil)
        #expect(PaneFrame.roleWord(.worker) != nil)
        #expect(PaneFrame.roleWord(.supervisor) != PaneFrame.roleWord(.worker))
    }
}
