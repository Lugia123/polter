import SwiftUI

/// The right-hand side's working-directory page (task 2634, #2140 M2/W2).
/// Draws the working directories of the selected group and allows inspecting them.
struct ControlRoomWorkdirsPage: View {
    typealias Look = ControlRoomLook

    let group: String
    @ObservedObject var model: ControlRoomModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Text(String(localized: "Working Directories", comment: "工作目录页标题"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text.color)

                Spacer()

                Button {
                    model.refreshWorkdirs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.color)
                }
                .buttonStyle(.plain)
                .help("刷新工作目录")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.windowBase.color)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: CGFloat(Look.Line.hairline))
            }

            // Body
            if let answer = model.workdirs, !answer.dirs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(answer.dirs, id: \.id) { dir in
                            dirCard(dir, theme: theme)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.terminalBackground.color)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.textSecondary.color.opacity(0.6))
                    Text(String(localized: "暂无工作目录记录", comment: "工作目录空状态"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary.color)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.terminalBackground.color)
            }
        }
        .onAppear {
            model.refreshWorkdirs()
        }
    }

    private func dirCard(_ dir: ControlRoomWorkdirs.Dir, theme: Look.Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary.color)

                Text(dir.short)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text.color)

                Spacer()

                if dir.editing > 0 {
                    Text("\(dir.editing) 改动中")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.paneGreenBadge.color))
                        .foregroundStyle(theme.text.color)
                }
            }

            if !dir.who.isEmpty {
                HStack(spacing: 6) {
                    ForEach(dir.who, id: \.id) { member in
                        Text(member.title)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(theme.perfCardEdge.color))
                    }
                }
            }

            Text(dir.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.textSecondary.color.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.windowBase.color))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.line.color, lineWidth: CGFloat(Look.Line.hairline)))
    }
}
