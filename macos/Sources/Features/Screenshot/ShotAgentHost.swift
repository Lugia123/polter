import AppKit
import ApplicationServices
import GhosttyKit
import ImageIO
import OSLog

/// The half of an agent's screenshot that touches the screen
/// (`dev-docs/poltergeist/screenshot.md`, 10.1). What the request says and
/// what it is answered with is `ShotAgent`.
///
/// Three things here are different from a person's screenshot, and all
/// three are the contract's:
///
/// * **Nothing asks.** A missing permission is a refusal the agent reads,
///   never a system prompt put in front of a person who did not start this.
/// * **Nothing is shared.** The image is written to the screenshot
///   directory and that is all: the clipboard is not touched and neither is
///   the record of the last image pasted.
/// * **A shielded terminal is painted black** before anything is composed,
///   wherever it is on screen and whether or not something covers it. A
///   screenshot is not a way round a pane the person closed to agents.
///
/// Everything here runs on the main thread, which is the app thread the
/// answer has to be given on.
final class ShotAgentHost {
    static let shared = ShotAgentHost()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ShotAgentHost.self)
    )

    /// One request at a time: a second one is told `Busy`.
    private var busy = false

    // MARK: The action

    /// Answer one request. False means this host has nothing to say to it,
    /// which the core reports as unsupported.
    func handle(_ v: ghostty_action_poltergeist_screenshot_s, terminal: Ghostty.SurfaceView?) -> Bool {
        guard let out = v.out, let spec = v.spec,
              let request = ShotAgent.parse(String(cString: spec)) else { return false }

        // Writes into the caller's buffer. An answer that does not fit is a
        // refusal that does: half a document is never left there.
        func write(_ result: ghostty_action_poltergeist_screenshot_result_e, _ text: String) {
            var result = result
            var bytes = Array(text.utf8)
            if bytes.count > out.pointee.cap {
                result = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_REFUSED
                bytes = Array(ShotAgent.Refusal(
                    code: .captureFailed, message: "The answer did not fit in the buffer it was given.").json.utf8)
            }
            guard let buf = out.pointee.buf, bytes.count <= out.pointee.cap else {
                out.pointee.result = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_UNSUPPORTED
                out.pointee.len = 0
                return
            }
            out.pointee.result = result
            out.pointee.len = bytes.count
            bytes.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress, !bytes.isEmpty else { return }
                UnsafeMutableRawPointer(buf).copyMemory(from: base, byteCount: bytes.count)
            }
        }
        func refuse(_ refusal: ShotAgent.Refusal, op: String, agent: String) {
            Self.logger.info("screenshot: agent \(agent, privacy: .public) op=\(op, privacy: .public) refused: \(refusal.code.rawValue, privacy: .public)")
            write(GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_REFUSED, refusal.json)
        }

        switch request {
        case .directory:
            write(GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_DONE, ShotAgent.directoryJSON(Self.directory().path))
            return true

        case .windows:
            let screens = Self.screens()
            let json = ShotAgent.windowsJSON(
                displays: screens.map(\.info), windows: Self.windows(on: screens), cap: out.pointee.cap)
            write(GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_DONE, json)
            return true

        case let .capture(target, items, meta):
            if let refusal = preflight(needsScreen: true, needsScrolling: false) {
                refuse(refusal, op: "capture", agent: meta.agentTerminal)
                return true
            }
            let token = out.pointee.token
            out.pointee.result = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_PENDING
            out.pointee.len = 0
            busy = true
            capture(target, items: items, meta: meta, terminal: terminal) { [weak self] result in
                self?.complete(token, result, op: "capture", target: "\(target)", agent: meta.agentTerminal)
            }
            return true

        case let .annotate(path, items, meta):
            if let refusal = preflight(needsScreen: false, needsScrolling: false) {
                refuse(refusal, op: "annotate", agent: meta.agentTerminal)
                return true
            }
            let token = out.pointee.token
            out.pointee.result = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_PENDING
            out.pointee.len = 0
            busy = true
            annotate(path, items: items, meta: meta) { [weak self] result in
                self?.complete(token, result, op: "annotate", target: path, agent: meta.agentTerminal)
            }
            return true

        case let .long(target, pages, meta):
            if let refusal = preflight(needsScreen: true, needsScrolling: true) {
                refuse(refusal, op: "long", agent: meta.agentTerminal)
                return true
            }
            let token = out.pointee.token
            out.pointee.result = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_PENDING
            out.pointee.len = 0
            busy = true
            long(target, pages: pages, meta: meta) { [weak self] result in
                self?.complete(token, result, op: "long", target: "\(target)", agent: meta.agentTerminal)
            }
            return true
        }
    }

    /// What stands in the way before anything is started. Asked with the
    /// calls that only *read* whether a permission is held: neither puts up
    /// the system's prompt.
    private func preflight(needsScreen: Bool, needsScrolling: Bool) -> ShotAgent.Refusal? {
        if busy {
            return .init(code: .busy, message: "Another screenshot an agent asked for is still being taken. Try again in a moment.")
        }
        if ScreenshotController.shared.isBusy {
            return .init(code: .busy, message: "The person at the keyboard is taking a screenshot of their own. Try again when they are done.")
        }
        if needsScreen && !ShotCapture.isPermitted {
            return .init(
                code: .screenRecordingRequired,
                message: "Polter does not have the Screen Recording permission. Ask the person to turn it on in System Settings, Privacy & Security, and restart Polter.")
        }
        if needsScrolling && !AXIsProcessTrusted() {
            return .init(
                code: .accessibilityRequired,
                message: "Scrolling another application's window needs the Accessibility permission. Ask the person to turn it on for Polter in System Settings, Privacy & Security.")
        }
        return nil
    }

    /// Give the answer to a request that was told to wait.
    ///
    /// **Never from inside the call that said "wait".** Some requests are
    /// refused before any waiting starts -- a window that is not there --
    /// and the core only knows the token once that call has returned; an
    /// answer given before then is an answer to a token nobody holds. So
    /// every answer goes round the main queue once.
    private func complete(
        _ token: UInt64, _ result: Result<String, ShotAgent.Refusal>, op: String, target: String, agent: String
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.deliver(token, result, op: op, target: target, agent: agent)
        }
    }

    private func deliver(
        _ token: UInt64, _ result: Result<String, ShotAgent.Refusal>, op: String, target: String, agent: String
    ) {
        busy = false
        let code: ghostty_action_poltergeist_screenshot_result_e
        let json: String
        switch result {
        case let .success(text):
            code = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_DONE
            json = text
            Self.logger.info("screenshot: agent \(agent, privacy: .public) op=\(op, privacy: .public) target=\(target, privacy: .public) done: \(text, privacy: .public)")
        case let .failure(refusal):
            code = GHOSTTY_ACTION_POLTERGEIST_SCREENSHOT_REFUSED
            json = refusal.json
            Self.logger.info("screenshot: agent \(agent, privacy: .public) op=\(op, privacy: .public) target=\(target, privacy: .public) refused: \(refusal.code.rawValue, privacy: .public) \(refusal.message, privacy: .public)")
        }
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else {
            Self.logger.error("screenshot: the app is gone; an agent's answer for token \(token, privacy: .public) was dropped")
            return
        }
        json.withCString { text in
            ghostty_app_poltergeist_screenshot_complete(app, token, code, text, UInt(strlen(text)))
        }
    }

    // MARK: What is on screen

    private struct Screen {
        var screen: NSScreen
        /// In the system's global coordinates, y downwards.
        var frame: CGRect
        var info: ShotAgent.DisplayInfo
    }

    /// The displays, the primary one first: the order `display` indexes.
    private static func screens() -> [Screen] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = ShotCapture.displayID(of: screen) else { return nil }
            let frame = CGDisplayBounds(id)
            let scale = Double(screen.backingScaleFactor)
            return Screen(
                screen: screen, frame: frame,
                info: .init(
                    size: .init(Int((Double(frame.width) * scale).rounded()), Int((Double(frame.height) * scale).rounded())),
                    scale: scale, primary: index == 0))
        }
    }

    private static func window(_ id: UInt64, frame: CGRect, app: String?, title: String?, pid: Int?, on screens: [Screen]) -> ShotAgent.WindowInfo? {
        guard let display = ShotAgent.display(of: frame, among: screens.map(\.frame)) else { return nil }
        return .init(
            id: id, app: app, title: title, pid: pid, display: display,
            rect: ShotAgent.rect(of: frame, on: screens[display].frame, scale: screens[display].info.scale))
    }

    /// The ordinary windows, front to back: the same ones the overlay
    /// offers to select.
    private static func windows(on screens: [Screen]) -> [ShotAgent.WindowInfo] {
        ShotCapture.windows().compactMap {
            window($0.id, frame: $0.frame, app: $0.app, title: $0.title, pid: $0.pid, on: screens)
        }
    }

    /// An AppKit rectangle (origin at the bottom left of the primary
    /// display) in the system's global coordinates (origin at its top left).
    private static func global(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The window a terminal is in, when that window is on screen.
    private static func window(of terminal: Ghostty.SurfaceView?, on screens: [Screen]) -> ShotAgent.WindowInfo? {
        guard let window = terminal?.window, window.isVisible, !window.isMiniaturized else { return nil }
        return self.window(
            UInt64(max(window.windowNumber, 0)), frame: global(window.frame),
            app: NSRunningApplication.current.localizedName, title: window.title,
            pid: Int(ProcessInfo.processInfo.processIdentifier), on: screens)
    }

    /// Every shielded terminal whose window is on screen right now, as the
    /// rectangle of its view in display `index`'s own pixels.
    ///
    /// **No test for what covers it.** A pane behind another window is
    /// painted all the same: painting too much costs a black rectangle, and
    /// getting an occlusion test wrong once is a leak.
    private static func shieldedPanes(on index: Int, of screens: [Screen]) -> [PixelRect] {
        var panes: [PixelRect] = []
        for window in NSApp.windows where window.isVisible && !window.isMiniaturized && window.isOnActiveSpace {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            for view in controller.surfaceTree where view.poltergeistShielded {
                guard view.window === window else { continue }
                let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
                panes.append(ShotAgent.rect(
                    of: global(onScreen), on: screens[index].frame, scale: screens[index].info.scale))
            }
        }
        return panes
    }

    private static func directory() -> URL {
        (NSApp.delegate as? AppDelegate)?.ghostty.config.screenshotDirectory
            ?? ShotStore.directory(
                configured: nil, environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static var appearance: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    // MARK: Writing

    private struct Written {
        var image: URL
        var json: URL
    }

    /// The sidecar's account of who asked. The git state is looked up and
    /// waited for -- an agent's request is not a person waiting at an
    /// overlay -- but only for as long as the lookup allows itself.
    private static func terminal(of meta: ShotAgent.Meta, then: @escaping (ShotSidecar.Terminal?) -> Void) {
        guard let id = meta.terminalID, !id.isEmpty else {
            then(nil)
            return
        }
        guard let cwd = meta.cwd, !cwd.isEmpty else {
            then(.init(id: id, cwd: nil, git: nil))
            return
        }
        ShotContext.lookUpGit(cwd: cwd) { git in
            then(.init(id: id, cwd: cwd, git: git.map { ($0.head, $0.dirty) }))
        }
    }

    /// Write the image and, beside it, the sidecar `sidecar` makes for the
    /// name the image got.
    private static func write(_ image: ComposedImage, sidecar: (String) -> String?) -> Result<Written, ShotAgent.Refusal> {
        guard let png = image.png() else {
            return .failure(.init(code: .captureFailed, message: "The image could not be encoded as a PNG."))
        }
        let directory = self.directory()
        let url: URL
        do {
            url = try ShotStore.write(png: png, to: directory)
        } catch {
            return .failure(.init(
                code: .writeFailed, message: "Could not write to \(directory.path): \(error.localizedDescription)"))
        }
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        guard let text = sidecar(url.lastPathComponent),
              FileManager.default.createFile(
                atPath: jsonURL.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            return .failure(.init(code: .writeFailed, message: "The image was written but its .json could not be, at \(jsonURL.path)."))
        }
        return .success(Written(image: url, json: jsonURL))
    }

    // MARK: capture

    private func capture(
        _ target: ShotAgent.Target, items: ShotAgent.Items, meta: ShotAgent.Meta, terminal: Ghostty.SurfaceView?,
        completion: @escaping (Result<String, ShotAgent.Refusal>) -> Void
    ) {
        let screens = Self.screens()
        let windows = Self.windows(on: screens)
        let terminalWindow = Self.window(of: terminal, on: screens)
        // Which display, before there is a picture of it.
        let planned: ShotAgent.Area
        switch ShotAgent.area(of: target, displays: screens.map(\.info), windows: windows, terminal: terminalWindow) {
        case let .success(area): planned = area
        case let .failure(refusal):
            completion(.failure(refusal))
            return
        }
        // Read now, with the picture: a pane shielded a moment later was
        // not shielded in it, and one shielded now must not be in it.
        let panes = Self.shieldedPanes(on: planned.display, of: screens)

        ShotCapture.capture([screens[planned.display].screen]) { displays in
            guard let display = displays.first, let bytes = ShotRenderer.rgbx(of: display.image),
                  let frozen = FrozenImage(
                    rect: PixelRect(0, 0, display.image.width, display.image.height), rgbx: bytes) else {
                completion(.failure(.init(code: .captureFailed, message: "The system returned no picture of display \(planned.display).")))
                return
            }
            // The picture's own size is the one that counts; clip to it.
            guard let rect = planned.rect.intersect(frozen.rect) else {
                completion(.failure(.init(code: .captureFailed, message: "The area lies outside the picture the system returned.")))
                return
            }
            let scale = screens[planned.display].info.scale
            let placed = ShotAgent.measured(items, scale: scale, measure: ShotTextMeasure())
                .map { $0.moved(dx: rect.x, dy: rect.y) }
            guard let image = ShotRenderer.compose(
                frozen: frozen, selection: rect, items: placed, scale: scale, redact: panes) else {
                completion(.failure(.init(code: .captureFailed, message: "The picture could not be composed.")))
                return
            }

            let source: ShotSidecar.Source
            if let window = planned.window {
                source = .window(
                    app: window.app, title: window.title, pid: window.pid,
                    windowRect: window.rect, selectionRect: rect)
            } else {
                source = .region(selectionRect: rect)
            }
            let now = Date()
            Self.terminal(of: meta) { terminal in
                let directory = Self.directory()
                let written = Self.write(image) { name in
                    ShotSidecar.json(
                        ShotSidecar.Meta(
                            image: name, taken: .init(now, timeZone: .current),
                            width: image.width, height: image.height, scale: scale,
                            by: .agent(terminal: meta.agentTerminal),
                            display: .init(
                                index: planned.display, width: frozen.rect.w, height: frozen.rect.h, scale: scale),
                            appearance: Self.appearance, source: source, terminal: terminal,
                            previous: planned.window.flatMap {
                                ShotContext.previous(app: $0.app, title: $0.title, before: name, in: directory)
                            },
                            redacted: ShotPixels.redactions(panes: panes, in: rect)),
                        items: ShotAgent.measured(items, scale: scale, measure: ShotTextMeasure()))
                }
                completion(written.map {
                    ShotAgent.doneJSON(path: $0.image.path, json: $0.json.path, size: .init(image.width, image.height))
                })
            }
        }
    }

    // MARK: annotate

    private func annotate(
        _ path: String, items: ShotAgent.Items, meta: ShotAgent.Meta,
        completion: @escaping (Result<String, ShotAgent.Refusal>) -> Void
    ) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let bytes = ShotRenderer.rgbx(of: picture),
              let frozen = FrozenImage(rect: PixelRect(0, 0, picture.width, picture.height), rgbx: bytes) else {
            completion(.failure(.init(code: .badImage, message: "\(path) could not be read as an image.")))
            return
        }
        let original = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
            .flatMap { String(data: $0, encoding: .utf8) }
        let scale = ShotAgent.scale(ofSidecar: original)
        let drawn = ShotAgent.measured(items, scale: scale, measure: ShotTextMeasure())
        // The picture on disk is already what was allowed out; nothing is
        // redacted a second time, and the record of what was is copied.
        guard let image = ShotRenderer.compose(frozen: frozen, selection: frozen.rect, items: drawn, scale: scale) else {
            completion(.failure(.init(code: .badImage, message: "\(path) could not be drawn on.")))
            return
        }
        let now = Date()
        Self.terminal(of: meta) { terminal in
            let written = Self.write(image) { name in
                let fresh = ShotSidecar.json(
                    ShotSidecar.Meta(
                        image: name, taken: .init(now, timeZone: .current),
                        width: image.width, height: image.height, scale: scale,
                        by: .agent(terminal: meta.agentTerminal),
                        source: .region(selectionRect: frozen.rect), terminal: terminal,
                        previous: url.lastPathComponent),
                    items: drawn)
                return ShotAgent.annotatedSidecar(fresh: fresh, original: original)
            }
            completion(written.map {
                ShotAgent.doneJSON(path: $0.image.path, json: $0.json.path, size: .init(image.width, image.height))
            })
        }
    }

    // MARK: long

    /// A long screenshot in progress: the frames, and how far it has got.
    private final class LongJob {
        var stitcher: ShotStitcher
        let capture: ShotLiveCapture
        /// Where to black out in every frame, in the frame's own pixels.
        let redact: [PixelRect]
        let size: Annotation.PixelSize
        /// How far one step scrolls, in points.
        let step: Double
        let pages: Int
        var page = 0
        var addedThisPage = 0
        var stopped = ShotAgent.Stopped.pages
        /// Where the pointer was, to put it back.
        let pointer: CGPoint

        init(stitcher: ShotStitcher, capture: ShotLiveCapture, redact: [PixelRect], size: Annotation.PixelSize, step: Double, pages: Int, pointer: CGPoint) {
            self.stitcher = stitcher
            self.capture = capture
            self.redact = redact
            self.size = size
            self.step = step
            self.pages = pages
            self.pointer = pointer
        }
    }

    /// How many looks a frame gets to hold still, and how far apart.
    private static let steadyTries = 10
    private static let steadyInterval: TimeInterval = 0.06
    /// How long a scroll is given before the first look.
    private static let settle: TimeInterval = 0.12

    /// Take frames until one is the same as the one before it, and say what
    /// joining it did. A region still moving after every try is `.lost`:
    /// nothing could be joined.
    private func steadyFrame(_ job: LongJob, tries: Int = 0, then: @escaping (ShotStitcher.Step) -> Void) {
        job.capture.frame { [weak self] frame in
            guard let self else { return }
            guard var frame else {
                then(.lost)
                return
            }
            // Black first: a frame is never held, compared or joined with a
            // shielded pane in it.
            let whole = PixelRect(0, 0, job.size.w, job.size.h)
            for rect in job.redact { ShotPixels.blackOut(&frame, covering: whole, rect: rect) }
            let step = job.stitcher.offer(frame)
            guard step == .moving else {
                then(step)
                return
            }
            guard tries + 1 < Self.steadyTries else {
                then(.lost)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.steadyInterval) {
                self.steadyFrame(job, tries: tries + 1, then: then)
            }
        }
    }

    private func long(
        _ target: ShotAgent.Target, pages: Int, meta: ShotAgent.Meta,
        completion: @escaping (Result<String, ShotAgent.Refusal>) -> Void
    ) {
        let screens = Self.screens()
        let area: ShotAgent.Area
        switch ShotAgent.area(of: target, displays: screens.map(\.info), windows: Self.windows(on: screens), terminal: nil) {
        case let .success(found): area = found
        case let .failure(refusal):
            completion(.failure(refusal))
            return
        }
        let screen = screens[area.display]
        let scale = screen.info.scale
        guard let displayID = ShotCapture.displayID(of: screen.screen),
              let stitcher = ShotStitcher(width: area.rect.w, height: area.rect.h) else {
            completion(.failure(.init(code: .captureFailed, message: "The area is not one a picture can be taken of.")))
            return
        }
        // The region in the display's own points, and its centre in the
        // system's global ones: where the wheel has to be.
        let region = CGRect(
            x: Double(area.rect.x) / scale, y: Double(area.rect.y) / scale,
            width: Double(area.rect.w) / scale, height: Double(area.rect.h) / scale)
        let centre = CGPoint(x: screen.frame.minX + region.midX, y: screen.frame.minY + region.midY)
        let job = LongJob(
            stitcher: stitcher,
            capture: ShotLiveCapture(
                displayID: displayID, region: region, pixels: .init(area.rect.w, area.rect.h), overlayNumbers: []),
            redact: ShotPixels.redactions(panes: Self.shieldedPanes(on: area.display, of: screens), in: area.rect),
            size: .init(area.rect.w, area.rect.h),
            step: Double(ShotAgent.Scroll.step(height: area.rect.h)) / scale,
            pages: pages,
            pointer: CGEvent(source: nil)?.location ?? centre)

        // The wheel goes to whatever is under the pointer, so the pointer
        // has to be there. It is put back when this is over.
        CGWarpMouseCursorPosition(centre)
        steadyFrame(job) { [weak self] first in
            guard let self else { return }
            guard first == .first else {
                self.finishLong(job, area: area, scale: scale, meta: meta, failure: .init(
                    code: .captureFailed, message: "The area never held still long enough to take a first frame of."),
                    completion: completion)
                return
            }
            self.scrollPage(job, stepsLeft: ShotAgent.Scroll.stepsPerPage) {
                self.finishLong(job, area: area, scale: scale, meta: meta, failure: nil, completion: completion)
            }
        }
    }

    /// Scroll one screen in steps, taking a frame after each, then decide
    /// whether to scroll another.
    private func scrollPage(_ job: LongJob, stepsLeft: Int, done: @escaping () -> Void) {
        if stepsLeft == ShotAgent.Scroll.stepsPerPage {
            job.page += 1
            job.addedThisPage = 0
        }
        guard stepsLeft > 0 else {
            if let stopped = ShotAgent.stop(
                after: job.page, of: job.pages, addedThisPage: job.addedThisPage, full: job.stitcher.isFull) {
                job.stopped = stopped
                done()
            } else {
                scrollPage(job, stepsLeft: ShotAgent.Scroll.stepsPerPage, done: done)
            }
            return
        }
        // Down the page: the content moves up, which is a negative wheel.
        let wheel = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -Int32(job.step.rounded()), wheel2: 0, wheel3: 0)
        wheel?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            guard let self else { return }
            self.steadyFrame(job) { step in
                if case let .added(rows) = step { job.addedThisPage += rows }
                if job.stitcher.isFull {
                    job.stopped = .limit
                    done()
                    return
                }
                self.scrollPage(job, stepsLeft: stepsLeft - 1, done: done)
            }
        }
    }

    private func finishLong(
        _ job: LongJob, area: ShotAgent.Area, scale: Double, meta: ShotAgent.Meta,
        failure: ShotAgent.Refusal?, completion: @escaping (Result<String, ShotAgent.Refusal>) -> Void
    ) {
        CGWarpMouseCursorPosition(job.pointer)
        if let failure {
            completion(.failure(failure))
            return
        }
        guard let stitched = job.stitcher.finish(),
              let image = ComposedImage(width: stitched.width, rgbx: stitched.rgbx) else {
            completion(.failure(.init(code: .captureFailed, message: "No frame of the area could be taken.")))
            return
        }
        let source: ShotSidecar.Source
        if let window = area.window {
            source = .window(
                app: window.app, title: window.title, pid: window.pid,
                windowRect: window.rect, selectionRect: area.rect)
        } else {
            source = .region(selectionRect: area.rect)
        }
        let cut = image.tiles()
        let now = Date()
        let displaySize = Self.screens().indices.contains(area.display) ? Self.screens()[area.display].info.size : job.size
        Self.terminal(of: meta) { terminal in
            let directory = Self.directory()
            var tiles: [ShotSidecar.Tile] = []
            let written = Self.write(image) { name in
                // One tile would be the picture itself.
                for (i, tile) in cut.enumerated() where cut.count > 1 {
                    let tileName = ShotStore.tileName(of: name, i + 1)
                    if FileManager.default.createFile(
                        atPath: directory.appendingPathComponent(tileName).path, contents: tile.png,
                        attributes: [.posixPermissions: 0o600]) {
                        tiles.append(.init(image: tileName, y: tile.y, height: tile.height))
                    }
                }
                return ShotSidecar.json(
                    ShotSidecar.Meta(
                        image: name, taken: .init(now, timeZone: .current),
                        width: image.width, height: image.height, scale: scale,
                        by: .agent(terminal: meta.agentTerminal),
                        display: .init(index: area.display, width: displaySize.w, height: displaySize.h, scale: scale),
                        appearance: Self.appearance, source: source, terminal: terminal,
                        tiles: tiles,
                        // Where the panes were in each frame, which is where
                        // they are in the first screen of the picture.
                        redacted: job.redact),
                    items: [])
            }
            completion(written.map {
                ShotAgent.longJSON(
                    path: $0.image.path, json: $0.json.path, size: .init(image.width, image.height),
                    tiles: tiles, pages: job.page, stopped: job.stopped)
            })
        }
    }
}
