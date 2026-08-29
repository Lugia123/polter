# Tab 合并与状态标记

> 最后更新对应的 git commit：`908f55b1f`（工作模式换成「按住」这一轮改动尚在工作树里，未提交）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**已实现**（S4）。判定在 `src/poltergeist/Bus.zig` 的 `TabMark` 与 `tabMark`，写入在 `src/Surface.zig` 的 `updatePoltergeistTabMark`，刷新在 `src/App.zig` 的 `refreshPoltergeistTabs`。
> 本章前半是选型推导；实际落地的样子见「实现」一节，两者不一致时以代码为准。

## 本章覆盖什么

- macOS 与 GTK 两套 tab 实现的现状核实：一个 tab 各自是什么东西、合并靠哪个 API。
- 「把散落的多个终端合并进一个 tab 组」这件事该不该由 Poltergeist（能力层）自动做。
- 给 tab 打「上班中 / 下班休息」标记的四个候选方案与推荐。
- 标记状态从核心传到 apprt 再到两端 UI 的完整链路设计。
- 标记的状态集合取几个值，以及为什么现在就定齐。
- 是否按监督组分组显示。

## 本章不覆盖什么

- 静止怎么测、静止阈值取多少 —— 见 [sensing.md](sensing.md)。
- 上班 / 下班由谁判定、「按住」是什么、确认策略 —— 见 [supervisor.md](supervisor.md)。
- 总管通过什么工具改这个标记、skill 体系怎么维护 —— 见 [mcp.md](mcp.md)。
- 群聊与私信界面的承载方式选型 —— 见 [chatui.md](chatui.md)。
- 各章分工总表与整体架构 —— 见 [README.md](README.md)。

## 一句话概括

Poltergeist 不发明新的 tab 机制。它需要的只是「把一个 per-surface 的枚举状态送到 tab 上并画出来」，而 Ghostty 里已经有 `readonly`（`src/apprt/action.zig:349-350`）和 `progress_report`（`src/apprt/action.zig:327`）两条把核心状态送到两端各自渲染的完整范本；本章的工作是选一条复用，并说清为什么不走「改标题」这条看起来更便宜的路。

## 设计目标与约束

本章主要对应 R10（多终端可合并到 tab 菜单显示，并给 tab 打状态标记）。同时受三条约束：

- **R5** —— 窗口是用户自己逐个打开、按屏幕布局摆好的，窗口位置属于用户的工作记忆，Poltergeist 不得擅自重排。
- **R4** —— 全系统只有「停掉监控」一个停止动作，因此 tab 标记只表达状态，不承担任何开关职责，点它不等于开关监督。
- **R8** —— 标记只表达工作状态，不表达任务内容；tab 上不出现任务名、进度百分比这类任务信息。注意 Ghostty 现有的 `progress_report`（`src/apprt/action.zig:326-327`）恰恰是「把任务进度送上界面」的通道，本设计明确不复用它的语义，只借它的实现形状。

## macOS 侧现状：一个 tab 就是一个窗口

### tab 组的构造

macOS 上每个 tab 实际是一个独立 `NSWindow`，靠 AppKit 的 tab 组机制聚在一起。`TerminalWindow.awakeFromNib` 先设 `tabbingMode = .preferred`，再在下一个 runloop 改回 `.automatic`（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:97-103`），注释写明不这样做窗口恢复时 tab 会还原成一个个独立窗口。

把窗口挂进既有 tab 组走 `addTabbedWindowSafely(_:ordered:)`；新建 tab 时先检查 `window.tabbingMode != .disallowed`，再按 `window-new-tab-position` 决定挂在当前窗口之后还是组末尾（`macos/Sources/Features/Terminal/TerminalController.swift:455-471`）。枚举全部终端窗口用 `TerminalController.all`，它 `compactMap` 遍历 `NSApplication.shared.windows`（`macos/Sources/Features/Terminal/TerminalController.swift:211-216`），这是按监督组筛选的现成数据源。

### 合并入口已经存在

这里要纠正一个容易犯的误判：**「合并所有窗口成 tab」在 macOS 上不是缺失能力，而是已经存在并且被 Ghostty 显式处理过的能力。**

- `TerminalWindow` 覆盖了 `mergeAllWindows(_:)`，在 `super` 之后延迟 0.1 秒调 `terminalController?.relabelTabs()`，注释指向 issue #1902（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:244-252`）。
- `TitlebarTabsVenturaTerminalWindow` 独立做了同样的覆盖与同样的延迟修复（`macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:130-138`），说明这条路径在多个窗口样式类里都要各修一遍。
- 菜单项本身由 AppKit 提供、不在 Ghostty 自己的 xib 里：UI 测试直接点系统菜单 `app.menuItems["mergeAllWindows:"]` 并断言合并后是 3 个 tab（`macos/GhosttyUITests/GhosttyTitlebarTabsUITests.swift:95-108`）。

