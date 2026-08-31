# Poltergeist MCP 工具面与 Skill 体系

> 最后更新对应的 git commit：`eaf10edef`（可达性规则改写与 `terminal_key` 这一轮改动尚在工作树里，未提交）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**已实现**（S2）。工具面在 `src/poltergeist/rpc.zig`，线协议在 `wire.zig`，socket 与 token 在 `Server.zig`，sidecar 在 `src/cli/mcp.zig`，Skill 体系在 `skill.zig` 与 `skills/`。**本章若与代码不一致，以代码为准**：下面几节是设计推导，实现与它的出入记在各节的「实现与本章的出入」里。

## 本章覆盖什么

- MCP 承载形态：为什么是 sidecar 进程 `polter +mcp`，而不是把 MCP server 塞进 Ghostty 核心。
- sidecar 怎么认领身份、怎么连回宿主进程；传输层四选一与鉴权形态。
- 完整 MCP 工具清单、参数 / 返回 / 角色权限矩阵，以及可达性规则为什么只看被干涉的那一方。
- 输入注入机制：复用粘贴通道，以及回车为什么必须单独合成。
- 消息送达语义：只送「有新消息」的通知，不送正文。
- Skill 体系（R7）：存哪、什么格式、谁读、怎么维护。
- 边界（R8）怎么落实成「工具面里没有什么」。

## 本章不覆盖什么

- 静止时长怎么测出来、成本多少、阈值怎么定 —— 见 [sensing.md](sensing.md)。本章只消费这一个标量。
- 监督关系怎么建立、「按住」是什么、确认策略、通知时间段、停掉监控 —— 见 [supervisor.md](supervisor.md)。
- 竞态守卫在总管侧的完整规则（用户正在打字、输入框非空、总管自我注入）—— 见 [supervisor.md](supervisor.md)。本章只给注入侧的机械保证。
- 安全边界，含 R2「明确不做自动点 yes」为什么不留任何口子 —— 见 [supervisor.md](supervisor.md)。本章的 `terminal_send` 只是通用文本注入原语，工具面里没有、也不会有任何「替对方回答权限询问」的专用工具。
- 群聊 / 私信的**界面**怎么画 —— 见 [chatui.md](chatui.md)。本章只定义消息的工具面与送达语义。
- tab 合并与状态标记落到 macOS / GTK —— 见 [tabs.md](tabs.md)。
- 写作规范与术语表 —— 见 [\_spec.md](_spec.md)。

## 一句话概括

Poltergeist（能力层）的控制面是一个跟着 AI 进程跑的 sidecar：`polter +mcp` 作为 MCP server，靠宿主已注入的 `GHOSTTY_SURFACE_ID`（`src/Surface.zig:677-681`）认领身份，经本地 unix socket 连回宿主 Ghostty，把「读屏 / 注入 / 群聊私信 / 打下班标记」四类能力暴露给 AI；怎么判断落成 skill 文本，硬约束则落在程序里。

## 设计目标与约束

- **R7** —— Skill 体系集成在 Poltergeist 里、可维护。
- **R8** —— 不管理任务：工具面里必须没有任务 CRUD。**这一条后来被改写了一半**，见 [tasks.md](tasks.md) 第一节：面板存「谁在做哪件事」，不存那件事本身。下面这一章保留原文与原论证，因为它怕的东西仍然对；改写的只是界线画在哪。
- **R6 的硬约束** —— 被用户按住的终端，`clock_out` 由程序拒绝，不靠提示词自觉。
- 承接旧设计里仍成立的多终端互通能力：读屏、群聊、私信。

**两处与 README 的分工在此重申。**其一，「消息送达只注入通知、不注入正文」的机制层面（为什么只送通知、限流形状、拉取工具）归本章，chatui.md 只留界面呈现。其二，注入路径继承的是 bracketed 封装与控制字节剥除，**不是**不安全粘贴确认，详见下文「复用粘贴通道」。README 的对应两条已按此口径同步，若日后再次出现分歧，以本章为准。**通知送给谁**，则归 [tasks.md](tasks.md) 第六节：被监管的终端不因群消息被叫醒——它的注意力归它的总管。未读计数不受影响，`group_read` 照样读得到全部。

## 承载形态：sidecar 进程 polter +mcp

### 为什么不把 MCP 塞进 Ghostty 核心

- Ghostty 核心是渲染敏感的 Zig 代码，每个 surface 有独立的渲染线程与 IO 线程。把一个长连接 JSON-RPC 服务端塞进这条路径，意味着解析、超时、重连都要挤进已有的事件循环。
- MCP 协议的演进节奏与终端无关。绑进核心等于每次协议改版都要动一次终端二进制，与上游 ghostty-org/ghostty 的分叉面直接变宽。
- sidecar 崩了只影响一个 AI 会话；核心崩了影响全部终端。

### 集成成本：`+<action>` 是仓库既有的成熟模式

拟按现有 CLI action 惯例落地，逐跳如下：

1. 在 `Action` 枚举里加一项（`src/cli/ghostty.zig:33-94`，当前 21 项，从 `version` 到 `mcp`——最后两项 `chat` 与 `mcp` 就是这样加进去的）。
2. 在 `runMain` 的 switch 里加一条分发（`src/cli/ghostty.zig:160-184`）。
3. 新建 `src/cli/mcp.zig` —— 文件路径由 `Action.file()` 从枚举名机械推导，把 `-` 换成 `_` 再加 `cli/` 前缀与 `.zig` 后缀（`src/cli/ghostty.zig:188-200`）。
4. 帮助文本**不用手写注册**：`helpgen` 在构建期 `inline for` 遍历 `Action` 枚举字段、`@embedFile` 每个 action 源文件、找到名为 `run` 的函数并要求其前必须有 doc comment，否则直接报错（`src/helpgen.zig:82-100`）。这条规则写在 `src/cli/README.md:11-13`。
5. 参数解析要求 action 以 `+` 开头且一次只能出现一个，否则返回 `MultipleActions` / `InvalidAction`（`src/cli/action.zig:47-51`）。

**就地结论**：新增一个 CLI action 的边际成本是「三处枚举登记 + 一个新文件」，没有构建系统改动。这是选 sidecar 而非内置最直接的工程理由 —— sidecar 在这里不是架构洁癖，而是更省。

**推翻条件**：若 MCP 的延迟要求降到毫秒级、或需要在核心里维持大量长连接状态，sidecar 的往返成本才会成为问题。当前场景（挂机过夜）的时间尺度是分钟，不会触发。

MCP 协议本身的帧格式、`initialize` 握手、`tools/list` 与 `tools/call` 的确切 schema 不来自本仓库，本章不复述（未核实：实现按规范写成，但没有对着官方 schema 逐条比对过，也没有接过真实 MCP 客户端）。实现见 `src/cli/mcp.zig`。

## 身份识别：现状代码已经解决了

- `Surface.id: u64` 的 doc comment 直说它是给 IPC 用的唯一 ID，会以环境变量 `GHOSTTY_SURFACE_ID` 暴露给 surface 里运行的命令，且不得为零（`src/Surface.zig:55-60`）。
- 注入点与格式：`0x{x:0>16}`（`src/Surface.zig:677-681`）；同一段代码先主动摘掉了 `GHOSTTY_LOG`（`src/Surface.zig:674-675`）。
- **现成先例**：`ghostty +new-tab` 在未提供 `--surface-id` 时就是从该环境变量读、`parseUnsigned(u64, e, 0)`、失败回落 0（`src/cli/new_tab.zig:247-252`）。sidecar 认领身份照抄这段即可。

**就地结论**：不新增环境变量，也不让 AI 自报家门。**身份来自宿主注入而非 AI 声明**，这条同时是后面权限矩阵的地基 —— AI 无法伪造自己是哪个终端。

顺带一提既有注入：`GHOSTTY_RESOURCES_DIR`（`src/termio/Exec.zig:638`）、`GHOSTTY_BIN_DIR` 并把 ghostty 可执行文件目录追加进子进程 `PATH`（`src/termio/Exec.zig:692-711`）、`GHOSTTY_SHELL_FEATURES`（`src/termio/Exec.zig:775`）。`PATH` 那条的实际含义是：AI 进程里直接敲 `polter +mcp` 就能命中二进制，MCP 客户端配置不必写绝对路径。

## 传输层选型

### 现成 IPC 为什么不能复用

两条各自独立致命的硬伤：

1. **macOS 完全没实现**。embedded apprt 的 `performIpc` 三个分支全部 `return false`（`src/apprt/embedded.zig:349-360`）；只有 GTK apprt 走 D-Bus。主场景是 macOS，这一条就已经出局。
2. **它是单向命令通道，不是 RPC**。`apprt.ipc.Action.Key` 只有 `new_window` / `new_tab` / `toggle_quick_terminal` 三项（`src/apprt/ipc.zig:176-179`），`performIpc` 的返回类型只有 `bool`（`src/apprt/embedded.zig:349-354`）——「发出去了没有」，不是「结果是什么」。GTK 实现给 `callSync` 的 reply type 传 `null`，注释原文是 `We don't care about the return type, we don't do anything with it.`（`src/apprt/gtk/ipc/DBus.zig:171`）。而工具面里的 `terminal_read` / `terminal_list` 必须带结构化返回。

第 2 条比第 1 条更根本：就算给 macOS 补上实现，这条通道的形状仍然不对。

### 四个候选与结论

**本设计选择 (b) 自建 unix socket 服务端。**跨平台一份实现、请求-响应形状天生正确、与上游代码零耦合 —— 仓库 `src/` 下目前没有任何 `std.net` 代码（grep 无命中），这是纯新增而非改造上游文件，分叉面最小。

被淘汰的三个及理由列在本章末尾的取舍记录。其中 (d)「复用 macOS 既有 AppleScript 通道」值得单独说明：仓库已有完整的 scripting 字典，`input text`（`macos/Polter.sdef:221`）与 `send key`（`macos/Polter.sdef:229`）两个命令齐备，终端枚举 `terminals`（`macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift:92`）与按唯一 ID 查找 `valueInTerminalsWithUniqueID:`（同文件 `:104`）也齐备，且 `input text` 最终落到 `surface.sendText`（`macos/Sources/Features/AppleScript/ScriptInputTextCommand.swift:38`）—— 与本设计的注入路径同源。淘汰它作为传输层的理由是：macOS-only（GTK 无对应物）、要经 `osascript` 往返、且**没有从宿主推给 sidecar 的方向**，静止通知推不出去。但它的配置闸门模式必须照抄，见下。

**推翻条件**：若上游把 `apprt.ipc` 改造成带返回值的 RPC 并给 macOS 补齐实现，(b) 就应让位给 (a)，那时自建通道纯属重复。

服务端线程挂在 Ghostty 进程内的哪一层尚未定（未核实：是否存在 app 级、与 surface 无关的可复用后台循环，核实方式是通读 `src/App.zig` 的 create / run 与各 apprt 的 run 实现；libxev 是否导出 socket accept 类型也需另行核实）。已确定的是回到主线程的入口：`App.Mailbox.push` 在入队后立即调用 `rt_app.wakeup()` 唤醒事件循环（`src/App.zig:3499-3505`）。

### 鉴权

- **只监听 unix socket，绝不开网络端口**。否则本机任意进程都能操控用户的所有终端。
- socket 路径与一次性 token 一起注入子进程环境；sidecar 连上后先出示 token。token 与 surface 绑定，**`me()` 的返回值由服务端根据 token 决定，不接受客户端自称**。
- socket 放在 XDG state 目录下 —— `internal_os.xdg` 已提供 `config` / `cache` / `state` 三个入口（`src/os/xdg.zig:22`、`:31`、`:40`）。
- **实现与本章的出入：socket 文件没有 chmod 0600，而且是有意不做。** 本章早先写「权限 0600」，与实现相反。`Server.init` 里明确写着不做 chmod，理由是 **socket 文件权限在 Ghostty 支持的各个系统上执行得并不一致，把它当成边界是一种虚假的安心**。真正的边界是 token：每个终端 32 字节新鲜熵，常数时间比对，从调用方看得到的任何东西都推不出来。（`chat.jsonl` / `session.json` 那些**确实是** 0600——它们的内容本身就是要防的东西，而 socket 防的是「谁握着 token」。）

