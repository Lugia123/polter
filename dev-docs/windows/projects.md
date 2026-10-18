# Windows 宿主的「项目」：哪页是哪页、随改随存、整个打开

> 状态（任务 #1496 两批都交了，2026-10-13）：**规则有测试；宿主接线交叉编译通过，一次都没有在 Windows 上跑过。**
> 设计：`control-room-design/v20/DESIGN.md`；两端契约：[`../poltergeist/projects.md`](../poltergeist/projects.md)。
> 还没做的在第 4 节，上测试机要看的在第 5 节。

## 1. 分在哪

| 在哪 | 是什么 | 怎么验 |
| --- | --- | --- |
| `windows/projects`（crate `polter-projects`，不依赖 Win32） | 规则：`pages`（开着的页照现在写、没开着的页原样留；窗口与页的次序、哪页在前、frame；说不出目录/说不出是谁的格子保留文件里的）、`placement`（一个窗口开成自己的窗口还是当前窗口的标签页；屏外夹回）、`autosave`（合并写盘与最晚时刻） | mac 上 `cargo test -p polter-projects` |
| 同一个 crate 的 `stated` / `orders` / `page_rules` | 向核心说的那一句（六个键）与另外三句；核心的待办单怎么读、每一条现在还要不要做；界面上关于「页」的规则（mac `ProjectPageRules.swift` 逐条） | 同上；`stated` 写出的字节与核心的测试吃同一份夹具 `src/poltergeist/testdata/host_project_acts.jsonl` |
| `windows/projectfile` | 文件格式（与 `src/Project.zig` 同一份），`front_tab()` 给缩略图用 | `cargo test -p polter-projectfile` |
| `windows/host/src/project_session.rs` | 哪个开着的标签页是哪个项目的哪一页；改动来了记一笔、到点写盘；整个打开 | 只能上测试机 |
| `windows/host/src/project_ui.rs` | 一页 ↔ 一棵分屏树（`tab_tree` / `name_leaves` / `open_page_in_new_tab`） | 纯的部分有测试，其余上测试机 |

规则与 mac 的 `ProjectPages.swift`（分支 cr/project，#1491）是同一张表，`windows/projects/src/tests.rs`
是 `ProjectPagesTests.swift` 逐条移过来的。

**没有进对照闸，差在这里**：`ProjectPages.swift` 还不在主线上（这棵树里没有那个文件），而且它在 #1495 里
正给叶子加 `bySupervisor`，格式没定。两边都落到主线后，可以做的对照是「同一份文件 + 同一组开着的页 →
两边写出的文件逐字节相同」（`frame.origin` 一个 `top-left` 一个 `bottom-left`，夹具里要各写各的）。

## 2. 随改随存

改动发生的地方调 `project_session::note(哪一类)`，每个开着的项目各有一个 `Debounce`：

| 哪一类 | 从哪里记 | 最晚 |
| --- | --- | --- |
| 布局（分屏、关格子、比例） | `tabs::run_ops` 每个操作（标题除外） | 3 秒 |
| 页的增减与次序 | 同上；打开项目之后 | 3 秒 |
| 哪页在前 | `tabs::set_active` | 3 秒 |
| 窗口位置大小 | `WM_SIZE` / `WM_MOVE` | 10 秒 |
| 标题、目录 | `Op::SetTabTitle`、`tabs::rename_tab`（标签条上改名不经过 `run_ops`）、`set_cwd_for_surface` | 30 秒 |

安静 1 秒就写；一直不安静，到「最晚」也写。数值与 mac 一致。「哪个项目变了」不问——每个开着的项目都记一笔，
只会改时间的写盘本来就不落盘（`project::write_file`）。

**退出时每个开着的项目存一次**：`WM_CLOSE`、`winid::close_window_now`、`WM_ENDSESSION(wParam≠0)` 都先
`save_all()`。**关一页不等于移出**：`tabs::destroy_tab_at` 在标签页还在的时候调 `tab_closing`，带着这一页
再存一次（这是自动保存里唯一抓整份回滚的一次），然后只解除「开着」，页留在项目里。