结论：`mergeAllWindows` 对 Poltergeist 是零成本的既有能力，但它的语义是「全部窗口」，没法只合并某个总管监督的那一组。要按监督组合并，必须自己挑窗口再逐个 `addTabbedWindowSafely`，并自行复制那段 `relabelTabs()` 收尾，否则快捷键标签会错乱。

### 已有的 per-tab 视觉标记

`tab.accessoryView` 已经是一个 `NSStackView`，按顺序装着 tab 颜色圆点、键盘快捷键标签、重置缩放按钮（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:163-171`）。这是本章推荐方案在 macOS 侧的落点 —— 往这个栈里加第四个 arranged subview 即可，不需要发明新的挂载点，也不必去抢 tab 颜色那块位置。

颜色圆点是 `NSHostingView<TabColorIndicatorView>`（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:28-32`），`tabColor` 的 didSet 换 rootView 并 `invalidateRestorableState()`（`:63-69`），色值枚举 `TerminalTabColor` 是 `Int` 原始值的 `CaseIterable, Codable`（`macos/Sources/Features/Terminal/TerminalTabColor.swift:4-14`），`none` 时指示器画一个 `.hidden()` 的透明圆（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:688-698`）。这一整套是「往 macOS tab 上挂自定义视觉标记」的完整范本。

## GTK 侧现状：一个 tab 是 libadwaita 的一页

### 页与视图

窗口私有字段持有 `tab_bar: *adw.TabBar` 与 `tab_view: *adw.TabView`（`src/apprt/gtk/class/window.zig:281-282`），模板里 `Adw.TabBar` 在 `src/apprt/gtk/ui/1.5/window.blp:88`，`Adw.TabView` 及其 `page-attached` / `page-detached` 等信号在 `:161-171`。

新页在 `newTabPage` 里插入并选中（`src/apprt/gtk/class/window.zig:504-505`），随后把 `Tab` 对象的 `title` / `tooltip` 用 `bindProperty(.sync_create)` 绑到 `adw.TabPage` 的同名属性（`:508-519`）。也就是说 tab 上显示什么，完全由 `Tab` 的 `title` 属性决定。

### 页迁移已有先例

`moveTabToNewWindow` 用 `tab_view.transferPage(page, window.private().tab_view, 0)` 把页搬到新建窗口的 TabView（`src/apprt/gtk/class/window.zig:641-662`）。这条 API 的目标参数是任意一个 `adw.TabView`，把目标换成一个**已存在**窗口的 tab_view，在 API 形状上就是「合并」。

注意区分：同窗口内挪位置走的是 `tab_view.reorderPage`（`src/apprt/gtk/class/window.zig:638`），跨窗口迁移走 `transferPage`，两套 API 不要混为一谈。仓库中只出现过「搬到新窗口」这一个方向，合并方向没有先例（见未决问题）。

### 已有的 per-tab 标记：needs-attention

响铃时只对非选中页调 `page.setNeedsAttention(@intFromBool(true))`（`src/apprt/gtk/class/tab.zig:445-460`，注释里作者本人还标注不喜欢这段逻辑放在 `Tab` 里）。而页被选中时会**无条件**清除：`page.setNeedsAttention(@intFromBool(false))`（`src/apprt/gtk/class/window.zig:1690-1692`）。

结论：它是一个布尔（表达不了三态以上）、语义已被响铃占用、且用户点一下 tab 就被清掉 —— 三条里任何一条都足以否掉它承载「下班休息」。

## 标题由谁决定：两端的优先级链

这一节是「用标题表达状态」这类方案的成本论证，两端的结论一致。

### macOS

`titleOverride` 定义在 `macos/Sources/Features/Terminal/BaseTerminalController.swift:103-107`，注释直接写明它是 `prompt_tab_title` 设的覆盖标题，didSet 触发 `applyTitleToWindow()`；`applyTitleToWindow` 里 override 优先于终端算出的标题（`:916-927`）。

关键在于 **Ghostty 自己表达瞬时状态用的不是 override，而是「合成期前缀」**：`computeTitle` 在响铃且 `bell-features` 含 `title` 时拼 `"🔔 "`（`:902-909`），而且 `applyTitleToWindow` 对 override 也照样过一遍 `computeTitle`（`:919-924`），所以前缀作用在 override 之外、不占 override 通道。

override 通道被谁占着：`set_tab_title` apprt action 直接写 `controller.titleOverride`（`macos/Sources/Ghostty/Ghostty.App.swift:1671-1680`）、内联重命名提交也写同一字段（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:821-828`）、窗口状态恢复还要写回它（`macos/Sources/Features/Terminal/TerminalRestorable.swift:172`）。另外窗口标题的 didSet 会把标题同步进 `tab.attributedTitle`（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:394-406`），所以改窗口标题即改 tab 标题，两者不是独立通道。

### GTK

优先级链写死在 `closureComputedTitle`：`tab_override → surface_override → terminal → config.title → "Ghostty"`，之后按 bell 拼 `"🔔 "`、按 zoomed 拼 `"🔍 "`（`src/apprt/gtk/class/tab.zig:482-538`）。该闭包由 blueprint 声明式绑定，六个入参一目了然（`src/apprt/gtk/ui/1.5/tab.blp:11-18`）—— 新增一个状态入参就是在这里加一个绑定。

`title_override` 同样是用户命名专用车道：`setTitleOverride`（`src/apprt/gtk/class/tab.zig:258-264`）被用户重命名对话框（`:265-272`）和 `set_tab_title` action（`src/apprt/gtk/class/application.zig:3087-3106`）共用。

**两端的结论一样：override 是「用户命名」专用车道，Poltergeist 一旦占用就会抹掉用户自己起的名字；而两端又都已经有一条不占车道的「合成期前缀」通道。** 这个区分是后面候选 1 与候选 2 的分水岭。

## 合并：Poltergeist 不自动做

本设计选择**不自动合并**，只提供一个显式动作（命令面板项 / MCP 工具），由用户或总管显式触发。三条理由：

1. R5 场景里窗口是用户自己按屏幕布局摆开的，自动搬家会破坏用户的空间记忆。
2. macOS 上合并即改变窗口的 `tabGroup` 归属，Ghostty 已经为此打过补丁 —— `mergeAllWindows` 覆盖里要延迟 0.1 秒重贴标签（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:244-252`），非原生全屏退出时还要按保存的 `tabGroupIndex` 把窗口重新插回 tab 组（`macos/Sources/Helpers/Fullscreen.swift:290-307`）。这类时序脆弱的操作不该由后台逻辑自发触发。
3. R4 规定只有「停掉监控」一个停止动作。一个会自动改用户窗口布局的功能必然需要一个「别自动合并」的开关，等于在「停掉监控」之外凭空多一个停止入口，与 R4 冲突。

