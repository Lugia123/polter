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

Windows 列（#988 真机，见第 2 期 Windows 表上方的「真机读数从哪来」）只填了真机读到的格；空着的格不在 #988 的范围里，没测。

| # | 行为 | mac | Windows |
|---|---|---|---|
| 1 | ⌘, / Ctrl+, 打开设置窗口（`open_config` os_open） | ✅ 主菜单 `performKeyEquivalent:` 收 ⌘, → `handled=1`，开出窗口。`01-first-open-cmd-comma.png`。⚠️ 核心 `GHOSTTY_ACTION_OPEN_CONFIG` 的 os_open / new_window 两个分支没有单独触发过 |✅ 96 / 144 @27ae20c52：Ctrl+, → `[settings] shown for route "" … (first opening)`。`96-1.1-first-open-client.jpg`、`144-1.1-first-open-client.jpg` |
| 2 | 菜单「偏好设置… / 设置…」打开设置窗口 | ✅ 菜单项（macOS 26 显示为「设置…」）→ `openConfig:` → 开出窗口。`02-reopen-keeps-size.png` | |
| 3 | 首开尺寸 1180×800，居中，超 90% 屏幕则缩 | ✅ frame 读回 `310,165,1180,800`（可用区 1800×1130，未触发 90%）。90% 截断：单元测试 `firstOpeningIsCutToNinetyPercent`、`onlyTheSideThatDoesNotFitIsCut`（1280×720 → 1152×648）；真机小屏没验 |✅ 96 @27ae20c52：`shown … at 690,364 1180x800 … (first opening) dpi=96`；144：1770x1200（= 1180×800×1.5）。90% 截断没在真机上造出来 |
| 4 | 最小 900×620，按钮不被裁 | ✅ 布局：900×620 下侧栏、列表、编辑器、底栏 + ⧉ − / 启动 / 还原 / 保存都在（旧构建截图，未随本次修复重截）。约束：原先 `minSize` 读回 0×32——SwiftUI hosting 在首次布局后按根视图最小尺寸（0×0）重设了它；现在根视图带最小尺寸、`sizingOptions = [.minSize]`，另在 `windowWillResize` 里用 `SettingsRules.clamped` 夹取。离屏探针（窗口不上屏）读回 minSize 900×620、frame 1180×800；单元测试 `aResizeIsHeldAtTheMinimum`。**修复后的 app 没在真机上读回过** |✅ 144：请求 200×200 被夹到 1350×930（= 900×620×1.5），96：900×620；底栏按钮不被裁（插件 P13 / R1、项目 P20 两格的读数） |
| 5 | 调大后关窗，再开尺寸保留 | ✅ 调到 1320×900、关窗；defaults `NSWindow Frame PolterSettings = 200 150 1320 900`；再开 frame 读回 `200,150,1320,900`。`02-reopen-keeps-size.png` | |
| 6 | 单例：多入口只有一个设置窗口 | ✅ 走完菜单栏 / tab 右键 / 终端右键三入口后，app 内标题为「Polter 设置」的窗口数 = 1 | |
| 7 | 菜单栏 智能体 ▸ 角色 ▸ 角色库… → roles/<当前终端的角色> | ✅ 焦点终端穿 test-worker，菜单项 route=`roles("test-worker")`，窗口选中「测试 Worker」。`03-menubar-role-library.png` | |
| 8 | tab 右键 ▸ 角色 ▸ 角色库… → roles/<该 tab 的角色> | ✅ 经 `NSMenuWillOpenNotification` 让真实的 `configureTabContextMenuIfNeeded` 加出角色子菜单，route=`roles("dev-worker")`，面包屑「角色 › 开发 Worker」。`04-tab-rightclick-role-library.png` ⚠️ 这张图的搜索框里有用户误打进来的 "pu"，列表被它过滤空了 | |
| 9 | 终端右键 ▸ 角色 ▸ 角色库… → roles/<该终端的角色> | ✅ route=`roles("test-worker")`，面包屑「角色 › 测试 Worker」。`05-terminal-rightclick-role-library.png`（同上，搜索框有 "pu"） | |
| 10 | 无角色的终端 / 无终端 → roles（无条目） | ✅（菜单读数）无角色终端的「角色库…」route=`roles(nil)`；单元测试 `theLibraryOpensOnThisTerminalsRole` 覆盖 `.none` 状态。没跑测试 | |
| 11 | 侧栏四栏目 角色 / 项目 / 插件 / 通用；项目、插件为占位 | ✅ 见 01。点「项目」只在 12 里点过（被询问拦下），占位页本身没截图 |✅ 96 / 144 @27ae20c52：角色 / 项目 / 插件（11 个插件逐行）/ 通用。`144-1.1-first-open-client.jpg` |
| 12 | 有未保存改动时切栏目先问（保存 / 不保存 / 取消） | ✅ 改「测试 Worker」名字后点侧栏「项目」→ 弹窗「保存修改吗？」按钮 取消 / 不保存 / 保存。`06a-dirty.png`、`06b-unsaved-prompt-alert.png`（NSAlert 自绘不全，文字以视图树读数为准） |✅ 96 @27ae20c52：插件有未保存改动时点「角色」→ 问「保存对这个插件的更改吗？」（插件 P7②） |
| 13 | 取消后留在原栏目、草稿保留、侧栏高亮复位 | ✅ 取消后仍是「角色 › 测试 Worker（改）」、蓝点在、侧栏高亮回「角色」。`06c-after-cancel.png` |✅ 96 @27ae20c52：取消后仍在 flaky、草稿 x 还在（插件 P7①）。侧栏高亮复位没单独读 |
| 14 | 未保存时切同栏目条目 / 从别的入口跳进来 / 关窗 先问 | ❌ 没验（代码走同一个 `SettingsUnsaved.confirmLeaving`） |✅（两支）96 @27ae20c52：切到另一个插件先问（P7①）、Ctrl+W 关窗先问（P7③）。「从别的入口跳进来」没读 |
| 15 | Esc 不关窗；⌘W 关窗（先问） | ❌ 没验 |✅ Esc 不关：96 / 144 @27ae20c52，按 Esc 后设置窗口仍在前台（`96-1.3-after-esc.jpg`、`144-1.3-after-esc.jpg`）。Ctrl+W 关：`[settings] hidden; last=…`；有未保存改动先问（P7③）。**焦点在哪都关**（R13，@2e768a5bf 96 / 144）：栏目窗口自身、勾选框、保存按钮、文本框、页面 close() 之后、点「保存」「还原」按钮变灰之后（插件 / 角色 / 项目）共 9 种都关，日志 `[settings] Ctrl+W (keyboard on …): closing`；对照 Ctrl+Shift+W、Ctrl+Alt+W 在任何焦点下都不关、标签页不动。页面里的 Ctrl+W（R10）@8aed2370c / @30f748f99 通过。中间两次 ❌：8aed2370c 上焦点在勾选框 / 按钮 / 栏目窗口时不关（→ #1005），30f748f99 上点保存后焦点为空时不关（→ #1010） |
| 16 | Launch 不可用原因写在底栏文字里 | ✅ 有未保存改动时底栏写「先保存角色再启动。」。见 06a | |
| 17 | 通用 ▸ 打开配置文件… | ❌ 没验 |✅ R4：96 @63dcba805、144 @8aed2370c，`.polter` 无关联时打开记事本，日志 `-> Notepad (.polter is claimed by None)`；`R96-R4-advanced-open-notepad-overview.jpg`。27ae20c52 上 ❌（系统 OpenWith 框，→ #999） |
| 18 | §2.3a 顶带下沿：侧栏 / 列表 / 编辑器三段同一行 | ✅ 1320×900 窗口 @2x：三段都是第 168–169 行（= 32pt 标题栏 + 52pt 顶带）。`07-grid-readings.png` |✅ 96 / 144 @27ae20c52：顶线侧栏段 / 内容段都在第 52 行（144：78），与日志 `[settings] grid … top rule row` 一致 |
| 19 | §2.3a 底带上沿：三段同一行 | ✅ 三段都是第 1694–1695 行（= 900 − 52 − 1 pt） |✅ 底线两段都在第 708 行（144：1065） |
| 20 | §2.3a 搜索框文字与面包屑同基线 | ✅ 搜索框填「角色」，与面包屑首字同字形比：「角」墨迹框两处都是第 104–128 行（阈值 40）/ 105–127 行（阈值 160），宽 22px；加权重心 116.34 / 116.30 |✅ 日志两条基线同为第 31 行（144：48）；墨迹 144 下两者都是 y 29..50，96 下 20..31 对 17..32（底沿差 1px，字号不同） |
| 21 | §2.3a 竖线上下贯通 | ✅ 侧栏竖线：顶带 / 主体上端 / 主体下端 / 底带都在第 440–441 列（= 220pt）；列表竖线：主体上端与下端都在第 962–963 列（= 220 + 1 + 260pt），顶带和底带里没有 |✅ 侧栏竖线顶带 / 中段 / 底带都在第 220 列（144：330） |
| 22 | §2.3a 表单「标签列 120 + 控件列」，勾选框 / 下拉进控件列 | ✅（目视）名称 / Key / 说明 / 打开位置 标签右对齐、勾选框与「打开位置」下拉在同一控件列。见 06a。没做像素测量 | |
| 23 | §2.3a 每列内容左缘 = 列左线 + PAD：面包屑文字、列表条目文字、底栏 + 按钮同一个 x | ⏳ 代码按 `SettingsLayout.ContentEdge` 摆放（三者都是 16），单元测试 `aColumnHasOneContentEdge`。修改后没在真机上量像素 | |
| 24 | §2.3a 侧栏搜索框左右缘 = 选中高亮左右缘（`PAD_SIDEBAR = 8`） | ⏳ 两者都取 `sidebarSearchEdges` / `sidebarHighlightEdges`（8..212），单元测试 `theSearchBoxAndTheHighlightShareTheirEdges`。没量像素 | |
| 25 | 搜索一个都不剩时列表写「没有匹配的角色」；过滤掉选中项时面包屑加「（不在搜索结果里）」 | ⏳ 规则 `SettingsRules.listing` / `breadcrumb`，单元测试 `aSearchThatMatchesNothingSaysSo`、`aSearchThatHidesTheSelectionSaysSo`、`theBreadcrumbNotesAHiddenItem`。没看画面 | |
| 26 | 侧栏与角色列表 ↑↓ 选上一个 / 下一个，两端停住不回绕，选中项滚动可见；切换照走「未保存先问」 | ⏳ 自绘行上 `focusable` + `onMoveCommand`，步进规则 `SettingsRules.step`，点行时焦点落到该列；角色列表 `ScrollViewReader` 滚到选中项。单元测试 `downAndUpMoveOneRow`、`theEndsHold`、`fromNothingDownIsFirstAndUpIsLast`、`anEmptyListGoesNowhere`、`theSidebarStepsThroughItsSections`。没按过键 | |
| 27 | 角色子菜单父项叫「角色」/「角色：<名>」，不带 beta | ⏳ 代码与文案改了（`PersonaMenu.title`、两份 Localizable.strings、MainMenu.xib 占位标题与 zh-Hans MainMenu.strings）。没看菜单 | |
| 28 | 内置角色在子菜单里显示本地化名（与列表一致的「Polter 总管」） | ✅（代码）子菜单行名取自 `PersonaCatalog`，它用的是 `Role.displayName`，与列表同源；本轮未改。没看菜单 | |
| 29 | 英文界面搜索框占位字 "Search" | ✅（代码）msgid "Search"，Base 为 "Search"、zh-Hans 为「搜索」 | |
| 30 | 最大化 / 缩放后关窗再开，状态与几何一致 | ⏳ 设置窗口 `collectionBehavior` 加 `.fullScreenNone`：绿色按钮是缩放，缩放后的 frame 就是普通 frame，按原样自动保存、原样再开，没有「标志与几何不一致」的余地。没在真机上关开过 | |
| 31 | 设置窗口开着时关掉最后一个终端窗口，app 不退出；退出前有未保存改动先问 | ⏳ 不退出：AppKit 只在最后一个窗口关掉后才问 `applicationShouldTerminateAfterLastWindowClosed`，设置窗口算窗口（且 mac 默认 quit-after-last-window-closed 为 false）。先问：`applicationShouldTerminate` 在关机检查之后、`needsConfirmQuit` 之前调 `SettingsWindowController.mayQuit()`（同一个未保存协议），取消则 `.terminateCancel`——之前 ⌘Q 在没有运行中进程时会直接退出、丢掉未保存的改动。都没在真机上试 |✅（不退出一支）144 @27ae20c52：`0 window(s) left -> the settings window is open; not quitting`，关设置窗口后 `… quitting`。「退出前先问」没读 |
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

