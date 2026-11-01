import Foundation

/// The `polter-file://` request routes, and the preview's `window.polter`
/// contract (task 2628, #2140 M1/W1; `polter-artifacts/2145/PLAN.md` §2.1
/// and §3.2).
///
/// **The twin of `windows/preview-route/src/lib.rs`**, held to the same
/// answers over `test/fixtures/preview-routes.tsv` -- the shape
/// `test/fixtures/project-filenames.tsv` uses for its three readers, and for
/// the same reason: two hosts in two languages can each be green while they
/// disagree, and nothing looks at both screens at once.
///
/// # What a preview is served over
///
/// A file being previewed is served to a web view the host owns, over
/// `polter-file://<token>/<rel>`. **The token is the capability and the host
/// is not the judge of it**: a ticket is held by the core
/// (`src/poltergeist/files/Tickets.zig`, task 2573), bound to one workdir and
/// one scope, and every single request goes back to the core's
/// `files_resolve(token, rel)`, which judges `rel` against *this ticket's*
/// scope again and answers the real path -- or a refusal. The host reads only
/// the path it was given.
///
/// So the split is:
///
/// * **here**: which ticket is being asked and what relative path is being
///   asked of it. A string rule, and this file is where it is written so both
///   hosts have one copy of it rather than two.
/// * **the core**: whether that path may be read, and what the real path is.
///   `Access.resolve` in the core, never here.
///
/// ⚠️ **A host that built a file path from `rel` would be a second judge of
/// "is this inside the workdir"**, and the two would drift. Nothing in this
/// file touches the file system, and nothing in it can be made to.
///
/// # Why `..` is refused here as well, when the core would refuse it too
///
/// Not for safety -- the core's answer is the one that decides -- but because
/// the browser normalises `a/../b` to `b` before the request is ever made
/// (`URL` on macOS, WebView2 on Windows). A `..` arriving at the handler is
/// therefore a caller that is not the page's own URL resolution -- a
/// hand-written `fetch`, an `<img src>` in a string -- and the honest answer
/// to it is a refusal rather than a resolved path that happens to land inside
/// the fence. `%2e%2e` is the same thing spelled so the browser will not
/// normalise it away, which is why the check is made after decoding and not
/// before.
enum PreviewRoutes {
    /// The scheme a previewed file is served over (`PLAN.md` §2.1). Registered
    /// with an authority component on both hosts, which is why the token is
    /// the URL's host.
    static let scheme = "polter-file"

    /// How many characters a token has: 16 random bytes as lower-case hex
    /// (`Tickets.newId`, which is `std.fmt.bytesToHex(raw, .lower)`).
    static let tokenLength = 32

    /// Why a request was not served. The handler answers 403 for every one of
    /// them and reads nothing.
    enum Refused: String, Error, Equatable {
        /// Not this scheme: `https`, `file:`, `polter-plugin:`, anything.
        case otherScheme = "other_scheme"
        /// This scheme, but what is in the authority is not a token. Judged
        /// before any path is looked at: an unguessable token is the whole of
        /// the capability, so a request that cannot carry one is refused for
        /// that and not for where it was pointing.
        case badToken = "bad_token"
        /// A path that would leave the ticket's own directory, or one that
        /// cannot be read as a path.
        case outside
        /// A percent-escape that is malformed, or bytes that are not UTF-8. A
        /// path that cannot be read is not guessed at.
        case badEscape = "bad_escape"

        /// The word the two hosts, the fixture and the tests all use for it.
        var word: String { rawValue }
    }

    /// Which ticket a request asks, and what it asks of it.
    ///
    /// `rel` empty means the ticket's own file (`Tickets.resolve` reads an
    /// empty `rel` as the anchor), which is what the entry URL asks for.
    struct Route: Equatable {
        var token: String
        var rel: String
    }

