import Foundation

/// The chat's one right-hand slot (DESIGN-v2 §11.2, contract §Search): it is
/// **closed, a search, or a preview, never two at once**, and every state a
/// search can be in is a different one on purpose.
///
/// **A value, not a view and not a request loop.** The feed that will drive
/// it asks the core and owns the clock; this holds what the person sees and
/// the transitions between those states. Keeping it here is what lets a test
/// walk empty → typing → searching → results → scanning-more → failed →
/// cancelled → located → preview → back without a window or a core.
///
/// **Partial results are not completeness.** `complete` is the contract's
/// `at_end && !gap && !restarted`; a `budget` page that has been scanned
/// through with no hits is `.scanningMore`, never "no results".
struct ControlRoomChatSidebarState: Equatable {
    enum Mode: Equatable {
        case closed
        case search
        case preview
    }

    /// The search's own state. `.searching` and `.scanningMore` differ: the
    /// first has nothing to show yet, the second has results and is still
    /// looking for more.
    enum Search: Equatable {
        case idle
        /// The person typed; the debounce has not fired.
        case waiting
        case searching
        case results
        case scanningMore
        /// There are results and a page cursor, but **no job is running**:
        /// the slot was paused (closed, preview, tab). Load more continues.
        case paused
        case emptyQuery
        case noResults
        /// The scan stopped over damaged records and cannot go on: partial
        /// results, never "no results" and never complete.
        case partial
        case failed(String)
        case cancelled
    }

    struct PreviewSource: Equatable {
        var group: String
        var anchor: String
        /// The exact raw reference from the message; never rebuilt here.
        var reference: String
        /// The core's opaque position hint from the same message, kept with
        /// the source so a re-open or eviction does not have to guess it.
        var location: String?
        /// Who said it, and when: the preview's shell names the message the
        /// file came from (DESIGN-v2 §6). Empty/zero for a source made
        /// without a message, which is then not named.
        var author: String = ""
        var atMs: Int64 = 0
    }

    enum Preview: Equatable {
        case none
        case loading(PreviewSource)
        case ready(PreviewSource)
        case failed(PreviewSource, String)
    }

    /// What "back to search" restores: the query, the hits, the selected
    /// result and the page cursor, so the right side comes back as it was.
    struct SavedSearch: Equatable {
        var query: String
        var submitted: String
        var hits: [ControlRoomChatSearch.Hit]
        var selected: String?
        var nextToken: String?
        var complete: Bool
        var dirty: Bool
        var hitsTrimmed: Bool
        var search: Search
    }

    var mode: Mode = .closed
    /// What is in the field right now.
    var query = ""
    /// The canonical query the results belong to.
    var submitted = ""
    var search: Search = .idle
    var hits: [ControlRoomChatSearch.Hit] = []
    var selected: String?
    var nextToken: String?
    var complete = false
    /// **Sticky**: a gap or a restart seen on any page keeps the whole search
    /// incomplete, even if a later page reports a clean end.
    var dirty = false
    /// The result list reached its bound; older matches were released and
    /// only a fresh search can bring them back.
    var hitsTrimmed = false
    var preview: Preview = .none
    var saved: SavedSearch?

    /// How many hits are held. The same bound as the message window: a
    /// search is not a reason to grow without limit.
    static let hitLimit = 500

    /// Whether the results shown are still being searched for.
    var hasMore: Bool { nextToken != nil && !complete }

    // MARK: - The slot

    mutating func openSearch() {
        mode = .search
        preview = .none
        if query.isEmpty, submitted.isEmpty {
            search = .idle
        } else if case .emptyQuery = search {
            search = .idle
        }
    }

    /// Closing the slot keeps the field and the results for a later opening;
    /// **it never clears the left side's reading anchor** (that is the
    /// page's, not this slot's).
    mutating func close() {
        mode = .closed
        preview = .none
        saved = nil
    }

    mutating func openPreview(_ source: PreviewSource) {
        if mode == .search {
            saved = SavedSearch(
                query: query, submitted: submitted, hits: hits,
                selected: selected, nextToken: nextToken,
                complete: complete, dirty: dirty, hitsTrimmed: hitsTrimmed,
                search: search
            )
        }
        mode = .preview
        preview = .loading(source)
    }

    mutating func previewReady() {
        guard case let .loading(source) = preview else { return }
        preview = .ready(source)
    }

    mutating func previewFailed(_ code: String) {
        guard case let .loading(source) = preview else { return }
        preview = .failed(source, code)
    }

    /// Back to the query, results, selection and scroll cursor that opened
    /// the preview. A preview not opened from a search has nothing to
    /// return to and closes the slot instead.
    mutating func backToSearch() {
        guard let saved else {
            close()
            return
        }
        query = saved.query
        submitted = saved.submitted
        hits = saved.hits
        selected = saved.selected
        nextToken = saved.nextToken
        complete = saved.complete
        dirty = saved.dirty
        hitsTrimmed = saved.hitsTrimmed
        search = saved.search
        self.saved = nil
        mode = .search
        preview = .none
    }

    // MARK: - Typing and submitting

    /// **A new query discards the old results**, so a stale page cannot be
    /// drawn under new words. The debounce is the driver's; this only says
    /// what the field now means.
    mutating func typing(_ text: String) {
        query = text
        selected = nil
        hits = []
        nextToken = nil
        complete = false
        dirty = false
        hitsTrimmed = false
        if ControlRoomChatQuery.trim(text).isEmpty {
            submitted = ""
            search = .emptyQuery
        } else {
            search = .waiting
        }
    }

