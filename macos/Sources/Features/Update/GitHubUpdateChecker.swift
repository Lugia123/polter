import Foundation
import os

/// Polls GitHub's Releases API for a newer tagged release than the one this
/// build carries, and nothing more.
///
/// This exists because Sparkle has no feed to check: `UpdateDelegate.swift`
/// returns `nil` from `feedURLString` on purpose, because Ghostty's own
/// appcast would make every Ghostty release look like an upgrade for Polter
/// (see the comment there). Sparkle's `SUAppcastItem` cannot be constructed
/// from here either -- its only public initializer is
/// `+emptyAppcastItem`, plus three `initWithDictionary:` overloads Apple
/// marks `__deprecated_msg` and says point at a *private* designated
/// initializer (`SUAppcastItem+Private.h`) for anything that "depends on the
/// system or application version". So this reaches GitHub directly and never
/// touches Sparkle at all: `UpdateState.gitHubUpdateAvailable` carries a bare
/// version string and a URL, not an `SUAppcastItem`, and nothing here ever
/// downloads or installs -- task 649 asked for a prompt, not an updater.
enum GitHubUpdateChecker {
    /// Anonymous GitHub API requests are rate-limited to 60/hour/IP.
    static let releasesURL = URL(string: "https://api.github.com/repos/Lugia123/polter/releases/latest")!

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "update")

    /// What a caller learns instead of a release: `checkForUpdate`'s success
    /// case is reserved for "there is (or is not) a newer version", so
    /// anything that is not that answer -- a dropped connection, a response
    /// this parser does not recognize, GitHub's rate limit -- is here
    /// instead and never coerced into "no update".
    enum CheckError: Error, LocalizedError {
        /// GitHub answered 403. Anonymous requests are capped at 60/hour/IP,
        /// and this is deliberately its own case: collapsing it into
        /// `.unexpectedStatus` or `.malformedResponse` would let it read as
        /// "checked, nothing found", which is the one thing a 403 must never
        /// be mistaken for -- the two cases look identical in the UI unless
        /// they are kept apart here first.
        case rateLimited
        case network(any Error)
        case malformedResponse
        case unexpectedStatus(Int)
        /// This build's own version could not be determined -- it was not
        /// built from a tagged release or a `feature/vX.Y` branch, so
        /// `PolterVersionSource` (`PolterVersion.zig`'s `Source`) says
        /// `fallback` rather than `tag` or `branch`.
        ///
        /// **Deliberately its own case, checked before any request goes
        /// out.** A fallback build's `CFBundleShortVersionString` is
        /// `0.1.<commit count>` -- the same shape a real `0.1.x` release
        /// would have, and comparing it against GitHub's latest tag would
        /// almost always read as "you're behind", because a fallback build
        /// is usually a dev checkout well ahead of the last release, not
        /// behind it. That is an update prompt telling the person to
        /// downgrade. `UpdateController.beginGitHubCheck` checks
        /// `currentVersionIsAGuess` before it ever calls `makeCheckTask`, so
        /// this case is produced without a request ever going out.
        case versionUnknown

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return String(localized: "GitHub limits anonymous requests to 60 per hour; try again later.", comment: "更新检查错误")
            case .network(let error):
                return error.localizedDescription
            case .malformedResponse:
                return String(localized: "GitHub's response could not be read.", comment: "更新检查错误")
            case .unexpectedStatus(let code):
                return String(localized: "GitHub returned an unexpected response (\(code)).", comment: "更新检查错误")
            case .versionUnknown:
                return String(localized: "This build's own version could not be determined (it was not built from a release tag or version branch), so it cannot be compared against GitHub's releases.", comment: "更新检查错误")
            }
        }
    }

    /// The two values `PolterVersionSource` carries when `major.minor` was
    /// actually read from somewhere -- `PolterVersion.zig`'s
    /// `@tagName(Source.tag)` and `@tagName(Source.branch)`. The two must
    /// agree by construction; there is no shared source between Zig and
    /// Swift to enforce it, so they are spelled out once here rather than
    /// typed again at each call site.
    ///
    /// **A whitelist of the known-good values, not a blacklist of the known
    /// bad one.** The first version of this checked `source == "fallback"`,
    /// which treats "fallback" as the only way to be unsure and everything
    /// else -- `nil`, `""`, a value nothing here has been taught about yet --
    /// as safe to compare. That is backwards for what each mistake costs:
    /// wrongly saying "cannot tell" loses one prompt; wrongly saying "I know"
    /// on a version this build cannot back up tells the person to downgrade.
    /// `nil`/`""` are not hypothetical either -- `macos/build.nu` calls
    /// `xcodebuild` directly and never runs `GhosttyXcodebuild.zig`'s
    /// `POLTER_VERSION_SOURCE=...` argument, so a `build.nu` build's
    /// `PolterVersionSource` is empty, and its `PolterCommit` is empty for
    /// the identical reason -- the build whose version string is least
    /// trustworthy is exactly the one this used to wave through.
    static let knownVersionSources: Set<String> = ["tag", "branch"]

    /// True when `versionSource` (read by the caller from `Bundle.main`'s
    /// `PolterVersionSource`) does **not** say this build's version was read
    /// from a tag or a branch -- which means it is a guess, whether that is
    /// because the source is `fallback`, or because it is missing, empty, or
    /// unrecognized. Checked before `checkForUpdate` ever builds a request --
    /// see `CheckError.versionUnknown`.
    ///
    /// Takes the string rather than a `Bundle` so the decision is a pure
    /// function: `Bundle.infoDictionary` is real I/O with no clean way to
    /// hand it a fake `PolterVersionSource` in a test, and the interesting
    /// logic here is the comparison, not the lookup.
    static func currentVersionIsAGuess(source: String?) -> Bool {
        guard let source else { return true }
        return !knownVersionSources.contains(source)
    }

    /// The log line for `CheckError.versionUnknown`. Says "cannot tell",
    /// never "up to date" or "update available" -- the distinction the whole
    /// of this short-circuit exists to keep.
    static func logVersionIsAGuess(currentVersion: String) {
        logger.info("check_for_updates: cannot tell what version this build is (current=\(currentVersion, privacy: .public), PolterVersionSource=fallback); not comparing against GitHub -- a fallback build is usually ahead of the last release, not behind it")
    }

    /// A newer release than the one running, once the version compare has
    /// already happened -- `checkForUpdate` returns `.success(nil)` rather
    /// than one of these when there is nothing newer.
    struct Update {
        /// Stripped of a leading `v`: `v0.6.657` becomes `0.6.657`.
        let version: String
        let htmlURL: URL
        let publishedAt: Date?
    }

    /// The subset of GitHub's release JSON this reads. Everything else in
    /// the response is ignored.
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let publishedAt: Date?
        let prerelease: Bool
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case prerelease
            case draft
        }
    }

    /// Builds (but does not start) the request for the latest release and
    /// compares it against `currentVersion`.
    ///
    /// Returned unresumed so the caller can hold it long enough to cancel:
    /// `UpdateController` wires this into `UpdateState.Checking.cancel`, and
    /// a check the user dismissed should not go on running in the
    /// background only to overwrite whatever state they moved on to.
    ///
    /// `completion` always runs on the main queue.
    static func makeCheckTask(
        currentVersion: String,
        completion: @escaping (Result<Update?, CheckError>) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        return URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.parse(data: data, response: response, error: error, currentVersion: currentVersion)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func parse(
        data: Data?,
        response: URLResponse?,
        error: (any Error)?,
        currentVersion: String
    ) -> Result<Update?, CheckError> {
        if let error {
            // A cancelled task lands here too (`NSURLErrorCancelled`), but by
            // the time that happens the caller has already moved the state
            // off `.checking` and will not act on this result -- see the
            // guard in `UpdateController`.
            logger.info("check_for_updates: request failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.network(error))
        }

        guard let http = response as? HTTPURLResponse else {
            logger.info("check_for_updates: no HTTP response")
            return .failure(.malformedResponse)
        }

        if http.statusCode == 403 {
            // **Must not fall through to "no update".** A 403 here and a 200
            // with no newer tag produce the exact same words in the popover
            // (`NotFoundView`) unless this is caught first -- which is the
            // whole reason it is its own branch rather than folded into the
            // status check below.
            logger.info("check_for_updates: rate-limited (403), not treated as up to date")
            return .failure(.rateLimited)
        }

        guard http.statusCode == 200, let data else {
            logger.info("check_for_updates: unexpected status \(http.statusCode, privacy: .public)")
            return .failure(.unexpectedStatus(http.statusCode))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let release = try? decoder.decode(Release.self, from: data) else {
            logger.info("check_for_updates: response did not decode as a release")
            return .failure(.malformedResponse)
        }

        guard !release.draft, !release.prerelease else {
            logger.info("check_for_updates: latest release \(release.tagName, privacy: .public) is a draft or prerelease; ignoring")
            return .success(nil)
        }

        let latestVersion = String(release.tagName.hasPrefix("v") ? release.tagName.dropFirst() : release.tagName[...])

        guard let latest = semver(latestVersion), let current = semver(currentVersion) else {
            logger.info("check_for_updates: could not parse a version to compare (latest=\(release.tagName, privacy: .public) current=\(currentVersion, privacy: .public))")
            return .success(nil)
        }

        let hasUpdate = isNewer(latest, than: current)
        logger.info("check_for_updates: current=\(currentVersion, privacy: .public) latest=\(latestVersion, privacy: .public) -> \(hasUpdate ? "update available" : "up to date", privacy: .public)")

        guard hasUpdate else { return .success(nil) }

        return .success(Update(version: latestVersion, htmlURL: release.htmlURL, publishedAt: release.publishedAt))
    }

    /// `"0.6.657"` -> `[0, 6, 657]`. Anything that is not exactly three
    /// dot-separated integers returns nil rather than guessing -- there is
    /// no `-dev` suffix to special-case here because `CFBundleShortVersionString`
    /// never carries one (`PolterVersion.zig` always emits a bare `X.Y.Z`).
    private static func semver(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return numbers
    }

    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            return x > y
        }
        return false
    }
}
