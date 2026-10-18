import AppKit
import GhosttyKit

/// The role library, as the app sees it: the one place the window and the
/// launch menus read from, and the one place that writes.
///
/// Everything is asked of the core -- the file, its validation, and the
/// CLI inventory are all there -- so this type reads nothing from disk and
/// runs nothing. Two readers of `personas.json` would be two sets of rules
/// about what a valid role is.
@MainActor
final class RoleLibrary: ObservableObject {
    static let shared = RoleLibrary()

    @Published private(set) var catalog = RoleCatalog()
    @Published private(set) var clis = AgentCliSnapshot()
    @Published private(set) var skills = OfficialSkillCatalog()

    private var pollTimer: Timer?
    private var pollDeadline = Date.distantPast

    private var app: ghostty_app_t? {
        (NSApp.delegate as? AppDelegate)?.ghostty.app
    }

    func reload() {
        guard let app else { return }
        if let json = PersonaCatalog.readJSON({ ghostty_app_persona_catalog(app, $0, $1) }),
           let parsed = RoleCatalog(json: json) {
            catalog = parsed
        }
        if let json = PersonaCatalog.readJSON({ ghostty_app_official_skills(app, $0, $1) }),
           let parsed = OfficialSkillCatalog(json: json) {
            skills = parsed
        }
        reloadClis(refresh: false)
    }

    /// One call that answers true, or false with an error's name. Nil on
    /// success, otherwise that name -- the caller turns it into words, or
    /// acts on it.
    private func ask(_ body: (ghostty_app_t, UnsafeMutablePointer<CChar>?, UInt) -> Bool) -> String? {
        guard let app else { return "NoApp" }
        var err = [CChar](repeating: 0, count: 128)
        let ok = err.withUnsafeMutableBufferPointer { body(app, $0.baseAddress, UInt($0.count)) }
        reload()
        return ok ? nil : String(cString: err)
    }

    /// Put an official role back to the shipped one. The error's name, not
    /// a sentence: `OverridesUnreadable` is a question to ask the person.
    func restore(_ key: String, everything: Bool) -> String? {
        ask { app, err, cap in
            key.withCString { ghostty_app_persona_restore(app, $0, UInt(strlen($0)), everything, err, cap) }
        }
    }

    /// "Keep mine", for a role the shipped version has moved under.
    func acknowledge(_ key: String) -> String? {
        ask { app, err, cap in
            key.withCString { ghostty_app_persona_acknowledge(app, $0, UInt(strlen($0)), err, cap) }
        }.map(Self.message(for:))
    }

    /// Keep a role the file holds under an official key as one's own.
    func adopt(_ key: String) -> String? {
        ask { app, err, cap in
            key.withCString { ghostty_app_persona_adopt(app, $0, UInt(strlen($0)), err, cap) }
        }.map(Self.message(for:))
    }

    func putSkill(_ name: String, text: String) -> String? {
        ask { app, err, cap in
            name.withCString { cName in
                text.withCString { cText in
                    ghostty_app_official_skill_put(app, cName, UInt(strlen(cName)), cText, UInt(strlen(cText)), err, cap)
                }
            }
        }.map(Self.message(for:))
    }

    /// "Keep mine", for a skill the shipped text has moved under.
    func acknowledgeSkill(_ name: String) -> String? {
        ask { app, err, cap in
            name.withCString { ghostty_app_official_skill_acknowledge(app, $0, UInt(strlen($0)), err, cap) }
        }.map(Self.message(for:))
    }

    func restoreSkill(_ name: String) -> String? {
        ask { app, err, cap in
            name.withCString { ghostty_app_official_skill_restore(app, $0, UInt(strlen($0)), err, cap) }
        }.map(Self.message(for:))
    }

