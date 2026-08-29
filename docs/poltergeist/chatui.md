# 群聊与私信界面

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**已实现**（`src/cli/chat.zig`，命令 `polter +chat`），并在真机上跑通：三栏布局、成员清单、本地时刻、以「你」的身份发言、落盘。macOS 原生窗口做出来过，用过之后被否掉了，代码已删除（见「决策变更」）。
> 本章前半是选型推导，保留下来是因为它解释了**为什么**是这个形状 —— 而且这一次实物证明了它推导对了。

## 本章覆盖什么

- 群聊与私信界面的需求边界：要列什么、要能做什么、给谁看。
- 六个承载方式候选的逐项成本核算与推荐结论。
- 群聊频道与私信线程在同一界面里的组织方式（会话列表 / 未读 / 搜索）。
- 聊天记录存在哪、留多久、界面怎么订阅增量。
- 用户能否在界面里发言的结论与理由，以及随之划定的三条边界。
- 分期计划：一期做哪一个、什么条件下推翻。

## 本章不覆盖什么

- MCP 工具清单、sidecar 进程形态、身份识别、skill 体系、不管任务的边界 —— 见 [mcp.md](mcp.md)。
- 屏幕静止怎么测、采样成本、静止阈值怎么定 —— 见 [sensing.md](sensing.md)。
- 监督关系、上班 / 下班、按住、确认策略、通知时间段、停掉监控 —— 见 [supervisor.md](supervisor.md)。
- tab 合并、tab 状态标记、「有 N 条未读」怎么打到 tab 上 —— 见 [tabs.md](tabs.md)。
- 构建与运行命令 —— 见 [preview-manual.md](../preview-manual.md)。

## 一句话概括

群聊界面做成**一个跑在 Polter 表面（surface）里的 TUI**（`polter +chat`）：仓库里已经链着 TUI 框架，已有结构同构的完整先例可以照抄，代价远低于在 macOS 与 GTK 两边各写一份原生 UI。这个界面是给人看的观察窗，AI 之间的通信不经过它。

绕了一圈才回到这里 —— 中间做过一版 macOS 原生窗口。绕这一圈的账记在「决策变更」一节，因为它换来的信息比省下的时间值钱。

## 设计目标与约束

主对应 **R9**（要有界面能看到群聊以及 AI 之间的私信）。四条附带约束决定了取舍方向：

- **R5** —— 用户本来就在终端里并行开着好几摊事，晚上还要挂机继续。所以「再开一个终端页签」是这个界面最自然的落点，不需要用户切换到另一个 app。
- **R4（不做开关式设计）** —— 界面里因此不放任何启停控件，「停掉监控」是本设计唯一的停止动作，归 [supervisor.md](supervisor.md)。
- **R8** —— Poltergeist 不管理任务。界面里不显示任务列表、不提供任务编辑入口。
- **R3** —— 确认策略里的「通知用户」分支要求用户有一个能回话的地方，这直接决定了界面必须可输入。

## 需求边界：这个界面到底要做什么

先把需求钉死，否则候选无法比较。

1. **列出所有会话** —— 一个群聊频道，加上每对 AI 一条私信线程。
2. **看历史** —— 可上翻、可按会话过滤、可搜索。
3. **实时增量** —— 新消息到达要能推上来，不能只在打开时拍一张快照。
4. **用户能发言** —— 结论见下文专节。
5. **观察窗，不是控制台** —— 除发言外只读：不在这里按住终端、不在这里停掉监控、不在这里给任何终端敲命令。
6. **中文必须能显示、能输入** —— 用户是中文使用者。

需求 3 与需求 6 在成本核算里权重最高：前者决定「要不要长连接」，后者决定「字体栈与输入法栈由谁负责」。需求 6 是硬性淘汰条件——一个打不出中文的聊天界面等于没做。

## 候选一：终端内 TUI（推荐）

### 现状核实：仓库已经链着 TUI 框架

有一种说法是「仓库里没有现成的 TUI 框架，所以 TUI 要从零写」。这不准确，必须先纠正，否则整章成本对比全错。

- `src/cli/tui.zig` 全文只有 6 行，只导出一个平台开关 `can_pretty_print`（`src/cli/tui.zig:3-6`），被 `src/cli/list_themes.zig:181` 用来判断要不要进入 TUI 预览。它确实不是框架。
- 但真正的 TUI 框架 libvaxis 已经作为依赖 `vaxis` 声明（`build.zig.zon:25-30`），在 `src/build/SharedDeps.zig:512-520` 被 `addImport("vaxis", …)` 加进模块图并注入 `uucode`；`SharedDeps` 又在 `src/build/GhosttyExe.zig:34` 加到主 exe 上。**`ghostty` 主二进制里已经链着 vaxis**。
- 宽字符宽度表也已经为 libvaxis 单独配过：`src/build/uucode_config.zig:42` 有一张名为 `libvaxis_only` 的字段表，含 `east_asian_width`（`:43-46`）。

