// A real WKWebView, the real page, a host the probe drives one message at a
// time (task 3098).
//
// **Not a browser test.** It serves `web/chat/` over the page's own scheme and
// installs `window.polter` before `chat.js` runs, exactly as a host does, then
// asserts what the page does when a host stays silent or answers badly:
//
//   1. no `page.reset` ever -> after 10 s the boot overlay says "still
//      loading", the retry is pressable, and `chat.ready` has been sent again;
//      pressing the retry sends another one.
//   2. a good empty `page.reset` -> the boot overlay goes; `chat.loadOlder`
//      is asked for (the page is at the top of an empty document).
//   3. `page.prepend {messages: [], hasEarlier: false}` -> "start of
//      history", and no further `chat.loadOlder`.
//   4. `page.prepend {messages: [], hasEarlier: false, error: "..."}` ->
//      the pill says earlier messages could not be read, is pressable, and
//      pressing it re-sends `chat.loadOlder`.
//   5. `page.reset {..., error: "..."}` -> the boot overlay says the read
//      failed and its retry re-sends `chat.ready`.
//
// Build and run from the repository root:
//
//   swiftc -O web/chat/probe/chat-page-probe.swift -o /tmp/chat-page-probe
//   /tmp/chat-page-probe web/chat
//
// Exit 0 when every reading matches; 1 otherwise. It needs a running
// WindowServer (the web view is real), so it is not part of mac-logic-tests.

import AppKit
import WebKit

let SCHEME = "probe-chat"
let HOST = "chat"

/// The page, served from the directory on argv[1].
final class Files: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(CocoaError(.fileNoSuchFile)); return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(CocoaError(.fileReadNoSuchFile)); return
        }
        let type: String
        switch file.pathExtension {
        case "html": type = "text/html; charset=utf-8"
        case "js": type = "text/javascript; charset=utf-8"
        case "css": type = "text/css; charset=utf-8"
        default: type = "application/octet-stream"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// What the page sent, in order.
final class Host: NSObject, WKScriptMessageHandler {
    var received: [[String: Any]] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let body = m.body as? [String: Any] { received.append(body) }
    }
    func count(_ type: String) -> Int { received.filter { $0["type"] as? String == type }.count }
}

let host = Host()
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/chat")
let files = Files(root: root)

let config = WKWebViewConfiguration()
config.setURLSchemeHandler(files, forURLScheme: SCHEME)
config.websiteDataStore = .nonPersistent()
let controller = WKUserContentController()
controller.add(host, name: "probe")
// **Installed before chat.js runs**, so the page's first `chat.ready` comes
// here instead of into the page's own `sent` record.
controller.addUserScript(WKUserScript(
    source: """
    window.polter = {
      postMessage: function (m) { window.webkit.messageHandlers.probe.postMessage(m); }
    };
    """,
    injectionTime: .atDocumentStart, forMainFrameOnly: true))
config.userContentController = controller

let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
var failures = 0

func fail(_ what: String, _ detail: Any = "") {
    failures += 1
    print("FAIL: \(what) \(detail)")
}
func pass(_ what: String, _ detail: Any = "") {
    print("PASS: \(what) \(detail)")
}
func js(_ source: String, _ done: @escaping (Any?) -> Void) {
    web.evaluateJavaScript(source) { value, error in
        if let error { print("  (js error: \(error.localizedDescription))") }
        done(value)
    }
}
func wait(_ seconds: Double, _ done: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: done)
}
/// Poll until `test` is true or `limit` seconds pass.
func until(_ limit: Double, _ label: String, _ test: @escaping () -> Bool,
           _ then: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(limit)
    func tick() {
        if test() { then(); return }
        if Date() > deadline { then(); return }
        wait(0.25, tick)
    }
    tick()
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else {
        fail("probe host could not encode", object); return
    }
    js("window.polterChat.receive(\(text))") { _ in }
}
func pageState(_ done: @escaping ([String: Any]) -> Void) {
    js("""
    JSON.stringify({
      bootSettled: window.polterChat.state.bootSettled,
      bootVisible: !!(document.getElementById('boot') && !document.getElementById('boot').hidden),
      bootText: (document.querySelector('#boot .boot-text') || {}).textContent || '',
      bootRetryVisible: !!(document.querySelector('#boot .boot-retry') && !document.querySelector('#boot .boot-retry').hidden),
      topText: (document.getElementById('top-text') || {}).textContent || '',
      topRetry: !!(document.getElementById('top') && document.getElementById('top').classList.contains('retry')),
      hasEarlier: window.polterChat.state.hasEarlier,
      resetDone: window.polterChat.state.resetDone
    })
    """) { value in
        guard let text = value as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fail("could not read page state", value ?? "nil"); done([:]); return }
        done(object)
    }
}
func string(_ s: [String: Any], _ k: String) -> String { s[k] as? String ?? "" }
func bool(_ s: [String: Any], _ k: String) -> Bool { s[k] as? Bool ?? false }

// MARK: the readings

