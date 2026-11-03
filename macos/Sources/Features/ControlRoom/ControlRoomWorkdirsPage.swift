import SwiftUI

/// The working-directories page: the v3 three-column shape (task 2643,
/// #2140 M4/W4, and task 2670 S3–S6; the design's
/// `polter-artifacts/2665/v3/`, its `files4.css` and `build2665.py`).
///
/// **Three columns**, left to right: the activity bar (48pt, `files4.css`
/// `.actbar`), the sidebar (296pt, `.wdl`), and the workbench (`.wdr`).
///
/// * **The activity bar** carries 2 marks and a button at its foot
///   (`.actbar-top` / `.actbar-bottom`): 资源管理器 and 搜索, and the button
///   that folds the sidebar. A press on the mark already in front folds it;
///   the button folds it and moves no mark (`ControlRoomWorkdirs.Activity`,
///   which is where all three of those rules live).
/// * **The sidebar** shows one of two things, by which mark is in front. The
///   explorer is 「最近改过」 -- a 28pt bar with a chevron that folds it, and
///   this round its rows stay empty -- over 「工作目录」, one root per working
///   directory and, under a root somebody has opened, **the real file tree**.
/// * **The workbench** is the file a row was clicked on.
///
/// # What this page decides and what it does not
///
/// **Nothing.** Every rule it obeys is a value beside it in
/// `ControlRoomWorkdirs.swift`, which `tools/mac-logic-tests.json` puts in
/// the package the logic tests build -- this file is a `sources.out` entry,
/// so **nothing in it can be reached by a test**. That is why which roots
/// are open is `Tree`'s, which mark is in front is `Activity`'s, which icon a
/// row carries is `Glyph`'s, and which rows the tree has is `nodes(under:)`'s.
/// What is left here is where a box goes and what a click asks for.
///
/// ⚠️ **This page reads no `kind` and counts no rows**: it walks the levels
/// in the order the core sent them and draws them
/// (`tools/control-room-hosts-do-not-decide.py`).
///
/// # The activity bar's ground is the look data's
///
/// The design gives the column a ground of its own (`files4.css`,
/// `.actbar { background: var(--actbar-bg) }`), and that value is now
/// `actbar_bg` in `src/input/control-room-look.json` -- the one document both
/// hosts' look files are generated from -- so this page reads
/// `theme.actbarBg` like every other colour here. **No hex is written in this
/// file**: a second copy of the control room's look here is exactly what
/// `tools/the-control-room-look-is-one-set.py` refuses. The accent used for
/// the mark in front is `attention`, the same blue the design's activity bar
/// uses.
struct ControlRoomWorkdirsPage: View {
    typealias Look = ControlRoomLook
    typealias Activity = ControlRoomWorkdirs.Activity
    typealias Glyph = ControlRoomWorkdirs.Glyph
    typealias Levels = ControlRoomWorkdirs.Levels
    typealias Node = ControlRoomWorkdirs.Node
    typealias Search = ControlRoomWorkdirs.Search
    typealias Split = ControlRoomWorkdirs.Split

    let group: String
    @ObservedObject var model: ControlRoomModel

