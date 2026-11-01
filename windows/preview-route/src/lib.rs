//! The `polter-file://` request routes, and the preview's `window.polter`
//! contract (task 2628, #2140 M1/W1; `polter-artifacts/2145/PLAN.md` §2.1
//! and §3.2).
//!
//! # What a preview is served over
//!
//! A file being previewed is served to a web view the host owns, over
//! `polter-file://<token>/<rel>`. **The token is the capability and the
//! host is not the judge of it**: a ticket is held by the core
//! (`src/poltergeist/files/Tickets.zig`, task 2573), bound to one workdir
//! and one scope, and every single request goes back to the core's
//! `files_resolve(token, rel)`, which judges `rel` against *this ticket's*
//! scope again and answers the real path -- or a refusal. The host reads
//! only the path it was given.
//!
//! So the split is:
//!
//! * **here**: which ticket is being asked and what relative path is being
//!   asked of it. A string rule, and this crate is where it is written so
//!   that it can be tested on any machine (the host's own tests compile
//!   only for a Windows target, `windows/Cargo.toml`).
//! * **the core**: whether that path may be read, and what the real path
//!   is. `Access.resolve` in the core, never here.
//!
//! ⚠️ **A host that built a file path from `rel` would be a second judge
//! of "is this inside the workdir"**, and the two would drift. Nothing in
//! this file touches the file system, and nothing in it can be made to.
//!
//! # Why `..` is refused here as well, when the core would refuse it too
//!
//! Not for safety -- the core's answer is the one that decides -- but
//! because the browser normalises `a/../b` to `b` before the request is
//! ever made (`URL` on macOS, WebView2 on Windows). A `..` arriving at the
//! handler is therefore a caller that is not the page's own URL resolution
//! -- a hand-written `fetch`, an `<img src>` in a string -- and the honest
//! answer to it is a refusal rather than a resolved path that happens to
//! land inside the fence. `%2e%2e` is the same thing spelled so the
//! browser will not normalise it away, which is why the check is made
//! after decoding and not before.
//!
//! # What the page can reach through the bridge
//!
//! `window.polter` carries exactly the eight calls
//! [`Call`] names: `info`, `read`, `readRel`, `openPath`, `watch`, `look`,
//! `propose`, `dirty`. **There is no `write`, no `create`, no `delete`, no
//! `rename`, no `exec` and no `fetch`** -- writing happens only through the
//! core's `files_commit`, after the person has chosen on the host's own
//! change screen. [`Call::parse`] is the whole of that surface, so a call
//! that is not in it is refused by name rather than silently ignored
//! (`PLAN.md` §3.2's table).
//!
//! The setup the two callers share -- non-persistent storage, the CSP
//! header, no new windows, no navigation -- stays where it is, in
//! `macos/Sources/Features/Preview/PluginWebView.swift` and
//! `windows/host/src/webview_host.rs`, because it is a thing done *to* a
//! web view and not a string a test can hold.

/// The scheme a previewed file is served over (`PLAN.md` §2.1). Registered
/// with an authority component on both hosts, which is why the token is the
/// URL's host.
pub const SCHEME: &str = "polter-file";

/// How many characters a token has: 16 random bytes as lower-case hex
/// (`Tickets.newId`, which is `std.fmt.bytesToHex(raw, .lower)`).
pub const TOKEN_LEN: usize = 32;

/// Why a request was not served. The handler answers 403 for every one of
/// them and reads nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refused {
    /// Not this scheme: `https`, `file:`, `polter-plugin:`, anything.
    OtherScheme,
    /// This scheme, but what is in the authority is not a token. Judged
    /// before any path is looked at: an unguessable token is the whole of
    /// the capability, so a request that cannot carry one is refused for
    /// that and not for where it was pointing.
    BadToken,
    /// A path that would leave the ticket's own directory, or one that
    /// cannot be read as a path.
    Outside,
    /// A percent-escape that is malformed, or bytes that are not UTF-8. A
    /// path that cannot be read is not guessed at.
    BadEscape,
}

