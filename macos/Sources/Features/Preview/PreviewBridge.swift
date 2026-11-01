import AppKit
import GhosttyKit
import OSLog
import WebKit

/// A file being previewed, in the same web view shell a plugin's settings
/// page is served in (task 2628, #2140 M1; `polter-artifacts/2145/PLAN.md`
/// §2.1 and §3.2).
///
/// **The shell is `WebViewShell`'s** -- a non-persistent store, one origin per
/// page, no network twice over, no navigation away, no new windows -- and the
/// reasons are in that file's header. What is here is what a *preview* is: the
/// eight calls `window.polter` carries, and where the bytes come from.
///
/// # Where the bytes come from
///
/// **Never from a path this file worked out.** A preview is served over
/// `polter-file://<token>/<rel>`; the token is a capability the core minted for
/// one workdir and one scope (`src/poltergeist/files/Tickets.zig`, task 2573),
/// and every request -- the page itself, an `<img>`, a `read` -- goes back
/// through `ghostty_app_files` to the core's `files_resolve(token, rel)`, which
/// judges `rel` against *that ticket* again and answers the real path, or a
/// refusal. This file reads only the path it was given. Which ticket and which
/// `rel` a URL means is `PreviewRoutes`'s, the same rule the Windows host runs
/// (`windows/preview-route`), and they are held to one table
/// (`test/fixtures/preview-routes.tsv`).
///
/// # What the page can reach
///
/// `window.polter` with the eight calls `PreviewCall` names: `info`, `read`,
/// `readRel`, `openPath`, `watch`, `look`, `propose`, `dirty`. **There is no
/// `write`, no `create`, no `delete`, no `rename`, no `exec`, no `fetch`.**
/// Writing happens only through the core's `files_commit`, and only once the
/// person has chosen on the host's own change screen -- `propose` is not a
/// write, it hands the text over.
///
/// # Why the settings page's scheme is not registered here
///
/// A preview shows one file, and the file previewed is somebody's document,
/// not a plugin: there is no plugin page to load and no `ui/` to read. So the
/// only scheme this view serves, and the only one it will navigate to, is its
/// own. The shell compiles its content rule list from exactly that list, so
/// "what this page may be served from" and "what it may load" are one answer
/// rather than two that can drift.
@MainActor
final class PreviewBridge: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "preview")

    /// The ticket this view is showing. **The whole of what the host knows
    /// about the file**: it cannot be turned into a path here, and nothing
    /// here tries.
    let token: String

    /// Told when the page says there are unsaved changes, so the host can draw
    /// its own "you have unsaved changes" question. Nothing is written.
    var onDirty: ((Bool) -> Void)?

    /// Told when the page asks for another file in the same slot. The host
    /// switches the preview; this view does not move its own anchor.
    var onOpen: ((String) -> Void)?

    /// The shell, made on the first ask and kept. ⚠️ `WKWebView`'s delegates
    /// are **weak**: a shell nobody holds is a shell whose delegates are
    /// deallocated before the page loads, which looks exactly like "no
    /// delegate was ever set" -- links navigate the view away and `window.open`
    /// gets a window.
    private var shell: WebViewShell.Shell<PreviewBridge>?

    init(token: String) {
        self.token = token
    }

    /// The web view for this file, making the shell the first time.
    func view() -> WKWebView {
        if let shell { return shell.view }
        let made = WebViewShell.Shell(self)
        shell = made
        return made.view
    }
}

// MARK: What the shell has to be told

extension PreviewBridge: WebViewShell.Page {
    static var scheme: String { PreviewRoutes.scheme }
    static var handlerName: String { "polter" }
    static var bridgeScript: String { Self.previewBridgeScript }

