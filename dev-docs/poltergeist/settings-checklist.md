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

## 第 2 期：插件栏目

mac 列的读数取自 worktree `settings2/mac-plugins`（基于 60b63ad7d，未提交改动）的 Debug 构建
（`polter.debug.dylib` sha256 前缀 `a991d0f9`，最后一处改动——详情里状态点上色——之后重建为 `a2544a58`，
没有重截图）。测试实例由 `tools/mac-test-instance.sh` 起，状态目录预先放了两个夹具插件：`feishu-demo`
（必填 `webhook`、带 `ui/index.html`、已开未填）和 `flaky`（进程一启动就退出）；起前起后
`mcpServers.polter.command` 都是 `/Applications/Polter.app/Contents/MacOS/polter`。窗口由 lldb 在进程内发
`openConfig:`、合成鼠标事件点击、`cacheDisplayInRect:` 自绘出图。截图目录
`ghostty-wt/settings-mac-shots/p2-plugins/`（不在仓内），驱动脚本在同目录。

| # | 行为 | mac | Windows |
|---|---|---|---|
| 33 | 插件在侧栏「插件」下展开，每个带状态点与文字 | ✅ 11 个插件，● 已开 / ◐ 缺配置 / ○ 已关 / ▲ 出错 / ↻ 重启后生效 都出现过。`11`、`14`、`19` | |
| 34 | 状态点判定 ↻ > ○ > ◐ > ▲ > ● | ✅ 纯函数 `SettingsRules.pluginDot`，用例表 10 行（`SettingsPluginRulesTests.dotCases`，Windows 同表）。真机：已开未填 → ◐（`12`）；进程反复退出 → ▲（`15`）；已关 → ○ | |
| 35 | 状态数据与 MCP `plugin_list` 同源 | ✅ 新 C 接口 `ghostty_app_plugin_list` = `wire.writeResponse(.plugins = pluginList)`，与 MCP 同一个函数；宿主只解析，不猜 | |
| 36 | 详情：名称、版本、作者、本地化说明 | ✅ 「飞书演示 v0.3.1 · Polter 测试」。`12`。manifest 没有 `author` 时不显示 | |
| 37 | 开关：缺必填项时禁止打开，旁边写缺哪几项 | ✅ 「先填好：Webhook」。`12`。已开着的仍可关掉 | |
| 38 | 「设置」页签 = 按 schema 生成的表单，标签列 120 + 控件列 | ✅（目视）文本框 / 下拉 / 勾选框都在控件列，说明与密钥提示也在控件列。`12` | |
| 39 | 有 `ui/index.html` 时多一个「页面」页签，嵌 PluginPage | ✅ 页签内 WKWebView，`polter.settings()` 读到设置。`13` | |
| 40 | 插件页面的保存走核心写入器 | ✅ 页面里 `polter.save({params:{webhook:…}})` → 文件变成核心 `Settings.render` 的格式（`"enabled": true`，0600），不是 Swift 的 `"enabled" : true`。`14` | |
| 41 | 「测试」走 `plugin_test` 同一逻辑，结果在按钮旁 | ✅ Flaky 的测试回核心原句（backing off after 8 failed starts…）。`15`；一分钟内再按 → 「一分钟内已经测试过插件，请一分钟后再试。」`16` | |
| 42 | 日志：最近 20 行 + 查看日志 + 显示插件文件夹 | ✅ 20 行（纯函数 `logTail`，CR / CRLF / LF 都断行）。`12`、`15`。两个按钮没点（会开 Finder） | |
| 43 | 保存时插件在跑 → ↻ + 详情顶部常驻横幅「重启 Polter 后生效」，不弹框，无「现在重启」按钮 | ✅ 页面保存 feishu-demo、表单保存 flaky 后，侧栏 ↻、顶部横幅。`14`、`19` | |
| 44 | 设置窗口可以关掉插件（agent 不能） | ✅ 取消勾选 + 保存 → 文件 `enabled: false`。`19`。核心：`pluginEnabledAfter(.user, …)` 放行、`.supervisor` 仍报 `WillNotDisable`（Zig 测试） | |
| 45 | 有未保存改动时切到另一个插件先问；取消后留在原处、草稿还在 | ✅ 改 Label 为 two 后点「飞书演示」→ 弹出 `_NSAlertPanel`；取消后仍是 Flaky、two、「有未保存的修改」。`17`、`18` | |
| 46 | 搜索按插件名过滤；选中项被滤掉时面包屑加注；当前栏目无匹配时跳到第一个有匹配的栏目 | ✅ 「code」→ 剩 4 个插件，面包屑「插件 › Flaky（不在搜索结果里）」`20`；「polter」→ 插件「没有匹配的插件」、跳到角色 `21` | |
| 47 | 插件子菜单「设置…」→ `plugins/<key>`，不再每插件一个窗口 | ✅ 菜单项 `Claude Code > 设置… ro=claude-code` → 面包屑「插件 › Claude Code」，设置窗口数 = 1。`22` | |
| 48 | §2.3a 网格在插件栏目 | ✅ @2x：顶带下沿 侧栏 / 详情两段都是第 168–169 行；底带上沿两段都是 1494–1495 行（页面页签的白色网页下方也是）；侧栏竖线在顶带、主体、底带都是 440–441 列。插件栏目没有列表列 | |
| 49 | 插件菜单的开关走核心写入器；在跑的插件才提示重启 | ⏳ 代码：`PluginCore.configure`，只有 `already_running` 弹「需重启 Polter 才生效」。没在真机上点 | |

