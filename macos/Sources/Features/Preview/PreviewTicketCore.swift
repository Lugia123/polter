import AppKit
import GhosttyKit
import Foundation

/// The one place a host asks the core for a capability ticket
/// (`PreviewTicket.Source`, task 2634, #2140 M2).
///
/// **This file names `GhosttyKit`, so it is not in the package
/// `tools/mac-logic-tests` builds** (`sources.out`, the same exclusion
/// `ControlRoomPerfPage.swift` and `PreviewBridge.swift` have): everything
/// `PreviewTicket` decides -- the request, the reading, what a token may
/// be -- is in that file and is tested there. What is left here is the
/// call, and a call is not a rule.
///
/// It is beside `PreviewBridge` rather than inside it because
/// `PreviewBridge` is where a ticket is *spent* and this is where one is
/// *asked for*: the ticket comes from the core and the bridge never mints
/// one, so the two are different halves of the same fence and are kept
/// where each can be read on its own.
extension PreviewTicket.Source {
    /// The core, through `ghostty_app_files`.
    ///
    /// **The same door an agent's socket uses**, asked as a host: `req` is
    /// the JSON text of one request and the answer is the JSON the socket
    /// would have carried, so a host cannot disagree with the tool surface
    /// about what a ticket is. The buffer rule is the persona one -- ask
    /// for the size with no buffer, allocate once, ask again -- and **zero
    /// is this door's "that is not one of the five"**, named rather than
    /// read as an empty answer.
    static func core(_ ghostty: Ghostty.App) -> PreviewTicket.Source {
        PreviewTicket.Source { request in
            guard let app = ghostty.app else { return .failure(.notReady) }
            let bytes = Array(request.utf8CString.dropLast())
            let need = bytes.withUnsafeBufferPointer { req in
                Int(ghostty_app_files(app, req.baseAddress, UInt(req.count), nil, 0))
            }
            guard need > 0 else { return .failure(.notReady) }
            var buffer = [CChar](repeating: 0, count: need + 1)
            let wrote = bytes.withUnsafeBufferPointer { req in
                buffer.withUnsafeMutableBufferPointer { out in
                    Int(ghostty_app_files(app, req.baseAddress, UInt(req.count), out.baseAddress, UInt(out.count)))
                }
            }
            guard wrote > 0, wrote <= need else { return .failure(.unreadable) }
            guard let text = String(bytes: buffer.prefix(wrote).map { UInt8(bitPattern: $0) },
                                    encoding: .utf8)
            else { return .failure(.unreadable) }
            return .success(text)
        }
    }
}
