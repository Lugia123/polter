import Foundation

/// The **raw Markdown destination** a rendered link came from.
///
/// The contract's `original_reference` is the exact destination spelling in
/// the stored message, not the URL a renderer produced: `[a](docs/a\(b\).md)`
/// must be sent with its backslashes. SwiftUI hands the view a `URL`, which
/// has already lost that spelling, so the row looks the link back up in its
/// own raw text and sends that span **exactly as written** (backslashes,
/// entities and all). If the span cannot be found, or more than one different
/// spelling renders to the same URL, the reference is **unavailable**: a
/// converted URL is not the source text, and picking the first of several
/// would send a different link than the one clicked.
enum ControlRoomChatRawReference {
    /// The one inline destination in `text` whose rendered form is `url`,
    /// exactly as written. Nil when there is none **or more than one**.
    static func destination(for url: URL, in text: String) -> String? {
        let found = Set(inlineDestinations(in: text).filter { matches($0, url) })
        return found.count == 1 ? found.first : nil
    }

    /// Every `](…)` destination, with `<…>` and backslash escapes unwrapped
    /// to the bytes a core would have stored. Balanced parentheses inside a
    /// bare destination are kept.
    static func inlineDestinations(in text: String) -> [String] {
        let scalars = Array(text)
        var found: [String] = []
        var i = 0
        while i + 1 < scalars.count {
            guard scalars[i] == "]" , scalars[i + 1] == "(" else { i += 1; continue }
            var j = i + 2
            // An optional title follows a space; the destination ends there.
            while j < scalars.count, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
            guard j < scalars.count else { break }
            var raw = ""
            if scalars[j] == "<" {
                j += 1
                while j < scalars.count, scalars[j] != ">" {
                    raw.append(scalars[j]); j += 1
                }
                if j < scalars.count { j += 1 }
            } else {
                var depth = 0
                while j < scalars.count {
                    let c = scalars[j]
                    if c == "\\", j + 1 < scalars.count {
                        // Kept as written: the contract wants the raw
                        // destination bytes, not an unescaped rendering.
                        raw.append(c); raw.append(scalars[j + 1]); j += 2; continue
                    }
                    if c == "(" { depth += 1 }
                    if c == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if c == " " || c == "\t" || c == "\n" { break }
                    raw.append(c); j += 1
                }
            }
            if !raw.isEmpty { found.append(raw) }
            i = j
        }
        return found
    }

    private static func matches(_ raw: String, _ url: URL) -> Bool {
        if raw == url.relativeString || raw == url.absoluteString { return true }
        let unescaped = unescape(raw)
        if unescaped == url.relativeString || unescaped == url.absoluteString { return true }
        if let made = URL(string: unescaped) {
            if made.absoluteString == url.absoluteString { return true }
            if made.relativeString == url.relativeString { return true }
        }
        if let decoded = unescaped.removingPercentEncoding,
           decoded == url.absoluteString || decoded == url.relativeString {
            return true
        }
        return false
    }

    /// `\(` -> `(`, only for **comparison**; the returned destination keeps
    /// the backslashes.
    private static func unescape(_ text: String) -> String {
        var out = ""
        var iterator = Array(text).makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                out.append(next)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