Windows 列最初（#958）的读数取自 worktree `s2-win-plugins`（基于 60b63ad7d + 核心补丁 9ca547a18），交叉编译
`polter-host.exe` sha256 前缀 `f9194b09`，当时只有纯层单元测试。**现在每格写的是 #988 的真机结论。**

#### 真机读数从哪来（#988，2026-10-01，本节和第 3、4 期的 Windows 列都按这个读）

- 测试机：Windows 测试机（中文界面、中文输入法），96 DPI 与 144 DPI 各一轮干净进程。被测的都是 feature/v0.9 上的
  复测包，从干净克隆构建，测试机上每个包 713 个文件逐个 sha256 与本机清单一致，启动日志 `[build] polter-host.exe sha256=…`、
  `pair (both from <提交>)` 都核过。格子里写「@提交号」就是**最终通过的那个包**：
  27ae20c52（`5c51fdd3`，首轮）｜63dcba805（`3b21da6c`）｜8aed2370c（`9d1f4448`）｜30f748f99（`10d8e408`）｜
  2e768a5bf（`7c284409`）｜04b09b027（`d8affa38`）｜d627112ff（`cde3ee62`）。括号里是 polter-host.exe sha256 前缀。
- 证据：test-win 的 `results.md`（逐格读数、日志原文）和 `shots/`（截图，格子里写文件名；`R96-` / `R144-` 开头的是复测轮）。
  都不在仓内；各轮宿主日志在测试机 `D:\polter988\pkg-<提交>\`。
- 首轮（27ae20c52）里 ❌ 的格，写成「❌ → 修复单 → 复测包上 ✅」。
- **滚轮一律未读到**：Argus 在这台测试机上送不出滚轮事件（发了 delta，画面不动），不记成缺陷，也不算通过。

| # | 行为 | mac | Windows |
|---|---|---|---|
| P1 | 插件在侧栏「插件」下逐个列出，「通用」排在它们下面 | | ✅ 96 / 144 @27ae20c52：侧栏「插件」下 11 行、「通用」在其下，每行「点 名称 …… 状态字」。`96-1.1-first-open-client.jpg`、`144-1.1-first-open-client.jpg`。观察：固件名在侧栏宽度里被省略号截断 |
| P2 | 状态点判定顺序 ↻ > ○ > ◐ > ▲ > ●（§5.1） | | ✅ 96 @27ae20c52：flaky 启用后变「▲ 出错」（`96-P2-flaky-just-enabled.jpg`）；w1-controls「○ 已关」；page-demo 缺必填时「◐ 缺配置」（`96-WG10b-restart-opens-advanced-and-page-demo-half-dot.jpg`）。在跑时清空必填并保存显示 ↻ 而不是 ◐、关掉退避中的插件显示 ↻ 而不是 ○——总管裁定符合规格（↻ 排在最前）。状态点**自己刷新**（R14，@30f748f99 96 / 144）：干净进程先落在「角色」再点进插件、启用 flaky 后不碰窗口，6–9 秒内变 ▲ + 红字（`R144-R14-flaky-turned-error-by-itself.jpg`）；对照 8aed2370c 上 112 秒仍「● 已开」（只等了 112 秒，不是方案的 3 分钟）。纯层 `dot_table` 仍在 |
| P3 | ↻ 只在「保存时常驻进程已在跑」时留下（核心 `already_running`），横幅「重启 Polter 后生效」，无按钮 | | ✅ 96 / 144 @27ae20c52：存档在跑时改目录保存 → `plugin_configure ok=true said="already_running"`、侧栏 ↻、详情顶部横幅「重启 Polter 后生效」、无按钮；重启后回到「● 已开」。`144-P3-archive-restart-banner.jpg`。首轮状态字被截成「改了未…」，#990 后 R6（144 @30f748f99）读到完整的「改了未重启」 |
| P4 | 核心没回答运行状态时不画 ▲，详情写「Polter 核心没有报告这个插件是否在运行」 | | ✅（核心有回答的一支）96 @27ae20c52：flaky / page-demo / w1-controls / 存档四个详情都没有这句。「核心没回答」那一支没在真机上造出来，只有纯层 `dot_table` 末行 |
| P5 | 点侧栏插件行 → 路由 `plugins/<key>`，面包屑「插件 › <名>」 | | ✅ 96 / 144 @27ae20c52：面包屑「插件 › Page demo (test fixture)」，日志 `[plugins-ui] shown: named=Some(8)`、`[settings] section plugins item=Some("page-demo")`。`144-P5-P8-page-demo-settings.jpg` |
| P6 | 菜单「插件…」、Ctrl+Shift+, → `plugins`（打开，不再是开关） | | ✅（菜单）96 @27ae20c52：智能体 › 插件… → 插件栏目（`96-P6-agent-menu.jpg`）。**方案勘误**：Ctrl+Shift+, 是 `reload_config`（与 mac 一致），不打开设置窗口；本行行为里写的「Ctrl+Shift+,」作废（总管裁定）。真机上按它两次都是 `[action] reload_config` |
| P7 | 插件有未保存改动时切到别的插件 / 别的栏目 / 关窗先问「保存对这个插件的更改吗？」 | | ✅ 96 @27ae20c52：flaky 有未保存改动时 ①切到另一个插件 ②点「角色」③Ctrl+W，都问「保存对这个插件的更改吗？」；取消留在原处、草稿还在；不保存后 flaky.json 不变。`96-P7-dirty-prompt-on-switch-plugin.jpg`。观察：这个询问的日志标签是 `[roles-ui]` |
| P8 | 缺必填项时开关不能打开，旁边写缺哪几项 | | ✅ 96 @27ae20c52：webhook 空时开关 `enabled=false`、旁边红字「必填但仍为空：Webhook」；填上（未保存）后红字消失、开关可用。`96-P5-P8-page-demo-switch-disabled.jpg`、`96-P8-webhook-filled-switch-enabled.jpg` |
| P9 | 表单：标签列 120 右对齐 + 控件列，说明在控件下；与开关同一条控件列 | | ✅ 96 / 144 @27ae20c52（UIA）：开关 / 文本框 / 下拉 / 勾选框左缘同一 x（客户区 96：365，144：547）；标签列 120px（144：180px），标签右对齐；说明在控件下。`96-P9-w1-controls-client.jpg`、`144-P9-w1-controls-client.jpg`。首轮文本框外框比框长 16 / 26px → #990 → R6（144 @30f748f99）线 546..1697 对框 547..1697 |
| P10 | 保存经核心 `ghostty_app_plugin_configure`（空值=删除），宿主不再自己写设置文件 | | ✅ 96 @27ae20c52：w1-controls 三次保存的文件原文——填 abc：`"a_text": "abc"`；清空：params 里没有 a_text；填 x：`"a_text": "x"`；日志 `plugin_configure ok=true said="not_started"`；文件写法与核心写的 page-demo.json 相同 |
| P11 | 「测试」在底栏还原左边，结果首行写在底栏，全文放在日志框顶部；一分钟一次的额度有专门的话 | | ✅ 96 @27ae20c52：测试结果首行在底栏、全文在日志框顶部；一分钟内再按 → 底栏红字「距上次测试不到一分钟，请一分钟后再试。」。`96-P11-second-test-within-a-minute.jpg` |
| P12 | 日志：最近 20 行 + 「显示日志」「显示插件文件夹」 | | ✅ 96 @27ae20c52：日志框最新一行在最下、11 行；「显示日志」打开记事本 `flaky.log`，「显示插件文件夹」打开资源管理器 |
| P13 | 最小窗口 900×620、横幅 + 长简介时表单区仍 ≥ 2 行控件高，五种 DPI | | ❌ @27ae20c52（最小窗口表单区 96：50px、144：68px，不足两行控件；侧栏「通用」被底带线切掉一半）→ #990 → ✅ R1：96 @63dcba805 表单区 64px、日志框 2 行；144 @30f748f99 表单区 112px；点露出一半的「通用」侧栏自动滚动、选中行落在底带线之上。`R96-R1-min-window-archive.jpg`、`R144-R1-min-window-archive.jpg`、`R144-R1-click-general-scrolls-into-view.jpg`。**滚轮滚侧栏：未读到**（见上） |
| P14 | 有 `ui/index.html` 才有「页面」页签；缺 Runtime / 缺 Loader / 创建失败 三种各有说明，页签不藏 | | ✅ 144 @27ae20c52：缺 Runtime（`144-P14a-runtime-missing.jpg`，日志 `-> RuntimeMissing`）、缺 Loader（改名后进程照常起，`144-P14b-loader-missing.jpg`）两种说明都对、页签都在；装上 Runtime 后页面渲染（`144-P14c-page-rendered.jpg`，96 同）。「创建失败」一支没造出来 |
| P15 | 页面只能读 `ui/` 里的文件，`..`、编码过的 `..`、别的插件、别的 scheme 一律拒 | | ✅ R3 / R3b / R3c：96 @63dcba805、144 @30f748f99。index.html / style.css / app.js 三个 `-> 200`；fetch example.com、`../plugin.json`、别的插件都是 `FAILED: TypeError: Failed to fetch`，页面策略框每次多一行 `blocked by the page's policy: connect-src -> …`，宿主日志里这三个地址 0 行；settings() / save() / window.open / close() 如预期。**方案勘误**：P15-4（`../plugin.json`）原写 `status 403`；插件页面本来就不许 fetch（`connect-src 'none'`，与 mac 一致），请求在页面里被拦、得到 TypeError，到不了宿主（#999 改了预期）。`R96-R3b-btn4-pluginjson.jpg`、`R144-R3b-btn4-pluginjson.jpg` |
| P16 | `WebView2Loader.dll` 不在导入表（缺它时进程照常起） | | ✅ 每个复测包构建后 `objdump -p` 都核过导入表里没有 WebView2Loader.dll；真机 144 @27ae20c52：把 Loader 改名后进程照常起（P14 的缺 Loader 一格） |
| P17 | 搜索框按插件名过滤侧栏插件行，过滤掉当前插件时面包屑加「（不在搜索结果里）」 | | ✅ 96 @27ae20c52：搜 flak → 侧栏插件行只剩「▲ Flaky 出错」，选中的 page-demo 被滤掉，面包屑「插件 › Page demo (test fixture)（不在搜索结果里）」。`96-P17-search-flak.jpg` |