    /// The one store every preview in the application is kept in, the same
    /// one the chat page's sidebar uses (`Ghostty.App.previewStore`, task
    /// 2645): 「右栏只有一个『当前文件』」, so a file opened on this page is the
    /// file the chat page's sidebar is showing.
    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.colorScheme) private var scheme

    /// Which roots are open and which row is selected, in the host's memory
    /// (`2145/PLAN.md` §2.5: 收起的状态按群记在宿主内存里).
    @State private var tree = ControlRoomWorkdirs.Tree()
    /// The activity bar: which mark is in front, whether the sidebar is
    /// drawn, and whether 「最近改过」 is folded.
    @State private var activity = Activity()
    /// Every level this page has read, and which directories are open under
    /// the roots. **Shut to begin with**: a level is a `files_list` the core
    /// has to walk, so the tree is lazy (the supervisor's scope for task
    /// 2670: 文件树按目录懒加载).
    @State private var levels = Levels()
    /// The search field's text, and the walk it is running.
    @State private var query = ""
    @State private var search = Search(roots: [], query: "")
    /// **The number of the walk that is wanted now.** Every round carries the
    /// number it was started under and writes nothing when it is not this one
    /// (`startSearch` says why a number and not a cancellation).
    @State private var generation = 0
    /// Why a row could not be read, for the one row it belongs to; and why a
    /// file could not be opened. Said on the page, in the core's own words
    /// where the core gave any.
    @State private var refusal: String?

    /// **The width the person dragged the left column to**, and the width of
    /// the box this page was given. Two, because they are two different
    /// things: the column is drawn at `Split.drawn(wanted: asked, …)` -- the
    /// first squeezed into what the second can hold -- and it is `asked`
    /// that is kept, so narrowing the window does not eat the width that was
    /// chosen (`ControlRoomWorkdirs.Split` says why that matters).
    @State private var asked: CGFloat = ControlRoomWorkdirs.Split.width
    @State private var containerWidth: CGFloat = 0
    /// Whether the pointer is on the divider, and whether it is being
    /// dragged: the two things the line is drawn differently for.
    @State private var dividerHovered = false
    @State private var dividerDragging = false
    /// Whether this view pushed a resize cursor and has not popped it. Only
    /// ever set on the systems that predate `pointerStyle` (macOS 14 and
    /// below); on 15 and up nothing is pushed and this stays false.
    @State private var cursorPushed = false

    private var theme: Look.Theme { Look.theme(scheme) }

    /// **Whether the answer in hand is this group's.** `ControlRoomWorkdirs.Answer`
    /// carries the group it was worked out for, and the controller asks the
    /// core on the main queue (`ControlRoomController.refreshWorkdirs`), so
    /// there is a moment after the row changes where the answer still in the
    /// model belongs to the group that was just left.
    ///
    /// ⚠️ **Everything that reads the roots reads this first**, and the two
    /// things that go wrong without it are worth naming, because both are
    /// silent:
    /// * a ticket minted from the old group's directories is a ticket for a
    ///   workdir **this** group may not have. The core answers `no_workdir`,
    ///   and the page draws that as a directory it may not read rather than
    ///   as an ask made with the wrong group's ticket. Stale roots also mean
    ///   stale *paths*, so a listing could be kept under a root the new group
    ///   does not have.
    /// * the tree would draw another group's directories under this group's
    ///   name -- one group's paths on another group's page.
    private var ready: Bool { model.workdirs?.group == group }

    /// The directories the core answered with, in the core's order -- **the
    /// group in front's, or none at all while the switch is in the air**.
    ///
    /// ⚠️ **Empty rather than the old group's**, and the two things that
    /// depends on are worth naming because both go wrong silently: a ticket
    /// minted from the group that was left is a ticket for a workdir *this*
    /// group may not have (the core answers `no_workdir`, which the page
    /// draws as a directory it may not read), and the tree would draw another
    /// group's directories under this group's name.
    private var dirs: [ControlRoomWorkdirs.Dir] { ready ? (model.workdirs?.dirs ?? []) : [] }
    /// Their ids, which is what the tree's state is a set of.
    private var ids: [String] { dirs.map(\.id) }

    /// Whether the page is waiting for the roots of the group in front, as
    /// opposed to having been given them. Drawn as a line of its own rather
    /// than as "no working directory on record", which is a different fact
    /// about a group the core has already answered for.
    private var waiting: Bool { !ready && !group.isEmpty }
    /// The cell this page's workbench lives in -- the same cell the chat
    /// page's sidebar uses, through the one constant that names it.
    private var cell: String { ControlRoomSidebar.key }
    /// What the core is asked with: one source for the ticket and for the
    /// listing, so the two cannot reach two different cores.
    private var source: PreviewTicket.Source { .core(ghostty) }

    var body: some View {
        HStack(spacing: 0) {
            bar
            if activity.open {
                side
            }
            right
        }
        // The page's own box, which is what a drag's x is read against (the
        // handle is offset from the page's leading edge, so its own local
        // space would be 8pt wide and say nothing about where the column is).
        .coordinateSpace(name: Self.pageSpace)
        // **The handle is drawn over the boundary, and only when there is
        // one.** An overlay and not a child of the `HStack`: an 8pt grab area
        // is a hit target, not a column, so it must take no width out of the
        // layout (the approved design `polter-artifacts/2713/v1/index.html`,
        // `.resizer-v`: 8 wide with -4 either side, so it is centred on the
        // boundary). Over the whole page rather than on the side, because a
        // handle drawn as part of the side would have the
        // workbench's own background laid across its right half.
        .overlay(alignment: .leading) {
            if activity.open, drawnSide > 0 {
                divider.offset(x: Tile.actWidth + drawnSide - Split.handle / 2)
            }
        }
        .background(theme.terminalBackground.color)
        // **The container's own width, for the squeeze only.** A
        // `GeometryReader` in the background reports the box this page was
        // given and draws nothing; it is deliberately *not* wrapped round the
        // page, which is a reader that would take the whole window's layout
        // into its own hands (`ControlRoomWorkdirs.Split.drawn` is where the
        // number is used, and it is a rule a test can read).
        .background(GeometryReader { place in
            Color.clear.preference(key: ContainerWidth.self, value: place.size.width)
        })
        .onPreferenceChange(ContainerWidth.self) { containerWidth = $0 }
        .onAppear {
            model.refreshWorkdirs()
            readOpenDirectories()
        }
        .onChange(of: model.workdirs) { _ in
            // **The one entry that acts on an answer**, and the guard is its
            // first line: the answer in hand must be the group in front's
            // (`ControlRoomWorkdirs.Answer.group` against `group`). While a
            // switch is in the air the model still holds the group that was
            // left -- and the core can also answer with a nil or an error --
            // so without this the page would read **the old group's
            // directories** and mint tickets for its workdirs, which the core
            // answers `no_workdir` for.
            //
            // ⚠️ **`model.workdirs` and not `ids`, and the group is why.**
            // `dirs` is empty while the answer is not this group's, so a
            // derived value over it would *not* change when one group's roots
            // are replaced by another's same directory -- `Workdirs.idOf` is
            // a hash of the path, so the same root under two groups is the
            // same id, and the page would go on listing with the ticket
            // minted for the group that was left. `Answer` carries the group
            // it was worked out for, so listening to the answer as a whole
            // fires on the group whether or not the directories differ.
            guard ready else { return }
            // Nothing that can fold or unfold a root is called here: the
            // roots' open/shut state is `Tree`'s and only a click changes it
            // (the supervisor's rule for this page is 不做任何自动折叠).
            // What a root that is open needs is its level read, and a root
            // that was open in the group just left is not open here.
            tree.keep(only: ids)
            levels.forget()
            readOpenDirectories()
            restartSearch()
        }
        .onChange(of: group) { _ in
            // **A pure reset of what is no longer this group's, and nothing
            // else.** The roots of the group in front are not known yet --
            // `model.workdirs` still holds the old answer and `dirs` is empty
            // until it says otherwise -- so nothing here reads a directory,
            // mints a ticket for one, or starts a walk: that is the handler
            // above, which runs when the matching answer lands.
            //
            // ⚠️ **`guard !ready` is what keeps the two handlers from
            // fighting.** Both can run in one turn (a new group and its
            // answer can arrive together), and in *either* order this leaves
            // the page set up exactly once: if the answer landed first, it
            // has already reset and restarted, and this must not wipe it; if
            // this ran first, the answer's handler has not yet, and this is
            // the reset it will build on. Which one ran first is therefore
            // not a thing the page's behaviour depends on.
            guard !ready else { return }
            refusal = nil
            levels.forget()
            search = Search(roots: [], query: "")
            generation &+= 1
        }
        // **Leaving the page stops the walk.** A round is a closure the main
        // queue will run later, and a page nobody is looking at must not go
        // on reading directories -- nor write its results back over the
        // search the next visit starts.
        .onDisappear { generation &+= 1 }
    }

    // MARK: - The activity bar

    /// 48pt, the two marks over the fold button (`files4.css`, `.actbar`).
    private var bar: some View {
        VStack(spacing: 0) {
            VStack(spacing: Tile.actGap) {
                ForEach(Activity.Icon.allCases, id: \.self) { icon in
                    mark(icon)
                }
            }
            .padding(.vertical, Tile.actPad)

            Spacer(minLength: 0)

            VStack(spacing: Tile.actGap) {
                RowHover { over in
                    Button {
                        activity.toggle()
                        // **The two halves of a mark press**, because this button
                        // is the same fold reached from the other end: a column
                        // that has just gone takes the walk with it, and one that
                        // has just come back carries an unfinished walk on rather
                        // than leaving the page saying 「还在找」 for nothing.
                        // The panel has to be the search's for that second half:
                        // unfolding onto the explorer is still a panel nobody is
                        // searching in.
                        if activity.open && activity.icon == .search {
                            resumeSearch()
                        } else {
                            generation &+= 1
                        }
                    } label: {
                        icon(ControlRoomWorkdirs.Mark.collapseSidebar,
                             ink: over ? theme.text : theme.textTertiary)
                            .frame(width: Tile.actItem, height: Tile.actItem)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                                    .fill(over ? theme.windowTabHover.color : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(activity.open
                          ? String(localized: "Collapse the sidebar", comment: "工作目录页：活动栏底部，收起侧栏按钮的提示")
                          : String(localized: "Expand the sidebar", comment: "工作目录页：活动栏底部，展开侧栏按钮的提示"))
                }
            }
            .padding(.vertical, Tile.actPad)
        }
        .frame(width: Tile.actWidth)
        .frame(maxHeight: .infinity)
        .background(theme.actbarBg.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line.color).frame(width: CGFloat(Look.Line.hairline))
        }
    }

    /// One mark of the activity bar, with the bar down its left edge while it
    /// is the one in front (`files4.css`, `.act-item.sel::before`: 3 wide, 8
    /// in from the top and the bottom, rounded on its right).
    ///
    /// **With the pointer on it the mark takes the flat ground and its icon
    /// comes up to the main text** (`.act-btn:hover { color: var(--t1);
    /// background: var(--hover) }`) -- the same two things the design's own
    /// CSS changes, and **the mark in front looks like that whether or not
    /// the pointer is on it** (`.act-btn.active { color: var(--t1) }`), which
    /// is what keeps hover and selected from reading as one state: hover adds
    /// the ground, being in front already had the ink.
    private func mark(_ which: Activity.Icon) -> some View {
        let front = activity.icon == which
        // Which of the two 20-unit drawings this press is about. **Two enums
        // that look alike**: `Activity.Icon` is what a press is about
        // (`explorer`, `search`) and `Mark` is what gets drawn, and the
        // ternary is written with the drawn one's type named so the two are
        // not quietly taken for each other.
        let drawn: ControlRoomWorkdirs.Mark = which == .explorer ? .explorer : .search
        return RowHover { over in
            Button {
                activity.press(which)
                // **Which half of the press this was is read off the state the
                // press left behind**, and there are two of them: the column is
                // still there with the search panel in it, or it is not.
                //
                // *Not there* -- the explorer is in front, or the press just shut
                // the column -- takes the walk with it: the search field and its
                // results are not drawn, and a round still running would go on
                // reading directories for a panel nobody can see.
                //
                // *There* is the case the first version of this got backwards:
                // pressing 搜索 with an unfinished walk behind it must **carry
                // that walk on**, not tick the generation a second time, or the
                // page comes back to 「还在找」 for a walk nothing will finish
                // (`resumeSearch` says how it is told apart from a fresh one).
                if activity.icon == .search && activity.open {
                    resumeSearch()
                } else {
                    generation &+= 1
                }
            } label: {
                icon(drawn, ink: (front || over) ? theme.text : theme.textTertiary)
                    .frame(width: Tile.actItem, height: Tile.actItem)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                            .fill(over ? theme.windowTabHover.color : Color.clear)
                    )
                    .overlay(alignment: .leading) {
                        if front {
                            RoundedRectangle(cornerRadius: Tile.actIndicatorRadius)
                                .fill(theme.attention.color)
                                .frame(width: Tile.actIndicatorWidth)
                                .padding(.vertical, Tile.actIndicatorInset)
                                .padding(.leading, -Tile.actPad)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(which == .explorer
                  ? String(localized: "Explorer", comment: "工作目录页：活动栏第一个图标的提示")
                  : String(localized: "Search", comment: "工作目录页：活动栏第二个图标的提示"))
        }
    }

    // MARK: - The sidebar

    private var side: some View {
        VStack(spacing: 0) {
            if activity.icon == .explorer {
                recent
                roots
            } else {
                searchPanel
            }
        }
        .frame(width: drawnSide)
        .frame(maxHeight: .infinity, alignment: .top)
        // **A zero-width column draws nothing, and clips what it would
        // have.** At a window too narrow for the column and the workbench
        // both, `drawnSide` is 0 -- and a `VStack` whose own frame is zero
        // still draws its children, so the tree would be laid over the
        // workbench. Clipping is what keeps the zero case at zero.
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line.color).frame(width: CGFloat(Look.Line.hairline))
        }
    }

    /// The column's width as drawn: `asked` squeezed into the room this
    /// window has (`ControlRoomWorkdirs.Split.drawn`). **Not `asked`**, which
    /// is what is remembered -- see `Split` for why the two are apart.
    ///
    /// ⚠️ **`containerWidth` is the whole page's width, and the activity bar
    /// is not the column's room.** The bar is a fixed `Tile.actWidth` at the
    /// leading edge, so what the column may take out of the container is what
    /// is left after it -- pass the container whole and the squeeze grants
    /// the column 48pt that are not there, which is exactly the width that
    /// then comes off `minRight`.
    private var drawnSide: CGFloat {
        Split.drawn(wanted: asked, container: max(0, containerWidth - Tile.actWidth))
    }

    /// **The vertical divider between the column and the workbench** (task
    /// 2719 S3; the design's `.resizer-v`).
    ///
    /// The line is the design's: a hairline, and the whole 8pt around it is
    /// the grab area, so the thing is drawn `Split.handle` wide with the line
    /// down its middle. Under the pointer, and while it is being dragged, the
    /// line takes the accent -- `.resizer-v:hover::after, .resizer-v.dragging::after
    /// { background: var(--resizer-hover); width: 2px }`, drawn here at a
    /// hairline's weight, since a 2pt line next to the other hairlines would
    /// read as a different kind of edge.
    private var divider: some View {
        let lit = dividerHovered || dividerDragging
        return ZStack {
            // The grab area, and the hit shape the pointer style and the
            // drag both need: without it the clear box is not hit-tested.
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(lit ? theme.attention.color : theme.line.color)
                .frame(width: CGFloat(Look.Line.hairline))
        }
        .frame(width: Split.handle)
        .frame(maxHeight: .infinity)
        // The resize cursor, the same way the split divider does it: the
        // backported pointer style where it exists (macOS 15+), and a
        // push/pop either side of the hover on the systems that predate it.
        // **The pop is what matters**: a push with nothing to match it leaves
        // the resize cursor on everything under the pointer for the rest of
        // the run.
        .backport.pointerStyle(.resizeLeftRight)
        .onHover { inside in
            dividerHovered = inside
            resizeCursor(inside)
        }
        // **Every way the pointer can leave the handle, and the view with
        // it.** `onHover(false)` is not sent when the view goes away under a
        // pointer that is on it -- a folded column takes the handle with it --
        // so disappearing pops too. Both go through one setter, and it is
        // guarded on what was actually pushed, so the balance is a property
        // of the flag rather than of how many of these ran.
        .onDisappear { resizeCursor(false) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.pageSpace))
                .onChanged { drag in
                    // **`asked` and not `drawn`**: the width is taken from the
                    // pointer's own x, so the column follows the handle rather
                    // than the squeeze it happens to be drawn at. `x` is
                    // measured from the page's leading edge, so the activity
                    // bar's 48 is taken off to get the column's own width --
                    // **the column starts after the bar**, not at the page's
                    // edge.
                    dividerDragging = true
                    asked = Split.asked(drag.location.x - Tile.actWidth)
                }
                .onEnded { _ in dividerDragging = false }
        )
    }

    /// The name the divider's drag reads its x against: the page's own box.
    private static let pageSpace = "ControlRoomWorkdirsPage"

    /// Hold the resize cursor on for as long as the pointer is on the handle,
    /// and let it go exactly once.
    ///
    /// ⚠️ **On macOS 15 and up this does nothing**, because
    /// `.backport.pointerStyle` above is the whole of it there and it does not
    /// leak -- the two are the same idiom `SplitView.Divider` uses, for the
    /// same reason. What it is here for are the systems that predate
    /// `pointerStyle`, where the cursor is a stack this code maintains by
    /// hand: one push, one pop, and neither twice.
    private func resizeCursor(_ on: Bool) {
        if #available(macOS 15, *) { return }
        if on {
            guard !cursorPushed else { return }
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else {
            guard cursorPushed else { return }
            NSCursor.pop()
            cursorPushed = false
        }
    }

    /// 「最近改过」: the bar with its chevron, and -- this round -- its state.
    ///
    /// **Its rows are empty because nothing sends any**, which is a fact
    /// about the core and not about this bit: `files/Recent.zig` is written
    /// and nothing calls it (`files/README.md` says so), and the task's scope
    /// keeps this section to the bar, the chevron and the fold. The design's
    /// 今天 3 个 count is deliberately **not** drawn: a count is a number, and
    /// the host has not counted anything.
    private var recent: some View {
        VStack(spacing: 0) {
            RowHover { over in
                Button { activity.toggleRecent() } label: {
                    HStack(spacing: Tile.barChevronGap) {
                        icon(activity.recentFolded ? .chevronShut : .chevronOpen,
                             ink: (over ? theme.text : theme.textSecondary))
                            .frame(width: Tile.twistyWidth, height: Tile.twistyWidth)
                        Text(Tile.recentTitle)
                            .font(.system(size: Tile.barSize, weight: .semibold))
                            .foregroundStyle((over ? theme.text : theme.textSecondary).color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tile.barPadX)
                    .frame(height: Tile.barHeight)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                            .fill(over ? theme.windowTabHover.color : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !activity.recentFolded {
                empty(Tile.recentEmpty, align: .leading)
            }

            rule()
        }
    }

    /// 「工作目录」: the bar, then one root per directory.
    private var roots: some View {
        VStack(spacing: 0) {
            bar(Tile.rootsTitle,
                // ⚠️ **Counted from the answer only while it is this group's.
                // ** `model.workdirs` still holds the group that was left
                // while the switch is in the air, and the count above an
                // empty list would be that group's number over this group's
                // (blank) page. `dirs` is the guarded list; it is what the
                // rows below are drawn from and what this counts.
                count: ready ? countWords(dirs.count) : nil,
                link: dirs.isEmpty ? nil : (Tile.collapseAll, { tree.collapseAll(ids) }),
                showsRefresh: true)

            if !dirs.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(dirs.enumerated()), id: \.element.id) { i, dir in
                            root(dir, first: i == 0)
                        }
                    }
                    .padding(.horizontal, Tile.bodyPadX)
                    .padding(.top, Tile.bodyPadY)
                    .padding(.bottom, Tile.rootsPadBottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ⚠️ **Two different facts, two different lines.** Waiting for
                // the roots of the group in front is not the same as a group
                // the core has already answered for that has none: the first
                // is a page with nothing to show yet, the second is a page
                // whose answer is that there is nothing. Drawn the same, a
                // slow answer reads as a group with no directories.
                empty(waiting ? Tile.rootsWaiting : Tile.rootsEmpty, align: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// One section bar: 28pt, its title, an optional count, an optional link
    /// at the right (`files4.css`, `.sb-explorer .rsec`).
    ///
    /// ⚠️ **`refresh` puts the design's refresh button at the right end of
    /// this row, and not in a header of its own.** The design draws it in the
    /// sidebar's header (`.sb-head`, 36pt, `build2665.py`: 刷新文件 over the
    /// explorer and 刷新搜索 over the search panel) -- and this page has
    /// never drawn that header. Drawing it now would add a row to both panels
    /// and move everything under them, which is a relayout of the page and
    /// not what this task is for. The section bar is the row this page
    /// already has, at the end where its one button already sits, so the
    /// button goes there.
    private func bar(_ title: String,
                     count: String?,
                     link: (String, () -> Void)?,
                     showsRefresh: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: Tile.barSize, weight: .semibold))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
            if let count {
                Text(count)
                    .font(.system(size: Tile.barSize))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .padding(.leading, Tile.barCountGap)
            }
            Spacer(minLength: Tile.barCountGap)
            if let link {
                Button(action: link.1) {
                    Text(link.0)
                        .font(.system(size: Tile.barSize))
                        .foregroundStyle(theme.text.color)
                        .underline(true, color: theme.textTertiary.color)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if showsRefresh {
                refreshButton(Tile.refreshFiles)
            }
        }
        .padding(.horizontal, Tile.barPadX)
        .frame(height: Tile.barHeight)
    }

    /// The sidebar's refresh button: the design's `IC_REFRESH` in a 24pt box
    /// at the end of the section bar (`files4.css`, `.sb-btn`: 24×24, a
    /// 14-unit drawing inside it, `--t2` until it is hovered).
    ///
    /// ⚠️ **What it does is the whole of task 2699**, and the three parts are
    /// in that order because each depends on the one before:
    ///
    /// 1. `levels.refresh()` forgets what every directory *holds* and
    ///    nothing else -- the group's tickets and the open set stay
    ///    (`Levels.refresh` says why each half is the half it is).
    /// 2. The directories that are open are read again. They must be read
    ///    again **by path and not from the rows**, because the rows come
    ///    from those very levels: after step 1 there is nothing left for
    ///    `readOpenDirectories` to skip, and a directory that has been
    ///    deleted on disk comes back through the core's own refusal
    ///    (`Tickets.list` -> `Access.Refuse.noSuchDir`), which is drawn as
    ///    the sentence it is.
    /// 3. `restartSearch()` throws the running walk away: `generation` is
    ///    ticked, so a round scheduled before this press writes nothing when
    ///    it runs, and the walk is started again from the refreshed levels.
    ///    **Not `startSearch()`**, whose same-query branch would *carry the
    ///    old walk on* -- hits and queue and all -- which is the opposite of
    ///    what a refresh means.
    private func refreshButton(_ tooltip: String) -> some View {
        RowHover { over in
            Button(action: refresh) {
                icon(.refresh, ink: over ? theme.text : theme.textSecondary)
                    .frame(width: Tile.sbButton, height: Tile.sbButton)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row) / 2)
                            .fill(over ? theme.windowTabHover.color : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(tooltip)
        }
    }

    /// Ask the directories again: the levels, the open ones, and the walk.
    private func refresh() {
        guard ready else { return }
        refusal = nil
        levels.refresh()
        readOpenDirectories()
        restartSearch()
    }

    /// The one line a part of the design says while nothing sends it data:
    /// small, grey, and on the column's own padding.
    private func empty(_ words: String, align: Alignment) -> some View {
        Text(words)
            .font(.system(size: Tile.wordsSize))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: align)
            .padding(.horizontal, Tile.bodyPadX)
            .padding(.vertical, Tile.bodyPadY)
    }

    /// A rule, drawn the way the design draws every one of them: half a
    /// point, and nothing else.
    ///
    /// ⚠️ **No `.frame(maxHeight: .infinity, …)`.** It used to take the whole
    /// height of whatever it was laid out in and hang the half point on an
    /// edge of *that*, so 「最近改过」 folded to its 28pt bar still reserved an
    /// empty column under it -- the space the fold was meant to give back to
    /// the tree. A hairline is the line and nothing else, so it is only as
    /// tall as the line. The `edge` argument went with it: it existed to say
    /// which edge of a stretched box the line sat on.
    private func rule() -> some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(height: CGFloat(Look.Line.hairline))
    }

    /// One working directory: its root row, and the tree under it while it is
    /// open.
    ///
    /// 展开的根上面多空 6，根之间空 2, and the first one has nothing above
    /// it (`files3.css`, `.root + .root` / `.root.open`).
    private func root(_ dir: ControlRoomWorkdirs.Dir, first: Bool) -> some View {
        let open = tree.isOpen(dir.id)
        return VStack(spacing: 0) {
            RowHover { over in
                Button {
                    tree.select(dir.id)
                    tree.toggle(dir.id)
                    readOpenDirectories()
                } label: {
                    rootRow(dir, open: open, over: over)
                }
                .buttonStyle(.plain)
                // ⌥-click: 按住 ⌥ 点一个根只展开它 (CHANGES.md, 12-trees-overflow).
                .simultaneousGesture(
                    TapGesture().modifiers(.option).onEnded { tree.solo(dir.id, among: ids) }
                )
            }

            if open { tree(for: dir) }
        }
        .padding(.top, first ? 0 : (open ? Tile.rootOpenGap : Tile.rootGap))
    }

    /// A root: 48pt, two lines -- the name with who is in it, over the path
    /// -- and, while anybody is changing files, the spinner and the count.
    ///
    /// ⚠️ **The chevron is inside the first line, not centred on the two.**
    /// The design draws it dropped between the two lines (`files3.css`,
    /// `.root`'s twisty against its 48pt body) and the user's own review
    /// asked for it otherwise (task 2668, the supervisor's 用户审稿时指出):
    /// 根目录那一行的展开箭头要和根名字（web-app 那一行）垂直居中，不要照
    /// 设计稿画成掉在两行之间偏下的位置. So the twisty and the name are two
    /// children of one `HStack` -- the row's first line -- and the path line
    /// hangs under the name, untouched by either.
    /// ⚠️ **`over` is the pointer, and it is not `selected`.** The ground
    /// under the pointer is the flat one the design's `.tr-row:hover` uses,
    /// and **a selected row keeps its chip instead**: the two are drawn apart
    /// everywhere in the design, and a row that drew hover over a selected
    /// row would lift the row the person is on every time the pointer crossed
    /// it. The twisty comes up to the main text under the pointer
    /// (`.tr-row:hover .tr-twisty { color: var(--t1) }`).
    private func rootRow(_ dir: ControlRoomWorkdirs.Dir, open: Bool, over: Bool) -> some View {
        let selected = tree.isSelected(dir.id)
        let hoverGround = over && !selected
        return HStack(spacing: Tile.rootGapBetween) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Tile.rootWordsGap) {
                    icon(open ? .chevronOpen : .chevronShut,
                         ink: over ? theme.text : theme.textSecondary)
                        .frame(width: Tile.twistyWidth, height: Tile.twistyWidth)
                    Text(name(of: dir))
                        .font(.system(size: Tile.wordsSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                    if let role = roles(dir) {
                        Text(role)
                            .font(.system(size: Tile.wordsSize))
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Tile.rootFirstLine)

                Text(dir.short)
                    .font(.system(size: Tile.wordsSize, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, Tile.twistyWidth + Tile.rootWordsGap)
                    .frame(height: Tile.pathLineHeight, alignment: .leading)
            }

            if dir.editing > 0 {
                HStack(spacing: Tile.busyGap) {
                    ControlRoomGlyph(shown: .working, size: Tile.busyGlyph)
                    Text(editingWords(dir.editing))
                        .font(.system(size: Tile.wordsSize))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Tile.rootPadX)
        .frame(height: Tile.rootHeight)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                .fill(selected ? Color.white.opacity(theme.selectionTint)
                               : (hoverGround ? theme.windowTabHover.color : Color.clear))
        )
        // The bar down the left edge of the selected row, sized and placed
        // as the design places it (`files.css`, `.tr.sel::after`).
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: Tile.barRadius)
                    .fill(theme.text.color)
                    .frame(width: Tile.selBarWidth, height: Tile.selBarHeight)
                    .padding(.leading, Tile.selBarInset)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row)))
    }

    /// The rows under one root, which is the real tree (`nodes(under:)`).
    ///
    /// **A directory that could not be read draws the core's own sentence**
    /// rather than an empty one: 「打不开」 and 「里面是空的」 are two different
    /// things, and a page that drew the second for the first would be saying
    /// there is nothing there.
    private func tree(for dir: ControlRoomWorkdirs.Dir) -> some View {
        ForEach(ControlRoomWorkdirs.nodes(under: dir, in: levels), id: \.path) { node in
            VStack(spacing: 0) {
                row(node)
                if let level = levels.level(node.path), level.more > 0, levels.isOpen(node.path) {
                    moreRow(level.more, depth: node.depth + 1)
                }
                if let why = levels.refusal(node.path), levels.isOpen(node.path) {
                    refusalRow(why, depth: node.depth + 1)
                }
            }
        }
    }

    /// One row of the tree: 28pt, one step of 16 a level, the chevron, the
    /// icon and the name (`files4.css`, `.tr`).
    ///
    /// **Under the pointer the whole row takes the flat ground**
    /// (`.tr-row:hover { background: var(--hover) }`), and the chevron comes
    /// up with it (`.tr-row:hover .tr-twisty { color: var(--t1) }`). **A
    /// selected row keeps its chip**: the two states are the design's two
    /// different things, and hover drawn over a selection would move the row
    /// the person is on whenever the pointer crossed it.
    private func row(_ node: Node) -> some View {
        let selected = tree.isSelected(node.path)
        // ⚠️ **`isOpen`, not `open`**: a local `Bool` named `open` shadows the
        // view's two `open(_:)` methods, and the call below then reads
        // `cannot call value of non-function type 'Bool'`. `swiftc -parse`
        // cannot see that (it checks syntax only); the app build did
        // (`t2681/xcodebuild-direct.log`).
        let isOpen = node.isDir && levels.isOpen(node.path)
        return RowHover { over in
            Button {
                if node.isDir {
                    levels.toggle(node.path)
                    tree.select(node.path)
                    readOpenDirectories()
                } else {
                    tree.select(node.path)
                    open(node)
                }
            } label: {
                HStack(spacing: Tile.treeGap) {
                    // A file has no chevron, and takes the chevron's box so that
                    // the two line up (`build2665.py`'s `build_tree_node`: 文件
                    // 占位保持对齐).
                    if node.isDir {
                        icon(isOpen ? .chevronOpen : .chevronShut,
                             ink: over ? theme.text : theme.textSecondary)
                            .frame(width: Tile.twistyWidth, height: Tile.twistyWidth)
                    } else {
                        Color.clear.frame(width: Tile.twistyWidth, height: Tile.twistyWidth)
                    }
                    icon(for: node, open: isOpen, over: over)
                        .frame(width: Tile.treeIcon, height: Tile.treeIcon)
                    Text(node.name)
                        .font(.system(size: Tile.wordsSize, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Tile.rootPadX + CGFloat(node.depth) * Tile.treeIndent)
                .padding(.trailing, Tile.rootPadX)
                .frame(height: Tile.treeRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                        .fill(selected ? Color.white.opacity(theme.selectionTint)
                                       : (over ? theme.windowTabHover.color : Color.clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// `还有 N 个`, under the directory it belongs to (`Listing.max_entries`).
    private func moreRow(_ n: UInt64, depth: Int) -> some View {
        Text(moreWords(n))
            .font(.system(size: Tile.wordsSize))
            .foregroundStyle(theme.textTertiary.color)
            .lineLimit(1)
            .padding(.leading, Tile.rootPadX + CGFloat(depth) * Tile.treeIndent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Tile.treeRowHeight)
    }

    /// A directory the core refused: **the core's own sentence**, not one
    /// written here. When the core gave none (`why` is nil) the code it
    /// refused with is the only thing there is to say.
    private func refusalRow(_ why: ControlRoomWorkdirs.Failure, depth: Int) -> some View {
        Text(ControlRoomWorkdirs.failureWords(why))
            .font(.system(size: Tile.wordsSize))
            .foregroundStyle(theme.textTertiary.color)
            .lineLimit(2)
            .padding(.leading, Tile.rootPadX + CGFloat(depth) * Tile.treeIndent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Tile.treeRowHeight)
    }

    /// Which of the eight icons this row carries -- `Glyph`'s rule, the
    /// page's drawing.
    ///
    /// **The ink is lifted under the pointer and not by the selection**, the
    /// same way the row's own twisty is: `selected` already says which row
    /// the person is on with the chip and the name at `--t1`, and hover says
    /// the pointer is here. Two different things, two different marks.
    private func icon(for node: Node, open: Bool, over: Bool) -> some View {
        let glyph = Glyph.of(name: node.name, isDir: node.isDir, open: open)
        let ink = (over || tree.isSelected(node.path)) ? theme.text : theme.textSecondary
        return MarkView(strings: glyph.art, artboard: Glyph.artboard)
            .stroke(ink.color, style: StrokeStyle(lineWidth: Tile.treeIconStroke,
                                                  lineCap: .round, lineJoin: .round))
            .frame(width: Tile.treeIcon, height: Tile.treeIcon)
    }

    // MARK: - The search panel

    /// 搜索: the two tabs, the field, and what the walk found (task 2670 S5).
    ///
    /// **搜内容 is drawn and does not work**: the supervisor's scope keeps the
    /// tab on screen and greys it out (界面上保留「搜内容」那个切换按钮，但让
    /// 它置灰), and `Search.Mode.enabled` is where that is decided -- the page
    /// only reads it. **Nothing here reads a file**: what is searched is the
    /// names a `files_list` already handed over (`Search`'s header says why).
    private var searchPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tile.searchTabGap) {
                ForEach(Search.Mode.allCases, id: \.self) { mode in
                    tab(mode)
                }
                // ⚠️ **The design's refresh button, over the search panel**
                // (`.sb-head` 刷新搜索, `build2665.py`): its own row in the
                // design, and this row here -- the search panel has no header
                // and adding one would move everything under it, which is the
                // relayout this task stays out of. The two tabs share what is
                // left, as they already did.
                refreshButton(Tile.refreshSearch)
            }
            .padding(.horizontal, Tile.searchPadX)
            .padding(.top, Tile.searchPadY)
            .padding(.bottom, Tile.searchFieldGap)

            HStack(spacing: Tile.searchTabGap) {
                TextField(Tile.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Tile.wordsSize))
                    .foregroundStyle(theme.text.color)
                    .onSubmit { startSearch() }
                    .onChange(of: query) { _ in startSearch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        search = Search(roots: [], query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Tile.wordsSize))
                            .foregroundStyle(theme.textTertiary.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Tile.searchFieldPadX)
            .frame(height: Tile.searchFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row) / 2)
                    .fill(Color.white.opacity(theme.selectionTint / 2))
            )
            .padding(.horizontal, Tile.searchPadX)
            .padding(.bottom, Tile.searchFieldGap)

            searchStatus
            searchResults
        }
    }

    /// One of the two tabs. **A tab that does not work is drawn and not
    /// pressable** -- a button that answered nothing would be a control the
    /// person presses and gets no reply from.
    private func tab(_ mode: Search.Mode) -> some View {
        let front = mode == Search.mode
        let ink = mode.enabled
            ? (front ? theme.text : theme.textSecondary)
            : theme.textTertiary
        return Text(mode == .content ? Tile.tabContent : Tile.tabFilename)
            .font(.system(size: Tile.wordsSize, weight: front ? .semibold : .regular))
            .foregroundStyle(ink.color)
            .frame(maxWidth: .infinity)
            .frame(height: Tile.searchTabHeight)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row) / 2)
                    .fill(front ? theme.terminalBackground.color : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { /* only the filename tab works this round */ }
    }

    /// What the walk has to say: how many names it found, and -- while there
    /// is more to read -- that it is still looking.
    private var searchStatus: some View {
        HStack(spacing: Tile.barCountGap) {
            Text(matchesWords(search.hits.count))
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .monospacedDigit()
                .lineLimit(1)
            if search.more > 0 {
                Text(moreWords(search.more))
                    .font(.system(size: Tile.wordsSize))
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tile.searchPadX)
        .frame(height: Tile.searchStatusHeight)
    }

    @ViewBuilder
    private var searchResults: some View {
        if query.isEmpty {
            empty(Tile.searchIdle, align: .leading)
            Spacer(minLength: 0)
        } else if search.hits.isEmpty, search.moreToCome {
            empty(Tile.stillLooking, align: .leading)
            Spacer(minLength: 0)
        } else if search.hits.isEmpty {
            empty(Tile.noSuchName, align: .leading)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(search.hits, id: \.path) { hit in
                        hitRow(hit)
                    }
                }
                .padding(.vertical, Tile.bodyPadY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One hit: its icon, its name, and the root it is under -- which of the
    /// group's directories a result came from is the thing a name alone does
    /// not say.
    private func hitRow(_ hit: Search.Hit) -> some View {
        let name = hit.path.split(separator: "/").last.map(String.init) ?? hit.name
        let selected = tree.isSelected(hit.path)
        return Button {
            tree.select(hit.path)
            open(hit)
        } label: {
            HStack(spacing: Tile.treeGap) {
                icon(ControlRoomWorkdirs.Glyph.of(name: name, isDir: false, open: false), node: hit.path)
                Text(name)
                    .font(.system(size: Tile.wordsSize, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(where_(hit))
                    .font(.system(size: Tile.wordsSize))
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tile.searchPadX)
            .frame(height: Tile.treeRowHeight)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row))
                    .fill(selected ? Color.white.opacity(theme.selectionTint) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ glyph: Glyph, node: String) -> some View {
        let ink = tree.isSelected(node) ? theme.text : theme.textSecondary
        return MarkView(strings: glyph.art, artboard: Glyph.artboard)
            .stroke(ink.color, style: StrokeStyle(lineWidth: Tile.treeIconStroke,
                                                  lineCap: .round, lineJoin: .round))
            .frame(width: Tile.treeIcon, height: Tile.treeIcon)
    }

    /// One of the activity bar's marks, one of the design's chevrons, or the
    /// sidebar's refresh button.
    ///
    /// **Two artboards, two strokes** (`files4.css`): the activity bar's
    /// three marks are `g20` with `stroke-width: 1.3` (`Tile.actStroke`), and
    /// the sidebar's own furniture -- the two chevrons and the refresh
    /// button, all `g14` -- is `1.2` (`Tile.twistyStroke`). The box the
    /// mark itself is drawn in is the artboard's side -- `.act-item svg
    /// { width: 20px; height: 20px }` inside a 40pt button, `.sb-btn svg
    /// { width: 14px; height: 14px }` inside a 24pt one -- so the frame the
    /// call site adds around it is the *button*, not the icon.
    ///
    /// ⚠️ **This takes `Mark` and not `Activity.Icon`.** The two enums look
    /// alike and are not the same one: `Activity.Icon` is the two things a
    /// press can be about (`explorer`, `search`) and has no
    /// `collapseSidebar` in it, while `Mark` is the drawings. The activity
    /// bar's own press asks about the first and draws from the
    /// second, so the mark passed here is chosen and not carried over.
    private func icon(_ mark: ControlRoomWorkdirs.Mark, ink: ControlRoomLook.RGBA) -> some View {
        // Named one at a time rather than read off `artboard`: what makes a
        // stroke 1.2 is that the design drew it `g14` beside the tree -- and
        // it is spelled as the three that are, so a mark that one day shares
        // the 14-unit artboard without being one of them does not silently
        // inherit the weight.
        let fourteen = mark == .chevronShut || mark == .chevronOpen || mark == .refresh
        return MarkView(strings: mark.art, artboard: mark.artboard)
            .stroke(ink.color, style: StrokeStyle(lineWidth: fourteen ? Tile.twistyStroke : Tile.actStroke,
                                                  lineCap: .round, lineJoin: .round))
            .frame(width: mark.artboard, height: mark.artboard)
    }

    /// Which root a hit came from, by the name of that directory -- the last
    /// step of the path the core sent, as a root's own label is.
    private func where_(_ hit: Search.Hit) -> String {
        guard let dir = dirs.first(where: { $0.id == hit.workdirId }) else { return "" }
        return name(of: dir)
    }

    // MARK: - The workbench

    private var right: some View {
        VStack(spacing: 0) {
            workHead
            workBody
            workFoot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The workbench's bar: 40pt, the file across it, and the preview's own
    /// kind at the right (`files.css`, `.fh`).
    private var workHead: some View {
        HStack(spacing: Tile.headGap) {
            Text(workbenchTitle)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(Tile.workbenchKind)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.leading, Tile.headPadX)
        .padding(.trailing, Tile.headPadRightX)
        .frame(height: Tile.workHeadHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line.color).frame(height: CGFloat(Look.Line.hairline))
        }
    }

    /// Where the file's lines go, and -- with none picked -- the one thing
    /// the page can say about it.
    ///
    /// **The file itself is not drawn here.** What a preview holds is
    /// `PreviewSlot`'s: this page writes the ticket into the one cell the
    /// chat page's sidebar also names, and draws what the slot holds through
    /// the same `PreviewWebView` that panel uses. A second reader of a file
    /// would be a second answer about what is open.
    @ViewBuilder
    private var workBody: some View {
        let state = ghostty.previewStore.state(cell)
        if !state.token.isEmpty {
            PreviewWebView(token: state.token)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: Tile.emptyGlyph)
                    .font(.system(size: Tile.emptyGlyphSize))
                    .foregroundStyle(theme.textSecondary.color.opacity(Tile.emptyGlyphOpacity))
                Text(refusal ?? Tile.pickFile)
                    .font(.system(size: Tile.wordsSize))
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .padding(.top, Tile.emptyWordsGap)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The foot: 32pt, what is in the pane and what the bars beside the
    /// lines mean (`files.css`, `.foot`).
    private var workFoot: some View {
        HStack(spacing: Tile.footGap) {
            Text(Tile.linesCount)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(Tile.theirsLegend)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Tile.headPadX)
        .frame(height: Tile.footHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line.color).frame(height: CGFloat(Look.Line.hairline))
        }
    }

    /// What the bar says: the file the slot holds, or the word for none.
    private var workbenchTitle: String {
        let rel = ghostty.previewStore.state(cell).rel
        return rel.isEmpty ? Tile.workbench : rel
    }

    // MARK: - Asking the core

    /// Read every directory that is open and has not been read yet.
    ///
    /// ⚠️ **What is asked for is decided here and nothing else is**: which
    /// rows the tree has is `nodes(under:in:)`'s, and a directory that is not
    /// open is not one this asks about (the tree is lazy). Called after
    /// anything that could have opened one -- a root's click, a directory's
    /// click, or the list of roots changing.
    ///
    /// ⚠️ **It does nothing until the answer in hand is this group's**, and
    /// that guard is what keeps the ticket ledger right: a read mints the
    /// root's ticket (`.workdir`, one per root per group, `Tickets.zig`), and
    /// a ticket minted from a directory of the group that was left is one the
    /// core answers `no_workdir` for. The page would draw that as a directory
    /// it may not read rather than as an ask made under the wrong group.
    /// `dirs` is already empty while `ready` is false, so this changes
    /// nothing today -- it is written down so that a caller added later
    /// cannot spend a ticket on the wrong group's root by calling this from
    /// somewhere new.
    private func readOpenDirectories() {
        guard ready, let answer = model.workdirs else { return }
        for dir in dirs where tree.isOpen(dir.id) {
            guard !levels.hasAsked(dir.path) else { continue }
            read(dir.path, rel: "", workdirId: dir.id)
        }
        // ⚠️ **From `Levels.openDirectories` and not from `nodes(under:in:)`**,
        // and after a refresh that is the difference between working and not:
        // a refresh empties the levels, so the rows that named an open
        // directory under a root are gone and a walk over them could not find
        // it to ask about it again. A root's own rows survive (`dirs` is the
        // core's answer, not the levels), which is why the loop above still
        // walks `dirs`. `openDirectories` says the rest.
        //
        // A directory whose `rel` cannot be worked out is dropped rather than
        // asked about: a path no root holds is one no ticket of this group
        // covers, and asking would be a request the core answers `no_workdir`
        // for (`Levels`' `tickets` comment).
        for path in levels.openDirectories where !levels.hasAsked(path) {
            guard let dir = ControlRoomWorkdirs.directory(holding: path, in: answer) else { continue }
            guard let rel = rel(of: path, under: dir) else { continue }
            read(path, rel: rel, workdirId: dir.id)
        }
    }

    /// Where `path` sits under `dir`, which is what a `files_list` takes --
    /// the same subtraction `rel(of hit:)` does for a search result, and the
    /// empty string for the root itself.
    ///
    /// **Built from the core's own paths and nothing else**: the root's path
    /// is the one the core sent and the rest is the names it sent joined on
    /// (`Node`'s comment), so this takes the prefix off rather than making a
    /// path up.
    private func rel(of path: String, under dir: ControlRoomWorkdirs.Dir) -> String? {
        if path == dir.path { return "" }
        let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// One `files_list`: the root's ticket, the request, and the reading of
    /// the answer (`ControlRoomWorkdirs.listingRequest` / `readListing`).
    ///
    /// **The ticket is minted once per root and kept** (`Levels.keepTicket`):
    /// a fresh ticket per directory would spend the core's ledger on
    /// directories the person has already looked at.
    private func read(_ path: String, rel: String, workdirId: String) {
        guard let token = ticket(for: workdirId, path: path) else { return }
        switch source.ask(ControlRoomWorkdirs.listingRequest(token: token, rel: rel)) {
        case .failure:
            levels.keepRefusal(.refusedFile(code: "unavailable", why: nil), at: path)
        case .success(let text):
            switch ControlRoomWorkdirs.readListing(text) {
            case .success(let level): levels.keep(level, at: path)
            case .failure(let why): levels.keepRefusal(why, at: path)
            }
        }
    }

    /// The ticket this root's tree is listed with: the one already kept, or a
    /// fresh one (`.workdir` scope -- a tree shows what is *under* a
    /// directory, which a `.file` ticket would not reach).
    private func ticket(for workdirId: String, path: String) -> String? {
        if let kept = levels.ticket(workdirId) { return kept }
        guard let root = dirs.first(where: { $0.id == workdirId }) else { return nil }
        switch PreviewTicket.open(source, workdirId: workdirId, path: root.path, scope: "workdir") {
        case .success(let answer):
            levels.keepTicket(answer.token, for: workdirId)
            return answer.token
        case .failure(let why):
            refusal = ControlRoomWorkdirs.failureWords(.refusedFile(code: "ticket", why: ticketWords(why)))
            return nil
        }
    }

    private func ticketWords(_ why: PreviewTicket.Failure) -> String {
        switch why {
        case .notReady: return String(localized: "The core is not answering", comment: "工作目录页：拿不到票据时的那一句")
        case .refused(let said): return said
        case .unreadable: return String(localized: "The answer was not a ticket", comment: "工作目录页：票据回答读不懂时的那一句")
        case .notAPath(let said): return said
        }
    }

    /// A file was clicked: it gets a ticket of its own (`.file`, on itself)
    /// and is put in the workbench -- the same cell the chat page's sidebar
    /// names, so the two pages show one file.
    private func open(_ node: Node) {
        guard let dir = dirs.first(where: { ControlRoomWorkdirs.contains($0.path, node.path) }) else {
            refusal = ControlRoomWorkdirs.noDirectory
            return
        }
        switch PreviewTicket.open(source, workdirId: dir.id, path: node.path) {
        case .success(let answer):
            refusal = nil
            ghostty.previewStore.setFile(cell, rel: node.rel, token: answer.token)
            ghostty.previewStore.set(cell, open: true)
        case .failure(let why):
            refusal = ticketWords(why)
            ghostty.previewStore.setFile(cell, rel: "", token: "")
        }
    }

    private func open(_ hit: Search.Hit) {
        let name = hit.path.split(separator: "/").last.map(String.init) ?? hit.name
        open(Node(name: name, path: hit.path, rel: rel(of: hit), isDir: false, depth: 0))
    }

    private func rel(of hit: Search.Hit) -> String {
        guard let dir = dirs.first(where: { $0.id == hit.workdirId }) else { return hit.name }
        let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        return hit.path.hasPrefix(prefix) ? String(hit.path.dropFirst(prefix.count)) : hit.name
    }

    // MARK: - The search walk

    /// A search is asked for on every keystroke, and **each round reads a few
    /// directories and gives the thread back** (`Search.max_asks`): a walk
    /// that read a whole tree before drawing would do one `files_list` per
    /// directory on the app thread, which is the cost `files/README.md`
    /// writes down about `realpath`.
    ///
    /// # A walk that is no longer wanted is dropped, and it is dropped by
    /// # generation rather than by asking the old one to stop
    ///
    /// Every round is scheduled onto the main queue and runs later, so a walk
    /// started for one query can still be in flight when the person types
    /// another character, clicks another mark, selects another group, or
    /// leaves the page. **There is nothing to cancel** -- `Search.round` is
    /// synchronous and the core is asked in the middle of it -- so what stops
    /// the old walk is a number: `startSearch` ticks `generation`, every round
    /// carries the number it was started under, and **a round whose number is
    /// not the current one returns without writing anything**. A walk that
    /// carried on would write its hits, its queue and its levels over the new
    /// search's, which is the shape of bug where an old answer silently
    /// replaces a new question. The same tick is what stops a walk when the
    /// page goes away (`onDisappear`) or the panel is no longer the search's.
    ///
    /// ⚠️ **Nothing is asked for an empty query.** `Search.matches` matches
    /// nothing then, but the *walk* would still read every directory in the
    /// group -- one `files_list` per directory, to find names nothing will be
    /// compared against. Clearing the field is the commonest thing anybody
    /// does to it, so this is the one round that must not happen at all.
    ///
    /// # A walk that is still wanted is carried on, and one that is not is
    /// # started over
    ///
    /// ⚠️ **Ticking the generation is what throws a walk away, so it must not
    /// be ticked for a walk the page still wants.** Pressing 搜索, or
    /// unfolding the column onto the search panel, is a press that does not
    /// change the query: an earlier version ticked the generation for it, the
    /// walk then stopped at its own next round (a round reads the generation
    /// before it writes, and returns without writing when it is not the
    /// current one), and what the page drew from then on was 「还在找」 with
    /// `query` still in the field and `moreToCome` still true. **Nothing was
    /// going to look again**: `searchRound` is scheduled from *inside* a
    /// round, so a round that returns early schedules nothing. A line that
    /// only looked like patience.
    ///
    /// So a call with the same query over an unfinished walk **carries it on**
    /// (`resumeSearch`) and anything else starts over: another query, a query
    /// that was cleared, or a walk that had run out.
    private func startSearch() {
        refusal = nil
        if search.query == query, search.moreToCome {
            resumeSearch()
            return
        }
        restartSearch()
    }

    /// Start the walk over from the page's current roots and query, and let
    /// the field's text stand as it is.
    ///
    /// The roots are re-derived (`searchRoots`) and the walk's own record --
    /// hits, queue and the cap it had reached -- is thrown away: this is used
    /// where the *question* changed (a new query, or a different set of
    /// roots), and carrying the old hits over would answer the new question
    /// with the old answer's names.
    ///
    /// ⚠️ **Nothing is started while the roots in hand are not this group's**
    /// (`ready`): `searchRoots` reads `dirs`, and a walk built on the group
    /// that was left would mint tickets for its workdirs (the core answers
    /// `no_workdir`) and keep its levels under its paths. Typing during the
    /// gap leaves the field's text where it is; the answer arriving is what
    /// starts the walk (`onChange(of: model.workdirs)`).
    private func restartSearch() {
        guard ready else { return }
        search = Search(roots: searchRoots(), query: query)
        generation &+= 1
        guard !query.isEmpty else { return }
        mintTickets()
        searchRound(generation)
    }

    /// Carry on the walk the page already has, under a **new** generation.
    ///
    /// ⚠️ **Ticking the generation and then walking under the new number is
    /// the whole of it**, and it is what a press on 搜索 and the unfold button
    /// need: the rounds already scheduled -- whose number is now stale -- write
    /// nothing when they run, and this one carries the page's own `search`
    /// (hits, queue and the cap it was already at) on from where the last round
    /// left it. The roots are not re-derived and the query is not re-read: this
    /// is the same search, continued, and only the number changes.
    ///
    /// ⚠️ **The same `ready` guard, and here it is the ticket ledger that
    /// depends on it**: `mintTickets` asks the core for one `.workdir` ticket
    /// per root, and a walk carried on across a group switch before the new
    /// answer landed would mint them for the workdirs of the group that was
    /// left.
    private func resumeSearch() {
        guard ready else { return }
        generation &+= 1
        guard search.moreToCome, !search.query.isEmpty else { return }
        mintTickets()
        searchRound(generation)
    }

    /// The places a walk starts at: every root, which is a directory the page
    /// was already given (no read is spent on one).
    private func searchRoots() -> [Search.Place] {
        dirs.map { Search.Place(workdirId: $0.id, path: $0.path, rel: "") }
    }

    /// Mint the ticket each root's tree is listed with, **before the walk
    /// starts and never from inside it**.
    ///
    /// ⚠️ **Inside the round it would be lost, and silently.** A round is run
    /// against a copy of `levels` that is written back when it ends
    /// (`Search.round(in:)` takes it `inout`), so a ticket minted by the
    /// `ask` closure *after* that copy was taken is thrown away by the write
    /// back -- and the next round mints another, spending the core's ledger
    /// (`Tickets.max_tickets`) once per round on the same directory. Minting
    /// here, before the first copy, is what keeps one ticket per root.
    private func mintTickets() {
        for dir in dirs where levels.ticket(dir.id) == nil {
            _ = ticket(for: dir.id, path: dir.path)
        }
    }

    /// One round of the walk, under the generation it was started for.
    private func searchRound(_ started: Int) {
        guard started == generation else { return }
        var walk = search
        guard walk.moreToCome else { return }
        var store = levels
        walk.round(in: &store) { place in ask(place) }
        // The generation is read again: a round asks the core 32 times, and
        // one of those asks can have handed the main queue something that
        // changed the query (`startSearch`) -- reading it only at the top
        // would let this round's copy land on top of the newer search.
        guard started == generation else { return }
        levels = store
        search = walk
        if walk.moreToCome {
            DispatchQueue.main.async { searchRound(started) }
        }
    }

    /// One directory the walk wants: its root's ticket, and the reading of
    /// the answer -- the same two halves `read(_:rel:workdirId:)` uses,
    /// without the storing (the walk keeps its own levels).
    ///
    /// ⚠️ **It reads `levels` and never writes it.** Minting a ticket here
    /// would be a write into a copy that the round's own write-back discards
    /// (see `mintTickets`), so a root with no ticket is a refusal and not a
    /// reason to go and get one.
    private func ask(_ place: Search.Place) -> Result<ControlRoomWorkdirs.Level, ControlRoomWorkdirs.Failure> {
        guard let token = levels.ticket(place.workdirId) else {
            return .failure(.refusedFile(code: "ticket", why: nil))
        }
        switch source.ask(ControlRoomWorkdirs.listingRequest(token: token, rel: place.rel)) {
        case .failure: return .failure(.refusedFile(code: "unavailable", why: nil))
        case .success(let text): return ControlRoomWorkdirs.readListing(text)
        }
    }

    // MARK: - Words

    /// The word for a root: the last step of the path the core sent
    /// (`work-app` in `~/work/web-app`), or the whole of it for a path with
    /// no step to take.
    private func name(of dir: ControlRoomWorkdirs.Dir) -> String {
        let step = dir.short.split(separator: "/").last.map(String.init) ?? ""
        return step.isEmpty ? dir.short : step
    }

    /// Who is in a directory, as the design writes it: the titles, in the
    /// core's order, joined by a `、`.
    private func roles(_ dir: ControlRoomWorkdirs.Dir) -> String? {
        let titles = dir.who.map(\.title).filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles.joined(separator: Tile.roleJoin)
    }

    private func countWords(_ n: Int) -> String {
        String(localized: "\(String(n)) directories", comment: "工作目录页：标题条右侧的个数")
    }

    /// ⚠️ **`String(n)` and not `n`.** Only a `String` interpolation becomes
    /// `%@` in the key the table is asked for; an `Int` becomes `%lld`, so a
    /// row written `"\(n) matches"` looks up `%lld matches` and never finds
    /// the `%@ matches` the table holds -- and the gate that checks this
    /// cannot see a type, so it would be the one place the mismatch lived.
    ///
    /// **And the words are in the literal, not passed in.** A key built by
    /// joining two values (`"\(n) \(word)"`) is a key the translation gate
    /// cannot see at all -- it is not a literal in any file, so nothing would
    /// ever report it missing its Chinese.
    private func matchesWords(_ n: Int) -> String {
        String(localized: "\(String(n)) matches", comment: "工作目录页：搜索结果条上的个数")
    }

    private func moreWords(_ n: UInt64) -> String {
        String(localized: "\(String(n)) more", comment: "工作目录页：一层或一次搜索里还有多少个没画出来")
    }

    private func editingWords(_ n: UInt64) -> String {
        String(localized: "\(String(n)) being changed", comment: "工作目录页：根节点右侧，正在被改的文件个数")
    }
}

/// The width of the box the page was given, reported up from a background
/// `GeometryReader` so that the column can be squeezed to fit it without the
/// reader wrapping the page (`ControlRoomWorkdirs.Split.drawn`).
///
/// ⚠️ **Deliberately not `GeometryReader { … }` round the page's body.** A
/// reader is a view that takes the size it is offered and proposes nothing,
/// so wrapping the page in one is how a page ends up laying itself out by the
/// whole window's numbers instead of its own. The background form measures the
/// box the page already has.
private struct ContainerWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// **Whether the pointer is inside the thing it wraps**, handed to that thing
/// so it can draw its own hover state -- the flat ground the design puts under
/// a row (`.tr-row:hover`, `.sec-row:hover`, `.act-btn:hover`,
/// `.sb-tool-btn:hover` all say `background: var(--hover)`).
///
/// ⚠️ **Hover is not selection.** The design draws them apart wherever it
/// draws both: hover is the ground, while selected carries the chip, the bar
/// and the accent.
private struct RowHover<Content: View>: View {
    @State private var over = false
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(over).onHover { over = $0 }
    }
}

/// The marks of the design's activity bar and tree, drawn: the strings of
/// their `<path>` elements turned into a `Path` on the artboard they were
/// written for.
///
/// **The rule is `ControlRoomWorkdirs.Mark`'s and the drawing is here**, the
/// same split `Glyph` has: which string says which icon is a value a test can
/// read, and turning a string into a curve is a `Path` only a drawing can do.
///
/// ⚠️ **Named `MarkView` and not `PathView`.** SwiftUI already has a
/// `PathView`, and a file-private type with that name would shadow it inside
/// this file -- which is a thing that compiles and then does not do what the
/// line says.
///
/// A string the parser could not read contributes **no segments** and the
/// mark is drawn without it -- `ControlRoomWorkdirs.unreadableMarks` is what
/// names those, and a test asks every mark to be readable, so a mistyped
/// string is caught there rather than drawn as a gap nobody can explain.
private struct MarkView: Shape {
    typealias Segment = ControlRoomWorkdirs.Segment

    let strings: [String]
    /// The side of the box the strings were written for (`viewBox="0 0 14
    /// 14"` is 14, the activity bar's three are 20).
    let artboard: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / max(artboard, 1)
        var out = Path()
        for string in strings {
            var pen = CGPoint.zero
            var start = CGPoint.zero
            for segment in Segment.parse(string) {
                func at(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
                }
                switch segment {
                case .move(let p):
                    pen = p; start = p
                    out.move(to: at(p))
                case .line(let p):
                    pen = p
                    out.addLine(to: at(p))
                case .cubic(let c1, let c2, let p):
                    pen = p
                    out.addCurve(to: at(p), control1: at(c1), control2: at(c2))
                case .close:
                    pen = start
                    out.closeSubpath()
                }
            }
        }
        return out
    }
}

/// The page's own layout numbers, and where each comes from.
///
/// **They are lay-out, not look**: where a box is and how tall it is, read
/// off the design's CSS. The colours are all `Look`'s -- not one is written
/// here -- and every size a *word* is drawn at is `Look.Font`'s.
///
/// ⚠️ File-private, and named for the design's own terms, because
/// `src/input/control-room-look.json` is the one set of look data both hosts
/// are generated from (`tools/gen-control-room-look.py`) and has no group for
/// this page yet. The day it gets one, these move there and both hosts read
/// them; until then they belong to the one host that draws the page.
private enum Tile {
    // `files4.css`: `.wdl { width: 296px }`, and `.wdl .tree`'s padding.
    // ⚠️ **The column's own width is not here**: it is dragged, so it lives
    // with the rules that clamp it -- `ControlRoomWorkdirs.Split.width` --
    // and the page reads it from there like any other rule.
    static let bodyPadX: CGFloat = 8
    static let bodyPadY: CGFloat = 4
    static let rootsPadBottom: CGFloat = 16

    // `files4.css`: `.actbar { width: 48px }`, `.act-item { width: 40px;
    // height: 40px; border-radius: 6px }`, `.actbar-top / -bottom
    // { padding: 8px 0; gap: 4px }`, `.act-item svg { width: 20px; height:
    // 20px }`, and `.act-item.sel::before { left: 0; top: 8px; bottom: 8px;
    // width: 3px; border-radius: 0 2px 2px 0 }`.
    static let actWidth: CGFloat = 48
    static let actItem: CGFloat = 40
    static let actPad: CGFloat = 8
    static let actGap: CGFloat = 4
    static let actIndicatorWidth: CGFloat = 3
    static let actIndicatorInset: CGFloat = 8
    static let actIndicatorRadius: CGFloat = 2

    // `files4.css`: the activity bar's three marks are `g20` with
    // `stroke-width: 1.3`; the tree's `g14` are `1.1` and the chevrons `1.2`.
    static let actStroke: CGFloat = 1.3
    static let treeIconStroke: CGFloat = 1.1
    static let twistyStroke: CGFloat = 1.2

    // `files4.css`: `.sb-explorer .rsec { height: 28px; padding: 0 14px }`,
    // and `.rsec.rsec-toggle { padding: 0 14px 0 8px; gap: 4px }` with a
    // 14pt twisty.
    static let barHeight: CGFloat = 28
    static let barPadX: CGFloat = 14
    static let barCountGap: CGFloat = 12
    static let barChevronGap: CGFloat = 4

    // ⚠️ **One size for every word on this page but the icons it draws.**
    // The design measures 128 pieces of text on it and every one is 13 --
    // `fs=13` for the section bars, the roots' two lines, the tree rows, the
    // search field and its results, the line numbers, the code and the foot
    // (`metrics.md`), and the machine's own menu font is 13 (`Look.Font.min`).
    // A `size: 11` or `size: 12` for "secondary" text is therefore not a
    // smaller step of the same scale; it is below the floor the repository
    // holds every window to, and the design never had it. What makes a line
    // secondary here is `textSecondary`, not a size.
    static let wordsSize = CGFloat(ControlRoomLook.Font.body)
    static let barSize = CGFloat(ControlRoomLook.Font.body)

    // `files3.css`: `.root { height: 48px; gap: 6px; padding: 0 8px }`, its
    // two lines, its twisty (`14px`), and `.root + .root` / `.root.open`.
    static let rootHeight: CGFloat = 48
    /// The first line's box, so that the twisty and the name are centred on
    /// one another and the path hangs under them: 48 = 12 + 24 + 12, and the
    /// name line is 24 of it (`files3.css`, `.root .l1`).
    static let rootFirstLine: CGFloat = 24
    static let rootPadX: CGFloat = 8
    static let rootGapBetween: CGFloat = 6
    static let rootGap: CGFloat = 2
    static let rootOpenGap: CGFloat = 6
    /// `.root .l2 { line-height: 18px }` -- the path line is set tighter than
    /// the name above it, which is what keeps the two inside 48.
    static let pathLineHeight: CGFloat = 18

    // `files.css`, `.tr.sel`: the ground is `--chip` (white opacity in
    // `theme.selectionTint`, light 0.72 / dark 0.11) and the bar is `--bar`.
    // **Two different things on purpose** -- the ground says "this is the
    // row you are on" and the bar says the same thing again for the one row
    // a glance will find.
    static let selBarWidth: CGFloat = 3
    /// 16 = 28 - 6 - 6, aligning with the design's `.tr.sel::after` bar height.
    static let selBarHeight: CGFloat = 16
    static let selBarInset: CGFloat = 3
    static let barRadius: CGFloat = 1.5
    static let twistyWidth: CGFloat = 14
    static let rootWordsGap: CGFloat = 8
    static let roleJoin = "、"

    // `files4.css`: `.root .busy { gap: 4px }`, and the design's spinner.
    static let busyGap: CGFloat = 4
    static let busyGlyph: CGFloat = 14

    // `files4.css`: `.tr { height: 28px }` and one step of 16 a level
    // (`CHANGES.md`: 行高 28，每深一层缩进 16). `.tr .fic` is a 14pt box
    // holding a 14pt icon, and `.tr`'s own gap is 6 (`files4.css`, `.tr`).
    static let treeRowHeight: CGFloat = 28
    static let treeIndent: CGFloat = 16
    static let treeIcon: CGFloat = 14
    static let treeGap: CGFloat = 6

    // `files4.css`: `.sb-btn { width: 24px; height: 24px; border-radius:
    // 4px }` with `.sb-btn svg { width: 14px; height: 14px }` -- the
    // sidebar's refresh button (task 2699).
    static let sbButton: CGFloat = 24

    // `files4.css`: `.search-controls { padding: 10px 14px 8px; gap: 8px }`,
    // `.search-mode-tab { height: 24px }`, `.search-input-wrap { height:
    // 30px; padding: 0 6px 0 10px }`, `.search-status { height: 28px;
    // padding: 0 14px }`.
    static let searchPadX: CGFloat = 14
    static let searchPadY: CGFloat = 10
    static let searchFieldGap: CGFloat = 8
    static let searchFieldPadX: CGFloat = 10
    static let searchFieldHeight: CGFloat = 30
    static let searchTabHeight: CGFloat = 24
    static let searchTabGap: CGFloat = 2
    static let searchStatusHeight: CGFloat = 28

    // `files.css`: `.fh { height: 40px; padding: 0 8px 0 16px }`, and
    // `.foot { height: 32px; padding: 0 16px; gap: 16px }`.
    static let workHeadHeight: CGFloat = 40
    static let headPadX: CGFloat = 16
    static let headPadRightX: CGFloat = 8
    static let headGap: CGFloat = 8
    static let footHeight: CGFloat = 32
    static let footGap: CGFloat = 16

    // The state a part of the design is in while nothing sends it data.
    static let emptyGlyph = "doc.text"
    static let emptyGlyphSize: CGFloat = 28
    static let emptyGlyphOpacity: CGFloat = 0.4
    static let emptyWordsGap: CGFloat = 8

    // Every word this page draws itself. **The keys are English**, the way
    // every other key in this app is: `the-mac-strings-still-have-a-chinese-half.py`
    // reads the English ones, and a Chinese key that happens to read right
    // in both languages is a key the gate cannot see at all -- measured, not
    // guessed.
    static let recentTitle = String(localized: "Recently changed", comment: "工作目录页：左栏第一段的标题")
    static let recentEmpty = String(localized: "No file changed today", comment: "工作目录页：最近改过为空时的那一行")
    static let rootsTitle = String(localized: "Working directories", comment: "工作目录页：左栏第二段的标题")
    static let rootsEmpty = String(localized: "No working directory on record", comment: "工作目录页：没有工作目录时的那一行")
    /// ⚠️ **Not `rootsEmpty`.** This one is drawn while the answer for the
    /// group in front has not arrived (`waiting`): a group the core has not
    /// answered for *yet* is not a group with no directories, and the two
    /// read the same if they share a sentence.
    static let rootsWaiting = String(localized: "Reading the working directories…", comment: "工作目录页：自己的那组工作目录还没回来时的那一行")
    static let collapseAll = String(localized: "Collapse all", comment: "工作目录页：把所有根收起来的那条链接")
    /// The two refresh buttons' tooltips (task 2699), which are the design's
    /// own two words: 刷新文件 over the explorer's tree and 刷新搜索 over the
    /// search panel (`build2665.py`, `title="刷新文件"` / `title="刷新搜索"`).
    ///
    /// ⚠️ **Two strings and not one.** They press the same thing, but a
    /// person looking at the search panel is looking for a refresh *of the
    /// search* -- and the design wrote them apart, so collapsing them here
    /// would be a second answer about what the button does.
    static let refreshFiles = String(localized: "Refresh files", comment: "工作目录页：资源管理器一侧刷新的提示")
    static let refreshSearch = String(localized: "Refresh search", comment: "工作目录页：搜索面板一侧刷新的提示")
    static let workbench = String(localized: "Workbench", comment: "工作目录页：右栏顶栏左侧，没有选中文件时的面包屑")
    static let workbenchKind = String(localized: "Text preview", comment: "工作目录页：右栏顶栏右侧，当前用哪种预览")
    static let pickFile = String(localized: "Pick a file to see its code and its changes", comment: "工作目录页：右栏代码区为空时的提示")
    static let linesCount = String(localized: "0 lines", comment: "工作目录页：右栏底栏左侧的行数")
    /// The legend for the bar beside a changed line. **No `{agent}` in it**,
    /// deliberately: the design writes 你打开以后 frontend 改过的行, and who
    /// changed a line is `PreviewSlot`'s to say.
    static let theirsLegend = String(localized: "The bars at the left mark lines changed after you opened this file", comment: "工作目录页：右栏底栏右侧，差异竖条的图例")

    // The search panel's own words (task 2670 S5).
    static let tabContent = String(localized: "Search in files", comment: "工作目录页：搜索面板的模式页签，本轮置灰")
    static let tabFilename = String(localized: "Search file names", comment: "工作目录页：搜索面板的模式页签，本轮可用")
    static let searchPlaceholder = String(localized: "Type to search file names", comment: "工作目录页：搜索框的占位文字")
    static let searchIdle = String(localized: "Type a name to look for a file", comment: "工作目录页：搜索框还没输入时的那一行")
    static let stillLooking = String(localized: "Still looking", comment: "工作目录页：搜索还没走完、暂时没有结果时的那一行")
    static let noSuchName = String(localized: "No file by that name", comment: "工作目录页：搜索走完且一个都没找到时的那一行")
}
