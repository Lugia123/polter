import Foundation
import Testing
@testable import Ghostty

/// `appearance` in the `.json` is the system's, not Polter's own windows'
/// (task 1198).
struct ShotAppearanceTests {
    @Test func onlyTheSystemsDarkIsDark() {
        #expect(ShotAppearance.name(interfaceStyle: "Dark") == "dark")
        #expect(ShotAppearance.name(interfaceStyle: "dark") == "dark")
        // Light is the setting being absent; anything else is not dark.
        #expect(ShotAppearance.name(interfaceStyle: nil) == "light")
        #expect(ShotAppearance.name(interfaceStyle: "") == "light")
        #expect(ShotAppearance.name(interfaceStyle: "Light") == "light")
        #expect(ShotAppearance.name(interfaceStyle: "Darkish") == "light")
    }

    @Test func theSystemsAnswerIsOneOfTheTwoAndFollowsTheGlobalSetting() {
        #expect(["light", "dark"].contains(ShotAppearance.system))
        #expect(ShotAppearance.system == ShotAppearance.name(interfaceStyle: ShotAppearance.systemInterfaceStyle()))
        // Read from the setting itself: what a person would read with
        // `defaults read -g AppleInterfaceStyle`.
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[ShotAppearance.key] as? String
        #expect(ShotAppearance.system == ShotAppearance.name(interfaceStyle: global))
    }
}
