#!/usr/bin/env swift
// Type, press keys, click and drag in a macOS app under test -- the input half
// that `tools/mac-drive.sh` does not have (it can only screenshot, read menus
// and click top-level menu items).
//
//     swift tools/mac-hid.swift <pid> text <string>
//     swift tools/mac-hid.swift <pid> key <keycode> [cmd,shift,ctrl,opt]
//     swift tools/mac-hid.swift <pid> click|rclick|move <x> <y>
//     swift tools/mac-hid.swift <pid> drag <x1> <y1> <x2> <y2>
//     swift tools/mac-hid.swift <pid> menu <bar item> <item> [<submenu item>]
//
// Coordinates are global points, top-left origin, as CGWindowList reports
// window bounds. Needs Accessibility (for `menu`) and Post Event access,
// granted to the responsible process (the app owning this terminal).
//
// **Two channels, because each works for only part of the job** (measured
// 2026-09-26, #818/#832):
//
// - `CGEvent.postToPid` reaches exactly one process and never the user's,
//   but only **plain characters** arrive. Key equivalents (⌘W), Esc and every
//   mouse event -- with or without the window-number fields set -- do
//   nothing. `text` uses it.
// - `CGEvent.post(tap: .cghidEventTap)` works for everything, and it is the
//   real mouse and keyboard: it goes to whatever is under the pointer or in
//   front. So every HID action below checks first and refuses otherwise:
//   pointer actions require <pid> to be the frontmost app *and* its window
//   to be the topmost at that point (on top alone is not enough: clicking an
//   uncovered background window activates its app); keys and menus require
//   <pid> to be the frontmost app.
//   Nothing here raises the target: taking the user's focus is not a side
//   effect this tool may have.
//
// **`menu` exists because AX `click` on a nested, dynamically built submenu
// item returns success and does nothing** (Agents > 角色（beta）> 角色库…,
// three attempts; a top-level item like 关于 Polter opens fine). This opens
// the menus with the real pointer instead, reading each item's position from
// the target's own accessibility tree -- `AXUIElementCreateApplication(pid)`,
// by pid, never by process name -- so a menu that failed to open is a named
// error, not a click on whatever happened to be there.

import AppKit
import ApplicationServices
import Carbon
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write("mac-hid: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    die("usage: <pid> text|key|click|rclick|move|drag|menu ...")
}
let action = args[2]
let rest = Array(args.dropFirst(3))

// The guard mac-drive.sh has, for the same reason: an installed copy is the
// user's session.
guard let app = NSRunningApplication(processIdentifier: pid) else { die("no app with pid \(pid)") }
if let path = app.executableURL?.path, path.hasPrefix("/Applications/") {
    die("refusing to drive \(pid): \(path) is an installed copy, not a build under test")
}

func topOwner(_ p: CGPoint) -> (pid: Int, window: Int)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
        return (w[kCGWindowOwnerPID as String] as? Int ?? -1, w[kCGWindowNumber as String] as? Int ?? -1)
    }
    return nil
}

/// Pointer actions need both: the target in front, and its window on top at
/// that point. On top alone is not enough -- a click on an uncovered window
/// of a background app activates that app, which took the user's focus
/// (#832). So a background target is refused here, not raised.
func requireOwner(_ p: CGPoint) {
    requireFront()
    guard let o = topOwner(p) else { die("nothing on screen at \(p.x),\(p.y)") }
    guard o.pid == Int(pid) else {
        die("refusing: the window on top at \(p.x),\(p.y) is window \(o.window) of pid \(o.pid), not \(pid)")
    }
}

func requireFront() {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    guard front == pid else { die("refusing: pid \(front) is in front, not \(pid); this tool does not raise the target") }
}

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
        .post(tap: .cghidEventTap)
    usleep(30_000)
}

func point(_ i: Int) -> CGPoint {
    guard rest.count > i + 1, let x = Double(rest[i]), let y = Double(rest[i + 1]) else { die("expected <x> <y>") }
    return CGPoint(x: x, y: y)
}

// --- Accessibility: menu item positions, read off the target by pid. -------

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }

func center(_ e: AXUIElement) -> CGPoint? {
    var pos = CGPoint.zero, size = CGSize.zero
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    guard size.width > 0, size.height > 0 else { return nil }
    return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
}