#988 读到的、不在上表行里的（都没有单子，按轻重）：

- 浮层关掉后键盘回到看不见的标签页（F10）：30f748f99 上 2/2 复现 → #1012 → R15 @04b09b027 设置窗口 96 / 144 通过，
  日志 `[overlay] settings closing: remembered … -> keyboard to … (CurrentPane)`；搜索条那一格 @96 ❌（键盘交还给了已隐藏的搜索窗口自己）
  → #1016 → R16 @d627112ff 96 / 144 通过（搜索条所属终端切出屏幕时自己结束，`the bar's terminal … is no longer on screen`）。
- 按钮变灰后键盘的去处（R17，#1017）：@d627112ff 96 / 144，插件 / 角色栏目交给表单里的框（Edit id=2000 / 1000），项目栏目交给栏目窗口自身；
  之后打字没有进侧栏搜索框。2e768a5bf 上交给的是侧栏搜索框（打字会过滤侧栏）。
- Ctrl+Shift+F 在这台机上打不开搜索：键绑着，但宿主日志 `[key] TSF ate … vk=0x46 … (not dispatched)`，被中文输入法吃掉
  （「微软拼音拿它做简繁切换」是推断，没核对）；菜单「查找…」不显示快捷键（`no shortcut for 27 of 50 core actions`）。
