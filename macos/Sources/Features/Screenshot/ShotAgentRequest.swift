import Foundation

/// What an agent's screenshot request says and what it is answered with:
/// the half of `dev-docs/poltergeist/screenshot.md`, 10.1 that is text and
/// arithmetic. The half that touches the screen is `ShotAgentHost`.
///
/// The core has already checked the caller's permission, the path of an
/// image to annotate, and every annotation; what arrives here is complete
/// and in range. This still reads it without trusting that, and answers
/// nil rather than guessing when something is not as promised.
enum ShotAgent {
    // MARK: Refusals

    /// Why the host would not do it. The names are the contract's.
    enum Code: String {
        case screenRecordingRequired = "ScreenRecordingRequired"
        case accessibilityRequired = "AccessibilityRequired"
        case noSuchWindow = "NoSuchWindow"
        case noSuchDisplay = "NoSuchDisplay"
        case badRegion = "BadRegion"
        case busy = "Busy"
        case badImage = "BadImage"
        case captureFailed = "CaptureFailed"
        case writeFailed = "WriteFailed"
    }

    struct Refusal: Error, Equatable {
        var code: Code
        /// One English sentence for the agent: what it is, and what can be
        /// done about it.
        var message: String

        var json: String {
            "{\"code\": \(ShotSidecar.quoted(code.rawValue)), \"message\": \(ShotSidecar.quoted(message))}"
        }
    }

    // MARK: Requests

    enum Target: Equatable {
        case display(Int)
        case window(UInt64)
        case region(display: Int, rect: PixelRect)
        /// The terminal the action was sent to.
        case terminal
    }

    /// Who asked, as the core says it; written into the sidecar as it is.
    struct Meta: Equatable {
        var agentTerminal: String
        var terminalID: String?
        var cwd: String?
    }

    /// An annotation as an agent gives it: in the result image's pixels,
    /// with any colour. Text has no measured size yet.
    typealias Items = [Annotation]

    enum Request: Equatable {
        case directory
        case windows
        case capture(target: Target, items: Items, meta: Meta)
        case annotate(path: String, items: Items, meta: Meta)
        case long(target: Target, pages: Int, meta: Meta)
    }

    private static func int(_ value: Any?) -> Int? {
        // A JSON `true` is a number to the parser; it is not one here.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    private static func point(_ value: Any?) -> PixelPoint? {
        guard let a = value as? [Any], a.count == 2, let x = int(a[0]), let y = int(a[1]) else { return nil }
        return PixelPoint(x, y)
    }

    private static func rect(_ value: Any?) -> PixelRect? {
        guard let a = value as? [Any], a.count == 4,
              let x = int(a[0]), let y = int(a[1]), let w = int(a[2]), let h = int(a[3]) else { return nil }
        return PixelRect(x, y, w, h)
    }

    private static func target(_ value: Any?) -> Target? {
        guard let t = value as? [String: Any], let kind = t["kind"] as? String else { return nil }
        switch kind {
        case "display":
            return int(t["index"]).map(Target.display)
        case "window":
            guard let id = int(t["window_id"]), id >= 0 else { return nil }
            return .window(UInt64(id))
        case "region":
            guard let display = int(t["display"]), let r = rect(t["rect"]) else { return nil }
            return .region(display: display, rect: r)
        case "terminal":
            return .terminal
        default:
            return nil
        }
    }

    private static func meta(_ value: Any?) -> Meta? {
        guard let m = value as? [String: Any], let agent = m["agent_terminal"] as? String else { return nil }
        let terminal = m["terminal"] as? [String: Any]
        return Meta(agentTerminal: agent, terminalID: terminal?["id"] as? String, cwd: terminal?["cwd"] as? String)
    }

    /// The step a size in points is. Nil for a size that is not one of the
    /// five: the core refuses those, so one arriving here is a fault, and
    /// it is not rounded to the nearest.
    private static func level(of value: Any?, among steps: [Int]) -> Int? {
        int(value).flatMap { steps.firstIndex(of: $0) }
    }

