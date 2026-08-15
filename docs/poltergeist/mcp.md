# Poltergeist MCP 工具面与 Skill 体系

> 最后更新对应的 git commit：`f81dcadc8`（`f81dcadc82ea2afdcf2dc92929037701122f05b5`，2026-08-14）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**已实现**（S2）。工具面在 `src/poltergeist/rpc.zig`，线协议在 `wire.zig`，socket 与 token 在 `Server.zig`，sidecar 在 `src/cli/polter_mcp.zig`，Skill 体系在 `skill.zig` 与 `skills/`。**本章若与代码不一致，以代码为准**：下面几节是设计推导，实现与它的出入记在各节的「实现与本章的出入」里。

## 本章覆盖什么

- MCP 承载形态：为什么是 sidecar 进程 `ghostty +polter-mcp`，而不是把 MCP server 塞进 Ghostty 核心。
- sidecar 怎么认领身份、怎么连回宿主进程；传输层四选一与鉴权形态。
- 完整 MCP 工具清单、参数 / 返回 / 角色权限矩阵，以及权限矩阵为什么是单向星形。
- 输入注入机制：复用粘贴通道，以及回车为什么必须单独合成。
- 消息送达语义：只送「有新消息」的通知，不送正文。
- Skill 体系（R7）：存哪、什么格式、谁读、怎么维护。
- 边界（R8）怎么落实成「工具面里没有什么」。

## 本章不覆盖什么

- 静止时长怎么测出来、成本多少、阈值怎么定 —— 见 [sensing.md](sensing.md)。本章只消费这一个标量。
- 监督关系怎么建立、监工模式语义、确认策略、通知时间段、停掉监控 —— 见 [supervisor.md](supervisor.md)。
- 竞态守卫在总管侧的完整规则（用户正在打字、输入框非空、总管自我注入）—— 见 [supervisor.md](supervisor.md)。本章只给注入侧的机械保证。
- 安全边界，含 R2「明确不做自动点 yes」为什么不留任何口子 —— 见 [supervisor.md](supervisor.md)。本章的 `terminal_send` 只是通用文本注入原语，工具面里没有、也不会有任何「替对方回答权限询问」的专用工具。
- 群聊 / 私信的**界面**怎么画 —— 见 [chatui.md](chatui.md)。本章只定义消息的工具面与送达语义。
- tab 合并与状态标记落到 macOS / GTK —— 见 [tabs.md](tabs.md)。
- 写作规范与术语表 —— 见 [\_spec.md](_spec.md)。

## 一句话概括

Poltergeist（能力层）的控制面是一个跟着 AI 进程跑的 sidecar：`ghostty +polter-mcp` 作为 MCP server，靠宿主已注入的 `GHOSTTY_SURFACE_ID`（`src/Surface.zig:651-655`）认领身份，经本地 unix socket 连回宿主 Ghostty，把「读屏 / 注入 / 群聊私信 / 打下班标记」四类能力暴露给 AI；监工模式落成几份 skill 文本，硬约束则落在程序里。

## 设计目标与约束

- **R7** —— Skill 体系集成在 Poltergeist 里、可维护。
- **R8** —— 不管理任务：工具面里必须**没有**任务 CRUD。
- **R6 的硬约束** —— 无限工作模式下 `clock_out` 由程序拒绝，不靠提示词自觉。
- 承接旧设计里仍成立的多终端互通能力：读屏、群聊、私信。

**两处与 README 的分工在此重申。**其一，「消息送达只注入通知、不注入正文」的机制层面（为什么只送通知、限流形状、拉取工具）归本章，chatui.md 只留界面呈现。其二，注入路径继承的是 bracketed 封装与控制字节剥除，**不是**不安全粘贴确认，详见下文「复用粘贴通道」。README 的对应两条已按此口径同步，若日后再次出现分歧，以本章为准。

## 承载形态：sidecar 进程 polter-mcp

### 为什么不把 MCP 塞进 Ghostty 核心

- Ghostty 核心是渲染敏感的 Zig 代码，每个 surface 有独立的渲染线程与 IO 线程。把一个长连接 JSON-RPC 服务端塞进这条路径，意味着解析、超时、重连都要挤进已有的事件循环。
- MCP 协议的演进节奏与终端无关。绑进核心等于每次协议改版都要动一次终端二进制，与上游 ghostty-org/ghostty 的分叉面直接变宽。
- sidecar 崩了只影响一个 AI 会话；核心崩了影响全部终端。

### 集成成本：`+<action>` 是仓库既有的成熟模式

拟按现有 CLI action 惯例落地，逐跳如下：

1. 在 `Action` 枚举里加一项（`src/cli/ghostty.zig:31-87`，当前 19 项，从 `version` 到 `@"toggle-quick-terminal"`）。
2. 在 `runMain` 的 switch 里加一条分发（`src/cli/ghostty.zig:153-174`）。
3. 新建 `src/cli/polter_mcp.zig` —— 文件路径由 `Action.file()` 从枚举名机械推导，把 `-` 换成 `_` 再加 `cli/` 前缀与 `.zig` 后缀（`src/cli/ghostty.zig:179-190`）。
4. 帮助文本**不用手写注册**：`helpgen` 在构建期 `inline for` 遍历 `Action` 枚举字段、`@embedFile` 每个 action 源文件、找到名为 `run` 的函数并要求其前必须有 doc comment，否则直接报错（`src/helpgen.zig:82-100`）。这条规则写在 `src/cli/README.md:11-13`。
5. 参数解析要求 action 以 `+` 开头且一次只能出现一个，否则返回 `MultipleActions` / `InvalidAction`（`src/cli/action.zig:47-51`）。

