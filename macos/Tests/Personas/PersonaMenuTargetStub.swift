import AppKit
@testable import Ghostty

/// Something for a built menu to point at.
///
/// **Why the tests stopped passing `nil`.** They passed it because nothing
/// in them ever clicks, so who the rows point at looked like a detail. It
/// is not one: `target == nil` is now the fact that makes a row unclickable
/// (`PersonaMenu`, `actionable`), so a menu built with `nil` is a menu in
/// its "there is no terminal here" state -- and a test that meant to check
/// what the shield does to an ordinary menu would have been checking that
/// state instead, and passing.
@MainActor
final class PersonaMenuTargetStub: NSObject, PersonaMenuTarget {
    private(set) var personaCalls: [String?] = []

    func setPoltergeistPersona(_ sender: NSMenuItem) {
        personaCalls.append(sender.representedObject as? String)
    }
}
