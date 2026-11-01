import SwiftUI

/// The working-directories page: the v3 two-column shape (task 2643,
/// #2140 M4/W4; the design's `2140/v3/src/04-workdir-trees-mac-dark.html`,
/// its `files.css` / `files2.css` / `files3.css`, and `CHANGES.md`'s
/// 定下来的常量).
///
/// **Left, 296pt wide** (`files2.css`, `.wdl`): 「最近改过」at the top -- a
/// 28pt section bar and its rows, 44pt each and two lines tall -- and under
/// it 「工作目录」, whose body is one root per working directory. A root is
/// 48pt and two lines (name and role over the `~` path), draws the spinner
/// and the count of files being changed while
/// `Workdirs.Dir.editing` says any, and opens onto the files under it.
/// **Right** (`files2.css`, `.wdr`): the file workbench -- a 40pt bar, the
/// code and its line numbers, and a 32pt foot (`files.css`, `.fh` / `.txt` /
/// `.foot`).
///
/// # What this page does not say, and why
///
/// Three of the design's parts have **no data behind them yet**, and this
/// page draws the state rather than a number to fill the gap:
///
/// 1. **「最近改过」.** Its rows are a group's files that changed today, who
///    changed them and when (`2145/PLAN.md` §1.4). The core has the table
///    (`files/Recent.zig`, C5) and nothing feeds it: its own README says
///    "Nothing is wired yet: no App, no hook event, no host calls these",
///    and the page sends none of it. So the section is the bar, its word for
///    the state, and its rule -- **no count**, because a count is a number
///    and `control-room.md` §8.2 settled that one already: 0 and "don't
///    know" are two different things, and a 0 here would be the host
///    claiming to have counted rows nobody sent it.
/// 2. **A root's files.** The design's tree rows come from
///    `files_list(token, rel_dir)` (`2145/PLAN.md` §2.5), which does not
///    exist: the five requests a host may make are open / resolve / propose
///    / commit / close (`rpc.zig`), and none of them lists a directory. An
///    open root therefore draws the one row the design leaves for it -- 一
///    行 28pt, 缩进 24pt, saying 暂无文件.
/// 3. **The workbench's file.** What a preview holds is `PreviewSlot`'s, and
///    this page is where the design puts that same slot. Nothing hands one
///    in yet, so the right side is the shell: the bar, the state, the foot.
///
/// **It reads no `kind` and counts no rows** -- `tools/control-room-hosts-do-not-decide.py`
/// refuses a host that does, and rightly: the page is handed the group's
/// directories and draws them in the order they arrive.
///
/// ⚠️ **`readable` and `why` are not read here either.** A row the core
/// lists and nothing may be read from carries its reason for the preview to
/// say, and this page has no second word for it: inventing one here would be
/// a second answer about which directories may be read, which is the thing
/// `Workdirs.Dir.readable` exists to be the only one of.
struct ControlRoomWorkdirsPage: View {
    typealias Look = ControlRoomLook

    let group: String
    @ObservedObject var model: ControlRoomModel

    @Environment(\.colorScheme) private var scheme

    /// Which roots are open and which row is the selected one, in the host's
    /// memory (`2145/PLAN.md` §2.5: 收起的状态按群记在宿主内存里).
    ///
    /// ⚠️ **One `@State` for the whole page and not one per root**, because
    /// SwiftUI rebuilds this view on every answer and a flag per row would be
    /// a state the view owns rather than a rule: `ControlRoomWorkdirs.Tree`
    /// is where the three gestures and the single selection are decided, and
    /// it is `sources.in` so a test reaches all four.
    @State private var tree = ControlRoomWorkdirs.Tree()
    private var theme: Look.Theme { Look.theme(scheme) }

