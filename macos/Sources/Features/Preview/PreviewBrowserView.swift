import AppKit
import SwiftUI
import WebKit

/// A matched `render: browser` preview: the ticket's own file in a web view
/// with scripts and network allowed, and **no `window.polter`**.
///
/// **The capability is still the ticket.** The file and every request it
/// makes over `polter-file://<token>/…` go through the existing
/// `PreviewBridge` scheme handler, which asks the core's `files_resolve` for
/// each path. Nothing here reads a file, builds a path or extends the
/// ticket's scope; the browser mode only changes the answer's policy (no
/// restrictive CSP) and omits the bridge.
///
/// **No settings or plugin page can come through here.** There is no message
/// handler, no injected script, no `extraSchemes` and no content rule list.
/// Navigation is limited to the ticket scheme and ordinary http/https;
/// `file:` and any other scheme are cancelled. `window.open` is refused.
@MainActor
struct PreviewBrowserView: NSViewRepresentable {
    let token: String

    func makeCoordinator() -> Coordinator {
        Coordinator(token: token)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Identity is the token; a new token makes a new view (the panel
        // keys it), and a redraw keeps this document.
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Holds the scheme handler: `WKWebView` keeps it weakly through the
        /// configuration, so it must outlive the view.
        let bridge: PreviewBridge
        let view: WKWebView

        init(token: String) {
            bridge = PreviewBridge(token: token, browser: true)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.setURLSchemeHandler(bridge, forURLScheme: PreviewRoutes.scheme)
            view = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            view.navigationDelegate = self
            view.uiDelegate = self
            view.allowsBackForwardNavigationGestures = false
            view.allowsMagnification = false
            view.load(URLRequest(url: Self.entry(token: token)))
        }

        /// The ticket's own file: an empty `rel` is the anchor
        /// (`Tickets.resolve`), which is what previewing a file means.
        private static func entry(token: String) -> URL {
            var components = URLComponents()
            components.scheme = PreviewRoutes.scheme
            components.host = token
            components.path = "/"
            return components.url!
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased()
            else {
                decisionHandler(.cancel)
                return
            }
            switch scheme {
            case PreviewRoutes.scheme, "http", "https":
                decisionHandler(.allow)
            case "mailto":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            default:
                // `file:` would be the host's own disk; every other scheme is
                // not something this view was given.
                decisionHandler(.cancel)
            }
        }

        /// No popups: a page cannot make a second window this preview does
        /// not know how to close.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