**就地结论**：新增一个 CLI action 的边际成本是「三处枚举登记 + 一个新文件」，没有构建系统改动。这是选 sidecar 而非内置最直接的工程理由 —— sidecar 在这里不是架构洁癖，而是更省。

**推翻条件**：若 MCP 的延迟要求降到毫秒级、或需要在核心里维持大量长连接状态，sidecar 的往返成本才会成为问题。当前场景（挂机过夜）的时间尺度是分钟，不会触发。

MCP 协议本身的帧格式、`initialize` 握手、`tools/list` 与 `tools/call` 的确切 schema 不来自本仓库，本章不复述（未核实：实现按规范写成，但没有对着官方 schema 逐条比对过，也没有接过真实 MCP 客户端）。实现见 `src/cli/polter_mcp.zig`。

## 身份识别：现状代码已经解决了

- `Surface.id: u64` 的 doc comment 直说它是给 IPC 用的唯一 ID，会以环境变量 `GHOSTTY_SURFACE_ID` 暴露给 surface 里运行的命令，且不得为零（`src/Surface.zig:57-62`）。
- 注入点与格式：`0x{x:0>16}`（`src/Surface.zig:651-655`）；同一段代码先主动摘掉了 `GHOSTTY_LOG`（`src/Surface.zig:649`）。
- **现成先例**：`ghostty +new-tab` 在未提供 `--surface-id` 时就是从该环境变量读、`parseUnsigned(u64, e, 0)`、失败回落 0（`src/cli/new_tab.zig:247-252`）。sidecar 认领身份照抄这段即可。

**就地结论**：不新增环境变量，也不让 AI 自报家门。**身份来自宿主注入而非 AI 声明**，这条同时是后面权限矩阵的地基 —— AI 无法伪造自己是哪个终端。

顺带一提既有注入：`GHOSTTY_RESOURCES_DIR`（`src/termio/Exec.zig:638`）、`GHOSTTY_BIN_DIR` 并把 ghostty 可执行文件目录追加进子进程 `PATH`（`src/termio/Exec.zig:692-711`）、`GHOSTTY_SHELL_FEATURES`（`src/termio/Exec.zig:770`）。`PATH` 那条的实际含义是：AI 进程里直接敲 `ghostty +polter-mcp` 就能命中二进制，MCP 客户端配置不必写绝对路径。

## 传输层选型

### 现成 IPC 为什么不能复用

两条各自独立致命的硬伤：

1. **macOS 完全没实现**。embedded apprt 的 `performIpc` 三个分支全部 `return false`（`src/apprt/embedded.zig:349-360`）；只有 GTK apprt 走 D-Bus。主场景是 macOS，这一条就已经出局。
2. **它是单向命令通道，不是 RPC**。`apprt.ipc.Action.Key` 只有 `new_window` / `new_tab` / `toggle_quick_terminal` 三项（`src/apprt/ipc.zig:176-179`），`performIpc` 的返回类型只有 `bool`（`src/apprt/embedded.zig:349-354`）——「发出去了没有」，不是「结果是什么」。GTK 实现给 `callSync` 的 reply type 传 `null`，注释原文是 `We don't care about the return type, we don't do anything with it.`（`src/apprt/gtk/ipc/DBus.zig:171`）。而工具面里的 `terminal_read` / `terminal_list` 必须带结构化返回。

第 2 条比第 1 条更根本：就算给 macOS 补上实现，这条通道的形状仍然不对。

### 四个候选与结论

**本设计选择 (b) 自建 unix socket 服务端。**跨平台一份实现、请求-响应形状天生正确、与上游代码零耦合 —— 仓库 `src/` 下目前没有任何 `std.net` 代码（grep 无命中），这是纯新增而非改造上游文件，分叉面最小。

被淘汰的三个及理由列在本章末尾的取舍记录。其中 (d)「复用 macOS 既有 AppleScript 通道」值得单独说明：仓库已有完整的 scripting 字典，`input text`（`macos/Ghostty.sdef:221`）与 `send key`（`macos/Ghostty.sdef:229`）两个命令齐备，终端枚举 `terminals`（`macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift:92`）与按唯一 ID 查找 `valueInTerminalsWithUniqueID:`（同文件 `:104`）也齐备，且 `input text` 最终落到 `surface.sendText`（`macos/Sources/Features/AppleScript/ScriptInputTextCommand.swift:38`）—— 与本设计的注入路径同源。淘汰它作为传输层的理由是：macOS-only（GTK 无对应物）、要经 `osascript` 往返、且**没有从宿主推给 sidecar 的方向**，静止通知推不出去。但它的配置闸门模式必须照抄，见下。

**推翻条件**：若上游把 `apprt.ipc` 改造成带返回值的 RPC 并给 macOS 补齐实现，(b) 就应让位给 (a)，那时自建通道纯属重复。

