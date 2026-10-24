import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// What starting a supervisor says of the one the group last had, whether
/// "go on with the last session / new session" is offered, and what the
/// start then sends (`ControlRoomStartChoice`).
///
/// **What these are not.** Whether a session can be gone on with, and why
/// not, are the core's and are tested there. That the view draws the
/// choice and the button sends it is in the app; nothing here starts it.
struct ControlRoomStartChoiceTests {
    typealias Choice = ControlRoomStartChoice
    typealias Start = ControlRoomList.SupervisorStart
    typealias Actions = ControlRoomActions

    private func start(cwd: String = "/Users/me/work", heard: Int64? = 1_700_000_000_000, lastCli: String? = "claude-code",
                       label: String? = "Claude Code", cwdIsLast: Bool = true, can: Bool = true,
                       why: Start.ResumeWhy = .none) -> Start {
        Start(state: .absent, canStart: true, failed: .none, role: "polter-supervisor", cwd: cwd,
              last: .init(cli: "claude-code", role: "polter-supervisor", lastCli: lastCli, heardMs: heard,
                          canResume: can, why: why, cwdIsTheLastSupervisors: cwdIsLast,
                          cliLabel: "Claude Code", lastCliLabel: label))
    }

    // MARK: Which agent CLI (task 1677)

    private func twoClis(last lastCli: String = "codex", byCli: [Start.CliResume]) -> (Start, [ControlRoomList.SupervisorRole]) {
        var s = start(lastCli: lastCli, label: lastCli == "codex" ? "Codex" : "Claude Code")
        s.last?.cli = lastCli
        s.last?.byCli = byCli
        let role = ControlRoomList.SupervisorRole(
            key: "polter-supervisor", name: "Polter Supervisor",
            clis: [.init(key: "claude-code", label: "Claude Code"), .init(key: "codex", label: "Codex")])
        return (s, [role])
    }

    /// 01a/01b: the core's CLI is on until another is picked; picking one
    /// that cannot go on with the session greys "Go on" and says whose it
    /// was; nothing is sent for the session then, and the CLI always is.
    @Test func pickingAnotherCliGreysGoingOnAndSaysWhy() {
        let (s, roles) = twoClis(byCli: [.init(cli: "claude-code", can: false, why: .cliDiffers),
                                         .init(cli: "codex", can: true, why: .none)])
        let none = Choice.cliChoice(s, roles: roles, role: nil, picked: nil)
        #expect(none.shown && none.picked == "codex" && none.resume == .live)
        #expect(Choice.sessionSent(none, picked: nil) == .last)
        #expect(Choice.resumeSaid(none, last: s.last) == nil)

        let other = Choice.cliChoice(s, roles: roles, role: nil, picked: "claude-code")
        #expect(other.picked == "claude-code" && other.resume == .greyed && other.why == .cliDiffers)
        #expect(Choice.sessionSent(other, picked: .last) == nil)
        #expect(Choice.resumeSaid(other, last: s.last) == "The last session was Codex's; Claude Code can't go on with it.")

        // A pick the role does not list is not kept.
        #expect(Choice.cliChoice(s, roles: roles, role: nil, picked: "other-cli").picked == "codex")
    }