分平台落地：macOS 按监督组挑出窗口后逐个 `addTabbedWindowSafely`，并复制 `relabelTabs()` 收尾；GTK 用 `transferPage` 指向目标窗口的 tab_view。

**推翻条件**：若实际使用中被监督终端常态超过屏幕能同时容纳的窗口数，手工合并的负担会压过布局自主权，届时应改成「首次超过 N 个时提示一次、用户点确认才合并」，而不是无声自动合并。

## 状态标记：四个候选

| 候选 | 做法                                    | 判断           |
| ---- | --------------------------------------- | -------------- |
| 1    | 写 tab 标题 override（`set_tab_title`） | 淘汰           |
| 2    | 走两端已有的「合成期前缀」通道          | 保留为降级路径 |
| 3    | 借用 GTK 的 `needs-attention`           | 淘汰           |
| 4    | 新增 apprt action，两端各自渲染         | 推荐           |

**候选 1 淘汰**，因为它抢用户命名车道 —— 两端的 override 字段都已被用户重命名与 `set_tab_title` 占用（`macos/Sources/Ghostty/Ghostty.App.swift:1671-1680`、`src/apprt/gtk/class/application.zig:3087-3106`）。Poltergeist 每刷新一次状态就抹掉一次用户起的名字，而用户一旦自己改名，状态标记又会消失。这是功能缺陷，不是审美问题。

**候选 2 保留为降级路径。** 它不抢车道，是 Ghostty 表达瞬时状态的既有做法（GTK 的 `closureComputedTitle` 拼 `"🔔 "` / `"🔍 "` 前缀在 `src/apprt/gtk/class/tab.zig:526-534`，macOS 的 `computeTitle` 拼 `"🔔 "` 在 `macos/Sources/Features/Terminal/BaseTerminalController.swift:902-909`）。但要诚实写明它**不是零成本**：GTK 侧要改 `closureComputedTitle` 的签名（`src/apprt/gtk/class/tab.zig:482-490`）、`src/apprt/gtk/ui/1.5/tab.blp:11-18` 的绑定、并给 `Tab` 加属性；macOS 侧要改 `computeTitle` 与它的触发源。它省下的只是 `include/ghostty.h` 同步、`CValue` 与两端 action 分发那一层。

**候选 3 淘汰**，三条独立死因已在 GTK 现状一节列出：布尔（`src/apprt/gtk/class/tab.zig:459`）/ 被响铃占用（`:445-460`）/ 选中即清（`src/apprt/gtk/class/window.zig:1690-1692`）。

