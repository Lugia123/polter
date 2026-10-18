import AppKit

/// Which of a role's agent CLIs its row in the `Role ▸` menu offers (#1670).
///
/// A role can be set up for several CLIs -- the official ones list Claude
/// Code and Codex -- but a CLI is only startable here when the core found an
/// adapter for it: its plugin is switched on and its adapter can run on this
/// machine. That set is `ghostty_app_agent_clis`'s `clis`, read by
/// `agent_cli.discover`, the same walk the core makes when it picks a CLI
/// for a role started without one (#1667, `Persona.defaultCli`); the core
/// reads it again when a plugin is switched on or off (`App.reloadPlugins`).
/// Offering a CLI outside it is a row that says "Codex" and answers "no
/// adapter" when clicked.
///
/// The Windows host makes the same decision in
/// `polter_settings_shell::role_cli::CliOffer`, with the same cases.
enum RoleCliOffer: Hashable {
    /// One row carrying the role key alone: the core decides what it means
    /// -- wear the role if an agent is here, otherwise start its CLI, or
    /// refuse and say why.
    case role
    /// One row that starts this CLI. Carries `key,cli`: of several set up,
    /// only this one is here, and the core is told so rather than left to
    /// work it out again.
    case only(String)
    /// A submenu, one row per CLI, in the role's order.
    case choose([String])

    /// - Parameters:
    ///   - configured: the CLIs the role is set up for, in its order.
    ///   - available: the keys the core found adapters for, or `nil` when
    ///     the core has not been read yet. **`nil` is not "none"**: with
    ///     nothing known, every CLI the role names is offered, as before
    ///     #1670, rather than the menu claiming none of them is here.
    static func of(configured: [String], available: Set<String>?) -> RoleCliOffer {
        let here = available.map { found in configured.filter { found.contains($0) } } ?? configured
        switch here.count {
        // None of them is here. The core still has an answer -- an agent in
        // this terminal wears the role without starting anything -- so the
        // row stays and the core says the rest.
        case 0: return .role
        case 1: return configured.count > 1 ? .only(here[0]) : .role
        default: return .choose(here)
        }
    }

    /// The keys `ghostty_app_agent_clis` answered with, or `nil` while it
    /// has never been read -- less the ones whose adapter said the CLI's
    /// program is not on this machine (`installed: false`, task 1744). One
    /// that did not say, or whose inventory failed, is still offered: not
    /// known is not "missing". The Windows host's twin is
    /// `roles::CliSnapshot::available`.
    static func available(_ snapshot: AgentCliSnapshot) -> Set<String>? {
        snapshot.stale ? nil : Set(snapshot.clis.filter { $0.installed != false }.map(\.key))
    }

    /// Make `entry` -- the role's row -- act this way.
    ///
    /// `labels` names each CLI the way the person knows it; a key it does
    /// not have is shown as itself. `action` and `target` are the role
    /// rows' own, passed in so this can be built without a terminal.
    @MainActor
    func apply(
        to entry: NSMenuItem,
        key: String,
        labels: [String: String],
        action: Selector,
        target: AnyObject?,
        enabled: Bool
    ) {
        entry.submenu = nil
        switch self {
        case .role:
            entry.action = action
            entry.representedObject = key
        case .only(let cli):
            entry.action = action
            entry.representedObject = "\(key),\(cli)"
        case .choose(let clis):
            entry.action = nil
            entry.representedObject = key
            let sub = NSMenu()
            sub.autoenablesItems = false
            for cli in clis {
                let row = NSMenuItem(title: labels[cli] ?? cli, action: action, keyEquivalent: "")
                row.target = target
                row.representedObject = "\(key),\(cli)"
                row.isEnabled = enabled
                sub.addItem(row)
            }
            entry.submenu = sub
        }
    }
}