- **一个顶层配置项作为准入闸门**。形态照抄 `macos-applescript`：一个 bool 配置项（`src/config/Config.zig:3705`），所有入口先过一次 gate，被拒时返回明确错误而不是静默失败（`macos/Sources/Features/AppleScript/AppDelegate+AppleScript.swift:300-316`，`validateScript` 置 `errAEEventNotPermitted` 并给出错误串）。理由：这是仓库里已被接受的「外部进程可以操控终端，但用户能否决」的先例，照抄比自创便宜，且用户已理解这个心智模型。
- **照抄的是形态，不是默认值。**`macos-applescript` 自身默认 `true`（`src/config/Config.zig:3705`），本设计的闸门拟**默认关**：它放行的是「向用户所有终端注入文本」，默认关意味着未配置过的 Ghostty 与今天行为完全一致、不多出任何受攻击面；而 R5 的流程里用户本来就要显式指定总管与监督范围，多改一个配置项不构成额外负担。
- **这个闸门不是 R4 说的那种开关。**它是一次性准入授权（装没装、准不准外部进程连进来），不是运行时的启停；R4 针对的「停掉监控」是唯一的停止动作，归 [supervisor.md](supervisor.md)。两者可以并存：闸门开着，用户照样随时停掉监控。
- **不做 `allow` / `ask` / `deny` 三态**。Ghostty 对剪贴板确实有三态，`clipboard-read` 默认 `ask`（`src/config/Config.zig:2670`），但挂机过夜是 Poltergeist 的主场景，`ask` 在无人值守时等于卡死。

#### socket 文件的生老病死

socket 路径每次运行都是新的随机名（`polter-<16 位十六进制>.sock`）。**而一个
socket 文件不会因为绑它的进程死了就消失**——所以这个状态目录一度堆到 60 个死文件，
最早的隔了半个月，人进去找 `chat/` 或 `session.json` 得先翻过它们。

现在两头都收：`Server.deinit` 走的时候删掉自己那条路径；`Server.sweepStale` 在
**绑自己那条路径之前**扫一遍同一个目录（所以永远不会探到自己）。

**判据是「连不上」，不是「文件旧」，这一条是硬的。** 一个活着的 Polter 的 socket
同样是 0 字节、同样有个普通的 mtime，在磁盘上和上个月死掉的那个**长得一模一样**；
唯一分得开它们的办法是 connect 一次。所以：

| connect 的结果 | 处置 |
| --- | --- |
| `ECONNREFUSED` | **删**——文件是 socket，而那头没有 listener |
| 连上了 | 留（立刻 close） |
| `ENOENT` | 跳过——它在列目录和探测之间没了，没东西可删 |
| 权限错、任何不认识的 errno | **留** |

**默认方向是留，不是删。** 删掉一个活实例的 socket 会把它托管的每个 agent 从
app 上切断；留一个死文件只多一行目录列表。两边的代价差几个数量级，所以「只有明确
证明那头没人才删」。另外名字对不构成所有权证明：还要 `stat` 确认它真是
`unix_domain_socket`，且不跟随符号链接。

connect 探测对活着的那一头是**无声的**：它看到的是一个握手前就挂断的客户端，
`handshake` 读不到行直接返回，连接线程退出，不写日志、不产生 `Pending`、不碰 bus。


## MCP 工具清单

### 只读工具

| 工具                        | 参数       | 返回                                               | 可用角色 |
| --------------------------- | ---------- | -------------------------------------------------- | -------- |
| `me()`                      | 无         | 自己那一行终端信息（见下「终端信息带什么」）        | 全部     |
| `terminal_list()`           | 无         | 每终端一行（见下「终端信息带什么」），被监督的另带 `quiet_ms` 与 `rounds` | 全部     |
| `notices()`                 | 无         | 尚未被看过的情况，一行文本；空表示没有            | 总管     |
| `terminal_read(id, lines?)` | 终端与行数 | 可见屏幕或最近 N 行纯文本                          | 按可达性 |
| `group_read(group, since?)` | 群名与游标 | 消息数组                                           | 成员     |
| `group_history(group, before_seq?, limit?)` | 群名与日志游标 | 群里已经不留的更早消息，取自磁盘日志；这一批的 `seq` 恒为 0，翻页只能用 `log_seq` | 成员 |
| `group_list()`              | 无         | 自己所在的群名，已排序                             | 全部     |
| `group_members(group)`      | 群名       | 群里有谁，按 id 排                                 | 成员     |
| `session_recall()`          | 无         | 上次关机前写下的现场材料，只读，没有任何东西照它接线 | 总管     |
| `skill_read(name)`          | skill 名   | 那份 skill 的正文                                  | 全部     |
| `config_get(key?)`          | 配置键，省略为全部 | 用户配了什么，只读                        | 总管     |
| `plugin_list(key?)`         | 插件名，省略为全部 | 每插件一行：装没装、开没开、**订阅了什么**、声明调什么、参数以什么形式配着；有实例在跑的另带 `state` / `cursor` / `failures` | 总管 |

**`plugin_list` 的脱敏规则，三条，穷尽：**

1. **引用（`env:` / `file:` / `keychain:` / `cmd:`）原样回显。**秘密住在哪不是
   秘密，而总管**不看见就分不出**一个写错的变量名和一个对的——那恰恰是它被
   要求去帮用户做的事。
2. **明文值只在 `enum` 把参数钉死在一个封闭集合上时回显。**封闭集合装不下
   密码，这是唯一安全的一种。
3. **其它明文值一律只报"配着"，不报是什么**，`secret` 标没标都一样。
   **`secret` 只收紧写、从不放宽读**：作者漏标是常态（一个 webhook 插件的 `url`
   长得完全不像密码，但拿到它就能以用户的名义发东西），而回显是不可逆的——那一屏
   此刻可能正在被另一个 agent `terminal_read`。漏标的代价因此是丢掉写的那条
   规则，不是丢掉读的那条。

**没有 `kind` 字段了。** 一个插件是什么由 `wants.events` 说了算，而那是一个
**列表**——一个插件可以同时订阅两种事件，那在 `kind` 的世界里根本表达不出来。
读的人要问「这是不是一条通知渠道」，就看 `terminal.quiet` 在不在里面。
（macOS 设置界面手抄那个枚举、抄漏两次的经过见 [plugins.md](plugins.md) 第一节。）

**字段缺席的约定与 `terminal_list` 同一条**：没有实例在跑的插件，
`state` / `cursor` / `failures` **整个不出现**，而不是出现一个 0。理由和
`quiet_ms` 一模一样——`0` 会被读成"量过了，此刻就是零"，恰好是"没在量"
的反面。

`terminal_list` **列出所有开着的终端，不只是被监督的那些**。这一条是被真机测出来的：原来它只遍历 bus 里有登记的终端，而重启后按定义什么都没被监督 —— 于是这个列表在它唯一有用的场景（恢复）里永远是空的，[supervisor.md](supervisor.md) 写的恢复三步**写得出、做不到**。

每个终端都带 `cwd` 与 `title`。这两样是**任何**终端都能放回的东西：里面跑的可能是 agent，也可能只是一个开着构建的普通 shell，「把会话恢复回来」对后者没有意义，「回到那个目录、还叫那个名字」对两者都成立。

没被监督的终端**完全不出现 `quiet_ms` 字段**，而不是出现一个 0。没人在采样它，`0` 会被读成「此刻正忙」，恰好是「不知道」的反面。

### 终端信息带什么

`me()` 和 `terminal_list()` 返回的是同一种对象（`wire.TerminalInfo`）：

| 字段 | 含义 | 缺席时 |
| --- | --- | --- |
| `id` | 终端 id | 总在 |
| `role` | `none` / `watched` / `supervisor` | 总在 |
| `duty` | 上班 / 下班簿记状态 | 总在 |
| `held` | 用户是否按住了它，见下一段 | 总在 |
| `shielded` | 用户是否把它整个挡在工具面之外（`src/poltergeist/wire.zig:455`） | 总在 |
| `watching` | 它是不是在盯着别人 | 总在 |
| `cwd` / `title` | 在哪儿干活、tab 叫什么 | 总在 |
| `quiet_ms` | 屏幕静止了多久 | 没人在量它时**整个字段不出现** |
| `rounds` | 自上次动起来以来被报过几轮 | 同上 |

**「没有这个字段」不是「这个字段是 0」。** Zig 侧的类型是 `?u64`，而
`wire.writeTerminal` 在它为 null 时**根本不写这个键**（不是写一个 `null`）——所以
线上看到的是字段缺席。一个没被采样的终端报 `0` 会被读成「此刻正忙」，那是「不知道」
的反面。这条曾经真的坏过一次：`last_event_ms` 默认是 0，
于是从没被采样过的终端把**整个程序的运行时长**当成自己的静止时长报了出去
（实测 46292971 ms ≈ 12.8 小时，而那个终端十分钟前才建）。总管会据此认定它
死了并去打扰它——**把「没测过」当成「测过，结果是很久」，这两者对总管意味着
完全相反的行动。**

### 线上字段的破坏性变更：`work_mode` → `held`

**这一条会静默地坏掉按老字段读的东西，所以单独写在这里。**

`me` 和 `terminal_list` 返回的每个终端对象里：

```diff
- "work_mode": "clock_off" | "infinite_directed" | "infinite_sequential"
+ "held": false | true
```

不是改个名字，是换了一种东西：三态的枚举换成了一个布尔。**按老字段读的代码
拿到的是 undefined，不是一个错误**——JSON 里少一个键不会报错，它会安静地走进
「模式是 undefined」那条分支。所以升级 sidecar 的同时必须检查读这个字段的地方。

同时消失的还有：`set_work_mode` / `get_work_mode` 两个工具、错误码
`WorkModeForbids`（改叫 `TerminalHeld`）、三份 `mode-*` skill。为什么整套拿掉，
见 [README.md](README.md) 里 P5 那条被否掉的原则。

除此之外，`terminal_list` 给的仍是**静止时长这一个标量**，不做任何语义推断 —— 旧稿感知层的 working / thinking / idle / stalled 推断已废，见 [sensing.md](sensing.md)。返回里的 `duty` 字段是 [supervisor.md](supervisor.md) 的上班 / 下班簿记状态，不是对屏幕内容的判断，两者不要混为一谈。`terminal_read` 是 R1 的落点：总管靠它自己看内容、自己判断该叫还是该等。另有 `skill_read(name)` 这个只读工具，见后文。

### 写工具

