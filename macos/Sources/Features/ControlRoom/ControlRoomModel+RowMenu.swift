import AppKit

/// The small things the group row's menu keeps while it works (task 1660).
enum ControlRoomRowMenuState {
    /// A row's name made a field.
    struct Renaming: Equatable {
        var row: String
        var draft: String
        /// Why the name as it stands is refused; nil when it is not.
        var refusal: String?
    }

    /// The note open in the panel at the right.
    struct NoteEditing: Equatable {
        var group: String
        /// What the note is, as last saved: what "discard" goes back to.
        var saved: String
        var draft: String
        /// Why the last save was refused; nil when it was not.
        var refusal: String?
    }

    /// The line under a row: what the supervisor was asked, or why
    /// something the menu did was refused.
    struct RowLine: Equatable {
        var text: String
        var delivered: Bool
        /// Told apart from a later line on the same row, so that folding
        /// away an old one does not take a new one with it.
        var serial: Int
        /// A line saying the core will try again: what was asked, and the
        /// message it is about once a snapshot has said (task 1671).
        var retry: Retry?

        struct Retry: Equatable {
            var ask: ControlRoomGroupWords.Ask
            var on: UInt64?
        }
    }

    /// What the menu does outside the control room. `system` is the real
    /// one; a test hands in its own.
    struct Effects {
        var reveal: (URL) -> Void
        var copy: (String) -> Void
        /// Ask, and hand the answer -- whether the button that acts was
        /// chosen -- to the closure, now or later.
        var ask: (ControlRoomGroupAlerts.Question, @escaping (Bool) -> Void) -> Void
        var now: () -> Date
        var calendar: Calendar
        /// Run this after so many seconds, on the main queue.
        var after: (TimeInterval, @escaping () -> Void) -> Void
        /// Say something that has no row to stand under any more.
        var tell: (String) -> Void
        /// "Let the control room take over…": the group, and the core's
        /// question to ask before it (#1635). Nil is the model's own
        /// `takeOver(group:question:)`; a test hands in its own.
        var takeOver: ((String, String) -> Void)? = nil

        static var system: Effects {
            Effects(
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                // On the control room's window, which is the key one when
                // its list's menu was used.
                ask: { question, answer in question.ask(on: NSApp.keyWindow, answer) },
                now: Date.init,
                calendar: .current,
                after: { seconds, run in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: run) },
                tell: { ControlRoomGroupAlerts.tell($0, on: NSApp.keyWindow) })
        }
    }
}

extension ControlRoomModel {
    typealias Row = ControlRoomList.Row

    // MARK: Which menu

    /// The state the rule asks, for `row`. Whether there is a supervisor,
    /// and whether it was started by hand and can be taken over, is the
    /// rule's own `supervisor(of:)` (#1635), which both hosts share.
    func menuState(_ row: Row) -> ControlRoomRowMenu.State {
        let facts = row.facts
        return ControlRoomRowMenu.State(
            archived: false,
            supervisor: ControlRoomRowMenu.supervisor(of: row),
            resumable: ControlRoomStartChoice.offersSession(row.start),
            pinned: facts?.pinned ?? false,
            muted: facts?.muted ?? false,
            clis: max(1, startClis(row).count))
    }

    /// The CLIs a supervisor for `row` can be started in: those of the role
    /// the core would start it in, whose plugins are on (task 1677).
    func startClis(_ row: Row) -> [ControlRoomList.SupervisorRole.Cli] {
        guard let role = row.start?.role else { return [] }
        return list?.supervisorRoles.first { $0.key == role }?.clis ?? []
    }

    /// The state for an archived group: the rule's three items.
    static let archivedState = ControlRoomRowMenu.State(
        archived: true, supervisor: .none, resumable: false, pinned: false, muted: false)

