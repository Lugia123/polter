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

## 第 3 期：项目栏目（§6）

mac 列的读数取自 worktree `s2-mac-projects`（基于 60b63ad7d，未提交改动）。单元测试由
`tools/mac-xctest-run.sh` 跑（隔离状态目录、`poltergeist-register-mcp = false`，前后 `mcpServers.polter`
逐字相同，输出 `MCP_SAME`）。截图不是真实例：是一条**临时**测试（不入库）在测试宿主里用真的
`SettingsRootView` + 一个指向临时目录的 `ProjectStore` 离屏渲染、`cacheDisplay` 出的图，数据是造的
（4 个项目，polter 有 3 个 pane、一个 `.prev`、1.7 MB scrollback）；没有终端窗口，所以「用当前标签页覆盖」
是灰的、底栏写原因。截图目录 `ghostty-wt/settings-mac-shots/p3-projects/`（不在仓内）。

| # | 行为 | mac | Windows |
|---|---|---|---|
| P1 | 列表每行：名称、上次保存时间、pane 数（tab 数恒为 1，不显示，见群里 #957 规格点 2） | ✅ `08-projects-1180.png` | |
| P2 | 缩略图按分屏树画，pane 标目录末段 + 标题（项目文件不存角色，见 #957 规格点 1） | ✅ 画面见 08；矩形切分 `ProjectsRules.cells`，单元测试 `aSideBySideSplitCutsTheWidth`、`anOverUnderSplitCutsTheHeightByItsRatio`、`nestedSplitsTileTheRectWithoutOverlap`、`aRatioOutOfRangeLeavesNoNegativeCell` | |
| P3 | 详情：目录、scrollback 占用、自动保存状态（绑定到哪个标签页 / 未绑定） | ✅（未绑定一格）见 08。绑定状态的文字没在画面上出现过 | |
| P4 | 打开 = 加载项目 | ⏳ 与「加载项目…」共用 `TerminalController.load`（原 `performLoad` 抽出）。没在真实例上点过 | |
| P5 | 重命名：重名拒绝并说明（含大小写 / 同文件名） | ✅ 规则 `renameVerdict`：`anotherProjectsNameIsRefused`、`aNameSavedUnderAnotherProjectsFileIsRefused`、`aFileDifferingOnlyInCaseIsRefused`；落盘 `renameOntoAnotherProjectIsRefusedAndTouchesNothing` | |
| P6 | 重命名带走 `.prev`、scrollback，`.prev` 里的名字也改；只改大小写不丢文件 | ✅ `renameMovesTheFileItsPreviousAndItsSnapshots`、`renameThatOnlyChangesCaseKeepsTheProject` | |
| P7 | 已绑定的项目改名，绑定跟着走 | ✅（存储层）`aBoundProjectIsRenamedAndItsBindingFollows`：登记表换键、持有者收到 will/did（新 key、新 scrollback 目录）。⏳ 真标签页上的续写（`TerminalController.projectDidMove` 重接 journal）没在真实例上验 | |
| P8 | 复制一份，默认名「<原名> 副本」，重名递增 | ✅ `aCopyTakesTheFirstFreeNameAndTheSnapshotsButNotThePrevious`、`aCopyNameThatIsTakenIsNumbered` | |
| P9 | 用当前标签页覆盖，需确认 | ⏳ 确认框 + `saveAndBind`（与「另存为项目」覆盖同一条路）。无终端时按钮灰、底栏写原因（08）。没在真实例上点过 | |
| P10 | 删除需确认；之后列表顶部「已删除 <名> [撤销]」直到关窗或下一次删除 | ✅ 画面 `10-projects-deleted-banner.png`；规则 `aDeleteShowsTheBannerAndTheNextReplacesIt`、`undoingTakesTheBannerAwayAndAFailedUndoKeepsIt`；关窗即丢（横幅在随窗口释放的 model 上） | |
| P11 | 删除进废纸篓、撤销放回；同名已被重新占用时撤销拒绝且不覆盖 | ✅ `deleteMovesEveryPartToTheTrashAndUndoPutsThemBack`、`undoIsRefusedWhenTheNameHasBeenTakenSince`、`aBoundProjectIsNotDeleted`（测试注入自己的「废纸篓」目录） | |
| P12 | 版本历史：当前 + 至多 1 个上一版，按时间，标出当前，选一个恢复 | ✅ 画面见 08；`versionsListTheCurrentAndTheKeptOne`、`versionsAreNewestFirst`、`aPreviousVersionNewerThanTheCurrentSortsFirst`。恢复走原 `restorePrevious`（互换，绑定时拒绝） | |
| P13 | 在 Finder 中显示 | ⏳ `NSWorkspace.activateFileViewerSelecting`。没在真实例上点过 | |
| P14 | 「管理项目…」→ `projects/<当前窗口的项目>` | ⏳ `manageProjects:` 改为 `openSettings(.projects(boundProject))`；选中规则 `projectToSelect` 四条单测。没在真实例上点过 | |
| P15 | 搜索按项目名过滤；过滤掉选中项时面包屑加注；在项目栏目里输入不被角色的匹配拉走 | ✅（规则）`sectionForSearch` 三条单测（在当前栏目有匹配就留下，否则去第一个有匹配的）。⚠️ 这是对 §2.3「跳到第一个有匹配的栏目」的收窄，已在群里报。没看画面 | |
| P16 | §2.3a 顶带下沿三段同一行 | ✅ 08（1180×800 @2x）：侧栏 / 列表 / 详情都是第 168–169 行；09（900×620）同 | |
| P17 | §2.3a 底带上沿三段同一行 | ✅ 08：三段都是第 1494–1495 行；09：三段都是 1134–1135 | |
| P18 | §2.3a 竖线上下贯通 | ✅ 08 / 09：侧栏竖线在顶带、主体上端、主体下端、底带都是 440–441 列；列表竖线主体上下端都是 962–963，顶带和底带里没有。⚠️ 10 里横幅紧贴顶带线，量法（比上下 6px 邻居）在列表段量不出那条线，不是没有 | |
| P19 | 每列内容左缘 = 列左线 + PAD | ✅ 08：面包屑、列表「polter」「market」首个墨迹都在第 475 列（线在 440–441 → 442 + 32 = 474，+1 是字形边距）；底栏第一个图标墨迹 479（按钮框起点 474，图标 18pt 框内居中）；详情标题 998、「版本历史」997（列表竖线 962–963 → 964 + 32 = 996） | |
| P20 | 最小 900×620 下按钮不被裁 | ✅ `09-projects-min-900.png`：重命名 / 在 Finder 中显示 / 用当前标签页覆盖 / 打开都在 | |

