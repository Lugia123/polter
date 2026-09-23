import AppKit
import Testing
@testable import Ghostty

/// Covers `MentionMenu` -- the direct-mentions switch, built without an app,
/// a window or a screen.
@MainActor
@Suite
struct MentionMenuTests {
    private let target = MentionMenuTargetStub()

    // MARK: Scope

    /// §6: the switch belongs to a supervisor. On any other terminal it is
    /// not a disabled row, it is a row about nothing -- so it is not on
    /// screen at all.
    @Test func onATerminalThatIsNotASupervisorTheSwitchIsNotThere() {
        let item = MentionMenu.makeItem(isSupervisor: false, allowed: false, target: target)
        #expect(item.isHidden)
        #expect(!item.isEnabled)
    }

    /// The contrast, without which the assertion above would also hold for a
    /// switch that is never shown to anybody.
    @Test func onASupervisorItIsThereAndClickable() {
        let item = MentionMenu.makeItem(isSupervisor: true, allowed: false, target: target)
        #expect(!item.isHidden)
        #expect(item.isEnabled)
        #expect(item.target === target)
        #expect(item.action == #selector(MentionMenuTarget.togglePoltergeistDirectMentions(_:)))
    }

    // MARK: State

    /// Off is the default (§6), and off has to read differently from on --
    /// otherwise the only way to find out whether the last click landed is
    /// to click again.
    @Test func theTickSaysWhichModeIsRunning() {
        #expect(MentionMenu.makeItem(isSupervisor: true, allowed: false, target: target).state == .off)
        #expect(MentionMenu.makeItem(isSupervisor: true, allowed: true, target: target).state == .on)
    }

    /// Hidden is about scope, not about the mode: a supervisor with the
    /// switch off still has the switch.
    @Test func aSupervisorWithItOffStillHasIt() {
        let item = MentionMenu.makeItem(isSupervisor: true, allowed: false, target: target)
        #expect(!item.isHidden)
        #expect(item.state == .off)
    }

    // MARK: The menu bar's copy

    /// The nib's item is filled in rather than replaced, and `configure` has
    /// to leave it in exactly the state `makeItem` would have produced --
    /// otherwise the menu bar is a fourth copy again, which is the defect
    /// this builder exists to prevent.
    @Test func fillingInTheNibsItemGivesTheSameItem() {
        let made = MentionMenu.makeItem(isSupervisor: true, allowed: true, target: target)

        let fromNib = NSMenuItem(title: "whatever was in the nib", action: nil, keyEquivalent: "")
        MentionMenu.configure(fromNib, isSupervisor: true, allowed: true, target: target)

        #expect(fromNib.title == made.title)
        #expect(fromNib.identifier == made.identifier)
        #expect(fromNib.state == made.state)
        #expect(fromNib.isHidden == made.isHidden)
        #expect(fromNib.isEnabled == made.isEnabled)
        #expect(fromNib.action == made.action)
    }

    /// The menu bar's half of the wiring, through the object `AppDelegate`
    /// hands the nib's item to. A nib item nobody fills in keeps the nib's
    /// title and no action -- a dead row that reads like a feature never
    /// built -- so what is checked is that attaching it runs the builder.
    ///
    /// It is also the one place "off by default" goes through the real
    /// path rather than an argument the test chose: the terminal the menu bar
    /// reads is whatever the test host has focused, or none, and neither has
    /// ever been switched on -- so the tick must be off.
    @Test func theMenuBarsItemIsFilledByTheBuilderAndStartsOff() {
        let agents = NSMenu(title: "Agents")
        let role = NSMenuItem(title: "Role (beta)", action: nil, keyEquivalent: "")
        let fromNib = NSMenuItem(title: "whatever was in the nib", action: nil, keyEquivalent: "")
        agents.addItem(role)
        agents.addItem(fromNib)

        let bar = PersonaMenuBar()
        bar.attach(to: role)
        bar.attachMentions(to: fromNib)

        #expect(fromNib.identifier == MentionMenu.itemIdentifier)
        #expect(fromNib.action == #selector(MentionMenuTarget.togglePoltergeistDirectMentions(_:)))
        #expect(fromNib.title != "whatever was in the nib")
        #expect(fromNib.state == .off)

        // And re-filled when the Agents menu opens, not only at attach.
        fromNib.state = .mixed
        bar.menuNeedsUpdate(agents)
        #expect(fromNib.state == .off)
    }
}

/// Something for a built menu to point at. Same reason as
/// `PersonaMenuTargetStub`: `target == nil` is a state the builder may come
/// to treat specially, so a test that means "an ordinary menu" says so.
@MainActor
final class MentionMenuTargetStub: NSObject, MentionMenuTarget {
    private(set) var calls = 0

    func togglePoltergeistDirectMentions(_ sender: NSMenuItem) {
        calls += 1
    }
}