    /// One annotation. A preset colour is kept as the preset it is, so that
    /// an agent's red rectangle and a person's are the same value.
    private static func item(_ value: Any) -> Annotation? {
        guard let a = value as? [String: Any], let type = a["type"] as? String else { return nil }
        func coloured(_ shape: Annotation.Shape, level: Int?) -> Annotation? {
            guard let level, let hex = a["color"] as? String, let rgb = ShotStyle.rgb(ofHex: hex) else { return nil }
            if let preset = ShotStyle.index(ofHex: hex) { return Annotation(shape: shape, colour: preset, level: level) }
            return Annotation(shape: shape, colour: 0, level: level, custom: rgb)
        }
        let width = level(of: a["width"], among: ShotStyle.widths)
        let font = level(of: a["font_size"], among: ShotStyle.fonts)
        func points() -> [PixelPoint]? {
            guard let raw = a["points"] as? [Any], raw.count >= 2 else { return nil }
            let all = raw.compactMap(point)
            return all.count == raw.count ? all : nil
        }

        switch type {
        case "rect":
            return rect(a["rect"]).flatMap { coloured(.rect($0), level: width) }
        case "ellipse":
            return rect(a["rect"]).flatMap { coloured(.ellipse($0), level: width) }
        case "line":
            guard let from = point(a["from"]), let to = point(a["to"]) else { return nil }
            return coloured(.line(from: from, to: to), level: width)
        case "arrow":
            guard let from = point(a["from"]), let to = point(a["to"]) else { return nil }
            return coloured(.arrow(from: from, to: to), level: width)
        case "pen":
            return points().flatMap { coloured(.pen($0), level: width) }
        case "highlighter":
            return points().flatMap { coloured(.highlighter($0), level: width) }
        case "text":
            guard let at = point(a["at"]), let text = a["text"] as? String else { return nil }
            return coloured(.text(at: at, text: text, size: .zero), level: font)
        case "number":
            guard let n = int(a["n"]), let at = point(a["at"]), let text = a["text"] as? String else { return nil }
            return coloured(.number(n: n, at: at, text: text, size: .zero), level: font)
        case "mosaic":
            guard let r = rect(a["rect"]),
                  let block = level(of: a["block"], among: ShotStyle.mosaic.map(\.points)) else { return nil }
            return Annotation(shape: .mosaic(r), colour: 0, level: block)
        default:
            return nil
        }
    }

    private static func items(_ value: Any?) -> Items? {
        guard let raw = value as? [Any] else { return nil }
        let all = raw.compactMap(item)
        return all.count == raw.count ? all : nil
    }

