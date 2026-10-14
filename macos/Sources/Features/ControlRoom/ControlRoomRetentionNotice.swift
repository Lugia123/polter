import SwiftUI

/// The one-time notice at the top of the control room's list that the first
/// sweep of old records is waiting for the person (task 1511): the sentence
/// Settings > General > Log Management says, and OK.
///
/// **Not a row, and not an answer.** A row of the list tells and does not
/// answer for the person (`tools/control-room-rows-only-tell.py`,
/// control-room.md 3.2): nothing on a row approves, refuses or replies to an
/// agent. This is about Polter's own records, sits in the room the list
/// leaves under its header, and is gone once agreed to. It is its own view,
/// rather than one more button in `ControlRoomListView`, so that the list
/// still has exactly the one button that gate counts.
struct ControlRoomRetentionNotice: View {
    typealias Look = ControlRoomLook

    let text: String
    let onAgree: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// The room the OK takes under the sentence.
    static let buttonHeight: CGFloat = 28

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "OK", comment: "日志管理与总控台：同意第一次清理"), action: onAgree)
        }
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
                .fill(theme.windowBase.color))
        .padding(.horizontal, CGFloat(Look.Side.headerPaddingX) - CGFloat(Look.Side.rowPaddingX))
    }
}
