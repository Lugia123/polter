# 群聊与私信界面

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**尚未实现**（S3）。承载方式已定：一期只做 macOS 原生 UI，见「选型结论与分期」。

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
- 监督关系、上班 / 下班、监工模式、确认策略、通知时间段、停掉监控 —— 见 [supervisor.md](supervisor.md)。
- tab 合并、tab 状态标记、「有 N 条未读」怎么打到 tab 上 —— 见 [tabs.md](tabs.md)。
- 构建与运行命令 —— 见 [preview-manual.md](../preview-manual.md)。

## 一句话概括

群聊与私信界面本设计选择做成**一个跑在 Ghostty 表面（surface）里的 TUI**（拟命名 `ghostty +polter-chat`）：仓库里已经链着 TUI 框架，并且已有一个结构完全同构的完整先例可以照抄，代价远低于在 macOS 与 GTK 两边各写一份原生 UI。这个界面是给人看的观察窗，AI 之间的通信不经过它。

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
5. **观察窗，不是控制台** —— 除发言外只读：不在这里改监工模式、不在这里停掉监控、不在这里给任何终端敲命令。
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

1. 新建 `src/cli/polter_chat.zig`（仓库中尚不存在）。help 文本写在 `run` 函数的文档注释里，不需另建文档文件（`src/cli/README.md:11-13`）。
2. 在 `src/cli/ghostty.zig` 的 `Action` 枚举加成员（枚举定义在 `src/cli/ghostty.zig:31`，末尾成员 `@"toggle-quick-terminal"` 在 `:87`）。
3. 在 `runMain` 的 switch 加一个分支（`src/cli/ghostty.zig:153-175`）。
4. 在 `options` 的 switch 加一个分支（`src/cli/ghostty.zig:195-219`）。

源文件名由枚举名 comptime 推导（`Action.file()`，`src/cli/ghostty.zig:179-190`），不用另外登记；shell 补全从 `@typeInfo(Action)` comptime 遍历生成（`src/extra/fish.zig:30`），零额外改动。合计 2 个文件 4 个改动点。

### 为什么它天然满足中文需求

CLI action 在 GUI 启动之前执行并直接 `std.process.exit`（`src/main_ghostty.zig:68-74`），所以 `+polter-chat` 就是一个普通的独立终端程序，跑在某个 Ghostty 表面里。字体栈、CJK 宽度、输入法全部由宿主表面负责——表面层已有 IME 预编辑通道 `preeditCallback`（`src/Surface.zig:2551`）。这是候选一相对候选三的决定性优势：中文支持是免费继承的，不用为聊天界面单独再实现一遍。

它还能自己发 OSC 0/2 改标题，经 `handleMessage` 的 `.set_title` 分支转成 apprt action（`src/Surface.zig:976-992`），与 [tabs.md](tabs.md) 的标记机制天然衔接。

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

1. 核心 action 枚举成员 —— `src/apprt/action.zig:119`，C ABI 同步枚举 `src/apprt/action.zig:373`。
2. C 头文件必须同步 —— `include/ghostty.h:917`。
3. 核心侧分发 —— `src/Surface.zig:5488-5490`。
4. 键绑定动作枚举 —— `src/input/Binding.zig:816`。
5. 默认键位 —— `src/config/Config.zig:6983`。
6. 命令面板自身的命令表 —— `src/input/command.zig:742`。
7. GTK 落地 —— `src/apprt/gtk/class/application.zig:786`，加速键同步在 `:1213`。
8. macOS 落地 —— `macos/Sources/Ghostty/Ghostty.App.swift:557-558`。

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

## 选型结论与分期

### 已定：一期只做 macOS 原生 UI（用户决策）

用户在设计评审中明确选定：**界面一期只做 macOS**。这条覆盖本章原先「一期做候选一（终端内 TUI）」的推荐，理由由用户给出而非本文推导，记录在此以免日后被当作笔误改回去。

落地口径：

