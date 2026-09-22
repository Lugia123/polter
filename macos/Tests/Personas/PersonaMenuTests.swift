import AppKit
import Testing
@testable import Ghostty

/// Covers `PersonaMenu` -- the whole of the `Role ▸` submenu, built without
/// an app, a window, or a screen.
///
/// **Why this file exists.** The menu compiled, and for a while that was the
/// only thing anyone could say about it: this project's agents are not
/// allowed to start the GUI (the user is sitting at the running instance),
/// so between "it builds" and "the menu came out right" there was nothing at
/// all. `makeItem` takes its personas and its state as arguments rather than
/// reaching for `PersonaCatalog.shared` precisely so that gap can be closed
/// here instead of by looking at it.
///
/// **What is asserted and what is not.** These check structure -- how many
/// rows, in what order, which one is ticked, which are disabled, and *which*
/// string went where -- not the wording, which lives in
/// `Localizable.strings` and is compared against itself where it appears at
/// all. The claims that matter are the ones phrased as a difference between
/// two menus, because those hold whatever language the machine is in.
@MainActor
@Suite
struct PersonaMenuTests {
    private let archer = Persona(key: "archer", name: "Archer")
    private let scribe = Persona(key: "scribe", name: "Scribe")

    /// Every menu here is built pointing at something, because a menu built
    /// pointing at nothing is a *different* menu -- see
    /// `PersonaMenuTargetStub` and `noTerminalToActOn…` below.
    private let target = PersonaMenuTargetStub()

    private var both: [Persona] { [archer, scribe] }

    private func makeItem(
        _ state: PersonaState,
        shielded: Bool = false,
        personas: [Persona]? = nil,
        personasKnown: Bool = true
    ) -> NSMenuItem {
        PersonaMenu.makeItem(
            state: state,
            shielded: shielded,
            personas: personas ?? both,
            personasKnown: personasKnown,
            target: target)
    }

    private func submenu(
        _ state: PersonaState,
        shielded: Bool = false,
        personas: [Persona]? = nil,
        personasKnown: Bool = true
    ) throws -> NSMenu {
        let item = makeItem(state, shielded: shielded, personas: personas, personasKnown: personasKnown)
        return try #require(item.submenu)
    }

    /// A terminal wearing `archer`, on a host that re-equips immediately.
    private var wearingArcher: PersonaState {
        PersonaState(key: "archer", name: "Archer", deviated: false,
                     hostClass: .hot, agentPresent: true)
    }

    // MARK: Shape

