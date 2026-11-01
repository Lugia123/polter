import SwiftUI
import WebKit
import OSLog

/// A plugin's own settings page, shown in a `WKWebView`.
///
/// **The five decisions that surround a page are not made here** -- a
/// non-persistent store, one origin per page, no network twice over, no
/// navigation away, no new windows are `WebViewShell`'s (task 2628, #2140 M1),
/// and a file preview is served in the same shell. The reasons are written out
/// in that file's header and are not repeated here. What is left in this file
/// is what is *this page's*: the scheme it is served over, the three calls
/// `window.polter` has, and how a request for one of its files is answered.
///
/// **This is not shipping a browser engine.** `WKWebView` is a system
/// component: the same WebKit every other app on the machine already links,
/// already installed, already updated by the OS. Nothing is bundled and
/// nothing is downloaded, so what this file costs is a view. That is the
/// whole reason "the plugin brings a web page" is an acceptable answer here
/// at all -- and it is exactly why the GTK side does not get one. There the
/// same feature is `WebKitGTK`, which upstream Ghostty does not link, and
/// that is a real new dependency rather than a view. GTK falls back to the
/// declarative form, which is why the form has to stay good.
///
/// Polter compiles nothing for the plugin. What is loaded is what the author
/// put in `ui/`; if they wrote TSX or Svelte, the build that turned it into
/// HTML was theirs and happened before it ever got here.
struct PluginPage: NSViewRepresentable {
    /// The scheme the page is served over. See `PluginPageBridge` for why it
    /// is this and not `file:`.
    static let scheme = "polter-plugin"

    /// The one name the page can post to. Everything the page can ask for
    /// goes through here, so this list is the whole surface.
    static let handlerName = "polter"

    let plugin: Plugin

    /// Called after the page saves, so the menu can redraw its tick.
    var onSave: (() -> Void)?

    /// Called when the page asks to be closed.
    var onClose: (() -> Void)?

    func makeCoordinator() -> PluginPageBridge {
        PluginPageBridge(plugin: plugin, onSave: onSave, onClose: onClose)
    }

    func makeNSView(context: Context) -> WKWebView {
        // The coordinator holds the shell; the shell holds the view. ⚠️ The
        // web view's delegates are **weak**, so a shell made here and thrown
        // away would leave a page with no delegation at all -- see `Shell`.
        context.coordinator.view()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The page owns what it shows. Reloading it because SwiftUI redrew
        // would throw away whatever the person was in the middle of typing.
        context.coordinator.onSave = onSave
        context.coordinator.onClose = onClose
    }
}

/// Everything the page is allowed to touch, and everything that stops it
/// touching anything else.
///
/// ## What the page can do
///
/// One object, `window.polter`, with three calls: read this plugin's
/// settings, write this plugin's settings, close the window. That is all.
/// In particular **the page cannot reach the MCP tool surface** -- it cannot
/// type into a terminal, post to a group, list sessions, or see another
/// plugin.
///
/// The reason is not that the page is untrusted while the plugin process is
/// trusted; the plugin process has the full surface, on purpose. The reason
/// is the pollution surface. A plugin author who runs `npm i` once has put
/// somebody else's code inside this page, and the framework decides what
/// runs here far more than the author does. The plugin process having every
/// capability is one thing; the same set sitting inside a dependency tree is
/// another. Another plugin system we built holds this line with an import
/// allowlist -- no axios, no lodash, no component library -- because its
/// plugins share a runtime with the host. Polter's pages do not share a runtime, so there is no allowlist
/// and a page may bring whatever it likes; the line has to be held here
/// instead, at what the page can reach.
///
/// A page that wants to type into a terminal is a case nobody has yet had.
/// When somebody does, opening it is a decision with a reason attached,
/// which is better than it having been open from the start.
@MainActor
final class PluginPageBridge: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    private let plugin: Plugin

    /// Where the page's files live, resolved once and used for every request
    /// as the fence a served path must sit inside.
    private let root: URL

    /// The shell, made on the first ask and kept. See `Shell` on why the
    /// delegates have to be held by something that lives as long as the view.
    private var shell: WebViewShell.Shell<PluginPageBridge>?

    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    init(plugin: Plugin, onSave: (() -> Void)?, onClose: (() -> Void)?) {
        self.plugin = plugin
        self.root = plugin.directory
            .appendingPathComponent("ui", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.onSave = onSave
        self.onClose = onClose
    }

    /// The web view for this page, making the shell the first time.
    func view() -> WKWebView {
        if let shell { return shell.view }
        let made = WebViewShell.Shell(self)
        shell = made
        return made.view
    }

    /// The URL the page is loaded from. The plugin's key is the host, which
    /// is what makes each page its own origin.
    var entryURL: URL? {
        var components = URLComponents()
        components.scheme = PluginPage.scheme
        components.host = plugin.key
        components.path = "/index.html"
        return components.url
    }

    /// What the page finds on `window`.
    ///
    /// `postMessage` to a reply handler returns a promise, so the whole
    /// bridge is three lines with no message ids or pending tables to get
    /// wrong. Frozen and non-configurable so a dependency that runs later
    /// cannot quietly replace it with something that logs what it is handed.
    private static let pageBridgeScript = """
    (function () {
      const post = (method, argument) =>
        window.webkit.messageHandlers.\(PluginPage.handlerName)
          .postMessage({ method: method, argument: argument === undefined ? null : argument });

      Object.defineProperty(window, "polter", {
        value: Object.freeze({
          // -> {enabled, params: {name: value}, parameters: [...]}
          settings: () => post("read"),
          // ({enabled?, params?}) -> the settings as they were written
          save: (next) => post("write", next || {}),
          close: () => post("close"),
        }),
        writable: false,
        configurable: false,
        enumerable: true,
      });
    })();
    """
}