### 这个先例和聊天界面同构

`src/cli/list_themes.zig` 里的 `Preview`（`src/cli/list_themes.zig:240`）是一个完整的 vaxis TUI，它要的东西聊天界面几乎全要：

1. 事件循环与终端初始化 —— `vaxis.Loop(Event)`（`src/cli/list_themes.zig:306`）、`enterAltScreen`（`:311`）、`setMouseMode`（`:314`）、`pollEvent`（`:323`）。
2. 左列表 + 右详情布局 —— 左侧固定宽 32 的子窗口（`src/cli/list_themes.zig:618-623`），右侧 `drawPreview()`（`src/cli/list_themes.zig:892`）。聊天界面是「左会话列表 + 右消息流」，同一形状。
3. 底部带边框的文本输入框 —— 字段 `text_input: vaxis.widgets.TextInput`（`src/cli/list_themes.zig:259`），绘制在 `src/cli/list_themes.zig:824-837`。
4. 模式机 —— `normal / help / search / save` 四态（`src/cli/list_themes.zig:252-257`）。聊天需要的「正常 / 搜索 / 帮助」是它的子集。
5. 入口函数只有 10 行 —— `fn preview(...)`（`src/cli/list_themes.zig:1744-1754`）。

所以候选一的真实成本不是「引依赖 + 造框架」，而是「照 `list_themes.zig` 抄一份并换掉数据源」。

### 注册成本

新增一个 CLI action 的改动点，逐跳列出：

1. 新建 `src/cli/polter_chat.zig`（这条路最终没有走，该文件不存在）。help 文本写在 `run` 函数的文档注释里，不需另建文档文件（`src/cli/README.md:11-13`）。
2. 在 `src/cli/ghostty.zig` 的 `Action` 枚举加成员（枚举定义在 `src/cli/ghostty.zig:33`，末尾成员 `@"toggle-quick-terminal"` 在 `:87`）。
3. 在 `runMain` 的 switch 加一个分支（`src/cli/ghostty.zig:160-184`）。
4. 在 `options` 的 switch 加一个分支（`src/cli/ghostty.zig:195-219`）。

源文件名由枚举名 comptime 推导（`Action.file()`，`src/cli/ghostty.zig:188-200`），不用另外登记；shell 补全从 `@typeInfo(Action)` comptime 遍历生成（`src/extra/fish.zig:30`），零额外改动。合计 2 个文件 4 个改动点。

### 为什么它天然满足中文需求

CLI action 在 GUI 启动之前执行并直接 `std.process.exit`（`src/main_ghostty.zig:68-74`），所以 `+polter-chat` 就是一个普通的独立终端程序，跑在某个 Ghostty 表面里。字体栈、CJK 宽度、输入法全部由宿主表面负责——表面层已有 IME 预编辑通道 `preeditCallback`（`src/Surface.zig:2636`）。这是候选一相对候选三的决定性优势：中文支持是免费继承的，不用为聊天界面单独再实现一遍。

它还能自己发 OSC 0/2 改标题，经 `handleMessage` 的 `.set_title` 分支转成 apprt action（`src/Surface.zig:1053`），与 [tabs.md](tabs.md) 的标记机制天然衔接。

### 怎么把它开成一个页签

- macOS / embedded 侧新建表面时可指定 `command`（`src/apprt/embedded.zig:470`）与 `initial_input`（`:477`）；注释说明设了 `command` 会自动开启 `wait_after_command`（`src/apprt/embedded.zig:462-465`）。
- GTK 侧是 per-surface 的 `overrides.command`（`src/apprt/gtk/class/surface.zig:749`，落地在 `:762`）。
- `ghostty` 可执行文件所在目录被追加进子进程 PATH 并导出 `GHOSTTY_BIN_DIR`（`src/termio/Exec.zig:692-711`），所以表面里可以直接调 `ghostty +…`。
  （未核实：macOS 应用包内的表面中 `ghostty` 是否确实在 PATH 上，核实方式是在装好的 Ghostty 里执行 `which ghostty` 与 `echo $GHOSTTY_BIN_DIR`。）

### 代价

观感不原生：没有系统滚动条、没有右键菜单。富内容做不了：图片、可点卡片、富文本 diff 都不行。文本折行、CJK 折行、滚动窗口这些基本功要自己写。
（未核实：vaxis 在中文长段落下的折行与光标定位表现，核实方式是构建后跑 `ghostty +list-themes` 并观察含宽字符的行，或写一个最小 vaxis 样例喂中文长文本。）

## 候选二：macOS 与 GTK 各写一份原生 UI

### 现状核实：command palette 的全链路