    /// Read the CLI cache, and keep reading it while the core says a newer
    /// answer is coming. The core never blocks on the adapters, so this is
    /// how the window learns the read finished.
    func reloadClis(refresh: Bool) {
        guard let app else { return }
        if let json = PersonaCatalog.readJSON({ ghostty_app_agent_clis(app, refresh, $0, $1) }),
           let parsed = AgentCliSnapshot(json: json) {
            clis = parsed
        }
        if clis.refreshing || clis.stale {
            if refresh || pollTimer == nil { pollDeadline = Date().addingTimeInterval(30) }
            schedulePoll()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func schedulePoll() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date() > self.pollDeadline {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    return
                }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.reloadClis(refresh: false)
            }
        }
    }

    /// Save a role. Nil on success, otherwise a sentence for the person.
    func put(_ role: Role) -> String? {
        guard let app else { return Self.message(for: "NoApp") }
        guard let data = role.jsonData else { return Self.message(for: "BadPersona") }
        var err = [CChar](repeating: 0, count: 128)
        let ok = data.withUnsafeBytes { raw -> Bool in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return err.withUnsafeMutableBufferPointer {
                ghostty_app_persona_put(app, ptr, UInt(data.count), $0.baseAddress, UInt($0.count))
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
                ghostty_app_persona_delete(app, cKey, UInt(strlen(cKey)), $0.baseAddress, UInt($0.count))
            }
        }
        reload()
        return ok ? nil : Self.message(for: String(cString: err))
    }

    /// Open a tab beside `surface` and start `cli` in it wearing `key`.
    /// Nil on success, otherwise a sentence for the person.
    static func launch(from surface: ghostty_surface_t, key: String, cli: String) -> String? {
        var err = [CChar](repeating: 0, count: 128)
        let ok = key.withCString { cKey in
            cli.withCString { cCli in
                err.withUnsafeMutableBufferPointer {
                    ghostty_surface_persona_launch(
                        surface, cKey, UInt(strlen(cKey)), cCli, UInt(strlen(cCli)),
                        $0.baseAddress, UInt($0.count))
                }
            }
        }
        return ok ? nil : message(for: String(cString: err))
    }

    /// The core's error names, in words. An unknown name is shown as it is
    /// rather than swallowed: it is the only clue there is.
    static func message(for code: String) -> String {
        switch code {
        case "BadPersona":
            return String(localized: "This role can't be saved: it needs a name, and a key of lowercase letters, digits and dashes.", comment: "角色库：保存被核心拒绝，角色本身不合格")
        case "FileUnreadable":
            return String(localized: "The role library file has an error in it, so saving would overwrite it. Fix the file first.", comment: "角色库：personas.json 当前解析失败，拒绝写入以免覆盖用户手写的内容")
        case "NoSuchPersona":
            return String(localized: "That role no longer exists.", comment: "角色库：要删/要启动的角色已经不在了")
        case "WriteNotLoaded":
            return String(localized: "The role was written but didn't read back. This is a bug in Polter.", comment: "角色库：写入后读回失败，属于程序缺陷")
        case "CouldNotWrite":
            return String(localized: "The role library file couldn't be written.", comment: "角色库：写文件失败")
        case "NotSetUpForCli":
            return String(localized: "This role isn't set up for that agent CLI.", comment: "用角色启动：角色没有为这个 CLI 配置")
        case "CliOff":
            return String(localized: "That agent CLI's plugin is off. Turn it on in Plugins.",
                          comment: "启动失败：这个 CLI 的插件装着但关着，去插件设置里打开就行")
        case "CliUnavailable":
            return String(localized: "That agent CLI can't be started on this machine.",
                          comment: "启动失败：这台机器上起不了这个 CLI（没有插件管理它，或插件的 adapter 在这里跑不起来），打开插件也没用")
        case "CliNotInstalled":
            return String(localized: "That agent CLI isn't installed on this machine.",
                          comment: "启动失败：这个 CLI 的插件开着，但它的程序没装在这台机器上（登录 shell 的 PATH 里找不到），要先装上")
        case "NoCli":
            return String(localized: "This role isn't set up for any agent CLI yet. Pick one in the role library.", comment: "用角色启动：角色还没选任何 CLI")
        case "ChooseCli":
            return String(localized: "This role is set up for more than one agent CLI. Choose one.", comment: "用角色启动：角色配了多个 CLI，要指定一个")
        case "NotYetOpen":
            return String(localized: "A tab was opened but didn't appear in time, so nothing was started in it.", comment: "用角色启动：新标签页没及时出现，没有往里启动任何东西")
        case "LockedName", "LockedDescription", "LockedStanding", "LockedField":
            return String(localized: "An official role's name, description and what it grants can't be changed. Duplicate it to make one of your own.", comment: "角色库：保存官方角色时动了不许改的字段")
        case "OverridesUnreadable":
            return String(localized: "The file that holds your changes to official roles can't be read, so nothing was saved into it. Restore Factory Settings sets it aside.", comment: "角色库：官方角色的改动文件读不了，拒绝写入")
        case "BadSkill":
            return String(localized: "This doesn't read as the skill: it needs its opening lines, with its own name in them.", comment: "角色库：官方 skill 的正文保存被拒")
        case "NoSuchSkill", "NoConfigDir":
            return String(localized: "This skill couldn't be saved.", comment: "角色库：官方 skill 保存失败")
        case "NoApp":
            return String(localized: "Polter isn't ready yet.", comment: "角色库：app 还没初始化")
        default:
            return code
        }
    }
}
