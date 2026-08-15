import SwiftUI
import GhosttyKit

/// What the terminals have said to each other.
///
/// An observation window: it shows the groups the supervisor has set up and
/// what was said in them, and lets the person at the keyboard join in. It
/// deliberately offers nothing else — no starting or stopping supervision,
/// no changing a work mode, no typing into a terminal. Those belong to the
/// people and processes that already own them.
///
/// See `docs/poltergeist/chatui.md`.
struct PoltergeistChatView: View {
    let ghostty: ghostty_app_t

    @State private var groups: [ChatGroup] = []
    @State private var selected: String?
    @State private var draft: String = ""

    /// Polled rather than pushed. The window is something a person opens
    /// now and then, and a push channel across the C boundary would be a
    /// lot of machinery for a view that can simply ask again.
    private let refresh = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        NavigationSplitView {
            List(groups, selection: $selected) { group in
                HStack {
                    Text(group.name)
                    Spacer()
                    if group.lines.isEmpty {
                        Text("empty")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .tag(group.name)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            if let group = current {
                messages(for: group)
            } else {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        "Groups appear here once a supervisor creates one."
                    )
                )
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private var current: ChatGroup? {
        guard let selected else { return groups.first }
        return groups.first { $0.name == selected } ?? groups.first
    }

    @ViewBuilder
    private func messages(for group: ChatGroup) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(group.lines) { line in
                            MessageRow(line: line).id(line.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: group.lines.count) {
                    guard let last = group.lines.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                TextField("Say something", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { send(to: group.name) }

                Button("Send") { send(to: group.name) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .navigationTitle(group.name)
    }

    private func send(to group: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let ok = group.withCString { g in
            text.withCString { t in
                ghostty_app_chat_post(ghostty, g, t)
            }
        }

        // Clearing only on success: silently swallowing what somebody typed
        // would be worse than leaving it there to try again.
        if ok {
            draft = ""
            reload()
        }
    }

    private func reload() {
        var snapshot = ghostty_chat_snapshot_s()
        guard ghostty_app_chat(ghostty, &snapshot) else { return }
        defer { ghostty_app_free_chat(&snapshot) }

        var built: [ChatGroup] = []
        for gi in 0..<snapshot.groups_len {
            let g = snapshot.groups[gi]

            var lines: [ChatLine] = []
            for li in 0..<g.lines_len {
                let l = g.lines[li]
                lines.append(
                    ChatLine(
                        seq: l.seq,
                        from: l.from,
                        atMs: l.at_ms,
                        isSummary: l.summary,
                        text: String(cString: l.text)
                    )
                )
            }

            built.append(ChatGroup(name: String(cString: g.name), lines: lines))
        }

        groups = built
        if selected == nil { selected = built.first?.name }
    }
}

private struct MessageRow: View {
    let line: ChatLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.author)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(line.isFromUser ? Color.accentColor : .secondary)

                if line.isSummary {
                    // Marked, because a summary is the supervisor's account
                    // of a conversation rather than anything that was said.
                    Text("summary")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

            Text(line.text)
                .textSelection(.enabled)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatGroup: Identifiable, Hashable {
    let name: String
    let lines: [ChatLine]

    var id: String { name }
}

struct ChatLine: Identifiable, Hashable {
    let seq: UInt64
    let from: UInt64
    let atMs: UInt64
    let isSummary: Bool
    let text: String

    var id: UInt64 { seq }

    /// Zero is the person at the keyboard; `Surface.id` is never zero.
    var isFromUser: Bool { from == 0 }

    var author: String {
        isFromUser ? "you" : String(format: "0x%016llx", from)
    }
}