设置窗口里的三件事跟着走：改名 → `moved`（开着的页跟到新文件，否则下一次自动保存会把旧文件写回来）；
删除、恢复上一版 → `forget`（标签页留着，不再是任何项目的页——否则会把刚删的写回来、把刚恢复的盖掉）。

### 2.1 分屏的标记（format 3，任务 #1700）

颜色、「不在此终端开 worker」、护盾、总管格存在叶子上（契约：`pane-color-interface.md` §7，
格式：`src/Project.zig`）。颜色、workers、护盾是**核心里那个终端的属性**，宿主只是转述：

- **存**：`project_ui::tab_tree` 从分屏取——颜色和 workers 来自这一格最后收到的 `poltergeist_pane`，
  护盾来自它自己的 mark；总管格只在 mark 说 role = supervisor 的那一格写 true，其余格写「不知道」，
  由 `polter_projects::pages` 的 `one_seat` 定：屏上有一格说了 true，屏上其它格都写 false；
  一格都没说（总管不在），各格沿用文件里的。标记变化记作「标题、目录」那一类（30 秒）。
- **开**：叶子的三个标记随 layout 的 `new` 单元走（键 `marks`，只有项目来源接受，工具来源拒绝），
  格子建好、装进标签页、锁放开之后，`tabs::hand_back` 对非默认值发 `poltergeist_set_pane_color:<c>` /
  `poltergeist_set_workers:refused` / `poltergeist_set_shielded:on`，核心当场推回。
- ⚠️ **竞态**：核心对新终端的第一句话是全默认，而且是在 `ghostty_surface_new` 里、交回之前说的；
  项目刚开几秒就会自动保存。所以带标记的恢复格从「不知道」开始（`PaneMarks::restored`，
  `polter_projects::handback::Waiting`），交回之前的推送一律不认；存盘时「不知道」走
  `keeping_what_the_file_knew` 取文件里的值。判据：`polter-projects` 的
  `a_save_before_the_marks_are_taken_back_writes_what_the_file_had`。
- 旧版本（只读到 format 2）遇到 format 3 报 `TooNew` 拒读；新版本存一次 format 2 文件就把它升成 3
  （`found_on_disk` 把升格式当布局变化，留 `.prev`）。

### 2.2 有人取的名字（format 3，任务 #1722）

规则（issue #9，`src/apprt/title.zig`）：有人取的名字压过程序报的标题（OSC 0/2）并且钉住；**程序的标题不从项目里恢复**。
格式：`Project.zig` 模块注释——标签页 `{"root":…,"title":S}`（没有就不写），叶子 `"title"` 之后紧跟
`"title_chosen":true`（只在为真且标题非空时写）。夹具 `test/project-format/titles.json`。

- **这个宿主没有「每格一个取的名字」**：显式的 `set_surface_title` 钉的是那一格所在的整个**标签页**
  （`Op::SetTabTitle` → `rename_tab(NamedBy::Tool)`）。所以：
  - **存**：标签页的 `title` = `title_override.text`（谁钉的都算：User / Tool / Restored），没有就不写
    （`tabs::chosen_name_of_tab` → `Live::title`）；叶子的 `title` 仍是那一格程序报的标题，`title_chosen`
    在 Windows 上恒为 false（`project_ui::tab_tree` 的注释）。
  - **开**：标签页建好之后、成为页之前，`polter_projects::pages::restored_name` 给出名字就
    `rename_tab(…, NamedBy::Restored)`（与重开关掉的标签页同一做法）。名字取标签页自己的 `title`；没有时，
    这个标签页里**恰好一格** `title_chosen`（mac 写的）就用它——这正是 Windows 上 `set_surface_title`
    当场会做的事；两格以上不猜。程序的标题什么也不做。
