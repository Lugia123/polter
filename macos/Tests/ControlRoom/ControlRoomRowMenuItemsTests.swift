import AppKit
import Testing
@testable import Ghostty

/// The group row's menu as AppKit gets it, and the two questions it asks
/// (task 1660).
@MainActor
struct ControlRoomRowMenuItemsTests {
    private typealias Items = ControlRoomRowMenuItems

    /// Every key of the rule, top-level and in the submenus: a key the
    /// rule gains with nothing here to say for it is red here.
    static let keys = ControlRoomRowMenu.Item.allCases.map(\.rawValue)
    static let submenuKeys = Set(ControlRoomRowMenu.Item.allCases.flatMap { $0.submenu ?? [] }.map(\.rawValue))

    @Test func everyKeyHasATitleAndEveryTopLevelOneASymbol() {
        for key in Self.keys {
            #expect(Items.title(key) != nil, "\(key) has no title")
            if !Self.submenuKeys.contains(key) {
                #expect(Items.symbol(key) != nil, "\(key) has no symbol")
                #expect(NSImage(systemSymbolName: Items.symbol(key) ?? "", accessibilityDescription: nil) != nil,
                        "\(key)'s symbol is not one the system has")
            } else {
                #expect(Items.symbol(key) == nil)
            }
        }
        // Two keys never say the same thing.
        let titles = Self.keys.compactMap(Items.title)
        #expect(Set(titles).count == titles.count)
        #expect(Items.title("no_such_item") == nil)
    }

    @Test func theRulesEntriesBecomeLinesKeyForKey() {
        let state = ControlRoomRowMenu.State(archived: false, supervisor: .hooked, resumable: false, pinned: true, muted: false)
        let entries = ControlRoomRowMenu.entries(state)
        let lines = Items.lines(entries)
        #expect(lines.count == entries.count)
        #expect(lines.first == .item("jump_to_supervisor", submenu: nil))
        #expect(lines.contains(.item("unpin", submenu: nil)))
        #expect(lines.contains(.item("mute", submenu: ["mute_hour", "mute_tomorrow", "mute_forever"])))
        #expect(lines.filter { $0 == .separator }.count == entries.filter { $0 == .separator }.count)
    }

    @Test func theMenuIsTheLinesInOrderWithTheirSubmenus() {
        let lines: [Items.Line] = [
            .item("jump_to_supervisor", submenu: nil),
            .separator,
            .item("pin", submenu: nil),
            .item("mute", submenu: ["mute_hour", "mute_tomorrow", "mute_forever"]),
            .separator,
            .item("delete", submenu: nil),
        ]
        let menu = Items.menu(lines) { _ in }
        #expect(menu.items.count == 6)
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false, false, true, false])
        #expect(menu.items[0].representedObject as? String == "jump_to_supervisor")
        #expect(menu.items[3].submenu?.items.compactMap { $0.representedObject as? String }
            == ["mute_hour", "mute_tomorrow", "mute_forever"])
        // An item that opens a submenu does nothing itself: AppKit gives it
        // its own `submenuAction:`, not the action the items choose by.
        #expect(menu.items[3].action != menu.items[0].action)
        #expect(menu.items[2].submenu == nil)
    }

    @Test func choosingAnItemHandsItsKeyBack() {
        var chosen: [String] = []
        let menu = Items.menu([.item("rename", submenu: nil), .item("project", submenu: ["open_project"])]) { chosen.append($0) }
        menu.performActionForItem(at: 0)
        menu.items[1].submenu?.performActionForItem(at: 0)
        #expect(chosen == ["rename", "open_project"])
    }

    @Test func onlyDeleteIsRed() {
        let menu = Items.menu([.item("archive", submenu: nil), .item("delete", submenu: nil)]) { _ in }
        func red(_ item: NSMenuItem) -> Bool {
            (item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemRed
        }
        #expect(!red(menu.items[0]))
        #expect(red(menu.items[1]))
    }

    @Test func whatStandsAtTheRightGoesOnItsItem() {
        let menu = Items.menu([.item("unmute", submenu: nil), .item("pin", submenu: nil)],
                              trailing: { $0 == "unmute" ? "until 15:40" : nil }, choose: { _ in })
        if #available(macOS 14.0, *) {
            #expect(menu.items[0].badge?.stringValue == "until 15:40")
            #expect(menu.items[1].badge == nil)
        } else {
            #expect(menu.items[0].title.hasSuffix("until 15:40"))
        }
    }

    @Test func greyedIsOnlyWhatTheCallerSays() {
        let menu = Items.menu([.item("project", submenu: ["open_project", "save_project"])],
                              enabled: { $0 != "save_project" }, choose: { _ in })
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[0].submenu?.items.map(\.isEnabled) == [true, false])
    }

    // MARK: The questions

    @Test func archivingAnswersReturnWithArchiveAndEscapeWithCancel() {
        let q = ControlRoomGroupAlerts.archive(name: "web-app", supervisorRunning: true)
        // The first button is drawn at the right.
        #expect(q.alert.buttons.map(\.title) == ["Archive", "Cancel"])
        #expect(q.alert.buttons[q.act].title == "Archive")
        #expect(q.alert.buttons[q.cancel].title == "Cancel")
        #expect(q.alert.buttons[0].keyEquivalent == "\r")
        #expect(q.alert.buttons[1].keyEquivalent == "")
        #expect(!q.alert.buttons[0].hasDestructiveAction)
        #expect(q.alert.alertStyle == .informational)
        #expect(q.alert.accessoryView == nil)
        #expect(q.acted(.alertFirstButtonReturn))
        #expect(!q.acted(.alertSecondButtonReturn))
    }

    /// Delete Group at the left, Cancel at the right taking Return and
    /// Escape (design v21 `06`).
    @Test func deletingAnswersReturnAndEscapeWithCancel() {
        let q = ControlRoomGroupAlerts.delete(name: "notes", project: "notes",
                                              still: .init(supervisor: false, workers: 0, openTasks: 0))
        #expect(q.alert.buttons.map(\.title) == ["Cancel", "Delete Group"])
        #expect(q.alert.buttons[q.act].title == "Delete Group")
        #expect(q.alert.buttons[q.cancel].title == "Cancel")
        #expect(q.alert.buttons[q.cancel].keyEquivalent == "\r")
        #expect(q.alert.buttons[q.act].keyEquivalent == "")
        #expect(q.alert.buttons[q.act].hasDestructiveAction)
        #expect(q.acted(.alertSecondButtonReturn))
        #expect(!q.acted(.alertFirstButtonReturn))
        // Nobody and nothing left in it: no warning.
        #expect(q.alert.accessoryView == nil)
    }

    @Test func deletingAGroupWithPeopleInItShowsTheWarning() throws {
        let q = ControlRoomGroupAlerts.delete(name: "web-app", project: nil,
                                              still: .init(supervisor: true, workers: 2, openTasks: 4))
        let view = try #require(q.alert.accessoryView)
        #expect(view.accessibilityLabel()?.contains("3 members") == true)
        #expect(view.frame.width > 0 && view.frame.height > 0)
    }

    /// The delete question's icon is drawn, square; what it shows is in the
    /// poltertest pictures.
    @Test func theCautionIconIsSquare() {
        let icon = ControlRoomGroupAlerts.cautionIcon()
        #expect(icon.size.width > 0)
        #expect(icon.size.width == icon.size.height)
    }

    // MARK: Over a row

    private func click(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// Only the click that asks for a menu is the catcher's; every other
    /// one goes through to the row, which selects on it.
    @Test func onlyAMenuClickIsCaught() {
        typealias Catcher = ControlRoomRightClick.Catcher
        #expect(Catcher.isMenuClick(click(.rightMouseDown)))
        #expect(Catcher.isMenuClick(click(.leftMouseDown, .control)))
        #expect(!Catcher.isMenuClick(click(.leftMouseDown)))
        #expect(!Catcher.isMenuClick(click(.leftMouseDown, .command)))
        #expect(!Catcher.isMenuClick(click(.leftMouseUp, .control)))
        #expect(!Catcher.isMenuClick(nil))
    }
}