以既有的 `toggle_command_palette` 为标尺，加一个 apprt action 起步就要动这些地方：

1. 核心 action 枚举成员 —— `src/apprt/action.zig:119`，C ABI 同步枚举 `src/apprt/action.zig:377`。
2. C 头文件必须同步 —— `include/ghostty.h:928`。
3. 核心侧分发 —— `src/Surface.zig:6007-6009`。
4. 键绑定动作枚举 —— `src/input/Binding.zig:877`。
5. 默认键位 —— `src/config/Config.zig:7199`。
6. 命令面板自身的命令表 —— `src/input/command.zig:772`。
7. GTK 落地 —— `src/apprt/gtk/class/application.zig:794`，加速键同步在 `:1213`。
8. macOS 落地 —— `macos/Sources/Ghostty/Ghostty.App.swift:571-572`。

八处改动跨 Zig / C / Swift 三种语言，其中头文件枚举与 `src/apprt/action.zig` 的顺序是 ABI 契约——这是 rebase 上游时冲突面最大的一类改动，而 Poltergeist 是 fork，要长期跟上游。

### UI 本体规模

- macOS：`macos/Sources/Features/Command Palette/CommandPalette.swift` 529 行，另有 `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift`。
- GTK：`src/apprt/gtk/class/command_palette.zig` 787 行 + `src/apprt/gtk/ui/1.5/command-palette.blp` 110 行，blueprint 还要登记进 `src/apprt/gtk/build/gresource.zig:54`（清单在 `:33-55`）。
- GTK 每个界面都是手写 GObject extern struct + `defineClass`（`src/apprt/gtk/class/command_palette.zig:23-32`），属性 / 信号 / 私有结构体全要手写。

约 1600 行平台 UI，且**每加一个界面元素改两处**。聊天界面比命令面板复杂，实际只会更多。

### 什么时候它才值得

只有当需求升级到富文本、图片、拖拽、系统级无障碍时。这同时就是候选一的推翻条件，写在下文「选型结论与分期」里。

## 候选三：imgui，复用 inspector 那条路

### 现状核实

- 核心一份 Zig：`src/inspector/Inspector.zig`，依赖 `dcimgui`（`build.zig.zon:75` 声明为本地 lazy 包）。
- macOS 侧嵌在 SwiftUI 里：`macos/Sources/Ghostty/Surface View/InspectorView.swift:29-38`。
- GTK 侧是独立窗口 + widget：`src/apprt/gtk/class/inspector_window.zig:19-29`，绘制在 `src/apprt/gtk/class/imgui_widget.zig`。

优点很实在：UI 逻辑只写一份 Zig，两个平台复用，比候选二便宜得多。

### 为什么不选它 —— 中文是硬伤

- imgui 上下文只 `AddFontFromMemoryTTF` 了 `font.embedded.regular`（`src/inspector/Inspector.zig:38-55`，调用在 `:47`），而它是 JetBrains Mono（`src/font/embedded.zig:16`），没有 CJK 字形来源。要显示中文得额外内嵌一份 CJK 字体并扩 glyph range，二进制体积与字体许可都要重新算。
- 输入法只做了一半，两平台不对等：GTK 侧持有 `gtk.IMMulticontext`（`src/apprt/gtk/class/imgui_widget.zig:58`）并在 `:188` 调 `filterKeypress`；macOS 侧 `setMarkedText` 只把字符串存进本地 `markedText` 就结束（`macos/Sources/Ghostty/Surface View/InspectorView.swift:355-366`），`firstRect(forCharacterRange:)` 返回零尺寸矩形（`:384-386`）。聊天界面是要一直打字的，这条不能将就。
- 该子系统没有单元测试（`src/inspector/AGENTS.md:12`），改动只能靠肉眼验证，维护成本被低估。

（未核实：imgui 路径下中文实际渲染为豆腐块、以及 macOS 侧 IME 候选窗定位错位，核实方式是构建后打开 inspector，用中文输入法在任一输入框打字并截图。上述结论是从字体加载与 `NSTextInputClient` 实现推出的，未实机验证。）

## 三个被排除的候选

### 候选四：轻量覆盖层 —— 只能做提示，不能做承载

- GTK 侧有三个：`resize-overlay` / `search-overlay` / `key-state-overlay`，blueprint 登记在 `src/apprt/gtk/build/gresource.zig:43-45`。
- macOS 侧在 `macos/Sources/Ghostty/Surface View/SurfaceView.swift` 的 ZStack 里叠了一排：进度条（`:75`）、readonly 徽章（`:86`）、按键状态（`:93`）、URL 悬停条（`:102`）、子进程退出条（`:107`）。

排除理由三条：没有可滚动的历史、没有文本输入、生命周期是自动出现自动消失。但它**保留为补充**——「有 N 条未读」用这一形态做是合适的，实现细节归 [tabs.md](tabs.md)。