    /// Return pressed (or the debounce fired): the canonical query to send,
    /// or nil when there is nothing to send. **A whitespace-only query is
    /// not sent as "match everything".**
    mutating func submit() -> String? {
        do {
            let canonical = try ControlRoomChatQuery.canonical(query)
            // **A fresh search starts from nothing**: accumulated hits, the
            // page cursor and the sticky gap belong to the previous words.
            submitted = canonical
            hits = []
            selected = nil
            nextToken = nil
            complete = false
            dirty = false
            hitsTrimmed = false
            search = .searching
            return canonical
        } catch {
            submitted = ""
            search = .emptyQuery
            return nil
        }
    }

    /// A new query while a scan is out: the driver cancels the old job and
    /// keeps no hits from it.
    mutating func beginAnswering() {
        search = hits.isEmpty ? .searching : .scanningMore
    }

    /// A retry of the current question: keep the hits and the page cursor
    /// that are already here.
    mutating func retryAnswering() {
        search = hits.isEmpty ? .searching : .scanningMore
    }

    /// The slot is being closed, hidden or replaced by a preview. A page
    /// that was out is over; results and their cursor stay, and the next
    /// opening can continue or ask again.
    mutating func pause() {
        switch search {
        case .waiting, .searching:
            search = hits.isEmpty ? .idle : .paused
        case .scanningMore:
            search = .paused
        default:
            break
        }
    }

    // MARK: - Pages

    /// One ready page. Results keep the core's newest-first order and are
    /// deduplicated by the stable message anchor; **a page that is not
    /// complete never says "no results"**.
    mutating func absorb(_ page: ControlRoomChatSearch.Ready) {
        var known = Set(hits.map(\.message.anchor))
        for hit in page.results where !known.contains(hit.message.anchor) {
            hits.append(hit)
            known.insert(hit.message.anchor)
        }
        nextToken = page.nextToken
        // **Sticky**: one dirty page keeps the search incomplete; a later
        // clean end cannot take that back.
        dirty = dirty || page.gap || page.restarted
        complete = page.complete && !dirty
        if hits.count > Self.hitLimit {
            // **Drop the newest, keep the edge being scanned.** Dropping the
            // tail while the token moves on loses the older matches the next
            // page is about to bring; a sliding window keeps paging possible
            // and a fresh search brings the newest back.
            let excess = hits.count - Self.hitLimit
            hits.removeFirst(excess)
            hitsTrimmed = true
            if let selected, !hits.contains(where: { $0.message.anchor == selected }) {
                self.selected = nil
            }
        }
        let stopped = page.nextToken == nil
        if hits.isEmpty {
            search = complete ? .noResults : (stopped ? .partial : .scanningMore)
        } else {
            search = complete ? .results : (stopped ? .results : .scanningMore)
        }
    }

    mutating func fail(_ code: String) {
        search = .failed(code)
    }

    mutating func cancel() {
        search = .cancelled
    }

    mutating func select(_ anchor: String) {
        guard hits.contains(where: { $0.message.anchor == anchor }) else { return }
        selected = anchor
    }

    /// The result the person picked, if it is still in the list.
    var selectedHit: ControlRoomChatSearch.Hit? {
        guard let selected else { return nil }
        return hits.first { $0.message.anchor == selected }
    }
}

/// Where the chat page's one right-hand slot goes (DESIGN-v2 §4/§11.2; the
/// v5 prototype's 1000px narrow state).
///
/// **The threshold is the preview rule's own number**, `preview.
/// cell_min_width_side_by_side` (800), read from the same data rather than
/// added up again (the supervisor's ruling of 2026-11-05): a page at least
/// that wide puts the slot beside the message column; a narrower one lays it
/// over the message column's **right edge** and leaves the column its full
/// width. What is the chat's own is the slot's width, `chat.sidebar_width`
/// (330) -- the number the narrow prototype draws.
///
/// **Not `PreviewLayout.split`**, and not a second copy of it either: the
/// terminal's preview splits a *terminal and a preview* with a drag band, a
/// left expose and a dimmed terminal behind it, and the chat's slot has none
/// of those. The one thing the two share is the threshold, and that is read
/// from the look, not written here.
enum ControlRoomChatSidebarLayout {
    typealias Look = ControlRoomLook

    struct Split: Equatable {
        /// The message column. **Full page width when the slot is over it.**
        var messageWidth: CGFloat
        var sidebarX: CGFloat
        var sidebarWidth: CGFloat
        /// The slot is over the message column rather than beside it.
        var overlay: Bool
    }

    static func split(pageW: CGFloat, open: Bool) -> Split {
        // A page is a size. A negative, a NaN or an infinity is a caller
        // that has lost its place, and the rule is only written for sizes;
        // show it nothing rather than a page turned inside out (`max(NaN, 0)`
        // is NaN in Swift, as `PreviewLayout.clamped` says).
        let w = pageW.isFinite ? max(pageW, 0) : 0
        guard open else {
            return Split(messageWidth: w, sidebarX: 0, sidebarWidth: 0, overlay: false)
        }
        let wanted = CGFloat(Look.Chat.sidebarWidth)
        let sidebar = min(wanted, w)
        if w >= CGFloat(Look.Preview.cellMinWidthSideBySide) {
            return Split(messageWidth: w - sidebar, sidebarX: w - sidebar,
                         sidebarWidth: sidebar, overlay: false)
        }
        // Over the right edge: **the message column is not squeezed**.
        return Split(messageWidth: w, sidebarX: w - sidebar,
                     sidebarWidth: sidebar, overlay: true)
    }
}