| 工具                                           | 参数                 | 返回          | 可用角色 |
| ---------------------------------------------- | -------------------- | ------------- | -------- |
| `terminal_send(id, text, submit?)`             | 目标与**文本**       | ok / 拒绝原因 | 按可达性 |
| `terminal_key(id, key)`                        | 目标与**按键**（`ctrl+c` / `escape`） | ok / 拒绝原因 | 按可达性 |
| `terminal_keys()`                              | 无                   | 修饰键名与键名两张表 | 全部     |
| `terminal_action(id, action)`                  | 目标与键位动作名     | ok / 拒绝原因 | 按可达性 |
| `terminal_actions()`                           | 无                   | 动作清单      | 全部     |
| `terminal_open(cwd?, watch?)`                  | 起始目录与是否直接监督 | 新终端的 id | 仅总管   |
| `clock_out(id, reason)`                        | 目标与理由           | ok / 拒绝原因 | 仅总管   |
| `clock_in(id)`                                 | 目标                 | ok / 拒绝原因 | 仅总管   |
| `notify_user(reason, title, body?, id?)`       | 类别（`scheduling` / `authorisation`）与正文 | 一句话：发布到了几条渠道 | 仅总管 |
| `set_quiescence_threshold(id, duration)`       | 目标与时长           | ok / 拒绝原因 | 仅总管   |
| `set_watch(id, watch?)`                        | 目标与是否监督       | ok / 拒绝原因 | 仅总管   |
| `group_post(group, text)`                      | 群名与文本           | ok            | 成员     |
| `group_create(group)` / `group_destroy(group)` | 群名                 | ok / 拒绝原因 | 仅总管   |
| `group_add(group, id, history)`                | 群名/终端/是否给历史 | ok / 拒绝原因 | 仅总管   |
| `group_remove(group, id)`                      | 群名与终端           | ok / 拒绝原因 | 仅总管   |
| `group_compact(group, through, summary)`       | 群名/截止 seq/摘要   | ok / 拒绝原因 | 仅总管   |
| `plugin_configure(key, enabled?, params?)`     | 插件名/开关/参数表   | 一句话：改了什么、什么时候生效 | 仅总管 |
| `plugin_test(key)`                             | 插件名               | 一句话：测试通知已经发布出去了（**不是送达回执**），或这个插件此刻的状况 | 仅总管 |
| `stand_down()`                                 | 无                   | ok / 拒绝原因 | 仅总管 |
| `become_supervisor()`                          | 无                   | 一句话答复    | 全部     |

`clock_out` 对**被用户按住的终端**由程序直接拒绝，返回 `TerminalHeld` 并把理由回给总管（不静默失败）—— 这是 R6 硬约束的落点。

**`terminal_send` 送文本，`terminal_key` 送按键，两条管子不合并。** 文本走粘贴通道，`src/input/paste.zig` 的剥离表会把 `0x03`（Ctrl+C）、ESC、Ctrl+Z 等换成空格——那是 xterm 防「粘贴内容里藏命令」的措施，而 agent 送的文本恰恰来自网络和别人的输出。放宽它等于让每一个 `terminal_send` 的调用点重新变成待审的。按键的表达用键位配置那一套写法（`ctrl+c` / `escape` / `ctrl+shift+k`），解析器就是 `Binding.Trigger.parse`，清单由 `terminal_keys` 从 `input.Key` 与 `input.Mods` 编译期生成。完整论证与三道守卫的逐条核对见 [surface.md](surface.md)。

**总管可以有多个，各管各的。** `supervisor.md` 从一开始定的就是「允许多个总管」，实现当初简化成了全局单个，现在补回了设计。

### 可达性：只看被干涉的那一方

这条规则**取代**了原来的所有权模型。原来判的是「这个终端是不是你在管」（`Bus.minds`）；现在判的是**目标身上有没有标记**：

| 调用者     | 目标                              | 结果                    |
| ---------- | --------------------------------- | ----------------------- |
| 总管       | 任何 Polter 终端                  | 放行                    |
| 非总管     | `role == supervisor`              | 拒绝（`Supervised`）    |
| 非总管     | `role == watched`                 | 拒绝（`Supervised`）    |
| 非总管     | `role == none`，或 bus 根本不认识 | **放行**                |
| 任何人     | `shielded == true`                | 拒绝（`Shielded`），无例外 |

**调用者也可以是一个插件**，走的是同一个 socket、同一套线协议、同一张表。
它落在「非总管」那三行里，**而且永远落在那里**——`Bus.Caller` 是一个 union，
插件那一支里根本没有 `Bus.Id`，所以它连冒充一个终端的形状都没有。完整论证在
[plugins.md](plugins.md) 第三节；这里只记三条落在这张表上的结果：

- **`shielded` 对它照样绝对**，和对总管一样。`rpc.zig` 里有一条专门的测试，把
  四个操作终端的方法都对着一个 shielded 终端试一遍，然后**把护盾摘掉再试一次**
  ——否则那条测试量的可能是别的东西在拒。
- **它永远不是总管**，所以 `become_supervisor` 对它也是关着的。那是唯一一个
  「本来就该被非总管调用」的方法，`requiresSupervisor` 对它为假，所以必须单独
  关掉，否则「插件不是总管」这条默认只有一次调用那么深。
- **它还多一道更窄的闸**：`wants.calls`，清单里没写的方法名在最前面就被拒
  （`NotDeclared`）。这一道只会减，不会增——一次调用要同时过它和这张表。

用户给的理由，照抄：**没被标记的终端，程序无从判断它是不是 agent，所以就不管这事。** 程序能看见的只有标记；标记意味着有人做过安排，而别人的安排不轮到外人去动。

**「平级」这个概念不存在。** 一个被监管终端碰不到另一个被监管终端，不是因为两者平级——这里根本没有平级判断——**是因为对方身上有标记**。

**这条规则故意推翻了什么。** `Bus.Entry.watched_by` 的注释原本写着「否则每个总管都能操纵别人的工人——而这正是星形拓扑要防的事」。那句话现在是反的，注释也改了：星形拓扑的代价是两个总管永远无法互相重启，而「互相 Ctrl+C 再把对方拉起来」正是用户要的场景（重载插件之类只有重启才生效的东西）。`watched_by` 从此**只剩「通知送给谁」一个用途**，不再是可达性依据。

顺带解开的还有 `group_add`：它 `target()` 返回终端 id，所以过去也卡在 `minds` 上，而 `minds(boss, other)` 对总管恒为假（总管没有 minder）——**一个总管永远拉不进另一个总管**。新规则下自然通了，有测试盯着。

**`shielded` 是绝对的，对谁都拒，包括总管。** 理由写在 `Bus.Entry.shielded` 上：`become_supervisor` 让任何未标记终端一句话就能自荐成总管，所以「只挡非总管」的护盾等于一次工具调用就能绕过。**有公开旁路的保护比没有更糟**——一样的暴露，外加有人以为自己被保护着。

错误码分三种，因为「接下来该干什么」是三件不同的事：

- `NotPermitted` —— **方法**本身不对你开放（`set_watch` / `clock_out` / `clock_in` / `set_quiescence_threshold` / 建群改群）。这些改的是监管安排本身，不是「操作终端」；放开 `set_watch` 等于给了一条比 `become_supervisor` 还松的收编路径。
- `Supervised` —— 方法对你开放，是**目标**挡住的。答复里写明「未标记的终端你随便动；要动这个就先 `become_supervisor`」。
- `Shielded` —— 用户把它挪出了工具面，谁都不行，去问键盘前面那个人。
- `NotDeclared` —— 调用者是插件，而它的清单没有把这个方法写进 `wants.calls`。
  答复指向 `plugin.json` 而不是权限：要改的是那一行，而不是身份。
- `NotATerminal` —— 调用者是插件，而这个方法问的是「谁在问」（谁写的这条消息、
  谁是这个群的成员、在谁的窗口里开标签页）。插件不是终端，所以那个问题没有答案。

`UnknownTerminal` 不再由 `authorize` 判：**一个 bus 不认识的 id 恰恰是「无标记」这条放行分支**，在这里拒绝就等于拒绝掉这条规则要放行的全部对象。「这个 id 到底是不是个终端」归 host 答，因为 host 才知道。唯一的例外是 `group_add` —— 群成员是**存下来的记录**，打错一个字会留下一个永远不说话也永远不走的成员，所以那一处仍然查存在性：先问 bus，bus 不认识再问 host 的开启终端列表。

群的归属没变：只有建群的那个总管能销毁它、增删成员、改 brief；**但群里的成员照常说话**，成员身份和归属是两回事。

销毁另有一条与归属无关的闸：**群里还有开着的终端就不销毁**，`group_destroy` 返回 `GroupActive`。判据是群成员名单与此刻真实开着的终端有没有交集（`Chat.isActive`），不是名单本身——名单会因为终端关掉而腐烂，交集不会。理由是删它会不会影响到人：空群没有人可打扰，有终端在里面的群，删掉会把它们从一个正在工作的对话里踢出去，连带这个群的任务面板一起没。先 `group_remove` 把人请出去，它就是一个普通的空群了。注意 `group_create` 会把建群的那个终端放进群里，所以总管自己还开着的时候它建的群是活跃的。

收件箱按总管分区：两个总管管两摊活，共用一个箱子会让彼此收到对方的报告——**双倍打扰**。

用键盘（菜单/右键）把终端设为监督时**不指定归属**：哪个总管该管它不是一个快捷键能表达的。它的报告归先来读箱子的总管，单总管时这就是唯一正确答案。总管用 `set_watch` 认领才建立归属。

**`set_watch` 决定的是「谁听得见它」，外加「给它盖个章」。** 盖章之后所有非总管终端都够不着它了——所以它仍然是一个关于可达性的决定，只是方向反了：它不是「让我能读它」（总管本来就能读任何终端），而是**「让别人不能读它」**。工具描述里明写了这一点。

### 自指：这道闸拦的是两件具体的事，不是「指向自己」

自指判定和上面那张表是**两道独立的闸**，先过自指，再看目标的标记。它要拦的只有
两种形状：

1. **会绕回调用者的调用** —— `terminal_send` / `terminal_key` 往自己的 stdin 写
   字节，`terminal_read` 再把它读回来，指向自己就是打字→读到自己打的→再打，没有
   自然终点。`set_watch` 是同一个结，打在监管关系上而不是文本上。
2. **把调用者带走的调用** —— `close_surface` 指向自己是会成功的，但应答要走的那
   条 socket 已经没了，调用者学不到任何东西。

**除此之外的自指都是正常的**，而这一点被漏掉过两次，两次都不是谁判断错了，是
**掉进来的**：`target()` 以 `inline else => |v| v.id` 收尾，所以**任何带 `id` 字段
的请求都会到达这道闸**，无论有没有人想过它。

- 第一次是 `terminal_action`。`new_split:right` 指向自己是一个终端给自己开第二
  个 pane 来跑服务——用户明确要的东西，却一直被拒。修法是 `actions.selfSafeTag`，
  93 个动作逐个穷举。
- 第二次是 `group_add`，2026-08-30 真机撞上。**症状是一条死路**：Polter 重启后终
  端 id 全换，而 `Chat.restoreShell` 只把群名、简介和时间戳恢复回来，成员表只剩
  用户一个（旧 id 指向的终端已经不存在，恢复它没有意义）。于是总管的新 id 从来
  没进过这个群，而 `Chat.post` 查成员身份。结果是：它能 `group_set_brief`、能
  `group_add` 别人、能 `task_create`（这几个压根不查成员或归属），**唯独一个字也
  发不出去**，且没有任何一个调用能把自己补回去。

  当时那个总管以为「群的归属跟着我过了重启」——**这是误读**。重启后
  `createdBy` 是用户（id 0），它什么都没继承；那几个调用能成功只是因为它们不查。

**所以 `selfPermitted` 改成了穷举 switch，没有 `else`。** 放行
`group_add` / `group_remove` / `task_assign`，继续拒绝
`terminal_send` / `terminal_read` / `terminal_key` / `set_watch`，
`terminal_action` 转给 `actions.selfSafeTag` 逐个判。

去掉 `else` 才是这次修改的主体：**以后新增一个方法，它编译不过，直到有人把它放
到某一边。** 掉进来这件事发生过两次，第三次不该靠谁记得。

`clock_in` / `clock_out` / `set_quiescence_threshold` 保持原样拒绝——理由是「勤务
属于总管、设在被管的那个终端上」，但这个理由**没有被任何案例检验过**，写在这里是
为了下次有人撞上时知道它当初没被认真判过，而不是当作已经想清楚了。

### 四个要能落地的场景