**候选 4 推荐。** 范本齐全（`readonly` 那一支在 `src/apprt/action.zig:349-350`），ABI 风险可控，展开见下一节。macOS 侧仿 `tabColorIndicator`（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:28-32`）加指示器不是独立候选，而是候选 4 在 macOS 侧的渲染载体。

## 推荐方案的完整链路

照 `readonly` 的形状描述，逐跳给出：

1. 核心侧加一个 per-surface 字段。范本是 `readonly: bool = false`（`src/Surface.zig:164-168`），本设计取一个小枚举而非布尔。
2. 状态变更时立刻发 apprt action。范本是 `.toggle_readonly` 分支翻转字段后 `performAction(.readonly, on/off)`（`src/Surface.zig:5426-5434`）。
3. 在 `Action` 里加一支，载荷是 `enum(c_int)`。范本是 `readonly: Readonly`（`src/apprt/action.zig:349-350`）与 `pub const Readonly = enum(c_int) { off, on }`（`:667-674`）。
4. 必须同步 `include/ghostty.h`。`Action.Key` 有 `checkGhosttyHEnum(Key, "GHOSTTY_ACTION_")` 测试（`src/apprt/action.zig:432-434`），载荷枚举各自也有一个（如 `:671-673`）；对照现有条目是 `include/ghostty.h:972` 的 `GHOSTTY_ACTION_READONLY`、`:666-668` 的 `ghostty_action_readonly_e`、`:1016` 的联合体成员。
5. `CValue` 是按 `Key` 枚举 comptime 生成的 extern union（`src/apprt/action.zig:437-459`），并带 `@sizeOf(CValue) == 24` 的 ABI 断言（`:467-476`）。**这就是本设计把载荷定成小枚举而不是结构体的理由** —— `enum(c_int)` 不会撑破断言，结构体可能会。
6. macOS 落点二选一：照 `setReadonly` 发 NotificationCenter 通知（`macos/Sources/Ghostty/Ghostty.App.swift:1086-1109`），或照 `progressReport` 直接写 `surfaceView` 属性（`:2055-2062`）。渲染挂到 `tab.accessoryView` 那个 NSStackView（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:163-171`）；`readonly` 现有的徽章画在 SurfaceView 叠层里（`macos/Sources/Ghostty/Surface View/SurfaceView.swift:86-90`），本设计要的是 tab 上而非 surface 上。
7. GTK 落点：做成 `Surface` 的 gobject 属性，getter 直读核心字段、setter 只发 notify（`src/apprt/gtk/class/surface.zig:1211-1223`，属性定义在 `:426-443`），UI 由 blp 声明式绑定（范本 `src/apprt/gtk/ui/1.2/surface.blp:83-86`），再由 `Tab` 汇总到页上。
8. 是否自动褪去：`progress_report` 在 macOS 侧有 15 秒自动清除定时器（`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:22-37`），可作为参照。本设计倾向「下班」标记不自动褪去（它是判定结果，不是瞬时事件），静止类标记若上界面则应自动褪去。

下图把上面八跳画成一张图，每一格右侧标的是它的现成范本出处。实际落地比这张图短得多 —— 复用了既有的 `set_tab_title`，两端一行未改，见「实现」一节：

```text
core Surface 字段                      范本 src/Surface.zig:164-168 (readonly)
        │  状态变更
        ▼
rt_app.performAction(.<新 action>)      范本 src/Surface.zig:5426-5434
        │
        ▼
apprt.Action 一支 + enum(c_int) 载荷    范本 src/apprt/action.zig:349-350, 667-674
        │  （必须同步 include/ghostty.h，否则 :432-434 的测试失败）
        ├──────────────────────────────┐
        ▼                              ▼
macOS handler                      GTK handler
Ghostty.App.swift:1086-1109        surface.zig:1211-1223
（NotificationCenter 或直写属性）   （gobject 属性 + notify）
        │                              │
        ▼                              ▼
tab.accessoryView 的 NSStackView   Tab 汇总 → adw.TabPage
TerminalWindow.swift:163-171       blp 声明式绑定，范本 surface.blp:83-86
```

两端在这条链路上的形状差异要写清：macOS 侧是命令式的 —— handler 收到 action 后自己找到 `surfaceView`、再找到 window controller，往 `tab.accessoryView` 里塞视图；GTK 侧是声明式的 —— handler 只负责 `notifyByPspec`，真正的显示由 blueprint 里的 `bind` 表达式驱动（`src/apprt/gtk/ui/1.2/surface.blp:84` 的 `reveal-child: bind template.readonly` 就是这个形状）。因此同一份设计在两端的代码量与改动位置并不对称，GTK 侧的改动集中在 blp 与属性定义，macOS 侧集中在 handler 与视图组装。

## 实现

### 复用既有通道，两端都不用改

落地用的是仓库里已有的 `set_tab_title` action（`src/apprt/action.zig:213`），macOS 与 GTK 两侧**一行都没改** —— 两端本来就实现了这个 action。这是本章选型里最省的一条路，也是它被选中的原因。

