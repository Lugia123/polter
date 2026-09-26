#!/usr/bin/env swift
// Save a macOS pasteboard before a GUI test and put it back afterwards,
// every item and every type, byte for byte.
//
//     swift tools/mac-pasteboard.swift save    <board> <dir>
//     swift tools/mac-pasteboard.swift restore <board> <dir>
//     swift tools/mac-pasteboard.swift compare <board> <dir>
//     swift tools/mac-pasteboard.swift selftest
//
// <board> is `general`, `selection` (the private board copy-on-select writes,
// `com.mitchellh.ghostty.selection`) or any other pasteboard name.
//
// **Why this exists.** A test instance of Polter shares both boards with the
// user's own copy: `general` is the whole machine's, and `selection` has the
// same name in every Polter. 2026-09-26 (#818) a drag-select test overwrote
// the user's selection board, and the cleanup put back the plain text it had
// remembered and lost the two HTML types it had not. Restoring "the string"
// is restoring one type out of four. So: every type, saved before the test
// touches anything, and a comparison that can say the restore did not happen.
//
// **What cannot be put back**: `changeCount`. A restore is a write, so the
// count goes up; anything that watches the count sees one more change. The
// saved count is recorded in the manifest so a report can say which it was.
//
// `compare` exits 1 on any difference and says which item and type differ.
// `selftest` is the floor under all of this, run on a pasteboard of its own
// (never `general` or `selection`): it saves a two-item, multi-type board,
// overwrites it the way a test would, restores, and requires equality -- and
// then does the same with the restore skipped and requires that `compare`
// fails. If the second half passes, the comparison cannot see a missing
// restore and the first half proves nothing.

import AppKit
import Foundation