    /// The ticket's own file: an empty `rel` is the anchor
    /// (`Tickets.resolve`), which is what previewing a file means.
    var entryURL: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        components.path = "/"
        return components.url
    }

    /// Per ticket rather than per shell: this policy names the one origin a
    /// preview may load from, and a settings page has no ticket to name. The
    /// text is `PreviewRoutes.policy`'s so the mac and Windows hosts send the
    /// same one.
    var policy: String { PreviewRoutes.policy(token: token) }

    /// What the page finds on `window`.
    ///
    /// `postMessage` to a reply handler returns a promise, so the bridge is a
    /// list of one-line calls with no message ids or pending tables to get
    /// wrong -- the shape `PluginPage.swift`'s bridge has. Frozen and
    /// non-configurable so a dependency that runs later cannot quietly replace
    /// it with something that logs what it is handed.
    ///
    /// ⚠️ **The eight names are `PreviewCall`'s, and this is JavaScript.** The
    /// host refuses anything else at the one name it posts to
    /// (`PreviewCall.parse` is the whole surface), so a call named here and not
    /// there comes back `no such call` rather than being lost; the route
    /// tests hold both sides of the wire to the same eight.
    /// ⚠️ **`PreviewBridge.handlerName`, not `Self.handlerName`.** This is a
    /// *stored* property, and a covariant `Self` cannot be referenced from a
    /// stored property's initializer (`error: covariant 'Self' type cannot be
    /// referenced from a stored property initializer`) -- the interpolation is
    /// run when the type's stored properties are set up, before `Self` means
    /// this type. `PluginPage.swift`'s script names its own type for the same
    /// reason. **Not written as a literal**, though that would also compile:
    /// the handler name is registered from `handlerName`, so a literal here
    /// would be a second copy of it that can drift -- and the day it drifts,
    /// the page posts to a handler nobody registered and gets silence.
    private static let previewBridgeScript = """
    (function () {
      // The top frame only: a page that frames something else does not get to
      // hand the bridge to whatever it framed.
      if (window.top !== window) return;
      const post = (method, argument) =>
        window.webkit.messageHandlers.\(PreviewBridge.handlerName)
          .postMessage({ method: method, argument: argument === undefined ? null : argument });

      Object.defineProperty(window, "polter", {
        value: Object.freeze({
          // -> what the core says the file is
          info: () => post("info"),
          // ({offset, length}) -> {base64, size, truncated}
          read: (offset, length) => post("read", { offset: offset || 0, length: length || 0 }),
          // ({rel, offset, length}) -> the same, for a file in the ticket's range
          readRel: (rel, offset, length) =>
            post("readRel", { rel: rel, offset: offset || 0, length: length || 0 }),
          // ({rel}) -> the host switches the preview, on the core's answer
          openPath: (rel) => post("openPath", { rel: rel }),
          // (cb) -> true. The host calls back when the file changes.
          watch: (cb) => post("watch", { cb: true }).then((ok) => {
            window.__polterWatch = cb;
            return ok;
          }),
          // -> {dark, colours, size, radius}
          look: () => post("look"),
          // ({fullText, baseVersion}) -> what the core would write. **Not a write.**
          propose: (fullText, baseVersion) =>
            post("propose", { fullText: fullText, baseVersion: baseVersion }),
          // (bool) -> true. The host keeps this; nothing is written.
          dirty: (yes) => post("dirty", { dirty: !!yes }),
        }),
        writable: false,
        configurable: false,
        enumerable: true,
      });
    })();
    """
}

// MARK: The eight calls

extension PreviewBridge: WKScriptMessageHandlerWithReply {
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
            let argument = body["argument"] as? [String: Any] ?? [:]

            // **`PreviewCall.parse` is the whole surface.** A method that is
            // not one of the eight gets `no such call` back, so an author who
            // guessed finds out instead of waiting on a promise that never
            // settles -- and there is no case for `write` or `delete` to fall
            // into, because there is none to give them.
            guard let call = PreviewCall.parse(method) else {
                replyHandler(nil, "no such call: \(method)")
                return
            }

