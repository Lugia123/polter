import AppKit
import GhosttyKit

/// The squad templates, as the app sees them: the one place the squads page
/// reads from and the one place that writes.
///
/// Everything is asked of the core -- the file, its validation, whether a
/// member's role is still in the library are all there -- so this type reads
/// nothing from disk. Two readers of `squads.json` would be two sets of rules
/// about what a valid template is, and the core's is the one both hosts use.
@MainActor
final class SquadLibrary: ObservableObject {
    static let shared = SquadLibrary()

    @Published private(set) var catalog = SquadCatalog()

    private var app: ghostty_app_t? {
        (NSApp.delegate as? AppDelegate)?.ghostty.app
    }

    /// Read the whole document again. `loaded` false means the file has not
    /// been looked at yet, which is not the same as "no templates".
    func reload() {
        guard let app else { return }
        if let json = PersonaCatalog.readJSON({ ghostty_app_squad_catalog(app, $0, $1) }),
           let parsed = SquadCatalog(json: json) {
            catalog = parsed
        }
    }

    /// One call that answers true, or false with an error's *name*. Nil on
    /// success, otherwise that name -- the caller turns it into words. The
    /// same helper `RoleLibrary` uses, so the two write paths answer alike.
    private func ask(_ body: (ghostty_app_t, UnsafeMutablePointer<CChar>?, UInt) -> Bool) -> String? {
        guard let app else { return "NoApp" }
        var err = [CChar](repeating: 0, count: 128)
        let ok = err.withUnsafeMutableBufferPointer { body(app, $0.baseAddress, UInt($0.count)) }
        reload()
        return ok ? nil : String(cString: err)
    }

    /// Save a template. Nil on success, otherwise a sentence for the person.
    ///
    /// The core is the one that decides: it re-reads the squad through its
    /// own reader (`BadSquad`) and refuses a supervisor's write that the
    /// person's should not be replaced by (`NotPermitted`).
    func put(_ squad: Squad) -> String? {
        guard let app else { return Self.message(for: "NoApp") }
        guard let data = squad.jsonData else { return Self.message(for: "BadSquad") }
        var err = [CChar](repeating: 0, count: 128)
        let ok = data.withUnsafeBytes { raw -> Bool in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return err.withUnsafeMutableBufferPointer {
                ghostty_app_squad_put(app, ptr, UInt(data.count), $0.baseAddress, UInt($0.count))
            }
        }
        reload()
        return ok ? nil : Self.message(for: String(cString: err))
    }

    func delete(_ key: String) -> String? {
        guard let app else { return Self.message(for: "NoApp") }
        var err = [CChar](repeating: 0, count: 128)
        let ok = key.withCString { cKey in
            err.withUnsafeMutableBufferPointer {
                ghostty_app_squad_delete(app, cKey, UInt(strlen(cKey)), $0.baseAddress, UInt($0.count))
            }
        }
        reload()
        return ok ? nil : Self.message(for: String(cString: err))
    }

    /// The core's error names, in words. An unknown name is shown as it is
    /// rather than swallowed: it is the only clue there is
    /// (`SquadStore.WriteError`).
    static func message(for code: String) -> String {
        switch code {
        case "FileUnreadable":
            return String(localized: "The squad templates file has an error in it, so saving would overwrite it. Fix the file first.", comment: "小队模版：squads.json 当前解析失败，拒绝写入以免覆盖用户手写的内容")
        case "BadSquad":
            return String(localized: "This squad can't be saved: it needs a name and a key, and every member needs an alias and a role.", comment: "小队模版：保存被核心拒绝，小队本身不合格")
        case "NoSuchSquad":
            return String(localized: "That squad is no longer there.", comment: "小队模版：要删的小队已经不在了")
        case "NotPermitted":
            return String(localized: "Only the person may change their own squads, and only you may make one that says it is yours.", comment: "小队模版：总管试图改/删用户的小队，或做了一个自称是用户的小队")
        case "ReasonRequired":
            return String(localized: "A squad made by a supervisor needs a reason, at least 20 characters saying why it is needed.", comment: "小队模版：总管建队必须写明理由，短于 20 字核心会拒")
        case "TooManySupervisorSquads":
            return String(localized: "There are already as many supervisor squads as are allowed.", comment: "小队模版：总管建的小队数已达上限 squad.max_supervisor_squads")
        case "SupervisorNotAllowed":
            return String(localized: "A supervisor can't be a member of a squad: whoever opens the task would be supervised by one of its own seats.", comment: "小队模版：成员里放了总管角色，核心拒绝（v3 第 12 条）")
        case "WriteNotLoaded":
            return String(localized: "The squad was written but didn't read back. This is a bug in Polter.", comment: "小队模版：写入后读回失败，属于程序缺陷")
        case "CouldNotWrite":
            return String(localized: "The squad templates file couldn't be written.", comment: "小队模版：写文件失败")
        case "NoApp":
            return String(localized: "Polter isn't ready yet.", comment: "角色库：app 还没初始化（与 RoleLibrary 同一句，故复用同一文案）")
        default:
            return code
        }
    }
}