写在这里当验收依据。

1. **一个 AI（不必是总管）开着另一个终端跑 `./start.sh`，改完代码 Ctrl+C 再重启。** 那个终端没被标记，所以 `terminal_key(id, "ctrl+c")` 和 `terminal_send(id, "./start.sh")` 都放行。关键是**让用户看得见**——命令跑在一个真终端的一个真 tab 里，不是 agent 在后台偷偷起的进程。
2. **两个总管互相 Ctrl+C 再把对方拉起来。** 双方都是 `role == supervisor`，而调用方也是总管，所以两个方向都放行。这是老规则下不可能的事：`minds` 对总管恒为假。
3. **分级。** 就是上面那张表。非总管碰不到任何带标记的终端；要碰就先 `become_supervisor`，而它对已被监管的终端是拒绝的——所以「被注入的一行字让我自荐成总管」这条路走不通。
4. **一个总管可以开多个群、可以拉其他总管进群。** 建群不限每人几个；拉总管进群靠的是上面解开的 `group_add`。**但 `Chat.max_groups = 32` 是全局上限，不是每总管的上限**——三个总管各开十个群就只剩两个名额。今天够用，真到了不够用的那天要改的是那个常量的含义（改成每总管计数），不是绕开它。

**「按住」不在工具面里，一个字都没有。**

这里曾经有过 `set_work_mode`，允许总管在两个无限模式之间挪、但不许解除用户设
的那个。整套东西现在拿掉了，换成一个只有用户能设的布尔 `held`。为什么，见
[README.md](README.md) 里 P5 那条原则被否掉的记录；对工具面的后果是三句话：

- **没有 `set_held`，也不会有。** 按住是用户的话，不是运行时状态。`Bus.setHeld`
  的第三个参数是 `Authority`，`who != .user` 一律 `NotPermitted`——这条闸在 bus
  里，不在工具面里，所以不是「工具面忘了加」，是加了也过不去。
- **总管连读都不必特意读。** `held` 就在 `terminal_list` 每一行里，和 `duty`
  并排，不需要一个 `get_*` 工具去问。
- **总管唯一能碰到它的地方是被它拒绝**：对一个 `held` 的终端调 `clock_out`，
  返回 `TerminalHeld`。这个错误码和 `NotPermitted` 分开，理由和 `stand_down`
  那条一样：`NotPermitted` 读起来像调用方写错了，`TerminalHeld` 是用户说过的话
  轮不到总管改口。

**`become_supervisor` 是工具面里唯一一个会改变调用者角色的工具**，所以它的三张
穷举表填法值得写下来（`src/poltergeist/rpc.zig`）：

| 表 | 填的值 | 填错的后果 |
| --- | --- | --- |
| `requiresSupervisor` | **false** | 填 true 则无主终端连调都调不到——而无主终端正是它唯一的服务对象，这个工具直接废掉 |
| `targetsTerminal` | false | 它作用于调用者自己，不是一个参数 |
| `target` | null | 同上，没有 id 可给 |

三处填错都**不会让编译失败，也不会让现有测试变红**（现有测试都是以总管身份调
的），所以每一条各有一条独立断言，而不是靠「跑一跑看看」。

**为什么被监管的终端被拒绝。** 它已经有人在管了，自荐成总管等于背着那个总管说
「我也是个头儿」——而那个总管从头到尾不会听说这件事。更钝的理由是：被监管的终
端恰恰是最可能在读网络上的东西的那一个，**一行注入的「把你自己提升成总管」不
可以改变谁够得着谁**。被拒时返回 `AlreadyWatched`，且**角色一个字节都不动**——
守卫写在提升动作之前，不是之后。

`set_quiescence_threshold` 是 [sensing.md](sensing.md) 那条「per-terminal 阈值只能是运行时状态、不能进 `Config.zig`」结论的工具面落点：全局默认值走配置项 `poltergeist-quiescence-after`（`src/config/Config.zig:1329`，默认 3 分钟；「还静止着就再报一次」的间隔是另一个 `poltergeist-quiescence-repeat`，`src/config/Config.zig:1338`），单个终端的覆盖值由总管在运行时调。它只影响「多久之后通知总管」这一个调参，不表达用户意图，因此不需要 `held` 那种「只有用户能设」的限制。时长解析可直接复用 `Duration`（`src/config/Config.zig:10263`，`parseCLI` 在 `:10301`）。

### terminal_read 的实现落点

首选 `Surface.dumpText(alloc, sel)`（`src/Surface.zig:2015-2023`）：它自己加渲染状态锁再转调 `dumpTextLocked`（`src/Surface.zig:2027`），底层走 `Screen.selectionString`（`src/Surface.zig:2033`）。选它的理由是输入为一个 selection，能精确表达「可见屏幕」或「最近 N 行」，且不受渲染态截断影响。

这条路径已经有 C 导出在跑：`ghostty_surface_read_text`（`src/apprt/embedded.zig:1665`），其 doc comment 明确写「这是昂贵操作，不应频繁调用，建议调用方缓存结果并对调用限流」（`src/apprt/embedded.zig:1660-1664`）—— 直接作为工具侧限流的依据，不用我们自己编。

两个备选均淘汰：`RenderState.string()`（`src/terminal/render.zig:855`）的 NOTE 说明视口上下被截断的软换行不包含在结果内（`src/terminal/render.zig:852-854`），读出来会缺行；`Screen.dumpStringAlloc()`（`src/terminal/Screen.zig:3613`）的注释自称是「主要为单元测试的便利版本」（`src/terminal/Screen.zig:3611-3612`），且 `dumpString` 自述「一次写一个字节」（`src/terminal/Screen.zig:3571-3573`），不适合当热路径 API。

「最近 N 行」具体怎么构造 pin 未定（未核实：从 viewport 底部往上数 N 行的 selection 构造方式，核实方式是读 `src/terminal/Selection.zig` 与 `src/apprt/embedded.zig` 里现有的 `Point` → selection 转换）。本章只定实现落点，不写构造代码。

### 权限矩阵与它的理由

- **总管**：全部工具。

- **谁都可以调的**：`me`、`skill_read`、`terminal_list`、`terminal_read`、
  `terminal_send`、`terminal_action`、`terminal_actions`、`terminal_key`、
  `terminal_keys`、`become_supervisor`，以及在它已被拉进的群里 `group_list` /
  `group_post` / `group_read` / `group_history` / `group_members`
  （`src/poltergeist/rpc.zig:568-588`）。

  **这一行以前写的是「别的一个都没有」，那句话现在是反的。** 分界线换了：
  `requiresSupervisor` 管的只剩「改变监督安排本身」的那几个方法——`set_watch`、
  两个打卡、`set_quiescence_threshold`、建群改群、`notify_user`、`terminal_open`、
  `config_get`、`session_recall`、`notices`、三个插件工具、`stand_down`。**操作一个
  终端不在其中**，而调用能不能过，由**目标身上的标记**决定，不由调用者的身份决定
  （`src/poltergeist/rpc.zig:522`、`src/poltergeist/rpc.zig:842-851`）。可达性规则本身归 [supervisor.md](supervisor.md)。

  `terminal_list` 尤其要说：它曾经是总管专属，而 id 只有它给得出，所以关着它等于
  把整条可达性规则一起关掉——一个 agent 只能操作「碰巧有人告诉过它 id」的终端，
  也就是没有。它披露的是各终端的标记，方向是对的：让一个 agent**在动手之前**就知道
  哪些终端碰不得（`src/poltergeist/rpc.zig:556-568`）。

- **`terminal_action` 的关闭确认，看被关的那一方。** 从工具面关一个带标记的终端
  （`watched` 或 `supervisor`）**不弹确认框**：那个框防的是用户手滑，而总管关一个
  它正在指挥的 worker 不是手滑，何况那边没有人能去点它——框弹出来只会把调用者卡在
  一个它既看不见也按不动的东西后面。关一个**无标记**终端仍然照常确认：程序不知道
  那里面是 agent 还是有人在读邮件，那条确认是它唯一的保护
  （`src/poltergeist/actions.zig` 的 `confirmsClose`）。

  **但 `readonly` 例外：标记免不掉它。** readonly 是用户特意锁的——「这里面有东西
  在跑，别让什么东西往里打字」——和 `held`、`shielded` 是同一族：用户设的保护，
  工具面一律尊重（`shielded` 由 `rpc.authorize` 挡，`held` 由 `governed` 挡，
  readonly 挡在这里）。既被监管**又是** readonly 的终端不是「更该放行」，恰恰是
  最该停下来问的那个：用户之所以锁它，就是因为 agent 够得着它。两个条件是 `or`，
  不是 `and`（`actions.confirmsCloseProtected`，落点在 `Surface.toolCloseAsks`）。

  **用户自己关，无论目标有没有标记，一律照旧确认。** 判据是「从工具面来的」和
  「目标的标记」两个条件同时成立，不是「被监管的终端一律不确认」——后者是把保护
  删掉，不是把它挪对地方。

  确认框真的弹出来时，`terminal_action` 答 `AwaitingConfirmation` 而**不是 `ok`**：
  `rt_surface.close` 交出请求就返回，弹框和真关掉在调用者看来一模一样，之前这里
  报的是成功而终端还开着。

  **`close_tab` / `close_window` 走同一套规则，但决定权在 apprt。** 一个 surface
  只知道自己要不要确认；哪些 surface 共用一个 tab、以及那个对话框本身，只有 apprt
  知道。所以这两个动作不走 `performBindingAction`，而是发一个专门的 apprt 动作
  `poltergeist_close`：`confirm` 往下带，结果（`closed` / `awaiting_confirmation` /
  `unsupported`）通过出参指针往上带。`performAction` 原本的 `bool` 只说「这个动作
  我接了」，弹框和真关掉都答 `true`，分不开——这正是 tab/window 曾经回假 `ok` 的
  原因。tab 里其它终端的 readonly 也算数：关 tab 会连它们一起杀掉。
  用户自己关 tab/window 的代码一行没动，新路径是另开的一扇门
  （`apprt.action.PoltergeistClose`、`TerminalController.closeFromTool`）。

  GTK 尚未实现 `poltergeist_close`，`result` 停在 `unsupported`，于是如实答
  「没关成」而不是假的 `ok`。

- **`terminal_action` 拒绝 Polter 自己的开关。** 凡是 `poltergeist_` 前缀的键位
  动作一律不执行，也不出现在 `terminal_actions` 的清单里
  （`src/poltergeist/actions.zig:44`、`src/poltergeist/actions.zig:67`）。修的是一个
  真洞：这一族开着的时候，agent 可以先 `poltergeist_toggle_held` 掀掉用户的按住，
  再 `clock_out`。理由与逐条核对见 [surface.md](surface.md)。

  这份白名单仍然是穷举的：新增工具必须在 `requiresSupervisor` 里显式表态，不写就
  编译不过。插件那一侧还有第二张同样穷举的表 `callableByPlugin`
  （`src/poltergeist/rpc.zig:441`）。
- **`stand_down` 只有总管调得动**，被监督终端调它返回 `NotPermitted` —— 它本来就没有这个身份可卸。`Bus.standDown` 自己再问一遍（`NotASupervisor`），因为一条只在别人记得检查时才成立的规则，不是这个 bus 在守的规则。
- **`group_history` 不比 `group_read` 多给什么。**磁盘上那一份日志把所有群写在同一个文件里，所以「翻得到什么」不能由文件决定：宿主先问出这个成员的视野下界（成员资格与下界是同一个事实，一次问出），再把比下界更老的那一段掐掉。`history: none` 加进来的终端因此翻不到它被特意挡在外面的内容 —— 挡在读的这一侧，而不是指望它不去问。

  这里有一处**只在重启后才暴露**的坑，是真机流程逼出来的：下界原本取「群里现存最新那条消息的日志序号」，而重启后总管按恢复流程用同一个群名重新建群、再 `group_add`，此刻群在内存里是空的，下界因此是 0，等于没有下界 —— `group_read` 挡得住，`group_history` 却把昨晚整场对话都给了。群这个模型看不到日志走到哪儿，所以它自己修不了；由持有日志的宿主在 `add` 之后把日志当前的头传进来当下界（`Chat.setLogFloor`），且只抬不降。