- **竞态**：改名在 `open_page_in_new_tab` 返回之后立刻做，早于这一页进 `bound`（以及循环之后的 `OPEN`），
  所以打开后那次立即保存看到的已经是改过名的标签页。万一有一次保存先看到没名字的标签页：`Live::title`
  为 `None` 时 `Pages::saving` 取文件里这一页的 `restored_name`，不写「没有名字」。判据：`polter-projects` 的
  `a_save_before_the_name_is_put_back_writes_what_the_file_had`。⚠️ 这条成立是因为这个宿主**没有办法把取的名字拿掉**；
  将来加了「恢复程序标题」，`Live::title` 必须变成三态。
- **已知的损失**：mac 在同一个标签页里给两格以上各取了名字、标签页本身没名字——Windows 打开时不改名，
  下一次保存把这些格写成 `title_chosen` 缺省，名字只剩作为「程序标题」的那份文字，mac 再打开不会恢复。

## 3. 整个打开

`project_session::open`：文件里每个窗口，凡是有页没开着的——

- 这个窗口已有页开着 → 缺的页补在那个窗口里；
- 否则问 `placement::place`：记过 frame（`origin` 是 `top-left`、数值像样）→ 开成自己的窗口，放在那里；
  没记过、或 frame 是 mac 写的（`bottom-left`）→ 开成当前窗口的标签页；没有当前窗口 → 开一个不指定位置的窗口；
- 整个项目已经开着 → 切到它的第一页并把窗口提到前面，不再开任何东西。

每个窗口里原来在前的那页会被切到前面。

**屏外夹回**：frame 整个落在某个显示器的工作区里就照用；否则挑与它重叠最多的那个工作区（都不重叠就第一个），
先把宽高限到工作区之内，再把左上角挪进去。

**DPI（代定，待总管/用户改）**：frame 存的是物理像素（`GetWindowRect`；最小化/最大化时取
`rcNormalPosition`），打开时照原数 `SetWindowPos`，**缩放比例变了不换算**，只做上面的夹回。理由：存一个
「当时的缩放比例」要给文件加字段，而 mac 那边没有对应物；不换算的后果是窗口在高缩放下显得小一些，不会丢。

## 4. 与核心互相告知（第二批）

- **陈述**（`project_session::state`）：每次全部、六个键全写。项目目录里的每个文件一项；开着的项目的 `open` 是上一次
  保存时每页各格的终端号，`supervisor` 是文件标成总管的那一格里现在的终端（按那一页的第几格数出来；页在保存后又变了、
  格数对不上时不说，等下一次保存）。`workers` 现在恒为 `[]`——项目文件还没有「总管开的」那个记号（`by_supervisor`）。
  发之前先用 `stated::refusal` 查一遍核心会拒的四种情形，会被拒就不发并在日志里写明是哪个项目；与上一句相同就不重发。
  什么时候说：第一版快照到达时、每次保存/打开/另存/关页/加入/移出/改名/删除之后。
- **待办单**（`project_session::told` → `obey`）：每版快照把 `project_orders` 过一遍，`orders::step` 说这一条现在还要不要做
  （已经是那个样子就不做）。每条在核心持续要它的期间只做一次，做没做成都记一行日志；核心不再要它之后再出现才会重做。
  `open` 找不到文件 → 发 `project_failed`（`not_found`）；文件读不出 → `unreadable`。
- **先问再做**：移出一页之前问 `project_remove`（被拒 `SupervisorPage` 就说那句话、不移）；设置窗口里改名之前问
  `project_rename`（项目是某个群的 → 核心去改群名，改名作为 `rename` 待办回来，宿主不自己改）。
- **总管那格只起 shell**：打开项目只还原终端，不启动任何 agent；打开之后立刻存一次并重说，核心从 `supervisor` 拿到终端号。

## 4a. 界面（第二批）

