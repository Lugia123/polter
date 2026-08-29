# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

## Checking Swift when `swiftlint` is not installed

`swiftc -typecheck -target arm64-apple-macos13.0` on the files you changed.
Name the deployment target: without it, an API that only exists on macOS 14
type-checks and then fails to run on the version this app supports.

**Do not run it over all of `macos/Sources` and read the error count.** The
tree has long-standing errors -- a parse error in `Ghostty.Shell.swift`, and
unresolved SPM members in `AppDelegate.swift` -- and a parse error stops the
compiler before it checks the files after it. So "26 errors, same as the
baseline" is what you get whether your own files are clean or broken, and it
looks exactly like having verified something. Type-check the directory you
touched, on its own, where the count starts at zero and can move.

`swiftc -typecheck` passing is also not the app building. Only `zig build`
(with the app bundle, i.e. without `-Demit-macos-app=false`) compiles the
Swift the way the app does; a change can type-check, pass tests, and still
fail there.

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`