    /// No CLI can go on with it: "Didn't find the last session" over a new
    /// one (task 1741), with the core's reason on hover and not on a line of
    /// its own. One CLI: no row (01c).
    @Test func withNothingToGoOnWithOrOneCliTheScreenIsTodays() throws {
        let (s, roles) = twoClis(byCli: [.init(cli: "claude-code", can: false, why: .cliDiffers),
                                         .init(cli: "codex", can: false, why: .sessionInUse)])
        let c = Choice.cliChoice(s, roles: roles, role: nil, picked: "claude-code")
        #expect(c.resume == .missing)
        #expect(Choice.resumeSaid(c, last: s.last) == nil)
        #expect(Choice.resumeTooltip(c, last: s.last) == Choice.resumeNote(.cliDiffers))
        let one = [ControlRoomList.SupervisorRole(key: "polter-supervisor", name: "P", clis: [.init(key: "codex", label: "Codex")])]
        #expect(!Choice.cliChoice(s, roles: one, role: nil, picked: nil).shown)
        // A core from before `resume_by_cli` has one answer, and it is the
        // answer whatever is picked (`scene::resume_for`): nothing here is
        // worked out in its place. Such a core sends one CLI anyway.
        var old = start()
        old.last?.byCli = []
        #expect(Choice.cliChoice(old, roles: roles, role: nil, picked: nil).resume == .live)
        #expect(Choice.cliChoice(old, roles: roles, role: nil, picked: "codex").resume == .live)
        // With the per-CLI table, a CLI it gives no answer for -- and that
        // is not the one its `resume` is about -- is not gone on with.
        var partial = s
        partial.last?.byCli = [.init(cli: "codex", can: true, why: .none)]
        #expect(Choice.resume(try #require(partial.last), for: "claude-code") == (false, .cliDiffers))
    }

    @Test func theCliPickedIsSent() throws {
        let request = Actions.request(for: .startSupervisor(group: "g", session: nil, cli: "codex"))
        #expect(request["cli"] as? String == "codex")
        #expect(Actions.request(for: .startSupervisor(group: "g"))["cli"] == nil)
    }

    /// An Agent CLI of the person's own is offered as a preset is (task
    /// 2156): the core puts it in the role's list under its own name, so
    /// the row shows it and picking it sends its key.
    @Test func anAgentCliOfThePersonsOwnIsOfferedAndSentByItsKey() throws {
        var s = start(lastCli: "claude-deepseek-flash", label: "Claude · DeepSeek flash")
        s.last?.cli = "claude-deepseek-flash"
        s.last?.byCli = [.init(cli: "claude-code", can: false, why: .cliDiffers),
                         .init(cli: "claude-deepseek-flash", can: true, why: .none)]
        let role = ControlRoomList.SupervisorRole(
            key: "polter-supervisor", name: "Polter Supervisor",
            clis: [.init(key: "claude-code", label: "Claude Code"),
                   .init(key: "claude-deepseek-flash", label: "Claude · DeepSeek flash")])
        // The core's own default is the one it was started in, and it is the
        // one "Go on" is about.
        let none = Choice.cliChoice(s, roles: [role], role: nil, picked: nil)
        #expect(none.shown && none.room == 2)
        #expect(none.picked == "claude-deepseek-flash")
        #expect(none.resume == .live)
        #expect(none.clis.map(\.key) == ["claude-code", "claude-deepseek-flash"])
        // Picked, its key is what the start carries.
        let picked = Choice.cliChoice(s, roles: [role], role: nil, picked: "claude-deepseek-flash")
        #expect(picked.picked == "claude-deepseek-flash")
        let request = Actions.request(for: .startSupervisor(group: "g", session: nil, cli: picked.picked))
        #expect(request["cli"] as? String == "claude-deepseek-flash")
        // Its base's plugin off: it is held back, and said so rather than
        // hidden.
        var off = role
        off.heldBack = [.init(key: "claude-deepseek-flash", label: "Claude · DeepSeek flash", why: .pluginOff)]
        off.clis = [.init(key: "claude-code", label: "Claude Code")]
        var last = s
        last.last?.lastCli = "claude-deepseek-flash"
        #expect(Choice.cliChoice(last, roles: [off], role: nil, picked: nil).clis.map(\.key) == ["claude-code"])
    }

    // MARK: The choice

    @Test func theChoiceIsOfferedOnlyWhenTheCoreSaysTheLastSessionCanBeGoneOnWith() {
        let can = Choice.offersSession(start(can: true))
        #expect(can == true)
        let cannot = Choice.offersSession(start(can: false, why: .sessionInUse))
        #expect(cannot == false)
        // A core that says nothing of a last supervisor, and no start at all.
        var old = start()
        old.last = nil
        let silent = Choice.offersSession(old)
        #expect(silent == false)
        let none = Choice.offersSession(nil)
        #expect(none == false)
    }

