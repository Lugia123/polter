import AppKit

/// Which language the app draws itself in.
///
/// macOS has no per-app language switch of its own: an app follows the
/// system, and the only lever is `AppleLanguages` in the app's own defaults,
/// which is read **once, at launch**. So switching writes the preference and
/// asks for a restart. There is no way to avoid that short of rebuilding
/// every menu and window in place, which trades a restart for a whole class
/// of bugs where half the interface has changed and half has not.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// The key macOS reads at launch. Writing it into our own defaults
    /// domain overrides the system language for this app alone.
    private static let defaultsKey = "AppleLanguages"

    /// Shown in its own language, never translated.
    ///
    /// A language menu that says "Chinese" to someone who cannot read
    /// English is no use, and one that says "英语" to someone who cannot
    /// read Chinese is no better. Every entry names itself.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// The locale to hand the core, which does its own translation through
    /// gettext and reads the environment rather than `AppleLanguages`.
    var posixLocale: String {
        switch self {
        case .english: return "en_US.UTF-8"
        case .simplifiedChinese: return "zh_CN.UTF-8"
        }
    }

    /// What the app will use next launch, or nil when it follows the system.
    static var selected: AppLanguage? {
        guard let languages = UserDefaults.standard.stringArray(forKey: defaultsKey),
              let first = languages.first else { return nil }

        // Matched by prefix: macOS normalises what it writes back, so a
        // stored "zh-Hans-CN" has to still count as Simplified Chinese.
        return AppLanguage.allCases.first { first.hasPrefix($0.rawValue) }
    }

    /// What the app is drawing itself in right now.
    ///
    /// Not the same question as `selected`: with nothing chosen the app
    /// follows the system, and the menu should still show a tick against
    /// whichever language that turned out to be.
    static var effective: AppLanguage? {
        if let selected { return selected }
        guard let current = Bundle.main.preferredLocalizations.first else { return nil }
        return AppLanguage.allCases.first { current.hasPrefix($0.rawValue) }
    }

    /// Choose a language for the next launch.
    ///
    /// Returns false when it was already the chosen one, so the caller can
    /// skip asking about a restart that would change nothing.
    @discardableResult
    static func select(_ language: AppLanguage) -> Bool {
        guard selected != language else { return false }
        UserDefaults.standard.set([language.rawValue], forKey: defaultsKey)
        return true
    }
}