### 组合，不是替换

`set_tab_title` 是**覆盖**：写进去什么，tab 就显示什么。所以不能写一个纯状态串进去 —— 那会把程序自己设的标题扔掉，而那才是人真正在看的内容。

实现是**组合**：`标记前缀 + 程序自己的标题`，标题从 `rt_surface.getTitle()` 取。没有标记时写回不带前缀的标题。

### 七个标记

`Bus.TabMark`（`src/poltergeist/Bus.zig`）的七个值，逐个对上：

| 标记   | 含义                                       |
| ------ | ------------------------------------------ |
| （无） | 不在监督范围内 —— tab 只显示程序自己的标题 |
| ●      | 上班中                                     |
| ○      | 静止（屏幕停了超过阈值）                   |
| ◉      | 被用户按住，且在动                         |
| ◎      | 被用户按住，且静止                         |
| 💤     | 下班休息                                   |
| ⚑      | 总管                                       |

**下班优先于静止。**一个已下班的终端当然是静止的，但「下班」是更有用的说法：它安静是因为被叫停了，不是因为卡住了。

**按住的组合只有两种，不是三种。** 「被按住」和「已下班」这个组合到不了：
`Bus.clockOff` 遇到 `held` 就返回 `TerminalHeld`，所以一个被按住的终端只可能
在动或静止。`TabMark` 里因此没有第三个环——**没有这个标记，是因为没有这个状态**，
不是因为漏画了。

护盾（`shielded`）不在这七个值里，它是拼在最前面的第二个前缀，理由见下面
「护盾：第二个前缀」一节。

**为什么按住要在 tab 上常驻一个环，而不是切换时提示一句。** 旧实现里切换工作
模式会往终端注入一句提示，然后那句话就随上下文被挤走了。一个只在设定那一刻存在
的状态，等于没有状态；而挂机过夜正是上下文最容易被冲掉的场景。环解决的正是这
个：只要按住还在，它就一直在视野里。同样的理由，菜单项**没有**做成勾选态——
勾只在拉开菜单那一刻看得见，解决不了「持续可见」这个问题（旁边的
`Supervise This Terminal` 也没有勾，不加反而一致）。

### 护盾：第二个前缀，不是第八个 `TabMark`

护盾（`Bus.Entry.shielded`）是用户的逃生开关——「任何终端里的任何 agent 都不许
读这个终端、不许往里打字」。它和按住一样，只有用户能设、程序据以拒绝，因此也
一样需要**常驻可见**：设过一次而看不见，等于没设。

标记怎么和按住共存，是这一节要回答的问题。答案是**两个前缀拼起来**，
`🔒 ◉ 标题`，而不是把 `TabMark` 从七个值翻成十四个。

理由是这两件事的形状根本不同：

- **环能折进 `TabMark`，是因为按住并不独立于它所修饰的那个值。** 按住只对被监督
  的终端有意义；`clockOff` 拒绝被按住的终端，所以「按住 + 下班」到不了；而且环
  就是实心圆改了中心，同一个字形家族，说的是「还在做那两件事之一，只是被钉住
  了」。七个值里它只碰得到两个，所以加两个值就够。
- **护盾和七个值全部正交，`none` 也包括在内。** 而 `none` 恰恰是最要紧的那一格：
  用户最想护住的是自己那个 shell，没人监督它，它身上一个标记都没有。折进枚举
  就是十四个值、没有一个不可达，并且 `none` 不再表示「没什么可说的」——现有
  代码和现有文档里到处都靠这条。还要为一个只有两个成员的字形家族再造七个字形。

所以拼接说的才是真话：**一个标记讲这个终端在干什么，一个讲谁可以碰它，分开读，
因为它们本来就是两回事。** 护盾在前，因为它是关于整个终端的事实，和它此刻在干
什么无关，而一列 tab 是顺着左边缘扫下来的。

| 标记       | 含义                   |
| ---------- | ---------------------- |
| `🔒`       | 被用户护住，谁都碰不到 |
| `🔒 ●`     | 护住 + 上班中          |
| `🔒 ◉`     | 护住 + 被按住 + 在动   |
| `🔒 ⚑`     | 护住 + 总管            |

判定在 `Bus.shield_prefix` 与 `Bus.isShielded`，拼接在
`Surface.updatePoltergeistTabMark`。菜单项同样没有做成勾选态，理由与按住那节
完全一致。

### 分屏：标记退化，护盾不退化

**这是一个已知的失效场景，写在这里是因为它不该被当成 bug 反复重新发现。**

一个 tab 只有一个标题，而四个分屏 surface 各有自己的 `Surface.id`、各自调用
`updatePoltergeistTabMark`、各自写这一个标题——最后写的那个赢。所以分屏里给某
一格设了护盾，tab 上可能挂着的是隔壁那格的标记。