    /// Read a request. Nil when it is not one this host understands, which
    /// is answered as unsupported.
    static func parse(_ spec: String) -> Request? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(spec.utf8)) as? [String: Any],
              let op = root["op"] as? String else { return nil }
        switch op {
        case "directory":
            return .directory
        case "windows":
            return .windows
        case "capture":
            guard let target = target(root["target"]), let items = items(root["annotations"]),
                  let meta = meta(root["meta"]) else { return nil }
            return .capture(target: target, items: items, meta: meta)
        case "annotate":
            guard let path = root["path"] as? String, !path.isEmpty, let items = items(root["annotations"]),
                  let meta = meta(root["meta"]) else { return nil }
            return .annotate(path: path, items: items, meta: meta)
        case "long":
            guard let target = target(root["target"]), let pages = int(root["pages"]), (1...20).contains(pages),
                  let meta = meta(root["meta"]) else { return nil }
            switch target {
            case .window, .region: return .long(target: target, pages: pages, meta: meta)
            case .display, .terminal: return nil
            }
        default:
            return nil
        }
    }

    /// Give every piece of text the size it measures at `scale`, which is
    /// known only once it is known which display the picture is of.
    static func measured(_ items: Items, scale: Double, measure: TextMeasure) -> Items {
        items.map { item in
            var item = item
            let font = ShotStyle.fontPx(level: item.level, scale: scale)
            switch item.shape {
            case let .text(at, text, _):
                item.shape = .text(at: at, text: text, size: measure.size(of: text, fontPx: font))
            case let .number(n, at, text, _) where !text.isEmpty:
                item.shape = .number(n: n, at: at, text: text, size: measure.size(of: text, fontPx: font))
            default:
                break
            }
            return item
        }
    }

    // MARK: Displays and windows

    struct DisplayInfo: Equatable {
        var size: Annotation.PixelSize
        var scale: Double
        var primary: Bool
    }

    struct WindowInfo: Equatable {
        var id: UInt64
        var app: String?
        var title: String?
        var pid: Int?
        /// The display its centre is on.
        var display: Int
        /// In that display's own pixels; it may reach past the display.
        var rect: PixelRect
    }

    /// Which display a window is counted on: the one its centre is on, or,
    /// with its centre on none, the one it covers most of. Nil when it
    /// touches none.
    static func display(of frame: CGRect, among screens: [CGRect]) -> Int? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let index = screens.firstIndex(where: { $0.contains(centre) }) { return index }
        let areas = screens.map { screen -> CGFloat in
            let part = screen.intersection(frame)
            return part.isNull ? 0 : part.width * part.height
        }
        guard let best = areas.max(), best > 0 else { return nil }
        return areas.firstIndex(of: best)
    }

    /// A window's frame in the pixels of the display it is counted on,
    /// which it may reach past.
    static func rect(of frame: CGRect, on screen: CGRect, scale: Double) -> PixelRect {
        func edge(_ v: CGFloat, _ origin: CGFloat) -> Int { Int((Double(v - origin) * scale).rounded()) }
        return PixelRect(
            left: edge(frame.minX, screen.minX), top: edge(frame.minY, screen.minY),
            right: edge(frame.maxX, screen.minX), bottom: edge(frame.maxY, screen.minY))
    }

    /// The answer to `windows`. When it would not fit in `cap` bytes,
    /// windows are left off the end -- the ones furthest back -- until it
    /// does, and the answer says so: half a document is never written.
    static func windowsJSON(displays: [DisplayInfo], windows: [WindowInfo], cap: Int) -> String {
        let displayParts = displays.enumerated().map { index, d in
            "{\"index\": \(index), \"size\": [\(d.size.w), \(d.size.h)], \"scale\": \(ShotSidecar.scaleText(d.scale)), \"primary\": \(d.primary)}"
        }
        let windowParts = windows.map { w -> String in
            var parts = ["\"window_id\": \(w.id)"]
            if let app = w.app, !app.isEmpty { parts.append("\"app\": \(ShotSidecar.quoted(app))") }
            if let title = w.title, !title.isEmpty { parts.append("\"title\": \(ShotSidecar.quoted(title))") }
            if let pid = w.pid { parts.append("\"pid\": \(pid)") }
            parts.append("\"display\": \(w.display)")
            parts.append("\"rect\": [\(w.rect.x), \(w.rect.y), \(w.rect.w), \(w.rect.h)]")
            return "{\(parts.joined(separator: ", "))}"
        }
        func document(_ count: Int) -> String {
            let listed = windowParts.prefix(count).joined(separator: ", ")
            let cut = count < windowParts.count ? ", \"truncated\": true" : ""
            return "{\"displays\": [\(displayParts.joined(separator: ", "))], \"windows\": [\(listed)]\(cut)}"
        }
        var count = windowParts.count
        while count > 0, document(count).utf8.count > cap { count -= 1 }
        return document(count)
    }

    /// What to capture: a display and a rectangle in its own pixels.
    struct Area: Equatable {
        var display: Int
        var rect: PixelRect
        /// The window it is, when it is one.
        var window: WindowInfo?
    }

    /// Turn a target into an area. `terminal` is the frame of the window
    /// the terminal is in, already found by the host and given as a window.
    static func area(of target: Target, displays: [DisplayInfo], windows: [WindowInfo], terminal: WindowInfo?) -> Result<Area, Refusal> {
        func whole(_ index: Int) -> PixelRect { PixelRect(0, 0, displays[index].size.w, displays[index].size.h) }
        func ofWindow(_ window: WindowInfo, what: String) -> Result<Area, Refusal> {
            guard displays.indices.contains(window.display),
                  let part = window.rect.intersect(whole(window.display)) else {
                return .failure(.init(code: .captureFailed, message: "\(what) is not on any display right now."))
            }
            return .success(Area(display: window.display, rect: part, window: window))
        }

        switch target {
        case let .display(index):
            guard displays.indices.contains(index) else {
                return .failure(.init(
                    code: .noSuchDisplay,
                    message: "There is no display \(index); screenshot_windows lists the \(displays.count) there are."))
            }
            return .success(Area(display: index, rect: whole(index), window: nil))
        case let .window(id):
            guard let window = windows.first(where: { $0.id == id }) else {
                return .failure(.init(
                    code: .noSuchWindow,
                    message: "No window \(id) is on screen; it may have closed. Call screenshot_windows again."))
            }
            return ofWindow(window, what: "Window \(id)")
        case let .region(index, rect):
            guard displays.indices.contains(index) else {
                return .failure(.init(
                    code: .noSuchDisplay,
                    message: "There is no display \(index); screenshot_windows lists the \(displays.count) there are."))
            }
            guard rect.w > 0, rect.h > 0, let part = rect.intersect(whole(index)) else {
                return .failure(.init(
                    code: .badRegion,
                    message: "The rectangle is empty or lies outside display \(index), which is \(displays[index].size.w) by \(displays[index].size.h) pixels."))
            }
            return .success(Area(display: index, rect: part, window: nil))
        case .terminal:
            guard let terminal else {
                return .failure(.init(
                    code: .captureFailed, message: "The terminal's window is not on screen right now."))
            }
            return ofWindow(terminal, what: "The terminal's window")
        }
    }

    // MARK: Answers

    static func directoryJSON(_ path: String) -> String {
        "{\"directory\": \(ShotSidecar.quoted(path))}"
    }

    /// Why a long screenshot stopped.
    enum Stopped: String {
        /// It scrolled as many screens as were asked for.
        case pages
        /// A screen's worth of scrolling added nothing: the end of the page.
        case bottom
        /// The picture reached the height limit.
        case limit
    }

    static func doneJSON(path: String, json: String, size: Annotation.PixelSize) -> String {
        "{\"path\": \(ShotSidecar.quoted(path)), \"json\": \(ShotSidecar.quoted(json)), \"size\": [\(size.w), \(size.h)]}"
    }

    static func longJSON(
        path: String, json: String, size: Annotation.PixelSize,
        tiles: [ShotSidecar.Tile], pages: Int, stopped: Stopped
    ) -> String {
        let listed = tiles.map { "{\"image\": \(ShotSidecar.quoted($0.image)), \"y\": \($0.y), \"height\": \($0.height)}" }
        return "{\"path\": \(ShotSidecar.quoted(path)), \"json\": \(ShotSidecar.quoted(json)), "
            + "\"size\": [\(size.w), \(size.h)], \"tiles\": [\(listed.joined(separator: ", "))], "
            + "\"pages\": \(pages), \"stopped\": \(ShotSidecar.quoted(stopped.rawValue))}"
    }

    // MARK: The sidecar of an annotated copy

    /// The sidecar of a new image made by annotating an existing one.
    ///
    /// `fresh` is the sidecar the new image would have on its own; `original`
    /// is the text of the old image's sidecar, when it has one. What the
    /// picture is *of* does not change by drawing on it, so `source`,
    /// `display` and `redacted` are the original's -- and are left out when
    /// there is no original to take them from, rather than made up. The
    /// annotations are the original's followed by the new ones. Nil when
    /// `fresh` is not a sidecar.
    static func annotatedSidecar(fresh: String, original: String?) -> String? {
        func object(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard var out = object(fresh) else { return nil }
        let old = original.flatMap(object)
        for key in ["source", "display", "redacted"] {
            if let value = old?[key] {
                out[key] = value
            } else {
                out.removeValue(forKey: key)
            }
        }
        let before = old?["annotations"] as? [Any] ?? []
        let added = out["annotations"] as? [Any] ?? []
        out["annotations"] = before + added
        guard let data = try? JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// The scale an existing image's sidecar records, or 1 when it has no
    /// sidecar or none that says.
    static func scale(ofSidecar text: String?) -> Double {
        guard let text,
              let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let scale = (root["scale"] as? NSNumber)?.doubleValue, scale > 0 else { return 1 }
        return scale
    }

    // MARK: Scrolling a long screenshot

    /// How a long screenshot an agent asked for is scrolled: each screen in
    /// several short steps, so that every frame overlaps the one before by
    /// much more than the stitcher needs.
    enum Scroll {
        /// Steps to a screen.
        static let stepsPerPage = 4
        /// How much of the region's height one screen of scrolling covers,
        /// in per cent: the rest is what the screens share.
        static let pagePerCent = 80

        /// How far one step scrolls, in pixels, for a region `height` tall.
        static func step(height: Int) -> Int {
            max(height * pagePerCent / 100 / stepsPerPage, 1)
        }
    }

    /// What is known after each screen of scrolling, and whether to go on.
    static func stop(after page: Int, of pages: Int, addedThisPage: Int, full: Bool) -> Stopped? {
        if full { return .limit }
        if addedThisPage == 0 { return .bottom }
        if page >= pages { return .pages }
        return nil
    }
}
