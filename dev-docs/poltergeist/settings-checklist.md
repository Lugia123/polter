# 设置窗口：两边对照清单

规格是 [settings.md](settings.md)（§8：每条是一个可观察的行为，两列各记核对结果与证据）。
每个阶段交付时更新本表。

## 第 1 期：窗口外壳 + 路由 + 角色栏目

mac 列的读数取自 worktree `settings/mac`（基于 0a18c2700，未提交改动）的 Debug 构建，
`polter.debug.dylib` sha256 前缀 `7f78c039`，测试实例由 `tools/mac-test-instance.sh` 起（隔离状态目录、
`--poltergeist-register-mcp=false`，起前起后 `mcpServers.polter.command` 均为
`/Applications/Polter.app/Contents/MacOS/polter`）。这台机器上宿主没有辅助功能 / 屏幕录制权限，
所以菜单是在进程内用 lldb 调真实菜单项的动作触发的（同一个 target / action / representedObject），
截图是窗口自己 `cacheDisplayInRect:` 出的图，不是系统截屏。截图目录
`ghostty-wt/settings-mac-shots/`（不在仓内），复现脚本 `run_all.sh`、输出 `run.log` 在同目录。

| # | 行为 | mac | Windows |
|---|---|---|---|
| 1 | ⌘, / Ctrl+, 打开设置窗口（`open_config` os_open） | ✅ 主菜单 `performKeyEquivalent:` 收 ⌘, → `handled=1`，开出窗口。`01-first-open-cmd-comma.png`。⚠️ 核心 `GHOSTTY_ACTION_OPEN_CONFIG` 的 os_open / new_window 两个分支没有单独触发过 | |
| 2 | 菜单「偏好设置… / 设置…」打开设置窗口 | ✅ 菜单项（macOS 26 显示为「设置…」）→ `openConfig:` → 开出窗口。`02-reopen-keeps-size.png` | |
| 3 | 首开尺寸 1180×800，居中，超 90% 屏幕则缩 | ✅ frame 读回 `310,165,1180,800`（可用区 1800×1130，未触发 90%）。90% 截断：单元测试 `firstOpeningIsCutToNinetyPercent`、`onlyTheSideThatDoesNotFitIsCut`（1280×720 → 1152×648）；真机小屏没验 | |
| 4 | 最小 900×620，按钮不被裁 | ✅ 布局：900×620 下侧栏、列表、编辑器、底栏 + ⧉ − / 启动 / 还原 / 保存都在（旧构建截图，未随本次修复重截）。约束：原先 `minSize` 读回 0×32——SwiftUI hosting 在首次布局后按根视图最小尺寸（0×0）重设了它；现在根视图带最小尺寸、`sizingOptions = [.minSize]`，另在 `windowWillResize` 里用 `SettingsRules.clamped` 夹取。离屏探针（窗口不上屏）读回 minSize 900×620、frame 1180×800；单元测试 `aResizeIsHeldAtTheMinimum`。**修复后的 app 没在真机上读回过** | |
| 5 | 调大后关窗，再开尺寸保留 | ✅ 调到 1320×900、关窗；defaults `NSWindow Frame PolterSettings = 200 150 1320 900`；再开 frame 读回 `200,150,1320,900`。`02-reopen-keeps-size.png` | |
| 6 | 单例：多入口只有一个设置窗口 | ✅ 走完菜单栏 / tab 右键 / 终端右键三入口后，app 内标题为「Polter 设置」的窗口数 = 1 | |
| 7 | 菜单栏 智能体 ▸ 角色 ▸ 角色库… → roles/<当前终端的角色> | ✅ 焦点终端穿 test-worker，菜单项 route=`roles("test-worker")`，窗口选中「测试 Worker」。`03-menubar-role-library.png` | |
| 8 | tab 右键 ▸ 角色 ▸ 角色库… → roles/<该 tab 的角色> | ✅ 经 `NSMenuWillOpenNotification` 让真实的 `configureTabContextMenuIfNeeded` 加出角色子菜单，route=`roles("dev-worker")`，面包屑「角色 › 开发 Worker」。`04-tab-rightclick-role-library.png` ⚠️ 这张图的搜索框里有用户误打进来的 "pu"，列表被它过滤空了 | |
| 9 | 终端右键 ▸ 角色 ▸ 角色库… → roles/<该终端的角色> | ✅ route=`roles("test-worker")`，面包屑「角色 › 测试 Worker」。`05-terminal-rightclick-role-library.png`（同上，搜索框有 "pu"） | |
| 10 | 无角色的终端 / 无终端 → roles（无条目） | ✅（菜单读数）无角色终端的「角色库…」route=`roles(nil)`；单元测试 `theLibraryOpensOnThisTerminalsRole` 覆盖 `.none` 状态。没跑测试 | |
| 11 | 侧栏四栏目 角色 / 项目 / 插件 / 通用；项目、插件为占位 | ✅ 见 01。点「项目」只在 12 里点过（被询问拦下），占位页本身没截图 | |
| 12 | 有未保存改动时切栏目先问（保存 / 不保存 / 取消） | ✅ 改「测试 Worker」名字后点侧栏「项目」→ 弹窗「保存修改吗？」按钮 取消 / 不保存 / 保存。`06a-dirty.png`、`06b-unsaved-prompt-alert.png`（NSAlert 自绘不全，文字以视图树读数为准） | |
| 13 | 取消后留在原栏目、草稿保留、侧栏高亮复位 | ✅ 取消后仍是「角色 › 测试 Worker（改）」、蓝点在、侧栏高亮回「角色」。`06c-after-cancel.png` | |
| 14 | 未保存时切同栏目条目 / 从别的入口跳进来 / 关窗 先问 | ❌ 没验（代码走同一个 `SettingsUnsaved.confirmLeaving`） | |
| 15 | Esc 不关窗；⌘W 关窗（先问） | ❌ 没验 | |
| 16 | Launch 不可用原因写在底栏文字里 | ✅ 有未保存改动时底栏写「先保存角色再启动。」。见 06a | |
| 17 | 通用 ▸ 打开配置文件… | ❌ 没验 | |
| 18 | §2.3a 顶带下沿：侧栏 / 列表 / 编辑器三段同一行 | ✅ 1320×900 窗口 @2x：三段都是第 168–169 行（= 32pt 标题栏 + 52pt 顶带）。`07-grid-readings.png` | |
| 19 | §2.3a 底带上沿：三段同一行 | ✅ 三段都是第 1694–1695 行（= 900 − 52 − 1 pt） | |
| 20 | §2.3a 搜索框文字与面包屑同基线 | ✅ 搜索框填「角色」，与面包屑首字同字形比：「角」墨迹框两处都是第 104–128 行（阈值 40）/ 105–127 行（阈值 160），宽 22px；加权重心 116.34 / 116.30 | |
| 21 | §2.3a 竖线上下贯通 | ✅ 侧栏竖线：顶带 / 主体上端 / 主体下端 / 底带都在第 440–441 列（= 220pt）；列表竖线：主体上端与下端都在第 962–963 列（= 220 + 1 + 260pt），顶带和底带里没有 | |
| 22 | §2.3a 表单「标签列 120 + 控件列」，勾选框 / 下拉进控件列 | ✅（目视）名称 / Key / 说明 / 打开位置 标签右对齐、勾选框与「打开位置」下拉在同一控件列。见 06a。没做像素测量 | |
| 23 | §2.3a 每列内容左缘 = 列左线 + PAD：面包屑文字、列表条目文字、底栏 + 按钮同一个 x | ⏳ 代码按 `SettingsLayout.ContentEdge` 摆放（三者都是 16），单元测试 `aColumnHasOneContentEdge`。修改后没在真机上量像素 | |
| 24 | §2.3a 侧栏搜索框左右缘 = 选中高亮左右缘（`PAD_SIDEBAR = 8`） | ⏳ 两者都取 `sidebarSearchEdges` / `sidebarHighlightEdges`（8..212），单元测试 `theSearchBoxAndTheHighlightShareTheirEdges`。没量像素 | |
| 25 | 搜索一个都不剩时列表写「没有匹配的角色」；过滤掉选中项时面包屑加「（不在搜索结果里）」 | ⏳ 规则 `SettingsRules.listing` / `breadcrumb`，单元测试 `aSearchThatMatchesNothingSaysSo`、`aSearchThatHidesTheSelectionSaysSo`、`theBreadcrumbNotesAHiddenItem`。没看画面 | |
| 26 | 侧栏与角色列表 ↑↓ 选上一个 / 下一个，两端停住不回绕，选中项滚动可见；切换照走「未保存先问」 | ⏳ 自绘行上 `focusable` + `onMoveCommand`，步进规则 `SettingsRules.step`，点行时焦点落到该列；角色列表 `ScrollViewReader` 滚到选中项。单元测试 `downAndUpMoveOneRow`、`theEndsHold`、`fromNothingDownIsFirstAndUpIsLast`、`anEmptyListGoesNowhere`、`theSidebarStepsThroughItsSections`。没按过键 | |
| 27 | 角色子菜单父项叫「角色」/「角色：<名>」，不带 beta | ⏳ 代码与文案改了（`PersonaMenu.title`、两份 Localizable.strings、MainMenu.xib 占位标题与 zh-Hans MainMenu.strings）。没看菜单 | |
| 28 | 内置角色在子菜单里显示本地化名（与列表一致的「Polter 总管」） | ✅（代码）子菜单行名取自 `PersonaCatalog`，它用的是 `Role.displayName`，与列表同源；本轮未改。没看菜单 | |
| 29 | 英文界面搜索框占位字 "Search" | ✅（代码）msgid "Search"，Base 为 "Search"、zh-Hans 为「搜索」 | |
| 30 | 最大化 / 缩放后关窗再开，状态与几何一致 | ⏳ 设置窗口 `collectionBehavior` 加 `.fullScreenNone`：绿色按钮是缩放，缩放后的 frame 就是普通 frame，按原样自动保存、原样再开，没有「标志与几何不一致」的余地。没在真机上关开过 | |
| 31 | 设置窗口开着时关掉最后一个终端窗口，app 不退出；退出前有未保存改动先问 | ⏳ 不退出：AppKit 只在最后一个窗口关掉后才问 `applicationShouldTerminateAfterLastWindowClosed`，设置窗口算窗口（且 mac 默认 quit-after-last-window-closed 为 false）。先问：`applicationShouldTerminate` 在关机检查之后、`needsConfirmQuit` 之前调 `SettingsWindowController.mayQuit()`（同一个未保存协议），取消则 `.terminateCancel`——之前 ⌘Q 在没有运行中进程时会直接退出、丢掉未保存的改动。都没在真机上试 | |
| 32 | 未保存询问框关掉后，键盘焦点回到发起它的那一列（侧栏引起的回侧栏，列表 ↑↓ 引起的回列表） | ⏳ ↑↓ 引起的：焦点本来就在那一列，询问是 `runModal`，关掉后 AppKit 把 key 还给设置窗口、first responder 不变。点击引起的：先把焦点给被点的列，切换挪到下一轮 runloop 再做，保证询问前焦点已落地。没有单元测试（焦点是 AppKit / SwiftUI 的状态，规则层没有可测的东西），没在真机上试 | |

