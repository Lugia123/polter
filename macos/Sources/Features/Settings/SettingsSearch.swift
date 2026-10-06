import Foundation

/// The settings search (screenshot.md §12.2), with no AppKit in it: what can
/// be found, how that is handed to the core, and what comes back.
///
/// **The core does the matching and the ranking** -- one pure function,
/// shared with the other host, so that the same words find the same things
/// in the same order on both. This side only says what there is to find
/// (`Entry`), in the order it would be drawn, and remembers for each what
/// it is and where it lives (`Target`), which the core neither knows nor
/// needs to.
enum SettingsSearch {
    /// What a result is, and so where choosing it leads.
    enum Target: Equatable {
        /// A row of the General form, drawn in the results with its own
        /// control.
        case formItem(key: String, group: GeneralGroup)
        /// A row that shows a binding.
        case shortcut(action: String, group: GeneralGroup)
        case role(key: String)
        case project(name: String)
        case plugin(key: String)
        /// One of a plugin's own settings.
        case pluginItem(plugin: String, name: String)
        /// A line of the Keyboard Shortcuts page.
        case keybind(action: String)
    }

    /// One thing the search can find. The six fields the core matches
    /// against, any of which may be missing, and what this host keeps.
    struct Entry: Equatable {
        var target: Target
        var name: String?
        var aliases: [String] = []
        var key: String?
        var summary: String?
        var choices: [String] = []
        /// The group it is drawn in, as the breadcrumb names it. Only a
        /// General row has one; All Options is not a place to look for.
        var group: String?
    }

    /// The words on a result that are not its name: where it is.
    static func crumb(section: String, item: String?) -> String {
        guard let item, !item.isEmpty else { return section }
        return "\(section) › \(item)"
    }

    /// Whether the search box holds a search. Spaces alone are not one:
    /// the page stays as it was.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The group a form item is drawn in: the one the core puts it in, or
    /// All Options for a key that is in no group -- and for a group this
    /// build has no page for, so that it can still be found and changed.
    static func group(of item: ConfigForm.Item) -> GeneralGroup {
        guard let name = item.group else { return .all }
        return GeneralGroup.allCases.first { ConfigFormRules.coreGroup($0) == name } ?? .all
    }

    /// What the core matches a group by: its title, and nothing for All
    /// Options, which every key would otherwise be found under.
    static func groupName(_ group: GeneralGroup) -> String? {
        group == .all ? nil : group.title
    }

    /// The General form as entries: every key, in the table's order, and
    /// after them the rows that show a binding.
    ///
    /// A name that was translated is also findable by its English: the
    /// English is what the documentation, a colleague's screenshot and the
    /// config file's own comments say.
    static func entries(of form: ConfigForm, bundle: Bundle = .main) -> [Entry] {
        func withEnglish(_ aliases: [String], _ msgid: String?) -> [String] {
            guard let msgid, ConfigFormRules.localized(msgid, bundle: bundle) != msgid else { return aliases }
            return aliases + [msgid]
        }
        var out = form.items.map { item -> Entry in
            Entry(
                target: .formItem(key: item.key, group: group(of: item)),
                name: item.label.map { ConfigFormRules.localized($0, bundle: bundle) },
                aliases: withEnglish(item.aliases, item.label),
                key: item.key,
                summary: ConfigFormRules.sentence(item, bundle: bundle),
                choices: item.control == .choice
                    ? ConfigFormRules.choices(of: item).map { ConfigFormRules.choiceTitle($0, of: item, bundle: bundle) }
                    : [],
                group: groupName(group(of: item)))
        }
        for section in form.sections {
            guard let group = GeneralGroup.allCases.first(where: { ConfigFormRules.coreGroup($0) == section.group })
            else { continue }
            for shortcut in section.shortcuts {
                out.append(Entry(
                    target: .shortcut(action: shortcut.action, group: group),
                    name: ConfigFormRules.localized(shortcut.label, bundle: bundle),
                    aliases: withEnglish(shortcut.aliases ?? [], shortcut.label),
                    key: shortcut.action,
                    summary: shortcut.summary.map { ConfigFormRules.localized($0, bundle: bundle) },
                    group: groupName(group)))
            }
        }
        return out
    }

    /// The entries as the core reads them: a JSON array, one object each,
    /// in order. An empty field is left out, which the core takes as "has
    /// none".
    static func json(_ entries: [Entry]) -> String {
        let objects = entries.map { entry -> [String: Any] in
            var object: [String: Any] = [:]
            if let name = entry.name, !name.isEmpty { object["name"] = name }
            if !entry.aliases.isEmpty { object["aliases"] = entry.aliases }
            if let key = entry.key, !key.isEmpty { object["key"] = key }
            if let summary = entry.summary, !summary.isEmpty { object["summary"] = summary }
            if !entry.choices.isEmpty { object["choices"] = entry.choices }
            if let group = entry.group, !group.isEmpty { object["group"] = group }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// One result: which entry, and how strongly it matched.
    struct Hit: Equatable {
        var index: Int
        var rank: String
    }

    /// The core's answer, best first. Nil when it is not an answer; a hit
    /// that names no entry of `count` is dropped rather than trusted.
    static func hits(from json: String, count: Int) -> [Hit]? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let raw = root["hits"] as? [[String: Any]] else { return nil }
        return raw.compactMap { hit in
            guard let index = (hit["index"] as? NSNumber)?.intValue, (0..<count).contains(index),
                  let rank = hit["rank"] as? String else { return nil }
            return Hit(index: index, rank: rank)
        }
    }

    /// The entries the hits name, in the hits' order.
    static func results(_ entries: [Entry], hits: [Hit]) -> [Entry] {
        hits.compactMap { entries.indices.contains($0.index) ? entries[$0.index] : nil }
    }
}
