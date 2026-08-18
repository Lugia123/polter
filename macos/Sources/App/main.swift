import AppKit
import Cocoa
import GhosttyKit

// Tell the core which language to speak, before it is initialized.
//
// The core translates through gettext, which reads `LANG` -- it knows
// nothing about `AppleLanguages`, the defaults key that decides what the
// menus are drawn in. Left alone the two disagree, and the result is a
// Chinese menu bar over an English command palette.
//
// Only set when the user has chosen a language. With nothing chosen, both
// sides follow the system on their own, which is already consistent.
//
// This must happen before `ghostty_init`: the core reads `LANG` once during
// initialization and falls back to Cocoa's idea of the locale only when the
// variable is absent. Setting it afterwards changes nothing.
if let language = AppLanguage.selected {
    setenv("LANG", language.posixLocale, 1)
    Ghostty.logger.info("app language=\(language.rawValue) LANG=\(language.posixLocale)")
} else {
    Ghostty.logger.info("app language follows the system")
}

// Initialize Ghostty global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Ghostty.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Polter failed to initialize! If you're executing Polter from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `ghostty +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `ghostty +boo`.
ghostty_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
