import Foundation
import GhosttyKit

/// What a terminal is **actually** handing the agent right now -- the core's
/// `Face` (contract §②), as far as this side needs it.
///
/// roles.md §5.2 keeps two things apart and this is the second of them: the
/// **persona** is the preset the user picked, a key; the **face** is what is
/// exposed in this terminal at this moment. Picking a persona resets the
/// face to the persona's declaration; switching one skill or one slot by
/// hand moves only the face.
///
/// The design this replaced had the persona exist only at the instant it was
/// set, and the reason it was thrown out is worth repeating: **a state that
/// only exists at the moment it is set is no state at all.** The face is the
/// resident thing; the persona key is where it came from.
///
/// The `tools` dimension of the core's `Face` is deliberately absent. This
/// version of the editor switches skills and slots only -- adding a third
/// list nobody asked for would be scope this task does not have.
struct PersonaFace: Equatable {
    struct Entry: Identifiable, Equatable {
        /// Identity as the core minted it: `<roster>-<index>`.
        ///
        /// **Copied into the action string verbatim, never assembled
        /// here.** Building it on this side would make the apprt a second
        /// place that knows the format, and the two would drift.
        ///
        /// The `roster` half is what makes it safe. A bare index aliases
        /// silently -- take a row out, put one back, and the number points
        /// at something else while every check on it still passes -- but
        /// the roster counts *changes to the shape of this list*, so `1-3`
        /// stops meaning anything the moment a row appears or leaves. The
        /// core must then *refuse* it, which is contract §0.5's third
        /// requirement and why this side never compares versions itself:
        /// one judge, the core.
        ///
        /// ⚠️ **Not the `epoch`, and the difference is the point.** The
        /// epoch moves for any change at all, an unrelated upstream dying
        /// included. Minting ids from it would mean a slot going down two
        /// rows away refuses the switch the user is pressing right now --
        /// refuses it *correctly*, for a reason that has nothing to do with
        /// what they did. An accurate but irrelevant refusal is worse than
        /// a wrong one, because it leaves nothing to fix.
        let id: String

        let name: String

        /// Exposed in this terminal right now.
        var enabled: Bool

        /// Declared by the persona that is currently set.
        ///
        /// Kept beside `enabled` rather than diffed elsewhere, because both
        /// directions of disagreement are real and the user undoes them
        /// differently: `inPersona && !enabled` was switched off by hand,
        /// `!inPersona && enabled` was added by hand.
        let inPersona: Bool

        /// What the slot process is actually doing with this upstream.
        /// Only meaningful for `mcp` rows; `nil` on skills.
        ///
        /// A separate axis from `enabled`, which is what the persona says.
        /// The two can disagree, and when they do the user needs to be sent
        /// somewhere different: "the persona withheld it" is fixed by
        /// editing the persona, "the server never came up" is not.
        /// roles.md's tenth section names exactly this -- *do not let "the
        /// upstream died" look like "this persona does not have it"*.
        var slot: SlotStatus?

        var isDeviation: Bool { enabled != inPersona }

        init(
            id: String? = nil,
            name: String,
            enabled: Bool,
            inPersona: Bool,
            slot: SlotStatus? = nil
        ) {
            self.id = id ?? name
            self.name = name
            self.enabled = enabled
            self.inPersona = inPersona
            self.slot = slot
        }
    }

    /// Contract §4.3's four states for one slot.
    ///
    /// Four rather than a `broken` flag because each sends the user
    /// somewhere different, and two of them are invisible in `enabled`.
    enum SlotStatus: String {
        /// Outside Polter: the slot never got an answer, so it passes the
        /// upstream through whole. Worth saying, because the persona is not
        /// what is deciding here.
        case transparent

        /// The persona asked for it and the slot is handing it over.
        case granted

        /// The persona did not ask for it, so the upstream is not even
        /// started. Says the same thing the unticked box does.
        case withheld

        /// The persona asked for it and the upstream would not come up.
        /// The one state the checkbox cannot express at all.
        case broken
    }

    var skills: [Entry] = []
    var mcp: [Entry] = []

    /// The core's version counter for this terminal's face: bumped by any
    /// change at all, including an upstream dying or coming back. What the
    /// editor watches to know it should re-read.
    var epoch: UInt64 = 0