### 单元测试（mac，第 3 期）

`macos/Tests/Settings/ProjectsRulesTests.swift`（28 条，被测 `ProjectsRules.swift` + `SettingsRules.sectionForSearch`）、
`macos/Tests/Projects/ProjectStoreSettingsTests.swift`（11 条，被测 `ProjectStore` 新增的 rename / duplicate / trash /
untrash / versions / scrollbackBytes，临时目录 + 注入的废纸篓）。同批回归 `ProjectStoreTests` 14、`ProjectAutosaveTests` 9、
`SettingsRulesTests` 30。基线（`-only-testing` 一个不存在的测试）0 条。地板：一次打坏 8 处，全部红在各自断言上，见交付报告。

## 第 4 期：通用栏目（§7）——不依赖核心表单的部分

mac 列：worktree `s2-mac-projects`（基于 1f9d4de14，未提交）。截图同第 3 期的离屏办法（临时测试，不入库），测试宿主
读隔离配置、没有配置错误；目录 `ghostty-wt/settings-mac-shots/p4-general/`。外观 / 字体 / 终端 / 窗口与标签 / Polter /
全部选项六组等 #960 的 form.zig，现在是占位页、列表里灰字。

| # | 行为 | mac | Windows |
|---|---|---|---|
| G1 | 中栏分组按 §7.1 顺序：外观、字体、终端、窗口与标签、Polter、全部选项、快捷键、高级、关于 | ✅ `general-*.png`；单测 `theGroupsAreTheSpecsInItsOrder`、`onlyTheFormGroupsWaitForTheCoresTable` | |
| G2 | 快捷键：只读列表，一行一个动作：名称（下面是 tag）、按键（没有就写 —）、说明（菜单不显示 / 没有快捷键 / agent 开关）；同一个键只列一次，一个键不会被拆到两行 | ✅ `menu-keybinds-1180.png`、`menu-keybinds-900.png`（99 个动作）。数据用现成的 `KeybindsModel`（读正向表，与 Windows 页同源），配置重载后跟着刷新。去重：`fold` 按渲染后的字符串去重，真实配置里 99 行都没有重复键（`log.txt`：goto_tab 是 ⌘1…⌘8 各一次）；单测 `aKeyWrittenTheSameWayTwiceIsListedOnce`。不断行：键里的空格换成不断行空格，单测 `aKeyIsNeverBrokenAcrossLines`，画面上「⇧Page Down」在同一行。窄窗口：说明挤不下时（规则 `keybindNoteBelow`，名称 + 按键 + 两个间距 + 160）放到按键下面，900 宽那张就是这样 | |
| G3 | 快捷键：「在配置文件中编辑…」 | ⏳ 底栏按钮，调宿主的打开文件逻辑（不走 `open_config`）。没在真实例上点过 | |
| G4 | 高级：配置错误列表（没有错误时明说）、打开配置文件、重新加载配置 | ✅（没有错误的一格）`general-advanced-1180.png`，重载后底栏写「已重新加载配置。」。⏳ 有错误时的列表没在画面上出现过；上一次写入前的备份位置要等 form.zig 实现 | |
| G5 | 关于：版本、构建、提交号 | ✅ `general-about-1180.png`（Debug 测试宿主的 bundle 里没有 PolterCommit，所以提交号那一行按规则不显示）；单测 `aboutListsVersionBuildAndCommitInThatOrder`、`aboutLeavesOutWhatTheBundleDoesNotSay` | |
| G6 | 路由 general/<组>：点名的组；没点名时新开窗口在第一组，已经开着的窗口留在原组 | ✅（规则）`aRouteLandsOnTheGroupItNames`、`withNoneNamedANewWindowTakesTheFirstAndAnOpenOneStays` | |
| G7 | §2.3a 网格 | ✅ 快捷键 / 高级 / 关于三张（1180×800 @2x）和快捷键 900×620：顶带下沿三段都在第 168–169 行；底带上沿三段都在 1494–1495 行（900：1134–1135）；侧栏竖线 440–441 贯通顶带、主体和底带；列表竖线 962–963 只画在主体里 | |
| G8 | 菜单「快捷键…」→ `general/keybinds`：打开设置窗口的「快捷键」组，不再开旧的独立窗口（旧的 `KeybindsController` 留给第 4 期删） | ✅ 在测试宿主里调真实的 `AppDelegate.showKeybinds(nil)`：打开的是「Polter 设置」窗口、只有 1 个，面包屑「通用 › 快捷键」（`menu-keybinds-1180.png`）；单测 `theKeyboardShortcutsMenuRoutesToItsGroup`。⏳ 菜单项本身没有点过（xib 的 action 没改，仍然是 `showKeybinds:`） | |
