import Foundation

/// «Copy Terminal ID» (task 1643): what goes on the clipboard and what the
/// rows say, apart from the menus that offer it.
///
/// **The id is the one the MCP tools take**: `terminal_list`'s `id`,
/// `ghostty_surface_poltergeist_id` written `0x%016llx`. The point is to
/// paste it to an agent so it acts on that terminal and no other, so it is
/// the whole sixteen digits, never a shortened one.
///
/// The Windows host has the same rules in `windows/host/src/terminal_id.rs`,
/// with the same cases in its tests.
enum TerminalIDCopy {
    /// One terminal: its id, and the title shown beside it.
    struct Entry: Equatable {
        let id: UInt64
        let title: String
    }

    /// What a tab's menu offers.
    enum Offer: Equatable {
        /// One terminal in the tab: the row copies it.
        case single(Entry)
        /// Several: a submenu of one row each, then «Copy All».
        case each([Entry])
    }

    /// The id as `terminal_list` writes it. 0 names no terminal (the core
    /// answers 0 for none), so it is never offered: see `known`.
    static func text(_ id: UInt64) -> String {
        String(format: "0x%016llx", id)
    }

    static func known(_ id: UInt64) -> Bool {
        id != 0
    }

    /// The longest title a submenu row shows before it is cut.
    static let titleLimit = 40

    /// A row of the submenu: "title — 0x…", the title on one line and cut
    /// at `titleLimit`; just the id when there is no title.
    static func rowLabel(_ entry: Entry) -> String {
        label(entry, limit: titleLimit)
    }

    /// «Copy All»: one line per terminal, as its row says it but with the
    /// whole title, in the tab's order.
    static func allText(_ entries: [Entry]) -> String {
        entries.map { label($0, limit: nil) }.joined(separator: "\n")
    }

    /// What the tab's menu offers for these terminals, those with no id
    /// left out; nil when none is left.
    static func offer(_ entries: [Entry]) -> Offer? {
        let offered = entries.filter { known($0.id) }
        switch offered.count {
        case 0: return nil
        case 1: return .single(offered[0])
        default: return .each(offered)
        }
    }

    private static func label(_ entry: Entry, limit: Int?) -> String {
        let flat = entry.title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if flat.isEmpty { return text(entry.id) }
        let shown: String
        if let limit, flat.count > limit {
            shown = String(flat.prefix(limit)) + "…"
        } else {
            shown = flat
        }
        return "\(shown) — \(text(entry.id))"
    }
}
