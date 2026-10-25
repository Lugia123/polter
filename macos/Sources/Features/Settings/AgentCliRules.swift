import Foundation
import SwiftUI

/// The Agent CLI page's data and rules (task 2156): what the core answers
/// (`ghostty_app_launchers`), the table it shows, and a draft being edited.
/// Pure, so that it is tested without a window. The core keeps them in
/// `launchers.json` and calls them launchers; the person sees "Agent CLI",
/// in every language.
enum AgentCliRules {
    struct Preset: Decodable, Equatable {
        var key: String
        var name: String
        var standing: String
    }

    struct Role: Decodable, Equatable {
        var key: String
        var name: String
    }

    struct Env: Codable, Equatable {
        var name: String
        var value: String
    }

    struct Custom: Codable, Equatable {
        var key: String
        var name: String
        var base: String
        var command: String
        var env: [Env]
        var args: [String]
        var roles: [String]
    }

    struct Page: Decodable, Equatable {
        struct File: Decodable, Equatable { var launchers: [Custom] }
        var presets: [Preset]
        var roles: [Role]
        var file: File
    }

    static func decode(_ json: String) -> Page? {
        try? JSONDecoder().decode(Page.self, from: Data(json.utf8))
    }

    /// One row of the table: presets first, in the core's order, then the
    /// person's own.
    struct Row: Equatable {
        var key: String
        var name: String
        var base: String
        var custom: Bool
        /// The command for one of the person's own; nil for a preset, which
        /// its plugin starts.
        var command: String?
    }

    static func rows(_ page: Page) -> [Row] {
        page.presets.map { Row(key: $0.key, name: $0.name, base: $0.key, custom: false, command: nil) }
            + page.file.launchers.map { Row(key: $0.key, name: $0.name, base: $0.base, custom: true, command: $0.command) }
    }

    /// A key for a new one: its name in `a-z0-9-`, or `agent-cli` when the
    /// name has none of those, with `-2`, `-3`... until it is taken by
    /// nothing in `page`.
    static func key(for name: String, in page: Page) -> String {
        var slug = ""
        var dash = false
        for c in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                slug.unicodeScalars.append(c)
                dash = false
            } else if !slug.isEmpty && !dash {
                slug.append("-")
                dash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "agent-cli" }
        slug = String(slug.prefix(56))
        let taken = Set(page.presets.map(\.key) + page.file.launchers.map(\.key))
        if !taken.contains(slug) { return slug }
        var n = 2
        while taken.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }

    /// A new one: no name yet, the first preset as its base, off for every
    /// role.
    static func blank(in page: Page) -> Custom {
        Custom(key: "", name: "", base: page.presets.first?.key ?? "", command: "", env: [], args: [], roles: [])
    }

    /// What is wrong with a draft before it is sent, in the core's own
    /// order; nil when nothing is. The core checks again.
    enum Problem: Equatable { case noName, noBase, commandNotAbsolute, badEnvName(String) }

    static func problem(_ c: Custom) -> Problem? {
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { return .noName }
        if c.base.isEmpty { return .noBase }
        let cmd = c.command
        let absolute = cmd.hasPrefix("/") || cmd.hasPrefix("~/") || cmd.hasPrefix("\\\\")
            || (cmd.count >= 3 && cmd.dropFirst().hasPrefix(":") && (cmd.dropFirst(2).hasPrefix("\\") || cmd.dropFirst(2).hasPrefix("/")))
        if !absolute { return .commandNotAbsolute }
        for e in c.env where !validEnvName(e.name) { return .badEnvName(e.name) }
        return nil
    }

    static func validEnvName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The object `ghostty_app_launcher_put` takes. A draft with no key yet
    /// is given one from its name.
    static func putJSON(_ c: Custom, in page: Page) -> String {
        var c = c
        if c.key.isEmpty { c.key = key(for: c.name, in: page) }
        c.env = c.env.filter { !$0.name.isEmpty }
        c.args = c.args.filter { !$0.isEmpty }
        let data = (try? JSONEncoder().encode(c)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The arguments as one line, a space between each; and back. A word
    /// with a space in it is not one this field can say -- the file can.
    static func argsLine(_ args: [String]) -> String { args.joined(separator: " ") }
    static func args(fromLine line: String) -> [String] {
        line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Who holds the draft the Agent CLI form edits (`AgentCliModel`), and the
/// bindings its controls are given.
///
/// **No binding here unwraps the draft** (task 2164). Deleting the selected
/// one sets the draft to nil, and SwiftUI reads the bindings of the form it
/// is about to take away once more, while it lays the window out -- a
/// `draft!` there stopped Polter dead, the first time anybody pressed
/// Delete. The same goes for a variable's row: its fields are read once
/// more after the row is removed, at an index that is no longer there. So
/// a binding whose draft or row is gone reads what it was made with, and a
/// write to it goes nowhere.
@MainActor
protocol AgentCliDraftHolder: AnyObject {
    var draft: AgentCliRules.Custom? { get set }
}

extension AgentCliDraftHolder {
    /// One field of the draft; `made` is what it read when the control was
    /// made, which is what it reads when the draft is gone.
    func field<T>(_ path: WritableKeyPath<AgentCliRules.Custom, T>, else made: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.draft?[keyPath: path] ?? made },
            set: { [weak self] v in self?.draft?[keyPath: path] = v })
    }

    /// One part of variable `i`, which may have been removed.
    func variable(_ i: Int, _ path: WritableKeyPath<AgentCliRules.Env, String>, else made: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let env = self?.draft?.env, env.indices.contains(i) else { return made }
                return env[i][keyPath: path]
            },
            set: { [weak self] v in
                guard let self, let env = self.draft?.env, env.indices.contains(i) else { return }
                self.draft?.env[i][keyPath: path] = v
            })
    }

    /// Whether the draft is switched on for `role`. **Nothing on the Agent
    /// CLI page ticks these any more** (task 2156 v5): which roles may start
    /// in one of the person's own is decided in the role library, through
    /// the core's `ghostty_app_role_launcher_set`. Kept because a draft
    /// carries its roles -- `dirty` and `revert` compare the whole thing,
    /// and one that dropped them would read as a change.
    func role(_ role: String, else made: Bool) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.draft.map { $0.roles.contains(role) } ?? made },
            set: { [weak self] on in
                self?.draft?.roles.removeAll { $0 == role }
                if on { self?.draft?.roles.append(role) }
            })
    }

    /// Take variable `i` out, if it is still there.
    func removeVariable(_ i: Int) {
        guard let env = draft?.env, env.indices.contains(i) else { return }
        draft?.env.remove(at: i)
    }
}
