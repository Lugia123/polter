import AppKit
import SwiftUI
import GhosttyKit

/// Settings > General > Log Management (task 1511): how much each kind of
/// record takes, how long it is kept -- the two retention settings edited
/// in its row -- and "Clear…". The figures and the clearing are the core's
/// (`ghostty_app_storage_usage`, `ghostty_app_storage_clear`); the
/// settings are written through the same form call as every other group.
@MainActor
final class LogManagementModel: ObservableObject {
    @Published private(set) var usage: StorageUsage?
    /// The core could not say: there is no state directory yet.
    @Published private(set) var unavailable = false

    /// How often the page reads the figures again while it is shown.
    static let refreshSeconds: TimeInterval = 10

    func reload(_ ghostty: Ghostty.App?) {
        guard let app = ghostty?.app,
              let json = PersonaCatalog.readJSON({ ghostty_app_storage_usage(app, $0, $1) }),
              let usage = StorageUsage.parse(json)
        else {
            unavailable = true
            return
        }
        unavailable = false
        self.usage = usage
    }

    /// Ask, then clear. Returns the status line to show, or nil when the
    /// person said no.
    func clear(_ kind: StorageUsage.Kind, ghostty: Ghostty.App?) -> String? {
        guard let app = ghostty?.app else { return nil }
        // Measured now, as the question is asked: the figure on the row may
        // be minutes old, and the confirmation is what the person agrees to.
        reload(ghostty)
        guard let kind = LogManagementRules.current(kind, in: usage) else { return nil }
        let c = LogManagementRules.confirmation(kind)
        let alert = LogManagementAlert.make(c, cancel: String(localized: "Cancel", comment: "日志管理：确认框的取消按钮"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Done once: the call is not asked for its size first.
        var buf = [CChar](repeating: 0, count: 512)
        let n = kind.key.withCString { k in
            buf.withUnsafeMutableBufferPointer { b in
                ghostty_app_storage_clear(app, k, UInt(strlen(k)), b.baseAddress, UInt(b.count))
            }
        }
        let json = String(bytes: buf.prefix(Int(min(n, UInt(buf.count)))).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        reload(ghostty)
        struct Answer: Decodable { var ok: Bool; var files: Int?; var bytes: UInt64?; var error: String? }
        guard let a = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)), a.ok else {
            if json.contains("ProjectUnreadable") {
                return String(localized: "A project file could not be read, so no shell history was cleared: it might have named some of it.", comment: "日志管理：清 Shell 历史时有项目文件读不了")
            }
            return String(localized: "Nothing was cleared: Polter's core refused.", comment: "日志管理：清理失败")
        }
        return String(format: String(localized: "Cleared %@.", comment: "日志管理：清理之后底栏的提示，%@ 是大小"), LogManagementRules.size(a.bytes ?? 0))
    }

    /// The person said OK to the first sweep.
    func agree(_ ghostty: Ghostty.App?) {
        guard let ghostty else { return }
        try? ControlRoomActions.core(ghostty).perform(.retentionAgree)
        // The sweep runs on its own thread; what it left is read next time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reload(ghostty) }
    }

    func revealStateDirectory() {
        guard let dir = usage?.stateDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir, isDirectory: true)])
    }
}

/// The page, drawn as `log-management-v2` drew it.
struct LogManagementPage: View {
    @ObservedObject var model: GeneralModel
    @ObservedObject var logs: LogManagementModel

    private typealias Grid = SettingsLayout

    /// Kept, not made in `body`: a publisher made there would start over
    /// each time the page is drawn again, and every reading draws it again.
    private let tick = Timer.publish(every: LogManagementModel.refreshSeconds, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if let waiting = logs.usage?.waitingBytes {
                notice(waiting)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: Grid.rule)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Grid.groupGap) {
                    if let usage = logs.usage {
                        Text(String(format: String(localized: "%1$@ in all, in %2$@. Past the limits, cleared when Polter starts and every hour after.", comment: "日志管理：页首一句，%1$@ 是总大小，%2$@ 是目录"),
                                    LogManagementRules.size(usage.totalBytes), (usage.stateDir as NSString).abbreviatingWithTildeInPath))
                            .font(SettingsFont.minimum)
                            .foregroundStyle(.secondary)
                        let sections = LogManagementRules.sections(usage)
                        group(String(localized: "Kept Going Round", comment: "日志管理：分组标题，循环保存"),
                              String(localized: "Past the days or the total, the oldest go first", comment: "日志管理：循环保存的说明"),
                              sections.cycle)
                        group(String(localized: "Kept for Good", comment: "日志管理：分组标题，永久保存"),
                              String(localized: "Deleted only when you choose Clear", comment: "日志管理：永久保存的说明"),
                              sections.forever)
                    } else if logs.unavailable {
                        Text(String(localized: "Polter has no records to show yet.", comment: "日志管理：还拿不到占用"))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Grid.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if model.form == nil { model.reloadForm() }
            logs.reload(model.ghostty)
        }
        // What the page shows changes behind it -- the control room's "OK",
        // files written while it is open (the tenth run, D4) -- so while it
        // is shown it reads the figures again. A field being typed in keeps
        // its text: it follows the form's value only when not focused.
        .onReceive(tick) { _ in
            logs.reload(model.ghostty)
        }
    }

