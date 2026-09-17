import Foundation
import OSLog

/// The personas the user has defined, and the read-only inventory of what
/// the agent CLI has installed globally.
///
/// Both live here because the editor needs both on screen at once, and
/// because the line between them is the design's hard boundary (roles.md §4):
///
/// | | Polter's attitude |
/// | --- | --- |
/// | personas, and what one hands out | **maintained** |
/// | the host's own global plugins / skills / MCP | **read-only** |
///
/// "Read-only" is not a soft preference. The inventory is on screen so the
/// user can see *what a persona does not cover* -- "my archer has no argus
/// from Polter, but argus is installed globally, so he has it anyway". It is
/// not there so anything here can switch it off, and this type offers no way
/// to.
///
/// ⚠️ **This type reads nothing from disk.** Contract §① is explicit that
/// the core reads `$XDG_CONFIG_HOME/polter/personas.json` and the apprt asks
/// for the result: the closed-set check belongs to the core (roles.md §7),
/// and two readers means two validators with the lenient one deciding.
@MainActor
final class PersonaCatalog: ObservableObject {
    static let shared = PersonaCatalog()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "personas")

    /// Every persona the core accepted, in file order (the file keeps an
    /// array rather than a map precisely so the user can order the menu).
    @Published private(set) var personas: [Persona] = []

    /// Whether anything has reported a persona list at all.
    ///
    /// An empty list is not enough to go on: "the user has defined no
    /// personas" and "nobody has told us which personas exist" are
    /// different facts, and they send the user to different places -- the
    /// first to write `personas.json`, the second to wait or report a bug.
    /// Collapsing them is the same mistake as an empty inventory reading
    /// as "nothing installed".
    @Published private(set) var isKnown: Bool = false

    /// What the agent CLI has installed globally, for the read-only pane.
    @Published private(set) var inventory: HostInventory = .unknown

    /// Refresh from the core.
    ///
    /// ⚠️ **PENDING-W1-568: there is nothing to ask yet.** The two query
    /// functions this will call are specified in contract §3.3 and §3.4 --
    /// `ghostty_app_personas` (key + name, "write what fits and say the real
    /// count") and `ghostty_app_persona_hosts` (a JSON blob, because the
    /// shape is the host's not ours). Neither exists in `include/ghostty.h`
    /// today, so this leaves both empty and every surface that draws them
    /// says which kind of empty it is.
    ///
    /// Deliberately not stubbed with plausible-looking sample personas: an
    /// interface wired to invented data is indistinguishable from one that
    /// is wired up, which is a mistake that costs a whole round of work to
    /// notice.
    func reload() {
        // no-op until the core has the queries
    }

    func persona(key: String) -> Persona? {
        personas.first { $0.key == key }
    }

    /// Replace the read-only inventory. Called by whoever learns it; this
    /// type never goes looking, because looking means reading the host's own
    /// config files, and that is the far side of the boundary above.
    func setInventory(_ inventory: HostInventory) {
        self.inventory = inventory
    }

    /// Replace the persona list. Same reason as `setInventory`.
    ///
    /// Calling this at all is what makes the list *known*, including when
    /// what arrives is empty -- that is the difference between "asked, and
    /// there are none" and "never asked".
    func setPersonas(_ personas: [Persona]) {
        self.personas = personas
        self.isKnown = true
    }
}

/// One category of what the agent CLI has installed globally -- and, when
/// there is no list, which kind of "no list" it is.
///
/// Four states rather than an array that might be empty, because the four
/// send the user to four different places. `roles.md` §4 puts this pane on
/// screen so the user can see *what a persona does not cover*; a pane that
/// says "nothing" when it means "we never looked" is worse than no pane.
enum HostInventorySection: Equatable {
    /// Nobody has established where this agent CLI keeps this kind of
    /// thing. **Not the same as "it has none"** -- this is our gap, not
    /// theirs, and the user who reads it should go and check the path
    /// rather than go and install something.
    case unknownLocation

    /// The location is known and there is nothing in it. Same rendering as
    /// `.read([])`, because to the user they are one fact.
    case absent

    /// Read. An empty array here really does mean empty.
    case read([String])

    /// The location is known and could not be read, in the core's words.
    /// The message is shown *with* a lead-in: raw error text alone has no
    /// subject, and a lead-in alone swallows a diagnosable error.
    case failed(String)

    var names: [String] {
        if case .read(let names) = self { return names }
        return []
    }
}

/// What the agent CLI has installed globally, purely to be looked at.
///
/// Every field is a list of names or a reason there is no list. There are no
/// toggles and no handles to act on, because there is no action to take --
/// see `PersonaCatalog`.
struct HostInventory: Equatable {
    /// Which agent CLI this is, as the host table names it (`claude-code`,
    /// `codex`, ...). `nil` when nobody has said.
    var host: String?

    var plugins: HostInventorySection = .unknownLocation
    var skills: HostInventorySection = .unknownLocation
    var mcpServers: HostInventorySection = .unknownLocation

    /// The core's cache has not been built yet, so this is last known (or
    /// nothing). Contract §3.4: scanning host directories is I/O and must
    /// not happen on the UI thread, so the first read can legitimately
    /// arrive stale.
    var stale: Bool = false

    /// Whether every agent's configuration was readable when the slots were
    /// counted (contract §4.1, `slot_budget.complete`).
    ///
    /// When it is false the number of slots on screen is a **lower bound**,
    /// not the count -- an agent whose config came back `unknownLocation` or
    /// `failed` contributed nothing to it. A number that was arrived at this
    /// way looks exactly like one that is complete, which is the whole
    /// reason this bit is carried up to the interface instead of being
    /// spent in the core and forgotten.
    ///
    /// Display only on this side. What the core does with an incomplete M --
    /// only ever push the connection ceiling *up*, never down, because
    /// under-counting upstreams is what walks a user into `AgentsFull` --
    /// is §4.1's business, not the editor's.
    var slotBudgetComplete: Bool = true

    /// Whether anything has reported an inventory at all.
    ///
    /// A different axis from the four states above: this one is "Polter has
    /// not finished working it out", those are "it worked it out, and this
    /// is the answer for this category". The same shape as the core's
    /// `PoltergeistTabPanes` reading a zero count as *did not answer*
    /// rather than as *empty*.
    var isKnown: Bool = false

    static let unknown = HostInventory()
}
