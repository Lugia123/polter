import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import GhosttyKit
import AppKit

protocol GhosttyAppDelegate: AnyObject {
    /// Called when a callback needs access to a specific surface. This should return nil
    /// when the surface is no longer valid.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView?
}

extension Ghostty {
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Optional delegate
        weak var delegate: GhosttyAppDelegate?

        /// The readiness value of the state.
        @Published var readiness: Readiness = .loading

        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        @Published private(set) var config: Config

        /// Preferred config file than the default ones
        private(set) var configPath: String?
        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @Published var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        init(configPath: String? = nil) {
            self.configPath = configPath
            // Initialize the global configuration.
            self.config = Config(at: configPath)
            if self.config.config == nil {
                readiness = .error
                return
            }

            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                    App.readClipboard(
                        userdata,
                        location: loc,
                        state: state,
                        mimes: mimes,
                        mimesLen: mimesLen,
                        list: list) },
                confirm_read_clipboard_cb: { userdata, confirm, state, request in
                    App.confirmReadClipboard(
                        userdata,
                        confirm: confirm,
                        state: state,
                        request: request) },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app
            // Set our initial focus state
            ghostty_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)
            self.readiness = .ready
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        /// `os_open` -- which is also what the default ⌘, binding sends --
        /// opens the settings window; `new_window` still opens the file
        /// (settings.md §3.2). The core cannot tell a default binding from
        /// an explicit `open_config:os_open`, so neither can we.
        private static func openConfig(_ app: ghostty_app_t, mode: ghostty_action_open_config_e) {
            if mode == GHOSTTY_ACTION_OPEN_CONFIG_OS_OPEN {
                DispatchQueue.main.async { openSettings() }
                return
            }
            guard let app_ud = ghostty_app_userdata(app) else { return }
            let app = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
            app.openConfig()
        }

        func openConfig() {
            openTextFile(path: configPath ?? Ghostty.AllocatedString(ghostty_config_open_path()).string)
        }

        /// Open a config file -- the main one, or one it includes -- the way
        /// `openConfig` opens the main one: as text, in the person's editor.
        func openTextFile(path str: String) {
            guard !str.isEmpty else { return }
            let fileURL = URL(fileURLWithPath: str).absoluteString
            var action = ghostty_action_open_url_s()
            action.kind = GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
            fileURL.withCString { cStr in
                action.url = cStr
                action.len = UInt(fileURL.count)
                _ = App.openURL(action)
            }
        }

        /// Reload the configuration.
        func reloadConfig(soft: Bool = false) {
            guard let app = self.app else { return }

            // Soft updates just call with our existing config
            if soft {
                ghostty_app_update_config(app, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration
            let newConfig = Config(at: configPath)
            guard newConfig.loaded else {
                Ghostty.logger.warning("failed to reload configuration")
                return
            }

            ghostty_app_update_config(app, newConfig.config!)
            /// applied config will be updated in ``Self.configChange(_:target:v:)``
        }

        func reloadConfig(surface: ghostty_surface_t, soft: Bool = false) {
            // Soft updates just call with our existing config
            if soft {
                ghostty_surface_update_config(surface, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration.
            // NOTE: We never set this on self.config because this is a surface-only
            // config. We free it after the call.
            let newConfig = Config(at: configPath)
            guard newConfig.loaded else {
                Ghostty.logger.warning("failed to reload configuration")
                return
            }

            ghostty_surface_update_config(surface, newConfig.config!)
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        func newTab(surface: ghostty_surface_t) {
            let action = "new_tab"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func newWindow(surface: ghostty_surface_t) {
            let action = "new_window"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func split(surface: ghostty_surface_t, direction: ghostty_action_split_direction_e) {
            ghostty_surface_split(surface, direction)
        }

        func splitMoveFocus(surface: ghostty_surface_t, direction: SplitFocusDirection) {
            ghostty_surface_split_focus(surface, direction.toNative())
        }

        func splitResize(surface: ghostty_surface_t, direction: SplitResizeDirection, amount: UInt16) {
            ghostty_surface_split_resize(surface, direction.toNative(), amount)
        }

        func splitEqualize(surface: ghostty_surface_t) {
            ghostty_surface_split_equalize(surface)
        }

        func splitToggleZoom(surface: ghostty_surface_t) {
            let action = "toggle_split_zoom"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func toggleFullscreen(surface: ghostty_surface_t) {
            let action = "toggle_fullscreen"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        enum FontSizeModification {
            case increase(Int)
            case decrease(Int)
            case reset
        }

        func changeFontSize(surface: ghostty_surface_t, _ change: FontSizeModification) {
            let action: String
            switch change {
            case .increase(let amount):
                action = "increase_font_size:\(amount)"
            case .decrease(let amount):
                action = "decrease_font_size:\(amount)"
            case .reset:
                action = "reset_font_size"
            }
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func toggleTerminalInspector(surface: ghostty_surface_t) {
            let action = "inspector:toggle"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        /// Perform one of the poltergeist bindings on a surface.
        ///
        /// One function for all of them rather than four that differ only
        /// in a string: they are reached the same way and fail the same
        /// way, and a copy each would be four places to fix a typo.
        func poltergeistAction(surface: ghostty_surface_t, _ action: String) {
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func resetTerminal(surface: ghostty_surface_t) {
            let action = "reset"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: Ghostty Callbacks (macOS)

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?,
            mimes: UnsafePointer<UnsafePointer<CChar>?>?,
            mimesLen: Int,
            list: Bool
        ) -> ghostty_clipboard_read_result_e {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.ghostty(location) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Gather the representation for each requested MIME type that
            // the pasteboard can serve. We only ever read the requested
            // representations so unrelated (potentially large) clipboard
            // contents are never loaded.
            var contents: [Ghostty.ClipboardContent] = []
            var seen = Set<String>()
            if let mimes {
                for i in 0..<mimesLen {
                    guard let ptr = mimes[i] else { continue }
                    let mime = String(cString: ptr)
                    guard !seen.contains(mime) else { continue }
                    seen.insert(mime)
                    // A clipboard holding an image and no text is pasted as
                    // the path of a file holding the image. Asked first, and
                    // it answers nil for everything that is not that case, so
                    // text and copied files go the way they always did.
                    //
                    // Only for the person pasting. A program that reads the
                    // clipboard (OSC 52) asks with the same "text/plain" and
                    // must get what is there, not a file it never asked for.
                    if mime == "text/plain", location == GHOSTTY_CLIPBOARD_STANDARD,
                       ghostty_clipboard_request_is_paste(state),
                       let config = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config,
                       let path = ImagePasteService.shared.pastedPath(
                        from: pasteboard,
                        pasteImage: config.clipboardPasteImage,
                        directory: config.screenshotDirectory) {
                        contents.append(.init(mime: mime, data: Data(path.utf8)))
                        // A screenshot taken here has more to say: a long
                        // one's other tiles, and a line of text. Each is
                        // pasted on its own, after this one: a paste has to
                        // be exactly one path for a CLI to take it as an
                        // image.
                        //
                        // They go to **this** terminal, the one pasted into.
                        // Closed before a piece is due, it gets none of what
                        // is left and no other terminal gets it instead;
                        // pasted into again, the pieces start over and what
                        // the earlier paste still owed is dropped.
                        let pane = ObjectIdentifier(surfaceView)
                        let run = ImagePasteService.shared.beginRun(in: pane)
                        let later = ImagePasteService.shared.followUps(for: pasteboard)
                        for (i, text) in later.enumerated() {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + ScreenshotController.secondPasteDelay * Double(i + 1)
                            ) { [weak surfaceView] in
                                guard let surfaceView,
                                      ImagePasteService.shared.isCurrent(run, in: pane) else { return }
                                MainActor.assumeIsolated { surfaceView.surfaceModel?.sendText(text) }
                            }
                        }
                        continue
                    }
                    guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                    contents.append(.init(mime: mime, data: data))
                }
            }

            // The listing of available types, only gathered when requested.
            let available: [String] = list ? pasteboard.ghosttyAvailableMimes() : []

            // With nothing to serve and no listing requested there is
            // nothing to complete the read with.
            if contents.isEmpty && !list {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }

            completeClipboardRequest(
                surface,
                contents: contents,
                available: available,
                state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            guard let confirm,
                  let kind = Ghostty.ClipboardRequest.from(request: request) else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            let c = confirm.pointee

            // Copy the borrowed C representations: the confirmation is
            // asynchronous and completes with exactly what the user
            // approved, so the clipboard is never re-read.
            var reps: [Ghostty.ClipboardContent] = []
            if let contents = c.contents {
                for i in 0..<c.contents_len {
                    let content = contents[i]
                    let data: Data = if content.len > 0 {
                        Data(bytes: content.data, count: content.len)
                    } else {
                        Data()
                    }
                    reps.append(.init(mime: String(cString: content.mime), data: data))
                }
            }
            var avail: [String] = []
            if let available = c.available {
                for i in 0..<c.available_len {
                    guard let ptr = available[i] else { continue }
                    avail.append(String(cString: ptr))
                }
            }

            // The dialog can only display text: show the text
            // representation when there is one and summarize the rest.
            let display = reps.first(where: { $0.mime == "text/plain" })
                .flatMap { String(data: $0.data, encoding: .utf8) }
                ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

            // Decode an image representation so the dialog can preview
            // exactly what would be disclosed rather than a byte count.
            let previewImage: NSImage? = reps.lazy
                .filter { $0.mime.hasPrefix("image/") }
                .compactMap { NSImage(data: $0.data) }
                .first

            // libghostty reaches this callback only when the request attempted
            // by readClipboard requires confirmation. Reads allowed by policy
            // complete immediately and never become pending Swift state.
            let request = Ghostty.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: display,
                kind: kind,
                programName: c.name.map { String(cString: $0) },
                canRemember: c.can_remember,
                previewImage: previewImage
            ) { surfaceView, confirmed, remember in
                guard let surface = surfaceView.surface else { return }
                if confirmed {
                    completeClipboardRequest(
                        surface,
                        contents: reps,
                        available: avail,
                        state: state,
                        confirmed: true,
                        remember: remember)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        private static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            contents: [Ghostty.ClipboardContent],
            available: [String],
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false,
            remember: Bool = false
        ) {
            // Copy everything into C memory for the duration of the call.
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            var cDatas: [UnsafeMutableRawPointer] = []
            defer {
                cStrings.forEach { free($0) }
                cDatas.forEach { $0.deallocate() }
            }

            var cContents: [ghostty_clipboard_content_s] = []
            for entry in contents {
                guard let mime = strdup(entry.mime) else { continue }
                cStrings.append(mime)
                let buf = UnsafeMutableRawPointer.allocate(
                    byteCount: max(entry.data.count, 1),
                    alignment: 1)
                cDatas.append(buf)
                entry.data.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buf.copyMemory(from: base, byteCount: src.count)
                    }
                }
                cContents.append(ghostty_clipboard_content_s(
                    mime: mime,
                    data: buf.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
            }

            var cAvailable: [UnsafePointer<CChar>?] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            guard let content = content, len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).compactMap { i in
                Ghostty.ClipboardContent.from(content: content[i])
            }
            guard !contentArray.isEmpty else { return }

            // Assert there is only one text/plain entry. For security reasons we need
            // to guarantee this for now since our confirmation dialog only shows one.
            assert(contentArray.filter({ $0.mime == "text/plain" }).count <= 1,
                   "clipboard contents should have at most one text/plain entry")

            if !confirm {
                // Apply writes allowed by policy immediately. Only writes that
                // require confirmation continue to the pending request below.
                let types = contentArray.compactMap { item in
                    NSPasteboard.PasteboardType(mimeType: item.mime)
                }
                pasteboard.declareTypes(types, owner: nil)

                // Set data for each type
                for item in contentArray {
                    guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                    pasteboard.setData(item.data, forType: type)
                }
                return
            }

            // For confirmation, use the text/plain content if it exists
            guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }),
                  let textPlainString = textPlainContent.string else {
                return
            }

            let request = Ghostty.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: textPlainString,
                kind: .osc_52_write
            ) { _, confirmed, _ in
                guard confirmed else { return }
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(textPlainString, forType: .string)
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Determine if a given notification should be presented to the user when Ghostty is running in the foreground.
        func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo

            // The control room's own: whether the person is looking was
            // decided before it was sent (`ControlNotify.zig`).
            if userInfo[ControlRoomAlert.groupKey] is String { return true }

            // We always require the notification to be attached to a surface.
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = delegate?.findSurface(forUUID: uuid),
                  let window = surface.window else { return false }

            // If we don't require focus then we're good!
            let requireFocus = userInfo["requireFocus"] as? Bool ?? true
            if !requireFocus { return true }

            return !window.isKeyWindow || !surface.focused
        }

        /// Returns the GhosttyState from the given userdata value.
        static private func appState(fromView view: SurfaceView) -> App? {
            guard let surface = view.surface else { return nil }
            guard let app = ghostty_surface_app(surface) else { return nil }
            guard let app_ud = ghostty_app_userdata(app) else { return nil }
            return Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }

        static private func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        // MARK: Actions (macOS)

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Make sure it a target we understand so all our action handlers can assert
            switch target.tag {
            case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
                break

            default:
                Ghostty.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
                return false
            }

            // Action dispatch
            switch action.tag {
            case GHOSTTY_ACTION_QUIT:
                quit(app)

            case GHOSTTY_ACTION_NEW_WINDOW:
                newWindow(app, target: target)

            case GHOSTTY_ACTION_NEW_TAB:
                return newTab(app, target: target, action: action.action.new_tab)

            case GHOSTTY_ACTION_TOGGLE_POLTERGEIST_CHAT:
                openChat(app, target: target)

            case GHOSTTY_ACTION_NEW_SPLIT:
                newSplit(app, target: target, v: action.action.new_split)

            case GHOSTTY_ACTION_CLOSE_TAB:
                closeTab(app, target: target, mode: action.action.close_tab_mode)

            case GHOSTTY_ACTION_CLOSE_WINDOW:
                closeWindow(app, target: target)

            case GHOSTTY_ACTION_POLTERGEIST_CLOSE:
                return poltergeistClose(app, target: target, v: action.action.poltergeist_close)

            case GHOSTTY_ACTION_POLTERGEIST_TAB_PANES:
                return poltergeistTabPanes(target: target, v: action.action.poltergeist_tab_panes)

            case GHOSTTY_ACTION_POLTERGEIST_GROUPING:
                return poltergeistGrouping(target: target, v: action.action.poltergeist_grouping)
            case GHOSTTY_ACTION_POLTER_TAB_MOVE:
                return polterTabMove(target: target, v: action.action.polter_tab_move)

            case GHOSTTY_ACTION_POLTER_HIGHLIGHT:
                return polterHighlight(target: target, v: action.action.polter_highlight)

            case GHOSTTY_ACTION_POLTERGEIST_LAYOUT:
                return poltergeistLayout(app, target: target, v: action.action.poltergeist_layout)

            case GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT:
                // An agent's screenshot request. The terminal target of a
                // capture arrives as the surface; everything else as the app.
                var terminal: SurfaceView?
                if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                    terminal = self.surfaceView(from: surface)
                }
                return ShotAgentHost.shared.handle(action.action.poltergeist_screenshot, terminal: terminal)

            case GHOSTTY_ACTION_HISTORY_FILENAME:
                return historyFilename(target: target, v: action.action.history_filename)

            case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
                toggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

            case GHOSTTY_ACTION_MOVE_TAB:
                return moveTab(app, target: target, move: action.action.move_tab)

            case GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW:
                return moveTabToNewWindow(app, target: target)

            case GHOSTTY_ACTION_GOTO_TAB:
                return gotoTab(app, target: target, tab: action.action.goto_tab)

            case GHOSTTY_ACTION_GOTO_SPLIT:
                return gotoSplit(app, target: target, direction: action.action.goto_split)

            case GHOSTTY_ACTION_PANE_STACK:
                return paneStack(app, target: target, verb: action.action.pane_stack)

            case GHOSTTY_ACTION_GOTO_WINDOW:
                return gotoWindow(app, target: target, direction: action.action.goto_window)

            case GHOSTTY_ACTION_RESIZE_SPLIT:
                return resizeSplit(app, target: target, resize: action.action.resize_split)

            case GHOSTTY_ACTION_EQUALIZE_SPLITS:
                equalizeSplits(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
                return toggleSplitZoom(app, target: target)

            case GHOSTTY_ACTION_INSPECTOR:
                controlInspector(app, target: target, mode: action.action.inspector)

            case GHOSTTY_ACTION_RENDER_INSPECTOR:
                renderInspector(app, target: target)

            case GHOSTTY_ACTION_EXPORT_TERMINAL_IO:
                return exportTerminalIO(app, target: target, v: action.action.export_terminal_io)

            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                showDesktopNotification(app, target: target, n: action.action.desktop_notification)

            case GHOSTTY_ACTION_SET_TITLE:
                setTitle(app, target: target, v: action.action.set_title)

            case GHOSTTY_ACTION_SET_TAB_TITLE:
                return setTabTitle(app, target: target, v: action.action.set_tab_title)

            case GHOSTTY_ACTION_PROMPT_TITLE:
                return promptTitle(app, target: target, v: action.action.prompt_title)

            case GHOSTTY_ACTION_PWD:
                pwdChanged(app, target: target, v: action.action.pwd)

            case GHOSTTY_ACTION_OPEN_CONFIG:
                openConfig(app, mode: action.action.open_config)

            case GHOSTTY_ACTION_FLOAT_WINDOW:
                toggleFloatWindow(app, target: target, mode: action.action.float_window)

            case GHOSTTY_ACTION_SECURE_INPUT:
                toggleSecureInput(app, target: target, mode: action.action.secure_input)

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                setMouseShape(app, target: target, shape: action.action.mouse_shape)

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                setMouseVisibility(app, target: target, v: action.action.mouse_visibility)

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                setMouseOverLink(app, target: target, v: action.action.mouse_over_link)

            case GHOSTTY_ACTION_INITIAL_SIZE:
                setInitialSize(app, target: target, v: action.action.initial_size)

            case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
                resetWindowSize(app, target: target)

            case GHOSTTY_ACTION_CELL_SIZE:
                setCellSize(app, target: target, v: action.action.cell_size)

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                rendererHealth(app, target: target, v: action.action.renderer_health)

            case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
                toggleCommandPalette(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
                toggleMaximize(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
                toggleQuickTerminal(app, target: target)

            case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
                toggleVisibility(app, target: target)

            case GHOSTTY_ACTION_CONTROL_ROOM_CHANGED:
                // The only thing that makes the control room fetch. Whoever
                // is listening takes the snapshot; nobody polls for it.
                NotificationCenter.default.post(name: ControlRoomFeed.changed, object: nil)

            case GHOSTTY_ACTION_CONTROL_ROOM_ALERT:
                // The core decided all of it: whether, when, how often.
                guard let alert = action.action.control_room_alert.alert?.pointee else { return false }
                controlRoomAlert(alert)

            case GHOSTTY_ACTION_TOGGLE_POLTERGEIST_CONTROL_ROOM:
                // A key binding or the command palette; the menu item calls
                // the same method directly.
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return false }
                appDelegate.poltergeistToggleControlRoom(nil)

            case GHOSTTY_ACTION_SCREENSHOT:
                // From the command palette or a keybind that is not the
                // registered hotkey. The controller reads for itself whether
                // this app is in front.
                ScreenshotController.shared.trigger()

            case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
                toggleBackgroundOpacity(app, target: target)

            case GHOSTTY_ACTION_KEY_SEQUENCE:
                keySequence(app, target: target, v: action.action.key_sequence)

            case GHOSTTY_ACTION_KEY_TABLE:
                keyTable(app, target: target, v: action.action.key_table)

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                progressReport(app, target: target, v: action.action.progress_report)

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                configChange(app, target: target, v: action.action.config_change)

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                configReload(app, target: target, v: action.action.reload_config)

            case GHOSTTY_ACTION_COLOR_CHANGE:
                colorChange(app, target: target, change: action.action.color_change)

            case GHOSTTY_ACTION_RING_BELL:
                ringBell(app, target: target)

            case GHOSTTY_ACTION_SELECTION_CHANGED:
                selectionChanged(app, target: target)

            case GHOSTTY_ACTION_READONLY:
                setReadonly(app, target: target, v: action.action.readonly)

            case GHOSTTY_ACTION_POLTERGEIST_MARK:
                return setPoltergeistMark(
                    app, target: target, v: action.action.poltergeist_mark)

            case GHOSTTY_ACTION_POLTERGEIST_PANE:
                return setPoltergeistPane(
                    app, target: target, v: action.action.poltergeist_pane)

            case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
                checkForUpdates(app)

            case GHOSTTY_ACTION_OPEN_URL:
                return openURL(action.action.open_url)

            case GHOSTTY_ACTION_UNDO:
                return undo(app, target: target)

            case GHOSTTY_ACTION_REDO:
                return redo(app, target: target)

            case GHOSTTY_ACTION_SCROLLBAR:
                scrollbar(app, target: target, v: action.action.scrollbar)

            case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
                closeAllWindows(app, target: target)

            case GHOSTTY_ACTION_START_SEARCH:
                startSearch(app, target: target, v: action.action.start_search)

            case GHOSTTY_ACTION_END_SEARCH:
                return endSearch(app, target: target)

            case GHOSTTY_ACTION_SEARCH_TOTAL:
                searchTotal(app, target: target, v: action.action.search_total)

            case GHOSTTY_ACTION_SEARCH_SELECTED:
                searchSelected(app, target: target, v: action.action.search_selected)

            case GHOSTTY_ACTION_COMMAND_FINISHED:
                commandFinished(app, target: target, v: action.action.command_finished)

            case GHOSTTY_ACTION_PRESENT_TERMINAL:
                return presentTerminal(app, target: target)

            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                return showChildExited(app, target: target, v: action.action.child_exited)

            case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
                return copyTitleToClipboard(app, target: target)

            default:
                Ghostty.logger.warning("unknown action action=\(action.tag.rawValue, privacy: .public)")
                return false
            }

            // If we reached here then we assume performed since all unknown actions
            // are captured in the switch and return false.
            return true
        }

        private static func quit(_ app: ghostty_app_t) {
            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
        }

        private static func checkForUpdates(
            _ app: ghostty_app_t
        ) {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.checkForUpdates(nil)
            }
        }

        private static func openURL(
            _ v: ghostty_action_open_url_s
        ) -> Bool {
            let action = Ghostty.Action.OpenURL(c: v)

            // OSC 8 targets are producer-controlled terminal output. Keep them
            // out of the unrestricted generic opener so unsafe local files and
            // deceptive targets cannot reach Launch Services directly.
            if action.kind == .osc8 {
                return openUntrustedURL(action.url)
            }

            // If the URL doesn't have a valid scheme we assume its a file path. The URL
            // initializer will gladly take invalid URLs (e.g. plain file paths) and turn
            // them into schema-less URLs, but these won't open properly in text editors.
            // See: https://github.com/ghostty-org/ghostty/issues/8763
            let url: URL
            if let candidate = URL(string: action.url), candidate.scheme != nil {
                url = candidate
            } else {
                // Expand ~ to the user's home directory so that file paths
                // like ~/Documents/file.txt resolve correctly.
                let expandedPath = NSString(string: action.url).standardizingPath
                url = URL(filePath: expandedPath)
            }

            switch action.kind {
            case .text:
                // Open with the default editor for `*.ghostty` file or just system text editor
                let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension) ?? NSWorkspace.shared.defaultTextEditor
                if let textEditor = editor {
                    NSWorkspace.shared.open([url], withApplicationAt: textEditor, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }

            case .html:
                // The extension will be HTML and we do the right thing automatically.
                break

            case .unknown:
                break

            case .osc8:
                assertionFailure("OSC 8 URLs must use the safe-opening policy")
                return true
            }

            // Open with the default application for the URL
            NSWorkspace.shared.open(url)
            return true
        }

        private static func openUntrustedURL(_ value: String) -> Bool {
            let target = UntrustedURL(value)
            switch target.decision {
            case .allow(let url):
                _ = NSWorkspace.shared.open(url)

            case .confirm(let url):
                UntrustedURLAlert.presentConfirmation(
                    for: url,
                    displayString: target.displayString
                )

            case .deny(let reason):
                UntrustedURLAlert.presentBlock(
                    reason: reason,
                    displayString: target.displayString
                )
            }

            // Always report OSC 8 actions as handled. Returning false would
            // cause the core to retry with the unrestricted fallback opener.
            return true
        }

        private static func undo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
            let undoManager: UndoManager?
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canUndo else { return false }
            undoManager.undo()
            return true
        }

        private static func redo(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
            let undoManager: UndoManager?
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canRedo else { return false }
            undoManager.redo()
            return true
        }

        private static func newWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewWindow,
                    object: nil,
                    userInfo: [:]
                )

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewWindow,
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW)),
                    ]
                )

            default:
                assertionFailure()
            }
        }

        /// False when no tab was asked of anybody: the core then answers
        /// whoever wanted the terminal that it was not opened, instead of
        /// "done" with nothing there.
        ///
        /// **And the answer cell, when there is one** (`action.result`):
        /// somebody other than the person is waiting to hear -- an agent's
        /// `terminal_open`. The two places a key press is answered with a
        /// dialog (tabs are off, this is the quick terminal) are answered
        /// to that caller with REFUSED and no dialog: the person did not
        /// ask for anything. The return value stays "performed" in those
        /// for a key, so the key does not fall through to the program.
        private static func newTab(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            action: ghostty_action_new_tab_s
        ) -> Bool {
            // Empty means "wherever a new tab would have gone anyway", which
            // is what a keybinding and a menu item both send. Only Poltergeist
            // names a directory, because only it has somewhere to put a
            // terminal that no existing terminal is already sitting in.
            let requested: String? = action.working_directory.flatMap {
                let s = String(cString: $0)
                return s.isEmpty ? nil : s
            }
            let answer = action.result
            func refuse(_ why: String) -> Bool {
                Ghostty.logger.warning("new tab refused: \(why, privacy: .public)")
                answer?.pointee = GHOSTTY_ACTION_NEW_TAB_RESULT_REFUSED
                return false
            }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                var config = SurfaceConfiguration()
                config.workingDirectory = requested
                answer?.pointee = GHOSTTY_ACTION_NEW_TAB_RESULT_WILL_OPEN
                var info: [AnyHashable: Any] = [Notification.NewTabAnswerWantedKey: answer != nil]
                if requested != nil { info[Notification.NewSurfaceConfigKey] = config }
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewTab,
                    object: nil,
                    userInfo: info
                )
                return true

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let appState = self.appState(fromView: surfaceView) else { return false }
                // Asked of the window the terminal belongs to, which is not
                // the one its view is in while the control room has it.
                guard let home = surfaceView.homeWindow else {
                    return refuse("no window holds the terminal it was asked from")
                }
                let lent = ControlRoomLender.shared.isLent(surfaceView)
                switch ControlRoomRules.newTabAnswer(
                    lent: lent,
                    homeTakesTabs: home.windowController is TerminalController,
                    decorations: appState.config.windowDecorations,
                    answerWanted: answer != nil) {
                case .open:
                    break
                case .refuseToTheCore(let why):
                    return refuse(why)
                case .tellThePerson:
                    // A key or a menu item, in a window that takes no tabs.
                    // The quick terminal says so itself when it hears the
                    // notification below; with decorations off it is said
                    // here.
                    guard appState.config.windowDecorations else {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Tabs are disabled", comment: "核心发起的提醒框")
                        alert.informativeText = String(localized: "Enable window decorations to use tabs", comment: "核心发起的提醒框")
                        alert.addButton(withTitle: String(localized: "OK", comment: "核心发起的提醒框"))
                        alert.alertStyle = .warning
                        _ = alert.runModal()
                        return true
                    }
                }

                // Inherited first, then overridden: everything else about
                // the new tab -- font size, environment, the rest -- should
                // still come from the terminal it was opened beside.
                var config = SurfaceConfiguration(
                    from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
                if let requested { config.workingDirectory = requested }

                if home.windowController is TerminalController {
                    answer?.pointee = GHOSTTY_ACTION_NEW_TAB_RESULT_WILL_OPEN
                }
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewTab,
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: config,
                        Notification.NewTabAnswerWantedKey: answer != nil,
                    ]
                )
                return true

            default:
                assertionFailure()
                return false
            }
        }

        /// Open a terminal running the chat interface.
        ///
        /// A terminal rather than a window of our own: the chat is a TUI, so
        /// anything that can open a terminal has the interface, and there is
        /// no second implementation to keep in step on GTK.
        ///
        /// `poltergeistChat` is what makes the difference between this and
        /// any other terminal -- it tells the core that requests from this
        /// surface speak for the person at the keyboard. It is set here,
        /// where we know why the surface is being opened, and nowhere else.
        private static func openChat(_ app: ghostty_app_t, target: ghostty_target_s) {
            var config = SurfaceConfiguration()
            config.command = "polter +chat"
            config.poltergeistChat = true
            config.context = GHOSTTY_SURFACE_CONTEXT_TAB

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewTab,
                    object: nil,
                    userInfo: [Notification.NewSurfaceConfigKey: config]
                )

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.ghosttyNewTab,
                    object: surfaceView,
                    userInfo: [Notification.NewSurfaceConfigKey: config]
                )

            default:
                assertionFailure()
            }
        }

        /// - Parameter v: direction, an optional working directory, and a
        ///   cell to answer in.
        ///
        /// **A named working directory is honoured or the split does not
        /// happen.** Splitting anyway, in the parent's directory, would tell
        /// the caller it got what it asked for; the core reads `unsupported`
        /// and opens a tab instead, which can carry a directory.
        private static func newSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_new_split_s) {
            let direction = v.direction
            let requested: String? = v.working_directory.flatMap {
                let s = String(cString: $0)
                return s.isEmpty ? nil : s
            }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                // New split does nothing with an app target
                Ghostty.logger.warning("new split does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                // **Only a surface some terminal window holds can be split.**
                // Every controller hears the notification below and each one
                // ignores a view outside its own tree without a word, so a
                // view in no tree -- a closed tab kept alive for undo -- got
                // `will_split` and then nothing at all (task 877). Refused
                // here instead, and said: the core then opens a tab.
                guard let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController,
                      controller.surfaceTree.contains(surfaceView) else {
                    Ghostty.logger.warning(
                        "new split refused: the target surface is not in any terminal window's split tree")
                    return
                }

                // A key pressed on a terminal the control room has borrowed
                // is refused; an agent's request is carried out in the
                // terminal's own tab, where its tree is
                // (`ControlRoomRules.newSplit`).
                switch ControlRoomRules.newSplit(
                    lent: ControlRoomLender.shared.isLent(surfaceView), answerWanted: v.result != nil) {
                case .split:
                    break
                case .refuseAloud:
                    Ghostty.logger.warning("new split refused: the terminal is in the control room")
                    NSSound.beep()
                    return
                }

                var config = SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
                if let requested { config.workingDirectory = requested }

                // Answered before the notification goes out, because the
                // split is handled asynchronously and this call has to return
                // a verdict now. What it claims is "this apprt will make the
                // split you asked for, in the directory you asked for" --
                // which is decided here, not later.
                if let cell = v.result { cell.pointee = GHOSTTY_ACTION_NEW_SPLIT_RESULT_WILL_SPLIT }

                NotificationCenter.default.post(
                    name: Notification.ghosttyNewSplit,
                    object: surfaceView,
                    userInfo: [
                        "direction": direction,
                        Notification.NewSurfaceConfigKey: config,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func presentTerminal(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                NotificationCenter.default.post(
                    name: Notification.ghosttyPresentTerminal,
                    object: surfaceView
                )
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func closeTab(_ app: ghostty_app_t, target: ghostty_target_s, mode: ghostty_action_close_tab_mode_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("close tabs does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                switch mode {
                case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
                    NotificationCenter.default.post(
                        name: .ghosttyCloseTab,
                        object: surfaceView
                    )
                    return

                case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
                    NotificationCenter.default.post(
                        name: .ghosttyCloseOtherTabs,
                        object: surfaceView
                    )
                    return

                case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
                    NotificationCenter.default.post(
                        name: .ghosttyCloseTabsOnTheRight,
                        object: surfaceView
                    )
                    return

                default:
                    assertionFailure()
                }

            default:
                assertionFailure()
            }
        }

        private static func closeWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("close window does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: .ghosttyCloseWindow,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        /// Close a tab or window because Polter's tool surface asked.
        ///
        /// **Not routed through `NotificationCenter` like `closeTab` above,
        /// and that is the point of the whole action.** A notification is a
        /// shout into the room: it reaches whichever controller owns the
        /// surface, which is fine when nothing has to come back, and no use at
        /// all here because something does. The core needs to know whether the
        /// tab closed or a dialog went up, and it needs to know before this
        /// call returns -- that answer exists nowhere later.
        ///
        /// So the controller is found by hand, the same way the notification
        /// observers pick themselves out (`surfaceTree.contains(target)`), and
        /// asked directly. The outcome goes back through `v.result`, which the
        /// core initialised to `unsupported`: every path that cannot answer
        /// leaves it alone and is honestly reported as "nothing happened",
        /// which is the failure mode this replaces.
        private static func poltergeistClose(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_close_s
        ) -> Bool {
            guard let out = v.result else { return false }

            let scope: TerminalController.ToolCloseScope
            switch v.scope {
            case GHOSTTY_ACTION_POLTERGEIST_CLOSE_SCOPE_THIS_TAB:
                scope = .thisTab
            case GHOSTTY_ACTION_POLTERGEIST_CLOSE_SCOPE_OTHER_TABS:
                scope = .otherTabs
            case GHOSTTY_ACTION_POLTERGEIST_CLOSE_SCOPE_TABS_TO_THE_RIGHT:
                scope = .tabsToTheRight
            case GHOSTTY_ACTION_POLTERGEIST_CLOSE_SCOPE_WINDOW:
                scope = .window
            default:
                assertionFailure()
                return false
            }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("poltergeist close does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = NSApp.windows
                    .compactMap({ $0.windowController as? TerminalController })
                    .first(where: { $0.surfaceTree.contains(surfaceView) })
                else {
                    // A surface with no terminal controller -- the quick
                    // terminal, say. It has no tabs to speak of, so there is
                    // nothing here to do and `unsupported` says so.
                    return false
                }

                switch controller.closeFromTool(scope: scope, confirm: v.confirm) {
                case .closed:
                    out.pointee = GHOSTTY_ACTION_POLTERGEIST_CLOSE_RESULT_CLOSED
                case .refused:
                    out.pointee = GHOSTTY_ACTION_POLTERGEIST_CLOSE_RESULT_REFUSED
                case .unsupported:
                    // Left at the value the core initialised it to, and said
                    // out loud rather than falling through, so that adding a
                    // case to `ToolCloseResult` is a compile error here.
                    out.pointee = GHOSTTY_ACTION_POLTERGEIST_CLOSE_RESULT_UNSUPPORTED
                }
                return true

            default:
                assertionFailure()
                return false
            }
        }

        /// Rearrange a tab's panes into a shape given from outside. See
        /// `TerminalController.applyToolLayout` for the actual work; this
        /// is the C ABI glue -- finding the target's controller and
        /// writing the answer through `v.out`, the same buffer-owned-by-
        /// the-caller shape `PoltergeistLayout.Out` documents.
        private static func poltergeistLayout(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_layout_s
        ) -> Bool {
            guard let out = v.out else { return false }

            // Writes into the caller's buffer, truncating rather than
            // overflowing it -- the ABI note on `Out` says an apprt that
            // needs more room says so in the reason instead.
            func write(_ result: ghostty_action_poltergeist_layout_result_e, _ text: String) {
                out.pointee.result = result
                guard let buf = out.pointee.buf, out.pointee.cap > 0 else {
                    out.pointee.len = 0
                    return
                }
                let bytes = Array(text.utf8)
                let n = min(bytes.count, out.pointee.cap)
                out.pointee.len = n
                guard n > 0 else { return }
                buf.withMemoryRebound(to: UInt8.self, capacity: n) { dst in
                    bytes.withUnsafeBufferPointer { src in
                        dst.update(from: src.baseAddress!, count: n)
                    }
                }
            }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("poltergeist layout does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                // A surface in no terminal tab -- the quick terminal, say --
                // has no tabs to lay out and no window to lay one out from.
                // `out` is already `unsupported`, the value the core
                // initialised it to, so leaving it alone here is the honest
                // answer.
                guard TerminalController.all.contains(where: { $0.surfaceTree.contains(surfaceView) }) else {
                    return false
                }

                guard let specText = String(cString: v.spec!, encoding: .utf8) else {
                    write(GHOSTTY_ACTION_POLTERGEIST_LAYOUT_REFUSED, "the layout is not valid UTF-8")
                    return true
                }

                switch TerminalController.applyToolLayout(specText, aimed: surfaceView) {
                case .refused(let why):
                    write(GHOSTTY_ACTION_POLTERGEIST_LAYOUT_REFUSED, why)
                case .applied(let json):
                    write(GHOSTTY_ACTION_POLTERGEIST_LAYOUT_APPLIED, json)
                }
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func closeAllWindows(_ app: ghostty_app_t, target: ghostty_target_s) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.closeAllWindows(nil)
        }

        private static func toggleFullscreen(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode raw: ghostty_action_fullscreen_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle fullscreen does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let mode = FullscreenMode.from(ghostty: raw) else {
                    Ghostty.logger.warning("unknown fullscreen mode raw=\(raw.rawValue, privacy: .public)")
                    return
                }
                NotificationCenter.default.post(
                    name: Notification.ghosttyToggleFullscreen,
                    object: surfaceView,
                    userInfo: [
                        Notification.FullscreenModeKey: mode,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleCommandPalette(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle command palette does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyCommandPaletteDidToggle,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleMaximize(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle maximize does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyMaximizeDidToggle,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleVisibility(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleVisibility(self)
        }

        private static func ringBell(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                // Technically we could still request app attention here but there
                // are no known cases where the bell is rang with an app target so
                // I think its better to warn.
                Ghostty.logger.warning("ring bell does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func selectionChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("selection changed does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttySelectionDidChange,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func setReadonly(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_readonly_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set readonly does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyDidChangeReadonly,
                    object: surfaceView,
                    userInfo: [
                        SwiftUI.Notification.Name.ReadonlyKey: v == GHOSTTY_READONLY_ON,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        /// Store Poltergeist's mark on the surface it is about.
        ///
        /// **Stored, not rendered here, and not written into the title.**
        /// The mark used to travel as a tab title override with the mark
        /// spliced on the front, which meant it shared one field with the
        /// title the program sets through OSC 0/2 -- so a program that
        /// renamed itself wiped its own mark. It lives on the surface now
        /// and is composed in front of the title whenever the title is
        /// rendered, so a rename recomposes rather than overwrites.
        /// The pane half of the mark (task 1699): its colour, whether
        /// workers are kept out, the supervisor's flag. Stored on the
        /// surface; the tab's dots and the pane's badge are drawn from it.
        private static func setPoltergeistPane(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_pane_s) -> Bool {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface) else { return false }
            surfaceView.poltergeistPaneColor = PaneColor(rawValue: Int(v.color.rawValue)) ?? .none
            surfaceView.poltergeistWorkersRefused = v.workers == GHOSTTY_POLTERGEIST_WORKERS_REFUSED
            surfaceView.poltergeistFlag = PaneFlag(rawValue: Int(v.flag.rawValue)) ?? .none
            surfaceView.poltergeistPaneReports += 1
            return true
        }

        private static func setPoltergeistMark(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_mark_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("poltergeist mark does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let prefix = v.prefix else { return false }
                surfaceView.poltergeistMark = String(cString: prefix, encoding: .utf8) ?? ""

                // The meaning as well as the glyphs. A menu item cannot
                // tick itself from a rendered string, and the first
                // version of this action sent one -- the cost of that was
                // written down at the time and this is it coming due.
                switch v.role {
                case GHOSTTY_POLTERGEIST_ROLE_SUPERVISOR:
                    surfaceView.poltergeistRole = .supervisor
                case GHOSTTY_POLTERGEIST_ROLE_WATCHED:
                    surfaceView.poltergeistRole = .watched
                default:
                    surfaceView.poltergeistRole = .none
                }
                surfaceView.poltergeistShielded = v.shielded
                surfaceView.poltergeistMayAuthorise = v.may_authorise
                surfaceView.poltergeistWorkerMentions = v.worker_mentions

                // Which persona, and whether anybody is in there wearing it.
                //
                // Copied out of the pointer immediately: the core says it is
                // "valid for the duration of the callback and no longer", the
                // same rule `prefix` above follows. Stashing the pointer
                // compiles, runs, and is garbage one frame later.
                //
                // The core documents `persona` as never NULL -- it always has
                // something to say, if only "nothing chosen, nobody here" --
                // so NULL is its bug and not a fifth state. Handled anyway,
                // as the state that asks the least of the user.
                if let persona = v.persona?.pointee {
                    surfaceView.poltergeistPersonaState = PersonaState(
                        key: persona.key.map { String(cString: $0) },
                        name: persona.name.map { String(cString: $0) },
                        deviated: persona.deviated,
                        hostClass: .init(persona.host_class),
                        agentPresent: persona.agent_present)
                } else {
                    Ghostty.logger.warning("poltergeist mark arrived with no persona payload")
                    surfaceView.poltergeistPersonaState = .none
                }
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func moveTab(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            move: ghostty_action_move_tab_s) -> Bool {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("move tab does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // See gotoTab for notes on this check.
                    guard (surfaceView.homeWindow?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: .ghosttyMoveTab,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyMoveTabKey: Action.MoveTab(c: move),
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func moveTabToNewWindow(
            _ app: ghostty_app_t,
            target: ghostty_target_s) -> Bool {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("move tab to new window does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // See gotoTab for notes on this check. A lone tab is already
                    // a window of its own, so there is nothing to move.
                    guard (surfaceView.homeWindow?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    surfaceView.homeWindow?.moveTabToNewWindow(nil)

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoTab(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            tab: ghostty_action_goto_tab_e) -> Bool {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("goto tab does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // Similar to goto_split (see comment there) about our performability,
                    // we should make this more accurate later.
                    guard (surfaceView.homeWindow?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: Notification.ghosttyGotoTab,
                        object: surfaceView,
                        userInfo: [
                            Notification.GotoTabKey: tab,
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            direction: ghostty_action_goto_split_e) -> Bool {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("goto split does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController else { return false }

                    // If the window has no splits, the action is not performable
                    guard controller.surfaceTree.isSplit else { return false }

                    // Convert the C API direction to our Swift type
                    guard let splitDirection = SplitFocusDirection.from(direction: direction) else { return false }

                    // Find the current node in the tree
                    guard let targetNode = controller.surfaceTree.root?.node(view: surfaceView) else { return false }

                    // Check if a split actually exists in the target direction before
                    // returning true. This ensures performable keybinds only consume
                    // the key event when we actually perform navigation.
                    let focusDirection: SplitTree<Ghostty.SurfaceView>.FocusDirection = splitDirection.toSplitTreeFocusDirection()
                    guard controller.surfaceTree.focusTarget(for: focusDirection, from: targetNode) != nil else {
                        return false
                    }

                    // We have a valid target, post the notification to perform the navigation
                    NotificationCenter.default.post(
                        name: Notification.ghosttyFocusSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.SplitDirectionKey: splitDirection as Any,
                        ]
                    )

                    return true

                default:
                    assertionFailure()
                    return false
                }
        }

        private static func gotoWindow(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            direction: ghostty_action_goto_window_e
        ) -> Bool {
            // Collect candidate windows: visible terminal windows that are either
            // standalone or the currently selected tab in their tab group. This
            // treats each native tab group as a single "window" for navigation
            // purposes, since goto_tab handles per-tab navigation.
            let candidates: [NSWindow] = NSApplication.shared.windows.filter { window in
                guard window.windowController is BaseTerminalController else { return false }
                guard window.isVisible, !window.isMiniaturized else { return false }
                // For native tabs, only include the selected tab in each group
                if let group = window.tabGroup, group.selectedWindow !== window {
                    return false
                }
                return true
            }

            // Need at least two windows to navigate between
            guard candidates.count > 1 else { return false }

            // Find starting index from the current key/main window
            let startIndex = candidates.firstIndex(where: { $0.isKeyWindow })
                ?? candidates.firstIndex(where: { $0.isMainWindow })
                ?? 0

            let step: Int
            switch direction {
            case GHOSTTY_GOTO_WINDOW_NEXT:
                step = 1
            case GHOSTTY_GOTO_WINDOW_PREVIOUS:
                step = -1
            default:
                return false
            }

            // Iterate with wrap-around until we find a valid window or return to start
            let count = candidates.count
            var index = (startIndex + step + count) % count

            while index != startIndex {
                let candidate = candidates[index]
                if candidate.isVisible, !candidate.isMiniaturized {
                    candidate.makeKeyAndOrderFront(nil)
                    // Also focus the terminal surface within the window
                    if let controller = candidate.windowController as? BaseTerminalController,
                       let surface = controller.focusedSurface {
                        Ghostty.moveFocus(to: surface)
                    }
                    return true
                }
                index = (index + step + count) % count
            }

            return false
        }

        private static func resizeSplit(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            resize: ghostty_action_resize_split_s) -> Bool {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("resize split does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController else { return false }

                    // If the window has no splits, the action is not performable
                    guard controller.surfaceTree.isSplit else { return false }

                    guard let resizeDirection = SplitResizeDirection.from(direction: resize.direction) else { return false }
                    NotificationCenter.default.post(
                        name: Notification.didResizeSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.ResizeSplitDirectionKey: resizeDirection,
                            Notification.ResizeSplitAmountKey: resize.amount,
                        ]
                    )
                    return true

                default:
                    assertionFailure()
                    return false
                }
        }

        private static func equalizeSplits(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("equalize splits does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didEqualizeSplits,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        /// A stack's verb from a key binding, the command palette or an
        /// agent's `terminal_action`: carried out on the pane of the
        /// surface it names. Answers whether there was anything to do, so
        /// that a binding with nothing to do falls through.
        private static func paneStack(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            verb: ghostty_action_pane_stack_e) -> Bool {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  let controller = BaseTerminalController.controller(owning: surfaceView)
            else { return false }
            let what: PaneStackRules.Verb
            switch verb {
            case GHOSTTY_PANE_STACK_NEW: what = .new
            case GHOSTTY_PANE_STACK_NEXT: what = .next
            case GHOSTTY_PANE_STACK_PREVIOUS: what = .previous
            case GHOSTTY_PANE_STACK_OUT: what = .out
            case GHOSTTY_PANE_STACK_ONTO_NEXT: what = .ontoNext
            case GHOSTTY_PANE_STACK_ONTO_PREVIOUS: what = .ontoPrevious
            default: return false
            }
            guard controller.offers(stack: what, at: surfaceView) else { return false }
            controller.perform(stack: what, at: surfaceView)
            return true
        }

        private static func toggleSplitZoom(
            _ app: ghostty_app_t,
            target: ghostty_target_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle split zoom does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController else { return false }

                // If the window has no splits, the action is not performable
                guard controller.surfaceTree.isSplit else { return false }

                NotificationCenter.default.post(
                    name: Notification.didToggleSplitZoom,
                    object: surfaceView
                )
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func controlInspector(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode: ghostty_action_inspector_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle inspector does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didControlInspector,
                    object: surfaceView,
                    userInfo: ["mode": mode]
                )

            default:
                assertionFailure()
            }
        }

        private static func exportTerminalIO(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_export_terminal_io_s
        ) -> Bool {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  let window = surfaceView.window,
                  let contents = v.contents
            else { return false }

            // The action data is borrowed for the duration of this callback,
            // so copy it before presenting the asynchronous save panel.
            let data = Data(bytes: contents, count: v.len)
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = "ghostty-terminal-io.txt"
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        Ghostty.logger.error(
                            "Failed to export terminal IO events: \(error, privacy: .public)"
                        )
                    }
                }
            }

            return true
        }

        private static func showDesktopNotification(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            n: ghostty_action_desktop_notification_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("desktop notification does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: n.title!, encoding: .utf8) else { return }
                guard let body = String(cString: n.body!, encoding: .utf8) else { return }
                showDesktopNotification(surfaceView, title: title, body: body)

            default:
                assertionFailure()
            }
        }

        private static func showDesktopNotification(
            _ surfaceView: SurfaceView,
            title: String,
            body: String,
            requireFocus: Bool = true) {
            // Asked here, on the main thread, as it is raised: the core is
            // asked from its own thread only, and the settings callback
            // below is not on it (task 1538).
            let group = notificationGroup(of: surfaceView)
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error = error {
                    Ghostty.logger.error("Error while requesting notification authorization: \(error, privacy: .public)")
                }
            }

            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                surfaceView.showUserNotification(
                    title: title,
                    body: body,
                    requireFocus: requireFocus,
                    group: group
                )
            }
        }

        /// The group a click on a notification from this terminal opens the
        /// control room at, as the core says now; nil when it is in none
        /// (`ghostty_app_notification_group`, task 1538).
        private static func notificationGroup(of surfaceView: SurfaceView) -> String? {
            guard let surface = surfaceView.surface, let app = ghostty_surface_app(surface) else { return nil }
            let id = ghostty_surface_poltergeist_id(surface)
            // The persona buffer rule; zero bytes is no group.
            let size = ghostty_app_notification_group(app, id, nil, 0)
            guard size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(size) + 1)
            let written = buf.withUnsafeMutableBufferPointer {
                ghostty_app_notification_group(app, id, $0.baseAddress, UInt($0.count))
            }
            guard written > 0, written <= size else { return nil }
            return String(bytes: buf.prefix(Int(written)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }

        /// The control room calling the person (task 1505): a system
        /// notification with a sound, about a group, that goes to the
        /// control room with that group selected when clicked.
        ///
        /// **Not silent when it cannot be shown**: with no permission for
        /// notifications, the log says so, every time, with the group --
        /// the person asked why none came, and "it was not allowed" is an
        /// answer only if it is written down.
        private static func controlRoomAlert(_ a: ghostty_control_room_alert_s) {
            let kind: ControlRoomAlert.Kind
            switch a.kind {
            case GHOSTTY_CONTROL_ROOM_ALERT_NEEDS_APPROVAL: kind = .needsApproval
            case GHOSTTY_CONTROL_ROOM_ALERT_NEEDS_ANSWER: kind = .needsAnswer
            case GHOSTTY_CONTROL_ROOM_ALERT_FAILED: kind = .failed
            default:
                Ghostty.logger.warning("control room alert of a kind this app does not know: \(a.kind.rawValue)")
                return
            }
            let group = a.group.map { String(cString: $0) } ?? ""
            let who = a.who.map { String(cString: $0) } ?? ""
            let text = a.text.map { String(cString: $0) } ?? ""
            let content = UNMutableNotificationContent()
            content.title = ControlRoomAlert.title(kind: kind, group: group)
            content.body = ControlRoomAlert.body(who: who, text: text, more: Int(a.more))
            content.sound = .default
            content.userInfo = [ControlRoomAlert.groupKey: group]

            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    Ghostty.logger.error("control room alert: asking for permission failed: \(error, privacy: .public)")
                }
            }
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    Ghostty.logger.warning("control room alert for group \(group, privacy: .public) not shown: notifications are not allowed for Polter (status \(settings.authorizationStatus.rawValue))")
                    return
                }
                let request = UNNotificationRequest(identifier: "control-room-\(UUID().uuidString)", content: content, trigger: nil)
                center.add(request) { error in
                    if let error {
                        Ghostty.logger.error("control room alert for group \(group, privacy: .public) was not taken: \(error, privacy: .public)")
                    } else {
                        Ghostty.logger.info("control room alert for group \(group, privacy: .public) handed to the system")
                    }
                }
            }
        }

        private static func commandFinished(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_command_finished_s
        ) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("command finished does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                // Determine if we even care about command finish notifications
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config else { return }
                switch config.notifyOnCommandFinish {
                case .never:
                    return

                case .unfocused:
                    if surfaceView.focused { return }

                case .always:
                    break
                }

                // Determine if the command was slow enough
                let duration = Duration.nanoseconds(v.duration)
                guard Duration.nanoseconds(v.duration) >= config.notifyOnCommandFinishAfter else { return }

                let actions = config.notifyOnCommandFinishAction

                if actions.contains(.bell) {
                    NotificationCenter.default.post(
                        name: .ghosttyBellDidRing,
                        object: surfaceView
                    )
                }

                if actions.contains(.notify) {
                    let title: String
                    if v.exit_code < 0 {
                        title = String(localized: "Command Finished", comment: "命令结束的系统通知标题：不知道成没成")
                    } else if v.exit_code == 0 {
                        title = String(localized: "Command Succeeded", comment: "命令结束的系统通知标题：成功")
                    } else {
                        title = String(localized: "Command Failed", comment: "命令结束的系统通知标题：失败")
                    }

                    let body: String
                    let formattedDuration = duration.formatted(
                        .units(
                            allowed: [.hours, .minutes, .seconds, .milliseconds],
                            width: .abbreviated,
                            fractionalPart: .hide
                        )
                    )
                    if v.exit_code < 0 {
                        body = String(localized: "Command took \(formattedDuration).", comment: "命令结束的系统通知正文，%@ 是用时")
                    } else {
                        body = String(localized: "Command took \(formattedDuration) and exited with code \(String(v.exit_code)).", comment: "命令结束的系统通知正文，%1$@ 是用时，%2$@ 是退出码")
                    }

                    showDesktopNotification(
                        surfaceView,
                        title: title,
                        body: body,
                        requireFocus: false
                    )
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleFloatWindow(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode mode_raw: ghostty_action_float_window_e
        ) {
            guard let mode = SetFloatWIndow.from(mode_raw) else { return }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle float window does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let window = surfaceView.window as? TerminalWindow else { return }

                switch mode {
                case .on:
                    window.level = .floating

                case .off:
                    window.level = .normal

                case .toggle:
                    window.level = window.level == .floating ? .normal : .floating
                }

                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.syncFloatOnTopMenu(window)
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleBackgroundOpacity(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("toggle background opacity does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface,
                    let surfaceView = self.surfaceView(from: surface),
                    let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController else { return }

                controller.toggleBackgroundOpacity()

            default:
                assertionFailure()
            }
        }

        private static func toggleSecureInput(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            mode mode_raw: ghostty_action_secure_input_e
        ) {
            guard let mode = SetSecureInput.from(mode_raw) else { return }

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
                appDelegate.setSecureInput(mode)

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let appState = self.appState(fromView: surfaceView) else { return }
                guard appState.config.autoSecureInput else { return }

                switch mode {
                case .on:
                    surfaceView.passwordInput = true

                case .off:
                    surfaceView.passwordInput = false

                case .toggle:
                    surfaceView.passwordInput = !surfaceView.passwordInput
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleQuickTerminal(
            _ app: ghostty_app_t,
            target: ghostty_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleQuickTerminal(self)
        }

        private static func setTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_set_title_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: v.title!, encoding: .utf8) else { return }
                // `is_explicit`: a caller chose this title on purpose
                // (`set_surface_title`), as opposed to the program
                // reporting one via OSC -- see `setExplicitTitle`.
                if v.is_explicit {
                    surfaceView.setExplicitTitle(title)
                } else {
                    surfaceView.setTitle(title)
                }

            default:
                assertionFailure()
            }
        }

        private static func setTabTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_set_title_s
        ) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set tab title does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let title = String(cString: v.title!, encoding: .utf8) else { return false }
                let titleOverride = title.isEmpty ? nil : title
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let window = surfaceView.homeWindow,
                      let controller = window.windowController as? BaseTerminalController
                else { return false }
                controller.titleOverride = titleOverride
                return true

            default:
                assertionFailure()
                return false
            }
        }

        /// Fired once, at surface init, naming the file this surface's
        /// captured commands are being appended to (see `Surface.zig`'s
        /// `history_filename` -- it's a one-time value decided at spawn,
        /// not something that changes later the way `pwd` does). Just
        /// remembered on the surface; "Save as Project" reads it from
        /// there when it needs `Leaf.history`.
        private static func historyFilename(
            target: ghostty_target_s,
            v: ghostty_action_history_filename_s
        ) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("history filename does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let filename = String(cString: v.filename!, encoding: .utf8) else { return false }
                surfaceView.historyFilename = filename
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func showChildExited(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_surface_message_childexited_s,
        ) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                // We handle this when the window is visible and timetime_ms is greater than 0,
                // which will rule out exit codes on launch
                guard surfaceView.window != nil, v.timetime_ms > 0 else { return false }
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config else { return false }
                surfaceView.setChildExitedMessage(.init(v, threshold: config.abnormalCommandExitRuntime))
                return true
            default:
                return false
            }
        }

        private static func copyTitleToClipboard(
            _ app: ghostty_app_t,
            target: ghostty_target_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                let title = surfaceView.title
                if title.isEmpty { return false }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(title, forType: .string)
                return true

            default:
                return false
            }
        }

        /// How many terminals share a tab with the target surface.
        ///
        /// **A fact this side owns and the core does not.** The core places a
        /// supervisor's worker terminals against a budget it keeps; the
        /// budget needs to know how full the tab already is, and nothing in
        /// the core knows which surfaces share a tab. So it hands over a cell
        /// and reads what goes in it.
        ///
        /// ⚠️ **Writing nothing is a real answer** -- the cell arrives zero,
        /// and a tab holding the target holds at least that terminal, so zero
        /// can only mean "not answered". Returning false without writing is
        /// how this says "I could not tell you", and the core opens a tab
        /// instead of a split.
        ///
        /// **No number from the budget belongs in here.** A copy of it on
        /// this side would put the two platforms' placements out of step
        /// while every log line and every reply read the same.
        private static func poltergeistTabPanes(
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_tab_panes_s) -> Bool {
            guard let cell = v.count else { return false }
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  let controller = surfaceView.homeWindow?.windowController as? BaseTerminalController
            else { return false }

            // A macOS "tab" is this controller's own window; what the user
            // sees as tabs are windows in a tab group. So the panes sharing a
            // tab with this surface are the leaves of this controller's tree.
            // Panes, not terminals: what is asked is how much room the tab
            // has, and terminals stacked behind another take none.
            let panes = controller.surfaceTree.shownLeaves().count
            guard panes > 0 else { return false }
            cell.pointee = UInt32(panes)
            return true
        }

        /// Which window and which tab this surface is in, as two opaque keys.
        ///
        /// **Addresses of live objects, deliberately.** They are never
        /// looked up and never stored: the only thing anybody may do with
        /// them is compare two of them. An address is the cheapest value
        /// that is unique among live objects and can never be zero, and zero
        /// is what tells the core this apprt did not answer.
        ///
        /// The two keys differ on this platform and that is the whole point.
        /// What the user calls a tab is its own window inside a tab group
        /// (see `poltergeistTabPanes`), so:
        ///   - the panes sharing one tab share that window, and
        ///   - the tabs of one window share that window's tab group.
        /// A window in no tab group is a window of one tab, so it stands in
        /// for its own group -- which keeps "same window" true for the panes
        /// inside it rather than leaving them ungrouped.
        private static func poltergeistGrouping(
            target: ghostty_target_s,
            v: ghostty_action_poltergeist_grouping_s) -> Bool {
            guard let windowCell = v.window, let tabCell = v.tab else { return false }
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  // **The tab whose tree holds it, not the window the view
                  // hangs in** (task 1571). The two differ twice: a terminal
                  // stacked behind another hangs in no window at all, and one
                  // a layout has just moved still hangs in its old window
                  // until the next drawing pass -- so the "after" reading of
                  // a move came back as "before", and `moved` said nothing
                  // had. The view's own window is the answer only when no
                  // tab claims it.
                  let window = TerminalController.all.first(where: { $0.surfaceTree.contains(surfaceView) })?.window
                      ?? surfaceView.homeWindow,
                  // Same gate as `poltergeistTabPanes`: only a terminal
                  // window has a tab and panes to talk about.
                  window.windowController is BaseTerminalController
            else { return false }

            let group: AnyObject = window.tabGroup ?? window
            tabCell.pointee = UInt64(UInt(bitPattern: ObjectIdentifier(window)))
            windowCell.pointee = UInt64(UInt(bitPattern: ObjectIdentifier(group)))

            // Where the tab stands in its strip and what the strip calls it
            // (task 1571), when the core asked. A window in no group is a
            // strip of one.
            if let info = v.info {
                let strip = window.tabGroup?.windows ?? [window]
                if let index = strip.firstIndex(where: { $0 === window }) {
                    info.pointee.index = UInt32(index)
                }
                if let buf = info.pointee.title, info.pointee.cap > 0 {
                    // Cut on a character, never inside one.
                    var bytes = Array(window.title.utf8)
                    if bytes.count > info.pointee.cap {
                        var cut = info.pointee.cap
                        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 { cut -= 1 }
                        bytes = Array(bytes[0..<cut])
                    }
                    buf.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { dst in
                        for (i, b) in bytes.enumerated() { dst[i] = b }
                    }
                    info.pointee.len = bytes.count
                }
            }
            return true
        }

        /// Move the target's whole tab (`polter_tab_move`, task 1571). See
        /// `TerminalController.polterMoveTab`; this is the C ABI glue.
        private static func polterTabMove(
            target: ghostty_target_s,
            v: ghostty_action_polter_tab_move_s) -> Bool {
            guard let out = v.out else { return false }
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  let controller = TerminalController.all.first(where: { $0.surfaceTree.contains(surfaceView) })
            else { return false }

            let into: TerminalController? = v.window == 0 ? nil : TerminalController.all.first { c in
                c.surfaceTree.contains { PoltergeistLayoutCell.surfaceHandle(for: $0).map(UInt64.init) == v.window }
            }
            let answer: (applied: Bool, text: String)
            if v.window != 0 && into == nil {
                answer = (false, "the terminal named as the window is not in a terminal tab")
            } else {
                answer = controller.polterMoveTab(to: Int(v.index), into: into)
            }

            out.pointee.result = answer.applied ? GHOSTTY_ACTION_POLTERGEIST_LAYOUT_APPLIED : GHOSTTY_ACTION_POLTERGEIST_LAYOUT_REFUSED
            let bytes = Array(answer.text.utf8)
            let n = min(bytes.count, out.pointee.cap)
            out.pointee.len = n
            if n > 0, let buf = out.pointee.buf {
                buf.withMemoryRebound(to: UInt8.self, capacity: n) { dst in
                    for i in 0..<n { dst[i] = bytes[i] }
                }
            }
            return true
        }

        /// Light the target up for `terminal_highlight` (task 1689). See
        /// `PolterHighlight`; this is the C ABI glue. Answered before it
        /// returns, as the core expects.
        private static func polterHighlight(
            target: ghostty_target_s,
            v: ghostty_action_polter_highlight_s) -> Bool {
            guard let out = v.out else { return false }
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface)
            else { return false }

            let label = v.label.map { String(cString: $0) }
            let answer = MainActor.assumeIsolated {
                PolterHighlight.shared.perform(surface: surfaceView, seconds: v.seconds, label: label)
            }

            out.pointee.result = answer.applied ? GHOSTTY_ACTION_POLTERGEIST_LAYOUT_APPLIED : GHOSTTY_ACTION_POLTERGEIST_LAYOUT_REFUSED
            let bytes = Array(answer.text.utf8)
            let n = min(bytes.count, out.pointee.cap)
            out.pointee.len = n
            if n > 0, let buf = out.pointee.buf {
                buf.withMemoryRebound(to: UInt8.self, capacity: n) { dst in
                    for i in 0..<n { dst[i] = bytes[i] }
                }
            }
            return true
        }

        private static func promptTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_prompt_title_e) -> Bool {
            let promptTitle = Action.PromptTitle(v)
            switch promptTitle {
            case .surface:
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("set title prompt does nothing with an app target")
                    return false

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    surfaceView.promptTitle()
                    return true

                default:
                    assertionFailure()
                    return false
                }

            // **`.tab` and `.window` are one operation on this platform, and
            // that is a fact about macOS rather than a shortcut.** A
            // `BaseTerminalController` owns exactly one `NSWindow`; what the
            // user sees as tabs are windows joined into a tab group. The
            // rename both scopes want is `titleOverride`, whose own comment
            // calls it "an override title for the tab/window" and which sets
            // `window.title` through `applyTitleToWindow`. Splitting them
            // would need two names for one string.
            case .tab, .window:
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
                          let controller = window.windowController as? BaseTerminalController
                    else { return false }
                    controller.promptTabTitle()
                    return true

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let window = surfaceView.homeWindow,
                          let controller = window.windowController as? BaseTerminalController
                    else { return false }
                    controller.promptTabTitle()
                    return true

                default:
                    assertionFailure()
                    return false
                }

            // **Refused by name, and the refusal is the feature.** A scope
            // this build has no case for is a newer core talking to an older
            // app. Doing nothing and saying so lets the core log a failed
            // action; picking whichever scope happens to be nearest is how
            // `GHOSTTY_PROMPT_TITLE_WINDOW` spent its life renaming panes.
            case .unknown:
                Ghostty.logger.warning(
                    "prompt title requested for a scope this build does not know; doing nothing")
                return false
            }
        }

        private static func pwdChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_pwd_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("pwd change does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let pwd = String(cString: v.pwd!, encoding: .utf8) else { return }
                surfaceView.pwd = pwd

            default:
                assertionFailure()
            }
        }

        private static func setMouseShape(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            shape: ghostty_action_mouse_shape_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.setCursorShape(shape)

            default:
                assertionFailure()
            }
        }

        private static func setMouseVisibility(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_visibility_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                switch v {
                case GHOSTTY_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)

                case GHOSTTY_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)

                default:
                    return
                }

            default:
                assertionFailure()
            }
        }

        private static func setMouseOverLink(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_over_link_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    return
                }

                let buffer = Data(bytes: v.url!, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)

            default:
                assertionFailure()
            }
        }

        private static func setInitialSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_initial_size_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("initial size does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.initialSize = NSSize(width: Double(v.width), height: Double(v.height))

            default:
                assertionFailure()
            }
        }

        private static func resetWindowSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("reset window size does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyResetWindowSize,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func setCellSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_cell_size_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }

            default:
                assertionFailure()
            }
        }

        private static func renderInspector(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.inspectorNeedsDisplay,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func rendererHealth(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_renderer_health_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: [
                        "health": v,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func keySequence(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_key_sequence_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("key sequence does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                DispatchQueue.main.async {
                    if v.active {
                        NotificationCenter.default.post(
                            name: Notification.didContinueKeySequence,
                            object: surfaceView,
                            userInfo: [
                                Notification.KeySequenceKey: keyboardShortcut(for: v.trigger) as Any
                            ]
                        )
                    } else {
                        NotificationCenter.default.post(
                            name: Notification.didEndKeySequence,
                            object: surfaceView
                        )
                    }
                }

            default:
                assertionFailure()
            }
        }

        private static func keyTable(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_key_table_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("key table does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let action = Ghostty.Action.KeyTable(c: v) else { return }

                NotificationCenter.default.post(
                    name: Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Notification.KeyTableKey: action]
                )

            default:
                assertionFailure()
            }
        }

        private static func progressReport(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_progress_report_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("progress report does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config else { return }

                guard config.progressStyle else {
                    Ghostty.logger.debug("progress_report action blocked by config")
                    DispatchQueue.main.async {
                        surfaceView.progressReport = nil
                    }
                    return
                }

                let progressReport = Ghostty.Action.ProgressReport(c: v)
                DispatchQueue.main.async {
                    if progressReport.state == .remove {
                        surfaceView.progressReport = nil
                    } else {
                        surfaceView.progressReport = progressReport
                    }
                }

            default:
                assertionFailure()
            }
        }

        private static func scrollbar(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_scrollbar_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("scrollbar does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let scrollbar = Ghostty.Action.Scrollbar(c: v)
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateScrollbar,
                    object: surfaceView,
                    userInfo: [
                        SwiftUI.Notification.Name.ScrollbarKey: scrollbar
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func startSearch(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_start_search_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("start_search does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let startSearch = Ghostty.Action.StartSearch(c: v)
                DispatchQueue.main.async {
                    if let searchState = surfaceView.searchState {
                        if let needle = startSearch.needle, !needle.isEmpty {
                            searchState.setNeedle(needle)
                        }
                    } else {
                        surfaceView.searchState = Ghostty.SurfaceView.SearchState(from: startSearch)
                    }

                    NotificationCenter.default.post(name: .ghosttySearchFocus, object: surfaceView)
                }

            default:
                assertionFailure()
            }
        }

        private static func endSearch(
            _ app: ghostty_app_t,
            target: ghostty_target_s) -> Bool {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("end_search does nothing with an app target")
                return false

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                DispatchQueue.main.async {
                    surfaceView.endSearch()
                }
                return true
            default:
                assertionFailure()
                return false
            }
        }

        private static func searchTotal(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_search_total_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("search_total does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let total: UInt? = v.total >= 0 ? UInt(v.total) : nil
                DispatchQueue.main.async {
                    surfaceView.searchState?.total = total
                }

            default:
                assertionFailure()
            }
        }

        private static func searchSelected(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_search_selected_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("search_selected does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let selected: UInt? = v.selected >= 0 ? UInt(v.selected) : nil
                DispatchQueue.main.async {
                    surfaceView.searchState?.selected = selected
                }

            default:
                assertionFailure()
            }
        }

        private static func configReload(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_reload_config_s) {
            logger.info("config reload notification")

            guard let app_ud = ghostty_app_userdata(app) else { return }
            let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                ghostty.reloadConfig(soft: v.soft)
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                ghostty.reloadConfig(surface: surface, soft: v.soft)

            default:
                assertionFailure()
            }
        }

        private static func configChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_config_change_s) {
                logger.info("config change notification")

                // Clone the config so we own the memory. It'd be nicer to not have to do
                // this but since we async send the config out below we have to own the lifetime.
                // A future improvement might be to add reference counting to config or
                // something so apprt's do not have to do this.
                let config = Config(clone: v.config)

                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    // Notify the world that the app config changed
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                    // We also REPLACE our app-level config when this happens. This lets
                    // all the various things that depend on this but are still theme specific
                    // such as split border color work.
                    guard let app_ud = ghostty_app_userdata(app) else { return }
                    let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
                    ghostty.config = config

                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                default:
                    assertionFailure()
                }
            }

        private static func colorChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            change: ghostty_action_color_change_s) {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("color change does nothing with an app target")
                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyColorDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.GhosttyColorChangeKey: Action.ColorChange(c: change)
                        ]
                    )

                default:
                    assertionFailure()
                }
        }

        // MARK: User Notifications

        /// Handle a received user notification. This is called when a user notification is clicked or dismissed by the user
        func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            // A terminal's own notification is remembered by its terminal
            // until clicked or dismissed, wherever the click goes.
            let surface = (userInfo["surface"] as? String).flatMap(UUID.init(uuidString:))
                .flatMap { delegate?.findSurface(forUUID: $0) }
            if case .controlRoom(let group) = NotificationClick.of(userInfo) {
                switch response.actionIdentifier {
                case UNNotificationDefaultActionIdentifier, Ghostty.userNotificationActionShow:
                    surface?.handleUserNotification(notification: response.notification, focus: false)
                    ControlRoomController.show(self, selecting: group)
                case UNNotificationDismissActionIdentifier:
                    surface?.handleUserNotification(notification: response.notification, focus: false)
                default:
                    break
                }
                return
            }
            guard let surface else { return }

            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier, Ghostty.userNotificationActionShow:
                // The user clicked on a notification
                surface.handleUserNotification(notification: response.notification, focus: true)
            case UNNotificationDismissActionIdentifier:
                // The user dismissed the notification
                surface.handleUserNotification(notification: response.notification, focus: false)
            default:
                break
            }
        }
    }
}
