import SwiftUI
import WebKit
import OSLog

/// A plugin's own settings page, shown in a `WKWebView`.
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
        let bridge = context.coordinator
        let webView = WKWebView(frame: .zero, configuration: bridge.configuration())
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge

        // Nothing here is a site, so there is nothing to go back to. A page
        // that swallowed a two-finger swipe and navigated would leave a
        // settings window showing a blank frame with no way back.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        bridge.load(into: webView)
        return webView
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
/// another. Tinia holds this line with an import allowlist -- no axios, no
/// lodash, no component library -- because its plugins share a runtime with
/// the host. Polter's pages do not share a runtime, so there is no allowlist
/// and a page may bring whatever it likes; the line has to be held here
/// instead, at what the page can reach.
///
/// A page that wants to type into a terminal is a case nobody has yet had.
/// When somebody does, opening it is a decision with a reason attached,
/// which is better than it having been open from the start.
///
/// ## What stops it
///
/// Each of these is a separate decision, written down because a default
/// taken silently is a default nobody can review:
///
/// 1. **A custom scheme, not `file:`.** Loading `file:///…/ui/index.html`
///    means either no read access to the page's own siblings, or -- with
///    `allowFileAccessFromFileURLs` -- a page that can `fetch` any file the
///    user can read, `~/.ssh` included. And `file:` origins are treated as
///    opaque and inconsistent across WebKit versions, which is a poor thing
///    to build an isolation story on. A scheme handler means every single
///    request is resolved by the code below, so "may not leave `ui/`" is a
///    check that runs rather than a property hoped for.
/// 2. **One origin per plugin.** The URL is `polter-plugin://<key>/…`, so
///    two plugins' pages are cross-origin to each other by the browser's own
///    rules -- no reaching across via frames or `window.opener`. Each page
///    also gets a fresh non-persistent data store, so cookies, local storage
///    and caches are neither shared between plugins nor left on disk.
/// 3. **No network.** Twice over, and deliberately: a `Content-Security-
///    Policy` header on every response, which covers `fetch`, `XHR`,
///    `WebSocket`, images, fonts and frames; and a content rule list that
///    blocks every load whose URL is not this scheme, which covers anything
///    CSP is later found not to. A settings page has no reason to talk to
///    the internet, and the dependency that does is exactly the one nobody
///    read.
/// 4. **No new windows.** `window.open` and `target="_blank"` get nothing
///    back. A page inside a settings window that can conjure a second
///    window is a page that can draw something that looks like Polter
///    asking for a password.
/// 5. **JavaScript stays on.** It is the point -- a page without it is a
///    worse version of the declarative form. What is switched off is
///    JavaScript *opening windows by itself*, which is (4) said to the
///    engine as well as to the delegate.
@MainActor
final class PluginPageBridge: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "plugins")

    private let plugin: Plugin

    /// Where the page's files live, resolved once and used for every request
    /// as the fence a served path must sit inside.
    private let root: URL

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

    /// The URL the page is loaded from. The plugin's key is the host, which
    /// is what makes each page its own origin.
    private var entryURL: URL? {
        var components = URLComponents()
        components.scheme = PluginPage.scheme
        components.host = plugin.key
        components.path = "/index.html"
        return components.url
    }

    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // Not shared with any other web view in the app, and never written
        // to disk: a settings page has no session to keep, and what it does
        // store should not outlive the window or be visible to the next
        // plugin's page.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(self, forURLScheme: PluginPage.scheme)

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: PluginPage.handlerName)
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,

            // The main frame only. A page that frames something else does
            // not get to hand the bridge to whatever it framed.
            forMainFrameOnly: true))
        configuration.userContentController = controller

        return configuration
    }

    /// Compile the block-everything rule list, then load the page.
    ///
    /// The load waits for the rule list so the page never runs for even one
    /// frame without it. If compiling fails the page is loaded anyway and
    /// the failure is logged: the CSP header on every response is the
    /// primary control and this is the belt beside it, so a page that
    /// silently never appears would be a worse outcome than a page running
    /// with one of two network blocks.
    func load(into webView: WKWebView) {
        guard let url = entryURL else { return }
        let request = URLRequest(url: url)

        guard let store = WKContentRuleListStore.default() else {
            Self.logger.warning("no content rule list store; page loads with CSP only")
            webView.load(request)
            return
        }

        store.compileContentRuleList(
            forIdentifier: "polter-plugin-offline",
            encodedContentRuleList: Self.blockEverythingElse
        ) { [weak webView] list, error in
            guard let webView else { return }
            if let list {
                webView.configuration.userContentController.add(list)
            } else {
                Self.logger.warning(
                    "content rules did not compile, page loads with CSP only: \(String(describing: error))")
            }
            webView.load(request)
        }
    }

    /// Block every load, then let this scheme back through.
    ///
    /// Written in that order because the last matching rule wins: a single
    /// "allow ours" rule would not stop anything, and a single "block http"
    /// rule would miss every scheme nobody thought of.
    private static let blockEverythingElse = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^polter-plugin://"},
       "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// What the page finds on `window`.
    ///
    /// `postMessage` to a reply handler returns a promise, so the whole
    /// bridge is three lines with no message ids or pending tables to get
    /// wrong. Frozen and non-configurable so a dependency that runs later
    /// cannot quietly replace it with something that logs what it is handed.
    private static let bridgeScript = """
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

    /// Write this plugin's file, and nothing else's.
    ///
    /// `enabled` and `params` are the whole of it. What is not named is left
    /// as it was, so a page that only wants to change one value does not
    /// have to send back everything it read and risk clobbering a field it
    /// did not understand.
    private func write(_ argument: [String: Any]) throws -> [String: Any] {
        var settings = PluginSettings.load(for: plugin)

        if let enabled = argument["enabled"] as? Bool { settings.enabled = enabled }

        if let params = argument["params"] as? [String: Any] {
            for (name, value) in params {
                // Only text. A settings file is a flat map of strings on
                // both sides -- the core reads nothing else out of it -- so
                // a number arriving here would be written and then not read,
                // which is worse than being refused.
                guard let text = value as? String else { continue }
                settings.params[name] = text
            }
        }

        try settings.save(key: plugin.key)
        onSave?()
        return describe(settings)
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

// MARK: Nowhere to navigate, nowhere to open

extension PluginPageBridge: WKNavigationDelegate, WKUIDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            // Only this scheme. A link to `https://…` does nothing rather
            // than turning a settings window into a browser; the content
            // rules block the load anyway, and this stops the frame being
            // replaced by a failure page.
            guard navigationAction.request.url?.scheme == PluginPage.scheme else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // See (4) on `PluginPageBridge`: a page that can put a second window
        // on screen can put something that looks like Polter on screen.
        nil
    }
}
