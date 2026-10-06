import AppKit
import GhosttyKit
import OSLog

/// Taking a screenshot, from the trigger to where the result goes
/// (`dev-docs/poltergeist/screenshot.md`, section 3).
final class ScreenshotController: ShotOverlayDelegate {
    static let shared = ScreenshotController()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ScreenshotController.self)
    )

    /// How long after the image's path the annotation line is pasted. They
    /// are two pastes on purpose -- a CLI takes the first as an attachment
    /// only when the paste is exactly one path -- and this keeps the second
    /// from arriving inside the first one's handling.
    static let secondPasteDelay: TimeInterval = 0.15

    private let hotKey = ShotGlobalHotKey()
    private var mouse: ShotMouseTrigger?
    private var warnedAboutHotKey = false

    /// A screenshot in progress: the overlays, and where the result should
    /// also be pasted.
    private struct Session {
        var overlays: [(window: ShotOverlayWindow, view: ShotOverlayView)]
        /// The terminal that had the focus when the screenshot was started,
        /// if this app was the one in front. Nil otherwise, and then nothing
        /// is pasted.
        weak var target: Ghostty.SurfaceView?
        var directory: URL
    }

    private var session: Session?
    /// Set from the trigger until the overlays are up, so that a second
    /// trigger in that gap -- the hotkey arriving twice, or a double-click
    /// and the hotkey together -- does not start a second screenshot.
    private var starting = false

    // MARK: Triggers

    /// Register the hotkey and the mouse gesture the configuration asks for.
    /// Called at launch and again whenever the configuration changes.
    func configure(_ config: Ghostty.Config) {
        configureHotKey(config)
        configureMouse(config)
    }

    private func configureHotKey(_ config: Ghostty.Config) {
        guard let spec = Self.hotKeySpec(config) else {
            if hotKey.registered != nil {
                Self.logger.info("screenshot: no usable keybind, hotkey unregistered")
            }
            hotKey.unregister()
            return
        }
        guard spec != hotKey.registered else { return }

        let status = hotKey.register(spec) { [weak self] in self?.trigger() }
        if status == noErr {
            Self.logger.info("screenshot: hotkey registered keyCode=\(spec.keyCode, privacy: .public) modifiers=\(spec.modifiers, privacy: .public)")
            return
        }

        // Said, and said once: a hotkey that silently does nothing looks
        // exactly like a feature that is not there.
        Self.logger.error("screenshot: the hotkey could not be registered, status=\(status, privacy: .public)")
        guard !warnedAboutHotKey else { return }
        warnedAboutHotKey = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "The screenshot shortcut could not be registered",
            comment: "截图热键注册失败的提示")
        alert.informativeText = String(
            localized: "Another application is already using it. Choose a different one with a `screenshot` keybind in the configuration.",
            comment: "截图热键注册失败的提示")
        alert.addButton(withTitle: String(localized: "OK", comment: "截图热键注册失败的提示"))
        alert.runModal()
    }

    /// The `screenshot` keybind as a hotkey registration, or nil when there
    /// is none or it cannot be one (no modifier, or a key with no position
    /// this can name).
    private static func hotKeySpec(_ config: Ghostty.Config) -> ShotHotKey.Spec? {
        guard let trigger = config.keybindTrigger(for: "screenshot") else { return nil }
        let mods = ShotMods(rawValue: trigger.mods.rawValue)

        let keyCode: UInt32?
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            keyCode = trigger.key.unicode == 0 ? nil : ShotHotKey.keyCode(forUnicode: trigger.key.unicode)
        case GHOSTTY_TRIGGER_PHYSICAL:
            keyCode = Ghostty.Input.Key.allCases
                .first(where: { $0.cKey == trigger.key.physical })?
                .keyCode.map(UInt32.init)
        default:
            keyCode = nil
        }
        return ShotHotKey.spec(keyCode: keyCode, mods: mods)
    }

    private func configureMouse(_ config: Ghostty.Config) {
        let required = ShotMods(rawValue: config.screenshotMouseTrigger).intersection(.all)
        guard required != mouse?.required ?? [] else { return }

        mouse?.stop()
        mouse = nil
        guard !required.isEmpty else { return }

        let trigger = ShotMouseTrigger(required: required) { [weak self] point in
            self?.trigger(preselecting: point)
        }
        trigger.start()
        mouse = trigger
    }

    // MARK: Starting

    /// Start a screenshot.
    ///
    /// - Parameter preselecting: where the pointer was, in AppKit's global
    ///   coordinates, when the screenshot was started by a double-click; the
    ///   window there is already selected when the overlay appears.
    func trigger(preselecting point: CGPoint? = nil) {
        guard session == nil, !starting else { return }

        guard ShotCapture.isPermitted else {
            askForPermission()
            return
        }

        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return }
        let directory = config.screenshotDirectory

        // Read before anything of ours appears: this is "was Polter in front
        // when the screenshot was started", and it decides whether the
        // result is also pasted.
        let target: Ghostty.SurfaceView? = NSApp.isActive
            ? (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
            : nil
        let windows = ShotCapture.windows()

        starting = true
        ShotCapture.captureAll { [weak self] displays in
            guard let self else { return }
            self.starting = false
            guard !displays.isEmpty else {
                Self.logger.error("screenshot: no display could be captured")
                return
            }
            self.present(displays, windows: windows, target: target, directory: directory, preselecting: point)
        }
    }

    /// Screen Recording is not granted. The first time, asking the system
    /// puts up its own prompt and that is enough. After that the system
    /// stays silent, so the explanation is ours.
    private func askForPermission() {
        let key = "ScreenshotAskedForScreenRecording"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            Self.logger.info("screenshot: asking for Screen Recording")
            ShotCapture.requestPermission()
            return
        }

        Self.logger.info("screenshot: Screen Recording is not granted")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "Polter needs the Screen Recording permission to take a screenshot",
            comment: "截图没有屏幕录制权限时的提示")
        alert.informativeText = String(
            localized: "Turn it on for Polter in System Settings, under Privacy & Security, then restart Polter.",
            comment: "截图没有屏幕录制权限时的提示")
        alert.addButton(withTitle: String(localized: "Open System Settings", comment: "截图没有屏幕录制权限时的提示"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "截图没有屏幕录制权限时的提示"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func present(
        _ displays: [ShotDisplay],
        windows: [ShotGeometry.Window],
        target: Ghostty.SurfaceView?,
        directory: URL,
        preselecting point: CGPoint?
    ) {
        var overlays: [(window: ShotOverlayWindow, view: ShotOverlayView)] = []
        for display in displays {
            // The window list is in global coordinates; the view wants its
            // own display's.
            let local = windows.map { window -> ShotGeometry.Window in
                var window = window
                window.frame = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                return window
            }
            let view = ShotOverlayView(display: display, windows: local)
            view.delegate = self
            let window = ShotOverlayWindow(display: display)
            window.contentView = view
            overlays.append((window, view))
        }
        session = Session(overlays: overlays, target: target, directory: directory)

        // The overlay under the pointer takes the keyboard.
        let mouse = NSEvent.mouseLocation
        let under = overlays.first(where: { $0.view.display.screen.frame.contains(mouse) }) ?? overlays[0]
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        under.window.makeKey()
        under.window.makeFirstResponder(under.view)

        if let point,
           let hit = overlays.first(where: { $0.view.display.screen.frame.contains(point) }) {
            // AppKit's global point, bottom-left origin, as that view's.
            let frame = hit.view.display.screen.frame
            hit.view.preselectWindow(at: CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
        }
    }

    private func dismiss() {
        guard let session else { return }
        self.session = nil
        for overlay in session.overlays {
            overlay.view.delegate = nil
            overlay.window.orderOut(nil)
            overlay.window.contentView = nil
        }
    }

    // MARK: ShotOverlayDelegate

    func overlayDidBeginSelection(_ view: ShotOverlayView) {
        guard let session else { return }
        for overlay in session.overlays where overlay.view !== view {
            overlay.view.clearSelection()
        }
        if let window = view.window, !window.isKeyWindow {
            window.makeKey()
            window.makeFirstResponder(view)
        }
    }

    /// Cancelled: nothing was written and the clipboard is as it was.
    func overlayDidCancel(_ view: ShotOverlayView) {
        dismiss()
    }

    func overlayDidFinish(_ view: ShotOverlayView) {
        guard let session, let selection = view.selection else { return }
        let display = view.display
        let annotations = view.annotations.items
        let source = view.source
        let target = session.target
        let directory = session.directory
        dismiss()

        guard let composed = ShotRenderer.composite(
                display: display, selection: selection, annotations: annotations),
              let png = ShotRenderer.png(composed.image) else {
            Self.logger.error("screenshot: the image could not be composed")
            return
        }

        // 1. The clipboard, so it can be pasted anywhere.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: composed.image).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }

        // 2. The file, and what was drawn as data beside it.
        let now = Date()
        let url: URL
        do {
            url = try ShotStore.write(png: png, to: directory, date: now)
        } catch {
            Self.logger.error("screenshot: could not write to \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let scale = display.scale
        let items = ShotExport.items(
            annotations,
            selectionOrigin: CGPoint(x: composed.pixels.minX / scale, y: composed.pixels.minY / scale),
            scale: scale)
        let metadata = ShotExport.Metadata(
            image: url.lastPathComponent,
            takenAt: now,
            timeZone: .current,
            pixelWidth: composed.image.width,
            pixelHeight: composed.image.height,
            scale: Double(scale),
            source: source)
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        let json = Data(ShotExport.json(metadata, items: items).utf8)
        if !FileManager.default.createFile(
            atPath: jsonURL.path, contents: json, attributes: [.posixPermissions: 0o600]) {
            Self.logger.error("screenshot: could not write \(jsonURL.path, privacy: .public)")
        }

        let line = ShotExport.line(
            items: items,
            pixelWidth: composed.image.width,
            pixelHeight: composed.image.height,
            jsonPath: jsonURL.path,
            words: Self.words)

        // A later paste of this image finds this file, and its annotations,
        // instead of writing the image a second time.
        ImagePasteService.shared.remember(changeCount: pasteboard.changeCount, url: url, annotations: line)
        Self.logger.info("screenshot: \(composed.image.width, privacy: .public)x\(composed.image.height, privacy: .public) written to \(url.path, privacy: .public), \(items.count, privacy: .public) annotations")

        // 3. Into the terminal, if this app was in front when it started.
        guard let target else { return }
        let path = Ghostty.Shell.escape(url.path)
        MainActor.assumeIsolated { target.surfaceModel?.sendText(path) }
        if let line {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondPasteDelay) { [weak target] in
                MainActor.assumeIsolated { target?.surfaceModel?.sendText(line) }
            }
        }
    }

    /// The words of the annotation line in the app's language. The English
    /// ones are the msgids `src/input/screenshot.zig` names.
    private static var words: ShotExport.Words {
        .init(
            header: String(localized: "Screenshot annotations", comment: "粘进终端的截图标注文本"),
            text: String(localized: "Text", comment: "粘进终端的截图标注文本"),
            rect: String(localized: "Box", comment: "粘进终端的截图标注文本"),
            arrow: String(localized: "Arrow", comment: "粘进终端的截图标注文本"),
            pen: String(localized: "Pen", comment: "粘进终端的截图标注文本"),
            separator: String(localized: "; ", comment: "粘进终端的截图标注文本：两条标注之间"),
            see: String(localized: ". See ", comment: "粘进终端的截图标注文本：最后一条标注与 json 路径之间"))
    }
}