写法注：mac 列的边缘写成区间（`8..212` = 从 8 到 212，右端是边界不是像素列）；Windows 列写含端点的像素列（`8..211`），两者同值。

### 单元测试（mac）

`macos/Tests/Settings/SettingsRulesTests.swift`，被测 `macos/Sources/Features/Settings/SettingsRules.swift`
（只依赖 Foundation / CoreGraphics）：首开尺寸与 90% 截断、尺寸夹取、记住的位置是否还能用（标题栏在不在屏上）、
roles 路由选哪个角色、未保存时的保存 / 不保存 / 取消。`xcodebuild test` 会拉起测试宿主（一个 Polter）并抢前台，
所以没跑；这份测试由 `xcodebuild build-for-testing` 编进测试包，并在一个把这两个文件符号链接进来的临时 SwiftPM 包里
用 `swift test` 跑。第二轮（左缘与搜索）后：`SettingsRules.swift`、`SettingsLayout.swift` 与测试文件都链接进包，
34 条（2 个 suite，含方向键 5 条）全过，基线（`--filter zz-nothing`）0 条；三轮共打坏 12 次，各红在对应断言上。
⚠️ 单元测试证的是常量和规则；「视图确实用了这些常量」没有测试能看见，要靠真机量像素（23、24）。

### 未完（mac）