// MARK: What the shell has to be told

extension PluginPageBridge: WebViewShell.Page {
    static var scheme: String { PluginPage.scheme }
    static var handlerName: String { PluginPage.handlerName }
    static var bridgeScript: String { Self.pageBridgeScript }
    var policy: String { Self.policy }
}

// MARK: The three calls

extension PluginPageBridge: WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let method = body["method"] as? String
            else {
                replyHandler(nil, "malformed call")
                return
            }

            switch method {
            case "read":
                replyHandler(describe(PluginSettings.load(for: plugin)), nil)

            case "write":
                let argument = body["argument"] as? [String: Any] ?? [:]
                do {
                    replyHandler(try write(argument), nil)
                } catch {
                    // Handed back to the page rather than only logged: the
                    // page is what is on screen and the only thing that can
                    // tell the person their settings did not save.
                    replyHandler(nil, error.localizedDescription)
                }

            case "close":
                onClose?()
                replyHandler(nil, nil)

            default:
                // Named rather than ignored, so an author who guessed at a
                // call finds out instead of waiting on a promise forever.
                replyHandler(nil, "no such call: \(method)")
            }
        }
    }

    /// The settings, plus what the manifest declares about each parameter.
    ///
    /// The declarations are handed over rather than left for the page to go
    /// and read, because the page cannot read `plugin.json` -- it is outside
    /// `ui/`, and the fence is the point. A page that wants to render its
    /// own fields still gets the titles, the help and the closed sets, in
    /// the reader's language where the plugin ships a sidecar for it.
    private func describe(_ settings: PluginSettings) -> [String: Any] {
        var parameters: [[String: Any]] = []
        for parameter in plugin.parameters {
            var described: [String: Any] = [
                "name": parameter.name,
                "title": parameter.title,
                "help": parameter.help,
                "required": parameter.required,
                "secret": parameter.looksSecret,
            ]
            switch parameter.control {
            case .text:
                described["type"] = "text"
            case .flag:
                described["type"] = "boolean"
            case .choice(let choices):
                described["type"] = "enum"
                described["choices"] = choices.map(\.value)
                // What each value is called in the person's language, for a
                // page that wants to show it; the value is still what is saved.
                described["choice_labels"] = Dictionary(
                    choices.map { ($0.value, $0.label) }, uniquingKeysWith: { first, _ in first })
            }
            if let value = parameter.defaultValue { described["default"] = value }
            parameters.append(described)
        }

        return [
            "key": plugin.key,
            "name": plugin.name,

            // What it subscribes to, verbatim. A page rendering its own
            // screen has the same right to know this as the menu does, and
            // it cannot read the manifest to find out.
            "events": plugin.events,
            "enabled": settings.enabled,
            "params": settings.params,
            "parameters": parameters,
        ]
    }

    /// Write this plugin's settings, and nothing else's -- through the
    /// core's writer, the one the settings window and `plugin_configure`
    /// use (settings.md §5.1), not a file written from here.
    ///
    /// `enabled` and `params` are the whole of it. What is not named is left
    /// as it was, so a page that only wants to change one value does not
    /// have to send back everything it read and risk clobbering a field it
    /// did not understand. An empty value unsets one, as everywhere else.
    private func write(_ argument: [String: Any]) throws -> [String: Any] {
        var params: [String: String] = [:]
        if let raw = argument["params"] as? [String: Any] {
            for (name, value) in raw {
                // Only text. A settings file is a flat map of strings on
                // both sides -- the core reads nothing else out of it -- so
                // a number arriving here would be written and then not read,
                // which is worse than being refused.
                guard let text = value as? String else { continue }
                params[name] = text
            }
        }

        switch PluginCore.configure(plugin.key, enabled: argument["enabled"] as? Bool, params: params) {
        case .failure(let failure):
            throw PageWriteError(message: failure.message)
        case .success:
            onSave?()
            return describe(PluginSettings.load(for: plugin))
        }
    }

    private struct PageWriteError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