- 主窗口宽 770 时活动的第 2 个标签页上没有 ×；144 DPI 下调色板 `shown at -35,194 840x525`，比窗口宽、贴屏幕左缘时左边被切；
  搜索条计数显示「-1/1」；R5 焦点回到字号框后光标在开头；关窗时 `[page] keyboard taken back from the hidden page (HWND(<表单框>))` 的 from 印的不是页面。

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
| PJ25 | 「另存为项目」在名字框输入已有项目名（含只差大小写）再保存，先弹与点选已有项目相同的覆盖确认；取消 = 不写、不换绑定（#980） | ✅ 真机（mac-saveas980，dylib `7231a4b7`）：输入 gamma、Gamma 都弹「覆盖这个项目？“gamma”已经有 1 个面板…被替换的版本会留作上一版。」，取消后 gamma.json sha 不变、没有新文件和 `.prev`。地板：`createNew` 改回直接 `onSave`（`e20d40c0`）→ 不问，gamma.json 被连续改写两次。判定：`ProjectsRules.saveAsStep` + `ProjectStore.nameVerdict(current: nil, …)`（与重命名同一规则，文件名不分大小写）。`p980/run.sh` 复现 | |

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
| G8 | 菜单「快捷键…」→ `general/keybinds`：打开设置窗口的「快捷键」组，不再开旧的独立窗口（旧的 `KeybindsController` 已在第 4 期 #975 删除） | ✅ 在测试宿主里调真实的 `AppDelegate.showKeybinds(nil)`：打开的是「Polter 设置」窗口、只有 1 个，面包屑「通用 › 快捷键」（`menu-keybinds-1180.png`）；单测 `theKeyboardShortcutsMenuRoutesToItsGroup`。⏳ 菜单项本身没有点过（xib 的 action 没改，仍然是 `showKeybinds:`） | |

