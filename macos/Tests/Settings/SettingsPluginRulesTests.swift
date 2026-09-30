import Testing
@testable import Ghostty

/// Covers the Plugins section's rules (settings.md §5): the status dot,
/// "restart to apply", what is missing, which plugin a route selects, a
/// log's last lines, where a search goes, and reading the core's answer.
///
/// The dot's cases are a table the Windows host repeats in
/// `polter-settings-shell`, row for row, so that the two can be compared.
struct SettingsPluginRulesTests {
    // MARK: The dot (§5.1): ↻ > ○ > ◐ > ▲ > ●

    struct DotCase {
        var name: String
        var restartPending: Bool
        var enabled: Bool
        var missing: [String]
        var status: PluginCoreStatus?
        var expected: PluginDot
    }

    static let failing = PluginCoreStatus(key: "p", enabled: true, state: "backing_off", failures: 3, note: "it keeps exiting")
    static let feeding = PluginCoreStatus(key: "p", enabled: true, state: "feeding", failures: 0, note: "")

    static let dotCases: [DotCase] = [
        .init(name: "restart pending beats off", restartPending: true, enabled: false, missing: [], status: nil, expected: .restartPending),
        .init(name: "restart pending beats missing and failing", restartPending: true, enabled: true, missing: ["Webhook"], status: failing, expected: .restartPending),
        .init(name: "off beats failing: the core's note is never empty for a plugin that is off", restartPending: false, enabled: false, missing: [],
              status: .init(key: "p", enabled: false, note: "p is installed but switched off"), expected: .off),
        .init(name: "off beats missing", restartPending: false, enabled: false, missing: ["Webhook"], status: nil, expected: .off),
        .init(name: "missing beats failing", restartPending: false, enabled: true, missing: ["Webhook"], status: failing, expected: .missingConfig),
        .init(name: "running with failures is failing", restartPending: false, enabled: true, missing: [],
              status: .init(key: "p", enabled: true, state: "feeding", failures: 2), expected: .failing),
        .init(name: "on with a note is failing", restartPending: false, enabled: true, missing: [],
              status: .init(key: "p", enabled: true, note: "no copy of it is running"), expected: .failing),
        .init(name: "failures count only while running", restartPending: false, enabled: true, missing: [],
              status: .init(key: "p", enabled: true, state: "", failures: 5), expected: .on),
        .init(name: "running cleanly is on", restartPending: false, enabled: true, missing: [], status: feeding, expected: .on),
        .init(name: "no answer from the core: on, as the table says", restartPending: false, enabled: true, missing: [], status: nil, expected: .on),
    ]

    @Test(arguments: dotCases.indices)
    func theDot(_ i: Int) {
        let c = Self.dotCases[i]
        let dot = SettingsRules.pluginDot(
            restartPending: c.restartPending,
            enabled: c.enabled,
            missing: c.missing,
            status: c.status)
        #expect(dot == c.expected, "\(c.name)")
    }

    @Test func everyDotIsReachable() {
        let reached = Set(Self.dotCases.map { "\($0.expected)" })
        #expect(reached.count == PluginDot.allCases.count)
    }

    // MARK: Restart to apply

    @Test func onlyASaveWhileRunningWaitsForARestart() {
        #expect(!SettingsRules.pluginRestartPending(savedWhileRunning: false, atLaunch: 1, now: 2))
        #expect(SettingsRules.pluginRestartPending(savedWhileRunning: true, atLaunch: 1, now: 2))
    }

    @Test func savingTheLaunchValuesBackClearsIt() {
        #expect(!SettingsRules.pluginRestartPending(savedWhileRunning: true, atLaunch: 1, now: 1))
    }

    @Test func aPluginNotThereAtLaunchDiffersFromAnything() {
        #expect(SettingsRules.pluginRestartPending(savedWhileRunning: true, atLaunch: nil as Int?, now: 1))
    }

    // MARK: Missing

    static let requirements: [PluginRequirement] = [
        .init(name: "url", title: "Webhook", required: true, isFlag: false, defaultValue: nil),
        .init(name: "dir", title: "Folder", required: true, isFlag: false, defaultValue: "~/x"),
        .init(name: "quiet", title: "Quiet", required: true, isFlag: true, defaultValue: nil),
        .init(name: "note", title: "Note", required: false, isFlag: false, defaultValue: nil),
        .init(name: "token", title: "Token", required: true, isFlag: false, defaultValue: nil),
    ]

    @Test func missingNamesTheEmptyRequiredOnesInOrder() {
        #expect(SettingsRules.pluginMissing(Self.requirements, params: [:]) == ["Webhook", "Token"])
    }

    @Test func blankIsMissing() {
        #expect(SettingsRules.pluginMissing(Self.requirements, params: ["url": "  ", "token": "t"]) == ["Webhook"])
    }