    @Test func aPlainSubmenuIsTheTwoPersonasThenNoRoleThenTheLibrary() throws {
        let menu = try submenu(wearingArcher)

        #expect(menu.items.count == 6)
        #expect(menu.items[0].title == "Archer")
        #expect(menu.items[1].title == "Scribe")
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].title == String(localized: "No Role"))
        #expect(menu.items[4].isSeparatorItem)
        #expect(menu.items[5].title == String(localized: "Role Library..."))
    }

    /// The order of the file is the order of the menu: `personas.json` keeps
    /// an array rather than a map so that the user decides it.
    @Test func personasKeepTheOrderTheyWereGivenIn() throws {
        let menu = try submenu(wearingArcher, personas: [scribe, archer])
        #expect(menu.items[0].title == "Scribe")
        #expect(menu.items[1].title == "Archer")
    }

    // MARK: Ticks

    @Test func exactlyTheCurrentPersonaIsTicked() throws {
        let menu = try submenu(wearingArcher)
        #expect(menu.items[0].state == .on)
        #expect(menu.items[1].state == .off)
        #expect(menu.items[3].state == .off)   // No Role
    }

    @Test func noRoleIsTickedWhenNoPersonaIsSet() throws {
        let menu = try submenu(PersonaState(hostClass: .hot, agentPresent: true))
        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .off)
        #expect(menu.items[3].state == .on)
    }

    /// The key is what a row carries, not its position: an index reused
    /// after a persona is removed aliases silently.
    @Test func eachRowCarriesItsPersonaKey() throws {
        let menu = try submenu(wearingArcher)
        #expect(menu.items[0].representedObject as? String == "archer")
        #expect(menu.items[1].representedObject as? String == "scribe")
        #expect(menu.items[3].representedObject == nil)
    }

    // MARK: The two claims that are not allowed to be wrong

    /// roles.md §5.3. With nobody connected the terminal still *has* the
    /// persona -- the row stays ticked -- but the parent item stops saying
    /// it *is* one, because that mark would be a measurement nobody took.
    ///
    /// Phrased as "reads the same as a terminal with no persona at all",
    /// which is the claim, and which holds in any language.
    @Test func withNoAgentConnectedTheParentDoesNotClaimThePersona() throws {
        var lonely = wearingArcher
        lonely.agentPresent = false

        let parentWhenLonely = makeItem(lonely).title
        let parentWhenUnset = makeItem(PersonaState(hostClass: .hot)).title
        let parentWhenWorn = makeItem(wearingArcher).title

        #expect(parentWhenLonely == parentWhenUnset)
        #expect(parentWhenLonely != parentWhenWorn)

        // Still set, though -- and the submenu says why it is not in force.
        let menu = try submenu(lonely)
        #expect(menu.items.last(where: { $0.representedObject as? String == "archer" })?.state == .on)
        #expect(menu.items.contains { $0.title == String(
            localized: "No agent is connected here, so nothing is wearing this yet") })
    }

    /// roles.md §5.2. Once the effective set has been changed by hand the
    /// name has to change with it, in the parent and in the ticked row.
    @Test func aDeviatedPersonaReadsDifferentlyEverywhereItIsNamed() throws {
        var changed = wearingArcher
        changed.deviated = true

        #expect(makeItem(changed).title != makeItem(wearingArcher).title)

        let tickedWhenChanged = try submenu(changed).items[0].title
        #expect(tickedWhenChanged != "Archer")
        #expect(tickedWhenChanged.contains("Archer"))
        #expect(try submenu(wearingArcher).items[0].title == "Archer")
    }

    // MARK: Host class

    /// roles.md §6: a cold host says so, above the choices, before the click.
    @Test func aColdHostSaysSoBeforeTheChoices() throws {
        var cold = wearingArcher
        cold.hostClass = .cold

        let menu = try submenu(cold)
        #expect(menu.items[0].title == PersonaHostClass.cold.pendingRestartNote)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Archer")
    }

    @Test func aHotHostSaysNothingAboutRestarting() throws {
        #expect(PersonaHostClass.hot.pendingRestartNote == nil)
        #expect(PersonaHostClass.warm.pendingRestartNote == nil)
        #expect(try submenu(wearingArcher).items[0].title == "Archer")
    }

    /// The four-way class has to read four ways. Folding `unknown` into
    /// `hot` makes a change that has not happened look like one that has;
    /// folding it into `cold` sends a claude-code user to restart for
    /// nothing.
    @Test func unknownIsItsOwnSentence() throws {
        let unknown = PersonaHostClass.unknown.pendingRestartNote
        let cold = PersonaHostClass.cold.pendingRestartNote
        #expect(unknown != nil)
        #expect(unknown != cold)

        var state = wearingArcher
        state.hostClass = .unknown
        #expect(try submenu(state).items[0].title == unknown)
    }

    // MARK: Shield

    /// roles.md §7.2: a shielded terminal refuses every re-equip, a
    /// supervisor included. Looking is not re-equipping, so the editor row
    /// stays live.
    @Test func aShieldedTerminalOffersNothingToClickButTheEditor() throws {
        let menu = try submenu(wearingArcher, shielded: true)

        #expect(menu.items[0].title == String(
            localized: "Agents are kept out of this terminal, so its role cannot be changed"))

        let personaRows = menu.items.filter { $0.representedObject is String }
        #expect(personaRows.count == 2)
        #expect(personaRows.allSatisfy { !$0.isEnabled })

        let noRole = try #require(menu.items.first { $0.title == String(localized: "No Role") })
        #expect(!noRole.isEnabled)

        let editor = try #require(
            menu.items.first { $0.title == String(localized: "Role Library...") })
        #expect(editor.isEnabled)
    }

    // MARK: Empty, and the two kinds of empty

    /// "Asked, and the user has defined none" sends them to write
    /// `personas.json`. "Nobody has reported the list" does not. One
    /// sentence apart, and the whole point of carrying `personasKnown`.
    @Test func noPersonasAndNoAnswerAreDifferentSentences() throws {
        let defined = try submenu(wearingArcher, personas: [], personasKnown: true)
        let unknown = try submenu(wearingArcher, personas: [], personasKnown: false)

        #expect(defined.items[0].title == String(localized: "No roles are defined"))
        #expect(unknown.items[0].title == String(
            localized: "Nothing has reported which roles exist yet"))
        #expect(defined.items[0].title != unknown.items[0].title)
    }

    /// Even with no personas to choose from, the way back out and the way
    /// into the editor are still there.
    @Test func anEmptyCatalogueStillOffersNoRoleAndTheEditor() throws {
        let menu = try submenu(wearingArcher, personas: [], personasKnown: true)
        #expect(menu.items.contains { $0.title == String(localized: "No Role") })
        #expect(menu.items.contains { $0.title == String(localized: "Role Library...") })
    }

    // MARK: Parent item

    /// The tab strip is where you look when you are deciding *which*
    /// terminal, so the parent row says what this one is without being
    /// opened.
    @Test func theParentNamesThePersonaWithoutBeingOpened() throws {
        #expect(makeItem(wearingArcher).title.contains("Archer"))
        #expect(!makeItem(PersonaState(hostClass: .hot)).title.contains("Archer"))
    }

    // MARK: Nothing to act on

    /// The state this submenu was actually caught in: every row enabled, the
    /// click delivered, and nothing happening.
    ///
    /// Measured on a real window before the fix (task 586): with the app not
    /// frontmost, `click` returned `clicked` and exit 0 while the window
    /// count stayed at 1, three times running, and the item read
    /// `enabled = true` throughout. `autoenablesItems = false` is why AppKit
    /// did not grey it for us -- that flag is load-bearing for the rows
    /// above, so the other half of its job has to be done by hand.
    ///
    /// A person reaches this with every window closed, which is when the
    /// menu bar's copy has no terminal to be about.
    @Test func withNoTerminalToActOnNothingIsClickable() throws {
        let menu = try #require(PersonaMenu.makeItem(
            state: wearingArcher,
            personas: both,
            personasKnown: true,
            target: nil).submenu)

        // The reason, above the grey rows. This file's own rule: greying
        // rows without saying why is just a broken menu.
        #expect(menu.items.first?.title == String(localized: "There is no terminal here to change"))
        #expect(menu.items.first?.isEnabled == false)

        for row in menu.items where !row.isSeparatorItem {
            #expect(!row.isEnabled, "\(row.title) is still clickable with nothing to act on")
        }
    }

    /// The contrast, and the reason the one above is not vacuous: the same
    /// menu with something to act on has those rows live.
    @Test func withATerminalToActOnTheSameRowsAreClickable() throws {
        let menu = try submenu(wearingArcher)

        #expect(menu.items.first?.title != String(localized: "There is no terminal here to change"))
        let clickable = menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }
        // Both personas, "No Role", and the editor.
        #expect(clickable.count == 4)
    }

    /// The library is about every role, not about this terminal: it stays
    /// live on a shielded terminal and with no terminal at all -- the menu
    /// bar with every window closed is where a first role gets made.
    @Test func theLibraryIsAlwaysReachable() throws {
        let shielded = try submenu(wearingArcher, shielded: true)
        let whenShielded = try #require(
            shielded.items.first { $0.title == String(localized: "Role Library...") })
        #expect(whenShielded.isEnabled)

        let targetless = try #require(PersonaMenu.makeItem(
            state: wearingArcher, personas: both, personasKnown: true,
            target: nil).submenu)
        let whenTargetless = try #require(
            targetless.items.first { $0.title == String(localized: "Role Library...") })
        #expect(whenTargetless.isEnabled)
    }

    /// A role set up for two agent CLIs opens a list of them, and each row
    /// carries `key,cli` so the core knows which to start. One CLI or none:
    /// a single row carrying the key alone.
    @Test func aRoleWithSeveralClisAsksWhich() throws {
        let duo = Persona(key: "duo", name: "Duo", clis: [
            .init(key: "claude-code", label: "Claude Code"),
            .init(key: "codex", label: "Codex"),
        ])
        let solo = Persona(key: "solo", name: "Solo", clis: [.init(key: "claude-code", label: "Claude Code")])
        let menu = try submenu(wearingArcher, personas: [solo, duo])

        let soloRow = try #require(menu.items.first { $0.title == "Solo" })
        #expect(soloRow.submenu == nil)
        #expect(soloRow.representedObject as? String == "solo")

        let duoRow = try #require(menu.items.first { $0.title == "Duo" })
        let clis = try #require(duoRow.submenu)
        #expect(clis.items.map(\.title) == ["Claude Code", "Codex"])
        #expect(clis.items.map { $0.representedObject as? String } == ["duo,claude-code", "duo,codex"])
        #expect(clis.items.allSatisfy { $0.isEnabled })
        #expect(clis.items.allSatisfy { $0.action == #selector(PersonaMenuTarget.setPoltergeistPersona(_:)) })
    }

    @Test func theSubmenuDecidesItsOwnEnabledState() throws {
        // Without this AppKit re-enables the rows this file just checked
        // are disabled: the default validation answers "yes" for anything
        // whose target responds to the selector.
        #expect(try submenu(wearingArcher).autoenablesItems == false)
    }
}