服务端线程挂在 Ghostty 进程内的哪一层尚未定（未核实：是否存在 app 级、与 surface 无关的可复用后台循环，核实方式是通读 `src/App.zig` 的 create / run 与各 apprt 的 run 实现；libxev 是否导出 socket accept 类型也需另行核实）。已确定的是回到主线程的入口：`App.Mailbox.push` 在入队后立即调用 `rt_app.wakeup()` 唤醒事件循环（`src/App.zig:617-623`）。

### 鉴权

- **只监听 unix socket，绝不开网络端口**。否则本机任意进程都能操控用户的所有终端。
- socket 路径与一次性 token 一起注入子进程环境；sidecar 连上后先出示 token。token 与 surface 绑定，**`me()` 的返回值由服务端根据 token 决定，不接受客户端自称**。
- socket 文件权限 0600，放在 XDG 运行时 / state 目录下 —— `internal_os.xdg` 已提供 `config` / `cache` / `state` 三个入口（`src/os/xdg.zig:22`、`:31`、`:40`）。
- **一个顶层配置项作为准入闸门**。形态照抄 `macos-applescript`：一个 bool 配置项（`src/config/Config.zig:3489`），所有入口先过一次 gate，被拒时返回明确错误而不是静默失败（`macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift:300-316`，`validateScript` 置 `errAEEventNotPermitted` 并给出错误串）。理由：这是仓库里已被接受的「外部进程可以操控终端，但用户能否决」的先例，照抄比自创便宜，且用户已理解这个心智模型。
- **照抄的是形态，不是默认值。**`macos-applescript` 自身默认 `true`（`src/config/Config.zig:3489`），本设计的闸门拟**默认关**：它放行的是「向用户所有终端注入文本」，默认关意味着未配置过的 Ghostty 与今天行为完全一致、不多出任何受攻击面；而 R5 的流程里用户本来就要显式指定总管与监督范围，多改一个配置项不构成额外负担。
- **这个闸门不是 R4 说的那种开关。**它是一次性准入授权（装没装、准不准外部进程连进来），不是运行时的启停；R4 针对的「停掉监控」是唯一的停止动作，归 [supervisor.md](supervisor.md)。两者可以并存：闸门开着，用户照样随时停掉监控。
- **不做 `allow` / `ask` / `deny` 三态**。Ghostty 对剪贴板确实有三态，`clipboard-read` 默认 `ask`（`src/config/Config.zig:2454`），但挂机过夜是 Poltergeist 的主场景，`ask` 在无人值守时等于卡死。

## MCP 工具清单

### 只读工具

| 工具                        | 参数       | 返回                                               | 可用角色 |
| --------------------------- | ---------- | -------------------------------------------------- | -------- |
| `me()`                      | 无         | `{surface_id, role, work_mode}`                    | 全部     |
| `terminal_list()`           | 无         | 每终端一行 `{id, name, quiescence_ms, duty, mode}` | 总管     |
| `terminal_read(id, lines?)` | 终端与行数 | 可见屏幕或最近 N 行纯文本                          | 总管     |
| `group_read(group, since?)` | 群名与游标 | 消息数组                                           | 成员     |
| `group_list()`              | 无         | 自己所在的群名，已排序                             | 全部     |

`terminal_list` 给的是**静止时长这一个标量**，不做任何语义推断 —— 旧稿感知层的 working / thinking / idle / stalled 推断已废，见 [sensing.md](sensing.md)。返回里的 `duty` 字段是 [supervisor.md](supervisor.md) 的上班 / 下班簿记状态，不是对屏幕内容的判断，两者不要混为一谈。`terminal_read` 是 R1 的落点：总管靠它自己看内容、自己判断该叫还是该等。另有 `get_work_mode(id)` 与 `skill_read(name)` 两个只读工具，见后文。

### 写工具

| 工具                                           | 参数                 | 返回          | 可用角色 |
| ---------------------------------------------- | -------------------- | ------------- | -------- |
| `terminal_send(id, text, submit?)`             | 目标与文本           | ok / 拒绝原因 | 仅总管   |
| `clock_out(id, reason)`                        | 目标与理由           | ok / 拒绝原因 | 仅总管   |
| `set_quiescence_threshold(id, duration)`       | 目标与时长           | ok / 拒绝原因 | 仅总管   |
| `group_post(group, text)`                      | 群名与文本           | ok            | 成员     |
| `group_create(group)` / `group_destroy(group)` | 群名                 | ok / 拒绝原因 | 仅总管   |
| `group_add(group, id, history)`                | 群名/终端/是否给历史 | ok / 拒绝原因 | 仅总管   |
| `group_remove(group, id)`                      | 群名与终端           | ok / 拒绝原因 | 仅总管   |
| `group_compact(group, through, summary)`       | 群名/截止 seq/摘要   | ok / 拒绝原因 | 仅总管   |

`clock_out` 在无限工作模式下由程序直接拒绝，并把理由回给总管（不静默失败）—— 这是 R6 硬约束的落点。

