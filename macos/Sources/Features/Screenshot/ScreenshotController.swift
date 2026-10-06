import AppKit
import GhosttyKit
import OSLog

/// Taking a screenshot, from the trigger to where the result goes
/// (`dev-docs/poltergeist/screenshot.md`, section 3).
final class ScreenshotController: ShotSessionDelegate {
    static let shared = ScreenshotController()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ScreenshotController.self)
    )

    /// How long after the image's path the next piece is pasted -- a long
    /// screenshot's next tile, the line of text -- when the person pastes a
    /// screenshot (`Ghostty.App`'s clipboard read). They are separate
    /// pastes on purpose -- a CLI takes one as an attachment only when the
    /// paste is exactly one path -- and this keeps each from arriving
    /// inside the handling of the one before.
    static let secondPasteDelay: TimeInterval = 0.15

    private let hotKey = ShotGlobalHotKey()
    private var mouse: ShotMouseTrigger?
    private var warnedAboutHotKey = false

    /// A screenshot in progress.
    private struct Session {
        var shot: ShotSession
        /// The terminal that had the focus when the screenshot was started,
        /// if this app was the one in front, as the sidecar names it. Nil
        /// otherwise. The git state arrives a moment after the screenshot
        /// starts, if it arrives.
        ///
        /// **Only for the sidecar.** Nothing is sent to that terminal when
        /// the screenshot is finished: the person pastes it where they
        /// want it.
        var terminal: ShotSidecar.Terminal?
        var directory: URL
    }

    private var session: Session?
    /// Set from the trigger until the overlays are up, so that a second
    /// trigger in that gap -- the hotkey arriving twice, or a double-click
    /// and the hotkey together -- does not start a second screenshot.
    private var starting = false
    /// Set while the explanation of a missing permission is on screen.
    private var asking = false

    /// Whether the person is in the middle of a screenshot of their own.
    /// An agent's waits its turn: the frozen overlay is on screen, and a
    /// capture now would be a picture of it.
    var isBusy: Bool { session != nil || starting || asking }

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
        // Not from inside whatever called this: the configuration is also
        // reloaded while this app is in the background.
        DispatchQueue.main.async { _ = Self.runInFront(alert, what: "hotkey not registered") }
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

        // The same way in as the hotkey: nothing is selected for having
        // been clicked on (3.1).
        let trigger = ShotMouseTrigger(required: required) { [weak self] in
            self?.trigger()
        }
        trigger.start()
        mouse = trigger
    }

    // MARK: Starting

    /// Start a screenshot. However it was asked for -- the hotkey, the
    /// click, the menu -- it starts the same: with nothing selected.
    func trigger() {
        guard session == nil, !starting, !asking else {
            Self.logger.info("screenshot: trigger ignored (session=\(self.session != nil, privacy: .public) starting=\(self.starting, privacy: .public) asking=\(self.asking, privacy: .public))")
            return
        }

        guard ShotCapture.isPermitted else {
            askForPermission()
            return
        }

        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return }
        let directory = config.screenshotDirectory

        // Read before anything of ours appears: this is "was Polter in front
        // when the screenshot was started", and it is what the sidecar's
        // `terminal` says.
        let focused: Ghostty.SurfaceView? = NSApp.isActive
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
            self.present(displays, windows: windows, focused: focused, directory: directory)
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
        // One explanation at a time, and not from inside the hotkey's or
        // the mouse monitor's own callback: a second trigger while this is
        // up is ignored rather than queued behind it.
        asking = true
        DispatchQueue.main.async { [weak self] in
            let answer = Self.runInFront(alert, what: "Screen Recording not granted")
            self?.asking = false
            if answer == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Run `alert` where the person can see it.
    ///
    /// A screenshot is usually asked for while some other application is in
    /// front -- that is what a global hotkey is for -- and a modal alert
    /// put up by an application that is not active opens *behind* the one
    /// that is. The person sees a key that did nothing, and this
    /// application sits in a modal loop on a window nobody can find. So
    /// this application is brought forward first; and because the system
    /// may decline to do that, the alert's own window is also raised above
    /// other applications' windows and ordered front whether or not this
    /// application is the active one.
    private static func runInFront(_ alert: NSAlert, what: String) -> NSApplication.ModalResponse {
        let wasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        logger.info("screenshot: alert (\(what, privacy: .public)) shown: appActive before=\(wasActive, privacy: .public) now=\(NSApp.isActive, privacy: .public) level=\(alert.window.level.rawValue, privacy: .public) visible=\(alert.window.isVisible, privacy: .public)")
        let answer = alert.runModal()
        logger.info("screenshot: alert (\(what, privacy: .public)) answered \(answer.rawValue, privacy: .public)")
        return answer
    }

    private func present(
        _ displays: [ShotDisplay],
        windows: [ShotWindow],
        focused: Ghostty.SurfaceView?,
        directory: URL
    ) {
        guard let shot = ShotSession(displays: displays, windows: windows, prefs: Self.loadPrefs()) else {
            Self.logger.error("screenshot: a display's picture could not be read")
            return
        }
        shot.delegate = self

        var terminal: ShotSidecar.Terminal?
        if let focused, let surface = focused.surface {
            let id = ghostty_surface_poltergeist_id(surface)
            if id != 0 {
                terminal = .init(id: String(format: "0x%016llx", id), cwd: focused.pwd, git: nil)
            }
        }
        session = Session(shot: shot, terminal: terminal, directory: directory)
        shot.show()

        // Asked now and not waited for: it has the whole time the person
        // spends choosing and drawing, and if it is not back by then the
        // sidecar goes without.
        if let cwd = terminal?.cwd, !cwd.isEmpty {
            ShotContext.lookUpGit(cwd: cwd) { [weak self, weak shot] git in
                guard let self, let git, let shot, self.session?.shot === shot else { return }
                self.session?.terminal?.git = (git.head, git.dirty)
            }
        }
    }

    // MARK: The tool memory

    private static var prefsURL: URL {
        ShotStore.toolPrefsURL(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func loadPrefs() -> ToolPrefs {
        guard let data = try? Data(contentsOf: prefsURL) else { return ToolPrefs() }
        return ToolPrefs(json: String(data: data, encoding: .utf8) ?? "")
    }

    /// Keep the colour and size each tool was left with, for the next
    /// screenshot. Written whether the screenshot was finished or not.
    private static func savePrefs(_ prefs: ToolPrefs) {
        guard prefs != loadPrefs() else { return }
        let url = prefsURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data(prefs.json().utf8).write(to: url, options: .atomic)
        } catch {
            logger.error("screenshot: the tool memory could not be saved to \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: ShotSessionDelegate

    /// Cancelled: nothing was written and the clipboard is as it was.
    func sessionDidCancel(_ shot: ShotSession) {
        guard session?.shot === shot else { return }
        session = nil
        Self.savePrefs(shot.prefs)
    }

    func sessionDidFinish(_ shot: ShotSession, with result: ShotSession.Result) {
        guard let session, session.shot === shot else { return }
        self.session = nil
        Self.savePrefs(shot.prefs)
        let directory = session.directory
        let image = result.image

        guard let png = image.png() else {
            Self.logger.error("screenshot: the image could not be encoded; nothing written")
            return
        }

        // 1. The clipboard, so it can be pasted anywhere.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // A long screenshot goes on as a PNG only: uncompressed, a picture
        // twenty thousand rows tall is hundreds of megabytes of clipboard.
        let tiff = result.isLong ? nil : image.cgImage().flatMap { NSBitmapImageRep(cgImage: $0).tiffRepresentation }
        pasteboard.declareTypes(tiff == nil ? [.png] : [.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }

        // 2. The file, and what was drawn as data beside it.
        let now = Date()
        let url: URL
        do {
            url = try ShotStore.write(png: png, to: directory, date: now)
        } catch {
            Self.logger.error("screenshot: could not write to \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let name = url.lastPathComponent

        // A long screenshot is also cut into tiles: the pieces a CLI can
        // read without shrinking them. One tile would be the picture itself.
        var tiles: [ShotSidecar.Tile] = []
        var tileURLs: [URL] = []
        if result.isLong {
            let cut = image.tiles()
            for (i, tile) in cut.enumerated() where cut.count > 1 {
                let tileName = ShotStore.tileName(of: name, i + 1)
                let tileURL = directory.appendingPathComponent(tileName)
                if FileManager.default.createFile(
                    atPath: tileURL.path, contents: tile.png, attributes: [.posixPermissions: 0o600]) {
                    tiles.append(.init(image: tileName, y: tile.y, height: tile.height))
                    tileURLs.append(tileURL)
                } else {
                    Self.logger.error("screenshot: tile \(tileURL.path, privacy: .public) was not written")
                }
            }
        }

        let source: ShotSidecar.Source
        if let window = result.window {
            source = .window(
                app: window.app, title: window.title, pid: window.pid,
                windowRect: result.windowRect, selectionRect: result.selection)
        } else {
            source = .region(selectionRect: result.selection)
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let meta = ShotSidecar.Meta(
            image: name,
            taken: .init(now, timeZone: .current),
            width: image.width,
            height: image.height,
            scale: result.scale,
            by: .user,
            display: .init(
                index: result.display, width: result.displaySize.w, height: result.displaySize.h,
                scale: result.scale),
            appearance: dark ? "dark" : "light",
            source: source,
            terminal: session.terminal,
            previous: result.window.flatMap {
                ShotContext.previous(app: $0.app, title: $0.title, before: name, in: directory)
            },
            tiles: tiles)
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        let json = Data(ShotSidecar.json(meta, items: result.items).utf8)
        if !FileManager.default.createFile(
            atPath: jsonURL.path, contents: json, attributes: [.posixPermissions: 0o600]) {
            Self.logger.error("screenshot: could not write \(jsonURL.path, privacy: .public)")
        }

        // The line that ends a paste of this screenshot: its annotations,
        // or for a long one -- pasted as its tiles, at most eight of them --
        // how many tiles there are, when some were left out.
        let pastedTiles = min(tileURLs.count, ShotSidecar.maxPastedTiles)
        let line: String?
        if result.isLong {
            line = ShotSidecar.longLine(
                size: .init(image.width, image.height), tiles: tileURLs.count, pasted: pastedTiles,
                imagePath: url.path, jsonPath: jsonURL.path, labels: Self.longLabels)
        } else {
            line = ShotSidecar.line(
                width: image.width, height: image.height, items: result.items,
                jsonPath: jsonURL.path, labels: Self.labels)
        }

        // A paste of this image finds this file, its tiles and its line,
        // instead of writing the image a second time.
        ImagePasteService.shared.remember(
            changeCount: pasteboard.changeCount, url: url, tiles: tileURLs, annotations: line)
        Self.logger.info("screenshot: \(image.width, privacy: .public)x\(image.height, privacy: .public) written to \(url.path, privacy: .public), \(result.items.count, privacy: .public) annotation(s), \(tiles.count, privacy: .public) tile(s)")

        // And that is all. Nothing is sent to a terminal from here, whether
        // or not this app was in front: a path arriving in whichever pane
        // had the focus is one the person has to delete when it was meant
        // for another. They paste it, and the paste is what sends the path
        // -- a long one's tiles -- and the line remembered above.
    }

    /// The words of the annotation line in the app's language. The English
    /// ones are the msgids `src/input/screenshot.zig` names.
    private static var labels: ShotSidecar.Labels {
        // One msgid to a line, in the order of the fields.
        let words = [
            "Screenshot annotations",
            "Text",
            "Box",
            "Circle",
            "Line",
            "Arrow",
            "Pen",
            "Highlighter",
            "Mosaic",
            "; ",
            ". See ",
        ].map(ShotWords.translate)
        return .init(
            header: words[0], text: words[1], rect: words[2], ellipse: words[3], line: words[4],
            arrow: words[5], pen: words[6], highlighter: words[7], mosaic: words[8],
            separator: words[9], see: words[10])
    }

    private static var longLabels: ShotSidecar.LongLabels {
        let t = ShotWords.translate
        return .init(
            header: t("Long Screenshot"), tiles: t("{n} tiles, first {m} pasted"), whole: t("whole image"),
            separator: t("; "), see: t(". See "))
    }
}