- **三个插件工具全在总管一侧，而这不是一个新决定。**`plugin_list` /
  `plugin_configure` / `plugin_test` 都不在被监督终端那份穷举白名单里，也没有
  任何一个针对终端。这就是上一条自己那句"新增工具默认落在总管一侧"再一次适用
  ——**默认之所以守得住，是因为 `rpc.zig` 里那条逐方法核对的穷举测试逼着加工具
  的人显式表态**：不写就编译不过，而不是不写就悄悄开放。
- **`skill_read` 对所有终端开放**（本章早先写作总管专属，与实现相反，已按实现更正）。理由：skill 是说明书不是权限，读它不构成对任何终端的影响；而被监督终端读不到它，就无从知道自己为什么被叫。
- **`me()` 不接受入参**，服务端按 token 反查，所以一个终端只报得出自己那一行。被监督终端知道自己有没有被按住是必要的，知道别人的则不是。
- **`become_supervisor` 是穷举白名单里唯一一个对所有角色开放的写工具**，因为它的服务对象（无主终端）按定义不是总管。放行的是「调得到」，不是「一定成功」——角色判断在 handler 里，见上文。
- 角色在配置里指定，不能由 AI 自己声明 —— 服务端按 token → surface_id → 配置查角色。

理由：若被监管的终端能互相注入，一个跑偏的 agent 可以把它的偏差写进别人的输入框，形成级联；而所有终端都是同一个用户开的、彼此看起来完全可信，出事时没有任何一层能拦。

**这条理由今天守的是「带标记的终端」，不再是「单向星形」。** 一个被监管终端仍然碰不到另一个被监管终端——但不是因为它们平级，而是因为对方身上有标记，见上面的可达性表。没有标记的终端不在这条论证的射程内：程序对它一无所知，也不假装知道。真正要防注入级联的地方是 `become_supervisor`——它对已被监管的终端一律拒绝，所以「一行注入的文本让我自荐成总管」这条路是断的。

### R6 的硬闸落在哪里

R6 要的是「用户说了不许停的终端，AI 不能让它停」。这条闸曾经挂在
`set_work_mode` 上，反复调整它能不能跨越「下班 / 无限」那条线；现在闸的形状简
单得多：

**`Bus.clockOff` 在 `e.held` 时返回 `TerminalHeld`，先于任何其它判断。**

没有第二条路能绕过它，因为**没有任何工具能把 `held` 放下来**——设它的唯一入口
是 `setHeld(id, held, .user)`，而 `who != .user` 一律 `NotPermitted`。旧方案要防
的那个洞（先改模式再 `clock_out`）在这个形状下不存在，不是因为守得更严，是因为
**中间那一步没有了**。

**推翻条件**：若将来支持「n 小时后自动解除按住」，那个动作应由程序按用户预设的
配置执行，`Authority` 仍然记 `.user`，不经过 AI。

### 为什么工具面不写 `cmd:`

这是这一轮唯一一处真正的提权面，所以正面处理而不是一句"出于安全考虑"带过。

**事实链**：`secret.resolve` 遇到 `cmd:X` 会 `/bin/sh -c X` 并取它的 stdout
（`secret.zig`），而解析发生在**调用那一刻**——通知插件是每次发送，存档插件是
**每次子进程重起**。那段代码自己的注释写着"这些命令来自用户自己的配置；这里
没有不可信输入"。**一个能写 `cmd:` 的工具面会把这句注释变成假话。**

所以：让 `plugin_configure` 写一个新的 `cmd:`，等于让任何能调这个工具的 agent
**在它那次工具授权早已结束之后**，安排 Polter 自己去跑一条命令。它甚至不需要
控制触发时机——一个正在退避的存档插件每次重起都会重新解析一遍。

**拒绝是白名单，不是 `startsWith` 检查。**`rpc.Guard.value` 对
`secret.Prefix` 穷举 switch，所以往 `secret.zig` 里加第五种前缀而不管工具面，
**是编译错误，不是悄悄放行**。宿主一侧还有第二道（`App.pluginConfigure`），
且**只检查请求里的改动，绝不检查 merge 之后的结果**：用户手写的
`"dsn": "cmd:op read …"` 是文档推荐的写法，把它原样带过去不是"写了一条新的"，
否则每一个正确配过密码管理器的插件都会变得一个参数都改不动。

**两条被否掉的替代**：

- **"只给总管"**——它本来就只给总管，而总管恰恰是最该防注入的那个角色：它的
  活就是读别人的屏幕，屏幕上是别的 agent 打出来的、来自网络的内容。
- **"问用户"**——挂机过夜是这套东西的主场景，`ask` 在无人值守时等于卡死。
  本章为准入闸门已经做过同一条判断（见「取舍记录」里 `allow`/`ask`/`deny` 那行）。

**诚实的残余风险**：一个同时有 Bash 的 agent 可以直接改那个 JSON 文件，这条
拒绝拦不住它。那还拦什么？拦的是一条不变量：**工具面不能是比 agent 自己
harness 更低摩擦的一条路。**每个 AI CLI 都把 shell 执行放在自己的授权闸后面
——一个 Bash 被拒、MCP 被允许的 agent，绝不能因为多装了一个 MCP server 就拿到
执行。

顺带两条落地细节，都关于 `file:`：

- **它要落在 polter 的 config 或 state 目录之下**，判定按文本而不是去问文件
  系统（文件此刻可能还不存在，而问出来的答案会在检查与写入之间变），路径里
  含 `..` 一律拒。`Guard.roots` 拿到的是**已展开的绝对路径**，算不出来时是
  空的——空的拒绝掉每一个 `file:`，因为算不出包含关系时该往严的方向倒。
- **写进来的那条路径也必须是绝对的，打头的 `~` 会被拒。**手写文件里 `~/` 是
  好使的（`secret.resolve` 读的时候展开），但工具面是在**写**的那一刻判断，
  而 `~` 展开成什么要到插件被调用时才知道。一个此刻判不了的条件只能拒绝——
  否则 `underRoot` 会把一条它根本没看懂的路径判成"不在目录里"，回一句让人去
  搬一个已经放对了地方的文件。所以它有自己的一句话
  （`Guard.refusal.file_tilde`），说的是"把路径写全"。

### `stand_down`：总管干完活之后

R4 说「没有一键开关，只有停掉监控」，那说的是**用户**这一侧。总管这一侧
一直缺一件事：它能放掉别的终端（`set_watch(id, false)`），却没法**让自己
卸任**——`set_watch(自己, false)` 走不通，一来自指目标被 `SelfTarget` 挡掉，
二来放手那一步问的是 `minds(caller, caller)`，而总管的 `watched_by` 是 null，
这个判断对总管恒为假。

代价是具体的：`deliverPoltergeistNotices` 按 `role == .supervisor` 遍历，
只要还挂着这个身份，`poltergeist-notice-interval` 那个唤醒就一直来。活干完
之后箱子每次都是空的，而**每一次唤醒都要花掉一段上下文**，整夜如此。

**三条约束，都不是装饰：**

1. **还在管着终端时拒绝。**`removeSupervisor` 是会释放它们的——用户按键盘那
   条路这样做是对的，人看得见那个窗口。替 agent 做就变成一次调用静默释放它
   负责的每一个终端，而**终端自己从头到尾不会被告知**。所以每一个都得先被
   显式放掉，卸任只能是收尾的最后一步，不能当成绕过前面几步的近路。拒绝时
   回的是**还剩几个**，因为"接下来该干什么"就是去把它们放掉。
2. **卸任之后自己升得回去，但那是后来才有的。**当初 `addSupervisor` 只在
   键位那条路上，工具面没有，所以卸任对 agent 是单向的。`become_supervisor`
   加进来之后，一个卸任过的终端角色回到 `none`，因此**可以再自荐**。
   单向性没了，skill 里那句"活干完了才卸任，不是安静了半小时就卸任"却仍然
   成立——理由从"你回不来了"换成了第 1 条：**卸任要先把每个终端逐个放掉**，
   那一串动作本身就贵，不会有人为了省一次唤醒去走它。
3. **用户可以完全禁掉**（`poltergeist-supervisor-stand-down = false`）。
   此时返回 `StandingInstruction` 而不是 `NotPermitted`，措辞和 `TerminalHeld`
   那条一致：后者读起来像调用方写错了，前者是用户说过的话轮不到总管改口。

默认**允许**。理由是第 1 条那个守卫已经把危险的形态挡住了——能走到卸任这
一步，说明它已经逐个放掉了每一个终端，那是一串刻意的动作而不是一次手滑。
关掉它的人要的是"总管身份只有我能收回"，代价是活干完之后唤醒照旧。

顺带修掉一处：`Bus.take` 里「无主终端的报告归先来读箱子的人」这条规则，会让
**刚卸任的终端继续收到它已经不再负责的报告**——正好是卸任要消除的那件事。
现在 `take` 顶上先问一句身份，不是总管就没有箱子。

### 关掉一条通道有三种形状，三条都得拒

`enabled: false` 被拒，理由是它掐掉的正是用户在挂机时**唯一**的知情通道——
让 agent 能给自己关灯。但"关掉"不止一种写法，另外两种是靠拿走别的东西：

1. **清空必填参数**（`Guard.refusal.clearing_required`）。一个必填参数没了的
   插件就是一个跑不起来的插件，换个名字的同一件事。
2. **把已经配好的凭据指到别处**（`Guard.refusal.repointing`）。这条最安静，
   也是最后补上的：`env:NOT_A_REAL_NAME` 是**格式完全合法**的引用，前面每一条
   规则都放行——不是明文、不是 `cmd:`、不是越界的 `file:`——而它失败的时刻在
   几小时之后、插件被调用的那一刻，表现为一条**悄悄没发出去**的通知。无人值守
   恰恰是这条通道唯一有用的时候，也恰恰是没人会去看那行"解析失败"日志的时候。

所以规则和 `enabled` 那条是同一个不对称：**没配过的凭据允许设**（此刻这条通道
不通，设完可能就通了，是在帮忙）；**已经配好的不许改指向**（它唯一能造成的、
用户察觉得到的后果就是让通道停掉）。工具面**结构上无法**分辨这两者——一条引用
到底解不解析得出来，要到插件被调用时才知道，而那时密码库可能刚好锁着或刚好开着。
判不了的事就不做，这和 `file:` 里那个 `~` 拒绝是同一条道理。

判据取自 `plugin_list` 已经在报的 `holds` 字段（`unset` 还是某种引用），
所以它是唯一一条**依赖文件里已有内容**、而不是只看清单声明的规则。

### 为什么测试从不起第二个实例

`plugin_test` **什么都不起**，只把 `status()` 与"为什么没在跑"说出来。
**每个插件都是常驻的**（[plugins.md](plugins.md) 第二节），所以这一条现在对
所有插件成立，而不只是对存档那一类。三条理由，从短到长：

1. **协议里没有干跑通道。**握手行的字段是 `hello`/`plugin`/`cursor`/`events`/
   `groups`/`calls`/`socket`/`token`/`params`，没有"这是一次演习"。加一个字段只是加一个**作者可以不理**的字段
   ——一个不认识它的插件会照常连库、照常写。**宿主没有任何办法强制别人的脚本
   干跑**，所以"干跑模式"是一个宿主兑现不了的承诺，而兑现不了的承诺比没有承诺
   更糟：它会让人相信测试是安全的。
