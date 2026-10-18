import AppKit
import Combine
import GhosttyKit

/// "Save as Project", "Load Project", and "Manage Projects" -- reachable
/// from the tab context menu (targeting the right-clicked tab, see
/// `TerminalWindow.configureTabContextMenuIfNeeded`) and from the `Project`
/// menu (targeting the focused tab via the responder chain, see
/// `MainMenu.xib`).
///
/// A tab is a page of at most one project, and the project -- not the tab
/// -- is what writes the file: see `ProjectSession`. What is here is the
/// tab's side of that: the menu actions, and telling the session what
/// changed.
extension TerminalController {
    /// The terminal tabs of this tab's window, in the order they stand:
    /// what "Save as Project" lists.
    private var tabsOfThisWindow: [TerminalController] {
        let windows = window?.tabGroup?.windows ?? window.map { [$0] } ?? []
        return windows.compactMap { $0.windowController as? TerminalController }
    }

    @IBAction func saveAsProject(_ sender: Any?) {
        presentSaveAsProject { _ in }
    }

    /// Show "Save as Project" for this tab's window. `done` is told whether
    /// a save happened and worked.
    private func presentSaveAsProject(done: @escaping (Bool) -> Void) {
        let controllers = tabsOfThisWindow
        let tabs = controllers.enumerated().map { index, controller in
            ProjectPageRules.Tab(
                id: index,
                title: controller.projectTabTitle,
                panes: controller.surfaceTree.count,
                project: controller.boundProject,
                isCurrent: controller === self)
        }
        projectPicker.presentSaveAs(
            tabs: tabs,
            onSave: { [weak self] name, ids in
                guard let self else { return }
                var saved = false
                // A save that fails is reported and is not a save
                // (`ProjectSaveBeforeClose.saveThenClose` is that rule).
                ProjectSaveBeforeClose.saveThenClose(
                    save: {
                        // Save As: a name that is taken is a replacement,
                        // and what it held is kept as the previous version,
                        // whatever its layout (#969). A new name has
                        // nothing to keep either way.
                        try ProjectSession.save(
                            ids.compactMap { controllers.indices.contains($0) ? controllers[$0] : nil },
                            as: name, keeping: .always, in: ProjectStore.shared)
                    },
                    reportFailure: { self.presentProjectError($0) },
                    close: { saved = true })
                done(saved)
            },
            onCancel: { done(false) })
    }

    @IBAction func loadProject(_ sender: Any?) {
        projectPicker.present(
            mode: .load,
            onLoad: { [weak self] entry in
                self?.performLoad(entry)
            })
    }

    /// The Projects section of the settings window, on this tab's project
    /// (settings.md §3.2).
    @IBAction func manageProjects(_ sender: Any?) {
        openSettings(.projects(boundProject))
    }

    /// The line at the top of the `Project` menu. It does nothing and is
    /// never offered: it is there to be read.
    @IBAction func projectMenuHeader(_ sender: Any?) {}

    /// "Add to Project ▸ <name>" on a tab's own menu: the project's name is
    /// the item's `representedObject`.
    @IBAction func addToProject(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        do {
            guard let entry = ProjectStore.shared.entry(name: name) else { throw ProjectStore.StoreError.notFound }
            try ProjectSession.add(self, to: entry, in: ProjectStore.shared)
        } catch {
            presentProjectError(error)
        }
    }

    /// "Take This Page Out of the Project": the tab stays open and is a tab
    /// of no project; the project no longer has the page.
    @IBAction func takeOutOfProject(_ sender: Any?) {
        do {
            try takeOutOfProject()
        } catch {
            presentProjectError(error)
        }
    }

    /// Take this page out of its project -- after asking the core, which
    /// does not allow it for the page a group's supervisor is on
    /// (`ProjectLinker.askToRemove`).
    private func takeOutOfProject() throws {
        guard let session = projectSession else { return }
        try ProjectLinker.shared?.askToRemove(self)
        session.detach(self, removing: true)
    }