**`set_work_mode` 不在工具面里**，只有只读的 `get_work_mode`。本表早先把它列为「仅总管」，与下文「只有用户能改工作模式」的论证直接矛盾；实现按后者落地（`src/poltergeist/Bus.zig` 的 `setWorkMode` 要求 `Authority.user`，`src/poltergeist/rpc.zig` 的 `Method` 里根本没有这一项，并有一条测试专门守着它别被加回来）。理由就是下文那句：总管若能改模式，只要先改再 `clock_out` 就绕过了 R6，硬闸等于没有。工作模式由用户在终端上设定。

`set_quiescence_threshold` 是 [sensing.md](sensing.md) 那条「per-terminal 阈值只能是运行时状态、不能进 `Config.zig`」结论的工具面落点：全局默认值走配置项 `polter-quiescence-threshold`，单个终端的覆盖值由总管在运行时调。它只影响「多久之后通知总管」这一个调参，不表达用户意图，因此不受 `set_work_mode` 那条「跨线只能用户改」的限制。时长解析可直接复用 `Duration`（`src/config/Config.zig:10047`，`parseCLI` 在 `:10085`）。

### terminal_read 的实现落点

首选 `Surface.dumpText(alloc, sel)`（`src/Surface.zig:1930-1938`）：它自己加渲染状态锁再转调 `dumpTextLocked`（`src/Surface.zig:1942`），底层走 `Screen.selectionString`（`src/Surface.zig:1948`）。选它的理由是输入为一个 selection，能精确表达「可见屏幕」或「最近 N 行」，且不受渲染态截断影响。

这条路径已经有 C 导出在跑：`ghostty_surface_read_text`（`src/apprt/embedded.zig:1641`），其 doc comment 明确写「这是昂贵操作，不应频繁调用，建议调用方缓存结果并对调用限流」（`src/apprt/embedded.zig:1636-1640`）—— 直接作为工具侧限流的依据，不用我们自己编。

两个备选均淘汰：`RenderState.string()`（`src/terminal/render.zig:855`）的 NOTE 说明视口上下被截断的软换行不包含在结果内（`src/terminal/render.zig:852-854`），读出来会缺行；`Screen.dumpStringAlloc()`（`src/terminal/Screen.zig:3613`）的注释自称是「主要为单元测试的便利版本」（`src/terminal/Screen.zig:3611-3612`），且 `dumpString` 自述「一次写一个字节」（`src/terminal/Screen.zig:3571-3573`），不适合当热路径 API。

「最近 N 行」具体怎么构造 pin 未定（未核实：从 viewport 底部往上数 N 行的 selection 构造方式，核实方式是读 `src/terminal/Selection.zig` 与 `src/apprt/embedded.zig` 里现有的 `Point` → selection 转换）。本章只定实现落点，不写构造代码。

### 权限矩阵与它的理由

- **总管**：全部工具，含两个不在上面两张表里的只读工具 `get_work_mode(id)` 与 `skill_read(name)`。
- **被监督终端**：`me`、`skill_read`，以及在它已被拉进的群里 `group_list` / `group_post` / `group_read`。**别的一个都没有** —— 没有 `terminal_send`，没有 `terminal_read`，没有 `clock_out`，也没有 `get_work_mode`。这份白名单是穷举的：新增工具默认落在总管一侧，要放给被监督终端必须显式改 `src/poltergeist/rpc.zig` 的 `requiresSupervisor`，那里有一条测试逐个方法核对。
- **`skill_read` 对所有终端开放**（本章早先写作总管专属，与实现相反，已按实现更正）。理由：skill 是说明书不是权限，读它不构成对任何终端的影响；而被监督终端读不到它，就无从知道自己为什么被叫。
- `me()` 里那个 `work_mode` 与 `get_work_mode(id)` 不冲突：前者只报**自己**的模式（服务端按 token 反查，不接受入参），后者能问**任意终端**的模式。被监督终端知道自己在哪种模式下工作是必要的，知道别人的则不是。
- 角色在配置里指定，不能由 AI 自己声明 —— 服务端按 token → surface_id → 配置查角色。

理由：若被监督终端能互相注入，一个跑偏的 agent 可以把它的偏差写进别人的输入框，形成级联；而所有终端都是同一个用户开的、彼此看起来完全可信，出事时没有任何一层能拦。单向星形拓扑（只有总管能写）把爆炸半径限制在一跳。

### set_work_mode 必须受限

若 `set_work_mode` 允许总管把一个终端从无限工作模式改成下班模式，R6 的「程序层禁止下班」就是纸糊的 —— 总管只要先改模式再 `clock_out` 即可绕过。

**本设计选择**：`set_work_mode` 只允许在无限工作模式的两个子型之间切换（定向无限 ↔ 接续无限），**不允许跨越「下班模式 / 无限工作模式」这条线**；跨线只能由用户在界面上改。理由：这条线是用户意图的表达，不是运行时状态。

**推翻条件**：若将来支持「n 小时后自动降级为下班模式」，那降级动作应由程序按用户预设配置执行，仍然不经过 AI。

## 输入注入机制

### 复用粘贴通道

拟走的调用链，逐跳如下：