func step1() {
    until(8, "chat.ready", { host.count("chat.ready") >= 1 }) {
        guard host.count("chat.ready") >= 1 else { fail("page never said chat.ready"); finish(); return }
        pass("page said chat.ready", "count=\(host.count("chat.ready"))")
        // 10 s with no reset: still loading, pressable, asked again.
        wait(10.6) {
            pageState { state in
                let ready = host.count("chat.ready")
                if bool(state, "bootVisible") && string(state, "bootText").contains("还在读")
                    && bool(state, "bootRetryVisible") {
                    pass("silent host shows still-loading retry", string(state, "bootText"))
                } else {
                    fail("silent host did not show the still-loading retry", state)
                }
                if ready >= 2 {
                    pass("silent host was asked again", "chat.ready count=\(ready)")
                } else {
                    fail("page did not ask again after the timeout", "count=\(ready)")
                }
                let before = ready
                js("document.querySelector('#boot .boot-retry').click()") { _ in
                    wait(0.5) {
                        if host.count("chat.ready") > before {
                            pass("retry re-sent chat.ready", "count=\(host.count("chat.ready"))")
                        } else {
                            fail("retry did not re-send chat.ready", "count=\(host.count("chat.ready"))")
                        }
                        step1b()
                    }
                }
            }
        }
    }
}

/// A first screen that failed, still before any good reset: the page must say
/// so and the retry must ask again (nothing readable exists to lose yet).
func step1b() {
    send(["type": "page.reset", "messages": [], "theme": ["mode": "dark"],
          "locale": "zh", "hasEarlier": false, "error": "boom"])
    wait(0.6) {
        pageState { state in
            if bool(state, "bootVisible") && string(state, "bootText").contains("读不到")
                && bool(state, "bootRetryVisible") && !bool(state, "bootSettled") {
                pass("a failed first screen says so", string(state, "bootText"))
            } else {
                fail("a failed first screen did not say so", state)
            }
            let before = host.count("chat.ready")
            js("document.querySelector('#boot .boot-retry').click()") { _ in
                wait(0.5) {
                    if host.count("chat.ready") > before {
                        pass("the failed first screen's retry re-sent chat.ready",
                             "count=\(host.count("chat.ready"))")
                    } else {
                        fail("the failed first screen's retry did not re-send chat.ready",
                             "count=\(host.count("chat.ready"))")
                    }
                    step2()
                }
            }
        }
    }
}

func step2() {
    send(["type": "page.reset", "messages": [], "theme": ["mode": "dark"],
          "locale": "zh", "hasEarlier": true])
    wait(0.8) {
        pageState { state in
            if !bool(state, "bootVisible") && bool(state, "bootSettled") {
                pass("empty reset settles the first screen")
            } else {
                fail("empty reset did not settle the first screen", state)
            }
                    until(2, "loadOlder", { host.count("chat.loadOlder") >= 1 }) {
                if host.count("chat.loadOlder") >= 1 {
                    pass("empty top asked for older", "count=\(host.count("chat.loadOlder"))")
                } else {
                    fail("empty top did not ask for older", "count=\(host.count("chat.loadOlder"))")
                }
                step3()
            }
        }
    }
}

func step3() {
    send(["type": "page.prepend", "messages": [], "hasEarlier": false])
    wait(0.5) {
        pageState { state in
            if bool(state, "hasEarlier") == false && string(state, "topText").contains("到头了") {
                pass("empty prepend is the end of history", string(state, "topText"))
            } else {
                fail("empty prepend was not the end of history", state)
            }
            let count = host.count("chat.loadOlder")
            wait(0.8) {
                if host.count("chat.loadOlder") == count {
                    pass("the end of history was not asked past", "count=\(count)")
                } else {
                    fail("the page asked for older past the end", "count=\(host.count("chat.loadOlder"))")
                }
                step4()
            }
        }
    }
}

func step4() {
    // Ask again from a fresh top so `hasEarlier` is true.
    send(["type": "page.reset", "messages": [], "theme": ["mode": "dark"],
          "locale": "zh", "hasEarlier": true])
    until(2, "loadOlder2", { host.count("chat.loadOlder") >= 2 }) {
        send(["type": "page.prepend", "messages": [], "hasEarlier": false, "error": "boom"])
        wait(0.5) {
            pageState { state in
                if string(state, "topText").contains("更早的记录读不到") && bool(state, "topRetry")
                    && bool(state, "hasEarlier") {
                    pass("a failed older read says so and stays askable", string(state, "topText"))
                } else {
                    fail("a failed older read did not say so", state)
                }
                let before = host.count("chat.loadOlder")
                js("document.getElementById('top').click()") { _ in
                    wait(0.5) {
                        if host.count("chat.loadOlder") > before {
                            pass("the pill's retry re-sent chat.loadOlder",
                                 "count=\(host.count("chat.loadOlder"))")
                        } else {
                            fail("the pill's retry did not re-send chat.loadOlder",
                                 "count=\(host.count("chat.loadOlder"))")
                        }
                        finish()
                    }
                }
            }
        }
    }
}

func finish() {
    print(failures == 0 ? "OK: every reading matched." : "FAIL: \(failures) reading(s) did not match.")
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
web.load(URLRequest(url: URL(string: "\(SCHEME)://\(HOST)/index.html")!))
step1()
app.run()