要紧的是它**丢的是什么**：护盾本身是 per-surface 判定的（`Bus.isShielded(id)`
按 surface 问，工具面按 surface 拒），所以丢掉的是**确认**，不是**保护**。设了
护盾的终端，无论 tab 上写着什么，都仍然碰不到。

为什么不修：真正的修法是做一个 per-surface 的徽章，照 `readonly` 那一套
（`src/apprt/gtk/ui/1.2/surface.blp:84` 的 `reveal-child: bind template.readonly`
和 macOS 侧 `SurfaceView` 的徽章）。那要穿 `include/ghostty.h` +
`src/apprt/embedded.zig` + 两端渲染，正是 gaps.md 给菜单勾选态算过的那三层成本。
在那之前，per-surface 的准确答案在 `terminal_list` 的 `shielded` 字段里。

**按住从落地那天起就是同样的退化**，护盾没有让情况变坏，只是第一次把它写下来。

### 不重复写

每个 surface 记住自己上次写过的标记，没变就什么都不做。这样 `refreshPoltergeistTabs` 可以在任何事件后被调用而不会不停重写 tab 标题。

## 状态集合

本设计建议核心枚举取五值：`none`（未纳入监督）/ `on_duty` / `quiescent` / `pending_confirm` / `off_duty`。除 `none` 外，其余四值与 [supervisor.md](supervisor.md) 的四态状态机逐个对应，命名不另起一套。五个值的语义分别是：

- **`none`** — 该终端不在任何监督关系里。这是默认值，必须存在，否则无法表达「用户新开的普通终端」。
- **`on_duty`（上班中）** — 已纳入监督关系、正在工作。它是被监督终端的默认状态。
- **`quiescent`（静止待判）** — 屏幕在阈值时长内没有变化、已通知总管。它是传感器的直接输出加一次去重簿记，不含任何语义判断。
- **`pending_confirm`（等确认）** — 总管认为需要人确认，正按确认策略处理中。这个值必须存在：[supervisor.md](supervisor.md) 规定确认请求要同时在群聊与 tab 标记上留痕，因为 macOS 侧的桌面通知在聚焦时 3 秒即被移除，不是合格的确认渠道。
- **`off_duty`（下班休息）** — 总管判定该终端无需继续工作后打的标记。被用户按住的终端进不了这个值：`clockOff` 在程序层面拒绝，语义见 [supervisor.md](supervisor.md)。

**这份五值提案与落地的 `TabMark` 已经不是一回事，以代码为准。** 实际的 `TabMark`
是七值：提案里的 `quiescent` 落地叫 `quiet`，`pending_confirm` 至今未实现，另外
多出 `supervisor`、`held_on_duty`、`held_quiet` 三个。这里保留提案原文是因为下面
那段「为什么一次定齐比后续追加便宜」的论证仍然成立——而它恰好被后来的事实印证了
一半：加 `held` 那两个值时，确实要同步 `include/ghostty.h` 与两端 switch。