## 第 3 期：项目栏目（§6）· Windows 列（#959）

> 行号与 mac 那一节（`settings2/mac-projects`，1f9d4de14）的 P1–P20 一一对应，合并时填进那张表的 Windows 列；
> W1–W3 是 §6.3 只属于 Windows 的三项。读数取自 worktree `s2-win-projects`（基于 60b63ad7d，未提交改动）。
> 当时（#959）测试机没开，格子里只有纯规则的单元测试；**现在每格写的是 #988 的真机结论**，来源与写法见第 2 期 Windows 表上方
> 「真机读数从哪来」。纯规则的用例名留在 #959 的交付记录里，这里不再重复。

| # | Windows |
|---|---|
| P1 | ✅ 96 / 144 @27ae20c52：「beta / 2026-10-01 13:10 · 1 个面板」「alpha / … · 2 个面板」，tab 数不显示。`96-P1-P14-projects-beta-1180.jpg`、`144-P1-P14-projects-beta-1770.jpg` |
| P2 | ✅ 96 / 144 @27ae20c52：alpha（两窗格）缩略图两个框「D: · D:\」「Windows · C:\Windows」。`144-P2-P3-alpha-detail.jpg` |
| P3 | ✅ 96 / 144 @27ae20c52：目录「D:\; C:\Windows」、回滚内容 2.6 KB（96：2.7 KB）、自动保存「没有绑定到打开的窗口」。`144-P2-P3-alpha-detail.jpg` |
| P4 | ✅ 96 / 144 @27ae20c52：alpha →「打开」→ `[projects-ui] open "alpha" … -> load_project_into_new_tab`、`[tab] created; count now 3`，新标签页两个窗格 `PS D:\>` / `PS C:\Windows>`。`144-P4-alpha-opened-tab3.jpg` |
| P5 | ✅ 96 / 144 @27ae20c52：alpha → alpha2，目录里 alpha.json / alpha.scrollback 换成 alpha2.*，日志 `renamed "alpha" -> "alpha2"`。名字去首尾空白、判重（含只差大小写）、空名拒绝见下面 3b。`144-P5-rename-prompt.jpg`。观察：重命名 / 另存为的输入框是衬线字，和设置窗口其余部分不一致 |
| P6 | ✅ 96 / 144 @27ae20c52：alpha2 改成 beta 被拒，底栏红字「已经有一个叫「beta」的项目。」，两个文件 sha 不变（`144-P6-rename-to-beta-refused.jpg`）；改名时 .scrollback 一起走（P5）。`.prev` 里的名字没单独读 |
| P7 | —（Windows 没有 tab↔项目绑定，裁定不做） |
| P8 | ✅ 96 / 144 @27ae20c52：复制 → 「alpha2 副本」（.json + .scrollback）；再复制按「副本 2」递增，手放的空文件「副本 3」被跳过、得「副本 4」（3b N13 / N14）。`144-P8-copy-alpha2.jpg`、`144-N13-N14-gamma-copies.jpg` |
| P9 | ✅ 96 / 144 @27ae20c52：确认框「用当前标签页覆盖「beta」？… 被替换的版本会保留，可以恢复。」；覆盖后 `beta.json.prev` 的 sha = 覆盖前 beta.json 的 sha（1 窗格盖 1 窗格也留）。`144-P9-overwrite-confirm.jpg`。「没终端窗口时按钮灰」没读 |
| P10 | ✅ 96 / 144 @27ae20c52：删除后列表顶「已删除「alpha2 副本」 [撤销]」，撤销后文件 sha 与删前相同。`144-P10-deleted-undo-banner.jpg`、`96-P10-deleted-undo-banner.jpg` |
| P11 | ✅ 96 / 144 @27ae20c52：横幅还在时关窗 → `[projects-ui] window closed: "…" -> Recycle Bin ok=true`，回收站 0 → 1 项、`projects\.deleted` 清空（证据是回收站枚举，不是截图）。观察：回收站里的条目是 `.deleted\<名>-<时间>` 目录，从回收站还原会回到 `.deleted` 下，不回到列表。「同名已被占用时撤销拒绝」没读 |
| P12 | ✅ 96 / 144 @27ae20c52：版本历史「当前版本 · 13:15」「上一版 · 13:10 [恢复]」；恢复两次，beta.json 与 .prev 的 sha 来回互换，日志两行 `restored the previous version of "beta"`。`144-P12-version-history.jpg` |
| P13 | ❌ @27ae20c52 144：资源管理器打开了目录但没选中文件（96 那轮 3/3 选中）→ #1000 → ✅ R2：96 @63dcba805 6/6、144 @30f748f99 6/6，`beta` 和带空格中文的 `测试 项目` 各 3 次都选中，日志全是 `SHOpenFolderAndSelectItems`、无退路。`R96-R2-beta-1-selected.jpg`、`R96-R2-cjk-space-1-selected.jpg`、`R144-R2-beta-1-selected.jpg` |
| P14 | ✅ 96 / 144 @27ae20c52：菜单 项目 › 管理项目… → `[settings] shown for route "projects"`、`section projects item=None` |
| P15 | ✅ 96 / 144 @27ae20c52：项目栏目搜 alp 留在项目、列表只剩 alpha2；在角色栏目搜 beta 跳到项目、面包屑「项目 › alpha2（不在搜索结果里）」。`144-P15a-search-alp-in-projects.jpg`、`144-P15b-search-beta-from-roles-jumps.jpg` |
| P16–P19 | ✅ 96 / 144 @27ae20c52（像素）：1180 宽 @96 顶线 52、底线 708（侧栏 / 列表 / 详情三段相同）、侧栏竖线 220、列表竖线 481、「+」左缘 237、最右按钮距右缘 16；900 宽底线 528。1770 宽 @144 顶线 78、底线 1065、竖线 330 / 721、「+」左缘 355；1350 宽底线 795。与日志 `[projects-ui] grid:` 一致。`144-P16-P20-projects-min-window.jpg`、`96-P16-P20-projects-min-window.jpg` |
| P20 | ✅ 96 / 144 @27ae20c52：最小窗口下详情最低墨迹 495 < 底线 528（144：749 < 795），缩略图 102px（144：157px = 104.7 逻辑）≥ 96。观察：96 下版本历史那行被截成「… 2 个面…」 |
| W1 | ✅ 96 / 144 @27ae20c52：`w1 [menu] pick "Manage Projects…" -> __polter_manage_projects ok=1` → 项目栏目（同 P14） |
| W2 | ✅ 96 / 144 @27ae20c52：跑着 ping 的标签页关闭时弹「关闭前存成项目吗？」；选「另存为项目…」后 Esc → `Save as Project cancelled; the tab stays open`；存成 w2ping → `saved as project "w2ping"; closing the tab`，ping 进程 0。`144-W2-close-tab-with-ping-asks.jpg`。首轮空闲提示符也弹（F3）→ #991 → R7：96 @8aed2370c、144 @30f748f99 各 4/4，空闲 PowerShell / cmd 不问直接关、跑 ping 的问（`R96-R7-idle-powershell-closed-no-prompt.jpg`、`R96-R7-ping-powershell-close-prompt.jpg`） |
| W3 | ✅ 96 / 144 @27ae20c52：标签页右键 关闭… ｜ 重命名标签… ｜ 标签颜色 ｜ **另存为项目… / 加载项目…** ｜ 智能体三项。`144-W3-tab-context-menu.jpg`、`96-W3-tab-context-menu.jpg` |

