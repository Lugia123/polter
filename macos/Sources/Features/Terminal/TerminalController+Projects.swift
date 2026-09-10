import AppKit
import GhosttyKit

/// "Save as Project", "Load Project", and "Manage Projects" -- reachable
/// from the tab context menu (targeting the right-clicked tab, see
/// `TerminalWindow.configureTabContextMenuIfNeeded`) and from the `Project`
/// menu (targeting the focused tab via the responder chain, see
/// `MainMenu.xib`).
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
    /// `closeAction` only runs once a save actually happens; cancelling out
    /// of the picker leaves the terminal open, same as cancelling used to.
    /// Choosing not to save runs `closeAction` immediately.
    func presentSaveAsProjectBeforeClosing(closeAction: @escaping () -> Void) {
        guard let window else {
            closeAction()
            return
        }
        guard !isPresentingCloseSaveAlert else { return }
        isPresentingCloseSaveAlert = true

        // Each String(localized:) call below stays on one line -- the
        // Chinese-strings checker only sees it when the literal starts on
        // the same line as the call.
        let alert = NSAlert()
        alert.messageText = String(localized: "Save as a Project Before Closing?", comment: "关闭终端前的存项目提醒标题")
        alert.informativeText = String(localized: "The terminal still has a running process. Closing it without saving as a project will kill it.", comment: "关闭终端前的存项目提醒正文")
        alert.addButton(withTitle: String(localized: "Save as Project...", comment: "关闭终端前的存项目提醒：存成项目按钮"))
        alert.addButton(withTitle: String(localized: "Close Without Saving", comment: "关闭终端前的存项目提醒：直接关闭按钮"))
        alert.alertStyle = .warning

        alert.beginSheetModal(for: window) { [weak self] response in
            // Important so we don't lose focus when Stage Manager is used
            // (matches `confirmCloseAsync`, #8336).
            alert.window.orderOut(nil)
            guard let self else { closeAction(); return }
            self.isPresentingCloseSaveAlert = false

            guard response == .alertFirstButtonReturn else {
                closeAction()
                return
            }

            self.projectPicker.present(
                mode: .saveAs(currentPaneCount: self.surfaceTree.count),
                onSave: { [weak self] name in
                    self?.performSave(name: name)
                    closeAction()
                })
        }
    }

    // MARK: Store Operations

    private func performSave(name: String) {
        do {
            try ProjectStore.shared.save(name: name, tree: surfaceTree)
        } catch {
            presentProjectError(error)
        }
    }

    private func performLoad(_ entry: ProjectStore.Entry) {
        guard let app = ghostty.app else { return }
        do {
            let tree = try ProjectStore.shared.loadTree(name: entry.name, app: app)
            TerminalController.openProject(ghostty, tree: tree, attachingTo: window)
        } catch {
            presentProjectError(error)
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