            switch ask(call, argument) {
            case .success(let value):
                replyHandler(value, nil)
            case .failure(let why):
                // The core's own words, handed to the page: a page that asked
                // for something it may not have should hear "no", not wait.
                Self.logger.info(
                    "preview \(self.token, privacy: .public): \(method, privacy: .public) refused: \(why.message, privacy: .public)")
                replyHandler(nil, why.message)
            }
        }
    }

    /// One of the eight calls, answered.
    private func ask(_ call: PreviewCall, _ argument: [String: Any]) -> Result<Any, CoreFailure> {
        switch call {
        // What the file is, reread on every ask rather than kept, so a file
        // that changed under the preview is not described by what it was.
        case .info:
            return resolve("")

        case .read, .readRel:
            // An empty `rel` is the ticket's own file: `read` and `readRel`
            // are one call, and which file it is about is the only difference.
            // A `readRel` with no path is refused rather than read as the
            // anchor -- the page asked about a different file and would
            // silently be handed this one.
            if call == .readRel, argument["rel"] as? String == nil {
                return .failure(.refused("readRel needs a path"))
            }
            let resolved: [String: Any]
            switch resolvedObject(call == .read ? "" : (argument["rel"] as? String ?? "")) {
            case .success(let object): resolved = object
            case .failure(let why): return .failure(why)
            }
            let offset = max(0, argument["offset"] as? Int ?? 0)
            let length = argument["length"] as? Int ?? 0
            let want = length <= 0 ? PreviewRoutes.readMax : min(length, PreviewRoutes.readMax)
            return read(resolved, offset: offset, length: want)

        // **The host switches the preview; the page does not read a path.**
        // The `rel` goes to the core like any other, so a file outside this
        // ticket's scope is refused here as it would be in an `<img>`.
        case .openPath:
            guard let rel = argument["rel"] as? String else {
                return .failure(.refused("openPath needs a path"))
            }
            switch resolvedObject(rel) {
            case .failure(let why):
                return .failure(why)
            case .success(let resolved):
                onOpen?(rel)
                return .success(["path": resolved["path"] as? String ?? "", "opened": true])
            }

        // Registered for the page; what happens when the file moves is the
        // host's, and it is the host that drives it.
        case .watch:
            Self.logger.debug("preview \(self.token, privacy: .public): the page wants a watch")
            return .success(["watching": true])

        // Colour tokens, the face and the sizes, from where the host's own
        // windows get them, so a preview and the window around it do not
        // disagree about a colour.
        case .look:
            return .success(PreviewRoutes.look(
                dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                // Never below the menu font: the rule the whole app holds to,
                // and the reason this is asked of the system rather than
                // written down.
                menuPointSize: SettingsFont.minimumPointSize,
                fonts: [
                    "ui": NSFont.systemFont(ofSize: ControlRoomLook.Font.body).fontName,
                    "mono": NSFont.monospacedSystemFont(
                        ofSize: ControlRoomLook.Font.body, weight: .regular).fontName,
                ]))

        // **Not a write.** The text goes to the core, which works out what
        // would be written; `files_commit` is a separate call, made only once
        // the person has chosen on the host's change screen.
        case .propose:
            guard let fullText = argument["fullText"] as? String else {
                return .failure(.refused("propose needs the text"))
            }
            do {
                return .success(try askCore("files_propose", [
                    "token": token,
                    "full_text": fullText,
                    "base_version": argument["baseVersion"] as? String ?? "",
                ]))
            } catch let failure as CoreFailure {
                return .failure(failure)
            } catch {
                return .failure(.refused("the core could not answer"))
            }

        // Whether there are unsaved changes. The host keeps its own copy for
        // its "you have unsaved changes" question; nothing is written.
        case .dirty:
            let dirty = argument["dirty"] as? Bool ?? false
            onDirty?(dirty)
            return .success(["dirty": dirty])
        }
    }
}

// MARK: Serving the ticket's files, and nothing beside them