    @Test func whatIsSentIsWhatIsSelectedAndNothingWhenNoChoiceIsOnScreen() {
        // On screen: the last session until the person picks the other.
        let byDefault = Choice.sessionSent(offered: true, picked: nil)
        #expect(byDefault == .last)
        let new = Choice.sessionSent(offered: true, picked: .new)
        #expect(new == .new)
        let back = Choice.sessionSent(offered: true, picked: .last)
        #expect(back == .last)
        // Not on screen: nothing is said, whatever was picked while it was.
        for picked in [nil, Choice.Session.last, .new] {
            let sent = Choice.sessionSent(offered: false, picked: picked)
            #expect(sent == nil)
        }
    }

    @Test func theStartCarriesTheSessionInTheCoresTwoWordsAndLeavesItOutWhenThereIsNone() throws {
        func sent(_ session: Choice.Session?) throws -> [String: Any] {
            let request = Actions.request(for: .startSupervisor(group: "nightly", role: nil, cwd: nil, session: session))
            return try #require(request as [String: Any]?)
        }
        let last = try sent(.last)
        #expect(last["session"] as? String == "last")
        let new = try sent(.new)
        #expect(new["session"] as? String == "new")
        let none = try sent(nil)
        #expect(none["session"] == nil)
        #expect(none.count == 2)
        // The two words are the core's (`ControlAct.zig`, `Session`).
        #expect(Choice.Session.allCases.map(\.rawValue) == ["last", "new"])
    }

    @Test func theTwoOptionsAreCalledDifferently() {
        let last = Choice.optionText(.last)
        let new = Choice.optionText(.new)
        #expect(!last.isEmpty && !new.isEmpty)
        #expect(last != new)
    }

    // MARK: What the last supervisor was

    @Test func theSameDirectoryIsNotSaidTwice() throws {
        // The line above already shows where this start will be. Until the
        // person picks elsewhere that is the last supervisor's directory,
        // and saying it again was the same path twice in three lines.
        let unpicked = try #require(Choice.lastSupervisorText(start(), home: "/Users/me"))
        #expect(!unpicked.contains("work"))
        #expect(unpicked.contains("Claude Code"))
        // Picked, and the same one: still not said.
        let same = Choice.lastSupervisorText(start(), startingIn: "/Users/me/work", home: "/Users/me")
        #expect(same == unpicked)
    }

    @Test func theLastDirectoryIsSaidOnceThePersonHasPickedAnother() throws {
        let moved = try #require(Choice.lastSupervisorText(start(), startingIn: "/srv/other", home: "/Users/me"))
        // The directory as it is shown everywhere else: home as a tilde.
        #expect(moved.contains("~/work"))
        #expect(!moved.contains("/Users/me"))
        #expect(!moved.contains("/srv/other"))
        #expect(moved.contains("Claude Code"))
        // With no CLI written down, the directory alone.
        let alone = try #require(Choice.lastSupervisorText(start(lastCli: nil), startingIn: "/srv/other", home: "/Users/me"))
        #expect(alone.contains("~/work"))
        #expect(!alone.contains("Claude"))
    }

