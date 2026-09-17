import Foundation
import GhosttyKit

// MARK: - Why this says "persona" and the interface says "Role"
//
// `ghostty_action_poltergeist_mark_s` already carries a field called `role`,
// and it means something else entirely: supervisor / watched / none, the
// terminal's place in the arrangement. A second field called `role_key`
// holding "archer" would sit in the same struct one suffix away from it,
// and reading one for the other does not fail -- it just looks right.
//
// So the identifier is `persona` everywhere in code, and every string the
// user reads still says 角色 / "Role". `dev-docs/poltergeist/personas-contract.md`
// §0 settles this; `roles.md` is the design it implements.

/// One persona, as declared in the user's `personas.json`.
///
/// **This app never parses that file.** The core reads it, validates it, and
/// hands over what is already checked (contract §①) -- two readers would be
/// two validators, and the lenient one wins. This type is the shape the core
/// hands over, nothing more.
struct Persona: Identifiable, Equatable, Hashable {
    var id: String { key }

    /// `[a-z0-9-]{1,32}`, unique within the file.
    ///
    /// The charset is not taste. The key ends up inside a binding action
    /// string, and `windows/host/src/menu.rs`'s
    /// `action_strings_have_a_binding_shape` only allows lowercase, digits
    /// and `_:,-` in one of those. A persona called `Archer` spells an
    /// action string that gate turns red on.
    let key: String

    /// What the user sees. Their words, any script.
    let name: String

    /// Polter's own opening prompt for this persona, delivered through the
    /// tool surface rather than placed as a file (roles.md §2: files are not
    /// per-terminal). Named here, not quoted -- the text is in their file.
    let prompt: String?

    /// The half only a restart can honour (roles.md §6). Shown so it can be
    /// seen, never presented as already applied.
    let hint: Hint?

    struct Hint: Equatable, Hashable {
        var disableHostPlugins: [String] = []
        var model: String?

        var isEmpty: Bool { disableHostPlugins.isEmpty && model == nil }
    }

    init(key: String, name: String, prompt: String? = nil, hint: Hint? = nil) {
        self.key = key
        self.name = name
        self.prompt = prompt
        self.hint = hint
    }
}

/// How the agent CLI in a terminal takes a change of persona (roles.md §6).
///
/// ⚠️ **There is deliberately no host-name table on this side.** The core
/// already refuses to copy its mark glyphs into each apprt because "a table
/// of them copied into each apprt is a table that drifts"
/// (`apprt/action.zig`, `PoltergeistMark.Role`). A hot/warm/cold table would
/// drift the same way, and it would drift in the direction of claiming a
/// change already took effect. The class arrives per terminal from the core.
///
/// Sync with: `ghostty_action_poltergeist_host_class_e` (contract §3.1).
enum PersonaHostClass: Equatable {
    /// Nobody has said which agent CLI is in there.
    ///
    /// **Zero in the C enum, and its own wording here.** Folding it into
    /// `.hot` makes a change that has not happened look like one that has;
    /// folding it into `.cold` sends a claude-code user to restart for
    /// nothing. Same shape as `PoltergeistLayout.Result` putting
    /// `unsupported` at zero: the zero value has to be the honest answer.
    ///
    /// Not a rare branch either -- the contract says the core sends
    /// `UNKNOWN` for every terminal until `host_class` has a source at all,
    /// and the window before an agent finishes its handshake is `UNKNOWN`
    /// forever after that.
    case unknown

    /// claude-code, gemini: the slot swaps its tool set, sends
    /// `notifications/tools/list_changed`, the running agent re-equips.
    case hot

    /// qwen-code: through its own runtime interface, not the MCP one.
    case warm

    /// codex, opencode, kimi, deepseek: only a restart.
    case cold

    /// Sync with: `ghostty_action_poltergeist_host_class_e`.
    ///
    /// Anything the core sends that this does not know maps to `.unknown`,
    /// which is the only safe default: a class added later and silently read
    /// as `.hot` would be a change that has not happened, drawn as one that
    /// has.
    init(_ c: ghostty_action_poltergeist_host_class_e) {
        switch c {
        case GHOSTTY_POLTERGEIST_HOST_HOT: self = .hot
        case GHOSTTY_POLTERGEIST_HOST_WARM: self = .warm
        case GHOSTTY_POLTERGEIST_HOST_COLD: self = .cold
        default: self = .unknown
        }
    }

    /// The one line the menu shows so that picking a persona cannot be
    /// mistaken for a change that already happened. `nil` when it is
    /// immediate, and three distinct strings otherwise -- see `.unknown`.
    var pendingRestartNote: String? {
        switch self {
        case .hot, .warm:
            return nil
        case .cold:
            return String(
                localized: "Takes effect the next time the agent starts",
                comment: "角色菜单：冷宿主，换角色要下次启动才生效")
        case .unknown:
            return String(
                localized: "May need the agent to restart before it takes effect",
                comment: "角色菜单：不知道是哪家 agent CLI，不许说得像已经生效")
        }
    }
}

/// What one terminal's persona looks like right now.
///
/// Two things that must not be conflated (roles.md §5.2): `key` is **the
/// preset the user picked**; `deviated` says the **effective set** has since
/// been changed by hand. A persona that existed only at the instant it was
/// set would be no state at all, so the pair is what is carried.
struct PersonaState: Equatable {
    /// `nil` when no persona has been set on this terminal.
    var key: String?

    /// The display name as the core knows it. Carried beside `key` so a
    /// terminal whose persona was deleted from the file still renders,
    /// without this side inventing a name for it.
    var name: String?

    /// The effective set no longer matches what the persona declares.
    /// Computed by the core on every read rather than recorded, so it
    /// cannot drift away from the thing it describes (contract §②).
    var deviated: Bool = false

    var hostClass: PersonaHostClass = .unknown

    /// Whether an agent is actually connected to Polter in this terminal.
    ///
    /// roles.md §5.3: a persona is the user's **intent** for a terminal, not
    /// a measurement of what is running in it, and "an out-of-date mark and
    /// a correct one look exactly alike". So with nobody home the terminal
    /// does not get shown as *being* that persona -- but it is still shown
    /// as *having* it, which is why this is its own bit rather than the core
    /// withholding `key`. Withholding makes "never picked one" and "picked
    /// one, nobody connected" identical, and the second one heals itself
    /// while the first sends the user to pick again.
    var agentPresent: Bool = false

    static let none = PersonaState()

    /// "射手", or "射手（已改）" once it has been changed by hand.
    func displayName(in catalog: [Persona]) -> String? {
        guard let key else { return nil }
        let base = name ?? catalog.first { $0.key == key }?.name ?? key
        guard deviated else { return base }
        return String(
            format: String(localized: "%@ (modified)",
                           comment: "角色显示名：选了角色之后又单独改过，例如「射手（已改）」"),
            base)
    }
}
