import Foundation

/// One cell's preview state, and every cell's (task 2634, #2140 M2; the
/// design's `INTERACTION.md` §一 终端格里的预览).
///
/// **This is the memory half of `PreviewLayout`, and it holds the shape
/// and not the numbers.** `PreviewLayout.split` answers *where* the
/// terminal and the preview go for one cell's width, its open flag and the
/// width the divider was dragged to; it is shared with the Windows host
/// line by line and has no memory of its own, on purpose -- a number the
/// two hosts agree on must not be a number that changes per cell.
///
/// What is here is what a cell remembers between two draws: whether its
/// preview is open, what its divider was dragged to, which file it is
/// showing and which ticket it may read it with. Every constant used below
/// is read from `ControlRoomLook.Preview` -- the same source
/// `PreviewLayout` reads -- so a ruling on the width of a preview is still
/// one edit; what is decided here is only where those numbers apply.
///
/// **No view in here.** A cell is named by a `String` the caller has (the
/// surface's id, in the app) and this type never learns what a surface is,
/// which is what lets it be tested with no app, no window and no terminal.
enum PreviewSlot {
    typealias Layout = PreviewLayout
    typealias Look = ControlRoomLook

    /// **The one cell key the control room's two whole-width pages share**
    /// (task 2645, #2140 M3; the design's `INTERACTION.md` §一 和 §二:
    /// 「右栏只有一个『当前文件』」).
    ///
    /// A `Store` remembers a cell by the `String` the caller names it with,
    /// and every terminal pane names itself -- its surface's id -- so two
    /// panes never share one. The chat page and the working-directories page
    /// are the other case: they are not cells of anybody's split tree, they
    /// hold no terminal, and the design says the file opened on one of them
    /// is the file the other is showing. So they name themselves the same
    /// `String`, and sharing falls out of the store that was already there
    /// rather than being a second mechanism -- no moving a file from one key
    /// to another as the person changes pages, and no second place a current
    /// file lives.
    ///
    /// ⚠️ **One constant, named twice**, which is the whole point: two
    /// literals spelled the same in two files are two places to be wrong in
    /// and nothing that notices when one of them is. `ControlRoomChatPage`
    /// and `ControlRoomWorkdirsPage` both name *this*.
    ///
    /// ⚠️ **And it is deliberately not a surface's id.** A terminal pane's
    /// preview is that pane's own (the design: 终端格里的预览是那一个格子
    /// 自己的), so nothing may ever mint a surface id equal to this. The
    /// name has a shape no UUID has, which is why it reads as a sentence.
    static let controlRoomSidebarKey = "control-room-sidebar"

    /// What one cell's preview is doing.
    struct State: Equatable {
        /// The preview is open in this cell.
        var open: Bool = false

        /// The width the divider was dragged to; nil for never dragged.
        ///
        /// ⚠️ **`nil` and a number are two different things**, and the
        /// difference is the design's: 预览默认占格子的一半 is what an
        /// *undecided* cell does, and a cell whose divider was put back to
        /// the default is undecided again. `PreviewLayout.split` takes
        /// exactly this distinction as its `draggedW`.
        var draggedW: CGFloat?

        /// The file this cell is showing, as a route's `rel`: empty is the
        /// ticket's own file, and empty is also a slot that is open with
        /// nothing picked yet (the design: 只点「文件」按钮打开时，右边先是
        /// 这个终端工作目录的「最近改过」，选一个才出内容). An open slot with
        /// no file is a state the page draws, not a reason to close it.
        var rel: String = ""

        /// The ticket the slot was handed, or empty for none.
        ///
        /// **Kept and never derived.** A ticket is minted by the core for
        /// one workdir and one scope, and it is the core's to mint: the
        /// slot holds what it was given. Empty is "no ticket yet", which is
        /// a slot that draws its own emptiness rather than asking for a
        /// file it has no right to read.
        var token: String = ""
    }

    /// Every cell's state. There is no second place a cell's open flag
    /// lives; a store is the whole of the memory.
    struct Store: Equatable {
        private var states: [String: State] = [:]

        init() {}

        /// What the cell `key` is doing.
        ///
        /// **A value, not an optional.** A caller that has to unwrap is a
        /// caller that can forget to, and the answer for a cell nobody has
        /// touched is the same as for one explicitly closed: closed,
        /// never dragged, nothing open.
        func state(_ key: String) -> State { states[key] ?? State() }

        /// Open or close this cell's preview, and change nothing else.
        ///
        /// **Closing keeps the dragged width and the file**: the design's
        /// 「再按一次「文件」按钮，或者 ⌘\」 reopens what was closed. Opening a
        /// cell never dragged opens at the default; one dragged opens where
        /// it was left.
        mutating func set(_ key: String, open: Bool) {
            var s = state(key)
            s.open = open
            states[key] = s
        }

