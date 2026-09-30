import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

/// The form's write, end to end, in the test host (settings.md §7.2-7.3):
/// a value goes into the config file this process loaded, the app reloads
/// it, the row shows it with its dot, an invalid value writes nothing and
/// says why, and restoring the default deletes the line.
///
/// ⚠️ **It writes a real file.** The test host is started on a config file
/// of its own under a temporary directory (`tools/mac-xctest-run.sh` sets
/// `GHOSTTY_CONFIG_PATH`), and since #967 that is the file the core writes.
/// The test refuses to write anything unless the form's main file is that
/// same temporary file -- so a regression that pointed the form back at the
/// person's own config fails here before it could change a byte of it.
///
/// ⚠️ **More than one test host can run it at once.** xcodebuild's parallel
/// testing starts several clones of the host on the one config file, and a
/// run was seen with this suite in two of them together (pids 95052 and
/// 95084): each read the other's write as its own starting point. So the
/// write is serialized across processes with an `flock` beside the file.
@MainActor
@Suite(.serialized)
struct ConfigFormWriteTests {
    private func canonical(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Let the reload that `set` asked for arrive (it comes back through
    /// the app's config-change action).
    private func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func appFontSize(_ ghostty: Ghostty.App) -> Float? {
        guard let cfg = ghostty.config.config else { return nil }
        var v: Float = 0
        let key = "font-size"
        return ghostty_config_get(cfg, &v, key, UInt(key.lengthOfBytes(using: .utf8))) ? v : nil
    }

    @Test func aValueIsWrittenReloadedMarkedRefusedAndRestored() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let ghostty = delegate.ghostty
        let host = try #require(ghostty.configPath, "the test host must run on a config file of its own")
        // Taken before the first read, not just the first write: another
        // host process may be holding the file in a state it made on
        // purpose (the config-error test below writes a broken line).
        let lock = open(host + ".form-write-test.lock", O_CREAT | O_RDWR, 0o600)
        try #require(lock >= 0)
        flock(lock, LOCK_EX)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let model = GeneralModel()
        model.reloadForm()
        let form = try #require(model.form)

        // The guard: only ever this process's own temporary file.
        try #require(canonical(form.main) == canonical(host), "form writes \(form.main), host reads \(host)")
        let temporary = [canonical(NSTemporaryDirectory()), "/private/tmp/", "/tmp/"]
        try #require(temporary.contains { canonical(host).hasPrefix($0) }, "\(host) is not a temporary file")
        #expect(model.writesAllowed)

        let url = URL(fileURLWithPath: host)
        let before = (try? Data(contentsOf: url)) ?? Data()
        defer {
            // Put the file back the way the run found it.
            try? before.write(to: url)
            ghostty.reloadConfig()
        }
        func item() -> ConfigForm.Item? { model.form?.items.first { $0.key == "font-size" } }
        let defaultValue = try #require(item()?.default)
        let newValue = defaultValue == "17" ? "18" : "17"

        // 1. A value goes into the file, after what was there, byte for byte.
        model.set("font-size", newValue)
        #expect(model.fieldErrors["font-size"] == nil)
        let written = try Data(contentsOf: url)
        #expect(written.starts(with: before), "the lines already there were changed")
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("# --- 由 Polter 设置窗口写入，可以手改 ---"))
        #expect(text.contains("font-size = \(newValue)"))

        // 2. The app reloaded it.
        settle { appFontSize(ghostty) == Float(newValue) }
        #expect(appFontSize(ghostty) == Float(newValue))

        // 3. The row shows it, with its dot, from the main file.
        let row = try #require(item())
        #expect(row.value == newValue)
        #expect(row.source.kind == .main)
        #expect(ConfigFormRules.differsFromDefault(row))
        #expect(ConfigFormRules.canRestoreDefault(row))

        // The first write of the run kept a copy of the file as it was.
        let backup = try #require(model.form?.backup)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == before)

        // 4. An invalid value writes nothing and says why.
        model.set("font-size", "not a size")
        #expect(model.fieldErrors["font-size"] != nil)
        #expect(try Data(contentsOf: url) == written)
        #expect(item()?.value == newValue)

        // 5. Restoring the default deletes the line.
        model.set("font-size", nil)
        #expect(model.fieldErrors["font-size"] == nil)
        let restored = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!restored.contains("font-size ="))
        #expect(item()?.value == defaultValue)
        #expect(item().map(ConfigFormRules.differsFromDefault) == false)
        settle { appFontSize(ghostty) == Float(defaultValue) }
        #expect(appFontSize(ghostty) == Float(defaultValue))
    }

    // MARK: Refusals (#986)

    /// A refusal is shown under its control while the person is still at
    /// that field, and is gone once the form is read for another reason: the
    /// window coming forward, a reload, another group. Before #986 it was
    /// still there after a reload and choosing the group again.
    @Test func aRefusalIsGoneOnceTheFormIsReadAgain() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let host = try #require(delegate.ghostty.configPath)
        let temporary = [canonical(NSTemporaryDirectory()), "/private/tmp/", "/tmp/"]
        try #require(temporary.contains { canonical(host).hasPrefix($0) }, "\(host) is not a temporary file")
        let lock = open(host + ".form-write-test.lock", O_CREAT | O_RDWR, 0o600)
        try #require(lock >= 0)
        flock(lock, LOCK_EX)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let url = URL(fileURLWithPath: host)
        let before = (try? Data(contentsOf: url)) ?? Data()

        let model = GeneralModel()
        model.reloadForm()
        let form = try #require(model.form)
        try #require(canonical(form.main) == canonical(host))
        model.select(.font)

        // Refused, and still shown after the write's own read.
        model.set("font-size", "not a size")
        #expect(model.fieldErrors["font-size"] != nil)
        // The window comes forward, or the configuration is reloaded.
        model.reloadForm()
        #expect(model.fieldErrors["font-size"] == nil)

        // Refused again, then another group and back.
        model.set("font-size", "not a size")
        #expect(model.fieldErrors["font-size"] != nil)
        model.select(.appearance)
        model.select(.font)
        #expect(model.fieldErrors["font-size"] == nil)

        // A refused value writes nothing.
        #expect(((try? Data(contentsOf: url)) ?? Data()) == before)
    }

    // MARK: Config errors (§7)

    /// End to end: a bad line in the file this process loaded, a reload,
    /// and the settings window opens at General › Advanced. Left open and
    /// moved to another group, the next reload does not move it back.
    @Test func aConfigErrorOpensTheWindowAtAdvancedAndThenStaysPut() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let ghostty = delegate.ghostty
        let host = try #require(ghostty.configPath)
        let temporary = [canonical(NSTemporaryDirectory()), "/private/tmp/", "/tmp/"]
        try #require(temporary.contains { canonical(host).hasPrefix($0) }, "\(host) is not a temporary file")

        let url = URL(fileURLWithPath: host)
        let lock = open(host + ".form-write-test.lock", O_CREAT | O_RDWR, 0o600)
        try #require(lock >= 0)
        flock(lock, LOCK_EX)
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let before = (try? Data(contentsOf: url)) ?? Data()
        let settings = SettingsWindowController.shared
        settings.window?.close()
        defer {
            try? before.write(to: url)
            ghostty.reloadConfig()
            settle { ghostty.config.errors.isEmpty }
            settings.window?.close()
        }
        #expect(!settings.isOpen)

        var broken = before
        broken.append(Data("\nfont-size = not-a-size\n".utf8))
        try broken.write(to: url)
        ghostty.reloadConfig()
        settle { settings.isOpen }
        #expect(!ghostty.config.errors.isEmpty)
        #expect(settings.shown?.section == .general)
        #expect(settings.shown?.group == .advanced)

        settings.selectGeneralGroup(.about)
        ghostty.reloadConfig()
        settle { false }  // three seconds for the reload and its follow-up to run out
        #expect(settings.shown?.section == .general)
        #expect(settings.shown?.group == .about)
    }

    @Test func errorsWithTheWindowClosedOpenItAtAdvanced() {
        #expect(SettingsRules.onConfigChanged(errorCount: 2, windowOpen: false) == .open(.general(.advanced)))
        #expect(SettingsRules.onConfigChanged(errorCount: 2, windowOpen: false) == .open(SettingsRoute(section: .general, item: "advanced")))
    }

    /// Open, it follows in place: a reload the form caused must not take
    /// the person away from the field they are in.
    @Test func anOpenWindowIsRefreshedNotMoved() {
        #expect(SettingsRules.onConfigChanged(errorCount: 2, windowOpen: true) == .refresh)
        #expect(SettingsRules.onConfigChanged(errorCount: 0, windowOpen: true) == .refresh)
    }

    @Test func noErrorsAndNoWindowIsNothing() {
        #expect(SettingsRules.onConfigChanged(errorCount: 0, windowOpen: false) == .nothing)
    }
}