impl Refused {
    /// The word the two hosts, the fixture and the tests all use for it.
    pub fn word(self) -> &'static str {
        match self {
            Refused::OtherScheme => "other_scheme",
            Refused::BadToken => "bad_token",
            Refused::Outside => "outside",
            Refused::BadEscape => "bad_escape",
        }
    }
}

/// Which ticket a request asks, and what it asks of it.
///
/// `rel` empty means the ticket's own file (`Tickets.resolve` reads an
/// empty `rel` as the anchor), which is what the entry URL asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub token: String,
    pub rel: String,
}

/// Turn a request URL into the ticket and relative path the core is asked
/// about, or why it is refused. **Nothing here reads a file.**
pub fn resolve(url: &str) -> Result<Route, Refused> {
    // 1. The scheme, without case: a URL scheme is case-insensitive by the
    //    standard, and WebView2 hands a lower-cased one while WKWebView
    //    does not.
    let rest = split_scheme(url).ok_or(Refused::OtherScheme)?;

    // 2. `//authority/path`, or nothing: the token is the host, so a URL
    //    with no authority cannot name one.
    let Some(authority) = rest.strip_prefix("//") else {
        return Err(Refused::OtherScheme);
    };
    let (host, path) = match authority.find('/') {
        Some(i) => (&authority[..i], &authority[i..]),
        None => (authority, ""),
    };

    // 3. The token. Lower-case hex, exactly `TOKEN_LEN` characters -- not
    //    "looks hex-ish": two hosts comparing it their own way is exactly
    //    how one of them comes to accept a token the other refuses.
    if !is_token(host) {
        return Err(Refused::BadToken);
    }

    let path = path.split(['?', '#']).next().unwrap_or("");
    let decoded = percent_decode(path).ok_or(Refused::BadEscape)?;

    let mut segs: Vec<&str> = Vec::new();
    for seg in decoded.split(['/', '\\']) {
        match seg {
            "" | "." => {}
            ".." => return Err(Refused::Outside),
            s if s.contains(':') || s.contains('\0') => return Err(Refused::Outside),
            s => segs.push(s),
        }
    }
    Ok(Route { token: host.to_string(), rel: segs.join("/") })
}

/// The part of `url` after `<scheme>://`, when the scheme is ours.
///
/// Returns the part including the `//`, so the caller does not have to
/// remember which of the two it got: a scheme match that leaves out the
/// authority is not a URL this scheme is served over.
fn split_scheme(url: &str) -> Option<&str> {
    let colon = url.find(':')?;
    let (scheme, rest) = url.split_at(colon);
    if !scheme.eq_ignore_ascii_case(SCHEME) {
        return None;
    }
    Some(&rest[1..])
}

