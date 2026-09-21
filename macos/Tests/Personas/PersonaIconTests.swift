import AppKit
import Testing
@testable import Ghostty

/// The checklist's items 1 and 7, made machine-answerable.
///
/// **What was only human about them.** "Is there an icon there, or a blank
/// where one should be" was on the paper checklist because a misspelt SF
/// Symbol is not an error in any layer: `NSImage(systemSymbolName:)` hands
/// back `nil`, the menu draws a gap, and nothing anywhere says so. And the
/// paper had a second warning under it -- icons are only set on macOS 26 and
/// up, so *no icons at all* is the correct picture on anything older. That
/// second half is the one a test on this machine cannot reach by accident:
/// this machine is 26.5.1, so `#available(macOS 26, *)` is true here every
/// time it is evaluated, and a check that only calls `setImageIfDesired`
/// would be asserting one branch while reporting on two.
///
/// So the gate was split (`NSMenuItem.menuItemImagesAreDesired`) and the
/// menu builder takes the answer as an argument. Both branches run here;
/// the `#available` itself is the one line that does not, and its true side
/// is what this machine returns.
@MainActor
@Suite
struct PersonaIconTests {
    private let archer = Persona(key: "archer", name: "Archer")
    private let target = PersonaMenuTargetStub()

    /// A terminal that makes the menu draw every note row it has: shielded,
    /// on an unknown host, with a persona set and nobody wearing it.
    private var everyNoteAtOnce: PersonaState {
        PersonaState(key: "archer", name: "Archer", deviated: false,
                     hostClass: .unknown, agentPresent: false)
    }

    private func menu(
        imagesDesired: Bool,
        personas: [Persona] = [],
        personasKnown: Bool = false
    ) -> NSMenuItem {
        PersonaMenu.makeItem(
            state: everyNoteAtOnce,
            shielded: true,
            personas: personas,
            personasKnown: personasKnown,
            target: target,
            imagesDesired: imagesDesired)
    }

    // MARK: The names themselves

    /// Item 7, for the symbols this build names.
    ///
    /// Walks `PersonaSymbol.allCases` rather than a list written out here:
    /// a list in a test is a copy, and a copy of the names is exactly the
    /// thing that can go stale while every assertion over it still passes.
    @Test func everySymbolTheRoleUINamesResolvesOnThisSystem() {
        for symbol in PersonaSymbol.allCases {
            #expect(symbol.resolves, "\(symbol.rawValue) resolved to no image")
        }
    }

    // MARK: macOS 26 and up

    /// Every row that asks for an icon gets one -- `item.image != nil`,
    /// which is the assertion a typo in a symbol name fails.
    @Test func onASystemThatWantsIconsEveryRowThatAsksForOneHasOne() throws {
        let item = menu(imagesDesired: true)
        #expect(item.image != nil, "the Role item itself has no icon")

        let rows = try #require(item.submenu).items
        let titled = rows.filter { !$0.isSeparatorItem }

        // The four notes this state produces, plus the editor. Named by
        // their strings rather than by index so a row moving does not turn
        // this into an assertion about a different row.
        for title in [
            String(localized: "Agents are kept out of this terminal, so its role cannot be changed"),
            String(localized: "May need the agent to restart before it takes effect"),
            String(localized: "No agent is connected here, so nothing is wearing this yet"),
            String(localized: "Nothing has reported which roles exist yet"),
            String(localized: "Role Editor (beta)..."),
        ] {
            let row = try #require(titled.first { $0.title == title },
                                   "no row titled \(title)")
            #expect(row.image != nil, "\(title) has no icon")
        }

        // "No Role" carries no icon on purpose: it is a choice, not a note,
        // and the tick is what says which choice is taken.
        let noRole = try #require(titled.first { $0.title == String(localized: "No Role") })
        #expect(noRole.image == nil)
    }

    /// The other note -- the list was reported and is empty -- needs its own
    /// terminal, because it and "nothing has reported" cannot both be drawn.
    @Test func theEmptyListNoteCarriesItsOwnIcon() throws {
        let item = menu(imagesDesired: true, personas: [], personasKnown: true)
        let rows = try #require(item.submenu).items
        let row = try #require(rows.first {
            $0.title == String(localized: "No roles are defined")
        })
        #expect(row.image != nil)
    }

    /// The note that appears when there is no terminal to act on carries one
    /// too. Its own test because it and the shield note cannot both be the
    /// first row, and because a symbol nobody renders is a symbol nobody
    /// notices is missing.
    @Test func theNoTerminalNoteCarriesItsOwnIcon() throws {
        let item = PersonaMenu.makeItem(
            state: everyNoteAtOnce,
            personas: [archer],
            personasKnown: true,
            target: nil,
            imagesDesired: true)
        let rows = try #require(item.submenu).items
        let row = try #require(rows.first {
            $0.title == String(localized: "There is no terminal here to change")
        })
        #expect(row.image != nil)
    }

    // MARK: Older than macOS 26

    /// The branch this machine cannot take by itself.
    ///
    /// Not a lesser claim than the one above: on macOS 25 and older a stray
    /// icon is the defect, and "no icons at all is correct here" was a
    /// sentence the checklist had to say to a human because nothing could
    /// assert it.
    @Test func onASystemThatDoesNotWantIconsNothingHasOne() throws {
        let item = menu(imagesDesired: false, personas: [archer], personasKnown: true)
        #expect(item.image == nil, "the Role item has an icon on a system that wants none")

        for row in try #require(item.submenu).items {
            #expect(row.image == nil, "\(row.title) has an icon on a system that wants none")
        }
    }

    /// The app itself asks the OS.
    ///
    /// `imagesDesired` has a default so that no call site in the app had to
    /// change -- and a default is exactly what can quietly stop being the
    /// OS's answer. Built with the argument left off, which is how the app
    /// builds it.
    @Test func theDefaultIsWhateverThisSystemAnswers() {
        let item = PersonaMenu.makeItem(
            state: everyNoteAtOnce,
            shielded: true,
            personas: [],
            personasKnown: false,
            target: target)
        #expect((item.image != nil) == NSMenuItem.menuItemImagesAreDesired)
    }
}
