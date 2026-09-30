import Foundation

/// Where the About group's buttons go. Polter's own repository and docs,
/// not upstream's: an issue tracker that has never heard of this program is
/// no help to somebody reading the About page. Upstream is linked as what
/// Polter is built on.
///
/// A file of its own so that the leak gate's allowance for the fork's public
/// name (`tools/no-local-identifiers.py`, KNOWN) covers these three lines
/// and nothing else.
enum PolterLinks {
    static let github = URL(string: "https://github.com/Lugia123/polter")!
    static let docs = URL(string: "https://github.com/Lugia123/polter/tree/main/docs/poltergeist")!
    static let upstream = URL(string: "https://github.com/ghostty-org/ghostty")!
}
