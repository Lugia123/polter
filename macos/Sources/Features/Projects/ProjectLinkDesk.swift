import AppKit
import Combine
import OSLog
import SwiftUI

/// The app's hands for a group's tie to a project (task 1713,
/// `project-link-interface.md` §3): what the group's "Project ›" menu, the
/// banner, the "join and link?" question and the line saying a project was
/// made ask to be done, carried out on real tabs and real files, and the
/// four acts sent to the core.
///
/// **Everything decided is decided in `ProjectLinkPlan` and
/// `ProjectLinkRules`**, which run without the app. None of this has been
/// run against a core or on a screen; that is said where it is handed
/// over.
@MainActor
final class ProjectLinkDesk: ControlRoomProjectHands {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "projects")

    private(set) static var shared: ProjectLinkDesk?

    static func start(_ ghostty: Ghostty.App) {
        guard shared == nil else { return }
        shared = ProjectLinkDesk(ghostty)
    }

    private let ghostty: Ghostty.App
    private let store = ProjectStore.shared
    private let hints = ProjectHints.shared
    private var listening: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    /// The projects as last listed; nil when a change has made it stale.
    private var listed: [ProjectLinkPlan.Project]?
    /// The core's `ask`, by group, as the last snapshot had it.
    private var asks: [String: Bool] = [:]
    private var asked = ProjectLinkPlan.Asked()
    /// A question is on a window.
    private var asking = false

    private init(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        hints.undoer = { [weak self] group, origin in
            MainActor.assumeIsolated { self?.undo(origin, group: group) }
        }
        listening = ControlRoomFeed.shared(ghostty).listen { [weak self] snapshot in
            MainActor.assumeIsolated { self?.heard(snapshot) }
        }
        let center = NotificationCenter.default
        for name in [ProjectStore.didWrite, ProjectStore.listDidChange, ProjectStore.bindingDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.listed = nil }
            })
        }
        // The person coming back: the moment a question that waited for
        // them may be put (v2 B 2).
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.considerAsking() }
            })
        }
    }

    private var actions: ControlRoomActions { ControlRoomActions.core(ghostty) }

    private func send(_ act: ControlRoomActions.Act) -> String? {
        do {
            try actions.perform(act)
            return nil
        } catch {
            return (error as? ControlRoomActions.Refusal ?? .init(name: "Refused")).message
        }
    }

    // MARK: What the core says

    private func heard(_ snapshot: ControlRoomSnapshot) {
        var stewards: [String: String] = [:]
        var asks: [String: Bool] = [:]
        for group in snapshot.groups {
            if let steward = group.steward { stewards[group.name] = steward }
            asks[group.name] = group.project?.ask ?? false
        }
        if hints.stewards != stewards { hints.stewards = stewards }
        self.asks = asks
        asked.heard(asks)
        considerAsking()
    }

    /// The supervisor of `group`, and the tab it is in.
    private func steward(of group: String) -> (TerminalController, Ghostty.SurfaceView)? {
        guard let terminal = ControlRoomFeed.shared(ghostty).latest?.groups.first(where: { $0.name == group })?.steward
        else { return nil }
        for controller in TerminalController.all {
            for view in controller.surfaceTree where ControlRoomLender.terminal(of: view) == terminal {
                return (controller, view)
            }
        }
        return nil
    }

    /// The group whose supervisor is in `controller`'s tab; nil for none.
    func supervisorGroup(in controller: TerminalController) -> String? {
        let terminals = controller.surfaceTree.compactMap(ControlRoomLender.terminal(of:))
        let groups = ControlRoomFeed.shared(ghostty).latest?.groups ?? []
        return ProjectLinkPlan.supervisorGroup(terminals: terminals, stewards: groups.map { ($0.name, $0.steward) })
    }

    // MARK: The line saying a project was made (§3.2)

    /// `ProjectLinker` carried out the core's `create` or `bind`.
    func made(_ origin: ProjectLinkPlan.Origin, for group: String) {
        hints.show(origin, for: group)
    }

    /// Undo, in the plan's order; the first thing that fails stops it and
    /// is said.
    private func undo(_ origin: ProjectLinkPlan.Origin, group: String) -> String? {
        for step in ProjectLinkPlan.undo(origin, group: group) {
            do {
                switch step {
                case .decline(let group):
                    if let refused = send(.projectDecline(group: group)) { return refused }
                case .letGo(let project):
                    letGo(project)
                case .trash(let project):
                    guard let entry = store.entry(name: project) else { throw ProjectStore.StoreError.notFound }
                    _ = try store.trash(entry)
                case .clearGroup(let project):
                    if let session = ProjectSession.open(for: project, in: store) {
                        session.setGroup(nil)
                    } else if let entry = store.entry(name: project) {
                        try store.setGroup(entry, to: nil)
                    }
                case .rename(let project, let to):
                    guard let entry = store.entry(name: project) else { throw ProjectStore.StoreError.notFound }
                    try store.rename(entry, to: to)
                case .restorePrevious(let project):
                    guard let entry = store.entry(name: project) else { throw ProjectStore.StoreError.notFound }
                    try store.restorePrevious(entry)
                }
            } catch {
                Self.logger.warning("undoing a project for '\(group, privacy: .public)' stopped: \(error.localizedDescription, privacy: .public)")
                return error.localizedDescription
            }
        }
        return nil
    }

    /// Every tab that is a page of `project` stops being one, the file
    /// left as it is and the terminals as they are.
    private func letGo(_ project: String) {
        for controller in TerminalController.all where controller.boundProject == project {
            controller.projectSession?.detach(controller, removing: false, saving: false)
        }
    }

    // MARK: ControlRoomProjectHands

    func projects() -> [ProjectLinkPlan.Project] {
        if let listed { return listed }
        let now = store.list().map {
            ProjectLinkPlan.Project(name: $0.name, group: $0.group, savedAt: $0.savedAt, pages: $0.pageCount)
        }
        listed = now
        return now
    }

    func open(project: String) {
        guard let entry = store.entry(name: project) else {
            tell(ProjectStore.StoreError.notFound.localizedDescription)
            return
        }
        do {
            if let room = ControlRoomController.shared {
                try room.loadProjectWhereTabsGo(entry)
            } else {
                try TerminalController.load(entry, ghostty: ghostty, into: nil, beside: TerminalController.preferredParent?.window)
            }
        } catch {
            tell(error.localizedDescription)
        }
    }

    func showInSettings(project: String?) {
        openSettings(.projects(project))
    }

    func unlink(group: String, project: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "No longer the group \(group)'s project?", comment: "不再作为群的项目：确认框标题，参数是群名")
        alert.informativeText = String(localized: "The project \"\(project)\" stays as it is, and its open tabs stay open. The group uses no project from now on.", comment: "不再作为群的项目：确认框正文，参数是项目名")
        let trash = NSButton(checkboxWithTitle: String(localized: "Also move the project file to the Trash", comment: "不再作为群的项目：同时把项目文件移到废纸篓（默认不勾）"), target: nil, action: nil)
        trash.state = .off
        trash.font = NSFont.menuFont(ofSize: 0)
        trash.sizeToFit()
        alert.accessoryView = trash
        alert.addButton(withTitle: String(localized: "No Longer This Group's Project", comment: "不再作为群的项目：确认按钮"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "项目选择界面：取消按钮")).keyEquivalent = "\u{1b}"
        present(alert) { [weak self] yes in
            guard let self, yes else { return }
            if let refused = self.send(.projectDecline(group: group)) { return self.tell(refused) }
            guard trash.state == .on else { return }
            self.letGo(project)
            do {
                guard let entry = self.store.entry(name: project) else { throw ProjectStore.StoreError.notFound }
                _ = try self.store.trash(entry)
            } catch {
                self.tell(error.localizedDescription)
            }
        }
    }

    func saveSupervisorTab(group: String) -> String? {
        guard let (controller, view) = steward(of: group) else {
            return ControlRoomActions.Refusal(name: "NoSupervisor").message
        }
        do {
            try ProjectSession.save([controller], as: group, keeping: .always, in: store)
            controller.projectSession?.setGroup(group)
            controller.projectSession?.makeSupervisor(view)
        } catch {
            return error.localizedDescription
        }
        return link(group: group, project: group)
    }

    func link(group: String, project: String) -> String? {
        // The core goes by what was last stated; a project saved a moment
        // ago is not in it until the next statement, and the link would be
        // refused (seen on poltertest, task 1713 ⑥).
        ProjectLinker.shared?.restateNow()
        do {
            try actions.perform(.projectLink(group: group, project: project))
            return nil
        } catch let refusal as ControlRoomActions.Refusal where refusal.name == "ProjectNameTaken" {
            // The project with the group's name is in the way: ask to put
            // it aside first, then link again.
            guard let entry = store.entry(name: group) else { return refusal.message }
            let aside = ProjectLinkPlan.asideName(group) { [store] in store.entry(name: $0) != nil }
            let alert = NSAlert()
            alert.messageText = ProjectLinkPlan.asideQuestion(group, to: aside)
            alert.addButton(withTitle: String(localized: "Rename and Link", comment: "关联时撞名：先改名再关联的按钮"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "项目选择界面：取消按钮")).keyEquivalent = "\u{1b}"
            present(alert) { [weak self] yes in
                guard let self, yes else { return }
                do {
                    try self.store.rename(entry, to: aside)
                } catch {
                    return self.tell(error.localizedDescription)
                }
                if let refused = self.send(.projectLink(group: group, project: project)) { self.tell(refused) }
            }
            return nil
        } catch {
            return (error as? ControlRoomActions.Refusal ?? .init(name: "Refused")).message
        }
    }

    func join(group: String, project: String) -> String? {
        guard let (controller, view) = steward(of: group) else {
            return ControlRoomActions.Refusal(name: "NoSupervisor").message
        }
        guard let entry = store.entry(name: project) else { return ProjectStore.StoreError.notFound.localizedDescription }
        do {
            // A file of an older format is written in this one, and kept
            // as it was as the previous version (`ProjectFileWriter.plan`).
            try ProjectSession.add(controller, to: entry, in: store)
            controller.projectSession?.makeSupervisor(view)
        } catch {
            return error.localizedDescription
        }
        // The core binds it at its next look: the supervisor's tab is in a
        // project of no group, named as the group is.
        hints.show(.joined(project: project), for: group)
        return nil
    }

    func replace(group: String, project: String) {
        guard let (controller, view) = steward(of: group) else {
            return tell(ControlRoomActions.Refusal(name: "NoSupervisor").message)
        }
        guard let blocker = projects().first(where: { $0.name == project }) else {
            return tell(ProjectStore.StoreError.notFound.localizedDescription)
        }
        let question = ProjectLinkPlan.replaceQuestion(blocker, tab: controller.projectTabTitle, panes: controller.surfaceTree.count)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.body + "\n\n" + question.after
        // Not red: the old one is kept, so nothing is destroyed.
        alert.addButton(withTitle: String(localized: "Replace", comment: "替换同名项目的二次确认：替换按钮"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "项目选择界面：取消按钮")).keyEquivalent = "\u{1b}"
        present(alert) { [weak self] yes in
            guard let self, yes else { return }
            do {
                try ProjectSession.save([controller], as: project, keeping: .always, in: self.store)
                controller.projectSession?.makeSupervisor(view)
            } catch {
                return self.tell(error.localizedDescription)
            }
            self.hints.show(.replaced(project: project), for: group)
        }
    }

    /// The tab's "Save as Project" was saved as `group`'s project, with
    /// the box ticked (§3.5): the file names the group, the supervisor's
    /// pane is marked when it is among the pages, and the core is told to
    /// link the two.
    func savedAsGroupProject(_ group: String) {
        let session = ProjectSession.open(for: group, in: store)
        session?.setGroup(group)
        if let session, let (controller, view) = steward(of: group), controller.projectSession === session {
            session.makeSupervisor(view)
        }
        if let refused = link(group: group, project: group) { tell(refused) }
    }

    func decline(group: String) -> String? { send(.projectDecline(group: group)) }

    func undecline(group: String) -> String? { send(.projectUndecline(group: group)) }

    // MARK: The question (v2 B1)

    private func front(of window: NSWindow) -> ProjectLinkPlan.Front {
        if window.windowController is ControlRoomController { return .controlRoom }
        return .other
    }

    /// Put the question for the first group the core asks about, when the
    /// person is there to answer it.
    private func considerAsking() {
        guard let window = NSApp.keyWindow else { return }
        for (group, ask) in asks.sorted(by: { $0.key < $1.key }) where ask {
            var front = front(of: window)
            if front == .other, let controller = window.windowController as? TerminalController,
               supervisorGroup(in: controller) == group {
                front = .stewardTab
            }
            guard ProjectLinkPlan.mayAsk(
                ask: ask, group: group,
                presence: .init(appActive: NSApp.isActive, windowKey: window.isKeyWindow, front: front,
                                sheetShowing: asking || window.attachedSheet != nil),
                asked: asked)
            else { continue }
            asked.asked(group)
            putQuestion(group, on: window)
            return
        }
    }

    private func putQuestion(_ group: String, on window: NSWindow) {
        guard let blocker = projects().first(where: { $0.name == group }) else { return }
        asking = true
        var sheet: NSWindow?
        let view = ProjectJoinSheet(
            question: ProjectLinkPlan.joinQuestion(blocker, group: group), group: group, blocker: blocker.name
        ) { [weak self, weak window] answer in
            if let sheet { window?.endSheet(sheet) }
            guard let self else { return }
            self.asking = false
            self.answered(answer, group: group, blocker: blocker.name)
        }
        let made = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet = made
        window.beginSheet(made)
    }

    private func answered(_ answer: ProjectJoinSheet.Answer, group: String, blocker: String) {
        switch answer {
        case .join:
            if let refused = join(group: group, project: blocker) { tell(refused) }
        case .replace:
            replace(group: group, project: blocker)
        case .later:
            if let refused = send(.projectNotNow(group: group)) { tell(refused) }
        case .decline:
            if let refused = send(.projectDecline(group: group)) { tell(refused) }
        }
    }

    // MARK: Saying

    private func present(_ alert: NSAlert, _ answer: @escaping (Bool) -> Void) {
        guard let window = NSApp.keyWindow else {
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            alert.window.orderOut(nil)
            answer(response == .alertFirstButtonReturn)
        }
    }

    private func tell(_ text: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Project Error", comment: "项目功能出错提醒标题")
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "项目功能出错提醒：确定按钮"))
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