/// Whether `s` is a token as `Tickets.newId` writes one: lower-case hex,
/// `TOKEN_LEN` characters. Upper case is refused rather than folded --
/// [`resolve`] hands this string to the core, where it is compared byte for
/// byte, so accepting `9F2C…` here would be a request that passes the
/// host's check and comes back `no_ticket` from the core.
pub fn is_token(s: &str) -> bool {
    s.len() == TOKEN_LEN && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `%XX` decoded, as UTF-8. `None` for a malformed escape or bytes that are
/// not UTF-8 -- the same rule `settings_shell::plugins::percent_decode` has
/// for a plugin page's path.
pub fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The `Content-Type` a preview answers with, by the file's extension.
///
/// # Why this is here and not in either host
///
/// It was written twice -- `preview_page.rs::content_type` and
/// `PreviewRoutes.contentType` -- and the two disagreed on two of the 33
/// extensions (`.css` and `.json`: `text/css`/`application/json` on
/// Windows, `text/plain` on macOS). Both sent `X-Content-Type-Options:
/// nosniff`, so the difference was not a difference on paper: it was a
/// stylesheet that renders on one machine and prints on the other.
///
/// Nothing in the product put the two halves side by side, and nothing
/// could: the host's tests compile only for a Windows target. **This crate
/// does compile here**, so the table lives here, the Windows host holds no
/// second copy of it, and `test/fixtures/preview-types.tsv` holds the macOS
/// one to the same answers (that half has to stay in Swift -- it cannot
/// call this).
///
/// # `text/plain` is the answer wherever a person is the reader
///
/// A preview exists to *show somebody a file*. `.js` is already
/// `text/plain` on both sides, and so are `.rs`, `.zig`, `.py` and the
/// rest: a previewed `.html` is a page and is served as one, and
/// everything else is text somebody is reading. `.css` and `.json` are the
/// same kind of thing -- a stylesheet is not loaded by a page whose own
/// scripts do not run -- and macOS's answer is the one both hosts now give.
///
/// ⚠️ **The plugin page's table keeps `text/css` and `application/json`,
/// and that is correct rather than a drift to be fixed.** A plugin page is
/// a program: its `.css` and `.json` are resources *the page* loads, and
/// the engine has to be told what they are. `settings-shell::plugins::
/// content_type` and `PluginPage.contentType` are that table and stay as
/// they are. The two tables answer different questions.
pub fn content_type(path: &str) -> &'static str {
    let ext = path.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    // A path with no dot at all, a dotfile (`.gitignore`), a trailing slash
    // and a directory component holding a dot (`a.d/b`) all have no
    // extension. `rsplit_once` gives `""` for `file.` and for `.gitignore`,
    // which falls to `octet-stream` like the rest -- checked against
    // `NSString.pathExtension` on macOS, which agrees on every one of them.
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "md" | "markdown" | "txt" | "log" | "csv" | "tsv" => "text/plain; charset=utf-8",
        "js" | "mjs" | "ts" | "tsx" | "css" | "json" | "rs" | "zig" | "py" | "swift" | "go"
        | "c" | "h" | "cpp" => "text/plain; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}

/// The calls `window.polter` carries -- **the whole surface** (`PLAN.md`
/// §3.2). A method that is not one of these gets `no such call: <name>`
/// back, so an author who guessed finds out instead of waiting on a promise
/// that never settles.
///
/// There is deliberately no `Write`, `Create`, `Delete`, `Rename`, `Exec`
/// or `Fetch`: a page cannot write a file, and `propose` is not a write --
/// it hands the text to the host, which draws the change and sends
/// `files_commit` only once the person has chosen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    /// Name, size, mtime, kind, encoding, end-of-line, `editable` and why not.
    Info,
    /// Bytes, inside the ticket's `reads` range.
    Read,
    /// Bytes of another file in the same range -- a markdown file's images.
    ReadRel,
    /// Ask the host to show another file in the same preview. Goes through
    /// [`resolve`], like any other request.
    OpenPath,
    /// A callback when the file changes, with who changed it.
    Watch,
    /// Colour tokens, font and size (`Look`), never below the menu font.
    Look,
    /// Hand the edited text to the host. **Not a write.**
    Propose,
    /// Whether there are unsaved changes.
    Dirty,
}

