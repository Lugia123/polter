import OSLog
import SwiftUI
import WebKit

/// The one web view shell a plugin's settings page and a file preview are
/// both served in (task 2628, #2140 M1; `polter-artifacts/2145/PLAN.md`
/// §2.1: "mac 从 `PluginPage.swift` 抽出一个 `PluginWebView`，配置、scheme、
/// CSP、拦导航、拦新窗口都在里面，设置页和预览共用").
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
/// Polter compiles nothing for the page. What is loaded is what the plugin
/// author put in `ui/` -- or, for a preview, the file the core's ticket
/// points at. If the author wrote TSX or Svelte, the build that turned it
/// into HTML was theirs and happened before it ever got here.
///
/// # What the shell decides, and what it is handed
///
/// The shell owns the five things that must not differ between the two
/// pages, because each one is a decision that is unreviewable if it is made
/// twice:
///
/// 1. **A fresh, non-persistent data store.** Cookies, local storage and
///    caches are neither shared between two pages nor left on disk.
/// 2. **One origin per page**, by the scheme's authority. Two pages are
///    cross-origin to each other by the browser's own rules.
/// 3. **No network, twice over**: a `Content-Security-Policy` header on
///    every response the page's own bridge serves, and a content rule list
///    that blocks every load whose URL is not one of the schemes the page is
///    served over. The rule list is what covers anything CSP is later found
///    not to.
/// 4. **No navigation away.** A link to `https://…` does nothing rather than
///    turning the page into a browser.
/// 5. **No new windows.** `window.open` and `target="_blank"` get nothing
///    back. A page that can conjure a second window is a page that can draw
///    something that looks like Polter asking for a password.
///
/// What it does *not* decide is what the page can **do**: that is the
/// bridge's `window.polter`, and the script message handler it is posted to
/// -- `PluginPageBridge` for a settings page, `PreviewBridge` for a preview.
/// The shell never sees a message.
@MainActor
enum WebViewShell {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "webview")

    /// Everything the shell has to be told, and nothing else.
    ///
    /// A type conforms to this and takes care of what its own
    /// `window.polter` may do; the shell takes care of what surrounds it.
    /// **The conforming types are concrete and live in the tree**
    /// (`PluginPageBridge`, `PreviewBridge`), so this is a list of two, and a
    /// third would have to come with a reason.
    @MainActor
    protocol Page: AnyObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
        /// The scheme the page itself is served over, and **the only scheme
        /// it may be loaded from**. Its authority is what makes each page its
        /// own origin: a plugin's key for a settings page, a ticket for a
        /// preview. There is no second scheme anywhere here -- a preview's
        /// own file, the images in it and the page that shows it are all
        /// `polter-file://<token>/…`, which is one rule rather than an allow
        /// list that can come to disagree with the requests it allows.
        static var scheme: String { get }

        /// The one name the page can post to. Everything the page can ask
        /// for goes through here, so this name is the whole surface.
        static var handlerName: String { get }

        /// What the page finds on `window`.
        static var bridgeScript: String { get }

        /// What the page is loaded from.
        var entryURL: URL? { get }

        /// Any scheme besides `scheme` this page's own resources come over.
        ///
        /// A preview of a file the core showed through a plugin has two kinds
        /// of bytes: the ticket's (`scheme`, judged by the core on every
        /// read) and the plugin's own installed page
        /// (`PreviewPluginPage.scheme`, fenced to that plugin's directory).
        /// The settings page has neither and takes the default.
        var extraSchemes: [String] { get }

        /// The `Content-Security-Policy` sent with every response this
        /// page's bridge serves. Per page rather than per shell because a
        /// preview's policy names one ticket's origin and a settings page has
        /// no ticket to name.
        var policy: String { get }
    }

    /// Every scheme a page of this kind may be loaded from: its own and any
    /// it declares, and nothing else. Named as a list because that is the
    /// shape the content rule list, the scheme handlers and the navigation
    /// delegate all take, so none of them can be compiled from a different
    /// answer.
    static func allowedSchemes(_ page: some Page) -> [String] {
        [type(of: page).scheme] + page.extraSchemes
    }

    /// A page, its web view, and the delegate objects that have to outlive
    /// the call that made them.
    ///
    /// ⚠️ **`WKWebView.navigationDelegate` and `.uiDelegate` are weak.** Hand
    /// one of these a freshly made delegate and it is deallocated before the
    /// page loads, which looks exactly like a delegate that was never set:
    /// links navigate the window away and `window.open` opens a window. So
    /// the shell is an object that *holds* them, and the view's owner holds
    /// the shell -- which is the one rule this type asks of its owner.
    ///
    /// ⚠️ **And so `page` is `unowned`, for the same reason read the other
    /// way round.** The page is already held by whatever retains it for its
    /// own sake (SwiftUI's coordinator for a settings page, the view that
    /// draws the slot for a preview), and a second strong reference from here
    /// would be a cycle the moment that owner also hangs on to the shell --
    /// which is exactly what both owners do, because they are the same
    /// object. `Shell` never outlives its page: it is made by, and stored in,
    /// the thing that owns the page.
    @MainActor
    final class Shell<Page: WebViewShell.Page> {
        unowned let page: Page
        let view: WKWebView
        private let navigation: Navigation
        private let windows: Windows

        init(_ page: Page) {
            self.page = page
            self.navigation = Navigation(schemes: WebViewShell.allowedSchemes(page))
            self.windows = Windows()
            self.view = WKWebView(frame: .zero, configuration: configuration(page))
            view.navigationDelegate = navigation
            view.uiDelegate = windows

            // Nothing here is a site, so there is nothing to go back to. A
            // page that swallowed a two-finger swipe and navigated would
            // leave the window showing a blank frame with no way back.
            view.allowsBackForwardNavigationGestures = false
            view.allowsMagnification = false

            load(page, into: view)
        }
    }

    private static func configuration(_ page: some Page) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // Not shared with any other web view in the app, and never written
        // to disk: a settings page has no session to keep, and what it does
        // store should not outlive the window or be visible to the next
        // plugin's page. A preview is the same and more so -- it is showing
        // somebody's file.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // **Every scheme the page declares, not only its own** (task 2779
        // S7B): a preview of a file shown by a plugin has the ticket's
        // `polter-file:` bytes *and* the plugin's own installed page, and
        // both have to have a handler or the second one never loads.
        for scheme in allowedSchemes(page) {
            configuration.setURLSchemeHandler(page, forURLScheme: scheme)
        }

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(
            page,
            contentWorld: .page,
            name: type(of: page).handlerName)
        controller.addUserScript(WKUserScript(
            source: type(of: page).bridgeScript,
            injectionTime: .atDocumentStart,

            // The main frame only. A page that frames something else does
            // not get to hand the bridge to whatever it framed.
            forMainFrameOnly: true))
        configuration.userContentController = controller

        return configuration
    }

    /// Compile the block-everything-else rule list, then load the page.
    ///
    /// The load waits for the rule list so the page never runs for even one
    /// frame without it. If compiling fails the page is loaded anyway and
    /// the failure is logged: the CSP header on every response is the
    /// primary control and this is the belt beside it, so a page that
    /// silently never appears would be a worse outcome than a page running
    /// with one of two network blocks.
    private static func load(_ page: some Page, into webView: WKWebView) {
        guard let url = page.entryURL else { return }
        let request = URLRequest(url: url)
        let allowed = allowedSchemes(page)

        guard let store = WKContentRuleListStore.default() else {
            logger.warning("no content rule list store; page loads with CSP only")
            webView.load(request)
            return
        }

        store.compileContentRuleList(
            // ⚠️ **The identifier names the scheme, not the shell.** The two
            // pages are served over different schemes (`polter-plugin` for a
            // settings page, `polter-file` for a preview) and the store is
            // keyed by identifier: one shared name would have the second
            // page's compile stand in for the first's, so a preview could be
            // loaded with a rule list that blocks the very scheme it is
            // served over. Nothing would fail -- the page would simply never
            // appear, with the only trace a line in the log.
            forIdentifier: "polter-page-offline-\(allowed.joined(separator: "-"))",
            encodedContentRuleList: blockEverythingElse(allowed)
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

    /// Block every load, then let the page's own schemes back through.
    ///
    /// Written in that order because the last matching rule wins: a single
    /// "allow ours" rule would not stop anything, and a single "block http"
    /// rule would miss every scheme nobody thought of.
    private static func blockEverythingElse(_ schemes: [String]) -> String {
        var rules = [#"{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}"#]
        for scheme in schemes {
            rules.append("""
            {"trigger": {"url-filter": "^\(scheme)://"}, \
            "action": {"type": "ignore-previous-rules"}}
            """)
        }
        return "[\n  " + rules.joined(separator: ",\n  ") + "\n]"
    }

    // MARK: Nowhere to navigate, nowhere to open

    /// Only the page's own schemes. A link to `https://…` does nothing
    /// rather than turning the window into a browser; the content rules
    /// block the load anyway, and this stops the frame being replaced by a
    /// failure page.
    final class Navigation: NSObject, WKNavigationDelegate {
        private let schemes: [String]

        init(schemes: [String]) {
            self.schemes = schemes
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                let scheme = navigationAction.request.url?.scheme ?? ""
                decisionHandler(schemes.contains(scheme) ? .allow : .cancel)
            }
        }
    }

    /// A page that can put a second window on screen can put something that
    /// looks like Polter on screen.
    final class Windows: NSObject, WKUIDelegate {
        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

/// **No second scheme unless a page says it has one.** The settings page
/// serves everything out of one scheme and this is what keeps it that way --
/// a page that wants a second one has to declare it, so the answer to "what
/// may this page be loaded from" is never accidentally wider than the page
/// itself needs.
extension WebViewShell.Page {
    var extraSchemes: [String] { [] }
}
