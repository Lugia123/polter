import AppKit
import ImageIO
import OSLog
import SwiftUI
import WebKit

/// The group chat's transcript page, drawn by `web/chat/` in a `WKWebView`
/// (task 3084; the page and its wire contract are `web/chat/CONTRACT.md`).
///
/// **The page draws and scrolls; the host owns the truth.** Which messages
/// are loaded, whether older history exists, where a search result landed,
/// what a local image path becomes and what a link means are decisions this
/// side makes. The page parses the Markdown once, keeps one scroll position
/// and reports back through one channel.
///
/// **It is the same shell the settings and preview pages use**
/// (`WebViewShell`): its own scheme, no network twice over, no navigation
/// away, no second window, one non-persistent store. The reasons are written
/// out in `Preview/PluginWebView.swift` and are not repeated here. What is
/// this page's own is the scheme it is served over, the one name it may post
/// to, how a request for one of its files is answered, and what it is told.
///
/// **There is a fallback, and it is not a second list.**
/// `POLTER_CHAT_WEB=0` in the environment -- or a page that never says
/// `chat.ready` -- puts `ControlRoomNativeChatView` on its plain-text list:
/// the messages' raw text, one `ScrollView`, no position model. That path
/// exists so a page that will not load is a diagnosis rather than a broken
/// group chat (design v3 §五).
enum ControlRoomChatTranscriptPage {
    /// The scheme the page is served over. `polter-chat://chat/…` is the
    /// page's own origin; the host is what makes it one.
    static let scheme = "polter-chat"

    /// The one name the page can post to, per the contract (`polterChat`).
    static let handlerName = "polterChat"

    /// The origin's host. One page, so one name, but written out because a
    /// request for any other host is refused rather than served.
    static let host = "chat"

    /// Where the page's files are found in the app bundle:
    /// `<resources>/polter-chat/…`, installed by `GhosttyResources.zig`.
    static let resourceDirectory = "polter-chat"