### 候选五：渲染器级 CPU 覆盖层 —— 直接排除

`src/renderer/Overlay.zig:1-12` 的文档说明它用 z2d 在 CPU 绘制、再经 image 子系统合成到 GPU；`Feature` 只有 `highlight_hyperlinks` 与 `semantic_prompts` 两项（`src/renderer/Overlay.zig:70-72`）。这是一条纯绘制通道，没有任何输入入口，连需求 4 的门槛都够不着。

### 候选六：外置进程 / 网页 —— 成本被低估

- `macos/Sources` 下 grep `WKWebView` 与 `WebKit` 均 0 命中。塞一个网页界面等于给两个平台各引一个浏览器引擎。
- 传输层也要新造：仓库里没有 unix socket 服务端，唯一的 `AF_UNIX` 用法是 Linux 上单向的 systemd notify（`src/os/systemd.zig:86-95`）；现成 IPC 只有三个 action（`src/apprt/ipc.zig:176-179`），而 embedded（macOS）的 `performIpc` 三个分支全部 `return false`（`src/apprt/embedded.zig:349-360`）。

注意：传输层这笔钱候选一也要付，差别在于网页方案**额外**要付一个 UI 引擎的钱，换来的只有观感。

## 决策变更：从 macOS 原生 UI 回到终端内 TUI

### 经过

1. 本章原本推荐**候选一（终端内 TUI）**。
2. 设计评审时用户说「界面就先做 macOS」，据此改成**候选二的 macOS 半边**（SwiftUI Feature），并记录为用户决策。
3. 按此实现，做出了一个 SwiftUI 窗口：会话列表 + 消息流 + 输入框，取数走 C ABI 快照。
4. 用户实际用过之后否掉了它，理由见下。
5. 回到候选一。SwiftUI 窗口、C ABI、菜单项与快照 API 全部删除。

第 2 步的理解可能本来就偏了：「先做 macOS」说的是**平台优先级**，而候选一本身就是跨平台的 —— 先在 macOS 上验证一个 TUI，同样满足「先做 macOS」。这个歧义当时没有澄清。

### 实物暴露了什么

四条都来自实际使用，不是推导：

| 现象 | 根因 | 换成 TUI 是否自然解决 |
| --- | --- | --- |
| 谁发言看不出来，和 tab 对不上 | 作者显示的是 `0x%016llx` 原始 id | **不自动解决**，得让快照带上终端标题 —— 但这是数据层的事，与渲染无关 |
| 几点发言看不出来 | 日志用单调时钟，没有墙钟基准 | **不自动解决**，同上，数据层 |
| 内容「就是纯 text」，不如终端 | SwiftUI 默认比例字体，代码对不齐，没有 ANSI | **自动解决**：终端天然等宽、天然认 ANSI、天然有滚动与选择 |
| 看不到群里有几个人 | 快照里没有成员 | **不自动解决**，数据层 |

值得记住的是这张表的第二列：四条里只有一条是渲染方式造成的，另外三条**换任何界面都要改数据层**。所以这次重做不是把前面的活白干，而是把「界面形态」和「数据不够」两个混在一起的问题拆开了。

### 这一圈的账

亏的：一版 SwiftUI 窗口（约 200 行 Swift）、一套 C ABI（约 90 行 Zig + 头文件声明）、菜单与 action 接线，全部删除。

赚的：

- **验证了候选一的推导是对的。**「中文显示与输入由宿主表面负责」这条当初是纸上推理，现在有了反例支撑 —— 原生 UI 里字体、对齐、输入法都要自己操心，而终端里这些本来就是解决好的。
- **拆出了三条数据层欠债**，它们本来会一直藏在「界面不好看」后面。
- **确认了 C ABI 这条路不必要**。TUI 走已有的 unix socket + rpc，不需要在 `include/ghostty.h` 里加任何东西，与上游的分叉面反而更小。

### 留下的

`toggle_poltergeist_chat` 这个 apprt action 保留，语义改成「开一个跑 `polter +chat` 的终端」。GTK 侧因此不再需要单独实现聊天 UI —— 它只要能开终端就有聊天界面，这正是候选一「一份代码两平台」的兑现方式。

## 实现设计：`polter +chat`

### 界面的形状

上、左、右三块：

```text
┌────────────────────────────────────────────────────────────┐
│  build ●3 │ research │ nightly                             │  ← 群 tab，●N 是未读
├──────────────┬─────────────────────────────────────────────┤
│ 4 人         │  you                                 01:23  │
│              │  看看进度                                    │
│ • you        │                                             │
│ • ✳ retry.py │  ✳ Write retry.py decorator          01:24  │
│ • ✳ test_ret │  retry.py 已就绪，签名如下：                  │
│ • ✳ reviewer │    def retry(attempts=3, base_delay=0.1)    │
│              │                                             │
│              │  ✳ Write test_retry.py               01:26  │
│              │  收到，我按这个写断言。                       │
│              │                                             │
│              ├─────────────────────────────────────────────┤
│              │ > _                                         │
└──────────────┴─────────────────────────────────────────────┘
```