3b 项目名（#983，N1–N14）：96 / 144 @27ae20c52 全部通过——另存为输入「  gamma 」/ `Gamma` / `gamma` 都弹同一个覆盖确认（写的是 “gamma”），
取消一个字节不写，覆盖后 `.prev` = 覆盖前；`delta` 不问直接存；重命名「  gamma 」/ `Gamma` 被拒、三个空格「项目要有名字。」、「epsilon 」存成
`epsilon.json`（无尾随空格）。`144-N1-overwrite-gamma-confirm.jpg`、`144-N4-Gamma-confirm-says-gamma.jpg`、`144-N8-rename-zeta-to-gamma-refused.jpg`、
`96-N10-rename-blank-refused.jpg`。N7（另存为输入三个空格）行为对，日志原文是 `Save as Project accepted with an empty name; nothing sent`，与方案写的
`declined or empty; nothing written` 措辞不同。

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

当时（#963）读数取自集成树 `s2-int-win`，交叉编译 `polter-host.exe` sha256 前缀 `1326f409`，只有纯层单元测试。
**现在每格写的是 #988 的真机结论**，来源与写法见第 2 期 Windows 表上方「真机读数从哪来」。方案里的 W-G14–W-G19
（标签名称、下拉选项、写进文件的原值、框宽、「更多…」、红字的清除）对应上面表单那张表的 G21 / G22 / G25，读数写在那三格。
mac 列见 mac 集成树的清单（#961 的 G1–G8 与 #964 的表单格）。