### 单元测试（mac，第 2 期）

`macos/Tests/Settings/SettingsPluginRulesTests.swift`，被测 `SettingsPluginRules.swift`（只依赖 Foundation）。
同第 1 期的办法：符号链接进临时 SwiftPM 包 `swift test`：全部 54 条（3 个 suite）过，其中插件 20 条（`theDot`
参数化 10 例算 1 条），基线 `--filter zz-nothing` 0 条。`xcodebuild build-for-testing` 把它和 `PluginSettingsTests`
编进测试包（没跑宿主）。打坏 4 次，各红在：判定顺序对调 → `theDot` 第 0 例（得 `.off`）；去掉 `running &&` → 第 7 例
（得 `.failing`）；只按 `\n` 断行 → `everyLineBreakEndsALine`；去掉 `savedWhileRunning` 守卫 →
`onlyASaveWhileRunningWaitsForARestart`。

Windows 列的读数取自 worktree `s2-win-plugins`（基于 60b63ad7d + 核心补丁 9ca547a18，未提交），交叉编译
`cargo build --release --target x86_64-pc-windows-gnu -p polter-host`，`polter-host.exe` sha256 前缀 `f9194b09`。
**Windows 测试机本轮没开**，所以下表 Windows 列没有一格是在真机上看过的：✅（纯层）= `polter-settings-shell`
的单元测试在 mac 上跑过、打坏过；⏳ = 代码写了、编过，等真机。