1. `Surface.textCallback(text)`（`src/Surface.zig:3308`）。doc comment 写明：按剪贴板粘贴的同一套逻辑处理 —— bracketed 模式下做 bracketed paste，否则把换行过滤成 `\r`（`src/Surface.zig:3303-3307`）。
2. → `completeClipboardPaste(data, allow_unsafe)`（`src/Surface.zig:5914`）。调用点传的 `allow_unsafe` 是 `true`（`src/Surface.zig:3313`）——**这条路径跳过不安全粘贴确认**。
3. → `input.paste.encode`，把 NUL / BS / ESC / DEL 以及 `0x03` VINTR、`0x1A` VSUSP 等一批控制字节统一替换成空格，且不论是否 bracketed 都执行（`src/input/paste.zig:46-91`）。
4. → `queueIo` 逐段写入（`src/Surface.zig:5985-5990`）。readonly 的 surface 在这里被直接丢弃 `write_small` / `write_stable` / `write_alloc` 三类消息（`src/Surface.zig:872-885`）。

**就地结论**：选这条路径而不是自己往 pty 写，是为了自动继承第 3 跳的控制字节剥除 —— 否则注入文本里一个 `\x03` 就能给对面发 Ctrl+C。但要写准：继承的是 bracketed 封装与控制字节剥除，**不是**不安全粘贴确认弹窗。

参照物：键绑定层的 `text: []const u8` action（`src/input/Binding.zig:333`，doc comment 自述内容目前未做校验）走的是另一条更直的路 —— `configpkg.string.parse` 之后直接 `queueIo`（`src/Surface.zig:4873-4888`），**不经过 paste 封装**。本设计不选它，正因为它绕过了控制字节剥除。

### 回车为什么必须单独合成

- bracketed paste 开启时，`encode` 把整段数据夹在 `\x1b[200~` 与 `\x1b[201~` 之间**直接返回**，中间的 `\n` 原样保留（`src/input/paste.zig:95-99`）。收到 bracketed paste 的 TUI 按约定把它当**字面文本**塞进输入框，不当提交。
- 只有非 bracketed 时才把 `\n` 全部替换成 `\r`（`src/input/paste.zig:101-108`）。
- 上游自己也这么说：`ghostty_surface_text` 的注释写「这被当作粘贴处理，因此不适合发转义序列；那种情况应该用单独的按键输入」（`src/apprt/embedded.zig:1819-1821`）。

因此 `terminal_send(id, text, submit=true)` 拟做成两步：文本走 `textCallback`，回车合成一个 `input.KeyEvent` 走 `keyCallback`（`src/Surface.zig:2674`）→ `encodeKey`（`src/Surface.zig:3208`）。

### 原子性与竞态守卫

文本与回车两步必须作为一个不可分割的操作提交，否则用户在两步之间敲的字符会被一起提交出去。

可用的抓手：`queueIo` 与 `Termio.queueMessage` 都带一个 `MutexState` 参数（`src/termio/Termio.zig:397-407`），`.locked` 会把 `renderer_state.mutex` 传给 `mailbox.send`；同一个 doc comment 还给出了批量提示 —— 「如果你要发很多消息，直接用 mailbox 再单独调 notify 可能更高效」（`src/termio/Termio.zig:394-396`）。（未核实：现有代码里没有把两条不同来源的写请求打成一个原子批次的原语，是否需要新增，核实方式是读 `src/termio/mailbox.zig` 的 send 语义与 `BlockingQueue` 的批量接口。）

注入前后各取一次屏幕指纹用于回环识别：紧跟注入之后的屏幕变化是我们自己造成的，不应被当成「对方动了」。更完整的守卫规则（用户正在打字、输入框非空、总管自我注入）归 [supervisor.md](supervisor.md)。

## 群的模型：只有总管能拉群，没有私聊

**私聊被取消了。**两个终端之间的对话就是一个只有两个成员的群，这样只有一套规则而不是两套 —— 少一套语义、少一处权限矩阵、少一类边界情况。

**建群、拉人、踢人、压缩历史都只有总管能做。**理由与「谁被监督由总管安排」同源：一个能自己建群并把别人拉进来的终端，是在搭一套用户从未设立的结构。但**群内说话不需要总管批准** —— 权限的界线不是读写，而是「这个调用会不会把东西塞进别人的输入框」。`group_post` 不会：对方只被告知有新消息，去不去看是它自己的决定。

**拉人进群时总管选择它能否看到历史。**`history: none`（默认）让对话从此刻对它开始；`history: all` 把日志里还在的全部交给它。默认是 `none`，因为把一整夜的背景灌给一个刚被叫来干活的 agent，吃掉的是它本该用在自己活上的上下文。已在群里的终端被重复 `group_add` 不会改变它的可见范围 —— 否则一次误操作就能把它当初被特意挡在外面的历史递给它。

**总管可以压缩群历史**（`group_compact`），等同 `/compact`：把截止某个 seq 的消息换成一段摘要。分工照旧 —— **摘要由总管写**（判断一段对话到底讲了什么，代码做不到），**替换由程序做**（正确地重写日志，不该交给提示词）。摘要继承它所替换的最后一条消息的 seq，所以还没跟上的成员读到的是摘要而不是一个空洞。

## 消息送达：只送通知，不送正文