- **承载方式取候选二的 macOS 半边** —— SwiftUI Feature，仿 `macos/Sources/Features/Command Palette/` 的组织方式。
- **GTK 侧明确推后到二期**，本期不写任何 GTK 聊天 UI。这意味着候选二原本「两套原生 UI」的成本本期只付一半。
- **跨平台代价照付一次**：驱动 macOS UI 所需的 apprt action 与 C ABI 登记（`src/apprt/action.zig`、`include/ghostty.h`、`macos/Sources/Ghostty/Ghostty.App.swift`）是平台无关的公共部分，本期就要建好，否则二期接 GTK 时要返工。
- **未读提示**走候选四的形态（tab 标记 / 覆盖层），归 [tabs.md](tabs.md)。

### 这条决策的代价，如实记录

本章原先推荐候选一，理由是一份 Zig 跨平台、约 1600 行平台 UI 的钱一分不用付。改做 macOS 原生后：

| 项               | 变化                                                                                               |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| 平台覆盖         | 从「一份代码两平台」变成「本期只有 macOS 能用」                                                    |
| 构建前置         | 需要 Xcode 26 + macOS 26 SDK（见 [preview-manual.md](../preview-manual.md)），不再是纯 `zig build` |
| 每加一个界面元素 | 二期接 GTK 后要改两处，维护翻倍                                                                    |
| 换来的           | 原生观感、系统级无障碍、图片与富文本的将来可能性                                                   |

若二期做 GTK，会多出 blueprint-compiler 这个构建前置（blueprint 清单见 `src/apprt/gtk/build/gresource.zig:33-55`），构建命令的唯一权威是 [preview-manual.md](../preview-manual.md)。

### 候选一的残值

终端内 TUI 方案不作废，降级为**调试视图**：实现成本低，且不依赖 Xcode，在没有 macOS 构建环境时（例如 CI、或纯核心开发）仍是唯一能看到聊天流的手段。建议保留为 `polter +chat --tui` 之类的次要入口，但不作为一期交付项。

## 群聊与私信在同一界面里的组织

- **左栏会话列表** —— 第一行固定是群聊频道，其下是若干私信线程，每条以参与的两个终端命名。终端标识用 `Surface.id`（`src/Surface.zig:57-62`，注释明说它用于 IPC 且暴露给子进程），该 ID 已以 `GHOSTTY_SURFACE_ID` 注入子进程环境（`src/Surface.zig:651-655`，格式 `0x{x:0>16}`）。这样聊天记录里的发言者 ID 与 [tabs.md](tabs.md) 的 tab 标记指的是同一个东西，不需要再造一套映射。
- **未读** —— 每条会话记一个「已读水位线」，用消息序号而不是时间戳。理由：序号单调，不受时钟回拨与跨机器时间漂移影响；挂机过夜的场景里系统休眠 / 唤醒会让时间戳排序变得不可靠。
- **右栏消息流** —— 选中会话的消息按序号升序排列，底部是发言框，用法照 `src/cli/list_themes.zig:259` 的字段声明与 `:824-837` 的绘制。
- **搜索** —— 照 `src/cli/list_themes.zig:252-257` 的模式机加一个 `search` 态；模糊匹配可直接用仓库已有的 `zf`（`build.zig.zon:60-65`，`src/cli/list_themes.zig:11` 已 import）。

以下为设计示意，仓库中尚不存在：

```text
┌────────────────────────────────┬──────────────────────────────────────────┐
│ # 群聊                    (3) │ [10:02] supervisor  该终端静止 8 分钟     │
│ ─────────────────────────────  │ [10:02] 0x…0003     正在跑测试，等编译    │
│ @ supervisor ↔ 0x…0003        │ [10:05] supervisor  收到，继续等          │
│ @ supervisor ↔ 0x…0007    (1) │ [10:11] you         先别切任务，等我看     │
│ @ 0x…0003 ↔ 0x…0007           │                                          │
│                                ├──────────────────────────────────────────┤
│                                │ > ▏                                      │
└────────────────────────────────┴──────────────────────────────────────────┘
  会话列表（宽 32）                消息流 + 发言框
```

## 数据来源、保留与订阅

### 权威存储在哪