理由是枚举扩展的真实成本落在 `include/ghostty.h` 同步与两端 switch 上（出处见上节第 4 跳），一次定齐比后续追加便宜；而渲染侧留白是零成本的 —— 首版可以只画 `off_duty` 与 `pending_confirm`，`none` 与 `on_duty` 不画，照 `TerminalTabColor.none` 隐藏指示器的做法（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:688-698`）。

`quiescent` 是否真的上 tab，由 [sensing.md](sensing.md) 的输出决定，本章只留位不展开。反面意见记在取舍记录里。

## 标记不承担开关职责

R4 规定全系统只有「停掉监控」一个停止动作，因此本设计明确：**tab 上的状态标记是只读的显示，点它不改变任何状态。**

这一条要专门写出来，是因为 Ghostty 里恰好有一个反例可以照抄：`readonly` 的徽章是可点的，点它会 `surfaceView.toggleReadonly(nil)`（`macos/Sources/Ghostty/Surface View/SurfaceView.swift:86-90`），GTK 侧的 `readonly` 覆盖层则显式设了 `can-target: false`（`src/apprt/gtk/ui/1.2/surface.blp:87-90`）。本设计取 GTK 那一侧的形状 —— 不可点、不捕获事件 —— 在两端都如此。

理由：一个可点的「下班」标记等价于一个 per-terminal 的监督开关，会让「停掉监控」不再是唯一的停止路径。用户要停，走停掉监控；总管要改标记，走 [mcp.md](mcp.md) 的工具面。

## 两端差异小结

| 维度              | macOS                                                     | GTK                                                  |
| ----------------- | --------------------------------------------------------- | ---------------------------------------------------- |
| 一个 tab 是什么   | 独立 `NSWindow`（`TerminalWindow.swift:97-103`）          | `adw.TabPage`（`window.zig:504-505`）                |
| 合并 API          | `addTabbedWindowSafely`（`TerminalController.swift:462`） | `transferPage`（`window.zig:655-659`）               |
| 现成整组合并      | 有，`mergeAllWindows`（`TerminalWindow.swift:244`）       | 无先例                                               |
| 现成 per-tab 标记 | `tab.accessoryView` 栈（`TerminalWindow.swift:163-171`）  | `needs-attention`，布尔且被响铃占用（`tab.zig:459`） |
| 状态落地风格      | 命令式 handler                                            | 声明式 blp 绑定                                      |

## 分组：不做物理分组，做逻辑列表

本设计选择**不按监督组物理重排**窗口或页。理由与上一节同源：macOS 上「组」就是 `tabGroup`，GTK 上「组」就是一个窗口的 TabView，两者的物理分组都等于搬家。

替代做法是逻辑筛选。macOS 命令面板里已经有一个跨窗口终端列表：它遍历 `TerminalController.all`，按 `tabColor` 给条目上色、按 `titleOverride` 取显示名（`macos/Sources/Features/Command Palette/TerminalCommandPalette.swift:142-179`）。把「属于哪个总管」做成这个列表的筛选或分节维度即可，纯读、随时可改、不动用户布局。GTK 侧的对应物是 `src/apprt/gtk/class/command_palette.zig`。界面承载方式的最终选型归 [chatui.md](chatui.md)。

## 分阶段落地

以下是本设计自己的分阶段计划，不是对上游的承诺。

- **阶段一**走候选 2（合成期前缀），只验证「状态能被人看见」。代价要写明：前缀会进入窗口标题，因为 macOS 上窗口标题会同步进 `tab.attributedTitle`（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:394-406`），进而影响命令面板的显示名（`macos/Sources/Features/Command Palette/TerminalCommandPalette.swift:150-158`）。
- **阶段二**换成候选 4，把前缀降级为 fallback 渲染（例如在没有 accessory view 的窗口样式下仍能看见）。

## 取舍记录

| 方案                                     | 成本                                                                               | 为什么没选 / 为什么选                                                                                                                                             |
| ---------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 自动把被监督终端合并成 tab               | 零用户操作                                                                         | 没选。违反 R5（窗口布局属于用户）、需要一个「别自动合并」的开关而违反 R4，且 macOS 合并路径时序脆弱（`TerminalWindow.swift:244-252`、`Fullscreen.swift:290-307`） |
| 显式合并动作（命令面板 / MCP 工具）      | 多一次用户操作                                                                     | 选。用户保留布局自主权，触发时机可控                                                                                                                              |
| macOS 合并复用 `mergeAllWindows`         | 零成本，AppKit 出菜单项，已有回归测试（`GhosttyTitlebarTabsUITests.swift:95-108`） | 没选。语义是「全部窗口」，无法只合并某个总管的那一组                                                                                                              |
| macOS 合并自己拼 `addTabbedWindowSafely` | 要自行复制 `relabelTabs()` 收尾                                                    | 选。`TerminalController.swift:455-471` 已是成熟路径，可按监督组挑目标                                                                                             |
| GTK 合并用 `transferPage`                | 合并方向无先例，需实测                                                             | 选。`window.zig:641-662` 已有跨窗口迁移用例，目标参数是任意 TabView                                                                                               |
| 候选 1：写 title override                | 核心侧几乎零改动                                                                   | 没选。抢用户命名车道，两端皆然（`Ghostty.App.swift:1671-1680`、`application.zig:3087-3106`、`tab.zig:265-272`）                                                   |
| 候选 2：合成期标题前缀                   | GTK 改闭包签名 + blp + Tab 属性；macOS 改 `computeTitle`                           | 保留为阶段一与永久 fallback。不抢车道，是 Ghostty 表达瞬时状态的既有做法（`tab.zig:526-534`、`BaseTerminalController.swift:902-909`）                             |
| 候选 3：GTK `needs-attention`            | 零新 UI 代码                                                                       | 没选。布尔、被响铃占用（`tab.zig:459`）、选中即清（`window.zig:1692`）                                                                                            |
| 候选 4：新增 apprt action                | `include/ghostty.h` + `action.zig` 一支 + 两端各一个 handler 与渲染                | 选。`readonly` 与 `progress_report` 范本齐全，`enum(c_int)` 载荷不撑破 24 字节断言（`action.zig:467-476`）                                                        |
| 状态集合取 2 态 + `none`                 | 更贴 R10 原文                                                                      | 备选。若 sensing 决定静止只通知总管、不上界面，且确认请求只在群聊留痕，应回退到这个                                                                               |
| 状态集合取 5 态                          | 多三个 switch 分支                                                                 | 选。与 supervisor 的四态一一对应，`pending_confirm` 是其硬要求；枚举扩展成本在头文件同步上，一次定齐更便宜；渲染侧留白零成本                                      |
| 标记可点（照 macOS `readonly` 徽章）     | 零额外成本                                                                         | 没选。可点的「下班」标记等价于 per-terminal 监督开关，与 R4 冲突（`SurfaceView.swift:86-90` 是这个反例）                                                          |
| 标记不可点（照 GTK `readonly` 覆盖层）   | 需显式设不捕获事件                                                                 | 选。`surface.blp:87-90` 已有 `can-target: false` 的现成写法                                                                                                       |
| 按监督组物理分组                         | 等于搬家                                                                           | 没选。理由同「不自动合并」                                                                                                                                        |
| 按监督组逻辑筛选                         | 复用现有列表模式                                                                   | 选。纯读、不动布局（`TerminalCommandPalette.swift:142-179`）                                                                                                      |