// MARK: Serving the page's own files, and nothing beside them

extension PluginPageBridge: WKURLSchemeHandler {
    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated { serve(task) }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Everything is read from disk and answered in one go, so there is
        // nothing in flight to cancel.
    }

    private func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url,
              url.scheme == PluginPage.scheme,

              // The host is the plugin's key and this handler belongs to one
              // plugin. A page asking for `polter-plugin://other/…` is asking
              // for somebody else's directory.
              url.host == plugin.key,
              let file = resolve(url.path)
        else {
            task.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }

        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.contentType(of: file),
                "Content-Length": String(data.count),
                "Content-Security-Policy": Self.policy,

                // The page is one plugin's, served to one web view. Nothing
                // should be reading it from anywhere else.
                "Access-Control-Allow-Origin": "null",
            ])

        guard let response else {
            task.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Turn a request path into a file inside `ui/`, or `nil`.
    ///
    /// The containment check is done on the *resolved* path, after `..` has
    /// been collapsed and after symlinks have been followed, because both
    /// are ways out of a directory and checking the string as written would
    /// catch neither. A plugin is somebody else's directory, so a symlink in
    /// it pointing at `~/.ssh` is a thing that can happen.
    private func resolve(_ path: String) -> URL? {
        let relative = (path.isEmpty || path == "/") ? "/index.html" : path

        let candidate = root
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let fence = root.path
        guard candidate.path == fence || candidate.path.hasPrefix(fence + "/")
        else {
            Self.logger.warning(
                "plugin \(self.plugin.key): page asked for \(path), which is outside its ui directory")
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        return candidate
    }

    /// What the page is allowed to load, said to the engine.
    ///
    /// `'self'` is `polter-plugin://<key>`, so everything has to come from
    /// the plugin's own `ui/`. `connect-src 'none'` is the one that matters
    /// most: no `fetch`, no `XMLHttpRequest`, no `WebSocket`, no
    /// `EventSource`. `data:` is allowed for images only, because inlining a
    /// small icon is how a single-file page ships one.
    ///
    /// `'unsafe-inline'` is allowed for scripts and styles. It is a real
    /// loosening and it is deliberate: plugin pages are single files written
    /// by hand as often as they are build output, and a policy that broke
    /// every `<script>` tag would be worked around by everybody rather than
    /// followed. What `'unsafe-inline'` protects against is injected script
    /// -- and the page has no network to be injected from, and no data
    /// arriving except this plugin's own settings.
    private static let policy = [
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

    /// Enough types for a page and its assets. Anything else is served as
    /// bytes: an unknown extension should not stop the file being fetched,
    /// and the engine sniffs what it can.
    private static func contentType(of file: URL) -> String {
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

// MARK: The two delegates are the shell's
//
// **Nothing here.** A link to `https://…` doing nothing, and `window.open`
// getting nothing back, used to be this class's `WKNavigationDelegate` and
// `WKUIDelegate`. They are `WebViewShell.Navigation` and
// `WebViewShell.Windows` now (task 2628, #2140 M1), because a preview needs
// exactly the same two answers from its view and a second copy of them is a
// second answer nothing would report -- both would be green on the day they
// drifted apart.
//
// The scheme list those delegates allow is `WebViewShell.allowedSchemes`,
// which for this page is `polter-plugin` and nothing else. A preview's adds
// `polter-file:`, and it is the same list the content rule list is compiled
// from, so a scheme a page may be loaded from and a scheme it may load
// cannot disagree.