| # | 行为 | Windows |
|---|---|---|
| W-G1 | 通用栏目有分组列表（列表列 260）：外观 / 字体 / 终端 / 窗口与标签 / Polter / 全部选项 / 快捷键 / 高级 / 关于，与 mac `GeneralGroup` 同名同序 | ✅ 96 / 144 @27ae20c52：九组 外观 … 关于，同名同序；最小窗口（144）下九组都在底带线之上。`144-WG1-general-appearance-1770.jpg`、`96-WG1-general-appearance-1180.jpg`、`144-WG8-WG1-keybinds-min-window.jpg` |
| W-G2 | 路由 `general/<组>` 落到该组；无组时新开的窗口在第一组、已开的留在原组；不认识的组名当作无 | ✅ 96 / 144 @27ae20c52：菜单「快捷键…」→ `shown for route "general/keybinds"`、`[general-ui] shown at keybinds`；「关于 Polter」→ `general/about`；配置出错时 → `general/advanced`（W-G10）。`144-WG2-menu-keybinds.jpg`。「不认识的组名当作无」没在真机上造 |
| W-G3 | 前五组的键取自核心 `ghostty_app_config_form` 的 `sections`，顺序照核心；全部选项 = 全部键，按键名筛选（忽略大小写） | ✅ 96 / 144 @27ae20c52：外观组顺序 主题、背景不透明度、背景模糊、光标样式…；全部选项按键序列出，筛 `FONT` 只剩 font-*（忽略大小写）。`144-WG3-all-options-filter-FONT.jpg`、`96-WG3-all-options-filter-FONT.jpg`。观察：首轮长键名被截成「font-family-bold…」，bold / bold-italic 两行看不出区别；#990（标签换行）之后这一项**未读到**（复测轮没看全部选项） |
| W-G4 | 控件：开关→勾选框，枚举→下拉，主题→浅色 / 深色两个框（写回 `light:A,dark:B`，两边相同写一个名），其余→单行框；全部选项里可写的一律单行框；只读项只读框 + 原因 | ✅ 96 / 144 @27ae20c52：光标样式是下拉、光标闪烁是勾选框、主题是浅色 / 深色两个框、背景不透明度是滑块（240 逻辑像素，144 下 360px），右边显示数值；拖到 0.9 松手只写一行 `set background-opacity = Some("0.9")`，左方向键再写一行 `0.89`。`144-WG4b-slider-0.9.jpg`。**未读到**：拖动中途「只刷新数值、不写」（一次性的拖动注入看不到中途）；深色下的绘制 |
| W-G5 | 即时写入：开关 / 枚举一动就写，文本框回车或失焦时写，值没变不写；写完走宿主的重新加载，并原地刷新数值（不重建控件、键盘不丢） | ✅ 96 / 144 @27ae20c52：字号输 15 回车 → 一行 `set font-size = Some("15")`，再 Tab 走开（没改）不写；下拉一选就写（`set copy-on-select = Some("clipboard")`）；写完插入点还在表单的框里 |
| W-G6 | 校验失败：控件下方红字显示核心的 `message`，值退回生效值，框线变红 | ✅ 96 / 144 @27ae20c52：字号输 abc 回车 → 控件下红字 `font-size: invalid value "abc"`（核心原文）、框线变红、值退回 15、底栏同一句；配置文件 sha 前后不变。`144-WG6-WG19-0-red-abc.jpg`、`96-WG6-WG19-0-red-abc.jpg` |
| W-G7 | 与默认值不同的项在标签左侧有点；右键标签有「恢复默认」，仅当生效行在主文件里（规则 5） | ✅ 96 / 144 @27ae20c52：写过的字号标签左侧有「•」；右键 →「恢复默认」→ `set font-size = None`，文件少了那一行（sha 回到写之前）、点消失、值回 12；没写进文件的「行高调整」右键没有菜单。`144-WG7-restore-default-menu.jpg`、`144-WG7-after-restore-default.jpg` |
| W-G8 | 快捷键组：旧快捷键弹窗并入（列：名称 220 / 按键 160 / 说明；窄于 name+keys+说明 160 时说明折到按键下），UI 自动化行读的是这里的快照；底栏「在配置文件中编辑…」 | ✅（布局）96 / 144 @27ae20c52：宽窗口三列、99 个动作，窄窗口说明折到按键下面，PageDown 翻一页。`144-WG8-keybinds-wide.jpg`、`144-WG8-WG1-keybinds-min-window.jpg`。「在配置文件中编辑…」：❌ @27ae20c52（`.polter` 无关联，出系统 OpenWith 框）→ #999 → ✅ R4：96 @63dcba805、144 @8aed2370c 打开记事本（`R96-R4-keys-edit-notepad-title.jpg`）。**滚轮未读到**；UIA 行快照没单独读。观察：部分动作名是英文原名（open_config、close_tab…）、列表没有可见滚动条、窄窗口下按键列在右缘被裁掉 |
| W-G9 | 高级组：表单写入的文件、配置错误列表（旧错误弹窗并入）、本次运行第一次写入前的备份位置；底栏「打开配置文件…」「重新加载配置」 | ✅ 96 / 144 @27ae20c52：显示表单写入的文件、「配置加载时没有错误。」、首次写入前的备份位置；「重新加载配置」→ `[reload] hard -> re-read the file, 0 diagnostic(s)`。`144-WG9-advanced.jpg`。「打开配置文件…」同 W-G8：首轮 OpenWith → R4 记事本（`R96-R4-advanced-open-notepad-overview.jpg`）。观察：路径里正反斜杠混用（`…\polter/config.polter`） |
| W-G10 | 设置窗口没开、配置有错时（启动、重新加载），直接打开设置窗口到 通用 › 高级（替代旧的错误弹窗）；窗口开着时只刷新页面、不跳转 | ✅ 96 / 144 @27ae20c52：窗口没开时配置里写 `font-size = abc` 再重载 → 设置窗口自己打开到 通用 › 高级，列出 `…config.polter:9:font-size: invalid value "abc"`（`144-WG10-auto-open-advanced-with-error.jpg`）；带着错重启同样（`144-WG10b-restart-with-error-opens-advanced.jpg`）；窗口开着、停在「关于」时再重载 → 不跳。改好后重载回到「没有错误」。观察：一次重载日志里 `config diagnostics` 和 `shown at advanced` 各出现 7 次（每个窗格的通知各触发一次） |
| W-G11 | 关于组：版本（核心 `ghostty_info`）/ 构建（构建模式 · 本二进制身份，与 `[build]` 日志同源）/ 提交（宿主提交号），空值不显示 | ✅ 96 / 144 @27ae20c52：版本 `1.3.2-HEAD+27ae20c52`、构建 `ReleaseFast · polter-host.exe sha256=5c51fdd335fd0437 …`、提交 `27ae20c52`，与 `[build]` 日志一致。观察：构建那一行行尾被省略号截断 |
| W-G12 | 菜单「关于 Polter」「快捷键…」改走 `general/about`、`general/keybinds`；`settings_ui.rs` 整个删除 | ✅ 96 / 144 @27ae20c52：两个菜单之后顶层可见窗口只有「Polter 设置」和主窗口，没有旧的关于 / 快捷键弹窗；带错重载时也没有错误弹窗 |
| W-G13 | 窗口重新获得焦点时重读整张表（§7.3），不重建控件除非该组的键变了 | ✅（重读）96 / 144 @27ae20c52：设置窗口失焦时外部把 font-size 改成 17，点回来字号框是 17、标签旁有点。焦点：❌ @27ae20c52（切回后键入的字不进原来的框，F6）→ #999 → ✅ R5：96 / 144 @8aed2370c，`[settings] activated; keyboard back to HWND(…)`，键入落进字号框，含外部改文件的对照（`R96-R5-typed-3-lands-in-font-size.jpg`、`R144-R5-control-external-17-typed-5.jpg`）。观察：焦点回到框后光标在开头。「键变了才重建控件」没单独读 |

