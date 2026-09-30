import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

/// #979: "About Polter" is the About group of the settings window, and a
/// click in the General group list moves the breadcrumb with it.
@MainActor
@Suite(.serialized)
struct AboutAndBreadcrumbTests {
    /// The root view watches `SettingsModel`; the group lives in
    /// `GeneralModel`. A group change has to reach the model the root
    /// watches, or the breadcrumb stays on the old group (#974 C).
    @Test func choosingAGroupIsAChangeTheRootViewSees() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("about979-\(UUID().uuidString)")
        let model = SettingsModel(section: .general, library: RoleLibrary.shared, projects: ProjectsModel(store: ProjectStore(directory: dir)))
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        model.general.select(.advanced)
        #expect(changes >= 1)
        let before = changes
        model.general.select(.advanced)  // the same group again is no change
        #expect(changes == before)
    }

    /// The real menu action, end to end: one settings window, at General ›
    /// About, and no About window of its own.
    @Test func aboutPolterOpensTheAboutGroup() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let settings = SettingsWindowController.shared
        settings.window?.close()
        defer { settings.window?.close() }
        delegate.showAbout(nil)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        #expect(settings.isOpen)
        #expect(settings.shown?.section == .general)
        #expect(settings.shown?.group == .about)
        let title = settings.window?.title ?? "-"
        #expect(NSApp.windows.filter { $0.isVisible && $0.title == title }.count == 1)
    }
}
