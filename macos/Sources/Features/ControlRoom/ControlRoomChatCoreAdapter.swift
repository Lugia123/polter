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
}