单元测试（Windows 纯层）：`polter-settings-shell` 110 条（合并后 94 + `general` 16），基线 `zz-nothing` 0；
地板 10 处（G1–G10），每处红在各自断言行。其中「全部选项筛选区分大小写」第一版变异体是等价的（键名本来就全小写），没红；
改成拿掉查询词一侧的小写化后红在 `general.rs:488`。
| G18 | 端到端写入（#968，#967 合入后）：改值 → 文件字节 → 重载 → 标点 → 非法值红字 → 恢复默认删行 | ✅ 测试宿主里 `ConfigFormWriteTests.aValueIsWrittenReloadedMarkedRefusedAndRestored`：form.main 与宿主读的是同一个临时文件（不是的话测试在写之前就停）；font-size 写入后原有字节不变、追加在「由 Polter 设置窗口写入」块下；app 配置读回 17；行上有标点、来源 main；备份与写前逐字节相同；非法值文件一个字节不变、红字、值不变；恢复默认后那一行没了、app 读回默认。截图 `ghostty-wt/settings-mac-shots/p4-form-write/` w0–w5 | |
| G19 | 配置出错（启动 / 重载）且设置窗口没开 → 打开到 通用›高级；窗口开着 → 只刷新不跳（替代旧的配置错误窗口） | ✅ `aConfigErrorOpensTheWindowAtAdvancedAndThenStaysPut`：往测试宿主的配置里写一行坏值、重载 → 窗口开在 通用›高级；切到「关于」再重载 → 仍在「关于」。规则 `SettingsRules.onConfigChanged` 三条单测。截图 w4 | |
| G20 | 写入后控件显示磁盘上的值（被拒时退回生效值） | ✅ 截图 w1（写 17 后框里是 17）、w2（非法值被拒，框里退回 17、下方红字）。修之前框里一直显示 13，是从截图里发现的 | |
| G21 | 前五组每项显示本地化名称；说明行是「键名（等宽灰字）+ 一句话说明」，Ghostty 原文收在「更多…」里；全部选项里没有名称的仍显示键名（#973） | ✅ 截图 `ghostty-wt/settings-mac-shots/p4-form-labels/`（外观 / 字体 / 终端 / 窗口与标签 / Polter 1180 宽，Polter 900 宽，全部选项）。核心：`form.zig` 表项的 label / summary 不给默认值，漏填编译报 `missing struct field: label`；测试「前五组每项都有非空 label / summary，summary ≤ 60 字符、只有一行、label 不等于键名」。mac：`everyNameTheCoreHandsOverIsTranslated` 用真核心的输出逐条核对 zh-Hans 都有译文。⏳「更多…」的展开没有点过（离屏截图点不了链接） | ✅ 96 / 144 @27ae20c52（方案 W-G14）：外观 / 字体 / 终端 / 窗口与标签 / Polter 五组的标签都是中文名，说明行是「键名（灰）+ 一句中文」，没有仍是键名的标签。`144-WG14-font-group.jpg`、`96-WG14-terminal-group.jpg`、`96-WG14-polter-group.jpg`。观察：「关闭最后一个窗…」（quit-after-last-window-closed）标签被省略号截断。「更多…」见 G22 |
| G22 | 前五组枚举项的下拉显示本地化名称（方块 / 竖线 / 询问 / 跟随系统…），写进文件的仍是原值；只有两个值的已经都是开关；数值框 120、短文本框 160，从控件列起（#977） | ✅ 截图 `ghostty-wt/settings-mac-shots/p4-form-choices/`（外观 / 终端 / 窗口与标签，1180 与 900；字体 1180）。核心：枚举键缺名称、或给了枚举里没有的值，都编不过（报出键名和值）；测试「每个值有名称、同一键内名称不重复、JSON 里 choice_labels 与 choices 一一对应」。mac：`aValueIsShownByItsNameAndWrittenAsItself`、`aShortBoxIsSizedForWhatGoesInIt`，真核心的每个选项名都有中文 | ✅ 96 / 144 @27ae20c52（方案 W-G15–W-G18）：下拉显示中文选项名（光标样式 竖线 / 方块 / 下划线 / 空心方块，终端、窗口与标签各下拉逐项读出），写进文件的是原值（`cursor-style = block_hollow`、`copy-on-select = clipboard`、`window-save-state = never`、`confirm-close-surface = false`）；字号框 120（144：180px），从控件列起；「更多… / 收起」展开 Ghostty 原文、下面的行下移不重叠（`144-WG18-expanded.jpg`）。**方案勘误**（W-G17）：左右 / 上下边距是短文本框 160（144：240），不是数值框 120——window-padding-x/y 不是数值控件，mac 相同（总管裁定，R9 两个 DPI 读到 160 / 240）。首轮整行宽的下拉箭头被表单滚动条盖住（F4）→ #1003 → R12 ✅：96 / 144 @8aed2370c，首次进组与写入重载后，下拉右缘与箭头都在滚动条左缘之左（`R96-R12-appearance-first-entry.jpg`、`R144-R12-appearance-after-reload.jpg`） |
| G23 | 菜单「关于 Polter」→ 设置窗口 通用›关于（与 Windows W-G12 一致），旧的 About 窗口删掉；原来窗口里的 Docs / GitHub / Ghostty 链接和版权行搬进「关于」组（#979） | ✅ 在测试宿主里调真实的 `AppDelegate.showAbout(nil)`：打开的是「Polter 设置」，只有 1 个，停在 通用›关于（`aboutPolterOpensTheAboutGroup`）。截图 `ghostty-wt/settings-mac-shots/p979/a1-about-from-menu.png`、`a4-about-900.png`。`Features/About/` 五个文件已删，grep 没有调用者 | |
| G24 | 在通用栏目的组列表里点一个组，面包屑跟着变（#974 C） | ✅ `choosingAGroupIsAChangeTheRootViewSees`（组的变化要通知到根视图观察的那个 model）。截图 a2（点「高级」→「通用 › 高级」）、a3（点「快捷键」→「通用 › 快捷键」） | |
| G25 | 被拒值的红字只属于那一次写入：写入后的那次读表保留；窗口获焦、重载配置、切到别的组再读表时清掉（#986） | ✅ 测试宿主 `aRefusalIsGoneOnceTheFormIsReadAgain`（写非法值 → 红字在；重读 → 没了；再写非法值 → 切组再切回 → 没了；文件一个字节没变）；规则 `ConfigFormRules.errors(_:after:)` | ✅ 96 / 144 @27ae20c52（方案 W-G19）：红字出现后 ①同组内 Tab 走开再回来，红字、红框、底栏红字都在；②点别处再点回设置窗口，三样都清掉；③终端里重载配置（设置窗口没获焦）也清掉，对照只失焦不重载时还在；④切到别的组再切回，清掉。四次期间配置文件 sha 不变。`144-WG6-WG19-0-red-abc.jpg`、`96-WG6-WG19-0-red-abc.jpg` |