| 哪里 | 有什么 |
| --- | --- |
| Project 菜单 | 原有三行之下加四行：加入项目…、把这一页移出项目、重命名项目…、关闭项目。按 `page_rules::offered` 亮灭：当前页不属于项目时只亮「加入」，属于时亮另外三行 |
| 标签页右键 | 最下面：不属于项目 →「加入项目…」；属于 →「把这一页移出项目 X」「关闭项目」 |
| 存为项目 | 当前页已是某项目的一页 → 说明并不开框；窗口里还有别的可存的页 → 先问「只存这一页 / 这个窗口的全部 N 页」 |
| 存到已有的名字上、设置里「用当前标签页覆盖」 | 与 mac 的 `ProjectSession.save` 相同：项目开在别的标签页里 → 拒绝；选的页是别的项目的 → 拒绝；项目只开在选的这些页里 → 当作它自己再存一次；没开着 → 项目变成这些页，旧的留作上一版 |
| 关一页 | 这页属于项目、项目还有别的页开着 → 问「关闭 / 同时把它从项目里移出 / 取消」；其余情形不问。属于项目的页关的时候不再问「要不要存为项目」 |
| 关闭项目 | 关掉它开着的每一页（页都留在项目里）；有进程在跑时先问一次 |
| 重命名项目 | 打开设置窗口的项目一节并选中它，在那里改 |

## 4b. 已知的缺口与代定

- **「存为项目」没有逐页的勾选框**，是两个选项（只这一页 / 全窗口）。逐页的选择用标签页右键的「加入项目」。原因：
  那个框的版式是按像素定死并有闸的，在看不到画面的机器上往里加一列勾选框，交出来的是没人看过的界面。
- **总控台「启动」那一块的字没有改。** `groups[].project.start` 已读出（`orders::Told`）、那两句话已有
  （`page_rules::start_in_project_words`），但没画：那块场景在 `windows/control-room` 里并与 mac 逐行对照，mac 的这一半
  还没进主线。行为不受影响——点启动后核心出 `open` 待办，这里照做。
- **关页询问没有「以后不再问」**，设置里也没有那一项：没有地方能把它改回来之前不给它。
- **谁在这一格里不记**（`who.is` 没接到保存里），与主线上的 mac 相同：每格存成「不知道」，保留文件里原来写的。
  「总管那一格」的记号只由核心的 `create` / `bind` 待办写。
- Project 菜单顶上没有「这一页属于项目 X」那一行（那张表的字是常量）。
- 待办单是从后台改名/建项目的，设置窗口若开着不会自己刷新列表。
- 最大化/最小化本身不记，只记还原后的位置。
- 一个窗口里混着两个项目的页时，两个项目都会记下这个窗口的 frame。

## 5. 上测试机要看的（逐步）

日志里找 `[project]`。每一步写明看到的那一行。

1. 一个两格的标签页 →「存为项目」叫 `t1` → 日志 `saved as "t1": 1 page(s) in 1 window(s)`；设置窗口里 `t1`
   的「自动保存」一行写的是「随改随存」那句而不是「未绑定」。
2. 在这页再分一格，手离开键盘 → 1～3 秒内出现 `saved "t1": 1 of 1 page(s) open`，`t1.json` 里是三格。
   之后不动：不再出现新的 `saved` 行。
3. 拖着窗口不停地动 15 秒 → 拖动期间（10 秒内）就有一行 `saved`；停下后文件里 `frame` 的 `origin` 是
   `top-left`，四个数等于窗口的屏幕矩形。
4. 让标题每半秒变一次（`while ($true) { $host.UI.RawUI.WindowTitle = Get-Date; sleep -m 500 }`）跑 40 秒 →
   30 秒内有一行 `saved`（不是等它停）。
5. 关掉这一页（项目只有这一页）→ 日志 `saved "t1": … (a tab closing)`；文件里这一页还在、`scrollback` 有文件；
   设置窗口里 `t1` 回到「未绑定」。
6. 打开 `t1` → 开成一个自己的窗口，位置大小与第 3 步记下的一致（日志 `a window of "t1" opens at Some(Rect{…})`、
   `opened "t1": 1 page(s) opened now`）。再点一次打开 → 不多开任何东西，窗口到前面，日志
   `0 page(s) opened now … (it was open already)`。