写入方是 Poltergeist 的 sidecar，其进程形态与消息协议归 [mcp.md](mcp.md)。本章只规定 UI 侧的读取契约：**界面是纯消费者，自己不产生除「用户发言」以外的任何消息**。这条边界是为了让界面随时可以关掉、重开、甚至开多个而不影响系统状态。

### 内存 + 落盘两层

- 内存：每条会话一个环形缓冲，只保留最近 N 条，用于快速上翻。
- 落盘：照 `src/cli/ssh-cache/DiskCache.zig` 的模板做——用 `xdg.state(...)` 加 `.{ .subdir = program }` 拿目录（`src/cli/ssh-cache/DiskCache.zig:32-37`），文档明确注明「在所有平台上都是 `${XDG_STATE_HOME}/ghostty/…`」（`src/cli/ssh-cache/DiskCache.zig:23`），文件以 0600 权限创建（`:56`），并设一个总量硬上限（该文件设的是 512KB，`:16`）。崩溃报告目录走的是同一套（`src/crash/dir.zig:8`）。

Poltergeist 的聊天日志拟落在 `${XDG_STATE_HOME}/ghostty/polter/chat/`。

选 state 不选 cache 的理由：聊天记录被系统当缓存清掉会直接丢掉排查线索，而这正是挂机过夜场景里第二天早上唯一能复盘的东西。选 0600 的理由：消息正文会带代码片段、文件路径、报错堆栈，是真实的隐私面而不是形式条款。这两条都不是新发明，是照抄仓库已经跑通的做法，省掉一次平台差异讨论。

### 保留期与隐私边界

默认按「天数 + 总量」双上限滚动淘汰，超出后按会话逐条丢弃最旧的。具体数值列入未决问题——`src/cli/ssh-cache/DiskCache.zig:16` 的 512KB 是 ssh 缓存的量级，照搬到会带大段代码的聊天正文没有依据。

必须提供「不落盘」配置（只留内存，进程退出即消失）。理由同上：R5 的场景里 AI 会大量把仓库内容粘进群聊。

### 订阅方式

两个候选就地比：

- **追加日志 + tail** —— 实现简单，无需新造传输层，代价是要处理文件轮转。
- **长连接推送** —— 实时性好，但要新造服务端，而仓库里根本没有（`src/os/systemd.zig:86-95` 只是单向 notify；`src/apprt/embedded.zig:349-360` 说明现成 IPC 在 macOS 上全部 `return false`）。

本设计选 tail 起步。传输层是必付成本，但没必要在本章重复设计一遍——那会和 [mcp.md](mcp.md) 打架。长连接留给 sidecar 协议统一解决，届时 UI 侧只需换掉数据源读取函数。

## 用户能不能发言

**结论：能，而且必须能。** 三条理由：

1. R5 的场景里用户要接管——白天分派、晚上挂机、早上回来插话。没有发言入口，用户就只能挨个终端敲字，群聊白做。
2. R3 的「通知用户」策略如果没有回话入口就是死路：用户被叫醒之后需要一个地方回「继续」或「换方向」。
3. 实现上用户发言与 AI 发言数据模型同构，只是发言者 ID 不同，零额外成本。

**同时划死三条边界**，否则这个界面会膨胀成控制台：

- 用户发言**只进入聊天记录**，不直接写进任何终端的 pty。往终端注入文本是总管的动作（核心侧路径是 `Surface.textCallback()`，`src/Surface.zig:3308`），触发条件与授权归 [supervisor.md](supervisor.md) 与 [mcp.md](mcp.md)。
- 界面里**不放停止按钮**。停掉监控是独立动作（R4），见 [supervisor.md](supervisor.md)。
- 界面里**不显示、不编辑任务**（R8）。

## 取舍记录