- **上：群 tab。**一个群一个 tab，带未读数。Tab 键或数字键切换。
- **左：成员列表。**「群里有几个人」那条诉求。每人一行，显示的是**终端标题** —— 也就是那个终端的 tab 上写着的同一个字符串，所以看到名字就知道是哪个窗口。这是「和 tab 对得上」的做法：不是把 id 印得好看一点，而是根本不印 id。
- **右：消息流 + 输入框。**作者行是终端标题，时间右对齐（墙钟时刻）。正文在终端里天然等宽，代码片段自然对齐；agent 之间贴的带 ANSI 颜色的日志片段也能照原样显示。

被压缩过的消息要有记号：摘要是总管对一段对话的转述，不是谁真的说过的话，读的人应该能一眼分开。

### 身份：聊天终端说话时算「你」

这是唯一的新机制。先说清楚它要解决什么，因为它看起来像是凭空多出来的一层。

**问题**：聊天界面是一个独立进程，跑在某个终端里，要通过已有的 unix socket 读写群聊。但这条 socket 上的身份认的是**终端**：宿主给每个终端注入一份令牌，服务端拿令牌反查出是哪个 `Surface.id`，那就是调用者。原则是「身份由宿主注入，不接受客户端自报家门」（见 [mcp.md](mcp.md)）。

于是聊天界面直接连上来会是这样：它被认成**它所在的那个终端**。而那个终端多半根本不在任何群里，`group_read` 会回 `NotAMember`；就算在，它发的言也会顶着那个终端的名字，而不是「你」。真正是每个群成员的是**键盘前的人**（`Chat.user_id`，也就是 0）。

**做法**：宿主记住哪些终端是它自己为聊天界面开的，这些终端说话时算 `user_id`。

不需要新令牌，也不需要新的环境变量 —— 现成的那份终端令牌照用，只是服务端在认出调用者之后多问一句「这个终端是聊天界面吗」：

### 入口：菜单，不能只有快捷键

macOS 上五个 poltergeist 动作 —— 开群聊、指定总管、监督本终端、按住本终端、把 agent 挡在本终端之外 —— **都没有默认键绑定**（`src/input/Binding.zig:694-735`）。只在命令面板里挂一条不够：没绑过键的人打开命令面板也得先知道该搜什么词。

所以菜单栏上有一个 **Agents** 菜单，五条动作都在里面（`macos/Sources/App/Base.lproj/MainMenu.xib:391-435`）。**一个只有快捷键的功能，对于没设过那个快捷键的人来说等于不存在**；而这五条里有三条是使用 Poltergeist 的必经步骤。

绑了键的人，菜单项右边会照常显示自己绑的那个键（走 `syncMenuShortcut`）。

```text
用户按下 poltergeist_toggle_chat（键绑定或菜单 Agents → Terminal Conversations）
        │
        ▼
Polter 新开一个 surface，命令是 `polter +chat`
        │  并把这个 surface 的 id 记进「聊天界面」名单
        ▼
这个 surface 像任何终端一样，环境里拿到 GHOSTTY_POLTER_SOCKET 与
GHOSTTY_POLTER_TOKEN（既有机制，不是为聊天新加的）
        │
        ▼
TUI 进程读这两个变量，连 socket，出示令牌
        │
        ▼
服务端反查出 surface id —— 到这里为止和 agent 的 sidecar 一模一样
        │
        ▼
宿主发现这个 id 在「聊天界面」名单里，于是这次调用的身份记作 user_id (0)
        │
        ▼
group_list / group_read 看到的是用户视角（用户是每个群的成员）
group_post 发的言显示为「你」
```

**全程没有任何东西需要人去录入。**令牌是宿主生成、宿主注入、进程自己从环境里读的，和 agent 那条路完全一样；用户看不到它，也不需要看到。

**为什么 agent 冒充不了**：名单里只有宿主自己开的聊天终端。一个被监督的 agent 拿着自己终端的令牌连上来，它的 id 不在名单里，身份就还是它自己 —— 它读不到自己不是成员的群，也没法以「你」的名义说话。

**被否掉的替代方案**：让客户端在握手时声明「我是界面」。那等于任何被监督的 agent 都能取得用户身份，而其它 agent 会把用户发的话当成人的指示来执行 —— 这是权限提升，不是便利。身份必须仍然由宿主判定。

**边界**：用户在聊天终端里跑别的程序，那个程序当然也能拿到同一份令牌，从而以用户身份说话。这是接受的 —— 那是用户自己的终端，用户自己负责。要守住的是**agent 拿不到**，这条成立。