        /// Whether `key`'s preview is open, flipped: the whole of what a
        /// press of ⌘\ (or a press on the 「文件」button) does (task 2645).
        ///
        /// **`open = !open` and nothing else**, so that the two things a
        /// person can do -- the key and the button -- cannot come apart. It
        /// is a method on the store rather than a line in a view because a
        /// view cannot be asked what it did: the control room's chat page
        /// and window controller are outside the package the logic tests
        /// build (`tools/mac-logic-tests.json`), and a toggle written there
        /// could only ever be checked on a running application. Here it is
        /// one call on a value.
        ///
        /// Returns what it left the flag at, so a caller that logs or draws
        /// does not have to read it back and cannot read it before the
        /// write.
        @discardableResult
        mutating func toggle(_ key: String) -> Bool {
            let open = !state(key).open
            set(key, open: open)
            return open
        }

        /// The same flip, for the control room's two whole-width pages:
        /// they are one place to the person, so they are one key here.
        ///
        /// ⚠️ **The pages call this, and never a key.** A page that spelled
        /// the key itself -- even the right one -- would be a second place
        /// the key is written, and the day one of the two is edited the
        /// pages stop sharing with nothing to say so. There is deliberately
        /// no `key` parameter on this and no second spelling of the
        /// constant: the only way to reach the sidebar's state is through
        /// the one name (`controlRoomSidebarKey`, above).
        @discardableResult
        mutating func toggleSidebar() -> Bool { toggle(PreviewSlot.controlRoomSidebarKey) }

        /// The divider in this cell was dragged to `w`, or nil for "put it
        /// back to the default".
        ///
        /// **What is stored is what the drag asked for, before any clamp.**
        /// Clamping against the cell's width as it is *now* would remember a
        /// number that was only right for the window as it was then: a cell
        /// dragged while narrow, then widened, would reopen pinned to the
        /// old cell's limit instead of following the divider the person
        /// left. `PreviewLayout.split` clamps on the way out, against the
        /// width the cell has now, which is the only width that can be
        /// right.
        mutating func setDraggedW(_ key: String, _ w: CGFloat?) {
            var s = state(key)
            s.draggedW = w
            states[key] = s
        }

        /// The file this cell shows and the ticket it may read it with.
        /// Handed in together because a `rel` with no ticket is a file the
        /// slot cannot open: one call, so the two cannot come apart for a
        /// frame.
        mutating func setFile(_ key: String, rel: String, token: String) {
            var s = state(key)
            s.rel = rel
            s.token = token
            states[key] = s
        }

        /// Everything about this cell is gone, and here is the token it was
        /// holding so it can be given back.
        ///
        /// Called when a pane closes or a tab does. **Nothing calls it for a
        /// cell that is merely not drawn**: a tab behind another keeps its
        /// cells' previews (the design: 切到 api，看到的是 api 自己的终端，
        /// api 有没有开预览是它自己的事；切回 frontend，它的预览还在).
        ///
        /// **It returns the ticket rather than closing it**, because a store
        /// that reached the core would be a store that needs a core, and
        /// this one is tested with no app at all. The caller closes what it
        /// is handed (`PreviewTicket.close`); an empty string is "there was
        /// nothing to give back", which is not a failure and not a token.
        @discardableResult
        mutating func forget(_ key: String) -> String {
            states.removeValue(forKey: key)?.token ?? ""
        }

        /// Where a cell `cellW` wide puts the terminal and the preview.
        func split(_ key: String, cellW: CGFloat) -> Layout.Split {
            let s = state(key)
            return Layout.split(cellW: cellW, open: s.open, draggedW: s.draggedW)
        }
    }

    /// The widths a divider may be dragged to in a cell `cellW` wide, or nil
    /// when this cell has no divider -- narrower than the side-by-side
    /// threshold, or not a size at all.
    ///
    /// **The band is `PreviewLayout`'s, asked for and not worked out
    /// again**: the preview's least width at the narrow end, and what leaves
    /// the terminal its least width at the wide end. A second copy of
    /// `440`/`360` here is exactly the drift `PreviewLayout` exists to
    /// prevent, so what is held here is the *shape* -- a band, and nil when
    /// there is none -- and never the numbers.
    static func dragBand(cellW: CGFloat) -> ClosedRange<CGFloat>? {
        guard cellW.isFinite else { return nil }
        let w = max(cellW, 0)
        guard w >= CGFloat(Look.Preview.cellMinWidthSideBySide) else { return nil }
        let lo = CGFloat(Look.Preview.previewMinWidth)
        let hi = w - CGFloat(Look.Preview.terminalMinWidth)
        // A cell exactly at the threshold has `hi == lo` -- a band of one
        // width, and still a band. `hi` under `lo` is answered rather than
        // trapped, the way `PreviewLayout.clamped` answers it: a cell narrow
        // enough to have made them so is the least width the design names.
        return lo...max(hi, lo)
    }

    /// Where a drag to `x` in a cell `cellW` wide lands: inside this cell's
    /// band, or nil when it has none to drag in.
    static func dragged(cellW: CGFloat, to x: CGFloat) -> CGFloat? {
        guard let band = dragBand(cellW: cellW) else { return nil }
        return Layout.clamped(x, band.lowerBound, band.upperBound)
    }
}