| 方案                                     | 成本                                                                                                                                                                     | 为什么没选 / 为什么选                                                                                                                                                                                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 一：终端内 TUI（`ghostty +polter-chat`） | 2 文件 4 改动点注册（`src/cli/ghostty.zig:31`、`:153-175`、`:179-190`、`:195-219`）+ 一份几百行 vaxis 代码；折行与滚动自写                                               | **选它**。vaxis 已链进主 exe（`build.zig.zon:25-30`、`src/build/SharedDeps.zig:512-520`、`src/build/GhosttyExe.zig:34`），`src/cli/list_themes.zig:240-262` 是同构先例；中文显示与输入由宿主表面负责（`src/Surface.zig:2551`）；与上游分叉面最小 |
| 二：两套原生 UI（仿 command palette）    | 一个 apprt action 起步 8 处改动跨 3 语言（`src/apprt/action.zig:119`、`include/ghostty.h:917`、`macos/Sources/Ghostty/Ghostty.App.swift:557-558` 等）+ 约 1600 行平台 UI | 每加一个界面元素改两处，维护翻倍；ABI 枚举顺序与上游 rebase 冲突面最大。留作二期，触发条件见「选型结论与分期」                                                                                                                                   |
| 三：imgui（仿 inspector）                | UI 只写一份 Zig，两平台复用；要拉 `dcimgui`（`build.zig.zon:75`）                                                                                                        | 只加载 JetBrains Mono（`src/inspector/Inspector.zig:38-55`、`src/font/embedded.zig:16`），无 CJK；macOS 侧 `setMarkedText` 不转发预编辑（`macos/Sources/Ghostty/Surface View/InspectorView.swift:355-366`）。聊天要打中文，这条过不去            |
| 四：轻量覆盖层                           | 最低                                                                                                                                                                     | 无滚动历史、无文本输入、自动消失（`macos/Sources/Ghostty/Surface View/SurfaceView.swift:75-107`）。降级为未读提示，归 [tabs.md](tabs.md)                                                                                                         |
| 五：渲染器级 CPU 覆盖层                  | 低                                                                                                                                                                       | `src/renderer/Overlay.zig:1-12` 与 `:70-72` 表明它是纯绘制通道，零输入能力。排除                                                                                                                                                                 |
| 六：外置进程 / 网页                      | 两平台各引一个浏览器引擎（`macos/Sources` 下 WebKit 0 命中）+ 新造传输层（`src/apprt/embedded.zig:349-360`）                                                             | 成本最高，收益只有观感。排除                                                                                                                                                                                                                     |
| 存储：XDG state 落盘                     | 照抄 `src/cli/ssh-cache/DiskCache.zig:23`、`:32-37`、`:56`                                                                                                               | 选 state 不选 cache：被当缓存清掉会丢排查线索；0600 因为正文含路径与堆栈。同时提供「不落盘」开关                                                                                                                                                 |
| 订阅：tail 起步                          | 要处理文件轮转                                                                                                                                                           | 长连接需新造服务端（`src/os/systemd.zig:86-95`），且协议归 [mcp.md](mcp.md)，本章不重复设计                                                                                                                                                      |

## 未决问题

1. 聊天日志的保留天数与总量上限具体取值——`src/cli/ssh-cache/DiskCache.zig:16` 的 512KB 不能直接照搬到会带大段代码的聊天正文。
2. tail 的轮转策略：单文件滚动，还是按天分文件。
3. vaxis 的 CJK 折行与光标定位实际表现到什么程度（`src/build/uucode_config.zig:42-46` 已把 `east_asian_width` 喂给它，但未实测长段落）。
4. 私信线程的命名：用 `Surface.id` 的十六进制（`src/Surface.zig:57-62`）可读性差，用 tab 标题别名又会随标题变化而漂移。
5. 用户发言是否需要 `@` 指定终端，还是一律广播到群聊——这牵涉总管如何解读用户消息，主体归 [supervisor.md](supervisor.md)。

## 延伸阅读

- [README.md](README.md) —— Poltergeist 总览与索引。
- [mcp.md](mcp.md) —— sidecar、消息协议、身份识别、skill 体系。
- [supervisor.md](supervisor.md) —— 监督关系、监工模式、确认策略、停掉监控。
- [tabs.md](tabs.md) —— tab 合并、状态标记、未读提示的落地位置。
- [\_spec.md](_spec.md) —— 本批文档的写作规范与术语表。