### 数据：走已有的 rpc，补三个缺口

不新增 C ABI。TUI 用的都是 [mcp.md](mcp.md) 已有的工具，只是补上数据层的三条欠债：

**三条欠债现在都还上了**，表里留着是因为「为什么要还」这一列仍然成立：

| 需要 | 当初的现状 | 现在 |
| --- | --- | --- |
| 群列表 | `group_list` 有 | 不变 |
| 消息 | `group_read` 有，时间戳是单调时钟 | 带 `at_ms` 墙钟毫秒（`src/poltergeist/wire.zig:617-618`） |
| 谁在说话 | 只有 id | 消息带作者的终端标题（`src/poltergeist/wire.zig:567-568`） |
| 群里有谁 | 没有 | `group_members` 是正式方法，非总管也调得到（`src/poltergeist/rpc.zig:46`、`src/poltergeist/rpc.zig:610-616`） |

墙钟时间的做法：日志本身继续用单调时钟（测静止时长必须如此，系统时钟被校正时不能跳），但在**取第一个时间戳时把两个钟配一次对**，之后任何一条消息都能换算回墙钟。

### 真机上抓到的四个（都不是编译期能发现的）

按被发现的顺序，因为后一个总是被前一个挡着：

1. **`Chat` 按值返回，结构体被复制。**`Tty` 与 `Vaxis` 都会把指向自身的指针交出去（事件循环拿的是 `&self.tty`、`&self.vx`），复制之后那些指针指向即将消失的栈帧。表现是启动即 `panic: reached unreachable code`，一行界面都没画出来。`list_themes` 用堆分配不是巧合。
2. **第一帧画在零尺寸窗口上。**主循环为了定时轮询改成了非阻塞取事件，于是在终端还没报尺寸之前就开画。零宽零高不是「画了个空的」，是走出零长度缓冲区的末尾。改成先阻塞等第一个事件，四个绘制函数各自再挡一道。
3. **vaxis 的单元格存的是切片，不是副本。**`Cell.Character.grapheme` 是 `[]const u8`，所以任何交给 `printSegment` 的文本都必须活到 `render` 之后。成员数和时刻当初写在栈缓冲里，渲染出来是乱码字节。现在有一个每帧重置的 arena 专门放这类临时串。
4. **时刻用的是 UTC。**差八小时的时间比没有时间更糟 —— 它看起来是对的。标准库没有时区处理，所以经 libc 的 `localtime_r`，夏令时交给它。

第 3 条最值得记：它编译通过、类型正确、在小窗口下甚至可能看起来是对的，只有真跑起来才会露馅。

### 不做什么

- **不做搜索、不做富文本渲染。**这是观察窗，不是聊天软件。
- **不做历史归档界面。**落盘是有的（见「数据来源」），但界面只读当前这一份日志；翻旧账用文件。
- **不放任何启停控件**（R4）：停掉监控是 [supervisor.md](supervisor.md) 的唯一停止动作。
- **不显示任务列表**（R8）。
- **不做通知气泡**：未读走 tab 标记，归 [tabs.md](tabs.md)。

## 旧实现的记录

这一节留的是**已经删掉的** macOS 原生窗口。留着是因为其中两条决定与渲染方式无关，重做时仍然成立。

**仍然成立、要带到新实现里的**：

- **用户是 id 0。**界面要能发言，「用户」就得在消息模型里有身份。用的是 id 0：`Surface.id` 的文档明说它永远不为零（`src/Surface.zig`），所以零不会和任何终端相撞。建群时用户自动入群、且带全部历史。
- **摘要要标出来。**被压缩过的消息带 `summary` 标记，界面上应打一个记号 —— 摘要是总管对一段对话的转述，不是谁真的说过的话，读的人应该能一眼分开。
- **发送失败不清空输入框。**把人写的东西悄悄吞掉，比让他再按一次发送糟糕得多。
- **一次取全量，不显示半更新的状态。**

**随窗口一起作废的**：

- `NSWindow` + `NSHostingView` 的搭法、左栏群列表右栏消息流的布局。
- 每秒轮询 `ghostty_app_chat` 快照的取数方式 —— 新实现走 rpc，节奏由 TUI 自己定。
- 整套 C ABI（`ghostty_app_chat` / `ghostty_app_free_chat` / `ghostty_app_chat_post`）。

**当时踩过、新实现别再踩的**：

- `uintptr_t` 在 Swift 里是 `UInt`，指针下标要 `Int`。（不适用于 TUI，但说明了 C ABI 这层的摩擦本身就是成本。）
- 窗口关闭后 SwiftUI 视图仍在 `contentView` 里，订阅不取消，轮询继续跑。TUI 没有这个问题：进程退出就是退出。

## 数据来源、保留与订阅

### 权威存储在哪