    /// The directories the core answered with, in the core's order.
    private var dirs: [ControlRoomWorkdirs.Dir] { model.workdirs?.dirs ?? [] }
    /// Their ids, which is what the tree's state is a set of.
    private var ids: [String] { dirs.map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            left
            right
        }
        .background(theme.terminalBackground.color)
        .onAppear { model.refreshWorkdirs() }
    }

    // MARK: - Left

    private var left: some View {
        VStack(spacing: 0) {
            recent
            roots
        }
        .frame(width: Tile.leftWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.line.color)
                .frame(width: CGFloat(Look.Line.hairline))
        }
    }

    /// 「最近改过」: the bar, the state, and the rule under it.
    private var recent: some View {
        VStack(spacing: 0) {
            bar(Tile.recentTitle, count: nil, link: nil)

            empty(Tile.recentEmpty, align: .leading)

            rule(edge: .bottom)
        }
    }

    /// 「工作目录」: the bar, then one root per directory.
    private var roots: some View {
        VStack(spacing: 0) {
            bar(Tile.rootsTitle,
                count: model.workdirs.map { countWords($0.dirs.count) },
                link: dirs.isEmpty ? nil : (Tile.collapseAll, { tree.collapseAll(ids) }))

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
                .onChange(of: ids) { tree.keep(only: $0) }
            } else {
                empty(Tile.rootsEmpty, align: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// One section bar: 28pt, its title, an optional count, an optional link
    /// at the right (`files3.css`, `.roots .rsec`).
    private func bar(_ title: String, count: String?, link: (String, () -> Void)?) -> some View {
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
        }
        .padding(.horizontal, Tile.barPadX)
        .frame(height: Tile.barHeight)
    }

    /// The one line a part of the design says while nothing sends it data:
    /// small, grey, and on the column's own padding -- the same words the
    /// page would put in a body, at the place the design puts a body.
    private func empty(_ words: String, align: Alignment) -> some View {
        Text(words)
            .font(.system(size: Tile.wordsSize))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: align)
            .padding(.horizontal, Tile.bodyPadX)
            .padding(.vertical, Tile.bodyPadY)
    }

    /// A rule, drawn the way the design draws every one of them: half a
    /// point, on one edge of what it separates.
    private func rule(edge: Alignment) -> some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(height: CGFloat(Look.Line.hairline))
            .frame(maxHeight: .infinity, alignment: edge)
    }

    /// One working directory: its root row, and its files when it is open.
    ///
    /// 展开的根上面多空 6，根之间空 2, and the first one has nothing above
    /// it (`files3.css`, `.root + .root` / `.root.open`).
    private func root(_ dir: ControlRoomWorkdirs.Dir, first: Bool) -> some View {
        let open = tree.isOpen(dir.id)
        return VStack(spacing: 0) {
            Button {
                tree.select(dir.id)
                tree.toggle(dir.id)
            } label: {
                rootRow(dir, open: open)
            }
            .buttonStyle(.plain)
            // ⌥-click: 按住 ⌥ 点一个根只展开它 (CHANGES.md, 12-trees-overflow).
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded { tree.solo(dir.id, among: ids) }
            )

            if open { files(dir) }
        }
        .padding(.top, first ? 0 : (open ? Tile.rootOpenGap : Tile.rootGap))
    }

    /// A root: 48pt, two lines -- the name with who is in it, over the path
    /// -- and, while anybody is changing files, the spinner and the count.
    private func rootRow(_ dir: ControlRoomWorkdirs.Dir, open: Bool) -> some View {
        let selected = tree.isSelected(dir.id)
        return HStack(spacing: Tile.rootGapBetween) {
            Image(systemName: open ? Tile.twistyOpen : Tile.twistyShut)
                .font(.system(size: Tile.twistySize))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Tile.twistyWidth)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Tile.rootWordsGap) {
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
                Text(dir.short)
                    .font(.system(size: Tile.wordsSize, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                .fill(selected
                      ? Color.white.opacity(theme.selectionTint)
                      : Color.clear)
        )
        // The bar down the left edge of the selected row, sized and placed
        // as the design places it (`files.css`, `.tr.sel::after`: 3 wide,
        // 16 tall, 1.5 round, 3 in from the left).
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

    /// What is under a root: the files it holds, which nothing sends yet.
    ///
    /// One row, at the height and the indent the design gives a file of the
    /// first level -- 行高 28, and the root's own words start at
    /// `root_pad_x`, one step of 16 in.
    private func files(_ dir: ControlRoomWorkdirs.Dir) -> some View {
        Text(Tile.filesEmpty)
            .font(.system(size: Tile.wordsSize))
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .padding(.leading, Tile.rootPadX + Tile.filesIndent)
            .padding(.trailing, Tile.rootPadX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Tile.filesRowHeight)
    }

    // MARK: - Right

    private var right: some View {
        VStack(spacing: 0) {
            workHead
            workBody
            workFoot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The workbench's bar: 40pt, the path across the top, one action at the
    /// right (`files.css`, `.fh`).
    ///
    /// **One action, and it is the one that says what the pane is.** The
    /// design's other five -- 编辑, 插件, 前进, 后退, 关闭 -- are each a
    /// request this page has nothing to send: the editor is `PreviewSlot`'s
    /// and the other four are a file's history, which is `files_list`'s
    /// world. Drawn, they would be controls that answer nothing.
    private var workHead: some View {
        HStack(spacing: Tile.headGap) {
            Text(Tile.workbench)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
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
            Rectangle()
                .fill(theme.line.color)
                .frame(height: CGFloat(Look.Line.hairline))
        }
    }

    /// Where the file's lines go, and -- with none picked -- the one thing
    /// the page can say about it.
    private var workBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: Tile.emptyGlyph)
                .font(.system(size: Tile.emptyGlyphSize))
                .foregroundStyle(theme.textSecondary.color.opacity(Tile.emptyGlyphOpacity))
            Text(Tile.pickFile)
                .font(.system(size: Tile.wordsSize))
                .foregroundStyle(theme.textSecondary.color)
                .padding(.top, Tile.emptyWordsGap)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Rectangle()
                .fill(theme.line.color)
                .frame(height: CGFloat(Look.Line.hairline))
        }
    }

    // MARK: - Words

    /// The word for a root, which is the last step of the path the core
    /// sent (`work-app` in `~/work/web-app`), or the whole of it for a path
    /// with no step to take.
    ///
    /// ⚠️ **Not the core's `tree_name`**, which is the key
    /// `ControlRoomWorkdirs.swift` says this host deliberately does not
    /// decode -- the gate that holds "a host draws, it does not decide"
    /// refuses a host that reads a second answer about what a row *is*.
    /// What the design's roots are named after is their directory, and this
    /// is that, taken from a field the page already has.
    private func name(of dir: ControlRoomWorkdirs.Dir) -> String {
        let step = dir.short.split(separator: "/").last.map(String.init) ?? ""
        return step.isEmpty ? dir.short : step
    }

    /// Who is in a directory, as the design writes it: the titles, in the
    /// core's order, joined by a `、` ("总管、tests").
    ///
    /// **The words are the core's** (`Workdirs.Dir.who[].title`, and the
    /// role it carries). A local table from `role` to a word would be the
    /// host deciding a second time who a terminal is -- and it is the same
    /// shape as the supervisor's own title, which the rest of the control
    /// room already writes the core's way.
    private func roles(_ dir: ControlRoomWorkdirs.Dir) -> String? {
        let titles = dir.who.map(\.title).filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles.joined(separator: Tile.roleJoin)
    }

    /// ⚠️ **`String(n)` and not `n`.** Only a `String` interpolation becomes
    /// `%@` in the key the table is asked for; an `Int` becomes `%lld`, so a
    /// row written `"\(n) directories"` looks up `%lld directories` and
    /// never finds the `%@ directories` the table holds -- and the gate that
    /// checks this cannot see a type, so it would be the one place the
    /// mismatch lived. Measured by the gate's own author (its NOT CHECKED
    /// section) rather than read off a document.
    private func countWords(_ n: Int) -> String {
        String(localized: "\(String(n)) directories", comment: "工作目录页：标题条右侧的个数")
    }

    private func editingWords(_ n: UInt64) -> String {
        String(localized: "\(String(n)) being changed", comment: "工作目录页：根节点右侧，正在被改的文件个数")
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
/// are generated from (`tools/gen-control-room-look.py`) and has no group
/// for this page yet. The day it gets one, these move there and both hosts
/// read them; until then they belong to the one host that draws the page.
private enum Tile {
    // `files2.css`: `.wdl { width: 296px }`, and `.wdl .tree`'s padding.
    static let leftWidth: CGFloat = 296
    static let bodyPadX: CGFloat = 8
    static let bodyPadY: CGFloat = 4
    static let rootsPadBottom: CGFloat = 16

    // `files3.css`: `.roots .rsec { height: 28px; padding: 0 16px }`, and the
    // title bar's count and link.
    static let barHeight: CGFloat = 28
    static let barPadX: CGFloat = 16
    static let barCountGap: CGFloat = 12

    // ⚠️ **One size for every word on this page but the icons it draws.**
    // The design measures 128 pieces of text on it and every one is 13 --
    // `fs=13` for the section bars, the roots' two lines, the recent rows,
    // the line numbers, the code and the foot (`metrics.json`, the
    // `04-workdir-trees-mac-dark` set), and the machine's own menu font is
    // 13 (`Look.Font.min`). A `size: 11` or `size: 12` for "secondary" text
    // is therefore not a smaller step of the same scale; it is below the
    // floor the repository holds every window to, and the design never had
    // it. What makes a line secondary here is `textSecondary`, not a size.
    static let wordsSize = CGFloat(ControlRoomLook.Font.body)
    static let barSize = CGFloat(ControlRoomLook.Font.body)

    // `files3.css`: `.root { height: 48px; gap: 6px; padding: 0 8px }`, its
    // two lines, its twisty (`14px`), and `.root + .root` / `.root.open`.
    static let rootHeight: CGFloat = 48
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
    // a glance will find; the design's own words for the bar are 你打开以后
    // frontend 改过的行 in the workbench, where the *other* bar lives, in
    // `textTertiary`. Using one colour for both would make a changed line
    // and a selected row the same word.
    static let selBarWidth: CGFloat = 3
    /// 16 = 28 - 6 - 6, aligning with the design's `.tr.sel::after` bar height.
    static let selBarHeight: CGFloat = 16
    static let selBarInset: CGFloat = 3
    static let barRadius: CGFloat = 1.5
    static let twistyWidth: CGFloat = 14
    static let twistySize: CGFloat = 11
    static let twistyOpen = "chevron.down"
    static let twistyShut = "chevron.right"
    static let rootWordsGap: CGFloat = 8
    static let roleJoin = "、"

    // `files3.css`: `.root .busy { gap: 4px }`, and the design's spinner.
    static let busyGap: CGFloat = 4
    static let busyGlyph: CGFloat = 14

    // `files.css`: `.tr { height: 28px }` and one step of 16 a level
    // (`CHANGES.md`: 行高 28，每深一层缩进 16，比根多缩一层). The one row this
    // page draws is a first-level one, so it sits at
    // `rootPadX + bodyPadX + 16`: the root's words start at `root_pad_x`,
    // and every level is another 8 + 16.
    static let filesRowHeight: CGFloat = 28
    static let filesIndent: CGFloat = 24

    // `files.css`: `.fh { height: 40px; padding: 0 8px 0 16px }`, `.txt`'s
    // 12pt, `.foot { height: 32px; padding: 0 16px; gap: 16px }`. The code
    // area's own numbers -- the 48pt number column, the 20pt line and the
    // 3 × 16 bar beside a line -- are the shape a file's lines are drawn in,
    // which arrives with the file.
    static let workHeadHeight: CGFloat = 40
    static let headPadX: CGFloat = 16
    static let headPadRightX: CGFloat = 8
    static let headGap: CGFloat = 8
    static let footHeight: CGFloat = 32
    static let footGap: CGFloat = 16

    // The state a part of the design is in while nothing sends it data: the
    // 28pt bar stays, and the words go where the design puts a body.
    static let emptyGlyph = "doc.text"
    static let emptyGlyphSize: CGFloat = 28
    static let emptyGlyphOpacity: CGFloat = 0.4
    static let emptyWordsGap: CGFloat = 8

    // Every word this page draws itself. **The keys are English**, the way
    // every other key in this app is: `the-mac-strings-still-have-a-chinese-half.py`
    // reads the English ones, and a Chinese key that happens to read right
    // in both languages is a key the gate cannot see at all -- measured, not
    // guessed: its `is_formatting_only` strips `\(...)` and then asks for
    // two ASCII letters, so a literal written in Chinese is classified as
    // having no words in it and is never looked for in the table.
    static let recentTitle = String(localized: "Recently changed", comment: "工作目录页：左栏第一段的标题")
    static let recentEmpty = String(localized: "No file changed today", comment: "工作目录页：最近改过为空时的那一行")
    static let rootsTitle = String(localized: "Working directories", comment: "工作目录页：左栏第二段的标题")
    static let rootsEmpty = String(localized: "No working directory on record", comment: "工作目录页：没有工作目录时的那一行")
    static let filesEmpty = String(localized: "No files", comment: "工作目录页：展开的根下面没有文件节点时的那一行")
    static let collapseAll = String(localized: "Collapse all", comment: "工作目录页：把所有根收起来的那条链接")
    static let workbench = String(localized: "Workbench", comment: "工作目录页：右栏顶栏左侧，没有选中文件时的面包屑")
    static let workbenchKind = String(localized: "Text preview", comment: "工作目录页：右栏顶栏右侧，当前用哪种预览")
    static let pickFile = String(localized: "Pick a file to see its code and its changes", comment: "工作目录页：右栏代码区为空时的提示")
    static let linesCount = String(localized: "0 lines", comment: "工作目录页：右栏底栏左侧的行数")
    /// The legend for the bar beside a changed line. **No `{agent}` in it**,
    /// deliberately: the design writes 你打开以后 frontend 改过的行, and who
    /// changed a line is `PreviewSlot`'s to say -- a placeholder this page
    /// cannot fill would be drawn as the literal braces, and a name it made
    /// up would be a second answer about who changed the file.
    static let theirsLegend = String(localized: "The bars at the left mark lines changed after you opened this file", comment: "工作目录页：右栏底栏右侧，差异竖条的图例")

}