impl Call {
    pub const ALL: [Call; 8] = [
        Call::Info,
        Call::Read,
        Call::ReadRel,
        Call::OpenPath,
        Call::Watch,
        Call::Look,
        Call::Propose,
        Call::Dirty,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Call::Info => "info",
            Call::Read => "read",
            Call::ReadRel => "readRel",
            Call::OpenPath => "openPath",
            Call::Watch => "watch",
            Call::Look => "look",
            Call::Propose => "propose",
            Call::Dirty => "dirty",
        }
    }

    pub fn parse(method: &str) -> Option<Call> {
        Call::ALL.into_iter().find(|c| c.name() == method)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The table both implementations run: the Windows one here and
    /// `macos/Sources/Features/Preview/PreviewRoutes.swift`, the shape
    /// `test/fixtures/project-filenames.tsv` uses for its three readers and
    /// for the same reason -- two hosts in two languages can each be green
    /// while they disagree.
    const TABLE: &str = include_str!("../../../test/fixtures/preview-routes.tsv");

    /// One row: `(case, verdict, token, rel, url)`, the columns as the
    /// fixture has them. ⚠️ **`split('\t')` and not `split_whitespace`**: two
    /// of the five columns are empty for a refusal, and a split that drops
    /// them turns every refused row into a three-column one -- which is why
    /// `url` is the last column rather than the second.
    ///
    /// ⚠️ **And the count is asserted against the table's own `# rows:` line.**
    /// Two implementations that agree on every row they read also agree when a
    /// row has been deleted -- "the two hosts match" is not "this case is still
    /// being tested", and the refusals are exactly the rows somebody trims.
    /// `project-filenames.tsv` carries the same guard for the same reason.
    fn rows() -> Vec<(String, String, String, String, String)> {
        let mut out = Vec::new();
        let mut declared: Option<usize> = None;
        for line in TABLE.lines() {
            if let Some(v) = line.strip_prefix("# rows:") {
                declared = Some(v.trim().parse::<usize>().expect("# rows: is a number"));
                continue;
            }
            if line.starts_with('#') || line.starts_with("case\t") || line.trim().is_empty() {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            assert_eq!(f.len(), 5, "the table row {line:?} does not have five columns");
            out.push((f[0].into(), f[1].into(), f[2].into(), f[3].into(), f[4].into()));
        }
        let declared = declared.expect("test/fixtures/preview-routes.tsv: no `# rows:` line to check against");
        assert_eq!(
            out.len(),
            declared,
            "the table declares {declared} rows and {} were read",
            out.len()
        );
        if out.is_empty() {
            panic!("test/fixtures/preview-routes.tsv: no rows, so nothing was checked");
        }
        out
    }

    #[test]
    fn every_row_of_the_shared_table_is_the_route() {
        for (case, verdict, token, rel, url) in rows() {
            match resolve(&url) {
                Ok(r) => {
                    assert_eq!(verdict, "ok", "{case}: {url} was served and the table says {verdict}");
                    assert_eq!(r.token, token, "{case}: the ticket");
                    assert_eq!(r.rel, rel, "{case}: the path asked of the ticket");
                }
                Err(e) => {
                    assert_eq!(verdict, e.word(), "{case}: {url} was refused as {:?}", e);
                }
            }
        }
    }

    /// The three refusals that are the whole point, asserted here as well as
    /// in the table: the table is a file both hosts read, and a case edited
    /// in it would move both sides at once. These do not move with it.
    #[test]
    fn the_three_refusals_a_preview_must_never_get_past() {
        let token = "9f2c0a1b4d5e6f708192a3b4c5d6e7f8";
        assert_eq!(resolve(&format!("polter-file://{token}/../etc/passwd")), Err(Refused::Outside));
        assert_eq!(resolve(&format!("polter-file://{token}/%2e%2e/etc/passwd")), Err(Refused::Outside));
        assert_eq!(resolve("polter-file://not-a-token/x"), Err(Refused::BadToken));
        assert_eq!(resolve("https://example.com/x"), Err(Refused::OtherScheme));
        // The empty request, which the shared table cannot carry: a row whose
        // `url` column is empty ends in tabs, and a reader that drops them
        // reads three columns. Asserted here and in the Swift twin instead.
        assert_eq!(resolve(""), Err(Refused::OtherScheme));
    }

    /// **The bridge's surface, said as an absence.** A method that is not
    /// one of the eight is `None`, and these six are the ones a page must
    /// not be able to reach even by guessing the name.
    #[test]
    fn a_page_cannot_write_and_the_names_that_say_so_are_not_calls() {
        for forbidden in ["write", "create", "delete", "rename", "exec", "fetch"] {
            assert_eq!(Call::parse(forbidden), None, "{forbidden} is not a call a page may make");
        }
        for allowed in Call::ALL {
            assert_eq!(Call::parse(allowed.name()), Some(allowed));
        }
        // The eight names themselves, spelled out: a name changed in `name()`
        // to something a page does not know is a call nobody can make, and
        // this is the only place that would go red for it.
        let names: Vec<&str> = Call::ALL.iter().map(|c| c.name()).collect();
        assert_eq!(names, ["info", "read", "readRel", "openPath", "watch", "look", "propose", "dirty"]);
    }

    #[test]
    fn a_token_is_hex_and_exactly_hex() {
        assert!(is_token("9f2c0a1b4d5e6f708192a3b4c5d6e7f8"));
        assert!(!is_token("9F2C0A1B4D5E6F708192A3B4C5D6E7F8"), "upper case is another string to the core");
        assert!(!is_token("9f2c0a1b4d5e6f708192a3b4c5d6e7f"), "short");
        assert!(!is_token("9f2c0a1b4d5e6f708192a3b4c5d6e7f80"), "long");
        assert!(!is_token("9f2c0a1b4d5e6f708192a3b4c5d6e7gz"), "not hex");
        assert!(!is_token(""));
    }

    /// The Content-Type table, the same shape as the route table above: the
    /// Windows implementation is this one (the host has no second copy), and
    /// the macOS one is held to the same rows by
    /// `macos/Tests/Preview/PreviewRoutesTests.swift`.
    ///
    /// ⚠️ `split('\t')` and not `split_whitespace`, and the `why` column is
    /// **never empty** -- a row ending in a tab is a row an editor trims into
    /// a two-column one.
    fn type_rows() -> Vec<(String, String)> {
        const TYPES: &str = include_str!("../../../test/fixtures/preview-types.tsv");
        let mut out = Vec::new();
        let mut declared: Option<usize> = None;
        for line in TYPES.lines() {
            if let Some(v) = line.strip_prefix("# rows:") {
                declared = Some(v.trim().parse::<usize>().expect("# rows: is a number"));
                continue;
            }
            if line.starts_with('#') || line.starts_with("path\t") || line.trim().is_empty() {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            assert_eq!(f.len(), 3, "the type row {line:?} does not have three columns");
            out.push((f[0].to_string(), f[1].to_string()));
        }
        let declared =
            declared.expect("test/fixtures/preview-types.tsv: no `# rows:` line to check against");
        assert_eq!(
            out.len(),
            declared,
            "the table declares {declared} rows and {} were read",
            out.len()
        );
        if out.is_empty() {
            panic!("test/fixtures/preview-types.tsv: no rows, so nothing was checked");
        }
        out
    }

    #[test]
    fn every_row_of_the_shared_type_table_is_the_content_type() {
        for (path, want) in type_rows() {
            assert_eq!(content_type(&path), want, "{path}: the Content-Type");
        }
    }

    /// The two the hosts disagreed on (`text/css` / `application/json` on
    /// Windows, `text/plain` on macOS), said here as well as in the table: a
    /// case edited in the table would move both hosts at once, and these do
    /// not move with it.
    ///
    /// ⚠️ **This is not the plugin page's table**, which keeps those two
    /// types. A plugin page is a program loading its own resources; a
    /// preview is a person reading a file whose scripts do not run.
    #[test]
    fn a_stylesheet_and_a_json_document_are_text_a_person_reads() {
        assert_eq!(content_type("site.css"), "text/plain; charset=utf-8");
        assert_eq!(content_type("data.json"), "text/plain; charset=utf-8");
        assert_eq!(content_type("index.html"), "text/html; charset=utf-8");
        // The shape of "no extension", which is where the two languages'
        // standard libraries could part: a trailing dot, a dotfile, a dot in
        // a directory component.
        assert_eq!(content_type("file."), "application/octet-stream");
        assert_eq!(content_type(".gitignore"), "application/octet-stream");
        assert_eq!(content_type("a.d/b"), "application/octet-stream");
        assert_eq!(content_type("LICENSE"), "application/octet-stream");
    }
}