7. 两页的项目：存为项目后在同一窗口再开一个标签页——**它不是项目的页**（第二批才有「加入」）。用手改文件造一个
   两页的也行。关掉其中一页再打开项目 → 只补回缺的那一页，补在另一页所在的窗口里。
8. 把文件里的 `frame.x` 改成 `99999` 再打开 → 窗口整个落在某个显示器的工作区里。把 `frame` 整个删掉再打开 →
   开成当前窗口的标签页。
9. 改完布局 **1 秒之内**关窗口（以及：直接结束会话/注销）→ 文件里是改完的布局，日志里有关窗口前的那行 `saved`。
10. 项目开着的时候在设置窗口里：改名 → 再改一下布局，写的是新文件，旧文件没有回来；删除 → 再改布局，文件没有回来；
    恢复上一版 → 再改布局，恢复出来的那一版没有被盖掉。
11. 两个不同缩放比例的显示器（或改缩放后重开）：记下窗口实际落在哪、多大——这是「DPI 不换算」的读数，定规矩要用。
12. 以上每一步之后程序还活着、没有卡住：`project_session` 在主线程上取窗口锁，读代码没有持锁调出去的地方
    （`lock-reentry.py` 绿），但没有一次是跑出来的。
13. **陈述**：启动后日志里有一行 `[project] stated N project(s), 0 open …`；存为项目 / 打开 / 关页之后各有一行，数字跟着变。
    总控台里绑着项目的群，行上的页数是对的（来自这句陈述）。不该出现 `NOT stated` 或 `was not taken`。
14. **从群启动**：一个绑着项目的群，点「启动」→ 日志 `order Open for "<项目>" -> Open … : done`，项目各页都开出来，
    第一个窗口开成当前窗口的标签页；随后一行 `stated … 1 with a supervisor's terminal`；总管那一格里先只有 shell，
    然后核心把启动行打进去、agent 起来。重复出现的同一条 `open` 待办只做一次（日志里 `nothing to do (it is open)`）。
15. **补全**：让一个旧群的总管连上（或总管在群里说 `group_project use`）→ 日志 `order Create …: done`，项目目录里多出
    以群名命名的文件，`group` 是群名，总管那一格 `"supervisor":true`。
16. **总管新开的标签页**：让总管开一个 worker 到新标签页 → `order AddTab …: done`，那一页进了项目。
17. **改群名**：给绑着项目的群改名 → `order SetGroup` 与 `order Rename` 各一行，文件、`.scrollback/`、`.prev` 都改了名，
    开着的页继续存到新文件。
18. **移出**：项目两页都开着，标签页右键「把这一页移出项目 X」→ 标签页还在、文件里少一页；对总管所在的那一页做同样的事 →
    弹出「这个群的总管在这一页上…」，文件不变。
19. **加入**：一个不属于项目的标签页，右键「加入项目…」→ 选一个项目 → 文件里多一页；这个标签页右键菜单变成「移出 / 关闭项目」。
20. **关页询问**：项目两页开着，关其中一页 → 问三选一；选「关闭」→ 页还在文件里；选「同时移出」→ 文件里没有了；
    只剩一页开着时再关 → 不问。项目的页里有进程在跑时关它 → 只问普通的那一句，不问「存为项目」。
21. **关闭项目**：Project 菜单「关闭项目」→ 它开着的页全关，文件里页数不变。
22. **存为项目的拒绝**：项目开着两页，在设置里对它「用当前标签页覆盖」→ 被拒并说明项目开在别的标签页里，文件不变。
    窗口有三个标签页时「存为项目」→ 先问只存这一页还是全部；选全部 → 文件里三页，次序与标签栏相同。
23. **菜单亮灭**：当前页不属于项目时 Project 菜单后四行只亮「加入项目…」；属于时亮另外三行。