extension PreviewBridge: WKURLSchemeHandler {
    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated { serve(task) }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Everything is resolved and answered in one go, so there is nothing
        // in flight to cancel.
    }

    /// Serve one request the page made over `polter-file://`.
    ///
    /// **The route says which ticket and which `rel`; the core says whether and
    /// where.** Nothing here builds a path, and there is no branch in which it
    /// could: it hands `(token, rel)` to the core's `files_resolve` and writes
    /// what came back.
    private func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url,
              // `resolve` answers a `Result` rather than throwing, so this
              // unwraps it: `try?` over a non-throwing call would wrap the
              // `Result` itself and leave `route` a `Result` with no `.token`.
              case .success(let route) = PreviewRoutes.resolve(url.absoluteString),
              // A page may only ask about the ticket it was served from: a
              // second token in the URL is another file's capability, and this
              // view was never given it.
              route.token == token
        else {
            Self.logger.warning(
                "preview \(self.token, privacy: .public): a request was refused for its route or its ticket")
            fail(task, status: 403)
            return
        }

        guard let resolved = try? askCore("files_resolve", ["token": token, "rel": route.rel]),
              let path = resolved["path"] as? String,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else {
            fail(task, status: 403)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": PreviewRoutes.contentType(of: path),
                "Content-Length": String(data.count),
                "Content-Security-Policy": policy,

                // The page is one ticket's, served to one web view. Nothing
                // should be reading it from anywhere else.
                "Access-Control-Allow-Origin": "null",

                // A previewed file is somebody's document, and a copy of it
                // left in a cache is a copy nobody asked for.
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            ])

        guard let response else {
            task.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// A refusal, as a status and no body. **Named with its status rather than
    /// answered as an empty file**: a page that asked for something it may not
    /// have should be able to tell "no" from "it is empty", and a 200 with
    /// nothing in it is neither.
    private func fail(_ task: WKURLSchemeTask, status: Int) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
        else {
            task.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        task.didReceive(response)
        task.didFinish()
    }

    /// `files_resolve(token, rel)`: the one call that decides whether a path
    /// may be read and what its real path is.
    ///
    /// **A `Result` and not a `throw`**, so the core's refusal and a bridge
    /// that could not ask at all arrive at the caller the same way -- which is
    /// what the eight calls want, because both are answered to the page as
    /// `.failure` with the core's own sentence in it.
    private func resolve(_ rel: String) -> Result<Any, CoreFailure> {
        do {
            return .success(try askCore("files_resolve", ["token": token, "rel": rel]))
        } catch let failure as CoreFailure {
            return .failure(failure)
        } catch {
            return .failure(.refused("the core could not answer"))
        }
    }

    /// The same call, as the object the callers index into.
    ///
    /// ⚠️ **This exists because `resolve` answers a `Result` and not a thrown
    /// error.** When it was changed to a `Result`, the two call sites that want
    /// the object -- `.read`/`.readRel` and `.openPath` in `ask` -- kept writing
    /// `try resolve(…)` and then used the value as a dictionary, which is a
    /// `Result<Any, CoreFailure>` and has no subscripts. (The third call site,
    /// `.info`'s `return resolve("")`, wants the `Result` itself and was never
    /// wrong.) The full-tree app build (`xcodebuild -target Ghostty`) reported
    /// both, at `PreviewBridge.swift:220:32` and `:241:50`; the Zig-only build
    /// does not compile `macos/` at all, so it was green throughout.
    ///
    /// The one refusal that is this function's own is the shape: a core that
    /// answered with something that is not an object is not a dictionary, and
    /// reading `["path"]` out of it would be inventing one.
    private func resolvedObject(_ rel: String) -> Result<[String: Any], CoreFailure> {
        switch resolve(rel) {
        case .failure(let why):
            return .failure(why)
        case .success(let value):
            guard let object = value as? [String: Any] else {
                return .failure(.refused("the core's answer is not an object"))
            }
            return .success(object)
        }
    }

    /// **The core's answer, through the door a host uses.** `req` is the same
    /// JSON request an agent's socket would carry, so the two cannot disagree
    /// about what a ticket does; the answer is `{"refused":…}` for anything the
    /// core will not do, in the one shape the core refuses in.
    ///
    /// The token is the whole of what makes this safe: it was minted for one
    /// workdir and one scope, and `Tickets.resolve` judges every path against
    /// *that ticket* on every call.
    private func askCore(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let app = delegate.ghostty.app
        else { throw CoreFailure.refused("Polter's core is not running") }

        guard let body = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        else { throw CoreFailure.refused("that request could not be built") }
        let bytes = Array(body)

        // The persona buffer rule: ask for the size, allocate once, ask again.
        let need = bytes.withUnsafeBufferPointer { req in
            Int(ghostty_app_files(app, req.baseAddress, UInt(req.count), nil, 0))
        }
        // **Zero is this door's "that is not one of the five"**, named rather
        // than read as an empty answer: a host that asked for something else
        // should not be handed somebody else's shape.
        guard need > 0 else {
            throw CoreFailure.refused("\(method) is not a request the core answers for a host")
        }

        var buffer = [CChar](repeating: 0, count: need + 1)
        let wrote = bytes.withUnsafeBufferPointer { req in
            buffer.withUnsafeMutableBufferPointer { out in
                Int(ghostty_app_files(app, req.baseAddress, UInt(req.count), out.baseAddress, UInt(out.count)))
            }
        }
        guard wrote > 0, wrote <= need else {
            throw CoreFailure.refused("the core's answer changed size between asking and reading")
        }
        guard let text = String(bytes: buffer.prefix(wrote).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            throw CoreFailure.refused("the core's answer is not JSON")
        }
        if parsed["refused"] != nil {
            throw CoreFailure.refused(parsed["why"] as? String ?? "refused")
        }
        return parsed
    }

    /// A span of a file the core named, clamped to what is really there.
    ///
    /// `truncated` is about the **ask**, not the file: it says whether this
    /// answer was cut at what was asked for, which is the difference between
    /// "that is all of it" and "that is all you were given".
    private func read(_ resolved: [String: Any], offset: Int, length: Int) -> Result<Any, CoreFailure> {
        guard let path = resolved["path"] as? String,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return .failure(.refused("the file could not be read")) }
        defer { try? handle.close() }

        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.read(upToCount: length)) ?? Data()
        return .success([
            "base64": data.base64EncodedString(),
            "size": resolved["size"] ?? 0,
            "truncated": data.count >= length,
        ])
    }
}

/// Why a call did not answer: the core's own words where the core refused, and
/// a sentence of this file's where the core could not be asked at all.
struct CoreFailure: Error {
    let message: String

    static func refused(_ why: String) -> CoreFailure { CoreFailure(message: why) }
}
