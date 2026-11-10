import Foundation
import GhosttyKit

/// The chat page's door onto the core (task 2791, #2791; transport, task
/// 2800, contract §2): the one place in this slice that names `GhosttyKit`,
/// kept apart from everything it feeds for the same reason
/// `ControlRoomPerfPage.swift` is apart from `ControlRoomResources.swift` --
/// the rules and the reading are tested without an app, and only the call
/// needs one.
///
/// **The door is in the tree**: `ghostty_app_chat_read` is declared in
/// `include/ghostty.h` and exported from `src/apprt/embedded.zig` (task
/// 2778), with the signature this file calls it by:
///
///     uintptr_t ghostty_app_chat_read(ghostty_app_t, const char*, uintptr_t, char*, uintptr_t);
///
/// **One call at the core's page budget, and a second only when the reply is
/// a live page larger than it.** The C function follows `copyJsonOut`: it
/// returns the length the reply needs, writes the body only when that length
/// plus a NUL fits, and reports the need either way. The first buffer is
/// 96 KiB + 1 -- exactly the core's own budget, and the smallest capacity
/// that keeps its restricted branch from turning search/metadata/around into
/// `BadParams`. Only the live `group_read` can exceed that budget, and then
/// the buffer is grown and the same request asked again (up to a 4 MiB cap).
/// `ControlRoomChatTransport` owns that rule and is the function this
/// adapter calls; it is the same function the logic tests drive with an
/// injected call.
///
/// The methods are `group_read` and the three bounded history calls
/// (`chat_history_begin`, `chat_history_poll`, `chat_history_cancel`);
/// anything else is refused by name with `{"error":"NotARead"}`, which is a
/// refusal and not an empty chat.
enum ControlRoomChatCoreAdapter {
    static func ask(_ ghostty: Ghostty.App) -> ControlRoomChatFeed.Ask {
        { [weak ghostty] request in
            guard let app = ghostty?.app else { return .notReady }
            let outcome = ControlRoomChatTransport.read(request) { bytes, out in
                Int(ghostty_app_chat_read(
                    app,
                    bytes.baseAddress,
                    UInt(bytes.count),
                    out.baseAddress,
                    UInt(out.count)
                ))
            }
            switch outcome {
            case let .answer(text): return .answer(text)
            case .notReady: return .notReady
            case let .refused(why): return .refused(why)
            }
        }
    }
}
