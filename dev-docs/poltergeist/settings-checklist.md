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