**本设计选择**：群聊 / 私信有新消息时，只向目标终端注入一行「你有 N 条新消息，用 `group_read` 拉取」，**不注入正文**。

两条各自独立成立的理由：

1. **正文可能很长。**群聊里几个 AI 互相贴日志片段，一次注入就能吃掉对方相当一截上下文，而对方的上下文主要该用在它自己手头的活上。
2. **让 AI 自己决定要不要看。**主动拉取这个动作本身带判断力 —— AI 会根据自己的进度决定现在看还是做完再看。被动注入等于替它做了「现在必须处理」的决定。

**代价写实**：多一次工具往返，延迟从「注入即到」变成「注入通知 + 一次拉取」。挂机场景的尺度是分钟而非毫秒，可以接受。

限流照抄现成写法：`showDesktopNotification`（`src/Surface.zig:6038`）用 Wyhash 摘要加时间戳实现「每秒最多一条」与「相同内容 5 秒内抑制」两道阈值（`src/Surface.zig:6045-6070`）。通知注入应复用同一形状。界面怎么呈现这些消息见 [chatui.md](chatui.md)。

## Skill 体系

### skill 是提示词，不是状态机

> **已定**：用户在设计评审中确认 skill **给总管 AI 读**，即采用本节的提示词方案。此项不再是待议项。

监工模式在实现上拟劈成两半：

- **判断部分是 skill 文本，给总管 AI 读。**「连续 n 次执行后判断没必要再继续」里的「没必要」是语义判断，写成程序判据就会随被监督程序的 UI 改版一起烂掉。
- **约束部分是程序硬闸。**无限工作模式禁止 `clock_out`，由服务端拒绝，不写进提示词。理由直白：提示词会被长会话的上下文冲掉，程序不会 —— 而挂机过夜恰恰是上下文最容易被冲掉的场景。

因此三种模式 = 三份 skill 文本 + 一张「模式 → 是否允许 `clock_out`」的程序侧映射表。

### 一共几个，怎么分

**5 个：2 个通用 + 3 个模式。**分法不按主题，按**什么会让它改变**：

| skill                      | 内容                                                         | 何时需要改                   | 何时被读           |
| -------------------------- | ------------------------------------------------------------ | ---------------------------- | ------------------ |
| `supervising`              | 总管行事总则：收到通知先做什么、何时袖手、怎么措辞、两条红线 | 监督策略变时                 | 成为总管时一次     |
| `reading-a-terminal`       | 怎么看一屏内容判断对方处于什么状态                           | **被监督的 AI CLI 改界面时** | 每次判断前         |
| `mode-clock-out`           | 下班模式的判据                                               | 用户想改下班标准时           | 按该终端的模式加载 |
| `mode-infinite-directed`   | 定向无限的判据                                               | 同上                         | 同上               |
| `mode-infinite-sequential` | 接续无限的判据                                               | 同上                         | 同上               |

**为什么把 `reading-a-terminal` 单独拎出来。**它是整套东西里唯一会自然腐烂的部分 —— 被监督的 agent CLI 改一次界面，判断依据就失效一次。隔离之后，用户换个 agent CLI 只需要改这一个文件，不必碰监督策略；反过来调整监督策略也不会碰坏识别逻辑。若按主题切（例如「判断类 / 动作类」），得不到这个性质。

**为什么三个模式 skill 不合并。**它们是按终端各自加载的：一个总管可能同时管着三种模式的终端，合成一份会让它每次都读到大量与当前终端无关的判据。

**为什么不再多切。**确认策略与通知时段（R3）看起来也够一个 skill，但它对应的程序机制尚未实现；为还不存在的行为写 skill 会让读它的 AI 以为自己能做到。等 R3 落地再加第 6 个。

### frontmatter 里没有 allow_clock_out

结构示意里早先带过这个字段，现已删除。「无限工作模式禁止下班」已经是程序硬闸（`src/poltergeist/Bus.zig` 的 `WorkMode.forbidsClockOff`），同一条约束有两个出处必然漂移；更糟的是 skill 文件用户可编辑，若程序采信文件里的值，用户改 skill 时就可能**无意中削弱一条安全约束**。硬闸只能有一个出处，而且必须在代码里。

frontmatter 只保留程序真正要读的：`name` / `mode` / `version` / `max_rounds` / `description`。正文原样交给 AI。

### 「连续 n 次」由程序计数，判断交给 AI

R6 要求「连续 n 次执行后判断没必要再继续」。次数正是长会话里最容易被上下文冲掉的东西，而计数恰恰是程序擅长、提示词不擅长的。

落法：Bus 记录「自上次 `resumed` 以来这个终端被通知过几轮」，随 `terminal_list` 一并给出；skill 文本写「当 rounds 达到 max_rounds 且你仍看不出还有事可做时，让它下班」。程序供数，AI 供判断 —— 与整套设计的分工一致，且不需要新增工具。

### 存放位置与优先级

照搬 themes 的两层结构：`themepkg.Location = { user, resources }`，注释明说枚举顺序即优先级、从上到下（`src/config/theme.zig:8-12`）；user 层由 `internal_os.xdg.config` 拼出、subdir 为 `ghostty/themes`（`src/config/theme.zig:30-35`）。

