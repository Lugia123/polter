import AppKit
import Testing
@testable import Ghostty

/// #1670: a role's row offers only the CLIs the core found an adapter for.
/// The Windows host's `roles::cli_offer` tests carry the same cases.
struct RoleCliOfferTests {
    private let both = ["claude-code", "codex"]

    /// The official roles as they ship: Codex's plugin is off, so its
    /// adapter is not found, and the row starts Claude Code with no
    /// submenu -- saying which, so the core is not left to choose again.
    @Test func aRoleForTwoWithOnlyOneHereStartsThatOne() {
        #expect(RoleCliOffer.of(configured: both, available: ["claude-code", "gemini"]) == .only("claude-code"))
        #expect(RoleCliOffer.of(configured: both, available: ["codex"]) == .only("codex"))
    }

    @Test func bothHereIsAChoiceInTheRolesOrder() {
        #expect(RoleCliOffer.of(configured: both, available: ["codex", "claude-code"]) == .choose(both))
        #expect(RoleCliOffer.of(configured: ["codex", "claude-code", "gemini"], available: ["gemini", "codex"])
                == .choose(["codex", "gemini"]))
    }

    /// Never read is not "none here": everything set up is offered, as
    /// before #1670.
    @Test func notReadYetOffersEverythingSetUp() {
        #expect(RoleCliOffer.of(configured: both, available: nil) == .choose(both))
        #expect(RoleCliOffer.of(configured: ["codex"], available: nil) == .role)
    }

    /// None of them here, one set up, or none set up: the row carries the
    /// key and the core decides -- an agent in the terminal wears the role
    /// without starting anything.
    @Test func otherwiseTheRowCarriesTheKeyAlone() {
        #expect(RoleCliOffer.of(configured: both, available: []) == .role)
        #expect(RoleCliOffer.of(configured: both, available: ["gemini"]) == .role)
        #expect(RoleCliOffer.of(configured: ["codex"], available: []) == .role)
        #expect(RoleCliOffer.of(configured: ["codex"], available: ["codex"]) == .role)
        #expect(RoleCliOffer.of(configured: [], available: ["codex"]) == .role)
    }

    @Test func aSnapshotNeverReadIsNotAnEmptyOne() throws {
        #expect(RoleCliOffer.available(AgentCliSnapshot()) == nil)
        let empty = try #require(AgentCliSnapshot(json: #"{"stale":false,"refreshing":false,"clis":[]}"#))
        #expect(RoleCliOffer.available(empty) == [])
        // An adapter whose inventory failed was still found: it can start.
        let read = try #require(AgentCliSnapshot(json: """
            {"stale":false,"refreshing":true,"clis":[
              {"key":"claude-code","label":"Claude Code","bin":"claude","error":null,"inventory":{"installed":true}},
              {"key":"codex","label":"Codex","bin":"codex","error":"timed out","inventory":null}]}
            """))
        #expect(RoleCliOffer.available(read) == ["claude-code", "codex"])
    }

    // MARK: - The row

    private final class Target: NSObject {
        @objc func pick(_ sender: NSMenuItem) {}
    }

    @MainActor private func row(_ offer: RoleCliOffer, enabled: Bool = true, target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: "Duo", action: nil, keyEquivalent: "")
        offer.apply(
            to: entry,
            key: "duo",
            labels: ["claude-code": "Claude Code", "codex": "Codex"],
            action: #selector(Target.pick(_:)),
            target: target,
            enabled: enabled)
        return entry
    }

    @Test @MainActor func oneHereIsOneRowThatNamesIt() {
        let entry = row(.only("claude-code"))
        #expect(entry.submenu == nil)
        #expect(entry.action == #selector(Target.pick(_:)))
        #expect(entry.representedObject as? String == "duo,claude-code")
    }

    @Test @MainActor func theKeyAloneIsOneRow() {
        let entry = row(.role)
        #expect(entry.submenu == nil)
        #expect(entry.action == #selector(Target.pick(_:)))
        #expect(entry.representedObject as? String == "duo")
    }

    @Test @MainActor func aChoiceIsASubmenuOfTheRowsHere() throws {
        let target = Target()
        let entry = row(.choose(["codex", "gemini"]), enabled: false, target: target)
        // The row itself opens the list (AppKit gives it `submenuAction:`);
        // it never picks.
        #expect(entry.action != #selector(Target.pick(_:)))
        let sub = try #require(entry.submenu)
        #expect(sub.autoenablesItems == false)
        // A key with no label is shown as itself.
        #expect(sub.items.map(\.title) == ["Codex", "gemini"])
        #expect(sub.items.map { $0.representedObject as? String } == ["duo,codex", "duo,gemini"])
        #expect(sub.items.allSatisfy { $0.action == #selector(Target.pick(_:)) && $0.target === target })
        #expect(sub.items.allSatisfy { !$0.isEnabled })
    }

    /// Applied twice, only the last one shows: no submenu is left behind.
    @Test @MainActor func applyingAgainReplacesTheSubmenu() {
        let entry = row(.choose(["claude-code", "codex"]))
        RoleCliOffer.only("codex").apply(
            to: entry, key: "duo", labels: [:], action: #selector(Target.pick(_:)), target: nil, enabled: true)
        #expect(entry.submenu == nil)
        #expect(entry.representedObject as? String == "duo,codex")
    }
}
