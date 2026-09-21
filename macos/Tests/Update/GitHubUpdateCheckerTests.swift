import Testing
import Foundation
@testable import Ghostty

/// Task 651: a build not cut from a tag or a `feature/vX.Y` branch reports
/// `CFBundleShortVersionString` as `0.1.<commit count>` -- indistinguishable,
/// by the numbers alone, from a real `0.1.x` release. These pin the decision
/// that keeps the two apart: `currentVersionIsAGuess` is a pure function of
/// the `PolterVersionSource` string (see its doc comment for why it is not
/// asked to read `Bundle.main` itself), so this needs no build-environment
/// setup and holds regardless of what this test happens to be built from.
struct GitHubUpdateCheckerTests {
    @Test func fallbackSourceIsAGuess() {
        #expect(GitHubUpdateChecker.currentVersionIsAGuess(source: "fallback"))
    }

    @Test func tagSourceIsNotAGuess() {
        #expect(!GitHubUpdateChecker.currentVersionIsAGuess(source: "tag"))
    }

    @Test func branchSourceIsNotAGuess() {
        #expect(!GitHubUpdateChecker.currentVersionIsAGuess(source: "branch"))
    }

    /// A missing `PolterVersionSource` -- an old Info.plist built before
    /// this key existed, or (measured: `macos/build.nu`, which calls
    /// `xcodebuild` directly and never runs `GhosttyXcodebuild.zig`'s
    /// `POLTER_VERSION_SOURCE=...` argument) a build whose `PolterCommit` is
    /// *also* empty -- must be treated as a guess. It is not "a tag or
    /// branch build that forgot to say so"; it is "unknown", and the build
    /// that produces it is exactly the one whose `CFBundleShortVersionString`
    /// is least trustworthy, since `build.nu` never sets that either.
    @Test func missingSourceIsAGuess() {
        #expect(GitHubUpdateChecker.currentVersionIsAGuess(source: nil))
    }

    /// An empty string reads the same as missing, not as a fourth source.
    @Test func emptySourceIsAGuess() {
        #expect(GitHubUpdateChecker.currentVersionIsAGuess(source: ""))
    }

    /// A value this list has never seen -- a future fourth source that
    /// nobody has taught `currentVersionIsAGuess` about yet -- is a guess by
    /// default. Whitelisting `tag`/`branch` rather than blacklisting
    /// `fallback` is what makes this the outcome rather than a silent
    /// pass-through: the day the sources this is asked about change, this
    /// stays on the safe side without anyone having to remember why.
    @Test func anUnrecognizedSourceIsAGuess() {
        #expect(GitHubUpdateChecker.currentVersionIsAGuess(source: "weird"))
    }
}
