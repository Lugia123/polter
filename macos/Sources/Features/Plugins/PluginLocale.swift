import Foundation

/// The strings a plugin shows a person, in that person's language.
///
/// A plugin is somebody else's directory. Polter's own strings go through
/// gettext (`po/`, `src/os/i18n.zig`), and a third party's cannot: they are
/// not in our catalogues and never will be. So a plugin carries its own
/// translations beside its manifest:
///
///     plugins/demo-archive/
///       plugin.json          the manifest, values are plain strings, English
///       i18n/zh-Hans.json    only the fields that need saying differently
///
/// The manifest keeps its shape. Turning `"description"` into
/// `{"en": …, "zh-Hans": …}` would make one field sometimes a string and
/// sometimes an object -- every reader of `plugin.json`, ours and anybody
/// else's, would have to learn that -- and a sidecar can be handed to a
/// translator, added, or removed on its own.
///
/// **This is the settings UI only.** `plugin_list` answers an agent, and it
/// answers with the manifest verbatim: if the tool surface followed the
/// machine's language, the same agent would read different tool descriptions
/// on a Chinese machine and an English one, and stop being reproducible. A
/// person gets their own language; an agent gets the same words everywhere.
/// See `docs/poltergeist/boundary.md` section 4.
enum PluginLocale {
    /// Which sidecar files to look for, in the order they should be tried.
    ///
    /// Built from the user's preferred languages, each one expanded into a
    /// ladder from most specific to least:
    ///
    ///     zh-Hans-CN  →  zh-Hans-CN, zh-Hans, zh-CN, zh
    ///     zh_CN.UTF-8 →  zh-Hans-CN, zh-Hans, zh-CN, zh
    ///     zh          →  zh-Hans, zh
    ///     en-GB       →  en-Latn-GB, en-Latn, en-GB, en
    ///
    /// Three decisions are packed in here, and this is where they are
    /// written down (`docs/poltergeist/boundary.md` had them open):
    ///
    /// 1. **Script beats region.** `zh-Hans` is tried before `zh-CN`,
    ///    because what a Chinese reader cannot read is the other script,
    ///    while the region only changes vocabulary. A translator who ships
    ///    one file ships `zh-Hans.json`, and it must reach somebody whose
    ///    machine says `zh_CN`.
    /// 2. **The script is filled in when it is not written.** `zh_CN` is a
    ///    POSIX locale and names no script, so `Locale` is asked what script
    ///    that implies -- Hans -- rather than this file carrying a table of
    ///    regions that would go stale and would only ever have Chinese in it.
    ///    It is also what normalises `_`, `.UTF-8` and `@euro` away, and what
    ///    fixes the casing, so `zh_hans` and `ZH-HANS` land on the same file.
    /// 3. **The first file that exists wins whole.** No merging a `zh-Hans`
    ///    over a `zh`: with merging, a key added to one file silently changes
    ///    what readers of the other see, and neither translator can see the
    ///    result. What a sidecar leaves out falls back to the manifest, which
    ///    is English -- one clearly-marked fallback instead of a chain.
    static func candidates(for preferred: [String]) -> [String] {
        var out: [String] = []

        for tag in preferred {
            let language = Locale(identifier: tag).language
            guard let code = language.languageCode?.identifier,
                  isTag(code)
            else { continue }

            let script = language.script?.identifier
            let region = language.region?.identifier

            var ladder: [String] = []
            if let script, let region { ladder.append("\(code)-\(script)-\(region)") }
            if let script { ladder.append("\(code)-\(script)") }
            if let region { ladder.append("\(code)-\(region)") }
            ladder.append(code)

            for candidate in ladder where isTag(candidate) && !out.contains(candidate) {
                out.append(candidate)
            }
        }

        return out
    }

    /// Whether a candidate is a language tag and nothing more.
    ///
    /// It is about to be spelled into a file name. Preferred languages come
    /// from system settings rather than from anywhere hostile, but the check
    /// costs nothing and the alternative is a path built out of a string
    /// somebody else chose -- the same rule, and the same reason, as
    /// `isPlainName` on the Zig side.
    private static func isTag(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 35 else { return false }
        var subtags = 0
        for subtag in text.split(separator: "-", omittingEmptySubsequences: false) {
            subtags += 1
            guard (2...8).contains(subtag.count) else { return false }
            for character in subtag.unicodeScalars {
                guard CharacterSet.alphanumerics.contains(character),
                      character.isASCII
                else { return false }
            }
        }
        return subtags > 0
    }
}

/// What one sidecar file says, or nothing when there is no sidecar.
///
/// Every field is optional and every missing one means "the manifest already
/// says it well enough". A sidecar holding one line is a legitimate sidecar.
struct PluginText {
    struct Field {
        var title: String?
        var help: String?
    }

    var name: String?
    var summary: String?
    var fields: [String: Field] = [:]

    static let none = PluginText()

    /// The sidecar file shape, which is flatter than the manifest's:
    ///
    ///     {
    ///       "name": "存档",
    ///       "description": "…",
    ///       "params": {
    ///         "dir": { "title": "…", "description": "…" }
    ///       }
    ///     }
    ///
    /// `params` maps a parameter's name straight to its strings rather than
    /// repeating the manifest's `params.properties` nesting: a sidecar is not
    /// a second copy of the schema, and nothing in it is a `type`, a
    /// `required` or an `enum`. What a translator opens is the list of
    /// sentences to translate.
    static func load(from directory: URL, preferring preferred: [String]) -> PluginText {
        let base = directory.appendingPathComponent("i18n")

        for candidate in PluginLocale.candidates(for: preferred) {
            let url = base.appendingPathComponent("\(candidate).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                // A file that is there but will not parse still ends the
                // search. Falling through to the next language would show
                // half a person's typo as somebody else's language.
                return .none
            }
            return parse(root)
        }

        return .none
    }

    private static func parse(_ root: [String: Any]) -> PluginText {
        var text = PluginText()
        text.name = root["name"] as? String
        text.summary = root["description"] as? String

        if let params = root["params"] as? [String: Any] {
            for (name, raw) in params {
                guard let spec = raw as? [String: Any] else { continue }
                text.fields[name] = Field(
                    title: spec["title"] as? String,
                    help: spec["description"] as? String)
            }
        }

        return text
    }
}