- 用户叫停了真机 GUI 测试（测试实例反复抢前台，用户的按键进了测试窗口）：14 / 15 / 17、真机小屏 90% 截断、
  修复后的最小尺寸读回，等用户说前台可以占用时再验。

## 第 3 期：项目栏目（§6）· Windows 列（#959）

> 行号与 mac 那一节（`settings2/mac-projects`，1f9d4de14）的 P1–P20 一一对应，合并时填进那张表的 Windows 列；
> W1–W3 是 §6.3 只属于 Windows 的三项。读数取自 worktree `s2-win-projects`（基于 60b63ad7d，未提交改动）。
> **Windows 测试机今晚不开，下面没有一格是在真机上看过的**：✅ 只表示纯规则有单元测试（`polter-settings-shell`，
> 在 mac 上跑，含临时目录里的真实文件操作）、宿主交叉编译通过；画面、点击、像素全部 ⏳。

| # | Windows |
|---|---|
| P1 | ⏳ 行：名称 / 「时间 · N 个窗格」（`projects_ui::paint`；tab 数不显示）。没看画面 |
| P2 | ✅（规则）`projects::thumbnail`：`the_thumbnail_has_one_box_per_pane_in_tree_order`、`a_deep_tree_in_a_small_box_still_shows_every_pane`；标签 `pane_label`（目录末段 · 标题）`a_pane_is_labelled_by_its_directory_and_its_title`。没看画面 |
| P3 | ⏳ 目录 / 回滚内容（`scrollback_bytes`、`format_bytes` 有单测）/ 自动保存恒为「没有绑定到打开的窗口」（Windows 无绑定，裁定）。「角色」一行写「项目文件不记录角色」 |
| P4 | ⏳ 与「加载项目…」同一个 `project_ui::load_project_into_new_tab`，装进发起设置窗口的那个终端窗口。没点过 |
| P5 | ⏳ 详情首行是项目名（粗体）+ 右边「重命名…」，点了弹「重命名项目」框（`prompt::prompt_rename_project`：输入框、说明「项目文件、上一版和 scrollback 一起改名。」、重命名 / 取消，Enter / Esc；框开着时设置窗口禁用），与 mac 一样没有内联名字框。✅（规则）`check_rename`：`a_rename_onto_a_name_that_is_taken_is_refused_and_names_it`（含名字只差大小写而文件名不同的旧文件、两个名字清洗成同一文件名）；落盘 `a_move_onto_another_project_is_refused_and_touches_nothing` |
| P6 | ✅ `a_move_takes_every_sidecar_with_it`、`a_rename_to_itself_is_nothing_and_a_change_of_case_is_a_rename`；`.prev` 里的名字由 `project::set_name` 一起改（宿主，未在真机跑） |
| P7 | —（Windows 没有 tab↔项目绑定，裁定不做） |
| P8 | ✅ `a_copy_is_named_after_its_original_and_numbered_past_what_is_taken`、`a_copy_has_the_snapshots_and_no_history` |
| P9 | ⏳ 确认框 → `project_ui::save_project`（旧命名规则的文件先挪到规则文件名）。没终端窗口时按钮灰、状态栏写原因。没点过 |
| P10 | ✅（规则）`the_undo_banner_lasts_until_the_next_delete_or_the_close`；画面 ⏳ |
| P11 | ✅（规则）删除先整份移进 `projects\.deleted\<名>-<时间>\`（`a_stashed_project_leaves_the_listing_and_comes_back_whole`、`two_deletes_of_one_name_in_one_second_are_two_stashes`），撤销=移回、同名已占用拒绝不覆盖（`undo_does_not_overwrite_a_project_saved_since`）；横幅结束（关窗 / 下一次删除）与启动时的残留（`leftovers_are_everything_but_what_the_banner_holds`）用 `SHFileOperationW(FO_DELETE, FOF_ALLOWUNDO\|NOCONFIRMATION\|SILENT\|NOERRORUI)` 送回收站——⏳ 送回收站这一步只在真机上能看 |
| P12 | ✅ `versions_are_newest_first_and_say_which_is_current`；一代 `.prev` 与 mac 同规则：`the_previous_generation_is_kept_only_on_a_layout_change`、`a_write_keeps_what_was_there_as_prev_and_leaves_nothing_else`、`restoring_swaps_so_it_is_undone_by_restoring_again`、`the_layout_is_the_shape_and_the_directions_not_the_ratios` |
| P13 | ⏳ `explorer.exe /select,"<文件>"`。没点过 |
| P14 | ⏳ 项目菜单新增「管理项目…」→ `projects`（Windows 无绑定，item 空 → 上次选中的，再空第一个）。没点过 |
| P15 | ✅（规则）`section_for_search` 搬了 mac 的三条用例原样：`a_search_stays_in_the_section_on_screen_when_it_matches_there`、`a_search_goes_to_the_first_section_that_matches`、`a_search_that_matches_nothing_stays_in_a_searchable_section`，加 `a_typed_query_is_asked_of_the_names`；面包屑加注走 `hidden_item`。没看画面 |
| P16–P19 | ⏳ 像素没量。网格规则：本栏目底带按钮与 `section_grid` 同一行 `the_actions_sit_in_the_band_on_its_row`；列表文字 = 列表左线 + PAD `the_banner_pushes_the_rows_down_and_the_text_keeps_its_edge`；详情只有「边距 / 控件列」两条左缘 `the_editor_has_two_left_edges_and_fits_at_the_minimum`。打开时日志 `[projects-ui] grid:` 会报这些列 / 行 |
| P20 | ✅（规则）最小窗口 900×620 在 96–240 DPI 下，详情全部落在底带线之上、缩略图不小于 96（该测试首跑就红过：固定 160 高时最后一行版本历史压到底带线下 33px，改成缩略图吃剩余高度）。画面 ⏳ |
| W1 | ⏳ 项目菜单补「管理项目…」一行（`menu.rs` `__polter_manage_projects`，已进 `HOST_ACTIONS`） |
| W2 | ✅（规则）关一个忙的 tab（或只有一个 tab 的窗口）时问「关闭前存成项目吗？」[另存为项目… / 不保存，直接关闭 / 取消]：`only_one_busy_tab_is_offered_a_save_before_it_closes`、`only_the_close_button_closes`；选「另存为项目…」弹名字框，**存成功才关**，取消或失败不关（`prompt.rs` `close_after`）。`project_ui::should_offer_save_as_project` 现在有调用方。弹框 ⏳ |
| W3 | ⏳ tab 右键在颜色之后、智能体之前一节「另存为项目… / 加载项目…」（`strip.rs` `TAB_MENU[8..=9]`，`the_colour_submenu_goes_after_the_second_separator` 已按新表改，宿主测试只编未跑） |

单元测试（Windows 纯层）：`polter-settings-shell` 79 条（基线 HEAD 44 条，新增 35：`projects.rs` 31、`lib.rs` 搜索 4），
`cargo test -p polter-settings-shell` 在 mac 上全过；地板 13 处变异（先写 9、后补 4），每处都红在各自断言行上，
其中「重名比较去掉大小写折叠」第一次没红，补了一条旧文件名的用例后才红。宿主测试 exe 交叉编译通过，没跑（只能在测试机上跑）。