    @Test func aDirectoryThatIsNotTheLastSupervisorsOwnIsNeverSaid() throws {
        // The core names a directory for the start in every case; only
        // `cwd_from: last_supervisor` makes it that supervisor's.
        let guessed = try #require(
            Choice.lastSupervisorText(start(cwdIsLast: false), startingIn: "/srv/other", home: "/Users/me"))
        #expect(!guessed.contains("work"))
        #expect(guessed.contains("Claude Code"))
        let nowhere = try #require(Choice.lastSupervisorText(start(cwd: ""), startingIn: "/srv/other", home: "/Users/me"))
        #expect(nowhere == guessed)
    }

    @Test func theCliIsCalledWhatTheCoreCallsItAndByItsKeyWhenTheCoreHasNoName() throws {
        let named = try #require(Choice.lastSupervisorText(start(), home: "/Users/me"))
        #expect(named.contains("Claude Code"))
        #expect(!named.contains("claude-code"))
        // No name, or an empty one: the key, which is all there is.
        for label in [nil, ""] as [String?] {
            let keyed = try #require(Choice.lastSupervisorText(start(label: label), home: "/Users/me"))
            #expect(keyed.contains("claude-code"))
            #expect(!keyed.contains("Claude Code"))
        }
        // A name for a CLI nobody wrote down names nothing.
        let none = Choice.cliName(key: nil, label: "Claude Code")
        #expect(none == nil)
        let empty = Choice.cliName(key: "", label: "Claude Code")
        #expect(empty == nil)
    }

    @Test func nothingIsSaidOfASupervisorThatWasNeverRecordedOrOfWhichNothingIsKnown() {
        // No moment it was heard from is no record at all.
        let never = Choice.lastSupervisorText(start(heard: nil), startingIn: "/srv/other", home: "/Users/me")
        #expect(never == nil)
        // Recorded, with no CLI written down and the directory already on
        // the line above: nothing left to say.
        let bare = Choice.lastSupervisorText(start(lastCli: nil), home: "/Users/me")
        #expect(bare == nil)
        let emptyCli = Choice.lastSupervisorText(start(lastCli: ""), home: "/Users/me")
        #expect(emptyCli == nil)
        var old = start()
        old.last = nil
        let silent = Choice.lastSupervisorText(old, home: "/Users/me")
        #expect(silent == nil)
        let none = Choice.lastSupervisorText(nil, home: "/Users/me")
        #expect(none == nil)
    }

    @Test func theDirectoryIsTheLastSupervisorsOnlyWhenTheCoreSaysHowItWasArrivedAt() throws {
        let fixture = String(decoding: try ControlRoomListTests.fixture(), as: UTF8.self)
        func isLast(_ json: String) throws -> [Bool] {
            try ControlRoomList.decode(snapshot: Data(json.utf8)).rows.map { $0.start?.last?.cwdIsTheLastSupervisors ?? false }
        }
        // Every group in the fixture has a directory arrived at another way.
        let asWritten = try isLast(fixture)
        #expect(asWritten.count == 8)
        #expect(!asWritten.contains(true))
        // The first one in the file, said to be where its supervisor last worked.
        let at = try #require(fixture.range(of: "\"cwd_from\": \"home\""))
        let said = try isLast(fixture.replacingCharacters(in: at, with: "\"cwd_from\": \"last_supervisor\""))
        #expect(said.filter { $0 }.count == 1)
        // And the names the core gives the two CLIs are read beside them.
        let rows = try ControlRoomList.decode(snapshot: Data(fixture.utf8)).rows
        let billing = try #require(rows.first { $0.id == "billing" }?.start?.last)
        #expect(billing.cliLabel == "Claude Code")
        #expect(billing.lastCliLabel == "Claude Code")
        let web = try #require(rows.first { $0.id == "web-app" }?.start?.last)
        #expect(web.lastCli == nil)
        #expect(web.lastCliLabel == nil)
        #expect(web.cliLabel == "Claude Code")
        // Any other way of arriving at it is not that.
        for other in ["session_snapshot", "members", "none"] {
            let none = try isLast(fixture.replacingCharacters(in: at, with: "\"cwd_from\": \"\(other)\""))
            #expect(!none.contains(true), "\(other)")
        }
    }

    // MARK: Why not

    @Test func everyReasonForNotGoingOnHasItsOwnSentenceAndTheTwoThatNeedNoneHaveNone() {
        let quiet: [Start.ResumeWhy] = [.none, .noRecord]
        for why in quiet {
            let said = Choice.resumeNote(why)
            #expect(said == nil, "\(why)")
        }
        let spoken = Start.ResumeWhy.allCases.filter { !quiet.contains($0) }
        #expect(spoken.count == 6)
        let sentences = spoken.compactMap { Choice.resumeNote($0) }
        #expect(sentences.count == 6)
        #expect(Set(sentences).count == 6)
        let empty = sentences.contains { $0.isEmpty }
        #expect(!empty)
    }

    @Test func theReasonThatWillChangeByItselfDoesNotSayANewSessionWillBeStarted() throws {
        // `clis_unread`: what the CLIs can do has not been read yet, and it
        // will be. Saying "a new session will be started" there would be
        // saying something that is about to stop being true.
        let checking = try #require(Choice.resumeNote(.clisUnread))
        let settled = try #require(Choice.resumeNote(.sessionInUse))
        #expect(checking.hasSuffix("…"))
        #expect(!settled.hasSuffix("…"))
    }

    // MARK: Looking for it (task 1741)

    private func unread(_ s: Start) -> Start {
        var u = s
        u.clisRead = false
        u.last?.canResume = false
        u.last?.why = .clisUnread
        let byCli = (s.last?.byCli ?? []).map { Start.CliResume(cli: $0.cli, can: false, why: .clisUnread) }
        u.last?.byCli = byCli
        return u
    }

    /// While the adapters are read the session is being looked for: no
    /// button until the person picks a new session, and then that is sent.
    @Test func whileLookingTheStartWaitsUnlessANewSessionIsPicked() {
        let (s, roles) = twoClis(byCli: [.init(cli: "claude-code", can: false, why: .cliDiffers),
                                         .init(cli: "codex", can: true, why: .none)])
        let u = unread(s)
        let c = Choice.cliChoice(u, roles: roles, role: nil, picked: nil)
        #expect(c.resume == .checking)
        let waits = Choice.startEnabled(c, picked: nil)
        #expect(!waits)
        let goOnIsNotPickable = Choice.startEnabled(c, picked: .last)
        #expect(!goOnIsNotPickable)
        let afterNew = Choice.startEnabled(c, picked: .new)
        #expect(afterNew)
        #expect(Choice.sessionSent(c, picked: nil) == nil)
        #expect(Choice.sessionSent(c, picked: .new) == .new)
        #expect(Choice.resumeSaid(c, last: u.last) == nil)
        #expect(Choice.resumeTooltip(c, last: u.last) == nil)
        // Found: the two sessions, the last one on, and the button back.
        let found = Choice.cliChoice(s, roles: roles, role: nil, picked: nil)
        #expect(found.resume == .live)
        #expect(Choice.startEnabled(found, picked: nil))
    }

    /// The last supervisor's CLI is not installed here (task 1744): not
    /// found, and the hover says why.
    @Test func notFoundBecauseItsCliIsGoneSaysSoOnHover() {
        var (s, roles) = twoClis(last: "opencode", byCli: [.init(cli: "claude-code", can: false, why: .cliDiffers),
                                                       .init(cli: "codex", can: false, why: .cliDiffers)])
        s.last?.lastCliLabel = "opencode"
        roles[0].heldBack = [.init(key: "opencode", label: "opencode", why: .notInstalled)]
        let c = Choice.cliChoice(s, roles: roles, role: nil, picked: nil)
        #expect(c.resume == .missing)
        #expect(Choice.startEnabled(c, picked: nil))
        #expect(Choice.sessionSent(c, picked: nil) == nil)
        #expect(Choice.resumeTooltip(c, last: s.last) == "opencode, which the last supervisor used, is not installed on this machine.")
    }

    /// Never a supervisor: nothing to look for, so nothing waits.
    @Test func withNoRecordNothingIsLookedForAndNothingWaits() {
        let (s, roles) = twoClis(byCli: [])
        var never = unread(s)
        never.last?.heardMs = nil
        never.last?.why = .noRecord
        let c = Choice.cliChoice(never, roles: roles, role: nil, picked: nil)
        #expect(c.resume == .hidden)
        #expect(Choice.startEnabled(c, picked: nil))
    }

    /// The CLI's name not read yet: the sentence is cut where it goes, for
    /// a bar there and never the key.
    @Test func aNameNotReadYetIsAPlaceInTheSentence() throws {
        let read = start(lastCli: "claude-code", label: nil)
        #expect(Choice.lastSupervisorParts(read) == nil)
        let parts = try #require(Choice.lastSupervisorParts(unread(read)))
        #expect(parts.before == "The last supervisor used ")
        #expect(parts.after == ".")
        let keyless = !(parts.before + parts.after).contains("claude-code")
        #expect(keyless)
    }
}