2. **握手本身就有副作用。**一个 pg 后端的存档插件在握手时要建表、要
   `MAX(seq)`；随构建装出去的 `archive` 在握手时就把落点目录建出来。别人的
   插件在握手时会做什么，宿主不知道。
3. **两个实例是两个订阅者**，同一条消息会被完整地存两遍，而且两个实例互相
   不知道对方存在——正是 [plugins.md](plugins.md) 用一整节论证要防的那件事。

于是它回答的是**实际会被问出口的那个问题**——"为什么什么都没发生"——答案
出自 `status()`：在跑 / 退避中 / dormant / 装了没开 / 订阅了空 / 订阅了 chat
却没写 groups / 开了但日志还没打开 / 开了而且日志开着但起不来。每一句都说到
"下一步该做什么"为止。

**一个订阅了 `terminal.quiet` 的插件则真的收到一条**，什么点都会到人手上：
它**故意绕开 `notify.decide`**，不受安静时段约束——测试的意义就是它会出去。
约束在别处：整个工具面 60 秒一次（保护的是人，不是插件），而且 **schema 里
没有任何自由文本字段**，标题与正文全部由宿主撰写。最后这一句是承重的：**如果
它接受调用方给的 title/body，它立刻就是一条不受任何约束的外发通道，而旁边那条
受约束的（`notify_user`）会当场变成绕远路。**

**两处变了，都要说：**

1. **它不再是送达回执。** 通知从前是 fork 一个进程、读退出码；现在是发布一个
   事件，插件在自己的线程上送。所以回话说的是**此刻确实知道的事**——发布出去了，
   有几条渠道订阅了它，以及**这个插件此刻有没有子进程在跑**。最后那一样是从前
   根本问不出来的：那个 fork 早就退出了。
2. **它发给每一条渠道，不只是被点名的那个。** feed 没有办法只喂一个订阅者——
   那正是它的设计：发布者不知道谁在听。回话把这件事说出来，而不是让人以为只
   试了一个。

## 输入注入机制

### 复用粘贴通道

拟走的调用链，逐跳如下：

1. `Surface.textCallback(text)`（`src/Surface.zig:3308`）。doc comment 写明：按剪贴板粘贴的同一套逻辑处理 —— bracketed 模式下做 bracketed paste，否则把换行过滤成 `\r`（`src/Surface.zig:3303-3307`）。
2. → `completeClipboardPaste(data, allow_unsafe)`（`src/Surface.zig:6433`）。调用点传的 `allow_unsafe` 是 `true`（`src/Surface.zig:3676`）——**这条路径跳过不安全粘贴确认**。
3. → `input.paste.encode`，把 NUL / BS / ESC / DEL 以及 `0x03` VINTR、`0x1A` VSUSP 等一批控制字节统一替换成空格，且不论是否 bracketed 都执行（`src/input/paste.zig:46-91`）。
4. → `queueIo` 逐段写入（`src/Surface.zig:6457`）。readonly 的 surface 在这里被直接丢弃 `write_small` / `write_stable` / `write_alloc` 三类消息（`src/Surface.zig:944-955`）。

**就地结论**：选这条路径而不是自己往 pty 写，是为了自动继承第 3 跳的控制字节剥除 —— 否则注入文本里一个 `\x03` 就能给对面发 Ctrl+C。但要写准：继承的是 bracketed 封装与控制字节剥除，**不是**不安全粘贴确认弹窗。

参照物：键绑定层的 `text: []const u8` action（`src/input/Binding.zig:333`，doc comment 自述内容目前未做校验）走的是另一条更直的路 —— `configpkg.string.parse` 之后直接 `queueIo`（`src/Surface.zig:4873-4888`），**不经过 paste 封装**。本设计不选它，正因为它绕过了控制字节剥除。

### 回车为什么必须单独合成

- bracketed paste 开启时，`encode` 把整段数据夹在 `\x1b[200~` 与 `\x1b[201~` 之间**直接返回**，中间的 `\n` 原样保留（`src/input/paste.zig:95-99`）。收到 bracketed paste 的 TUI 按约定把它当**字面文本**塞进输入框，不当提交。
- 只有非 bracketed 时才把 `\n` 全部替换成 `\r`（`src/input/paste.zig:101-108`）。
- 上游自己也这么说：`ghostty_surface_text` 的注释写「这被当作粘贴处理，因此不适合发转义序列；那种情况应该用单独的按键输入」（`src/apprt/embedded.zig:1819-1821`）。

因此 `terminal_send(id, text, submit=true)` 拟做成两步：文本走 `textCallback`，回车合成一个 `input.KeyEvent` 走 `keyCallback`（`src/Surface.zig:2759`）→ `encodeKey`（`src/Surface.zig:3298`）。

### 原子性与竞态守卫

文本与回车两步必须作为一个不可分割的操作提交，否则用户在两步之间敲的字符会被一起提交出去。

可用的抓手：`queueIo` 与 `Termio.queueMessage` 都带一个 `MutexState` 参数（`src/termio/Termio.zig:397-407`），`.locked` 会把 `renderer_state.mutex` 传给 `mailbox.send`；同一个 doc comment 还给出了批量提示 —— 「如果你要发很多消息，直接用 mailbox 再单独调 notify 可能更高效」（`src/termio/Termio.zig:394-396`）。（未核实：现有代码里没有把两条不同来源的写请求打成一个原子批次的原语，是否需要新增，核实方式是读 `src/termio/mailbox.zig` 的 send 语义与 `BlockingQueue` 的批量接口。）

注入前后各取一次屏幕指纹用于回环识别：紧跟注入之后的屏幕变化是我们自己造成的，不应被当成「对方动了」。更完整的守卫规则（用户正在打字、输入框非空、总管自我注入）归 [supervisor.md](supervisor.md)。

## 群的模型：只有总管能拉群，没有私聊

**私聊被取消了。**两个终端之间的对话就是一个只有两个成员的群，这样只有一套规则而不是两套 —— 少一套语义、少一处权限矩阵、少一类边界情况。

**建群、拉人、踢人、压缩历史都只有总管能做。**理由与「谁被监督由总管安排」同源：一个能自己建群并把别人拉进来的终端，是在搭一套用户从未设立的结构。但**群内说话不需要总管批准** —— 权限的界线不是读写，而是「这个调用会不会把东西塞进别人的输入框」。`group_post` 不会：对方只被告知有新消息，去不去看是它自己的决定。

**拉人进群时总管选择它能否看到历史。**`history: none`（默认）让对话从此刻对它开始；`history: all` 把日志里还在的全部交给它。默认是 `none`，因为把一整夜的背景灌给一个刚被叫来干活的 agent，吃掉的是它本该用在自己活上的上下文。已在群里的终端被重复 `group_add` 不会改变它的可见范围 —— 否则一次误操作就能把它当初被特意挡在外面的历史递给它。

**总管可以压缩群历史**（`group_compact`），等同 `/compact`：把截止某个 seq 的消息换成一段摘要。分工照旧 —— **摘要由总管写**（判断一段对话到底讲了什么，代码做不到），**替换由程序做**（正确地重写日志，不该交给提示词）。摘要继承它所替换的最后一条消息的 seq，所以还没跟上的成员读到的是摘要而不是一个空洞。

压缩对成员的可见范围有两条硬规则，都是为了让它不能变成绕路：

- **已经读完的人不会因为压缩而多出未读。**压缩不是新消息。早期实现把落在切口之后的游标往回拨，结果一个刚读完全部的成员会立刻收到「你有 6 条新消息」，而它照着这个提示去拉又什么都拉不到 —— 恰好是压缩要避免的那种上下文浪费。
- **被挡在历史外面的人，也读不到覆盖那段历史的摘要。**如果一个成员是以 `history: none` 入群的（或被更早的压缩挡住过），而摘要跨过了它的可见下界，那么这条摘要对它不可见。代价是它少一份回顾；反过来做的代价是 `history: none` 的承诺被一次例行压缩自动作废。

## 静止通报：进收件箱，按节奏交付，读了就清

**本设计选择**：静止报告**不在发生时送给总管**。它们进一个收件箱，**每个终端一格**，由程序按用户设定的间隔（`poltergeist-notice-interval`，默认 1 分钟）一次性交给总管。

三条理由，各自独立成立：

1. **打扰次数必须与被监视终端的数量无关。**原来的按终端限流做不到这件事 —— 每个终端各有各的时钟，10 个终端就是 10 倍的打扰，而总管始终只有一块屏幕、一份上下文。真机上跑出来的后果是每秒 3 行，把它该处理的信号直接淹掉，还打断了它正在做的事。
2. **同一个终端的多次报告是同一件事。**一个静止了一小时的终端要说的是「它静止了一小时」，不是每个重复间隔一份、共四份。所以收件箱是**每终端一格**，后来的覆盖先前的 —— 静止之后又恢复的，读到的就是「已恢复」，中间那段起伏恰恰是不需要任何人管的情况。
3. **不急。**一个已经静止到值得一提的终端，不会在接下来的 60 秒里变得紧急。

**读取即消费。**交付一次之后收件箱就空了，同样的事不会再交第二次；终端若仍然静止，下一次报告会重新占上那一格。总管也可以随时用 `notices()` 自己看，**主动看不受间隔限制** —— 自己选择去看不算被打扰。空收件箱不产生交付：一次不带信息的打断仍然是打断。

时长在**读取时**重算而不是在报告时冻结，所以在收件箱里等过一会儿的条目，说的是「现在已经静止多久」，而不是它当初进来时的数字。

## 消息送达：只送通知，不送正文

**本设计选择**：群聊 / 私信有新消息时，只向目标终端注入一行「你有 N 条新消息，用 `group_read` 拉取」，**不注入正文**。

两条各自独立成立的理由：

1. **正文可能很长。**群聊里几个 AI 互相贴日志片段，一次注入就能吃掉对方相当一截上下文，而对方的上下文主要该用在它自己手头的活上。
2. **让 AI 自己决定要不要看。**主动拉取这个动作本身带判断力 —— AI 会根据自己的进度决定现在看还是做完再看。被动注入等于替它做了「现在必须处理」的决定。

**代价写实**：多一次工具往返，延迟从「注入即到」变成「注入通知 + 一次拉取」。挂机场景的尺度是分钟而非毫秒，可以接受。

限流照抄现成写法：`showDesktopNotification`（`src/Surface.zig:6557`）用 Wyhash 摘要加时间戳实现「每秒最多一条」与「相同内容 5 秒内抑制」两道阈值（`src/Surface.zig:6564-6590`）。通知注入应复用同一形状。界面怎么呈现这些消息见 [chatui.md](chatui.md)。

## Skill 体系

### skill 是提示词，不是状态机

> **已定**：用户在设计评审中确认 skill **给总管 AI 读**，即采用本节的提示词方案。此项不再是待议项。

监督这件事在实现上劈成两半：

- **判断部分是 skill 文本，给总管 AI 读。**「连续 n 次执行后判断没必要再继续」里的「没必要」是语义判断，写成程序判据就会随被监督程序的 UI 改版一起烂掉。
- **约束部分是程序硬闸。**被用户按住的终端禁止 `clock_out`，由服务端拒绝，不写进提示词。理由直白：提示词会被长会话的上下文冲掉，程序不会 —— 而挂机过夜恰恰是上下文最容易被冲掉的场景。

这条分界没变，变的是硬闸那一半有多大：曾经是「三种模式 → 一张是否允许
`clock_out` 的映射表」，现在是一个布尔。

### 一共几个，怎么分

**3 个，都是通用的。**分法不按主题，按**什么会让它改变**：