**本设计选择**：内置默认 skill 放 resources 层，用户自定义放 `$XDG_CONFIG_HOME/ghostty/polter/skills/`，同名时 user 覆盖内置。三条理由：与 themes 完全同构，用户已有心智模型；user 目录可进 dotfiles 仓库，天然版本化；内置层随二进制升级，用户层不被覆盖。

**为什么不塞进 `src/config/Config.zig`**：该文件已 11120 行，且配置项是扁平 KV，而 skill 主体是多段自然语言 —— 塞进去要么变成超长单行字符串，要么要发明一套多行块语法。配置里只留一个指向 skill 名字的键。**为什么不编译进二进制**：R7 要求可维护、用户能改能加，编译进去直接违背。

### 结构示意

实际的内置 skill 在 `src/poltergeist/skills/`，安装到 `share/ghostty/poltergeist/`。下面是其中一份的开头：

```md
---
name: mode-clock-out
version: 1
mode: clock_off
max_rounds: 5
description: 下班模式：连续若干轮判定无事可做后让终端下班
---

每轮先用 terminal_read 看这个终端现在的屏幕内容，再判断……
（正文原样交给总管 AI 读，程序不解析。）
```

选 YAML frontmatter 加 Markdown 而不是自造 KV 格式，理由是**程序只需要读 frontmatter 里那几个字段**（`mode` / `allow_clock_out` / `max_rounds` / `version`），正文原样丢给 AI，解析成本几乎为零；而这个格式恰好是 AI 侧 skill 生态的通行写法，用户不用学新东西。

### 怎么被总管取用与怎么维护

两个候选：(i) 建立监督关系时一次性注入总管上下文；(ii) 总管通过 MCP 工具按需读。**选 (i) 为主、(ii) 为辅** —— 监工模式是每轮都要用的判据，纯按需读等于每轮多一次往返；但保留一个 `skill_read(name)` 只读工具，让总管在上下文被冲掉后能自己找回来。

维护上：内置 skill 随仓库走，改动可 review；用户 skill 放进目录即生效。frontmatter 里的 `version` 应记进日志，便于事后复盘「为什么它当时判定下班」。（未核实：用户改了 skill 文件后是否需要重启 Ghostty —— themes 的加载时机本文只核实了查找路径未核实触发时机，核实方式是读 `src/config/Config.zig` 的 theme 载入调用点与配置重载路径。）

## 边界：Poltergeist 不管理任务

四条禁令，正面回答 R8：

1. **不提供任何任务 CRUD 工具** —— 工具清单里没有 `task_create` / `task_list` / `task_update` / `task_done`。
2. **不持久化任务内容** —— Poltergeist 会落盘的只有聊天记录（落点见 [chatui.md](chatui.md)）与审计日志（见 [supervisor.md](supervisor.md)）；监督关系、监工模式、静止阈值按 [supervisor.md](supervisor.md) 的选择只活在 Ghostty 进程内存里、不落盘（是否需要跨重启持久化见本章未决问题 6）。无论落盘与否，都没有任务体。
3. **不解析任务描述** —— 不从屏幕里提取「当前任务是什么」。
4. **不做任务排序或依赖** —— 没有队列、没有优先级、没有 DAG。

任务由其他系统 / 载体承载（看板、文件、issue 追踪器），AI 自己去读。

**代价写实**：总管看不到任务全貌，它能拿到的只有屏幕内容（`terminal_read`，底层是 `Surface.dumpText`，`src/Surface.zig:1930`）与聊天记录（`group_read` / `dm_read`），所以总管的判断天然是「就地可见」的判断，做不了跨任务的全局调度。

**为什么仍然值得**：任务载体种类繁多且每家 schema 不同，做进来必然做成半吊子；更糟的是会和用户已有的任务工具打架 —— 同一个任务出现在两处、状态不同步，用户要维护两份真相。把这条边界画死，Poltergeist 就永远只是一层能力，不会长成一个竞品任务系统。这条边界同时是工具面稳定性的来源：只要不碰任务，工具清单就不会随任务系统的演进而膨胀。

## 取舍记录

