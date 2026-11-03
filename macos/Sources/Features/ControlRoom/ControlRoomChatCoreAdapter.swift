import Foundation
import GhosttyKit

/// The chat page's door onto the core (task 2791, #2791): the one place in
/// this slice that names `GhosttyKit`, kept apart from everything it feeds
/// for the same reason `ControlRoomPerfPage.swift` is apart from
/// `ControlRoomResources.swift` -- the rules and the reading are tested
/// without an app, and only the call needs one.
///
/// **The door is in the tree**: `ghostty_app_chat_read` is declared in
/// `include/ghostty.h` and exported from `src/apprt/embedded.zig` (task
/// 2778, landed as `0db7ea854`), with the signature this file calls it by:
///
///     uintptr_t ghostty_app_chat_read(ghostty_app_t, const char*, uintptr_t, char*, uintptr_t);
///
/// ⚠️ **What is not yet true is that this file has been compiled.** The app
/// links a generated `macos/GhosttyKit.xcframework`, and the copy on this
/// machine is older than the declaration; until the next mainline app build
/// regenerates it the name has no prototype on the Swift side. That is a
/// build-order fact and not a doubt about the interface -- and it is written
/// here so that "unbuilt" is not read later as "the door was never there".
///
/// The buffer rule is the one the header states: asked with a nil buffer it
/// answers how many bytes the reply needs, and **a second call with the same
/// request gives the same answer, which is what makes asking the size first
/// safe here** -- a read changes nothing. `group_read` is the only method
/// this door accepts; anything else comes back as `{"error":"NotARead"}`,
/// which is a refusal and not an empty chat.
enum ControlRoomChatCoreAdapter {
    static func ask(_ ghostty: Ghostty.App) -> ControlRoomChatFeed.Ask {
        { [weak ghostty] request in
            guard let app = ghostty?.app else { return .notReady }
            let bytes = Array(request.utf8CString.dropLast())
            let need = bytes.withUnsafeBufferPointer { req in
                Int(ghostty_app_chat_read(app, req.baseAddress, UInt(req.count), nil, 0))
            }
            guard need > 0 else { return .notReady }
            var buffer = [CChar](repeating: 0, count: need + 1)
            let wrote = bytes.withUnsafeBufferPointer { req in
                buffer.withUnsafeMutableBufferPointer { out in
                    Int(ghostty_app_chat_read(app, req.baseAddress, UInt(req.count), out.baseAddress, UInt(out.count)))
                }
            }
            guard wrote > 0, wrote <= need else {
                return .refused("the answer changed size between asking and reading")
            }
            guard let text = String(bytes: buffer.prefix(wrote).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                return .refused("the answer is not UTF-8")
            }
            return .answer(text)
        }
    }

    /// The same door's **post** (task 2791, slice 3 of #2778).
    ///
    /// ⚠️ **Called once and never probed.** A post writes to the group and
    /// types into terminals, so there is no "how long is the answer" call
    /// here: the answer is handed out owned and released with
    /// `ghostty_app_chat_free`, which is why the pair `out`/`outLen` is
    /// declared together and freed in one `defer` -- a `defer` that read one
    /// of the two before the other was filled would be a pointer with no
    /// length or the reverse.
    ///
    /// **The three outcomes are the core's three and are kept apart.** Only
    /// `CONFIRMED` means it went; `REFUSED` means nothing was written and is
    /// the only one that may be sent again; `UNKNOWN` means the door cannot
    /// say, and the caller must not send it again on its own.
    ///
    /// ⚠️ **Not compiled yet.** This file imports `GhosttyKit`, and the
    /// generated `macos/GhosttyKit.xcframework` on this machine is older than
    /// `include/ghostty.h` (declarations at 1829/1867/1870, from `0db7ea854`),
    /// so neither name has a Swift-side prototype until the next app build.
    static func send(_ ghostty: Ghostty.App) -> ControlRoomChatFeed.Send {
        { [weak ghostty] request in
            guard let app = ghostty?.app else { return .refused("NoCore") }
            let bytes = Array(request.utf8CString.dropLast())
            var out: UnsafeMutablePointer<CChar>?
            var outLen: UInt = 0
            var err = [CChar](repeating: 0, count: 256)
            let result = bytes.withUnsafeBufferPointer { req in
                ghostty_app_chat_send(app, req.baseAddress, UInt(req.count),
                                      &out, &outLen, &err, UInt(err.count))
            }
            // **Both, or neither.** `out` is the pointer half and `outLen`
            // its length; the core refuses a call that passes one without
            // the other, and this never does.
            defer { ghostty_app_chat_free(app, out, outLen) }
            // The answer is not NUL-terminated -- it is a pointer and a
            // length -- so it is read by length and not with `String(cString:)`.
            let answer: String? = out.map { p in
                String(decoding: UnsafeBufferPointer(start: p, count: Int(outLen)).map { UInt8(bitPattern: $0) },
                       as: UTF8.self)
            }
            let said = err[0] == 0 ? nil : String(cString: err)
            if result == GHOSTTY_CHAT_SEND_CONFIRMED { return .confirmed(answer) }
            let why = said ?? answer ?? ""
            if result == GHOSTTY_CHAT_SEND_REFUSED { return .refused(why) }
            return .unknown(why)
        }
    }
}