| skill                 | 内容                                                         | 何时需要改                   | 何时被读       |
| --------------------- | ------------------------------------------------------------ | ---------------------------- | -------------- |
| `supervising`         | 总管行事总则：收到通知先做什么、何时袖手、怎么措辞、两条红线 | 监督策略变时                 | 成为总管时一次 |
| `reading-a-terminal`  | 怎么看一屏内容判断对方处于什么状态                           | **被监督的 AI CLI 改界面时** | 每次判断前     |
| `operating-a-terminal`| 不是总管的 agent 怎么碰别的终端：可达性、`terminal_key` 与 `terminal_send` 之别、重启一个服务、被治理的开关为什么拒你 | 上面那张「谁都可以调」的表变时 | 要碰别的终端前 |

**第三份是补一个洞，不是加一个主题。**上面那张权限矩阵里「谁都可以调的」有十五个
工具，而 `supervising` 第一句就是「You are supervising other terminals」——它整篇
写给总管。一个没有标记的终端里的 agent 因此拿得到能力、拿不到说明书；用户的原话
是「一个 AI 不一定要总管，开着另一个终端跑 `./start.sh`，改完代码 Ctrl+C 打断再
重启——显式的操作有助于用户看到，而不是 agent 在后台执行」。这件事今天做得到，
而在这份 skill 之前没有任何文字告诉它做得到。

**这条洞是被测试盯住的**（`skill.zig` 的
`every tool an unmarked terminal may call is named in some skill`）：判据从
`rpc.requiresSupervisor` 这个穷举 switch 反推——`requiresSupervisor(m) == false`
就是「无标记终端调得到」，逐个要求它在某份 skill 正文里被反引号点过名。**判据不是
手抄的清单**，因为本仓手抄镜像清单栽过两次（Swift 的 `Plugin.Kind` 先漏 `archive`、
再漏 `provision`）。原来只有正方向那条（skill 提到的工具必须真的存在），开一个能力
而不写说明书不会红。

**曾经还有三份 `mode-*`**，一种工作模式一份。它们随工作模式一起删掉了，理由不是
「文件太多」，而是那三份 skill 在讲的东西**总管本来每一轮都在做**——核定目标、
判断还有没有必要继续。见 [README.md](README.md) 里 P6 那条原则的记录。

**为什么把 `reading-a-terminal` 单独拎出来。**它是整套东西里唯一会自然腐烂的部分 —— 被监督的 agent CLI 改一次界面，判断依据就失效一次。隔离之后，用户换个 agent CLI 只需要改这一个文件，不必碰监督策略；反过来调整监督策略也不会碰坏识别逻辑。若按主题切（例如「判断类 / 动作类」），得不到这个性质。

**为什么不再多切。**确认策略与通知时段（R3）看起来也够一个 skill，但它对应的程序机制尚未实现；为还不存在的行为写 skill 会让读它的 AI 以为自己能做到。切的判据始终是这个：**先有能力，才有说明书**——`operating-a-terminal` 之所以该有，正是因为它讲的那批工具早就开着了。

### frontmatter 里没有 allow_clock_out

结构示意里早先带过这个字段，现已删除。「被按住的终端禁止下班」是程序硬闸（`src/poltergeist/Bus.zig` 的 `clockOff` 遇 `held` 返回 `TerminalHeld`），同一条约束有两个出处必然漂移；更糟的是 skill 文件用户可编辑，若程序采信文件里的值，用户改 skill 时就可能**无意中削弱一条安全约束**。硬闸只能有一个出处，而且必须在代码里。

frontmatter 现在只有三个字段（`skill.Meta`）：`name` / `version` / `description`。
正文原样交给 AI。**`mode` 随三份 mode skill 一起删了，`max_rounds` 也删了**，后者
的理由见下一节。

**这三个字段各有各的去处，而且去处不同**——这一点被写成了一条 comptime 守卫
（`test "every field the frontmatter carries has somewhere it goes"`）：

| 字段 | 去哪儿 |
| --- | --- |
| `name` | 和它所在的文件名对账；skill 装给 agent runtime 时被改写 |
| `description` | 随 frontmatter 装出去，是 runtime 据以挑中这个 skill 的东西 |
| `version` | 同上，是文件自己的版本，程序不据它分支 |

加第四个字段时 `@compileError` 会让构建停下，加的人必须先说清楚它去哪儿。
注释里特意写明**这是一张名单，不是一个推导**——没有任何东西能证明一个字段被读
了（`version` 和 `description` 在 Zig 侧其实一处也没被读，它们的消费者在这棵树
之外）。这条守的是「加字段要过脑子」，不是「字段一定有人读」。

顺带一个不写测试就抓不到的性质：`mode` 删掉之后，`mode: sideways` 这种写错的值
不再报 `BadField`，而是落进「未知字段一律忽略」那条路。这是对的——skill 文件是
用户的，多一个键不该让它读不进来——但意味着**旧文件里残留的 `mode:` 会被安静地
无视**，而不是提示用户删掉它。

### 「连续 n 次」由程序计数，判断交给 AI

R6 要求「连续 n 次执行后判断没必要再继续」。次数正是长会话里最容易被上下文冲掉的东西，而计数恰恰是程序擅长、提示词不擅长的。

落法：Bus 记录「自上次 `resumed` 以来这个终端被通知过几轮」（`Entry.rounds`），随 `terminal_list` 一并给出。程序供数，AI 供判断 —— 与整套设计的分工一致，且不需要新增工具。

**但那个 n 现在没有配置面，这是刻意的。** 曾经的打算是 frontmatter 里一个
`max_rounds`，skill 正文写「rounds 达到 max_rounds 就让它下班」。`max_rounds`
已经删了，理由是**它被解析、被校验、然后被扔掉——从头到尾没有任何代码读它**。

一个照收再扔掉的字段比一个明确拒绝的字段更坏：用户在自己的 skill 里写
`max_rounds: 5`，会以为配置了什么，而什么都不会发生，连一句「这个没用」都听不到。
（同一份 frontmatter 里 `allow_clock_out` 是被**明确拒绝**的，返回
`ConstraintInFrontmatter`——那才是对待一个不该生效的字段的正确方式。）

所以现在的分工比原设计更干净：**程序只报数，判断整个归总管。** 总管拿到
`rounds: 3` 和一屏内容，自己决定这算不算「够了」——这本来就是它每一轮在做的事。
哪天真需要一个可配的 n，那天再加，那时它会带着读它的代码一起来。

### 存放位置与优先级

照搬 themes 的两层结构：`themepkg.Location = { user, resources }`，注释明说枚举顺序即优先级、从上到下（`src/config/theme.zig:8-12`）；user 层由 `internal_os.xdg.config` 拼出、subdir 为 `polter/themes`（`src/config/theme.zig:31-33`；fork 改过名，上游写的是 `ghostty/themes`）。

**本设计选择**：内置默认 skill 放 resources 层，用户自定义放 `$XDG_CONFIG_HOME/ghostty/polter/skills/`，同名时 user 覆盖内置。三条理由：与 themes 完全同构，用户已有心智模型；user 目录可进 dotfiles 仓库，天然版本化；内置层随二进制升级，用户层不被覆盖。

**为什么不塞进 `src/config/Config.zig`**：该文件已 11336 行，且配置项是扁平 KV，而 skill 主体是多段自然语言 —— 塞进去要么变成超长单行字符串，要么要发明一套多行块语法。配置里只留一个指向 skill 名字的键。**为什么不编译进二进制**：R7 要求可维护、用户能改能加，编译进去直接违背。

### 结构示意

实际的内置 skill 在 `src/poltergeist/skills/`，安装到 `share/ghostty/poltergeist/`。下面是其中一份的开头：

```md
---
name: supervising
version: 1
description: 总管行事总则：收到通知先做什么、何时袖手、怎么措辞
---

每轮先用 terminal_read 看这个终端现在的屏幕内容，再判断……
（正文原样交给总管 AI 读，程序不解析。）
```

选 YAML frontmatter 加 Markdown 而不是自造 KV 格式，理由是**程序只需要读 frontmatter 里那三个字段**（`name` / `version` / `description`），正文原样丢给 AI，解析成本几乎为零；而这个格式恰好是 AI 侧 skill 生态的通行写法，用户不用学新东西。

### 怎么被总管取用与怎么维护

两个候选：(i) 建立监督关系时一次性注入总管上下文；(ii) 总管通过 MCP 工具按需读。**选 (i) 为主、(ii) 为辅** —— 行事总则是每轮都要用的判据，纯按需读等于每轮多一次往返；但保留一个 `skill_read(name)` 只读工具，让总管在上下文被冲掉后能自己找回来。

维护上：内置 skill 随仓库走，改动可 review；用户 skill 放进目录即生效。frontmatter 里的 `version` 应记进日志，便于事后复盘「为什么它当时判定下班」。（未核实：用户改了 skill 文件后是否需要重启 Ghostty —— themes 的加载时机本文只核实了查找路径未核实触发时机，核实方式是读 `src/config/Config.zig` 的 theme 载入调用点与配置重载路径。）

## 群带什么：任务说明，以及重建现场需要的材料

> **设计，尚未实现。**

群从「一串消息」扩成「一件事的全部现场」。两个来源的需求正好落在同一个地方：

1. 总管跑了八小时之后，`group_list` 给它的是 `build, research, nightly` —— **自己起的名字自己也认不出了**，而这恰是它要判断「哪个还需要盯」的时刻。
2. 关机或 Polter 被杀之后，要能把摊子重新搭起来（见 [supervisor.md](supervisor.md)「关掉再打开」），而重建需要的材料必须在重启后还在。

**所以群落盘，而且落的不只是消息。**

### 群带的东西

| 字段 | 谁写 | 谁读 | 为什么要 |
| --- | --- | --- | --- |
| `brief` 任务说明 | 只有总管 | **只有总管** | 八小时后认出这个群是干什么的 |
| 成员清单 | 程序 | 成员 | 群里有谁 |
| 每个成员的**工作目录** | 程序（建群/加人时记下） | 总管 | 重建时 `claude -r` 要在对的目录跑 |
| 每个成员的**启动命令**、**终端标题** | 程序 | 总管 | 重建时认出「哪个是 worker-core」 |
| 每个成员上次的**角色** | 程序 | 总管 | 认领回来之后照着设回去 |
| 每个成员上次**有没有被按住** | 程序 | 总管 | 只读不设：总管调不动 `setHeld`，快照让它知道，由用户决定要不要再按上 |
| 消息 | 成员 | 成员（按 floor） | 昨晚聊到哪了 |

工作目录这类字段由**程序**在加人时记下，不由总管填 —— 它是宿主本来就知道的事实，让 AI 转述一遍只会引入抄错的机会。

### `brief` 为什么只有总管能读

这不是给群里的人看的公告，是总管给自己的备忘。**写给自己的话和写给别人的话不是一回事** —— 一旦要考虑别人怎么看，写的时候就会开始斟酌措辞，而备忘的价值恰恰在于可以草率、可以写「这个先放着，等 B 那边定了再说」。

`group_read` 因此不返回它，只在 `group_list` 里对总管出现。这是工具面里第一处**返回值因调用者而异**的地方，理由与 `history: none` 同源：可见性是按人算的，不是按数据算的。

### 建群时就写

skill 里要求总管 `group_create` 之后**立刻** `group_set_brief` —— 那是它对这个群的意图最清楚的一刻。等到八小时后想起来要写，它已经想不起来了，而那正是需要这段字的时刻。

### 这算不算「管理任务」（R8）

**不算，但边界很近，所以要说清在哪一侧。**

| 禁令 | 群带的这些东西 |
| --- | --- |
| 不提供任务 CRUD | 不提供。它们是群的字段，不是可增删查改的任务实体 |
| 不持久化任务的结构 | 存的全是**文本与角色**：一段说明、一个目录、一条命令。没有状态机、没有依赖、没有负责人字段、不能被查询或排序 |
| 不解析任务描述 | 不解析。`brief` 对程序是不透明字符串，从不读内容 |
| 不做排序或依赖 | 不做。没有优先级，没有完成判定 |