| # | 行为 | mac | Windows |
|---|---|---|---|
| P1 | 插件在侧栏「插件」下逐个列出，「通用」排在它们下面 | | ✅（纯层）`plugin_rows_sit_between_plugins_and_general`；⏳ 画面 |
| P2 | 状态点判定顺序 ↻ > ○ > ◐ > ▲ > ●（§5.1） | | ✅（纯层）`dot_table`，14 行用例（与 mac `SettingsRules` 同一张表，待 #956 贴出后逐行对） |
| P3 | ↻ 只在「保存时常驻进程已在跑」时留下（核心 `already_running`），横幅「重启 Polter 后生效」，无按钮 | | ✅（纯层）`restart_pending_only_when_a_running_copy_has_other_settings`；⏳ 画面 |
| P4 | 核心没回答运行状态时不画 ▲，详情写「Polter 核心没有报告这个插件是否在运行」 | | ✅（纯层）`dot_table` 末行；⏳ 画面 |
| P5 | 点侧栏插件行 → 路由 `plugins/<key>`，面包屑「插件 › <名>」 | | ⏳ |
| P6 | 菜单「插件…」、Ctrl+Shift+, → `plugins`（打开，不再是开关） | | ⏳ `menu.rs` / `keys.rs` 改走 `settings_win::request` |
| P7 | 插件有未保存改动时切到别的插件 / 别的栏目 / 关窗先问「保存对这个插件的更改吗？」 | | ⏳ 走 `shell::leave` + `PluginsSection` |
| P8 | 缺必填项时开关不能打开，旁边写缺哪几项 | | ✅（纯层）`the_switch_cannot_be_turned_on_with_something_missing`、`missing_required_names_empty_required_ones_in_order`；⏳ 画面 |
| P9 | 表单：标签列 120 右对齐 + 控件列，说明在控件下；与开关同一条控件列 | | ✅（纯层）`detail_uses_two_left_edges_only`、`form_rows_stack_with_help_under_the_control`；⏳ 像素 |
| P10 | 保存经核心 `ghostty_app_plugin_configure`（空值=删除），宿主不再自己写设置文件 | | ⏳ `plugins::configure`；`plugins::save` 已删 |
| P11 | 「测试」在底栏还原左边，结果首行写在底栏，全文放在日志框顶部；一分钟一次的额度有专门的话 | | ⏳ |
| P12 | 日志：最近 20 行 + 「显示日志」「显示插件文件夹」 | | ✅（纯层）`the_log_tail_is_the_last_lines_oldest_first`；⏳ 画面 |
| P13 | 最小窗口 900×620、横幅 + 长简介时表单区仍 ≥ 2 行控件高，五种 DPI | | ✅（纯层）`detail_fits_at_the_smallest_window`（首版在这里红过：表单只剩 25px，改为开关后行距 8、日志 4 行） |
| P14 | 有 `ui/index.html` 才有「页面」页签；缺 Runtime / 缺 Loader / 创建失败 三种各有说明，页签不藏 | | ✅（纯层）`page_tab_stays_when_the_page_cannot_show`；⏳ 画面（Server 2022 默认无 Runtime，正好测「缺 Runtime」） |
| P15 | 页面只能读 `ui/` 里的文件，`..`、编码过的 `..`、别的插件、别的 scheme 一律拒 | | ✅（纯层）`requests_stay_inside_ui`；宿主另按 canonicalize 后的真实路径再围一次 |
| P16 | `WebView2Loader.dll` 不在导入表（缺它时进程照常起） | | ✅ `objdump -p polter-host.exe` 38 个 DLL Name，含 webview 的 0 个 |
| P17 | 搜索框按插件名过滤侧栏插件行，过滤掉当前插件时面包屑加「（不在搜索结果里）」 | | ⏳ |
## 第 3 期：项目栏目（§6）

mac 列的读数取自 worktree `s2-mac-projects`（基于 60b63ad7d，未提交改动）。单元测试由
`tools/mac-xctest-run.sh` 跑（隔离状态目录、`poltergeist-register-mcp = false`，前后 `mcpServers.polter`
逐字相同，输出 `MCP_SAME`）。截图不是真实例：是一条**临时**测试（不入库）在测试宿主里用真的
`SettingsRootView` + 一个指向临时目录的 `ProjectStore` 离屏渲染、`cacheDisplay` 出的图，数据是造的
（4 个项目，polter 有 3 个 pane、一个 `.prev`、1.7 MB scrollback）；没有终端窗口，所以「用当前标签页覆盖」
是灰的、底栏写原因。截图目录 `ghostty-wt/settings-mac-shots/p3-projects/`（不在仓内）。