    /// What stands at an item's right for `row`: until when each length of
    /// mute would last, or until when it does.
    func trailing(_ key: String, for row: Row) -> String? {
        let now = effects.now()
        let locale = Locale.current
        // 02A: going on names the CLI it goes on in, and asks nothing; in
        // the submenu of CLIs the last supervisor's says so.
        if let cli = ControlRoomRowMenu.cli(of: key) {
            return cli == row.start?.last?.lastCli ? ControlRoomRowMenuItems.lastUsedText : nil
        }
        switch key {
        case "start_resume" where startClis(row).count > 1:
            let last = row.start?.last
            return ControlRoomStartChoice.cliName(key: last?.lastCli, label: last?.lastCliLabel)
        case "mute_hour": return ControlRoomGroupWords.muteEndText(.hour, now: now, calendar: effects.calendar, locale: locale)
        case "mute_tomorrow": return ControlRoomGroupWords.muteEndText(.tomorrow, now: now, calendar: effects.calendar, locale: locale)
        case "unmute":
            let until = row.facts?.mutedUntilMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            return ControlRoomGroupWords.mutedUntilText(until, now: now, calendar: effects.calendar, locale: locale)
        default: return nil
        }
    }

    /// Whether an item can be chosen for `row`. Only the project's submenu
    /// greys anything: open is for a group bound to a project, save and
    /// link for one that is not. Until the project actions are wired here
    /// (they are the project store's), all three are grey.
    func enabled(_ key: String, for row: Row) -> Bool {
        switch key {
        case "open_project", "save_project", "link_project": return false
        default: return true
        }
    }

    /// The menu for `row`.
    @MainActor
    func menu(for row: Row) -> NSMenu {
        let state = menuState(row)
        let clis = startClis(row)
        let lines = ControlRoomRowMenuItems.lines(
            ControlRoomRowMenu.entries(state),
            startNew: state.clis > 1
                ? ControlRoomRowMenu.cliSubmenu(clis.map(\.key), last: row.start?.last?.lastCli).map(\.id) : nil)
        return ControlRoomRowMenuItems.menu(
            lines,
            title: { key in
                ControlRoomRowMenu.cli(of: key).flatMap { cli in
                    ControlRoomStartChoice.cliName(key: cli, label: clis.first { $0.key == cli }?.label)
                }
            },
            trailing: { [weak self] in self?.trailing($0, for: row) },
            enabled: { [weak self] in self?.enabled($0, for: row) ?? false },
            choose: { [weak self] in self?.choose($0, on: row) })
    }

    /// The menu for a group in "Archived".
    @MainActor
    func menu(forArchived group: ControlRoomList.ArchivedGroup) -> NSMenu {
        let lines = ControlRoomRowMenuItems.lines(ControlRoomRowMenu.entries(Self.archivedState))
        return ControlRoomRowMenuItems.menu(lines) { [weak self] key in
            self?.chooseArchived(key, group)
        }
    }

    // MARK: What each does

    func choose(_ key: String, on row: Row) {
        let group = row.id
        switch key {
        case "jump_to_supervisor":
            choose(group)
            goToSupervisor()
        case "take_over":
            // The core's question, as the frame's own button asks it; the
            // rule offers the item only when there is one.
            if let question = row.supervisor?.takeOver?.confirm {
                if let hand = effects.takeOver {
                    hand(group, question)
                } else {
                    takeOver(group: group, question: question)
                }
            }
        case "start_resume":
            startSupervisor(for: group, role: nil, cwd: nil, session: .last)
        case "start_new":
            startSupervisor(for: group, role: nil, cwd: nil, session: .new)
        case let key where ControlRoomRowMenu.cli(of: key) != nil:
            startSupervisor(for: group, role: nil, cwd: nil, session: .new, cli: ControlRoomRowMenu.cli(of: key))
        case "start":
            startSupervisor(for: group, role: nil, cwd: nil)
        case "report_progress":
            ask(.reportProgress, of: row)
        case "close_idle_workers":
            ask(.closeIdleWorkers, of: row)
        case "reveal":
            if let dir = row.facts?.recordDir { effects.reveal(URL(fileURLWithPath: dir, isDirectory: true)) }
        case "copy_supervisor_id":
            if let steward = row.facts?.steward { effects.copy(steward) }
        case "pin":
            act(.pin(group: group), on: group)
        case "unpin":
            act(.unpin(group: group), on: group)
        case "mute_hour":
            mute(row, for: .hour)
        case "mute_tomorrow":
            mute(row, for: .tomorrow)
        case "mute_forever":
            mute(row, for: .forever)
        case "unmute":
            act(.unmute(group: group), on: group)
        case "rename":
            beginRename(row)
        case "edit_note":
            // Its supervisor beside it, as the design has the two.
            choose(group)
            openNote(row)
        case "archive":
            archive(row)
        case "delete":
            let facts = row.facts
            delete(group, project: facts?.project, cost: facts?.deleteCost, supervisor: facts?.steward != nil)
        default:
            break
        }
    }