/// The item called `name` in an open menu, waiting briefly for it to be
/// drawn. A zero size means "exists but not open", which is the state the
/// AX click silently fails in, so it is waited out rather than clicked.
func openItem(in parent: AXUIElement, _ name: String) -> (AXUIElement, CGPoint) {
    for _ in 0..<20 {
        for menu in children(parent) {
            for item in children(menu) where title(item) == name {
                if let c = center(item) { return (item, c) }
            }
        }
        usleep(100_000)
    }
    let seen = children(parent).flatMap { children($0).map(title) }.filter { !$0.isEmpty }
    die("no open menu item '\(name)' (open menu has: \(seen.joined(separator: " | ")))")
}

func runMenu() {
    guard (2...3).contains(rest.count) else { die("menu takes <bar item> <item> [<submenu item>]") }
    requireFront()
    guard AXIsProcessTrusted() else { die("Accessibility is not granted to the responsible process") }
    let axApp = AXUIElementCreateApplication(pid)
    guard let bar = attr(axApp, kAXMenuBarAttribute) else { die("pid \(pid) has no menu bar") }
    let barItem = children(bar as! AXUIElement).first { title($0) == rest[0] }
    guard let barItem, let barPoint = center(barItem) else { die("no menu bar item '\(rest[0])' on pid \(pid)") }

    mouse(.mouseMoved, barPoint); mouse(.leftMouseDown, barPoint); mouse(.leftMouseUp, barPoint)
    let (item, itemPoint) = openItem(in: barItem, rest[1])
    if rest.count == 2 {
        mouse(.mouseMoved, itemPoint); mouse(.leftMouseDown, itemPoint); mouse(.leftMouseUp, itemPoint)
        print("clicked \(rest[0]) > \(rest[1])")
        return
    }
    // Hover to open the submenu, then move sideways into it before going
    // down: a diagonal path crosses the parent's other rows and closes it.
    mouse(.mouseMoved, itemPoint)
    let (_, subPoint) = openItem(in: item, rest[2])
    mouse(.mouseMoved, CGPoint(x: subPoint.x, y: itemPoint.y))
    mouse(.mouseMoved, subPoint)
    mouse(.leftMouseDown, subPoint); mouse(.leftMouseUp, subPoint)
    print("clicked \(rest[0]) > \(rest[1]) > \(rest[2])")
}

switch action {
case "text":
    guard rest.count == 1 else { die("text takes one string") }
    // An input method (pinyin and the like) takes these events by keycode and
    // composes them: the terminal shows an underlined fragment and runs
    // nothing, which reads exactly like "typing does not work" (#832; the
    // user's source was com.apple.inputmethod.SCIM.ITABC). The input source
    // is one setting for the whole machine, so switching it would switch the
    // user's too. Refused here, naming the source, rather than typed badly.
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let prop = { (k: CFString) in
        Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, k)).takeUnretainedValue() as String
    }
    guard prop(kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String) else {
        die("refusing: the current input source is \(prop(kTISPropertyInputSourceID)), an input method; typed characters would be composed, not typed. It is a machine-wide setting, so this tool does not change it.")
    }
    for ch in rest[0] {
        // A newline has to be the Return key itself (keycode 36, which does
        // arrive by this channel): "\r" as the unicode string of some other
        // key is typed as a character and runs nothing.
        let isReturn = ch == "\n" || ch == "\r"
        let u = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: isReturn ? 36 : 0, keyDown: down)!
            if !isReturn { e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
            e.postToPid(pid)
            usleep(15_000)
        }
    }
    print("typed \(rest[0].count) character(s) into pid \(pid)")
case "key":
    guard let code = rest.first.flatMap({ CGKeyCode($0) }) else { die("key takes <keycode> [mods]") }
    var flags: CGEventFlags = []
    for m in (rest.count > 1 ? rest[1] : "").split(separator: ",") {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        case "opt": flags.insert(.maskAlternate)
        default: die("unknown modifier \(m)")
        }
    }
    requireFront()
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    print("pressed key \(code) in pid \(pid)")
case "click", "rclick", "move":
    let p = point(0)
    requireOwner(p)
    mouse(.mouseMoved, p)
    if action == "click" { mouse(.leftMouseDown, p); mouse(.leftMouseUp, p) }
    if action == "rclick" { mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right) }
    print("\(action) at \(p.x),\(p.y) in pid \(pid)")
case "drag":
    let a = point(0), b = point(2)
    requireOwner(a); requireOwner(b)
    mouse(.mouseMoved, a); mouse(.leftMouseDown, a)
    for i in 1...20 {
        let t = Double(i) / 20
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    mouse(.leftMouseUp, b)
    print("dragged \(a.x),\(a.y) -> \(b.x),\(b.y) in pid \(pid)")
case "menu":
    runMenu()
default:
    die("unknown action \(action)")
}
