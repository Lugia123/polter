import Foundation
import SwiftUI
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
        #expect(b?.title == Title(name: "web-app worker", shown: .needsYou, word: "Awaiting approval", badged: true))
        // Not the first one listed, and not another terminal's.
        let c = PaneFrame.drawn(terminal: shell, ownName: "not this", at: split, in: all)
        #expect(c?.title == Title(name: "zsh", shown: .none, word: "", badged: true))
    }

    @Test func anOrdinaryTerminalThatWaitsSaysSo() throws {
        let c = PaneFrame.drawn(terminal: waitingShell, ownName: "", at: split, in: try terminals())
        #expect(c == Drawn(wears: .plain, title: Title(name: "zsh — ~/work", shown: .needsYou, word: "Awaiting approval", badged: true)))
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
        #expect(unknown == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "", badged: true)))
        let noID = PaneFrame.drawn(terminal: nil, ownName: "fish", at: split, in: all)
        #expect(noID == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "", badged: true)))
        let noSnapshot = PaneFrame.drawn(terminal: supervisor, ownName: "fish", at: split, in: nil)
        #expect(noSnapshot == Drawn(wears: .plain, title: Title(name: "fish", shown: .none, word: "", badged: true)))
        // And alone, that is nothing.
        let unknownAlone = PaneFrame.drawn(terminal: nil, ownName: "fish", at: alone, in: all)
        #expect(unknownAlone == nil)
    }

    @Test func aSnapshotFromBeforeTheCoreSaidWhichFrameDrawsAnOrdinaryOne() throws {
        let json = Data(#"{"id":"0x01","title":"old","shown":"working","text":"在干活"}"#.utf8)
        let old = try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        #expect(old.pane == nil)
        let drawn = PaneFrame.drawn(terminal: "0x01", ownName: "", at: split, in: [old])
        #expect(drawn == Drawn(wears: .plain, title: Title(name: "old", shown: .working, word: "在干活", badged: true)))
    }

    @Test func aFrameTheHostDoesNotKnowIsAnErrorNotAnOrdinaryTerminal() {
        let json = Data(#"{"id":"0x01","title":"t","shown":"none","text":"","pane":"stacked"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        }
    }

    // MARK: The right end of the title: the core's pair

    private typealias Bar = ControlRoomSnapshot.Terminal.Bar

    @Test func theTitlesGlyphAndWordAreThePairTheCoreGivesForEveryTerminal() throws {
        let all = try terminals()
        for terminal in all {
            let bar = try #require(terminal.bar, "\(terminal.id) has no bar")
            let drawn = try #require(PaneFrame.drawn(terminal: terminal.id, ownName: "", at: split, in: all))
            #expect(drawn.title == Title(name: terminal.title, shown: bar.shown, word: bar.text, badged: true),
                    "\(terminal.id)")
        }
    }

    @Test func aHeldWorkerOfTheFixtureSaysHeldAndItsStatusIsUntouched() throws {
        let all = try terminals()
        // `tokens`: a worker that clocked off, and the person holds it.
        let held = try #require(all.first { $0.title == "tokens" })
        #expect(held.bar == Bar(shown: .held, text: "Held"))
        // What a row or a window tab would draw of it is still its status.
        #expect(held.shown == .none)
        #expect(held.text == "Off duty")
        let drawn = PaneFrame.drawn(terminal: held.id, ownName: "", at: split, in: all)
        #expect(drawn == Drawn(wears: .worker, title: Title(name: "tokens", shown: .held, word: "Held", badged: true)))
        // Exactly one of the fixture's terminals is held.
        let heldOnes = all.filter { $0.bar?.shown == .held }.map(\.title)
        #expect(heldOnes == ["tokens"])
    }

    @Test func theHostTakesThePairAsGivenAndWorksNothingOut() {
        // Whatever the status says: the title is the pair. Which wins when a
        // terminal is held and also waiting is the core's rule, not this.
        for status in ControlRoomList.Shown.allCases {
            for bar in Bar.Shown.allCases {
                let terminal = ControlRoomSnapshot.Terminal(
                    id: "0x01", title: "t", shown: status, text: "status", pane: .worker, bar: Bar(shown: bar, text: "pair"))
                let drawn = PaneFrame.drawn(terminal: "0x01", ownName: "", at: split, in: [terminal])
                #expect(drawn?.title == Title(name: "t", shown: bar, word: "pair", badged: true), "\(status) \(bar)")
            }
        }
    }

    @Test func aSnapshotFromBeforeTheCoreGaveThePairSaysTheStatus() throws {
        let json = Data(#"{"id":"0x01","title":"old","shown":"working","text":"在干活","pane":"worker"}"#.utf8)
        let old = try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        #expect(old.bar == nil)
        let drawn = PaneFrame.drawn(terminal: "0x01", ownName: "", at: split, in: [old])
        #expect(drawn?.title == Title(name: "old", shown: .working, word: "在干活", badged: true))
    }

    @Test func aGlyphTheHostDoesNotKnowIsAnErrorNotABlankTitle() {
        let json = Data(#"{"id":"0x01","title":"t","shown":"none","text":"","pane":"plain","bar":{"shown":"muted","text":"x"}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRoomSnapshot.Terminal.self, from: json)
        }
    }

    @Test func heldIsTheOnlyGlyphOfATitleThatIsNotAStatus() {
        for status in ControlRoomList.Shown.allCases {
            #expect(Bar.Shown(status).status == status)
        }
        let notAStatus = Bar.Shown.allCases.filter { $0.status == nil }
        #expect(notAStatus == [.held])
        // The control room's own frame: a supervisor's status, as it was.
        let title = Title(ControlRoomList.SupervisorTitle(name: "web-app", shown: .trouble, word: "出错"))
        #expect(title == Title(name: "web-app", shown: .trouble, word: "出错"))
    }

    @Test func theHeldGlyphIsTwoBarsInsideTheStatusGlyphsBox() {
        let side = CGFloat(ControlRoomLook.Side.glyph)
        let box = PaneHeldGlyph().path(in: CGRect(x: 0, y: 0, width: side, height: side)).boundingRect
        // The design's: from 3.8 to 10.2 across and 3 to 11 down, of 14.
        #expect(abs(box.minX - 3.8) < 0.01 && abs(box.maxX - 10.2) < 0.01)
        #expect(abs(box.minY - 3) < 0.01 && abs(box.maxY - 11) < 0.01)
        #expect(PaneHeldGlyph.bars.count == 2)
    }

    // MARK: The word after the name, when the title brings its own

    @Test func aControlRoomTitleBringsItsOwnWordAcross() {
        // The control room has one frame -- a supervisor's -- and shows in it
        // a terminal that may be a worker or neither. Whose word follows the
        // name comes with the title, and must still be there on the bar.
        for says in PaneFrame.Kind.allCases {
            let from = ControlRoomList.SupervisorTitle(name: "lone", shown: .needsYou, word: "等批准", says: says)
            let title = Title(from)
            #expect(title.says == says, "\(says)")
            #expect(title == Title(name: "lone", shown: .needsYou, word: "等批准", says: says))
            // In the supervisor's frame it says what the title says it is.
            #expect(title.roleWord(in: .supervisor) == PaneFrame.roleWord(says), "\(says)")
        }
        // An ordinary terminal in the supervisor's frame says nothing; a
        // worker there says it is a worker, not a supervisor.
        let plain = Title(ControlRoomList.SupervisorTitle(name: "zsh", shown: .none, word: "", says: .plain))
        #expect(plain.roleWord(in: .supervisor) == nil)
        let worker = Title(ControlRoomList.SupervisorTitle(name: "w", shown: .none, word: "", says: .worker))
        #expect(worker.roleWord(in: .supervisor) == PaneFrame.roleWord(.worker))
        #expect(worker.roleWord(in: .supervisor) != PaneFrame.roleWord(.supervisor))
    }

    @Test func aTitleThatBringsNoWordSaysWhatItsFrameIsAndAPaneOfASplitNeverBringsOne() throws {
        // A group's supervisor in the control room: no word of its own.
        let group = Title(ControlRoomList.SupervisorTitle(name: "web-app", shown: .working, word: "在干活"))
        #expect(group.says == nil)
        #expect(group.roleWord(in: .supervisor) == PaneFrame.roleWord(.supervisor))
        // Every pane of a split: the frame is what it is.
        let all = try terminals()
        for terminal in all {
            let drawn = try #require(PaneFrame.drawn(terminal: terminal.id, ownName: "", at: split, in: all))
            #expect(drawn.title.says == nil, "\(terminal.id)")
            #expect(drawn.title.roleWord(in: drawn.wears) == PaneFrame.roleWord(drawn.wears), "\(terminal.id)")
        }
        let unlisted = try #require(PaneFrame.drawn(terminal: nil, ownName: "fish", at: split, in: all))
        #expect(unlisted.title.says == nil)
        #expect(Title(name: "t", shown: .none, word: "").says == nil)
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

    // MARK: The supervisor's badge and edge (task 1692)

    @Test func theBadgeIsOnASupervisorsPaneOfASplitAndNotInTheControlRoom() throws {
        for wears in PaneFrame.Kind.allCases {
            #expect(Title(name: "t", shown: .none, word: "", badged: true).badge(in: wears) == (wears == .supervisor), "\(wears)")
            #expect(!Title(name: "t", shown: .none, word: "").badge(in: wears), "\(wears)")
        }
        // Every pane of a split the core says is a supervisor's, and no other.
        let all = try terminals()
        for terminal in all {
            let drawn = try #require(PaneFrame.drawn(terminal: terminal.id, ownName: "", at: split, in: all))
            #expect(drawn.title.badge(in: drawn.wears) == (terminal.pane == .supervisor), "\(terminal.id)")
        }
        // The control room's frame never has one, whoever it shows.
        for says in [nil] + PaneFrame.Kind.allCases.map(Optional.some) {
            let title = Title(ControlRoomList.SupervisorTitle(name: "web-app", shown: .working, word: "在干活", says: says))
            #expect(!title.badge(in: .supervisor), "\(String(describing: says))")
        }
    }

    @Test func withNoFramesOnlyTheSupervisorsPaneHasTheEdgeAloneOrNot() throws {
        let all = try terminals()
        let off = Place(enabled: false, quickTerminal: false, alone: false)
        let offAlone = Place(enabled: false, quickTerminal: false, alone: true)
        for place in [off, offAlone] {
            for terminal in all {
                #expect(PaneFrame.edged(terminal: terminal.id, at: place, in: all) == (terminal.pane == .supervisor), "\(terminal.id) \(place)")
            }
            #expect(!PaneFrame.edged(terminal: nil, at: place, in: all))
            #expect(!PaneFrame.edged(terminal: "0x00000000000000ee", at: place, in: all))
            #expect(!PaneFrame.edged(terminal: supervisor, at: place, in: nil))
        }
        // With frames it wears its frame and has no edge; nor in the quick terminal.
        #expect(!PaneFrame.edged(terminal: supervisor, at: split, in: all))
        #expect(!PaneFrame.edged(terminal: supervisor, at: alone, in: all))
        #expect(!PaneFrame.edged(terminal: supervisor, at: Place(enabled: false, quickTerminal: true, alone: true), in: all))
    }
}
