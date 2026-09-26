import AppKit
import Combine
import GhosttyKit

/// "Save as Project", "Load Project", and "Manage Projects" -- reachable
/// from the tab context menu (targeting the right-clicked tab, see
/// `TerminalWindow.configureTabContextMenuIfNeeded`) and from the `Project`
/// menu (targeting the focused tab via the responder chain, see
/// `MainMenu.xib`).
extension TerminalController: ProjectBindingHolder {
    var projectBindingTitle: String { window?.title ?? "" }
}

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

    @IBAction func manageProjects(_ sender: Any?) {
        projectPicker.present(mode: .manage)
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
                            save: { try self.saveAndBind(name: name) },
                            reportFailure: { self.presentProjectError($0) },
                            close: closeAction)
                    })
            }
        }
    }

    // MARK: Store Operations

    private func performSave(name: String) {
        do {
            try saveAndBind(name: name)
        } catch {
            presentProjectError(error)
        }
    }

    /// Save this tab as `name` and bind it there. Throws rather than
    /// reporting, so a caller that has something riding on the save --
    /// closing the tab -- can tell whether it worked.
    private func saveAndBind(name: String) throws {
        let store = ProjectStore.shared
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before writing, not after: saving over a project another
        // tab autosaves into would be overwritten by that tab on its next
        // change -- the silent two-writer failure binding exists to prevent.
        if let holder = store.bindings.owner(of: store.bindingKey(name: trimmed)), holder !== self {
            throw ProjectStore.StoreError.boundElsewhere(
                name: trimmed,
                holder: store.holderTitle(name: trimmed) ?? "")
        }
        let entry = try store.save(name: trimmed, tree: surfaceTree)
        try bindProject(entry.name)
    }

    private func performLoad(_ entry: ProjectStore.Entry) {
        guard let app = ghostty.app else { return }
        let store = ProjectStore.shared
        do {
            // Refused before `loadTree`, which starts a shell per pane: a
            // second tab on the same project would have to either not
            // autosave (quietly unlike the first) or fight it for the file.
            if let holder = store.holderTitle(name: entry.name) {
                throw ProjectStore.StoreError.boundElsewhere(name: entry.name, holder: holder)
            }
            let tree = try store.loadTree(entry, app: app)
            let controller = TerminalController.openProject(ghostty, tree: tree, attachingTo: window)
            try controller.bindProject(entry.name)
        } catch {
            presentProjectError(error)
        }
    }

    // MARK: Binding and Autosave

    /// Bind this tab to `name` -- from now on its layout, cwds and titles
    /// are written to that project as they change. Replaces any binding
    /// this tab had. Throws `boundElsewhere` if another tab holds it.
    func bindProject(_ name: String) throws {
        let store = ProjectStore.shared
        if case .heldBy = store.bindings.claim(store.bindingKey(name: name), for: self) {
            throw ProjectStore.StoreError.boundElsewhere(name: name, holder: store.holderTitle(name: name) ?? "")
        }

        if let old = boundProject, store.bindingKey(name: old) != store.bindingKey(name: name) {
            store.bindings.release(store.bindingKey(name: old), for: self)
        }
        boundProject = name
        startProjectAutosave()

        // What carries the binding across a restart -- see
        // `TerminalRestorableState.InternalState.boundProject`.
        invalidateRestorableState()
    }

    /// Stop autosaving. Doesn't write anything; call `saveBoundProjectOnClose`
    /// first if the last change should still land.
    func unbindProject() {
        guard let name = boundProject else { return }
        let store = ProjectStore.shared
        store.bindings.release(store.bindingKey(name: name), for: self)
        stopProjectAutosave()
        boundProject = nil
        invalidateRestorableState()
    }

    /// Window restoration's half of `bindProject`: a restored tab takes its
    /// binding back if nobody else has it and the project still exists, and
    /// otherwise starts unbound -- a restart is no time for an alert.
    func restoreProjectBinding(_ name: String?) {
        guard let name else { return }
        guard ProjectStore.shared.entry(name: name) != nil else {
            Ghostty.logger.warning("not restoring binding to missing project '\(name, privacy: .public)'")
            return
        }
        do {
            try bindProject(name)
        } catch {
            Ghostty.logger.warning("not restoring binding to project '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The last save of a bound tab that is closing: the layout as it is
    /// now, plus -- the one time besides an explicit save -- a full
    /// scrollback capture. Called from `windowWillClose`, while the panes
    /// are still alive: the core only promises that a capture requested
    /// before `ghostty_surface_free` has landed by the time that returns.
    func saveBoundProjectOnClose() {
        projectAutosave?.cancel()
        guard let name = boundProject, !surfaceTree.isEmpty else { return }
        do {
            try ProjectStore.shared.save(name: name, tree: surfaceTree, capturingScrollback: true)
        } catch {
            Ghostty.logger.warning("final save of project '\(name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startProjectAutosave() {
        stopProjectAutosave()

        let debouncer = ProjectAutosaveDebouncer(scheduler: MainQueueScheduler()) { [weak self] in
            self?.autosaveProject()
        }
        projectAutosave = debouncer

        // Each of these publishes its current value on subscription (and
        // the per-surface ones again on every tree change); `dropFirst`
        // keeps binding itself from counting as a change. Splits added or
        // removed and dividers dragged all arrive as a new `surfaceTree`.
        $surfaceTree
            .dropFirst()
            .sink { _ in debouncer.poke() }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.pwd, publisherKeyPath: \.$pwd)
            .dropFirst()
            .sink { _ in debouncer.poke() }
            .store(in: &projectAutosaveCancellables)
        surfaceValuesPublisher(valueKeyPath: \.title, publisherKeyPath: \.$title)
            .dropFirst()
            .sink { _ in debouncer.poke() }
            .store(in: &projectAutosaveCancellables)
    }

    private func stopProjectAutosave() {
        projectAutosaveCancellables.removeAll()
        projectAutosave?.cancel()
        projectAutosave = nil
    }

    private func autosaveProject() {
        guard let name = boundProject else { return }
        // A tab whose last pane just closed is about to go away, not a
        // project that now has nothing in it. Writing it would leave a
        // project that opens to nothing -- and push the real layout into
        // `.prev`, one mistake away from gone.
        guard !surfaceTree.isEmpty else { return }
        do {
            // Layout only. A full scrollback capture is up to the configured
            // limit per pane and this runs a second after any title change;
            // continuous scrollback is the incremental-pages step's job.
            try ProjectStore.shared.save(name: name, tree: surfaceTree, capturingScrollback: false)
        } catch {
            // Logged, not alerted: this runs on its own a second after any
            // change, and an alert per keystroke-driven title change is
            // worse than the failure. The next change tries again.
            Ghostty.logger.warning("autosave of project '\(name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
        }
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