/// Where the start button is drawn while the last session is looked for and
/// once it is found (task 1741): in a real hosting view, in a real window
/// that is never shown, read from what the view tells a screen reader.
@MainActor struct ControlRoomStartLayoutTests {
    typealias Start = ControlRoomList.SupervisorStart
    typealias Role = ControlRoomList.SupervisorRole

    private final class Seen {
        var button: CGRect?
        var all: CGRect?
    }

    /// The button's frame and the whole start's in `start` with `roles`,
    /// on a right-hand side `width` wide, laid out as the side lays it out
    /// (`ControlRoomStartSupervisor.ButtonFrame`, `.Frame`).
    private func laid(_ start: Start, _ roles: [Role], width: CGFloat) throws -> (button: CGRect, all: CGRect) {
        let seen = Seen()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.contentView = NSHostingView(rootView: ControlRoomDetailMessage(
            detail: .noSupervisor(group: "billing"), askFor: {}, start: start, roles: roles)
            .onPreferenceChange(ControlRoomStartSupervisor.ButtonFrame.self) { seen.button = $0 }
            .onPreferenceChange(ControlRoomStartSupervisor.Frame.self) { seen.all = $0 })
        window.setContentSize(NSSize(width: width, height: 600))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        return (try #require(seen.button), try #require(seen.all))
    }

    /// As the macOS test machine had it: the role is set up for Claude Code
    /// and Antigravity, and only Antigravity is installed. While the
    /// adapters are read both are offered, as two bars; the read holds
    /// Claude Code back, and one CLI is no row. Its room stays, so the
    /// button does not move -- nor when Claude Code is installed after --
    /// on a wide side and on the 230 points the side is in a window of the
    /// size it opens at, where nothing is wider than the side either.
    @Test(arguments: [600, 230] as [CGFloat])
    func aCliTheReadTakesAwayLeavesItsRoomAndTheButtonStays(width: CGFloat) throws {
        let found = Start(state: .absent, canStart: true, failed: .none, role: "polter-supervisor", cwd: "/Users/me/work",
                          last: .init(cli: "agy", role: "polter-supervisor", lastCli: "agy", heardMs: 1_700_000_000_000,
                                      canResume: true, why: .none, cliLabel: "Antigravity", lastCliLabel: "Antigravity",
                                      byCli: [.init(cli: "agy", can: true, why: .none)]))
        var looking = found
        looking.clisRead = false
        looking.last?.canResume = false
        looking.last?.why = .clisUnread
        looking.last?.byCli = [.init(cli: "claude-code", can: false, why: .clisUnread),
                               .init(cli: "agy", can: false, why: .clisUnread)]
        let both = [Role(key: "polter-supervisor", name: "Polter Supervisor",
                         clis: [.init(key: "claude-code", label: "Claude Code"), .init(key: "agy", label: "Antigravity")])]
        let one = [Role(key: "polter-supervisor", name: "Polter Supervisor",
                        clis: [.init(key: "agy", label: "Antigravity")],
                        heldBack: [.init(key: "claude-code", label: "Claude Code", why: .notInstalled)])]
        // The case itself: two to choose from while looking, none once read.
        let whileLooking = ControlRoomStartChoice.cliChoice(looking, roles: both, role: nil, picked: nil)
        let once = ControlRoomStartChoice.cliChoice(found, roles: one, role: nil, picked: nil)
        #expect(whileLooking.shown && whileLooking.resume == .checking)
        #expect(!once.shown && once.resume == .live)

        let wait = try laid(looking, both, width: width)
        let gone = try laid(found, one, width: width)
        let installed = try laid(found, both, width: width)
        let foundAt = gone.button
        #expect(foundAt == wait.button)
        #expect(installed.button == foundAt)
        // Nothing wider than the side, in any of the three.
        for drawn in [wait.all, gone.all, installed.all] {
            let inside = drawn.minX >= 0 && drawn.maxX <= width
            #expect(inside, "\(drawn) on a side \(width) wide")
        }
    }
}