    /// "Close Project": every open page of this tab's project closes, and
    /// every one stays a page. Asked about once, for all of them, when
    /// something is still running in one.
    @IBAction func closeProject(_ sender: Any?) {
        guard let session = projectSession else { return }
        guard session.needsConfirmToClose else {
            session.closeAllPages()
            return
        }
        confirmClose(
            messageText: String(localized: "Close Project?", comment: "关闭项目的确认框标题"),
            informativeText: String(localized: "A terminal of this project still has a running process. If you close the project the process will be killed.", comment: "关闭项目的确认框正文")
        ) {
            session.closeAllPages()
        }
    }

    /// "Rename Project…": asks for the new name on a sheet and renames the
    /// project's file, with everything that goes with it
    /// (`ProjectStore.rename`); its open pages follow.
    @IBAction func renameProject(_ sender: Any?) {
        guard let window, let name = boundProject, let entry = ProjectStore.shared.entry(name: name) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Project", comment: "给项目改名的框标题")
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.font = NSFont.systemFont(ofSize: SettingsFont.minimumPointSize)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename", comment: "给项目改名的框：改名按钮"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", comment: "项目选择界面：取消按钮"))
        cancel.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                // Asked of the core first; a group's project is renamed by
                // the order that follows (`ProjectLinker.rename`).
                if let linker = ProjectLinker.shared {
                    try linker.rename(entry, to: field.stringValue)
                } else {
                    try ProjectStore.shared.rename(entry, to: field.stringValue)
                }
            } catch {
                self?.presentProjectError(error)
            }
        }
    }

    /// What the `Project` menu's items say and whether each is offered for
    /// this tab (`ProjectPageRules`). Nil for an item that is not one of
    /// them.
    func validateProjectMenuItem(_ item: NSMenuItem) -> Bool? {
        let project = boundProject
        switch item.action {
        case #selector(projectMenuHeader(_:)):
            item.title = ProjectPageRules.menuHeader(project: project)
            return false
        case #selector(saveAsProject(_:)): return ProjectPageRules.offered(.saveAs, pageOf: project)
        case #selector(loadProject(_:)): return ProjectPageRules.offered(.open, pageOf: project)
        case #selector(manageProjects(_:)): return ProjectPageRules.offered(.manage, pageOf: project)
        case #selector(addToProject(_:)): return ProjectPageRules.offered(.addTo, pageOf: project)
        case #selector(renameProject(_:)): return ProjectPageRules.offered(.rename, pageOf: project)
        case #selector(closeProject(_:)): return ProjectPageRules.offered(.closeProject, pageOf: project)
        case #selector(takeOutOfProject(_:)):
            item.title = ProjectPageRules.takeOutTitle(project: project)
            return ProjectPageRules.offered(.takeOut, pageOf: project)
        default:
            return nil
        }
    }

    // MARK: Closing a Page

    /// Run `close` for this one tab, after asking -- where
    /// `ProjectPageRules.closeStep` says to ask -- whether the page should
    /// be taken out of its project as well. Cancel leaves the tab open.
    func askAboutProjectPage(thenClose close: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let choice = defaults.string(forKey: ProjectPageRules.closeChoiceKey)
            .flatMap(ProjectPageRules.CloseChoice.init(rawValue:)) ?? .ask
        let step = ProjectPageRules.closeStep(
            pageOf: boundProject,
            otherPagesOpen: projectSession?.otherPagesOpen(than: self) ?? 0,
            scope: .tab,
            choice: choice)

        func finish(takingOut: Bool) {
            if takingOut {
                do {
                    try takeOutOfProject()
                } catch {
                    // Not taken out, so not closed either: the person asked
                    // for both, and is told why one cannot be.
                    presentProjectError(error)
                    return
                }
            }
            close()
        }

        guard step == .ask, let window, let project = boundProject else {
            if case .close(let takingOut) = step { finish(takingOut: takingOut) } else { close() }
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Close the page \"\(projectTabTitle)\"", comment: "关掉项目里的一页的询问框标题，参数是这一页的标题")
        alert.informativeText = String(localized: "It is a page of the project \"\(project)\". If you only close it, it comes back the next time the project is opened.", comment: "关掉项目里的一页的询问框正文，参数是项目名")
        let takeOut = NSButton(checkboxWithTitle: String(localized: "Also take it out of the project", comment: "关掉项目里的一页：同时把它从项目里移出"), target: nil, action: nil)
        let dontAsk = NSButton(checkboxWithTitle: String(localized: "Don't ask again (do as chosen this time)", comment: "关掉项目里的一页：以后不再问（照这次选的做）"), target: nil, action: nil)
        let font = NSFont.systemFont(ofSize: SettingsFont.minimumPointSize)
        takeOut.font = font
        dontAsk.font = font
        let stack = NSStackView(views: [takeOut, dontAsk])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Close", comment: "关闭确认框"))
        // Esc is bound explicitly: NSAlert only binds it on its own to a
        // button titled "Cancel" in English.
        alert.addButton(withTitle: String(localized: "Cancel", comment: "项目选择界面：取消按钮")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            alert.window.orderOut(nil)
            guard response == .alertFirstButtonReturn else { return }
            let takingOut = takeOut.state == .on
            let remembered = ProjectPageRules.choice(
                afterTakingOut: takingOut, dontAskAgain: dontAsk.state == .on, was: choice)
            if remembered != choice {
                defaults.set(remembered.rawValue, forKey: ProjectPageRules.closeChoiceKey)
            }
            finish(takingOut: takingOut)
        }
    }

    // MARK: Close Flow

    /// Presents "Save as a Project Before Closing?" in place of the plain
    /// "this will kill the running process" warning, for a tab (or a
    /// window that reduces to one tab -- see the `closeWindow` call site)
    /// whose surfaces need confirmation to close.
    ///
    /// Choosing to save opens the same picker as "Save as Project", and
    /// `closeAction` only runs once a save actually succeeds; cancelling out
    /// of the picker, or a save that fails, leaves the terminal open.
    /// Choosing not to save runs `closeAction` immediately. Cancel (or Esc)
    /// on the alert itself leaves it open -- see `ProjectSaveBeforeClose`.
    func presentSaveAsProjectBeforeClosing(closeAction: @escaping () -> Void) {
        guard let window else {
            closeAction()
            return
        }

        // A bound tab is already saved -- asking whether to save it as a
        // project would be asking a question whose answer is already on
        // disk. Fall back to the ordinary running-process warning, which has
        // a way out; the last change and the scrollback are written when the
        // tab actually closes (`saveBoundProjectOnClose`), not here, so
        // choosing Cancel writes nothing.
        if boundProject != nil {
            confirmClose(
                messageText: String(localized: "Close Terminal?", comment: "关闭确认框"),
                informativeText: String(localized: "The terminal still has a running process. If you close the terminal the process will be killed.", comment: "关闭确认框")
            ) {
                closeAction()
            }
            return
        }
        guard !isPresentingCloseSaveAlert else { return }
        isPresentingCloseSaveAlert = true

        let alert = ProjectSaveBeforeClose.makeAlert()

        alert.beginSheetModal(for: window) { [weak self] response in
            // Important so we don't lose focus when Stage Manager is used
            // (matches `confirmCloseAsync`, #8336).
            alert.window.orderOut(nil)
            guard let self else { closeAction(); return }
            self.isPresentingCloseSaveAlert = false

            switch ProjectSaveBeforeClose.choice(for: response) {
            case .keepOpen:
                return
            case .closeWithoutSaving:
                closeAction()
            case .save:
                // Cancelling the sheet, or a save that fails (which the
                // sheet reports), keeps the tab open too.
                self.presentSaveAsProject { saved in
                    if saved { closeAction() }
                }
            }
        }
    }

    // MARK: Store Operations

    /// Save this tab as the project `name` and make it that project's page.
    /// Throws rather than reporting, so a caller that has something riding
    /// on the save -- closing the tab, the settings window's "Overwrite
    /// with Current Tab" -- can tell whether it worked. `keeping` is
    /// `.always` when this replaces a project with the tab.
    func saveAndBind(name: String, keeping: ProjectFileWriter.Keeping) throws {
        try ProjectSession.save([self], as: name, keeping: keeping, in: ProjectStore.shared)
    }

    private func performLoad(_ entry: ProjectStore.Entry) {
        do {
            try Self.load(entry, ghostty: ghostty, into: nil, beside: window)
        } catch {
            presentProjectError(error)
        }
    }

    /// Open the whole project in `entry`: every page of it that is not
    /// open, and bring it in front (`ProjectSession.open` has the rules).
    /// What "Load Project", the settings window's "Open" and the control
    /// room's all do. A project that is open already is not refused; it
    /// comes in front.
    ///
    /// `current` is the terminal window the person is in: a window of the
    /// project that has no recorded frame opens as tabs there, and one that
    /// has opens as its own window (`ProjectPlacement.place`).
    ///
    /// `home` is a window the project's first window goes into as tabs
    /// whatever its frame, and `inFront` false leaves those tabs behind the
    /// one showing there: the control room's "Load Project", where the tab
    /// in front is the control room (`ControlRoomRules.newTab`).
    static func load(
        _ entry: ProjectStore.Entry, ghostty: Ghostty.App,
        into home: NSWindow?, beside current: NSWindow?, inFront: Bool = true
    ) throws {
        try ProjectSession.session(for: entry, in: ProjectStore.shared)
            .open(ghostty, into: home, beside: current, inFront: inFront)
    }

    // MARK: A Page of a Project

    /// What this tab is called when something says which tab a project is
    /// open in. Never empty: a tab just opened has no window title until
    /// its shell sets one (see `ProjectsRules.holderLabel`, #965).
    var projectTabTitle: String {
        ProjectsRules.holderLabel(
            windowTitle: window?.title ?? "",
            paneTitles: [focusedSurface?.title ?? ""] + surfaceTree.map(\.title),
            cwds: [focusedSurface?.pwd] + surfaceTree.map(\.pwd))
    }

    /// Window restoration's side: a restored tab asks for its page back.
    /// Whether it gets it is the project file's to say
    /// (`ProjectSession.restore`).
    func restoreProjectBinding(_ name: String?) {
        guard let name else { return }
        ProjectSession.restore(self, to: name, in: ProjectStore.shared)
    }

    /// The application is quitting: write every open project as it is now.
    ///
    /// Quitting closes no window, so `windowWillClose` -- where a tab's last
    /// save is -- does not run, and a change still waiting out its second
    /// was lost with the process.
    static func saveBoundProjectsBeforeQuit() {
        var saved: [ObjectIdentifier] = []
        for controller in all {
            guard let session = controller.projectSession, !saved.contains(ObjectIdentifier(session)) else { continue }
            saved.append(ObjectIdentifier(session))
            session.saveBeforeQuit()
        }
    }

    /// Stop every pane's scrollback journal: the tab no longer writes to a
    /// project. Their files stay; the project's own saves decide what is
    /// kept.
    func stopScrollbackJournals() {
        for view in surfaceTree {
            view.stopScrollbackJournal()
        }
    }

    /// Tell the project of this tab's changes from now on. Called by
    /// `ProjectSession` when the tab joins it.
    func startProjectAutosave() {
        stopProjectAutosave()

        // Each of these publishes its current value on subscription (and
        // the per-surface ones again on every tree change); `dropFirst`
        // keeps joining itself from counting as a change. Splits added or
        // removed and dividers dragged all arrive as a new `surfaceTree`.
        //
        // Which kind each is decides how long its write may be put off
        // (`ProjectAutosaveChange`): a title changes for as long as an
        // agent works, and must not hold back a split the person made.
        $surfaceTree
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.layout) }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.pwd, publisherKeyPath: \.$pwd)
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.title, publisherKeyPath: \.$title)
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
        // The tab's chosen name is saved with its page (task 1722).
        $titleOverride
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
        // The user's marks on a pane are part of what is saved (format 3,
        // task 1699): a colour, the workers mark or the shield changed is
        // a pane changed.
        surfaceValuesPublisher(valueKeyPath: \.poltergeistPaneColor, publisherKeyPath: \.$poltergeistPaneColor)
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.poltergeistWorkersRefused, publisherKeyPath: \.$poltergeistWorkersRefused)
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.poltergeistShielded, publisherKeyPath: \.$poltergeistShielded)
            .dropFirst()
            .sink { [weak self] _ in self?.projectSession?.poke(.paneDetail) }
            .store(in: &projectAutosaveCancellables)
    }

    func stopProjectAutosave() {
        projectAutosaveCancellables.removeAll()
    }

    func presentProjectError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Project Error", comment: "项目功能出错提醒标题")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "项目功能出错提醒：确定按钮"))
        alert.beginSheetModal(for: window)
    }
}
