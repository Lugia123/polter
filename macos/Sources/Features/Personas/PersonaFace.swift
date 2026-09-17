import Foundation

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
        /// Identity as the core minted it: `<epoch>-<index>`.
        ///
        /// **Copied into the action string verbatim, never assembled
        /// here.** Building it on this side would make the apprt a second
        /// place that knows the format, and the two would drift.
        ///
        /// The epoch half is what makes it safe. A bare index aliases
        /// silently -- take a row out, put one back, and the number points
        /// at something else while every check on it still passes -- but
        /// any change bumps the epoch, so `8-3` is meaningless in version 9
        /// rather than accidentally still valid. Version 9 must *refuse*
        /// it, which is contract §0.5's third requirement and the reason
        /// this side does not compare epochs itself: one judge, the core.
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

        /// The slot is granted by the persona but its upstream server did
        /// not come up. Only ever true for `mcp` rows.
        ///
        /// Its own bit rather than `enabled = false`, because those two
        /// send the user to opposite places: "the persona withheld it" is
        /// fixed by editing the persona, "the server is down" is not, and
        /// roles.md's tenth section names exactly this -- *do not let "the
        /// upstream died" look like "this persona does not have it"*.
        var broken: Bool = false

        var isDeviation: Bool { enabled != inPersona }

        init(id: String? = nil, name: String, enabled: Bool, inPersona: Bool, broken: Bool = false) {
            self.id = id ?? name
            self.name = name
            self.enabled = enabled
            self.inPersona = inPersona
            self.broken = broken
        }
    }

    var skills: [Entry] = []
    var mcp: [Entry] = []

    /// The core's version counter for this terminal's face. Sent back with
    /// a toggle so a click made against a stale window cannot land on a
    /// different row than the one that was on screen.
    var epoch: UInt64 = 0

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
