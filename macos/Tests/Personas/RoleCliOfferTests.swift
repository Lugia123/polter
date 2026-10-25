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

    /// Task 1744: a CLI whose adapter says its program is not here is not
    /// offered; one that did not say is.
    @Test func aCliWhoseProgramIsMissingIsNotOffered() throws {
        let read = try #require(AgentCliSnapshot(json: """
            {"stale":false,"refreshing":false,"clis":[
              {"key":"antigravity","label":"Antigravity","bin":"agy","error":null,"inventory":{"installed":true}},
              {"key":"claude-code","label":"Claude Code","bin":"claude","error":null,"inventory":{"installed":false}},
              {"key":"silent","label":"Silent","bin":"s","error":null,"inventory":{}}]}
            """))
        let offered = RoleCliOffer.available(read)
        #expect(offered == ["antigravity", "silent"])
    }

    // MARK: - The person's own (task 2156 v5)

    private let withOwn = """
        {"stale":false,"refreshing":false,"clis":[
          {"key":"claude-code","label":"Claude Code","bin":"claude","error":null,"inventory":{"installed":true}},
          {"key":"codex","label":"Codex","bin":"codex","error":null,"inventory":{"installed":false}}],
         "own":[
          {"key":"claude-deepseek-flash","name":"Claude · DeepSeek flash","base":"claude-code","roles":["polter-supervisor"]},
          {"key":"over-codex","name":"Over Codex","base":"codex","roles":[]}]}
        """

    /// **One of the person's own stands as its base stands** (task 2156 v5):
    /// the one over the CLI that is here is offered, the one over a CLI
    /// whose program is missing is not -- offered, it would be a row that
    /// answers "no adapter" when clicked.
    @Test func thePersonsOwnStandAsTheirBaseDoes() throws {
        let read = try #require(AgentCliSnapshot(json: withOwn))
        #expect(RoleCliOffer.available(read) == ["claude-code", "claude-deepseek-flash"])
    }

    /// Its name reaches the menu, not the key (task 2156 v5): the row says
    /// "Claude · DeepSeek flash", which is what the person called it.
    @Test func anOwnCliIsNamedByNameAndKnownByItsKey() throws {
        let read = try #require(AgentCliSnapshot(json: withOwn))
        #expect(read.label(for: "claude-deepseek-flash") == "Claude · DeepSeek flash")
        #expect(read.label(for: "claude-code") == "Claude Code")
        #expect(read.label(for: "nobody") == "nobody")
        #expect(read.known("claude-deepseek-flash"))
        #expect(!read.known("nobody"))
        #expect(read.own("claude-deepseek-flash")?.ticked("polter-supervisor") == true)
        #expect(read.own("claude-deepseek-flash")?.ticked("polter-tester") == false)
    }

    /// Where it stands is its base's answer, one hop: not a third thing the
    /// page has to know about. The base whose plugin is off holds it back
    /// too, and the base nobody manages is no plugin for it as well.
    @Test func anOwnCliStandsWhereItsBaseStands() throws {
        let read = try #require(AgentCliSnapshot(json: """
            {"stale":false,"refreshing":false,"clis":[],
             "held_back":[{"key":"codex","label":"Codex","why":"plugin_off"}],
             "own":[
              {"key":"over-claude","name":"Over Claude","base":"claude-code","roles":[]},
              {"key":"over-codex","name":"Over Codex","base":"codex","roles":[]}]}
            """))
        #expect(read.standing("over-claude") == .noPlugin)
        #expect(read.standing("over-codex") == .pluginOff(label: "Codex"))
    }

    /// A snapshot from a core before this field is not one with no own CLIs,
    /// and one that has never been read offers everything it is given.
    @Test func anAnswerWithNoOwnFieldIsAnEmptyOneNotABrokenOne() throws {
        let old = try #require(AgentCliSnapshot(json: #"{"stale":false,"refreshing":false,"clis":[]}"#))
        #expect(old.own.isEmpty)
        #expect(RoleCliOffer.available(old) == [])
        #expect(RoleCliOffer.available(AgentCliSnapshot()) == nil)
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
