import AppKit
import SwiftUI

/// The line under a card that reads "Failed" (task 1560): "Fix", which has
/// the core tell the card's supervisor who failed and leaves what to do
/// about it to that supervisor; greyed as "Supervisor notified" once
/// pressed, until the card changes; and, when the last press was refused,
/// why, beside it.
///
/// **It answers nothing for the person.** A row does not approve, refuse
/// or reply to an agent (`tools/control-room-rows-only-tell.py`), and this
/// does none of the three: it types into the supervisor, which decides.
/// Its own view, as `ControlRoomRetentionNotice` is, so that the list
/// still has exactly the one button that gate counts.
struct ControlRoomFixLine: View {
    typealias Look = ControlRoomLook

    let fix: ControlRoomList.Fix
    /// Why the last press was not done; nil when it was, or was not made.
    let refusal: String?
    let onFix: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// The menu's font: nothing in Polter's own windows is set smaller.
    private static var font: Font { SafeFace.menu.swiftUI }

    static func title(_ fix: ControlRoomList.Fix) -> String {
        switch fix {
        case .sent:
            return String(localized: "Supervisor notified",
                          comment: "总控台：出错卡片上点过「修复」之后，按钮变灰显示的字")
        case .offered, .none:
            return String(localized: "Fix",
                          comment: "总控台：出错卡片上的按钮，通知总管处理")
        }
    }

    var body: some View {
        HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            Button(Self.title(fix), action: onFix)
                .disabled(fix != .offered)
                .fixedSize()
            if let refusal, fix == .offered {
                Text(refusal)
                    .foregroundStyle(Look.theme(scheme).textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(refusal)
            }
        }
        .font(Self.font)
        .frame(height: CGFloat(Look.Side.fixLineHeight), alignment: .leading)
    }
}