| 方案                                       | 成本                                                                                    | 为什么没选 / 为什么选                                                                                             |
| ------------------------------------------ | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **选**：sidecar `ghostty +polter-mcp`      | 三处枚举登记 + 一个新文件（`src/cli/ghostty.zig:31-190`），无构建改动                   | 崩溃隔离；协议演进不动终端二进制；集成成本近乎为零                                                                |
| MCP server 塞进 Ghostty 核心               | 长连接状态挤进渲染 / IO 线程；每次协议改版动核心                                        | 核心崩了影响全部终端；与上游分叉面变宽                                                                            |
| 传输 (a) 扩展 `apprt.ipc` 并补 macOS       | 要给 union 加返回值通道；同步 `include/ghostty.h` 的 C ABI（`src/apprt/ipc.zig:57-71`） | macOS 三分支全 false（`src/apprt/embedded.zig:349-360`）；且它是单向命令通道，形状不对                            |
| **选**：传输 (b) 自建 unix socket          | 自管监听 / 鉴权 / 生命周期 / 崩溃清理；`src/` 现无 `std.net` 代码                       | 跨平台一份实现；请求-响应形状天生正确；与上游零耦合，分叉面最小                                                   |
| 传输 (c) 文件系统 / 命名管道               | 轮询有延迟，或上 inotify / FSEvents 变两套平台代码                                      | 并发写、残留文件、权限位都要自己兜，省下的复杂度会换个形式还回来                                                  |
| 传输 (d) 复用 macOS AppleScript            | 已有 `input text` / `send key`（`macos/Ghostty.sdef:221`、`:229`）                      | macOS-only；需 osascript 往返；**没有宿主 → sidecar 的推送方向**                                                  |
| **选**：鉴权用 bool 准入闸门（默认关）     | 一个配置项 + 各入口 gate                                                                | 照抄 `macos-applescript`（`src/config/Config.zig:3489`）的形态；默认值反过来取关，未配置的 Ghostty 不多出受攻击面 |
| 鉴权用 `allow` / `ask` / `deny` 三态       | 与 `clipboard-read`（`src/config/Config.zig:2454`）同构                                 | 挂机过夜无人值守时 `ask` 等于卡死                                                                                 |
| **选**：读屏用 `Surface.dumpText`          | 自带渲染锁，输入是 selection（`src/Surface.zig:1930`）                                  | 能精确表达「最近 N 行」；不受渲染态截断影响                                                                       |
| 读屏用 `RenderState.string`                | 现成                                                                                    | 视口上下被截断的软换行不含在内（`src/terminal/render.zig:852-854`），会缺行                                       |
| 读屏用 `Screen.dumpStringAlloc`            | 现成                                                                                    | 注释自称主要供单元测试（`src/terminal/Screen.zig:3611-3612`），且一次写一字节                                     |
| **选**：注入走 `textCallback` 粘贴通道     | 多一跳编码                                                                              | 自动继承控制字节剥除（`src/input/paste.zig:46-91`），`\x03` 不会变 Ctrl+C                                         |
| 注入走键绑定 `text` action 的直写路径      | 更短                                                                                    | 绕过 `input.paste.encode`（`src/Surface.zig:4873-4888`），无剥除                                                  |
| **选**：消息只注入通知                     | 多一次工具往返（先注入通知，再等对方拉取）                                              | 不吃对方上下文；主动拉取本身带判断力                                                                              |
| 消息注入正文                               | 零往返                                                                                  | 长正文灌爆对方上下文；替 AI 做了「现在必须处理」的决定                                                            |
| **选**：skill 存 user + resources 双层     | 一套查找逻辑                                                                            | 与 themes 同构（`src/config/theme.zig:8-12`）；可进 dotfiles；升级不覆盖                                          |
| skill 塞进 `src/config/Config.zig`         | 该文件已 11120 行；扁平 KV                                                              | 多段自然语言塞不进 KV，要么超长单行要么发明多行块语法                                                             |
| skill 编译进二进制                         | 最省运行时                                                                              | 直接违背 R7「可维护、用户能改能加」                                                                               |
| **选**：判断在提示词、约束在程序           | 两处维护                                                                                | 语义判断会随 UI 改版烂掉；而提示词会被长会话冲掉，程序不会                                                        |
| 监工模式做成纯程序状态机                   | 可测试                                                                                  | 「没必要再继续」是语义判断，写死判据随被监督程序改版失效                                                          |
| **选**：`set_work_mode` 跨模式线只能用户改 | 少一个自由度                                                                            | 否则总管先改模式再 `clock_out` 就绕过了 R6 的程序硬闸                                                             |
| **选**：不提供任何任务工具                 | 总管做不了跨任务全局调度                                                                | 任务载体 schema 各异必成半吊子；与用户已有工具打架会产生两份真相                                                  |

## 未决问题

1. 服务端线程在 Ghostty 进程内挂在哪一层 —— 是否存在可复用的 app 级后台循环，还是需要新起一条线程再经 `App.Mailbox.push`（`src/App.zig:617-623`）回主线程。
2. sidecar 的进程模型 —— 每个 AI 进程起一个实例（stdio transport），还是一个常驻实例多路复用。本设计倾向前者且不负责其生命周期（由 AI 客户端按其 MCP 配置拉起），但仓库内无可参照先例。
3. 文本与回车两步的原子提交是否需要新增批量写入原语（见「原子性与竞态守卫」）。
4. 「最近 N 行」的 selection / pin 构造方式。
5. skill 文件改动后的生效时机 —— 是否需要重启，能否复用配置重载路径。
6. 监督关系与角色配置是否需要跨 Ghostty 进程重启持久化，还是每次挂机重设一遍（与 `README.md` 未决问题 4 同源）。

## 延伸阅读

- [README.md](README.md) — Poltergeist 设计总览与五章索引。
- [\_spec.md](_spec.md) — 写作规范与统一术语表。
- [sensing.md](sensing.md) — 静止时长怎么测。
- [supervisor.md](supervisor.md) — 监督关系、监工模式、确认策略、竞态守卫。
- [chatui.md](chatui.md) — 群聊与私信界面。
- [tabs.md](tabs.md) — tab 合并与状态标记。
- [platform-and-config.md](../platform-and-config.md) — Ghostty 配置系统现状。
- [architecture.md](../architecture.md) — Ghostty 模块地图与线程模型。