| # | 行为 | mac | Windows |
|---|---|---|---|
| PJ1 | 列表每行：名称、上次保存时间、pane 数（tab 数恒为 1，不显示，见群里 #957 规格点 2） | ✅ `08-projects-1180.png` | |
| PJ2 | 缩略图按分屏树画，pane 标目录末段 + 标题（项目文件不存角色，见 #957 规格点 1） | ✅ 画面见 08；矩形切分 `ProjectsRules.cells`，单元测试 `aSideBySideSplitCutsTheWidth`、`anOverUnderSplitCutsTheHeightByItsRatio`、`nestedSplitsTileTheRectWithoutOverlap`、`aRatioOutOfRangeLeavesNoNegativeCell` | |
| PJ3 | 详情：目录、scrollback 占用、自动保存状态（绑定到哪个标签页 / 未绑定） | ✅（未绑定一格）见 08。绑定状态的文字没在画面上出现过 | |
| PJ4 | 打开 = 加载项目 | ⏳ 与「加载项目…」共用 `TerminalController.load`（原 `performLoad` 抽出）。没在真实例上点过 | |
| PJ5 | 重命名：重名拒绝并说明（含大小写 / 同文件名） | ✅ 规则 `renameVerdict`：`anotherProjectsNameIsRefused`、`aNameSavedUnderAnotherProjectsFileIsRefused`、`aFileDifferingOnlyInCaseIsRefused`；落盘 `renameOntoAnotherProjectIsRefusedAndTouchesNothing` | |
| PJ6 | 重命名带走 `.prev`、scrollback，`.prev` 里的名字也改；只改大小写不丢文件 | ✅ `renameMovesTheFileItsPreviousAndItsSnapshots`、`renameThatOnlyChangesCaseKeepsTheProject` | |
| PJ7 | 已绑定的项目改名，绑定跟着走 | ✅（存储层）`aBoundProjectIsRenamedAndItsBindingFollows`：登记表换键、持有者收到 will/did（新 key、新 scrollback 目录）。⏳ 真标签页上的续写（`TerminalController.projectDidMove` 重接 journal）没在真实例上验 | |
| PJ8 | 复制一份，默认名「<原名> 副本」，重名递增 | ✅ `aCopyTakesTheFirstFreeNameAndTheSnapshotsButNotThePrevious`、`aCopyNameThatIsTakenIsNumbered` | |
| PJ9 | 用当前标签页覆盖，需确认 | ⏳ 确认框 + `saveAndBind`（与「另存为项目」覆盖同一条路）。无终端时按钮灰、底栏写原因（08）。没在真实例上点过 | |
| PJ10 | 删除需确认；之后列表顶部「已删除 <名> [撤销]」直到关窗或下一次删除 | ✅ 画面 `10-projects-deleted-banner.png`；规则 `aDeleteShowsTheBannerAndTheNextReplacesIt`、`undoingTakesTheBannerAwayAndAFailedUndoKeepsIt`；关窗即丢（横幅在随窗口释放的 model 上） | |
| PJ11 | 删除进废纸篓、撤销放回；同名已被重新占用时撤销拒绝且不覆盖 | ✅ `deleteMovesEveryPartToTheTrashAndUndoPutsThemBack`、`undoIsRefusedWhenTheNameHasBeenTakenSince`、`aBoundProjectIsNotDeleted`（测试注入自己的「废纸篓」目录） | |
| PJ12 | 版本历史：当前 + 至多 1 个上一版，按时间，标出当前，选一个恢复 | ✅ 画面见 08；`versionsListTheCurrentAndTheKeptOne`、`versionsAreNewestFirst`、`aPreviousVersionNewerThanTheCurrentSortsFirst`。恢复走原 `restorePrevious`（互换，绑定时拒绝） | |
| PJ13 | 在 Finder 中显示 | ⏳ `NSWorkspace.activateFileViewerSelecting`。没在真实例上点过 | |
| PJ14 | 「管理项目…」→ `projects/<当前窗口的项目>` | ⏳ `manageProjects:` 改为 `openSettings(.projects(boundProject))`；选中规则 `projectToSelect` 四条单测。没在真实例上点过 | |
| PJ15 | 搜索按项目名过滤；过滤掉选中项时面包屑加注；在项目栏目里输入不被角色的匹配拉走 | ✅（规则）`sectionForSearch` 三条单测（在当前栏目有匹配就留下，否则去第一个有匹配的）。⚠️ 这是对 §2.3「跳到第一个有匹配的栏目」的收窄，已在群里报。没看画面 | |
| PJ16 | §2.3a 顶带下沿三段同一行 | ✅ 08（1180×800 @2x）：侧栏 / 列表 / 详情都是第 168–169 行；09（900×620）同 | |
| PJ17 | §2.3a 底带上沿三段同一行 | ✅ 08：三段都是第 1494–1495 行；09：三段都是 1134–1135 | |
| PJ18 | §2.3a 竖线上下贯通 | ✅ 08 / 09：侧栏竖线在顶带、主体上端、主体下端、底带都是 440–441 列；列表竖线主体上下端都是 962–963，顶带和底带里没有。⚠️ 10 里横幅紧贴顶带线，量法（比上下 6px 邻居）在列表段量不出那条线，不是没有 | |
| PJ19 | 每列内容左缘 = 列左线 + PAD | ✅ 08：面包屑、列表「polter」「market」首个墨迹都在第 475 列（线在 440–441 → 442 + 32 = 474，+1 是字形边距）；底栏第一个图标墨迹 479（按钮框起点 474，图标 18pt 框内居中）；详情标题 998、「版本历史」997（列表竖线 962–963 → 964 + 32 = 996） | |
| PJ20 | 最小 900×620 下按钮不被裁 | ✅ `09-projects-min-900.png`：重命名 / 在 Finder 中显示 / 用当前标签页覆盖 / 打开都在 | |
| PJ21 | 「用当前标签页覆盖」一律留上一版，1 pane 盖 1 pane 也留（#965） | ✅ 真机（mac-fix965，dylib `28810ce0`）：gamma（1 pane，cwd work/g，标题 gamma-only）被 /bin/sh 标签页（1 pane）覆盖 → 出现 `gamma.json.prev`，与覆盖前的 gamma.json 逐字节相同（sha1 `1d3fda26`），版本历史列出上一版可恢复。`p965/s3-overwrite-confirm-1pane.png`、`s4-after-overwrite.png`。写入层：`ProjectFileWriter.Keeping` 无默认值，覆盖传 `.always`，自动保存 / 关窗保存 / 菜单另存为传 `.onLayoutChange` | |
| PJ22 | 设置窗口开着时，列表与详情的「上次保存」随自动保存刷新 | ✅ 真机：打开 beta 后没有点任何东西，5 秒后列表与详情都从 03:23 变成 03:35（磁盘 saved_at 1790796916），绑定标签页名也跟着换成新标题。`p965/s1-just-opened.png` → `s2-after-5s.png`。机制：`ProjectStore.didWrite`（真写了才发）+ `bindingDidChange`（绑定 / 解绑 / 每次自动保存），项目模型订阅，不轮询 | |
| PJ23 | 绑定的标签页名永不为空（刚打开的项目曾显示「绑定到标签页「」」） | ⏳ 规则 `ProjectsRules.holderLabel`：窗口标题 → 第一个非空 pane 标题 → 第一个 cwd 末段 → 「未命名标签页」，单元测试 3 条。真机这次没复现出空标题：点「打开」后 0.3 秒窗口标题已是「🪄 Polter」（`s1`）；空标题那一刻只在 #962 的截图 s02 里见过 | |
| PJ24 | 菜单「另存为项目」存到已有名字也留上一版，确认框写「被替换的版本会留作上一版」（#969） | ✅ 真机（mac-fix969，dylib `d71230b0`）：/bin/sh（1 个面板）另存为到已有的 gamma（1 个面板）→ 确认框「“gamma”已经有 1 个面板，保存于 …。被替换的版本会留作上一版。」→ 覆盖后生成 `gamma.json.prev`，与之前的 gamma.json 逐字节相同。另存为新名字 delta 不产生 `.prev`。地板：把这个调用点改回 `.onLayoutChange` 重建（`cfe9683a`），同样操作覆盖照样发生、没有 `.prev`。`p969/s1-saveas-picker.png`、`s2-saveas-overwrite-confirm.png` | |

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