    /// Turn a request URL into the ticket and relative path the core is asked
    /// about, or why it is refused. **Nothing here reads a file.**
    static func resolve(_ url: String) -> Result<Route, Refused> {
        // 1. The scheme, without case: a URL scheme is case-insensitive by the
        //    standard, and WebView2 hands a lower-cased one while WKWebView
        //    does not.
        guard let rest = splitScheme(url) else { return .failure(.otherScheme) }

        // 2. `//authority/path`, or nothing: the token is the host, so a URL
        //    with no authority cannot name one.
        guard rest.hasPrefix("//") else { return .failure(.otherScheme) }
        let authority = rest.dropFirst(2)
        let host: Substring
        let path: Substring
        if let slash = authority.firstIndex(of: "/") {
            host = authority[authority.startIndex..<slash]
            path = authority[slash...]
        } else {
            host = authority
            path = ""
        }

        // 3. The token. Lower-case hex, exactly `tokenLength` characters --
        //    not "looks hex-ish": two hosts comparing it their own way is
        //    exactly how one of them comes to accept a token the other
        //    refuses.
        guard isToken(host) else { return .failure(.badToken) }

        let beforeQuery = path.prefix { $0 != "?" && $0 != "#" }
        guard let decoded = percentDecode(String(beforeQuery)) else { return .failure(.badEscape) }

        var segments: [String] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: false)
            .flatMap({ $0.split(separator: "\\", omittingEmptySubsequences: false) }) {
            switch segment {
            case "", ".":
                continue
            case "..":
                return .failure(.outside)
            default:
                // A colon is a drive letter or a URL inside a path; NUL is a
                // string that ends early in half the places it is handed to.
                if segment.contains(":") || segment.contains("\0") { return .failure(.outside) }
                segments.append(String(segment))
            }
        }
        return .success(Route(token: String(host), rel: segments.joined(separator: "/")))
    }

    /// The part of `url` after `<scheme>`, when the scheme is ours.
    ///
    /// Returns the part including the `//`, so the caller does not have to
    /// remember which of the two it got: a scheme match that leaves out the
    /// authority is not a URL this scheme is served over.
    private static func splitScheme(_ url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let name = url[url.startIndex..<colon]
        guard name.lowercased() == scheme else { return nil }
        return String(url[url.index(after: colon)...])
    }

    /// Whether `s` is a token as `Tickets.newId` writes one: lower-case hex,
    /// `tokenLength` characters. Upper case is refused rather than folded --
    /// `resolve` hands this string to the core, where it is compared byte for
    /// byte, so accepting `9F2C…` here would be a request that passes the
    /// host's check and comes back `no_ticket` from the core.
    static func isToken(_ s: some StringProtocol) -> Bool {
        guard s.count == tokenLength else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x61 && scalar.value <= 0x66)
        }
    }

    /// `%XX` decoded, as UTF-8. `nil` for a malformed escape or bytes that are
    /// not UTF-8 -- the same rule
    /// `settings_shell::plugins::percent_decode` has for a plugin page's path.
    static func percentDecode(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count,
                      let hi = hexValue(bytes[i + 1]),
                      let lo = hexValue(bytes[i + 2])
                else { return nil }
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: What a response carries

    /// The most one `read` hands back. A file larger than this comes back
    /// through `info` with `truncated: true` rather than being silently
    /// short -- which is the difference between "that is all of it" and "that
    /// is all you were given".
    static let readMax = 4 << 20

    /// The `Content-Security-Policy` sent with every response this scheme
    /// serves.
    ///
    /// `'self'` is `polter-file://<token>`, so everything has to come from
    /// this one ticket. **`img-src` and `media-src` name that origin too**,
    /// and that is the whole of the loosening: a markdown file's `<img>` is a
    /// load the core resolves like any other, so it may come from this ticket
    /// and from nowhere else (`PLAN.md` §2.1). `connect-src 'none'` is the
    /// one that matters most -- no `fetch`, no `XMLHttpRequest`, no
    /// `WebSocket`, no `EventSource`. A previewed file's data reaches the page
    /// through `window.polter`, so the request is stopped in the page before
    /// it is made.
    static func policy(token: String) -> String {
        [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: \(scheme)://\(token)",
            "media-src 'self' \(scheme)://\(token)",
            "font-src 'self' data:",
            "connect-src 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
    }

    /// Enough types for a file being previewed. Anything else is served as
    /// bytes: an unknown extension should not stop the file being read, and
    /// the engine sniffs what it can.
    ///
    /// ⚠️ **A source file is `text/plain`, not `text/html`.** A previewed
    /// `.html` is a page and is served as one -- but a `.md`, a `.rs` or a
    /// `.json` is being *read* by a person, and serving somebody's `.rs` as a
    /// document would run it as markup instead of showing it.
    ///
    /// **This table is written once here and once in Rust, and
    /// `test/fixtures/preview-types.tsv` is what holds the two together.**
    /// The Windows host imports `polter_preview_route::content_type` rather
    /// than keeping a copy, so on that side there is one implementation --
    /// but this is Swift and cannot call it. The table the two run is the
    /// only place the answers are compared, and the answers that used to
    /// differ are `.css` and `.json`: both hosts send
    /// `X-Content-Type-Options: nosniff`, so `text/css` on one side and
    /// `text/plain` on the other was a stylesheet that rendered on one
    /// machine and printed on the other.
    ///
    /// ⚠️ **The plugin page's table is not this one and keeps `text/css` and
    /// `application/json`** (`PluginPage.contentType`): a plugin page is a
    /// program loading its own resources and the engine has to be told what
    /// they are; a preview is a person reading a file whose scripts do not
    /// run. The two tables answer different questions.
    static func contentType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "md", "markdown", "txt", "log", "csv", "tsv": return "text/plain; charset=utf-8"
        case "js", "mjs", "ts", "tsx", "css", "json", "rs", "zig", "py", "swift", "go", "c", "h", "cpp":
            return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    /// What `look()` hands the page: the colours, the sizes and the radii the
    /// host itself draws with.
    ///
    /// **A preview is a page somebody else wrote, drawn inside Polter's own
    /// window**, and what it shows is usually somebody's markdown or code. The
    /// one thing that must not happen is the page inventing a look beside the
    /// window it sits in -- white text on a light host, or a terminal's
    /// near-black ground inside a floating panel. So every number comes from
    /// `ControlRoomLook`, which is where the host's own chrome gets them, and
    /// the Windows host answers the same call from the same data
    /// (`windows/control-room/src/look.rs`).
    ///
    /// ⚠️ **The size has a floor, and it is not this file's to decide.** The
    /// menu font is asked of the system and handed in as `menuPointSize`,
    /// because a preview set at a literal 13 pt goes unreadable the day the
    /// system's text size moves (`SettingsFont.minimumPointSize`;
    /// `tools/no-text-below-the-menu-font.py` holds the rest of the app to the
    /// same rule).
    ///
    /// `fonts` is the caller's: a face name is `AppKit`'s to know and this file
    /// is `Foundation`'s, so what a page puts in `font-family` comes from the
    /// host and everything else is decided here.
    static func look(dark: Bool, menuPointSize: CGFloat, fonts: [String: String]) -> [String: Any] {
        let theme = ControlRoomLook.theme(dark: dark)
        let hex: (ControlRoomLook.RGBA) -> String = { c in
            let base = String(format: "#%02X%02X%02X", c.r, c.g, c.b)
            // Eight digits when the table has an alpha: `line` is black at
            // 0.16, and a page handed `#000000` for it would draw a hard rule
            // where the host draws a faint one.
            guard c.a < 1 else { return base }
            let a = Int((min(max(c.a, 0), 1) * 255).rounded())
            return base + String(format: "%02X", a)
        }
        var colours: [String: String] = [:]
        for (name, colour) in [
            ("text", theme.text),
            ("text_secondary", theme.textSecondary),
            ("text_tertiary", theme.textTertiary),
            ("well", theme.windowBase),
            ("panel", theme.sidePanel),
            ("row", theme.surfaceRow),
            ("row_selected", theme.surfaceRowSelected),
            ("line", theme.line),
            ("line_faint", theme.lineFaint),
            ("terminal_background", theme.terminalBackground),
            ("terminal_text", theme.terminalText),
            ("terminal_dim", theme.terminalDim),
            ("attention", theme.attention),
            ("problem", theme.problem),
        ] {
            colours[name] = hex(colour)
        }
        return [
            "dark": theme.dark,
            "colours": colours,
            "font": fonts,
            "size": [
                "body": ControlRoomLook.Font.body,
                "min": max(ControlRoomLook.Font.min, menuPointSize),
                "line_height": ControlRoomLook.Font.lineHeightTerminal,
            ],
            "radius": [
                "card": ControlRoomLook.Radius.row,
                "window": ControlRoomLook.Radius.window,
            ],
        ]
    }
}

/// The calls `window.polter` carries -- **the whole surface** (`PLAN.md`
/// §3.2). A method that is not one of these gets `no such call: <name>` back,
/// so an author who guessed finds out instead of waiting on a promise that
/// never settles.
///
/// There is deliberately no `write`, `create`, `delete`, `rename`, `exec` or
/// `fetch`: a page cannot write a file, and `propose` is not a write -- it
/// hands the text to the host, which draws the change and sends `files_commit`
/// only once the person has chosen.
///
/// **The twin of `windows/preview-route`'s `Call`**, and the tests on both
/// sides name the same eight: a call one host answers and the other refuses is
/// a page that works on one machine and not the other, with nothing to report
/// it.
enum PreviewCall: String, CaseIterable {
    /// Name, size, mtime, kind, encoding, end-of-line, `editable` and why not.
    case info
    /// Bytes, inside the ticket's `reads` range.
    case read
    /// Bytes of another file in the same range -- a markdown file's images.
    case readRel
    /// Ask the host to show another file in the same preview. Goes through
    /// `PreviewRoutes.resolve`, like any other request.
    case openPath
    /// A callback when the file changes, with who changed it.
    case watch
    /// Colour tokens, font and size (`ControlRoomLook`), never below the menu
    /// font.
    case look
    /// Hand the edited text to the host. **Not a write.**
    case propose
    /// Whether there are unsaved changes.
    case dirty

    var name: String { rawValue }

    static func parse(_ method: String) -> PreviewCall? {
        PreviewCall(rawValue: method)
    }
}