    /// Bumped only when the *shape* of the lists changes -- a row appearing,
    /// leaving, or moving. Ids are minted from it, so a click stays valid
    /// while the rows it was aimed at are still the same rows.
    ///
    /// Carried but never compared here. Deciding whether an id is still good
    /// is the core's, and a second judge on this side would be a second set
    /// of rules with the lenient one winning.
    var roster: UInt64 = 0

    /// Something the core wants the user to see, in its own words.
    ///
    /// Shown rather than swallowed: contract §① keeps the previous file in
    /// effect and sends the error text to the interface, and without it here
    /// a syntax error in `personas.json` reads exactly like "no personas are
    /// defined" -- a message this app already shows, which would then be
    /// taking the blame for a typo.
    var loadError: String?

    /// Which kind of error `loadError` is (contract §3.5): `"parse"` for a
    /// `personas.json` that did not load, `"stale_id"` for a toggle sent
    /// from a menu built against an older epoch, `nil` for none.
    ///
    /// Carried rather than inferred from the message, because the two need
    /// different things from the user -- fix the file, versus reopen the
    /// menu -- and a substring match on prose is not a way to tell them
    /// apart.
    var errorKind: String?

    /// Whether anything has reported a face for this terminal yet.
    ///
    /// Same reason `HostInventory.isKnown` exists: two empty lists are
    /// equally "this terminal hands out nothing" and "nobody has told us",
    /// and only one of those is worth a sentence to the user.
    var isKnown: Bool = false

    var isEmpty: Bool { skills.isEmpty && mcp.isEmpty }

    /// The face no longer matches the persona's declaration.
    ///
    /// Computed from the rows on screen rather than read from the core's
    /// `deviated` bit, so the badge and the rows explaining it can never
    /// disagree. The core's bit is the one the *menu* shows; the two
    /// disagreeing is a bug to hear about, not a field to pick a winner
    /// from.
    var deviates: Bool {
        skills.contains(where: \.isDeviation) || mcp.contains(where: \.isDeviation)
    }
}

extension PersonaFace {
    /// Decode `ghostty_surface_persona_face`'s JSON.
    ///
    /// Returns `nil` only when there was no answer at all -- a well-formed
    /// answer with nothing in it is `isKnown = true` and empty, which is a
    /// different fact and drawn differently.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        self.init()

        // `stale` is the core saying it has nothing to report yet -- either
        // `personas.json` has not been read, or rendering the face failed.
        // Reading that as a face with nothing in it is the exact collapse
        // the field was added to prevent: "nobody has told us" would be
        // drawn as "this terminal hands out nothing", and the second one
        // never resolves itself.
        self.isKnown = !(root["stale"] as? Bool ?? false)
        self.epoch = (root["epoch"] as? NSNumber)?.uint64Value ?? 0
        self.roster = (root["roster"] as? NSNumber)?.uint64Value ?? 0
        self.loadError = root["error"] as? String
        self.errorKind = root["error_kind"] as? String
        self.skills = Self.entries(root["skills"])
        self.mcp = Self.entries(root["mcp"])
    }

    private static func entries(_ value: Any?) -> [Entry] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            // `id` is the core's, `<epoch>-<index>`, and goes back into the
            // action string exactly as it arrived. A row without one is a row
            // no toggle could be sent for, so it is dropped rather than shown
            // with a switch that would do nothing.
            guard let id = row["id"] as? String,
                  let name = row["name"] as? String
            else { return nil }
            return Entry(
                id: id,
                name: name,
                enabled: row["enabled"] as? Bool ?? false,
                inPersona: row["in_persona"] as? Bool ?? false,
                // An unrecognised status is left `nil` rather than guessed
                // at: a slot state this build does not know is not a state
                // it should be drawing a sentence about.
                slot: (row["slot"] as? String).flatMap(SlotStatus.init(rawValue:)))
        }
    }

    /// Read this terminal's face out of the core.
    ///
    /// `@MainActor` because the reader it borrows is: this is a query onto
    /// core state and it is called while a menu is being built, which is
    /// the main thread by construction.
    @MainActor
    static func read(surface: ghostty_surface_t) -> PersonaFace? {
        guard let json = PersonaCatalog.readJSON({ buf, cap in
            ghostty_surface_persona_face(surface, buf, cap)
        }) else { return nil }
        return PersonaFace(json: json)
    }
}
