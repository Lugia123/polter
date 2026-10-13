# Windows 宿主的「项目」：哪页是哪页、随改随存、整个打开

> 状态（任务 #1496 第一批，2026-10-13）：**规则有测试；宿主接线交叉编译通过，一次都没有在 Windows 上跑过。**
> 第二批（向核心发 `projects` 陈述、照做 `project_orders`、勾页的另存、右键加入/移出、关页询问、
> Project 菜单的关闭与改名）还没做。设计：`control-room-design/v20/DESIGN.md`；两端契约：
> [`../poltergeist/projects.md`](../poltergeist/projects.md)。

## 1. 分在哪

| 在哪 | 是什么 | 怎么验 |
| --- | --- | --- |
| `windows/projects`（crate `polter-projects`，不依赖 Win32） | 规则：`pages`（开着的页照现在写、没开着的页原样留；窗口与页的次序、哪页在前、frame；说不出目录/说不出是谁的格子保留文件里的）、`placement`（一个窗口开成自己的窗口还是当前窗口的标签页；屏外夹回）、`autosave`（合并写盘与最晚时刻） | mac 上 `cargo test -p polter-projects` |
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
| 标题、目录 | `Op::SetTabTitle`、`set_cwd_for_surface` | 30 秒 |

安静 1 秒就写；一直不安静，到「最晚」也写。数值与 mac 一致。「哪个项目变了」不问——每个开着的项目都记一笔，
只会改时间的写盘本来就不落盘（`project::write_file`）。

**退出时每个开着的项目存一次**：`WM_CLOSE`、`winid::close_window_now`、`WM_ENDSESSION(wParam≠0)` 都先
`save_all()`。**关一页不等于移出**：`tabs::destroy_tab_at` 在标签页还在的时候调 `tab_closing`，带着这一页
再存一次（这是自动保存里唯一抓整份回滚的一次），然后只解除「开着」，页留在项目里。

设置窗口里的三件事跟着走：改名 → `moved`（开着的页跟到新文件，否则下一次自动保存会把旧文件写回来）；
删除、恢复上一版 → `forget`（标签页留着，不再是任何项目的页——否则会把刚删的写回来、把刚恢复的盖掉）。

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

## 4. 已知的缺口与代定

- 「用当前标签页覆盖」现在的意思是**项目变成这一页**（原来的在 `.prev` 里，可「恢复上一版」）。过渡接口
  `replacing_first_tab` 的意思是「换掉第一页、其余留着」；接口删了，这个语义没有保留。多页项目上这个按钮该是什么，
  等第二批的「加入项目 / 移出项目」定。
- 最大化/最小化本身不记，只记还原后的位置。
- 一个窗口里混着两个项目的页时，两个项目都会记下这个窗口的 frame。
- `project_of_tab` / `summary` / `bound_tabs` 现在没有调用者（编译警告），是给第二批的陈述用的。

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
