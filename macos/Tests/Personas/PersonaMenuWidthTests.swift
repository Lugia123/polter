import AppKit
import Testing
@testable import Ghostty

/// The checklist's item 3 -- "两条长中文各占一行，完整，没有 `…`" -- without
/// anybody looking at a menu.
///
/// **Why it was a human's job.** Nothing in the app truncates these strings:
/// AppKit does, and only once the menu would not fit the screen it is being
/// drawn on. So the defect has no code to inspect and no state to assert;
/// the only thing that distinguishes the good case from the bad one is a
/// number of points. This file measures that number instead of looking at
/// it: `NSAttributedString.size()` in the menu's own font, plus the chrome
/// AppKit puts around a title, against a width budget.
///
/// **What it does not cover.** A persona's *name* comes out of the user's
/// `personas.json` and can be any length at all; checking ours against a
/// budget says nothing about theirs, and nothing here truncates theirs
/// either. Checklist item 11 stays a human's.
@MainActor
@Suite
struct PersonaMenuWidthTests {
    /// The narrowest display this project is willing to look right on, in
    /// logical points.
    ///
    /// ⚠️ **A policy number, not a measurement.** Nothing was surveyed to
    /// arrive at it; it is the width a 1280×800 default-scaled Mac display
    /// reports, chosen because it is the narrowest still in use here. If a
    /// narrower one starts mattering, change this number -- the test then
    /// says whether the strings still fit, which is the whole reason it is
    /// a named constant instead of being folded into the budget.
    static let narrowestSupportedScreenWidth: CGFloat = 1280

    /// Item 3's own words: "或者菜单宽得跨过半个屏幕" is the failure.
    static let budget = narrowestSupportedScreenWidth / 2

    private let archer = Persona(key: "archer", name: "Archer")
    private let target = PersonaMenuTargetStub()

    private static let menuFont = NSFont.menuFont(ofSize: 0)

    private static func width(_ title: String) -> CGFloat {
        NSAttributedString(string: title, attributes: [.font: menuFont]).size().width
    }

    /// Every submenu the role item can produce, between them naming every
    /// string it can show.
    ///
    /// Two are needed rather than one because "nothing has reported the
    /// list" and "the list is empty" cannot both be on screen, and the
    /// point of the sweep is that no string gets left out of it.
    private func allSubmenus() throws -> [NSMenu] {
        let waiting = PersonaState(key: "archer", name: "Archer", deviated: true,
                                   hostClass: .unknown, agentPresent: false)
        let cold = PersonaState(key: nil, name: nil, deviated: false,
                                hostClass: .cold, agentPresent: true)
        return [
            try #require(PersonaMenu.makeItem(
                state: waiting, shielded: true, personas: [archer],
                personasKnown: false, target: target).submenu),
            try #require(PersonaMenu.makeItem(
                state: cold, shielded: false, personas: [],
                personasKnown: true, target: target).submenu),
            // Built pointing at nothing, which is a different menu and has
            // a sentence of its own -- left out, the sweep would not know
            // that string exists.
            try #require(PersonaMenu.makeItem(
                state: cold, shielded: false, personas: [],
                personasKnown: true, target: nil).submenu),
        ]
    }

    // MARK: The instrument

    /// What AppKit adds around a title: the image column, the tick column,
    /// the padding, the submenu arrow.
    ///
    /// Calibrated off a real `NSMenu` rather than written down, because a
    /// number written down here is a number that stops being true when the
    /// system draws menus differently -- and it would stop being true
    /// silently, in the lenient direction.
    private func chrome(of menu: NSMenu) throws -> CGFloat {
        let widest = menu.items.map { Self.width($0.title) }.max() ?? 0
        let total = menu.size.width
        // Guard the instrument: a zero here would make every budget check
        // below pass for the reason that nothing was measured at all.
        try #require(total > 0, "NSMenu.size gave nothing; this whole file would be vacuous")
        try #require(total > widest, "menu is narrower than its own widest title")
        return total - widest
    }

    @Test func theMenuFitsTheBudgetInTheLanguageThisMachineRunsIn() throws {
        for menu in try allSubmenus() {
            _ = try chrome(of: menu)
            #expect(menu.size.width <= Self.budget,
                    "menu is \(menu.size.width)pt wide, over the \(Self.budget)pt budget")
        }
    }

    // MARK: Every localization, not just this one

    /// The strings are translated, and a translation is where the long one
    /// comes from. Running the app in English and calling that a width check
    /// measures the shortest case and reports on all of them.
    @Test func everyLocalizationOfEveryRowFitsTheBudget() throws {
        let tables = try Self.localizationTables()
        try #require(tables.count >= 2,
                     "only \(tables.count) localization(s) found; the sweep would be one language wide")

        // Recovering the key from a title that is already translated: the
        // keys are the English text, so the Base table's keys serve as
        // themselves and every other table gives a value -> key map.
        var keyOf: [String: String] = [:]
        for (_, table) in tables {
            for (key, value) in table {
                keyOf[value] = key
                keyOf[key] = key
            }
        }

        var checked = 0
        var translated = 0
        for menu in try allSubmenus() {
            let chrome = try chrome(of: menu)

            for item in menu.items where !item.isSeparatorItem {
                // The persona's own name is the user's, not ours, and is
                // deliberately out of scope -- see the type's comment.
                if item.title == archer.name { continue }

                let key = try #require(
                    keyOf[item.title],
                    """
                    the row "\(item.title)" traces back to no localization key, so this \
                    sweep is blind to it. Either it is a new string that needs one, or \
                    this exclusion list needs it named.
                    """)

                for (localization, table) in tables {
                    // A missing translation falls back to the key at
                    // runtime too, so measuring the key is right -- but a
                    // sweep where *every* lookup fell back would be a sweep
                    // of one language wearing the names of several, and it
                    // would be green. `translated` below is what refuses
                    // that.
                    let text = table[key] ?? key
                    if text != key { translated += 1 }

                    let total = Self.width(text) + chrome
                    #expect(total <= Self.budget,
                            """
                            \(localization): "\(text)" needs \(total)pt, \
                            over the \(Self.budget)pt budget
                            """)
                    checked += 1
                }
            }
        }

        // A sweep that swept nothing is a green that means nothing.
        #expect(checked >= 10, "only \(checked) string/localization pairs were measured")
        #expect(translated >= 5,
                """
                only \(translated) of \(checked) pairs were an actual translation -- \
                the rest fell back to the English key, so this measured one language \
                and reported on \(tables.count)
                """)
    }

    /// Every `Localizable.strings` the app ships, keyed by localization.
    private static func localizationTables() throws -> [(String, [String: String])] {
        let bundle = Bundle(for: RoleLibraryEditor.self)
        return bundle.localizations.compactMap { localization in
            guard let url = bundle.url(forResource: "Localizable",
                                       withExtension: "strings",
                                       subdirectory: nil,
                                       localization: localization),
                  let table = NSDictionary(contentsOf: url) as? [String: String]
            else { return nil }
            return (localization, table)
        }
    }
}