### 第 4 期：通用栏目表单（§7.2–7.4，form.zig 三接口）

mac 列：worktree `s2-int-mac`（基于 02842d01f，未提交）。截图 `ghostty-wt/settings-mac-shots/p4-form/`（临时测试在测试宿主里离屏出图）。
⚠️ 测试宿主带着自己的配置文件（`GHOSTTY_CONFIG_PATH`）启动，而 form.zig 的「主文件」按默认候选找，指到用户自己的
`~/Library/Application Support/<bundle>/config.polter`；所以截图里是只读横幅，写入没有端到端验过，等 #967。

| # | 行为 | mac | Windows |
|---|---|---|---|
| G9 | 前五组按核心表的顺序列键；「全部选项」列全部键、可按键名过滤 | ✅ 真核心读数：外观 9（含 mac 独有的 macos-titlebar-style）/ 字体 3 / Polter 12 / 全部 230；单测 `theCoresOwnTableDecodes`（真 `ghostty_app_config_form` 的输出能解码、每组每个键都在 items 里且组名对得上）、`aGroupShowsItsKeysInTheTablesOrder`、`allOptionsIsEveryKeyFilteredByName` | |
| G10 | 控件：开关 / 枚举下拉 / 窄范围滑块（background-opacity）/ 文本 / 主题拆浅色+深色；全部选项里一律单行文本；可重复和来源不在主文件的只读 | ✅ 画面 `form-appearance-1180.png`、`form-all-1180.png`；规则 `control(for:in:)`、`usesSlider`、`themePair/themeValue` 的单测 | |
| G11 | 与默认值不同的标点，右键「恢复默认」（只对主文件里有那一行的键） | ⏳ 规则 `differsFromDefault`、`canRestoreDefault` 单测；画面上没出现过（测试宿主读到的全是默认） | |
| G12 | 只读项说明来源：别的文件 → 「由 <文件> 第 <行> 行设置」+「打开那个文件」；命令行 → 说明；可重复 → 「在配置文件中编辑…」 | ✅（可重复一格）`form-all-1180.png`；其余两格没在画面上出现过 | |
| G13 | 写入即时：开关、下拉、滑块松手就写；文本回车或失焦才写，没改不写；拒绝时红字显示在控件下、值退回；写完重载配置和表 | ⏳ 代码路径 + `leavingATextBoxWritesOnlyWhatChanged`、`aRefusalSaysWhatTheCoreSaid`、`aSetResultDecodesEitherWay`。**没有端到端写过**（见上面的 ⚠️） | |
| G14 | 进程读的配置文件和表单要写的不是同一个时，整页只读、顶上横幅写明两个路径 | ✅ 测试宿主实测：host=`/tmp/pxt…/config.polter`，main=`~/Library/Application Support/<bundle id>/config.polter`，writesAllowed=false，横幅见截图；单测 `aProcessOnAnotherConfigFileDoesNotWrite`（符号链接指向同一个文件时视为同一份） | |
| G15 | 高级：上一次写入前的备份位置 | ⏳ 读 `form.backup`；没有写过，所以只见过「还没有备份」 | |
| G16 | 窗口获得焦点时重读整张表 | ⏳ `windowDidBecomeKey` 里调 `reloadForm()`；没在真实例上验 | |
| G17 | §2.3a 网格 | ✅ 外观 / 全部选项 / Polter（1180）和外观（900）：顶带下沿 168–169 行、底带上沿 1494–1495 行（900：1134–1135）、侧栏竖线 440–441 贯通、列表竖线 962–963 只在主体里 | |