    /// **Load success and failure, and every bridge message** (task 3084's
    /// instrument). A reading is counted from these lines: `loaded` once per
    /// page, `bridge:` per message in either direction, `unread` when the
    /// page never said `chat.ready`.
    static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "chat-page")

    /// Whether the page is the list. **Not a build flag**: the same binary
    /// can be asked for the native list with `POLTER_CHAT_WEB=0`, which is
    /// what makes "the page and the old list disagree" testable.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["POLTER_CHAT_WEB"] != "0"
    }

    /// What the page is allowed to load. The page's own scheme is the only
    /// origin; `data:` and `polter-file:` are image sources (a ticket URL or
    /// an image this host has already read and inlined).
    static let policy = [
        "default-src 'none'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src polter-chat: data: polter-file:",
        "connect-src 'none'",
    ].joined(separator: "; ")

    /// What the page finds on `window`.
    ///
    /// `postMessage` is the page's order of preference before the WebKit
    /// handler, and `receive` is the host's way in when it wants to call
    /// without `evaluateJavaScript`'s string envelope. The page installs its
    /// own `receive` on this same object when it loads (it is the function
    /// that dispatches `page.*`), so this one is the before-load stand-in
    /// and a path for a host that wanted `postMessage`; **the host sends
    /// through whatever `receive` is there at the time**, which after load is
    /// the page's.
    static let bridgeScript = """
    (function () {
      const post = (obj) =>
        window.webkit.messageHandlers.\(ControlRoomChatTranscriptPage.handlerName)
          .postMessage(obj);
      const bridge = {
        protocol: 2,
        postMessage: post,
        receive: function (obj) { window.postMessage(obj, "*"); },
        sent: []
      };
      Object.defineProperty(window, "polterChat", {
        value: bridge,
        writable: true,
        configurable: true,
        enumerable: true
      });
    })();
    """

    // MARK: - What a message is, on the wire

    /// One message, in the contract's shape (`CONTRACT.md` §2.1).
    ///
    /// **`text` is the raw Markdown the core sent**, not a rendered block:
    /// the page parses it once and that is the point of the page. `dayBreak`
    /// and `speakerRule` are decided here, where the neighbouring messages
    /// are known -- the page only draws the hairline it is told to.
    struct Message: Equatable {
        var id: String
        var seq: UInt64
        var at: Int64
        var author: String
        var role: String?
        var text: String
        var dayBreak: Bool
        var speakerRule: Bool

        var json: [String: Any] {
            var object: [String: Any] = [
                "id": id,
                "seq": seq,
                "at": at,
                "author": author,
                "text": text,
                "dayBreak": dayBreak,
                "speakerRule": speakerRule,
            ]
            if let role, !role.isEmpty { object["role"] = role }
            return object
        }
    }

    /// The CSS variables the page's own palette is replaced with
    /// (`CONTRACT.md` §3.9). **A complete set every time**: the page removes
    /// the previous injection wholesale, so a key left out means the built-in
    /// value rather than a stale one. `mode` switches its built-in ground.
    struct Theme: Equatable {
        var mode: String
        var vars: [String: String]

        var json: [String: Any] {
            var object: [String: Any] = vars
            object["mode"] = mode
            return object
        }

        init(look theme: ControlRoomLook.Theme) {
            mode = theme.dark ? "dark" : "light"
            vars = [
                "--bg": Self.css(theme.windowBase),
                "--bg-code": Self.css(theme.terminalBackground),
                "--fg": Self.css(theme.text),
                "--muted": Self.css(theme.textSecondary),
                "--rule": Self.css(theme.line),
                "--rule-soft": Self.css(theme.lineFaint),
                "--accent": Self.css(theme.paneBlue),
                "--link": Self.css(theme.paneBlue),
                "--who-supervisor": Self.css(theme.panePurple),
                "--who-user": Self.css(theme.paneGreen),
                "--font-size": "\(ControlRoomLook.Font.body)px",
            ]
        }

        private static func css(_ color: ControlRoomLook.RGBA) -> String {
            if color.a >= 0.999 {
                return String(format: "#%02x%02x%02x", color.r, color.g, color.b)
            }
            return String(
                format: "rgba(%d, %d, %d, %.3f)",
                color.r, color.g, color.b, color.a)
        }
    }

    // MARK: - Images

    /// The largest file this host will inline as a `data:` URL. Past it the
    /// page keeps its alt text: sending a 40 MB base64 string through
    /// `evaluateJavaScript` is a stall the reader would feel, and an image
    /// that big is not something a chat message needs to show inline.
    static let imageSizeLimit = 8 * 1024 * 1024

    /// Read a local path the page cannot read itself and turn it into a
    /// `page.image` payload (`CONTRACT.md` §3.8).
    ///
    /// Returns nil -- and the bridge answers `page.notImage` -- when the path
    /// is not absolute, `stat` cannot read it, the file is over the 8 MB
    /// limit, or **its first bytes are not an image**. The file's extension
    /// is not consulted: `.png` on a text file is a name, not a picture, and
    /// a screenshot saved without an extension is a picture all the same.
    ///
    /// The width and height come from the file's header (ImageIO), not from
    /// laying the image out: they are what the page reserves before the bytes
    /// arrive, so that a late image does not move what the reader is reading.
    /// The local path a page path names, or nil when it is not one. `~` is
    /// expanded and a `file://` URL is decoded; the result is only accepted
    /// if absolute, because a relative path would be resolved against the
    /// app's working directory rather than anything the sender meant.
    static func localPath(_ src: String) -> String? {
        var path = src
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? path
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        return path.hasPrefix("/") ? path : nil
    }

    /// **Whether this path names an image file**, from its first bytes.
    ///
    /// The link path asks this: the transcript shows an image inline, and
    /// handing its raw path to the file preview is a preview that cannot
    /// read it (the person's 2026-11-09 reading: "无法打开这个文件"). Only
    /// the header is read, not the bytes.
    static func isImagePath(_ src: String) -> Bool {
        guard let path = localPath(src),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= imageSizeLimit,
              let handle = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { try? handle.close() }
        guard let head = (try? handle.read(upToCount: 16)) ?? nil else { return false }
        return imageMIME(fromMagic: head) != nil
    }

    /// **Open a clicked image with the system's default program**, and say
    /// whether it did.
    ///
    /// **This is the one place a chat path leaves the workdir boundary on
    /// purpose.** Every other local path a message names is resolved by the
    /// core, and `files/Tickets.zig` judges it against the chat's workdir: a
    /// picture at `/tmp/shot.png` is refused there *by design*, which is why
    /// clicking one used to end in a preview that could not read it. A
    /// picture the transcript already drew is a different case -- this host
    /// read those very bytes to draw it (`isImagePath` / `imagePayload`), so
    /// "open it" means handing the same file to the person's own viewer.
    ///
    /// **Only an image, and only by the host's own reading**: `isImagePath`
    /// reads the file's header; the page's extension or its word is never
    /// the check. A non-image returns false and is not opened, so this adds
    /// no route for opening arbitrary local files with a system program.
    @discardableResult
    static func openImage(_ src: String) -> Bool {
        guard isImagePath(src), let path = localPath(src) else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }

    static func imagePayload(for src: String) -> [String: Any]? {
        guard let path = localPath(src) else {
            log.notice("image: not a local path src=\(src, privacy: .public)")
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= imageSizeLimit
        else {
            log.notice("image: missing or too large path=\(path, privacy: .public)")
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            log.notice("image: unreadable path=\(path, privacy: .public)")
            return nil
        }
        guard let mime = imageMIME(fromMagic: data) else {
            log.notice("image: not an image path=\(path, privacy: .public)")
            return nil
        }

        var payload: [String: Any] = [
            "src": src,
            "url": "data:\(mime);base64,\(data.base64EncodedString())",
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            payload["width"] = width.intValue
            payload["height"] = height.intValue
        }
        log.notice("image: inlined path=\(path, privacy: .public) bytes=\(data.count, privacy: .public) type=\(mime, privacy: .public)")
        return payload
    }

    /// The image type from the file's own first bytes, or nil.
    ///
    /// **The magic numbers are the check; a name is not.** Each is the
    /// shortest signature that a file of that kind must start with:
    /// PNG `89 50 4E 47`, JPEG `FF D8 FF`, GIF `GIF8`, WebP `RIFF….WEBP`,
    /// BMP `BM`, TIFF `II*\0` / `MM\0*`, HEIC `ftyp` + a HEIF brand.
    /// SVG is text and is deliberately not here: a local SVG is served as a
    /// file link, not inlined as an image (the page's own `img-src` allows
    /// `data:` for images the page built itself).
    static func imageMIME(fromMagic data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func at(_ index: Int, _ byte: UInt8) -> Bool {
            index < bytes.count && bytes[index] == byte
        }
        func ascii(_ range: Range<Int>, _ string: String) -> Bool {
            let scalars = Array(string.utf8)
            guard range.upperBound <= bytes.count,
                  scalars.count == range.count else { return false }
            for (offset, byte) in scalars.enumerated()
            where bytes[range.lowerBound + offset] != byte {
                return false
            }
            return true
        }

        if at(0, 0x89), at(1, 0x50), at(2, 0x4E), at(3, 0x47) { return "image/png" }
        if at(0, 0xFF), at(1, 0xD8), at(2, 0xFF) { return "image/jpeg" }
        if ascii(0..<4, "GIF8") { return "image/gif" }
        if ascii(0..<4, "RIFF"), ascii(8..<12, "WEBP") { return "image/webp" }
        if ascii(0..<2, "BM") { return "image/bmp" }
        if ascii(0..<4, "II*\u{0}") || ascii(0..<4, "MM\u{0}*") {
            return "image/tiff"
        }
        if ascii(4..<8, "ftyp") {
            for brand in ["heic", "heix", "heif", "mif1"] where ascii(8..<12, brand) {
                return "image/heic"
            }
        }
        return nil
    }

    // MARK: - The wire

    /// One host-to-page message as the JavaScript that delivers it.
    ///
    /// **The JSON is handed over as a string and `receive` parses it**
    /// (`CONTRACT.md` §1: the page accepts a JSON string). A string literal
    /// is also the one form `evaluateJavaScript` cannot confuse with
    /// structure: no object literal to escape, no `U+2028` line terminator
    /// left raw where JavaScript would read it as a newline.
    static func script(for object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return "window.polterChat.receive(\(jsString(json)))"
    }

    /// A JavaScript string literal from a Swift string. JSON's own escaping
    /// is the same for the characters that matter; the two line terminators
    /// are not.
    static func jsString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        return out + "\""
    }

    // MARK: - Serving the page's files

    /// The directory the page's files are served from.
    static var root: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent(resourceDirectory, isDirectory: true)
    }

    /// A request path turned into a file inside the page's directory, or nil.
    ///
    /// **The containment check is on the resolved path**, after `..` has been
    /// collapsed and symlinks followed: a page's `..` is the obvious way out
    /// and checking the string as written would catch none of it. The fence
    /// is the page's own directory, so every path that leaves it -- now or
    /// through a link -- is refused and logged.
    static func resolve(_ path: String) -> URL? {
        guard let root = root?.standardizedFileURL.resolvingSymlinksInPath() else {
            return nil
        }
        let relative = (path.isEmpty || path == "/") ? "/index.html" : path
        let candidate = root
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fence = root.path
        guard candidate.path == fence || candidate.path.hasPrefix(fence + "/") else {
            log.warning("page asked for \(path, privacy: .public), outside its directory")
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return candidate
    }

    static func contentType(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - The page and its one channel

/// Everything the page can ask for, and the one place an answer goes back.
///
/// **The bridge is the host side of `CONTRACT.md`**: it turns `chat.*` into
/// calls on the owner's closures, and it is the only thing that serialises
/// `page.*`. It keeps the last state it was told so that a page that says
/// `chat.ready` after the view has already been given messages still gets
/// them, in one `page.reset`, rather than an append per row.
@MainActor
final class ControlRoomChatPageBridge: NSObject {
    /// What the page has been told. `ControlRoomChatNativeChatView` computes
    /// it from the feed on every body pass; `update` diffs it against the
    /// last one.
    struct Snapshot {
        var messages: [ControlRoomChatTranscriptPage.Message]
        var hasEarlier: Bool
        var theme: ControlRoomChatTranscriptPage.Theme
        var located: String?
        /// **The place this chat was left at**, when it was made again from
        /// the container's store (`feed.restoredPlace`). Sent on the first
        /// `page.reset` of this page and never again: a later reset is a
        /// reload or a return-to-latest, whose landing is the newest.
        var reading: ControlRoomChatReadingPlaces.Place?
        /// **`page.reset.error`** (task 3098): the first screen's read
        /// failed. The page says so and offers the retry instead of drawing
        /// an empty group.
        var resetError: String?
        /// **`page.prepend.error`** (task 3098): the older read failed.
        /// `hasEarlier` alone cannot say this -- the page would print "start
        /// of history" over a read that never happened.
        var olderError: String?
        /// Whether the older scan is **not** running. A `chat.loadOlder`
        /// with no prepend and a settled scan is a failure to answer, not a
        /// wait, and the page is owed one (task 3098).
        var olderSettled: Bool
    }

    private var shell: WebViewShell.Shell<ControlRoomChatPageBridge>?
    /// The page said `chat.ready`. Nothing is sent before this: a `page.*`
    /// that arrived earlier would be delivered to a listener that is not
    /// there yet and be lost without a trace.
    private var ready = false
    /// **The most recent state the owner computed, whether or not the page
    /// is there yet** (task 3098). A `chat.ready` always answers with it --
    /// including the empty one -- and a page that re-asks after its own
    /// timeout gets the current state, not silence.
    private var latest: Snapshot?
    /// **What the page is still owed** (task 3098): the one reset a ready
    /// page gets, and whether a `chat.loadOlder` has been answered. The rule
    /// itself is `ControlRoomChatTranscriptObligations`, which a test can
    /// hold without a web view; this is only its state.
    private var obligations = ControlRoomChatTranscriptObligations.State()
    private var lastIDs: [String] = []
    private var lastTheme: ControlRoomChatTranscriptPage.Theme?
    private var lastLocated: String?
    /// **What the page last said about being at the bottom** (`chat.follow`,
    /// `CONTRACT.md` §4.3). The reset's confirming `page.follow` is withheld
    /// once this says the reader has left the bottom: at that point the
    /// second word would be a yank, not a confirmation.
    private var pageFollows = true
    /// **The restored place goes out with the first reset and no other.**
    /// The snapshot carries it on every update (it is the feed's one piece
    /// of state), but a reset after a reload or a return-to-latest must land
    /// at the newest, not at a place from the last visit.
    private var readingUsed = false

    /// **What a `chat.loadOlder` led to** (task 3098). `.started` means the
    /// scan is out and its answer will be a prepend when it lands;
    /// `.answered` means there is nothing to ask, so the page is owed an
    /// empty prepend now rather than waiting for a message that will never
    /// come.
    enum OlderAnswer {
        case started
        case answered(hasEarlier: Bool, error: String?)
    }

    /// The host's decisions, one per `chat.*` (`CONTRACT.md` §4).
    var onLoadOlder: (() -> OlderAnswer)?
    var onOpenLink: ((String) -> Void)?
    /// Where the reader is (`chat.reading`, §4.9): the anchor row, how far
    /// into it the viewport starts, and whether the reader is at the bottom.
    var onReading: ((String?, Double, Bool) -> Void)?
    /// **"Back to latest" was pressed** (§4.10). The page's own scroll only
    /// reaches the end of what is loaded; a located window needs the host.
    var onJumpLatest: (() -> Void)?
    /// Returns the `page.image` payload for a path the page cannot read, or
    /// nil to leave the alt text. The bridge sends the answer; the owner is
    /// where the file is read.
    var onImageTicket: ((String) -> [String: Any]?)?
    var onMenu: ((String, Double, Double) -> Void)?
    var onCopy: ((String) -> Void)?
    var onFollow: ((Bool, Int) -> Void)?
    var onError: ((String) -> Void)?
    /// **The page never said `chat.ready`** (the 10 s watchdog below). The
    /// owner answers by drawing the plain list (design v3 §五); this is the
    /// only "the page did not load" signal WebKit gives us.
    var onUnready: (() -> Void)?

    /// The web view for this page, making the shell the first time.
    func view() -> WKWebView {
        if let shell { return shell.view }
        let made = WebViewShell.Shell(self)
        shell = made
        watchForReady()
        return made.view
    }

    /// **A page that never says `chat.ready` is said out loud, and handed
    /// over.** WebKit gives no callback here for "the page's script threw",
    /// and the shell's navigation delegate only refuses other schemes;
    /// without this the only trace of a page that did not load would be an
    /// empty rectangle. `onUnready` is what turns that rectangle into the
    /// plain list (design v3 §五).
    private func watchForReady() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ready else { return }
                ControlRoomChatTranscriptPage.log.error(
                    "unread: no chat.ready after 10s (resources and CSP are the first suspects)")
                self.onUnready?()
            }
        }
    }

    // MARK: What the owner tells the page

    /// Diff the state the owner has now against the state the page was last
    /// told, and send the smallest message that makes them agree.
    ///
    /// **Appended is `page.append` per row, prepended is one
    /// `page.prepend`, anything else is a `page.reset`.** The classification
    /// is `ControlRoomChatTranscriptDiff.change`, so "the window slid" is
    /// not mistaken for "these are all new".
    func update(_ snapshot: Snapshot) {
        // **The latest state is kept whether or not the page is there.**
        // `chat.ready` answers with it, and a page that re-asks after its
        // own timeout gets the current state rather than silence (task 3098).
        latest = snapshot
        guard ready else { return }

        let ids = snapshot.messages.map(\.id)
        // **A restored place whose rows arrived after the empty boot reset**
        // (task 3098) needs a reset to land on: `page.append` carries no
        // reading. The boot reset could not spend it (see `reset`), so this
        // is the first reset that can, and it must be a whole document.
        var deferredReset = false
        if !readingUsed, snapshot.reading != nil, !ids.isEmpty,
           obligations.sentInitialReset {
            deliver(.reset, snapshot)
            // A whole document answers any older request that was out: the
            // page's reset clears its loading state itself.
            obligations.awaitsOlder = false
            deferredReset = true
        }
        if !deferredReset {
            let replies = ControlRoomChatTranscriptObligations.update(
                &obligations,
                ids: ids,
                lastIDs: lastIDs,
                hasEarlier: snapshot.hasEarlier,
                olderSettled: snapshot.olderSettled,
                olderError: snapshot.olderError)
            for reply in replies {
                deliver(reply, snapshot)
            }
        }
        lastIDs = ids

        if snapshot.theme != lastTheme {
            send(snapshot.theme.json.merging(["type": "page.theme"]) { $1 })
            lastTheme = snapshot.theme
        }
        if snapshot.located != lastLocated {
            if let located = snapshot.located {
                send(["type": "page.locate", "id": located])
            }
            lastLocated = snapshot.located
        }
    }

    /// Turn one obligation into the JSON it names. **The decision is
    /// `ControlRoomChatTranscriptObligations`**; nothing here decides what is
    /// owed.
    private func deliver(
        _ reply: ControlRoomChatTranscriptObligations.Reply,
        _ snapshot: Snapshot?
    ) {
        switch reply {
        case .reset:
            guard let snapshot else { return }
            reset(snapshot)
            // **A reset puts the page at the bottom, so a located window
            // must be put back on its target in the same breath** (the
            // person's 2026-11-09 reading: the result was located, then the
            // list bounced back near the newest). The reset and the locate
            // are two messages; the second is the one that must be last. A
            // *new* locate is sent by `update` below, so only an unchanged
            // one is re-asserted here.
            if let located = snapshot.located, located == lastLocated {
                send(["type": "page.locate", "id": located])
            }
        case .append(let from):
            guard let snapshot else { return }
            let start = min(from, snapshot.messages.count)
            for message in snapshot.messages[start...] {
                send(["type": "page.append", "message": message.json, "pending": 0])
            }
        case .prepend(let upTo, let hasEarlier, let error):
            let messages = snapshot?.messages ?? []
            let end = min(upTo, messages.count)
            var object: [String: Any] = [
                "type": "page.prepend",
                "messages": messages.prefix(end).map(\.json),
                "hasEarlier": hasEarlier,
            ]
            if let error { object["error"] = error }
            send(object)
        }
    }

    private func reset(_ snapshot: Snapshot) {
        var object = snapshot.theme.json.merging(["type": "page.reset"]) { $1 }
        object["messages"] = snapshot.messages.map(\.json)
        object["locale"] = Locale.current.identifier
        object["hasEarlier"] = snapshot.hasEarlier
        // **A read that failed is not an empty group** (task 3098): the
        // page shows the failure and its retry rather than "no messages".
        if let error = snapshot.resetError { object["error"] = error }
        // **The place, once** (task 3096 #4): the first reset of this page
        // may carry the reader's previous place, and the page lands there
        // (or says why it could not, `chat.restoreFailed`). Every reset after
        // this one is a reload or a return-to-latest, whose landing is the
        // newest by definition.
        // **An empty reset does not spend the restored place** (task 3098).
        // A ready page is now answered even when the feed has not answered
        // yet, and a place with no rows to land on would fail the page's own
        // restore (`chat.restoreFailed`) and fall to the bottom. The place
        // goes with the first reset that **has a row to land on**; after
        // that, every reset is a reload / return-to-latest.
        let placedReading: ControlRoomChatReadingPlaces.Place? =
            (readingUsed || snapshot.messages.isEmpty) ? nil : snapshot.reading
        if !snapshot.messages.isEmpty { readingUsed = true }
        if let reading = placedReading {
            object["reading"] = [
                "id": reading.id,
                "offset": reading.offset,
            ]
        }
        send(object)
        ControlRoomChatTranscriptPage.log.notice(
            "bridge: reset rows=\(snapshot.messages.count, privacy: .public) hasEarlier=\(snapshot.hasEarlier ? 1 : 0, privacy: .public) located=\(snapshot.located == nil ? 0 : 1, privacy: .public) reading=\(placedReading?.id ?? "-", privacy: .public) offset=\(Int(placedReading?.offset ?? 0), privacy: .public)")
        let ids = snapshot.messages.map(\.id)
        lastIDs = ids
        lastTheme = snapshot.theme

        // **The bottom is confirmed once, after the frame that drew it.**
        // The page's own `page.reset` puts the viewport at the bottom in the
        // same pass, and on this page that has been right every time -- but
        // "same pass" is the one place a web view that has just been attached
        // can be measured at zero height, and a first screen that lands at
        // the top would be indistinguishable from a working one until
        // somebody read the top row. `page.follow` is the contract's own
        // "go to the bottom" (`CONTRACT.md` §3.5), so this is a second word
        // rather than a second rule.
        //
        // **Not after a locate** (§3.6): the locate is sent in this same
        // update and is the landing the reader asked for; following would
        // overwrite it. And **not if the page has already said it is not
        // following** (`chat.follow`), which is a reader who scrolled in the
        // meantime. **Not after a restored place either**: the restore is
        // the landing, and a `page.follow` 150 ms later would yank the reader
        // to the bottom before their own `chat.follow` had arrived.
        guard snapshot.located == nil, placedReading == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ready,
                      self.lastIDs == ids,
                      self.pageFollows
                else { return }
                self.send(["type": "page.follow"])
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let script = ControlRoomChatTranscriptPage.script(for: object) else {
            ControlRoomChatTranscriptPage.log.error("bridge: could not serialise \(object["type"] as? String ?? "?", privacy: .public)")
            return
        }
        ControlRoomChatTranscriptPage.log.notice(
            "bridge: send \(object["type"] as? String ?? "?", privacy: .public) writing=\(self.shell != nil ? 1 : 0, privacy: .public)")
        shell?.view.evaluateJavaScript(script) { _, error in
            if let error {
                ControlRoomChatTranscriptPage.log.error(
                    "bridge: evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: What the page asks

    private func received(_ body: Any, reply: @escaping (Any?, String?) -> Void) {
        guard let body = body as? [String: Any],
              let type = body["type"] as? String
        else {
            ControlRoomChatTranscriptPage.log.error("bridge: malformed message")
            reply(nil, "malformed message")
            return
        }

        // **Every bridge message is a line** (task 3084's instrument): the
        // page's questions and the host's answers are read from this log,
        // not inferred from what the window looks like.
        ControlRoomChatTranscriptPage.log.notice(
            "bridge: recv \(type, privacy: .public) id=\(Self.identifier(in: body), privacy: .public)")

        switch type {
        case "chat.ready":
            ready = true
            ControlRoomChatTranscriptPage.log.notice(
                "loaded protocol=\(body["protocol"] as? Int ?? -1, privacy: .public) url=\(ControlRoomChatTranscriptPage.scheme, privacy: .public)://\(ControlRoomChatTranscriptPage.host, privacy: .public)/index.html")
            // **Every `chat.ready` is answered with a reset, a blank page
            // included.** Task 3084 skipped the empty one ("not known yet"
            // is not "empty"), and the real machine showed the cost: an
            // empty snapshot was the only one that ever arrived, so the host
            // sent no `page.*` at all and the page waited for ever. The
            // page's own timeout now re-asks, and a re-ask must get the
            // current state rather than silence (task 3098). The empty
            // reset's cost -- a page that fills itself from the top -- is
            // the page's `chat.loadOlder`, which is exactly the request the
            // host wants.
            if let latest {
                deliver(ControlRoomChatTranscriptObligations.ready(&obligations), latest)
            }

        case "chat.loadOlder":
            // **A `chat.loadOlder` is always answered with one
            // `page.prepend`** (task 3098). When there is nothing to ask,
            // the owner says so and the empty prepend goes now; otherwise
            // the answer comes from `update` when the scan settles.
            switch onLoadOlder?() {
            case .answered(let hasEarlier, let error):
                // The reply is built by the same rule the test holds, and
                // it carries no rows: the empty prepend goes out now.
                let reply = ControlRoomChatTranscriptObligations.olderAnswered(
                    hasEarlier: hasEarlier, error: error)
                deliver(reply, latest)
            case .started, .none:
                ControlRoomChatTranscriptObligations.olderStarted(&obligations)
            }

        case "chat.openLink":
            if let href = body["href"] as? String { onOpenLink?(href) }

        case "chat.openImage":
            // **A clicked picture, opened here rather than through a link**
            // (`CONTRACT.md` §4.8). `openLink` is the other route and means
            // "the host resolves this reference", which for a local path is
            // the core's ticket and is judged against the chat's workdir --
            // so a picture kept outside it (`/tmp`) cannot be previewed.
            // `openImage` is the deliberate exception, and only for an image
            // this host has read the header of itself; a non-image is logged
            // and dropped, never opened.
            if let src = body["src"] as? String {
                if !ControlRoomChatTranscriptPage.openImage(src) {
                    ControlRoomChatTranscriptPage.log.notice(
                        "image: click not opened src=\(src, privacy: .public)")
                }
            }

        case "chat.imageTicket", "chat.image":
            // **Two requests, one answer** (`CONTRACT.md` §4.7): a Markdown
            // image's source and a bare path in the prose are the same
            // question -- "can you read this as a picture?" -- and the
            // answer is either the picture or "no, it is a file".
            if let src = body["src"] as? String {
                if let payload = onImageTicket?(src) {
                    send(payload.merging(["type": "page.image"]) { $1 })
                } else {
                    send(["type": "page.notImage", "src": src])
                }
            }

        case "chat.menu":
            let id = (body["id"] as? String) ?? ""
            let x = (body["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (body["y"] as? NSNumber)?.doubleValue ?? 0
            onMenu?(id, x, y)

        case "chat.copy":
            onCopy?(body["text"] as? String ?? "")

        case "chat.follow":
            let follow = body["follow"] as? Bool ?? false
            pageFollows = follow
            let pending = (body["pending"] as? NSNumber)?.intValue ?? 0
            onFollow?(follow, pending)

        case "chat.reading":
            // **Where the reader is** (§4.9). The page throttles this while
            // scrolling; the host keeps only the last one, and only a place
            // a reader made (`following` false) is remembered when the
            // group is left.
            let anchor = body["anchor"] as? String
            let offset = (body["offset"] as? NSNumber)?.doubleValue ?? 0
            let following = body["following"] as? Bool ?? false
            onReading?(anchor, offset, following)

        case "chat.jumpLatest":
            // **"Back to latest"** (§4.10): a located window's end is not
            // the conversation's newest, so the host rebuilds at the newest
            // when it is holding one.
            onJumpLatest?()

        case "chat.restoreFailed":
            // **A restore that could not land is said out loud** (§3.1):
            // the page fell to the bottom, and this line is the only way to
            // explain later why a reader came back to the bottom. A page's
            // `console` reaches nobody on a real machine.
            let why = body["why"] as? String ?? "?"
            let offset = (body["offset"] as? NSNumber)?.doubleValue ?? 0
            let want = (body["want"] as? NSNumber)?.intValue ?? 0
            let got = (body["got"] as? NSNumber)?.intValue ?? 0
            ControlRoomChatTranscriptPage.log.notice(
                "reading: restore failed why=\(why, privacy: .public) id=\(Self.identifier(in: body), privacy: .public) offset=\(Int(offset), privacy: .public) want=\(want, privacy: .public) got=\(got, privacy: .public); back to the bottom")

        case "chat.error":
            let message = body["message"] as? String ?? ""
            ControlRoomChatTranscriptPage.log.error("page error: \(message, privacy: .public)")
            onError?(message)

        default:
            // Named rather than ignored, so a page that starts sending a new
            // message is a line in the log rather than silence.
            ControlRoomChatTranscriptPage.log.notice(
                "bridge: unknown \(type, privacy: .public)")
        }
        reply(nil, nil)
    }

    private static func identifier(in body: [String: Any]) -> String {
        if let id = body["id"] as? String { return id }
        if let id = body["id"] as? NSNumber { return id.stringValue }
        return "-"
    }
}

// MARK: What the shell has to be told

extension ControlRoomChatPageBridge: WebViewShell.Page {
    static var scheme: String { ControlRoomChatTranscriptPage.scheme }
    static var handlerName: String { ControlRoomChatTranscriptPage.handlerName }
    static var bridgeScript: String { ControlRoomChatTranscriptPage.bridgeScript }

    /// The page is loaded from `polter-chat://chat/index.html`; the host is
    /// the origin and the scheme handler refuses any other.
    var entryURL: URL? {
        var components = URLComponents()
        components.scheme = ControlRoomChatTranscriptPage.scheme
        components.host = ControlRoomChatTranscriptPage.host
        components.path = "/index.html"
        return components.url
    }

    var policy: String { ControlRoomChatTranscriptPage.policy }
}

// MARK: The one channel

extension ControlRoomChatPageBridge: WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated { received(message.body, reply: replyHandler) }
    }
}

// MARK: Serving the page's own files, and nothing beside them

extension ControlRoomChatPageBridge: WKURLSchemeHandler {
    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated { serve(task) }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Everything is read from disk and answered in one go, so there is
        // nothing in flight to cancel.
    }

    private func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme == ControlRoomChatTranscriptPage.scheme,

              // The host is the page's origin and this handler belongs to
              // one page. A request for another host is asking for something
              // this page was never given.
              url.host == ControlRoomChatTranscriptPage.host,
              let file = ControlRoomChatTranscriptPage.resolve(url.path)
        else {
            ControlRoomChatTranscriptPage.log.error(
                "serve: refused \(task.request.url?.absoluteString ?? "-", privacy: .public)")
            task.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }

        guard let data = try? Data(contentsOf: file) else {
            ControlRoomChatTranscriptPage.log.error(
                "serve: unreadable \(file.path, privacy: .public)")
            task.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": ControlRoomChatTranscriptPage.contentType(of: file),
                "Content-Length": String(data.count),
                "Content-Security-Policy": ControlRoomChatTranscriptPage.policy,

                // The page is one page's, served to one web view. Nothing
                // should be reading it from anywhere else.
                "Access-Control-Allow-Origin": "null",
            ])

        guard let response else {
            task.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }

        ControlRoomChatTranscriptPage.log.notice(
            "serve: \(url.path, privacy: .public) bytes=\(data.count, privacy: .public)")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - SwiftUI's handle on it

/// The page as a SwiftUI view. **It draws nothing itself**: `makeNSView`
/// asks the coordinator for the web view the shell made, and every later
/// update is a diff against what the page was last told.
struct ControlRoomChatWebView: NSViewRepresentable {
    var messages: [ControlRoomChatTranscriptPage.Message]
    var hasEarlier: Bool
    var theme: ControlRoomChatTranscriptPage.Theme
    var located: String?
    /// The place this chat was left at, when it is being made again. Used by
    /// the bridge on the first reset only; nil everywhere else.
    var reading: ControlRoomChatReadingPlaces.Place?
    /// **A read that failed, as the page's `error`** (task 3098). The first
    /// screen's failure and the older read's are two different questions,
    /// so they travel apart.
    var resetError: String?
    var olderError: String?
    /// Whether the older scan is **not** running (task 3098).
    var olderSettled: Bool = false

    var onOlder: () -> ControlRoomChatPageBridge.OlderAnswer = { .answered(hasEarlier: false, error: nil) }
    var onOpenLink: (String) -> Void = { _ in }
    var onImageTicket: (String) -> [String: Any]? = { _ in nil }
    var onMenu: (String, Double, Double) -> Void = { _, _, _ in }
    var onCopy: (String) -> Void = { _ in }
    var onFollow: (Bool, Int) -> Void = { _, _ in }
    var onUnready: () -> Void = {}
    var onReading: (String?, Double, Bool) -> Void = { _, _, _ in }
    var onJumpLatest: () -> Void = {}

    func makeCoordinator() -> ControlRoomChatPageBridge {
        let bridge = ControlRoomChatPageBridge()
        wire(bridge)
        return bridge
    }

    func makeNSView(context: Context) -> WKWebView {
        // The coordinator holds the shell; the shell holds the view. ⚠️ The
        // web view's delegates are **weak**, so a shell made here and thrown
        // away would leave a page with no delegation at all -- see `Shell`.
        context.coordinator.view()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        wire(context.coordinator)
        context.coordinator.update(ControlRoomChatPageBridge.Snapshot(
            messages: messages,
            hasEarlier: hasEarlier,
            theme: theme,
            located: located,
            reading: reading,
            resetError: resetError,
            olderError: olderError,
            olderSettled: olderSettled))
    }

    private func wire(_ bridge: ControlRoomChatPageBridge) {
        bridge.onLoadOlder = onOlder
        bridge.onOpenLink = onOpenLink
        bridge.onImageTicket = onImageTicket
        bridge.onMenu = onMenu
        bridge.onCopy = onCopy
        bridge.onFollow = onFollow
        bridge.onUnready = onUnready
        bridge.onReading = onReading
        bridge.onJumpLatest = onJumpLatest
    }
}