    @Test func aDefaultCountsOnlyWhileUnset() {
        #expect(SettingsRules.pluginMissing(Self.requirements, params: ["url": "u", "token": "t"]) == [])
        #expect(SettingsRules.pluginMissing(Self.requirements, params: ["url": "u", "token": "t", "dir": ""]) == ["Folder"])
    }

    // MARK: Routes (§3.1)

    @Test func aRouteSelectsThePluginItNames() {
        #expect(SettingsRules.pluginToSelect(item: "b", current: "a", fresh: false, keys: ["a", "b"]) == "b")
    }

    @Test func aRouteWithNoneNamedKeepsAnOpenWindowsChoice() {
        #expect(SettingsRules.pluginToSelect(item: nil, current: "b", fresh: false, keys: ["a", "b"]) == "b")
        #expect(SettingsRules.pluginToSelect(item: "gone", current: "b", fresh: false, keys: ["a", "b"]) == "b")
    }

    @Test func aNewWindowOrAGoneChoiceTakesTheFirst() {
        #expect(SettingsRules.pluginToSelect(item: nil, current: "b", fresh: true, keys: ["a", "b"]) == "a")
        #expect(SettingsRules.pluginToSelect(item: nil, current: "gone", fresh: false, keys: ["a", "b"]) == "a")
        #expect(SettingsRules.pluginToSelect(item: nil, current: nil, fresh: true, keys: []) == nil)
    }

    // MARK: Log

    @Test func theLogIsItsLastTwentyLines() {
        let text = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = SettingsRules.logTail(text)
        #expect(tail.count == 20)
        #expect(tail.first == "line 6")
        #expect(tail.last == "line 25")
    }

    @Test func everyLineBreakEndsALine() {
        #expect(SettingsRules.logTail("a\r\nb\rc\nd") == ["a", "b", "c", "d"])
    }

    @Test func aShortOrEmptyLogIsAllOfIt() {
        #expect(SettingsRules.logTail("a\n\nb\n") == ["a", "", "b"])
        #expect(SettingsRules.logTail("") == [])
    }

    // MARK: Search (§2.3)

    @Test func aSearchStaysWhereItHasAMatch() {
        let next = SettingsRules.sectionForSearch("x", current: .plugins) { _ in true }
        #expect(next == .plugins)
    }

    @Test func aSearchGoesToTheFirstSectionWithAMatch() {
        let next = SettingsRules.sectionForSearch("x", current: .general) { $0 == .plugins || $0 == .projects }
        #expect(next == .projects)
    }

    @Test func anEmptyOrUnmatchedSearchGoesNowhere() {
        #expect(SettingsRules.sectionForSearch("  ", current: .general) { _ in true } == nil)
        #expect(SettingsRules.sectionForSearch("x", current: .general) { _ in false } == nil)
    }

    // MARK: The core's answer

    /// The shape `wire.writeResponse(.plugins)` writes: `state`, `cursor`
    /// and `failures` only while a copy runs, `note` only when non-empty.
    static let listJSON = """
        {"ok":true,"plugins":[
          {"key":"archive","name":"Archive","enabled":true,"wants":{"events":["chat"]},"params":[],
           "state":"backing_off","cursor":12,"failures":3,"note":"archive is backing off"},
          {"key":"ntfy","name":"ntfy","enabled":false,"params":[],
           "note":"ntfy is installed but switched off"},
          {"key":"quiet","name":"Quiet","enabled":true,"params":[],"state":"feeding","cursor":0,"failures":0}
        ]}
        """

    @Test func theCoresListIsReadByKey() throws {
        let list = try #require(PluginCoreStatus.parse(Self.listJSON))
        #expect(list.count == 3)
        #expect(list["archive"] == PluginCoreStatus(key: "archive", enabled: true, state: "backing_off", failures: 3, note: "archive is backing off"))
        #expect(list["ntfy"]?.running == false)
        #expect(list["ntfy"]?.enabled == false)
        #expect(list["quiet"]?.running == true)
        #expect(list["quiet"]?.note == "")
    }

    @Test func aRefusalOrNoiseIsNoAnswer() {
        #expect(PluginCoreStatus.parse(#"{"ok":false,"error":"x","plugins":[]}"#) == nil)
        #expect(PluginCoreStatus.parse("not json") == nil)
        #expect(PluginCoreStatus.parse(#"{"ok":true,"plugins":[]}"#) == [:])
    }

    /// The names `ghostty_app_plugin_configure` writes: `report.Started`'s
    /// tags in the core, pinned on that side by the test "configure answers
    /// with report.Started's tag names" in `src/App.zig`.
    @Test func startedNamesAreTheCoresTags() {
        #expect(PluginStarted(rawValue: "already_running") == .alreadyRunning)
        #expect(PluginStarted(rawValue: "started_now") == .startedNow)
        #expect(PluginStarted(rawValue: "not_started") == .notStarted)
        #expect(PluginStarted(rawValue: "subscribes_to_nothing") == .subscribesToNothing)
    }
}
