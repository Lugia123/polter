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
    @IBAction func saveAsProject(_ sender: Any?) {
        projectPicker.present(
            mode: .saveAs(currentPaneCount: surfaceTree.count),
            onSave: { [weak self] name in
                self?.performSave(name: name)
            })
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
                // Cancelling the picker keeps the tab open too: `onCancel`
                // defaults to doing nothing.
                self.projectPicker.present(
                    mode: .saveAs(currentPaneCount: self.surfaceTree.count),
                    onSave: { [weak self] name in
                        guard let self else { return }
                        ProjectSaveBeforeClose.saveThenClose(
                            // Save As onto an existing name replaces that
                            // project: what it held is kept as `.prev` (#969).
                            save: { try self.saveAndBind(name: name, keeping: .always) },
                            reportFailure: { self.presentProjectError($0) },
                            close: closeAction)
                    })
            }
        }
    }

    // MARK: Store Operations

    private func performSave(name: String) {
        do {
            // Save As: a name that is taken is a replacement, and what it
            // held is kept as the previous version, whatever its layout
            // (#969). A new name has nothing to keep either way.
            try saveAndBind(name: name, keeping: .always)
        } catch {
            presentProjectError(error)
        }
    }

    /// Save this tab as the project `name` and make it that project's page.
    /// Throws rather than reporting, so a caller that has something riding
    /// on the save -- closing the tab, the settings window's "Overwrite
    /// with Current Tab" -- can tell whether it worked. `keeping` is
    /// `.always` when this replaces a project with the tab.
    func saveAndBind(name: String, keeping: ProjectFileWriter.Keeping) throws {
        try ProjectSession.save(self, as: name, keeping: keeping, in: ProjectStore.shared)
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
    }

    func stopProjectAutosave() {
        projectAutosaveCancellables.removeAll()
    }

    private func presentProjectError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Project Error", comment: "项目功能出错提醒标题")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "项目功能出错提醒：确定按钮"))
        alert.beginSheetModal(for: window)
    }
}