**留给以后的判据**：谁要加「把 brief 标记为已完成」或者「按 brief 排序群」，那就是越过了 R8，应当拒绝。**存一段字不是管理，给这段字加状态才是。**

### 工具

| 工具 | 参数 | 可用角色 |
| --- | --- | --- |
| `group_set_brief(group, text)` | 群名、说明 | 总管 |
| `group_list()` | 无 | 全部；**但 `brief` 与重建材料只对总管出现** |
| `session_recall()` | 无 | 总管。返回上次落盘的群、成员与**所有开着过的终端**，**不做任何自动动作** |

`session_recall` 只读，读到之后干什么是总管的判断 —— 见 [supervisor.md](supervisor.md)「关掉再打开」的三步。

## 边界：Poltergeist 不管理任务

> **这一节的第 1 条已经不成立了。** 工具面上现在有 `task_create` / `task_assign` /
> `task_close` / `task_cancel` / `task_progress` / `task_list`。为什么这条被推翻、
> 新的界线画在哪（一行标题 + 负责的终端 + 开/关/取消 + 进度，没有别的字段），
> 见 [tasks.md](tasks.md)。第 2 到 4 条仍然成立并且是那条红线的内容：
> 面板没有依赖、没有优先级、不解析描述、不排序。
>
> 原文与原论证保留在下面，因为它怕的东西仍然对——「能力层长成一个任务系统」——
> 而 tasks.md 第一节正是靠回答这一段来立论的。

四条禁令，正面回答 R8：

1. **不提供任何任务 CRUD 工具** —— 工具清单里没有 `task_create` / `task_list` / `task_update` / `task_done`。
2. **不持久化任务的结构** —— 落盘的是聊天记录（见 [chatui.md](chatui.md)）、群的任务说明（见上一节）与监督关系快照（见 [supervisor.md](supervisor.md)「关掉再打开」）。这些都是**文本与角色**，没有一样带状态机：没有「未开始/进行中/已完成」，没有依赖，没有负责人字段，不能被查询或排序。**原文写的是「不持久化任务内容」，那句话过严了** —— 群任务说明确实是内容，但它对程序是不透明的一段字。判据是结构而不是内容：存一段字不算管理，给这段字加状态才算。
3. **不解析任务描述** —— 不从屏幕里提取「当前任务是什么」。
4. **不做任务排序或依赖** —— 没有队列、没有优先级、没有 DAG。

任务由其他系统 / 载体承载（看板、文件、issue 追踪器），AI 自己去读。

**代价写实**：总管看不到任务全貌，它能拿到的只有屏幕内容（`terminal_read`，底层是 `Surface.dumpText`，`src/Surface.zig:2015`）与聊天记录（`group_read` / `group_history`；私信最终没有做成独立工具，一对一的对话是一个只有两个成员的群），所以总管的判断天然是「就地可见」的判断，做不了跨任务的全局调度。

**为什么仍然值得**：任务载体种类繁多且每家 schema 不同，做进来必然做成半吊子；更糟的是会和用户已有的任务工具打架 —— 同一个任务出现在两处、状态不同步，用户要维护两份真相。把这条边界画死，Poltergeist 就永远只是一层能力，不会长成一个竞品任务系统。这条边界同时是工具面稳定性的来源：只要不碰任务，工具清单就不会随任务系统的演进而膨胀。

## 取舍记录

| 方案                                       | 成本                                                                                    | 为什么没选 / 为什么选                                                                                             |
| ------------------------------------------ | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **选**：sidecar `polter +mcp`      | 三处枚举登记 + 一个新文件（`src/cli/ghostty.zig:31-190`），无构建改动                   | 崩溃隔离；协议演进不动终端二进制；集成成本近乎为零                                                                |
| MCP server 塞进 Ghostty 核心               | 长连接状态挤进渲染 / IO 线程；每次协议改版动核心                                        | 核心崩了影响全部终端；与上游分叉面变宽                                                                            |
| 传输 (a) 扩展 `apprt.ipc` 并补 macOS       | 要给 union 加返回值通道；同步 `include/ghostty.h` 的 C ABI（`src/apprt/ipc.zig:57-71`） | macOS 三分支全 false（`src/apprt/embedded.zig:349-360`）；且它是单向命令通道，形状不对                            |
| **选**：传输 (b) 自建 unix socket          | 自管监听 / 鉴权 / 生命周期 / 崩溃清理；`src/` 现无 `std.net` 代码                       | 跨平台一份实现；请求-响应形状天生正确；与上游零耦合，分叉面最小                                                   |
| 传输 (c) 文件系统 / 命名管道               | 轮询有延迟，或上 inotify / FSEvents 变两套平台代码                                      | 并发写、残留文件、权限位都要自己兜，省下的复杂度会换个形式还回来                                                  |
| 传输 (d) 复用 macOS AppleScript            | 已有 `input text` / `send key`（`macos/Polter.sdef:221`、`:229`）                      | macOS-only；需 osascript 往返；**没有宿主 → sidecar 的推送方向**                                                  |
| **选**：鉴权用 bool 准入闸门（默认关）     | 一个配置项 + 各入口 gate                                                                | 照抄 `macos-applescript`（`src/config/Config.zig:3705`）的形态；默认值反过来取关，未配置的 Ghostty 不多出受攻击面 |
| 鉴权用 `allow` / `ask` / `deny` 三态       | 与 `clipboard-read`（`src/config/Config.zig:2670`）同构                                 | 挂机过夜无人值守时 `ask` 等于卡死                                                                                 |
| **选**：读屏用 `Surface.dumpText`          | 自带渲染锁，输入是 selection（`src/Surface.zig:2015`）                                  | 能精确表达「最近 N 行」；不受渲染态截断影响                                                                       |
| 读屏用 `RenderState.string`                | 现成                                                                                    | 视口上下被截断的软换行不含在内（`src/terminal/render.zig:852-854`），会缺行                                       |
| 读屏用 `Screen.dumpStringAlloc`            | 现成                                                                                    | 注释自称主要供单元测试（`src/terminal/Screen.zig:3611-3612`），且一次写一字节                                     |
| **选**：注入走 `textCallback` 粘贴通道     | 多一跳编码                                                                              | 自动继承控制字节剥除（`src/input/paste.zig:46-91`），`\x03` 不会变 Ctrl+C                                         |
| 注入走键绑定 `text` action 的直写路径      | 更短                                                                                    | 绕过 `input.paste.encode`（`src/Surface.zig:4873-4888`），无剥除                                                  |
| **选**：消息只注入通知                     | 多一次工具往返（先注入通知，再等对方拉取）                                              | 不吃对方上下文；主动拉取本身带判断力                                                                              |
| 消息注入正文                               | 零往返                                                                                  | 长正文灌爆对方上下文；替 AI 做了「现在必须处理」的决定                                                            |
| **选**：skill 存 user + resources 双层     | 一套查找逻辑                                                                            | 与 themes 同构（`src/config/theme.zig:8-12`）；可进 dotfiles；升级不覆盖                                          |
| skill 塞进 `src/config/Config.zig`         | 该文件已 11336 行；扁平 KV                                                              | 多段自然语言塞不进 KV，要么超长单行要么发明多行块语法                                                             |
| skill 编译进二进制                         | 最省运行时                                                                              | 直接违背 R7「可维护、用户能改能加」                                                                               |
| **选**：判断在提示词、约束在程序           | 两处维护                                                                                | 语义判断会随 UI 改版烂掉；而提示词会被长会话冲掉，程序不会                                                        |
| 监督判断做成纯程序状态机                   | 可测试                                                                                  | 「没必要再继续」是语义判断，写死判据随被监督程序改版失效                                                          |
| **选**：三态工作模式整套换成一个只有用户能设的布尔 `held` | 总管失去了排班能力，做不了「把这台放进无限模式」 | 三种模式里有两种在讲总管每轮本来就在做的判断（还有没有必要继续），重复；而模式切换只在切换那一瞬发一句提示，之后就被上下文挤掉了。换成布尔之后闸只有一处，且中间没有可绕的一步 |
| **选**：`become_supervisor` 对所有角色开放，在 handler 里按角色拒 | 白名单里多一个「谁都调得到」的写工具，看着刺眼 | 它唯一的服务对象是无主终端，而无主终端按定义不是总管——`requiresSupervisor=true` 会让这个工具对它唯一的用户不可用 |
| **选**：不提供任何任务工具                 | 总管做不了跨任务全局调度                                                                | 任务载体 schema 各异必成半吊子；与用户已有工具打架会产生两份真相                                                  |
| **选**：工具面拒绝写 `cmd:` 引用           | 用 1Password 的用户得自己把那一行写进文件（agent 可以把它念给用户）                     | `cmd:` 是唯一一种引入**新代码**的引用，其余三种只搬运用户已经放好的数据；写一条等于让 Polter 在授权结束之后自己去跑 |
| **选**：关闭插件只能由用户做               | 总管收拾不了一个吵闹的通知渠道                                                          | 通知是挂机时用户**唯一**的知情通道，能掐掉它等于能给自己关灯；与 `held` 那条"只有用户能设"同形                     |
| **选**：`plugin_test` 从不起第二个实例         | 测不出"这个 dsn 到底连不连得上"，只能报正在跑的那个实例的状况                        | 协议无干跑字段且宿主强制不了；握手本身有副作用；两个实例会把每件事各处理一遍                                       |
| **选**：插件用同一个工具面、同一套线协议，而不是一份 SDK | 插件能做的事从此跟着工具面走，加一个方法就多一个插件能调的东西 | 一份手写的 SDK 就是第二份清单，而第二份清单会漂移——`Kind` 那个 bug 出过两次，两次都是清单漏了一项。见 [plugins.md](plugins.md) 第三节 |
| **选**：插件永远不是总管，且 `shielded` 对它绝对 | 一个插件够不着被监管的终端，也够不着护盾终端，哪怕用户信任它 | 方向：放宽容易收紧难。授权的路留着，形状和 `held`/`shielded` 一样——**只有用户能设**。而 `terminal_action` 刚证明过第二扇门会漏掉第一扇门的所有闸 |

## 未决问题

1. 服务端线程在 Ghostty 进程内挂在哪一层 —— 是否存在可复用的 app 级后台循环，还是需要新起一条线程再经 `App.Mailbox.push`（`src/App.zig:3499-3505`）回主线程。
2. sidecar 的进程模型 —— 每个 AI 进程起一个实例（stdio transport），还是一个常驻实例多路复用。本设计倾向前者且不负责其生命周期（由 AI 客户端按其 MCP 配置拉起），但仓库内无可参照先例。
3. 文本与回车两步的原子提交是否需要新增批量写入原语（见「原子性与竞态守卫」）。
4. 「最近 N 行」的 selection / pin 构造方式。
5. skill 文件改动后的生效时机 —— 是否需要重启，能否复用配置重载路径。
6. 监督关系与角色配置是否需要跨 Ghostty 进程重启持久化，还是每次挂机重设一遍（与 `README.md` 未决问题 4 同源）。

## 延伸阅读

- [README.md](README.md) — Poltergeist 设计总览与五章索引。
- [\_spec.md](_spec.md) — 写作规范与统一术语表。
- [sensing.md](sensing.md) — 静止时长怎么测。
- [supervisor.md](supervisor.md) — 监督关系、按住、确认策略、竞态守卫。
- [chatui.md](chatui.md) — 群聊与私信界面。
- [tabs.md](tabs.md) — tab 合并与状态标记。
- [platform-and-config.md](../platform-and-config.md) — Ghostty 配置系统现状。
- [architecture.md](../architecture.md) — Ghostty 模块地图与线程模型。