## 未决问题

- （未核实：`adw.TabPage` 的 `indicator-icon` / `loading` 属性在 zig-gobject 绑定里可用，从而 GTK 可以给 tab 挂图标指示器。核实方式是在 Linux/GTK 环境跑 `zig build -Demit-macos-app=false`，再到 zig 全局缓存里 grep 生成的 adw 绑定是否有 `setIndicatorIcon` / `setLoading`。）仓库内对 `adw.TabPage` 只用到 `getChild`、`getSelected`、`setNeedsAttention`（`src/apprt/gtk/class/tab.zig:457-459`、`src/apprt/gtk/class/window.zig:1683`、`:1692`）。**在核实前，本设计不得断言 GTK 能挂图标指示器。**
- （未核实：`transferPage` 把页搬进一个已有页、已有选中页的 TabView 与搬进空 TabView 同样安全。核实方式是在 GTK 构建里加一个临时 action 触发跨已有窗口的 `transferPage`，观察 `page-detached` / `page-attached` 信号顺序，以及 `tabViewPageAttached`（`src/apprt/gtk/class/window.zig:1695`）里绑定的信号是否被重复挂上。）
- （未核实：`mergeAllWindows` 在 `tabbingMode` 为 `.disallowed` 或窗口处于原生全屏时的行为。核实方式是配置相关选项后手工点系统菜单项观察。）Ghostty 自己加 tab 时会先检查 `tabbingMode != .disallowed`（`macos/Sources/Features/Terminal/TerminalController.swift:455`），但 `mergeAllWindows` 是 AppKit 实现的，Ghostty 只覆盖了收尾。
- （未核实：tab 徽章需要什么样的可访问性处理。核实方式是 grep `accessibilityLabel` 在 `macos/Sources/Features/Terminal/` 下的用法。）现有的 `TabColorIndicatorView` 是纯装饰的 SwiftUI Circle，没有任何 accessibility 修饰（`macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:684-700`），也就是说现有先例本身没做 a11y。
- （未核实：GTK 侧是否存在与 macOS `relabelTabs()` 等价的、合并后需要手工修复的状态。核实方式是 grep `goto_tab` 在 `src/apprt/gtk/` 下的处理，看 tab bar 是否显示序号。）
- （未核实：新增 apprt action 后 `include/ghostty/` 下的 libghostty-vt 头文件是否也要同步。核实方式是跑 `zig build test -Dtest-filter="ghostty.h"` 看还有哪些 `checkGhosttyHEnum` 命中。）已核实的是 `include/ghostty.h` 与 `src/apprt/action.zig:432-434` 的强制测试。
- 状态标记要不要进 macOS 窗口状态恢复：`tabColor` 与 `titleOverride` 都进了 `TerminalRestorableState`（`macos/Sources/Features/Terminal/TerminalRestorable.swift:73-78`），且 `version: Int { 7 }` / `minimumVersion: Int { 5 }`（`:61-62`）说明加字段要升版本号。但「上班 / 下班」是运行时状态，重启后监督关系是否还成立取决于 [supervisor.md](supervisor.md) 的设计，本章不单方面决定。

## 延伸阅读

- [README.md](README.md) —— 总览、原则与各章分工。
- [sensing.md](sensing.md) —— 静止怎么测，`quiescent` 是否上 tab 的输入方。
- [supervisor.md](supervisor.md) —— 上班 / 下班由谁判定，「按住」。
- [mcp.md](mcp.md) —— 总管通过什么工具改标记、触发合并。
- [chatui.md](chatui.md) —— 逻辑分组列表的界面承载方式。
- [\_spec.md](_spec.md) —— 本批文档的写作规范与术语表。
- [architecture.md](../architecture.md) —— Ghostty 整体架构。
- [platform-and-config.md](../platform-and-config.md) —— apprt 与平台差异。
