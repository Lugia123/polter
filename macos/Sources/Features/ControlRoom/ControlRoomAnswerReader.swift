import Foundation

/// Reading the right side's pages' answers one field at a time (task 2039,
/// API.md §2.0): **a field missing, or of the wrong kind, costs only what it
/// is drawn as** -- that item is left out, and its path is kept in
/// `missing` for the page to write down -- never the page. The Windows
/// host's `reader`, the same rules and the same paths (`machine.text.swap`,
/// `cards[0].dial.big`), so that the two hosts' lines read alike.
///
/// What is read for a word and is missing reads as "", which draws nothing;
/// what has no such neutral value (a dial's fill, a task's glyph) reads as
/// nil.
final class ControlRoomAnswerReader {
    typealias Object = [String: Any]

    /// Every field that was missing or not what it should be, in the order
    /// met.
    private(set) var missing: [String] = []

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    static func at(_ path: String, _ i: Int) -> String {
        "\(path)[\(i)]"
    }

    /// What an answer lacked, as one line: the first dozen paths and how
    /// many more -- the Windows host's `missing_words`.
    static func words(_ missing: [String]) -> String {
        let shown = 12
        var out = missing.prefix(shown).joined(separator: ", ")
        if missing.count > shown { out += " and \(missing.count - shown) more" }
        return out
    }

    func miss(_ path: String) {
        missing.append(path)
    }

    private func said<T>(_ path: String, _ key: String) -> T? {
        miss(Self.join(path, key))
        return nil
    }

    /// JSON's true and false come as NSNumber too: these tell them apart.
    private static func isBool(_ x: Any) -> Bool {
        guard let n = x as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    func obj(_ v: Object, _ path: String, _ key: String) -> Object? {
        if let o = v[key] as? Object { return o }
        return said(path, key)
    }

    /// An object that may be null (§2.0): nil for null, unsaid.
    func nullableObj(_ v: Object, _ path: String, _ key: String) -> Object? {
        if v[key] is NSNull { return nil }
        return obj(v, path, key)
    }

    func text(_ v: Object, _ path: String, _ key: String) -> String {
        if let s = v[key] as? String { return s }
        miss(Self.join(path, key))
        return ""
    }

    func nullableText(_ v: Object, _ path: String, _ key: String) -> String? {
        if v[key] is NSNull { return nil }
        if let s = v[key] as? String { return s }
        return said(path, key)
    }

    func int(_ v: Object, _ path: String, _ key: String) -> UInt64? {
        if let x = v[key], !Self.isBool(x), let n = x as? NSNumber, n.doubleValue >= 0, n.doubleValue == n.doubleValue.rounded() {
            return n.uint64Value
        }
        return said(path, key)
    }

    func nullableInt(_ v: Object, _ path: String, _ key: String) -> UInt64? {
        if v[key] is NSNull { return nil }
        return int(v, path, key)
    }

    func number(_ v: Object, _ path: String, _ key: String) -> Double? {
        if let x = v[key], !Self.isBool(x), let n = x as? NSNumber { return n.doubleValue }
        return said(path, key)
    }

    func bool(_ v: Object, _ path: String, _ key: String) -> Bool? {
        if let x = v[key], Self.isBool(x), let n = x as? NSNumber { return n.boolValue }
        return said(path, key)
    }

    /// The list at `key`; empty and said when missing or not a list.
    func list(_ v: Object, _ path: String, _ key: String) -> [Any] {
        if let a = v[key] as? [Any] { return a }
        miss(Self.join(path, key))
        return []
    }

    /// A value named at `key` from `T`'s names: nil, and said, when missing,
    /// not words, or a name this build does not know.
    func named<T: RawRepresentable>(_ v: Object, _ path: String, _ key: String, as _: T.Type) -> T? where T.RawValue == String {
        if let s = v[key] as? String, let t = T(rawValue: s) { return t }
        return said(path, key)
    }

    /// One that may be null (a `tone`, §2.0).
    func nullableNamed<T: RawRepresentable>(_ v: Object, _ path: String, _ key: String, as t: T.Type) -> T? where T.RawValue == String {
        if v[key] is NSNull { return nil }
        return named(v, path, key, as: t)
    }
}
