import Foundation

/// A preview plugin's **static page**: where it is, and what may be served
/// out of it (task 2779 S7B, contract 2789).
///
/// # Why this is not the ticket's route
///
/// A preview has two kinds of bytes and they are not the same kind. The
/// **ticket** is a capability the core minted for one file in one workdir,
/// and everything it reaches goes back through the core (`files_resolve`);
/// that is `PreviewRoutes`'s `polter-file://<token>/…`. The **plugin's own
/// page** is somebody else's installed directory, which the core located and
/// nothing minted, and it is served here over a scheme of its own.
///
/// They are kept apart on purpose: a token in a URL is a capability, and a
/// plugin page is not one -- routing a static file through the ticket's
/// route would make "this plugin's page" and "this file the person opened"
/// the same kind of thing, and the day one of them is wrong the other is
/// what gets read.
///
/// # What this file owns
///
/// Three rules a plugin page needs and a previewed file does not:
/// the **fence** (`fencedFile`), the **types** a page's own resources are
/// served as (`contentType`), and its **policy**. All three are here rather
/// than in `PreviewBridge` so they can be tested with no web view and no
/// app, which is the same split `PreviewRoutes` has from `PreviewBridge`.
enum PreviewPluginPage {
    /// The scheme a plugin's own page and resources are served over.
    ///
    /// **Not `polter-plugin`** -- that one is the *settings* page's
    /// (`PluginPage.scheme`), and its page is served out of `ui/` with the
    /// settings bridge in it. Two pages on one scheme would be two origins
    /// claiming one name.
    static let scheme = "polter-plugin-page"

    /// A located page: the plugin's key (which is the URL's authority, and
    /// so the page's origin), the absolute directory the plugin manager
    /// scanned, and the manifest's own relative page inside it.
    ///
    /// **Every field came from the core.** Nothing here is derived from a
    /// key, a ticket, or a convention about where plugins live.
    struct Location: Equatable {
        /// The plugin's key: `Plugin.isPlainName`.
        var key: String
        /// Absolute path of the plugin's own directory.
        var root: String
        /// Relative to `root`, already checked by
        /// `PreviewTicket.isRelativePagePath`.
        var page: String

        /// Where the page is loaded from. The key is the host, so this
        /// page is its own origin.
        var url: URL? {
            var components = URLComponents()
            components.scheme = PreviewPluginPage.scheme
            components.host = key
            components.path = "/" + page
            return components.url
        }
    }

    /// Turn a request path into a file inside the plugin's own directory, or
    /// `nil`.
    ///
    /// **The containment check is on the *resolved* path**, after `..` has
    /// been collapsed and after symlinks have been followed, because both
    /// are ways out of a directory and a check on the string as written
    /// catches neither. This is the rule `PluginPageBridge.resolve` applies
    /// to a settings page's `ui/`; it is written once here so a preview's
    /// page is held to the same one rather than to a second that can drift.
    ///
    /// A path that is not inside the root is `nil`, which the caller answers
    /// as a refusal -- never as an empty file.
    static func fencedFile(root: String, path: String) -> URL? {
        guard !root.isEmpty, root.hasPrefix("/") else { return nil }
        let relative = (path.isEmpty || path == "/") ? "/index.html" : path

        let fence = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let candidate = fence
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let prefix = fence.path
        guard candidate.path == prefix || candidate.path.hasPrefix(prefix + "/") else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        return candidate
    }

    /// What a page's own resource is served as.
    ///
    /// **A plugin page's table, not a previewed file's** (`PreviewRoutes`'s
    /// keeps a `.rs` as `text/plain` so it is read rather than run; this one
    /// keeps `text/css` and `application/json` because the engine has to be
    /// told what a page's own resources are). The two answer different
    /// questions and the difference is deliberate -- see
    /// `PreviewRoutes.contentType`'s note.
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

    /// What the page may load.
    ///
    /// `'self'` is `polter-plugin-page://<key>`, so everything comes from
    /// this plugin's own directory. **`connect-src 'none'` is the one that
    /// matters**: the page's file bytes arrive through `window.polter`, not
    /// through a request, so there is no reason for it to reach anything --
    /// not the network, and not the ticket's `polter-file:` route either,
    /// which would be a second way for the page to read a file and a second
    /// place the scope rule would have to be right.
    ///
    /// `'unsafe-inline'` is allowed for scripts and styles, and it is
    /// deliberate: a page plugin ships as a single file as often as it
    /// ships as build output, and a policy that broke every `<script>` tag
    /// would be worked around rather than followed. What the page has to be
    /// injected from is a network it does not have.
    static let policy = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")
}