    func chooseArchived(_ key: String, _ group: ControlRoomList.ArchivedGroup) {
        switch key {
        case "reveal":
            if let dir = group.recordDir { effects.reveal(URL(fileURLWithPath: dir, isDirectory: true)) }
        case "unarchive":
            act(.unarchive(group: group.name), on: group.name)
        case "delete":
            delete(group.name, project: nil, cost: group.deleteCost, supervisor: false)
        default:
            break
        }
    }

    /// One act on a group; a refusal is said under its row.
    @discardableResult
    func act(_ act: ControlRoomActions.Act, on row: String) -> Bool {
        do {
            try perform(act)
            return true
        } catch {
            say(Self.refusal(error).message, under: row, delivered: false)
            return false
        }
    }

    static func refusal(_ error: Error) -> ControlRoomActions.Refusal {
        error as? ControlRoomActions.Refusal ?? ControlRoomActions.Refusal(name: "Refused")
    }

    func mute(_ row: Row, for length: ControlRoomGroupWords.MuteFor) {
        let end = ControlRoomGroupWords.muteEnd(length, now: effects.now(), calendar: effects.calendar)
        act(.mute(group: row.id, untilMs: end.map { UInt64(($0.timeIntervalSince1970 * 1000).rounded()) }), on: row.id)
    }

    // MARK: The line under a row

    /// Put `text` under `row`. One that says something was done folds away
    /// after `group_note.feedback_seconds`; one that says it was not stays
    /// until the next is put there (design v21 `07`).
    func say(_ text: String, under row: String, delivered: Bool, retry: ControlRoomRowMenuState.RowLine.Retry? = nil) {
        let serial = (rowLines.values.map(\.serial).max() ?? 0) + 1
        rowLines[row] = .init(text: text, delivered: delivered, serial: serial, retry: retry)
        guard delivered else { return }
        effects.after(ControlRoomLook.GroupNote.feedbackSeconds) { [weak self] in
            guard let self, self.rowLines[row]?.serial == serial else { return }
            self.rowLines[row] = nil
        }
    }

    /// Ask the supervisor something: the core types a sentence of its own
    /// into its terminal. What is said is that it was asked, or why the
    /// sentence did not go in.
    func ask(_ ask: ControlRoomGroupWords.Ask, of row: Row) {
        do {
            try perform(.askSupervisor(group: row.id, ask: ask))
            say(ControlRoomGroupWords.asked(ask), under: row.id, delivered: true)
        } catch {
            let name = Self.refusal(error).name
            say(ControlRoomGroupWords.notDelivered(ControlRoomGroupWords.askReason(name)),
                under: row.id, delivered: false,
                retry: ControlRoomGroupWords.triedAgain(name) ? .init(ask: ask, on: nil) : nil)
        }
    }

    /// A new list may say how an ask being tried again ended (task 1671):
    /// the line says it went in, and folds away, or says why it was given
    /// up on. The ask's own answer could only say it would be tried again.
    func followAsks(in list: ControlRoomList) {
        for (row, line) in rowLines {
            guard let retry = line.retry else { continue }
            let said = list.rows.first { $0.id == row && $0.alone == nil }?.facts?.ask
            switch ControlRoomRowMenu.followAsk(waitingOn: retry.on, ask: said) {
            case .keep:
                break
            case .wait(let seq):
                rowLines[row]?.retry?.on = seq
            case .delivered:
                say(ControlRoomGroupWords.asked(retry.ask), under: row, delivered: true)
            case .gaveUp(let code):
                say(ControlRoomGroupWords.notDelivered(ControlRoomGroupWords.askReason(code, willTryAgain: false)),
                    under: row, delivered: false)
            }
        }
    }