    private func notice(_ bytes: UInt64) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(LogManagementRules.noticeTitle(bytes)).fontWeight(.medium)
                Text(LogManagementRules.noticeDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(String(localized: "OK", comment: "日志管理与总控台：同意第一次清理")) {
                logs.agree(model.ghostty)
            }
            .keyboardShortcut(.defaultAction)
        }
        .font(SettingsFont.minimum)
        .padding(.horizontal, Grid.pad)
        .padding(.vertical, Grid.rowGap + 4)
        .background(Color.orange.opacity(0.10))
    }

    private func group(_ title: String, _ note: String, _ kinds: [StorageUsage.Kind]) -> some View {
        VStack(alignment: .leading, spacing: Grid.rowGap) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold)
                Text(note).foregroundStyle(.secondary)
            }
            .font(SettingsFont.minimum)
            ForEach(kinds) { kind in
                LogManagementRow(model: model, logs: logs, kind: kind)
            }
        }
    }
}

/// The columns, right to left from the content's right edge
/// (`log-management-v3/README.md`: the tenth run found the English page's
/// "days" broken in two at a unit of 28, and "Compact…" has no room in 80).
enum LogManagementColumns {
    static let button: CGFloat = 96
    static let size: CGFloat = 72
    static let days: CGFloat = 44
    static let mb: CGFloat = 56
    static let unit: CGFloat = 36
    static let gap: CGFloat = 8
    /// The least a row is; one whose description wraps grows.
    static let rowHeight: CGFloat = 40
    /// A description wraps rather than being cut off -- the English ones
    /// run past their column -- but to no more than this.
    static let detailLines = 2
    /// Both fields and their units, which a row with no fields fills with
    /// one sentence instead.
    static var rule: CGFloat { days + unit + gap + mb + unit + gap }
}

private struct LogManagementRow: View {
    @ObservedObject var model: GeneralModel
    @ObservedObject var logs: LogManagementModel
    let kind: StorageUsage.Kind

    private typealias Columns = LogManagementColumns

    var body: some View {
        HStack(alignment: .center, spacing: Columns.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LogManagementRules.title(kind.key)).fontWeight(.medium)
                Text(LogManagementRules.detail(kind.key))
                    .foregroundStyle(.secondary)
                    .lineLimit(Columns.detailLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rule
            Text(LogManagementRules.size(kind.bytes))
                .monospacedDigit()
                .frame(width: Columns.size, alignment: .trailing)
            Button(LogManagementRules.action(kind)) {
                if let said = logs.clear(kind, ghostty: model.ghostty) { model.status = said }
            }
            .frame(width: Columns.button, alignment: .trailing)
        }
        .font(SettingsFont.minimum)
        .frame(minHeight: Columns.rowHeight)
    }

    @ViewBuilder
    private var rule: some View {
        switch kind.kept {
        case "fixed":
            Text(String(format: String(localized: "Fixed at %lld days", comment: "日志管理：改名备份那一行，固定天数"), Int64(kind.fixedDays ?? 0)))
                .foregroundStyle(.secondary)
                .frame(width: Columns.rule, alignment: .leading)
        case "forever":
            Text(String(localized: "Kept for good", comment: "日志管理：永久保存那几行的规则一栏"))
                .foregroundStyle(.secondary)
                .frame(width: Columns.rule, alignment: .leading)
        default:
            HStack(spacing: Columns.gap) {
                if let key = kind.daysKey {
                    HStack(spacing: 4) {
                        RetentionField(model: model, logs: logs, key: key, width: Columns.days)
                        Text(String(localized: "days", comment: "日志管理：保留天数的单位")).foregroundStyle(.secondary)
                            .frame(width: Columns.unit - 4, alignment: .leading)
                    }
                } else {
                    Text(String(localized: "Not by days", comment: "日志管理：群里的终端记录只按总量，不按天数"))
                        .foregroundStyle(.secondary)
                        .frame(width: Columns.days + Columns.unit, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    if let key = kind.mbKey {
                        RetentionField(model: model, logs: logs, key: key, width: Columns.mb)
                    }
                    Text(verbatim: "MB").foregroundStyle(.secondary)
                        .frame(width: Columns.unit - 4, alignment: .leading)
                }
            }
        }
    }
}

/// One retention setting, in its row. Written on Return or when it loses
/// focus, through the form's own call; a value that is not a whole number
/// or "no limit" is refused there and put back.
private struct RetentionField: View {
    @ObservedObject var model: GeneralModel
    @ObservedObject var logs: LogManagementModel
    let key: String
    let width: CGFloat

    @State private var text = ""
    @FocusState private var focused: Bool

    private var item: ConfigForm.Item? { model.form?.items.first { $0.key == key } }

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .focused($focused)
            .disabled(!model.writesAllowed)
            .onAppear { text = LogManagementRules.fieldText(item?.value ?? "") }
            .onChange(of: item?.value) { value in
                if !focused { text = LogManagementRules.fieldText(value ?? "") }
            }
            .onChange(of: focused) { if !$0 { commit() } }
            .onSubmit { commit() }
            .help(model.fieldErrors[key] ?? "")
    }

    private func commit() {
        let current = item?.value ?? ""
        guard let value = LogManagementRules.valueToWrite(text) else {
            text = LogManagementRules.fieldText(current)
            model.status = String(localized: "Write a whole number, or leave it empty for no limit.", comment: "日志管理：保留设置填的不是整数")
            return
        }
        guard value != current else { return }
        model.set(key, value)
        logs.reload(model.ghostty)
    }
}
