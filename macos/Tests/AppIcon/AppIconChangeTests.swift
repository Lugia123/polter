import Testing
@testable import Ghostty

/// Applying the app icon does only what would change something (task 1873).
@Suite
struct AppIconChangeTests {
    /// The configuration reload every launch does, and every reload after:
    /// the same official icon, a bundle without a custom one. Nothing.
    @Test func theSameIconAgainIsNothing() {
        #expect(AppIconChange.of(want: String?.none, stored: nil, bundleHasCustomIcon: false) == .nothing)
        #expect(AppIconChange.of(want: "glass", stored: "glass", bundleHasCustomIcon: true) == .nothing)
    }

    /// A different icon is all of it.
    @Test func aDifferentIconIsEverything() {
        let all = AppIconChange(defaults: true, bundle: true)
        #expect(AppIconChange.of(want: "glass", stored: nil, bundleHasCustomIcon: false) == all)
        #expect(AppIconChange.of(want: String?.none, stored: "glass", bundleHasCustomIcon: true) == all)
        #expect(AppIconChange.of(want: "paper", stored: "glass", bundleHasCustomIcon: true) == all)
    }

    /// The defaults remember an icon the bundle does not carry: a new copy
    /// of the app was put in place. The bundle is set again, and only it.
    @Test func aBundleThatLostItsIconIsGivenItAgain() {
        let bundle = AppIconChange(defaults: false, bundle: true)
        #expect(AppIconChange.of(want: "glass", stored: "glass", bundleHasCustomIcon: false) == bundle)
        // And one that still has a custom icon when the official is wanted.
        #expect(AppIconChange.of(want: String?.none, stored: nil, bundleHasCustomIcon: true) == bundle)
    }
}