    // MARK: Renaming

    func beginRename(_ row: Row) {
        renaming = .init(row: row.id, draft: row.id, refusal: nil)
    }

    /// What the field says as it is typed in: only "empty" is the host's
    /// to say before Return; the core's two are said when it refuses.
    func renameTyped(_ text: String) {
        guard var r = renaming else { return }
        r.draft = text
        r.refusal = text.trimmingCharacters(in: .whitespaces).isEmpty ? ControlRoomGroupWords.emptyName : nil
        renaming = r
    }

    /// Return, or the keyboard leaving the field. Nothing happens while the
    /// name is refused; the same name ends it with nothing sent.
    func submitRename() {
        guard let r = renaming, r.refusal == nil else { return }
        let to = r.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if to == r.row {
            renaming = nil
            return
        }
        do {
            try perform(.renameGroup(from: r.row, to: to))
            renaming = nil
            // Selected again once the core lists it by its new name.
            if selection == r.row { madeGroup = to }
        } catch {
            renaming?.refusal = Self.refusal(error).message
        }
    }

    func cancelRename() {
        renaming = nil
    }

    // MARK: The note

    func openNote(_ row: Row) {
        let brief = row.facts?.brief ?? ""
        noteEditing = .init(group: row.id, saved: brief, draft: brief, refusal: nil)
    }

    func saveNote() {
        guard let n = noteEditing else { return }
        do {
            try perform(.setBrief(group: n.group, brief: n.draft))
            noteEditing = nil
        } catch {
            noteEditing?.refusal = Self.refusal(error).message
        }
    }

    /// Close the panel, giving up what was not saved.
    func closeNote() {
        noteEditing = nil
    }

    // MARK: Archiving and deleting

    func archive(_ row: Row) {
        let question = ControlRoomGroupAlerts.archive(name: row.id, supervisorRunning: row.facts?.steward != nil)
        effects.ask(question) { [weak self] yes in
            guard yes else { return }
            self?.act(.archive(group: row.id), on: row.id)
        }
    }

    /// Ask, and delete with the two counts the question showed. The core
    /// refuses with `Stale` when they changed meanwhile; then nothing was
    /// deleted, and the question is asked again with the counts as they now
    /// are, once.
    func delete(_ group: String, project: String?, cost: ControlRoomSnapshot.DeleteCost?, supervisor: Bool, again: Bool = false) {
        let members = cost?.members ?? 0
        let tasks = cost?.open_tasks ?? 0
        let still = ControlRoomGroupWords.Still(
            supervisor: supervisor && members > 0, workers: max(0, members - (supervisor && members > 0 ? 1 : 0)), openTasks: tasks)
        effects.ask(ControlRoomGroupAlerts.delete(name: group, project: project, still: still)) { [weak self] yes in
            guard let self, yes else { return }
            do {
                try self.perform(.deleteGroup(group: group, members: members, openTasks: tasks))
            } catch let refusal as ControlRoomActions.Refusal where refusal.name == "Stale" && !again {
                // As the core now has it.
                let now = self.list?.rows.first { $0.id == group }?.facts
                let archived = self.list?.archived.first { $0.name == group }
                self.delete(group, project: project, cost: now?.deleteCost ?? archived?.deleteCost,
                            supervisor: now?.steward != nil, again: true)
            } catch let refusal as ControlRoomActions.Refusal where refusal.name == "DeleteFailed" {
                // The group is off the list already: there is no row left
                // to say it under.
                self.effects.tell(refusal.message)
            } catch {
                self.say(Self.refusal(error).message, under: group, delivered: false)
            }
        }
    }
}