写入方是 Poltergeist 的 sidecar，其进程形态与消息协议归 [mcp.md](mcp.md)。本章只规定 UI 侧的读取契约：**界面是纯消费者，自己不产生除「用户发言」以外的任何消息**。这条边界是为了让界面随时可以关掉、重开、甚至开多个而不影响系统状态。

### 内存 + 落盘两层

- 内存：每条会话一个环形缓冲，只保留最近 N 条，用于快速上翻。
- 落盘：照 `src/cli/ssh-cache/DiskCache.zig` 的模板做——用 `xdg.state(...)` 加 `.{ .subdir = program }` 拿目录（`src/cli/ssh-cache/DiskCache.zig:32-37`），文档明确注明「在所有平台上都是 `${XDG_STATE_HOME}/ghostty/…`」（`src/cli/ssh-cache/DiskCache.zig:23`），文件以 0600 权限创建（`:56`），并设一个总量硬上限（该文件设的是 512KB，`:16`）。崩溃报告目录走的是同一套（`src/crash/dir.zig:8`）。

Poltergeist 的聊天日志落在 `${XDG_STATE_HOME}/polter/chat/`。**已经做了**（`src/poltergeist/ChatLog.zig`，开关 `poltergeist-chat-log`，`src/config/Config.zig:1414`，默认开）。当初写「要做」的理由原样留着，因为它就是这件事的意义：人睡觉的时候 agent 在聊，第二天早上要能复盘昨晚发生了什么，而纯内存的实现 Polter 一退出就全没了。

落盘归 `Chat.zig` 这一层，不归界面。理由是写入方是消息模型本身，而界面是纯消费者 —— 让界面负责持久化，就等于「不开界面就不留记录」，而挂机过夜恰恰是没人开着界面的时候。

选 state 不选 cache 的理由：聊天记录被系统当缓存清掉会直接丢掉排查线索，而这正是挂机过夜场景里第二天早上唯一能复盘的东西。选 0600 的理由：消息正文会带代码片段、文件路径、报错堆栈，是真实的隐私面而不是形式条款。这两条都不是新发明，是照抄仓库已经跑通的做法，省掉一次平台差异讨论。

### 保留期与隐私边界

**当初写的是「按天数 + 总量双上限滚动淘汰」，落地时被否掉了，而且是反过来的。**
实现分成两种形状（`src/poltergeist/ChatLog.zig`，完整论证归 [storage.md](storage.md)）：

- **流** `chat.jsonl` —— 8MB 轮转、留两代，给机器自己回填比对用（`src/poltergeist/ChatLog.zig:58`）。
- **记录** `<群>/<日期>.jsonl` —— **从不轮转、从不裁剪**，给人和 AI 读。

否掉「滚动淘汰」的理由是这一节自己那句话的反面：第二天早上要能复盘昨晚，而一个
会自己丢东西的记录恰恰在「昨晚很热闹」的时候丢得最多。有界的那一份留给不需要
完整的那一侧，读的人拿的是完整的那一份。

「不落盘」配置有了：`poltergeist-chat-log`（`src/config/Config.zig:1414`）。理由同上：
R5 的场景里 AI 会大量把仓库内容粘进群聊。

### 订阅方式

两个候选就地比：

- **追加日志 + tail** —— 实现简单，无需新造传输层，代价是要处理文件轮转。
- **长连接推送** —— 实时性好，但要新造服务端，而仓库里根本没有（`src/os/systemd.zig:86-95` 只是单向 notify；`src/apprt/embedded.zig:349-360` 说明现成 IPC 在 macOS 上全部 `return false`）。

**这段推导已被现实取代。**写它的时候仓库里还没有任何服务端；后来 [mcp.md](mcp.md) 的 unix socket 落地了，TUI 直接用它取数，两个候选都不必选。留着这段是因为它记录了「传输层是必付成本」这个判断 —— 而这笔成本最后由 MCP 那条线一次性付掉了，界面这边一分没花。

TUI 侧的取数节奏因此是它自己的事：按需拉取，不需要宿主推送。

## 用户能不能发言

**结论：能，而且必须能。**三条理由：

1. R5 的场景里用户要接管——白天分派、晚上挂机、早上回来插话。没有发言入口，用户就只能挨个终端敲字，群聊白做。
2. R3 的「通知用户」策略如果没有回话入口就是死路：用户被叫醒之后需要一个地方回「继续」或「换方向」。
3. 实现上用户发言与 AI 发言数据模型同构，只是发言者 ID 不同（用户是 0），零额外成本。

**同时划死三条边界**，否则这个界面会膨胀成控制台：