struct Manifest: Codable {
    var name: String
    var changeCount: Int
    /// Types per item, in the board's own order.
    var items: [[String]]
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write("mac-pasteboard: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

func board(_ arg: String) -> NSPasteboard {
    switch arg {
    case "general": return .general
    case "selection": return NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    default: return NSPasteboard(name: .init(arg))
    }
}

/// A type name becomes a file name. Hex, because type names carry dots,
/// slashes and spaces ("NeXT TIFF v4.0 pasteboard type").
func fileName(_ type: String) -> String {
    type.utf8.map { String(format: "%02x", $0) }.joined() + ".bin"
}

/// What is on the board now, as (types, bytes) per item. A type whose data
/// cannot be read is recorded as empty data rather than dropped: dropping it
/// would make the manifest agree with a board that lost it.
func snapshot(_ pb: NSPasteboard) -> [[(String, Data)]] {
    (pb.pasteboardItems ?? []).map { item in
        item.types.map { t in (t.rawValue, item.data(forType: t) ?? Data()) }
    }
}

func save(_ pb: NSPasteboard, to dir: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.path) {
        die("\(dir.path) already exists; refusing to overwrite an earlier save")
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let snap = snapshot(pb)
    for (i, item) in snap.enumerated() {
        let d = dir.appendingPathComponent(String(i))
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        for (t, data) in item { try data.write(to: d.appendingPathComponent(fileName(t))) }
    }
    let m = Manifest(name: pb.name.rawValue, changeCount: pb.changeCount, items: snap.map { $0.map { $0.0 } })
    try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
    print("saved \(snap.count) item(s), \(snap.reduce(0) { $0 + $1.count }) type(s), changeCount=\(pb.changeCount) -> \(dir.path)")
}

func load(_ dir: URL) throws -> (Manifest, [[(String, Data)]]) {
    let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    let items = try m.items.enumerated().map { (i, types) in
        try types.map { t in (t, try Data(contentsOf: dir.appendingPathComponent(String(i)).appendingPathComponent(fileName(t)))) }
    }
    return (m, items)
}

func restore(_ pb: NSPasteboard, from dir: URL) throws {
    let (m, items) = try load(dir)
    pb.clearContents()
    // An empty board was saved as zero items; clearing it is the restore.
    if !items.isEmpty {
        let objs: [NSPasteboardItem] = items.map { types in
            let it = NSPasteboardItem()
            for (t, data) in types { it.setData(data, forType: .init(t)) }
            return it
        }
        guard pb.writeObjects(objs) else { die("writeObjects refused the saved items") }
    }
    print("restored \(items.count) item(s) saved at changeCount=\(m.changeCount); changeCount is now \(pb.changeCount)")
}

/// Differences between the board now and a save, one line each. Empty = equal.
func differences(_ pb: NSPasteboard, _ dir: URL) throws -> [String] {
    let (_, saved) = try load(dir)
    let now = snapshot(pb)
    var out: [String] = []
    if now.count != saved.count { out.append("item count: saved \(saved.count), now \(now.count)") }
    for i in 0..<min(now.count, saved.count) {
        let a = saved[i], b = now[i]
        if a.map({ $0.0 }) != b.map({ $0.0 }) {
            out.append("item \(i) types: saved \(a.map { $0.0 }), now \(b.map { $0.0 })")
        }
        let bm = Dictionary(b, uniquingKeysWith: { x, _ in x })
        for (t, data) in a where bm[t] != nil && bm[t] != data {
            out.append("item \(i) type \(t): \(data.count) bytes saved, \(bm[t]!.count) now, contents differ")
        }
    }
    return out
}

func compare(_ pb: NSPasteboard, _ dir: URL) throws -> Bool {
    let d = try differences(pb, dir)
    if d.isEmpty { print("equal: every item, type and byte matches the save"); return true }
    d.forEach { print("DIFF \($0)") }
    return false
}

func selftest() throws -> Bool {
    // A board nobody else uses. Never general, never selection.
    let pb = NSPasteboard(name: .init("polter.mac-pasteboard.selftest.\(getpid())"))
    defer { pb.releaseGlobally() }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-pasteboard-selftest-\(getpid())")
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Two items, several types each, one of them binary: the shape a single
    // `string(forType:)` would silently shrink.
    let a = NSPasteboardItem()
    a.setString("before the test", forType: .string)
    a.setString("<b>before</b> the test", forType: .html)
    a.setData(Data([0, 1, 2, 255, 254]), forType: .init("org.polter.selftest.binary"))
    let b = NSPasteboardItem()
    b.setString("second item", forType: .string)
    pb.clearContents()
    guard pb.writeObjects([a, b]) else { die("selftest could not seed its board") }

    func runTest() {
        // What a test does to the board: plain text, one item, nothing else.
        pb.clearContents()
        pb.setString("REG-selftest", forType: .string)
    }

    var ok = true
    let s1 = tmp.appendingPathComponent("with-restore")
    try save(pb, to: s1)
    runTest()
    try restore(pb, from: s1)
    let d1 = try differences(pb, s1)
    print(d1.isEmpty ? "PASS restored board equals the save" : "FAIL restored board differs: \(d1)")
    ok = ok && d1.isEmpty

    // The floor: same thing with the restore left out. This must be RED.
    let s2 = tmp.appendingPathComponent("without-restore")
    try save(pb, to: s2)
    runTest()
    let d2 = try differences(pb, s2)
    print(d2.isEmpty ? "FAIL compare saw no difference with the restore skipped" : "PASS compare is red with the restore skipped (\(d2.count) difference(s))")
    ok = ok && !d2.isEmpty
    return ok
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: save|restore|compare <board> <dir>, or selftest") }
do {
    switch args[1] {
    case "selftest": exit(try selftest() ? 0 : 1)
    case "save", "restore", "compare":
        guard args.count == 4 else { die("\(args[1]) takes <board> <dir>") }
        let pb = board(args[2]), dir = URL(fileURLWithPath: args[3])
        switch args[1] {
        case "save": try save(pb, to: dir)
        case "restore": try restore(pb, from: dir)
        default: exit(try compare(pb, dir) ? 0 : 1)
        }
    default: die("unknown action \(args[1])")
    }
} catch {
    die("\(error)")
}