## 第 4 期：通用栏目（§7）· Windows 列（#963）

读数取自集成树 `s2-int-win`（feature/v0.9 9fc5c4bc5 + 合并中的 settings2/win-projects + 本期改动，未提交），交叉编译
`polter-host.exe` sha256 前缀 `1326f409`。**没上真机**：✅（纯层）= `polter-settings-shell` 的 `general` 模块单元测试
在 mac 上跑过、打坏过；⏳ = 写了、编过，等真机。mac 列见 mac 集成树的清单（#961 的 G1–G8 与 #964 的表单格）。

| # | 行为 | Windows |
|---|---|---|
| W-G1 | 通用栏目有分组列表（列表列 260）：外观 / 字体 / 终端 / 窗口与标签 / Polter / 全部选项 / 快捷键 / 高级 / 关于，与 mac `GeneralGroup` 同名同序 | ✅（纯层）`group_keys_are_the_macos_raw_values`、`group_rows_are_the_sidebar_rhythm_and_clicks_find_them`（900×620 下九行都在底带线之上）；⏳ 画面 |
| W-G2 | 路由 `general/<组>` 落到该组；无组时新开的窗口在第一组、已开的留在原组；不认识的组名当作无 | ✅（纯层）`a_route_lands_on_its_group_else_first_or_stays`、`general_carries_a_group_and_nothing_else`。⚠️ 规格 §3.1 表里 general 的 item 仍写「—」，mac #961 与这里都已按 `general/<组>` 做，表要改 |
| W-G3 | 前五组的键取自核心 `ghostty_app_config_form` 的 `sections`，顺序照核心；全部选项 = 全部键，按键名筛选（忽略大小写） | ✅（纯层）`a_group_shows_its_keys_in_the_tables_order_and_all_filters`；⏳ 画面 |
| W-G4 | 控件：开关→勾选框，枚举→下拉，主题→浅色 / 深色两个框（写回 `light:A,dark:B`，两边相同写一个名），其余→单行框；全部选项里可写的一律单行框；只读项只读框 + 原因 | ✅（纯层）`a_row_draws_by_whether_it_can_be_written`、`theme_pairs_round_trip`、`a_readonly_row_says_why`；⏳ 画面。数值项有 min/max 且跨度 ≤ 1（`background-opacity` 0–1）时是滑块（trackbar，100 步，最宽 240，右边显示两位小数去零的值，松手 / 放开按键时写，拖动时只刷新旁边的值），判定与 mac `ConfigFormRules.usesSlider` 同一张用例：`only_a_narrow_range_is_a_slider`、`a_slider_only_where_the_row_is_a_writable_number_outside_all`、`slider_positions_round_trip_to_what_is_written`、`the_slider_starts_on_the_control_column_and_stops_at_240`（#971）；⏳ 滑块画面、深色下的绘制 |
| W-G5 | 即时写入：开关 / 枚举一动就写，文本框回车或失焦时写，值没变不写；写完走宿主的重新加载，并原地刷新数值（不重建控件、键盘不丢） | ✅（纯层）`switches_write_at_once_boxes_on_enter_readonly_never`、`the_dot_and_restore_default`（`should_write`）；⏳ 真机 |
| W-G6 | 校验失败：控件下方红字显示核心的 `message`，值退回生效值，框线变红 | ⏳ |
| W-G7 | 与默认值不同的项在标签左侧有点；右键标签有「恢复默认」，仅当生效行在主文件里（规则 5） | ✅（纯层）`the_dot_and_restore_default`；⏳ 菜单 |
| W-G8 | 快捷键组：旧快捷键弹窗并入（列：名称 220 / 按键 160 / 说明；窄于 name+keys+说明 160 时说明折到按键下），UI 自动化行读的是这里的快照；底栏「在配置文件中编辑…」 | ✅（纯层）`keybind_rows_do_not_overlap_and_scroll_into_the_same_slots`、`a_narrow_page_puts_the_note_under_the_keys`、`keybind_scrolling_holds_at_the_ends`；⏳ 画面、UIA |
| W-G9 | 高级组：表单写入的文件、配置错误列表（旧错误弹窗并入）、本次运行第一次写入前的备份位置；底栏「打开配置文件…」「重新加载配置」 | ⏳ |
| W-G10 | 设置窗口没开、配置有错时（启动、重新加载），直接打开设置窗口到 通用 › 高级（替代旧的错误弹窗）；窗口开着时只刷新页面、不跳转 | ⏳ `general_ui::config_changed` |
| W-G11 | 关于组：版本（核心 `ghostty_info`）/ 构建（构建模式 · 本二进制身份，与 `[build]` 日志同源）/ 提交（宿主提交号），空值不显示 | ✅（纯层）`about_leaves_out_what_is_blank`；⏳ 画面 |
| W-G12 | 菜单「关于 Polter」「快捷键…」改走 `general/about`、`general/keybinds`；`settings_ui.rs` 整个删除 | ⏳ `menu.rs` |
| W-G13 | 窗口重新获得焦点时重读整张表（§7.3），不重建控件除非该组的键变了 | ⏳ |

单元测试（Windows 纯层）：`polter-settings-shell` 110 条（合并后 94 + `general` 16），基线 `zz-nothing` 0；
地板 10 处（G1–G10），每处红在各自断言行。其中「全部选项筛选区分大小写」第一版变异体是等价的（键名本来就全小写），没红；
改成拿掉查询词一侧的小写化后红在 `general.rs:488`。