- 用户发言**只进入聊天记录**，不直接写进任何终端的 pty。往终端注入文本是总管的动作（核心侧路径是 `Surface.textCallback()`，`src/Surface.zig:3672`），触发条件与授权归 [supervisor.md](supervisor.md) 与 [mcp.md](mcp.md)。
- 界面里**不放停止按钮**。停掉监控是独立动作（R4），见 [supervisor.md](supervisor.md)。
- 界面里**不显示、不编辑任务**（R8）。

## 取舍记录

| 方案                                     | 成本                                                                                                                                                                     | 为什么没选 / 为什么选                                                                                                                                                                                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 一：终端内 TUI（`ghostty +polter-chat`） | 2 文件 4 改动点注册（`src/cli/ghostty.zig:33`、`:153-175`、`:179-190`、`:195-219`）+ 一份几百行 vaxis 代码；折行与滚动自写                                               | **选它**。vaxis 已链进主 exe（`build.zig.zon:25-30`、`src/build/SharedDeps.zig:512-520`、`src/build/GhosttyExe.zig:34`），`src/cli/list_themes.zig:240-262` 是同构先例；中文显示与输入由宿主表面负责（`src/Surface.zig:2636`）；与上游分叉面最小 |
| 二：两套原生 UI（仿 command palette）    | 一个 apprt action 起步 8 处改动跨 3 语言（`src/apprt/action.zig:119`、`include/ghostty.h:928`、`macos/Sources/Ghostty/Ghostty.App.swift:571-572` 等）+ 约 1600 行平台 UI | 每加一个界面元素改两处，维护翻倍；ABI 枚举顺序与上游 rebase 冲突面最大。留作二期，触发条件见「选型结论与分期」                                                                                                                                   |
| 三：imgui（仿 inspector）                | UI 只写一份 Zig，两平台复用；要拉 `dcimgui`（`build.zig.zon:75`）                                                                                                        | 只加载 JetBrains Mono（`src/inspector/Inspector.zig:38-55`、`src/font/embedded.zig:16`），无 CJK；macOS 侧 `setMarkedText` 不转发预编辑（`macos/Sources/Ghostty/Surface View/InspectorView.swift:355-366`）。聊天要打中文，这条过不去            |
| 四：轻量覆盖层                           | 最低                                                                                                                                                                     | 无滚动历史、无文本输入、自动消失（`macos/Sources/Ghostty/Surface View/SurfaceView.swift:75-107`）。降级为未读提示，归 [tabs.md](tabs.md)                                                                                                         |
| 五：渲染器级 CPU 覆盖层                  | 低                                                                                                                                                                       | `src/renderer/Overlay.zig:1-12` 与 `:70-72` 表明它是纯绘制通道，零输入能力。排除                                                                                                                                                                 |
| 六：外置进程 / 网页                      | 两平台各引一个浏览器引擎（`macos/Sources` 下 WebKit 0 命中）+ 新造传输层（`src/apprt/embedded.zig:349-360`）                                                             | 成本最高，收益只有观感。排除                                                                                                                                                                                                                     |
| 存储：XDG state 落盘                     | 照抄 `src/cli/ssh-cache/DiskCache.zig:23`、`:32-37`、`:56`                                                                                                               | 选 state 不选 cache：被当缓存清掉会丢排查线索；0600 因为正文含路径与堆栈。同时提供「不落盘」开关                                                                                                                                                 |
| 订阅：tail 起步                          | 要处理文件轮转                                                                                                                                                           | 长连接需新造服务端（`src/os/systemd.zig:86-95`），且协议归 [mcp.md](mcp.md)，本章不重复设计                                                                                                                                                      |

## 未决问题

1. ~~聊天日志的保留天数与总量上限~~ —— **已定**：流 8MB × 2 代（`src/poltergeist/ChatLog.zig:58`），记录不设上限。
2. ~~tail 的轮转策略：单文件滚动，还是按天分文件~~ —— **已定：两个都做**，各服务一侧，见上「保留期与隐私边界」与 [storage.md](storage.md)。
3. vaxis 的 CJK 折行与光标定位实际表现到什么程度（`src/build/uucode_config.zig:42-46` 已把 `east_asian_width` 喂给它，但未实测长段落）。
4. 私信线程的命名：用 `Surface.id` 的十六进制（`src/Surface.zig:55-60`）可读性差，用 tab 标题别名又会随标题变化而漂移。
5. 用户发言是否需要 `@` 指定终端，还是一律广播到群聊——这牵涉总管如何解读用户消息，主体归 [supervisor.md](supervisor.md)。

## 延伸阅读

- [README.md](README.md) —— Poltergeist 总览与索引。
- [mcp.md](mcp.md) —— sidecar、消息协议、身份识别、skill 体系。
- [supervisor.md](supervisor.md) —— 监督关系、按住、确认策略、停掉监控。
- [tabs.md](tabs.md) —— tab 合并、状态标记、未读提示的落地位置。
- [\_spec.md](_spec.md) —— 本批文档的写作规范与术语表。
