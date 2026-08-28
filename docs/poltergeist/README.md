# Poltergeist 设计总览

> 最后更新对应的 git commit：`908f55b1f`（工作模式换成「按住」这一轮改动尚在工作树里，未提交）
> 校验方式：`git log -1 --format='%H %h %ad %s'`
> 状态：**S0–S4 全部落地并在真机上验证过**。见 `src/poltergeist/`、`src/cli/mcp.zig`、`src/cli/chat.zig`。界面绕过一圈：macOS 原生窗口做出来后被否掉，改回终端内 TUI，见 [chatui.md](chatui.md)「决策变更」。
> 整条链路已用真实 Claude Code CLI 跑过一轮，并因此改掉了两个单元测试结构上发现不了的致命 bug —— 见「验证到什么程度」。GTK 侧的聊天窗口未做。

## 本章覆盖什么

- Poltergeist（能力层）是什么、和宿主终端 Ghostty 是什么关系。
- 真实使用场景：用户怎么把已经开好的几个 AI 终端交给一个总管照看。
- 本次修订后的八条核心原则，每条附理由。
- 四层架构图，以及它挂在 Ghostty 现有结构上的具体位置。
- 各章索引、分阶段路线、安全边界的一句话结论、未决问题。

## 本章不覆盖什么

- 屏幕静止怎么测、成本多少、阈值怎么定 —— 见 [sensing.md](sensing.md)。
- 监督关系、上班 / 下班、按住、确认策略、通知时间段 —— 见 [supervisor.md](supervisor.md)。
- MCP 工具清单、sidecar、身份识别、skill 体系 —— 见 [mcp.md](mcp.md)。
- 怎么动手写一个插件（含自测） —— 见 [writing-a-plugin.md](writing-a-plugin.md)。
- 群聊与私信界面的承载方式选型 —— 见 [chatui.md](chatui.md)。
- tab 合并与状态标记的平台差异 —— 见 [tabs.md](tabs.md)。
- 写作规范与术语表 —— 见 [\_spec.md](_spec.md)。
- Ghostty 现有架构、屏幕数据结构、apprt 与配置、构建与调试命令 —— 分别见 [architecture.md](../architecture.md)、[terminal-core.md](../terminal-core.md)、[platform-and-config.md](../platform-and-config.md)、[preview-manual.md](../preview-manual.md)。

## 一句话概括

Poltergeist 是加在 Ghostty 之上的能力层（命令名 / 短名 polter），让用户把**已经自己开好、自己派好活**的多个 AI 终端交给一个「总管」终端去照看；Ghostty 侧只当传感器和管道，所有语义判断交给总管 AI。

## 真实使用场景

用户并行处理多摊事 —— 一边开发，一边做研究，每摊各占一个终端里的一个 AI agent。**agent 是用户自己逐个打开的，任务也是用户自己分配的**，Poltergeist 不代劳这两件事。

典型场景是「白天没干完，晚上挂机继续」：工作了一天，有几个终端里的任务还没收尾，用户下班前把它们托管给总管，人去睡觉，机器继续跑。

托管流程五步：

1. 开启群聊。
2. 指定某个终端为总管。
3. 定义总管监督哪几个终端。
4. 把不许停的终端按住。
5. 想停的时候，停掉监控。

这条流程不需要新的身份机制：Ghostty 现在已经给每个 surface 分配 `Surface.id`（`src/Surface.zig:57-62`）并以 `GHOSTTY_SURFACE_ID` 注入 pty 子进程环境（`src/Surface.zig:651-655`），「哪个终端」这件事在现状代码里已经是可寻址的。

## 修订后的核心原则

本节是全文的宪法。每条都写了理由，因为后面五章的所有取舍都要能回溯到这里。

### P1 程序只当传感器（R1）

Poltergeist 只测一个量：**这个终端的屏幕有多久没变化了**。达到配置的静止阈值就按配置通知总管。**由总管 AI 去看对方的界面内容，自己判断该叫一下对方还是继续等。**

理由有二。其一，测「变没变」比解析「变成了什么」便宜得多，量级差在一个哈希和一次全屏文本理解之间。其二，语义判断本来就是 AI 擅长、程序不擅长的事 —— 程序侧写死的判据会随被监督程序的 UI 改版一起烂掉。

因此程序侧**不再做** spinner 剔除、四态推断这类判断。展开在 [sensing.md](sensing.md)。

### P2 不做自动点 yes（R2）

Claude Code 自己有自动模式，没必要重复造；更重要的是，替对方按下工具授权的「yes」等于废掉对方的安全模型。本设计**明确不做这件事**，只在 [supervisor.md](supervisor.md) 的安全一节保留这条说明。

### P3 需要人确认时二选一（R3）

由用户配置：(a) 总管代理用户决策；(b) 通知用户，且用户可设定允许打扰的**通知时间段**（例如只在 09:00–22:00）。

选「二选一 + 时段」而不是「一律通知」，是因为挂机过夜正是主场景 —— 半夜把人叫醒会让整套东西失去意义。展开在 [supervisor.md](supervisor.md)。

### P4 没有一键开关（R4）

只有「停掉监控」这一个动作。监控一停，总管自己就停下来了；其他 agent 干完手头任务也会自然停下。

理由：一键开关会诱导用户把它当保险丝用，而真正的停止语义是「不再产生新的催促」，不是「冻结所有进程」—— 后者做不到，也不该假装做得到。

### P5 用户按住，其余归总管（R6）

**这条原则替换了原来的 P5「监工模式按终端各自设定」。原来那条被整条否掉了，
理由记在下面——它比新规则本身更值得读。**

现在的规则：每个终端有一个布尔 `held`，**只有用户能设**。立起来的意思是「这个
不许停」，程序据此拒绝 `clock_out`（返回 `TerminalHeld`）。tab 上常驻一个环
（`◉` 在动 / `◎` 静止）让这件事一直看得见。展开在 [supervisor.md](supervisor.md)。

**原来那条是什么。** 每个被监督终端各自设三种工作模式之一：下班模式（连续 n 次
判定无事可做后打下班标记）、定向无限、接续无限；无限模式在程序层面禁止下班。

**为什么被否掉，两条，都是实际用起来才看出来的：**

1. **三种模式里有两种在讲总管本来每一轮都在做的事。** 「定向无限」是「照着这个
   方向继续」，「接续无限」是「做完一个接下一个」——而总管每次被唤醒，本来就要
   核定目标、判断还有没有必要继续。**把它编码成一个每终端的枚举，是把一个判断
   变成了一份配置**，然后要求用户去维护它。
2. **模式切换只在切换那一瞬间说一句话。** 旧实现里切模式会往终端里注入一句提
   示，之后这句话就随上下文被挤走了。**一个只在设定那一刻存在的状态，等于没有
   状态**——挂机过夜恰恰是上下文最容易被冲掉的场景，也正是这个机制该起作用的
   场景。取代它的环是常驻的：只要按住还在，它就一直在 tab 上。

**留下来的是那条硬闸的形状。** 「用户说了不许停就不许停，这条约束放程序不放提
示词」这句话仍然成立，只是它现在挂在一个布尔上而不是一个枚举上。旧方案要防的洞
（总管先改模式再让它下班）在新形状下不存在——不是因为守得更严，是因为**中间那
一步没有了**。

### P6 判断归 skill，配置不归（R7）

**这条原则也改了。原来是「模式即 skill」——上面那几种模式本质就是几个不同的
skill；模式没了，这句话也就没了对象。**

留下来的是它更一般的那一半，而且是原话里本来就有的：**Skill 体系集成在
Poltergeist 里、可维护——用户能改、能加、能版本化，而不是编译进二进制。**

变的是 skill 的粒度。曾经是 5 份（2 通用 + 3 模式），现在是 2 份，都是通用的：
`supervising`（行事总则）和 `reading-a-terminal`（怎么看一屏内容）。三份
`mode-*` 随模式一起删掉了，理由和 P5 第 1 条同源——**它们在讲的判断，总管每一轮
本来就在做。**

同时删掉的还有 skill frontmatter 里的 `mode` 字段。展开在 [mcp.md](mcp.md)。

### P7 边界铁律：不管理任务（R8）

Poltergeist 本身不管理任务。任务由其他系统 / 载体承载，AI 自己去读。Poltergeist 不干涉任务内容、不存任务、不排任务。

理由：一旦开始存任务，就要处理任务状态、依赖、冲突、持久化，能力层会长成一个任务系统，而市面上已有的任务载体比我们做得好。落实方式展开在 [mcp.md](mcp.md)。

### P8 界面要看得见（R9、R10）

群聊与私信要有界面（[chatui.md](chatui.md)）；多终端可合并到 tab 菜单显示并打状态标记（[tabs.md](tabs.md)）。

打 tab 标记在现状代码里有先例可循：GTK 侧响铃时走 `page.setNeedsAttention(true)`（`src/apprt/gtk/class/tab.zig:459`），macOS 侧已有 per-tab 颜色标记 `TerminalTabColor`（`macos/Sources/Features/Terminal/TerminalTabColor.swift:4`）。

## 架构图

下图各层现已全部落地；每个挂接点的 `路径:行号` 是当初调研的结果，行号可能已随改动漂移，以文件为准。

```text
┌── 用户层 ──────────────────────────────────────────────────────────┐
│ 自己开 agent / 自己分配任务 / 指定总管 / 定义监督关系             │
│ 按住不许停的终端 / 设确认策略与通知时间段 / 停掉监控              │
└──────────────────────────────┬────────────────────────────────────┘
                               │
┌── 界面层 ─────────────────────▼───────────────────────────────────┐
│ 群聊 / 私信界面  →  chatui.md                                     │
│ tab 合并 + 状态标记（上班中 / 下班休息）  →  tabs.md              │
│   挂接点：set_tab_title action   src/apprt/action.zig:209         │
└──────────────────────────────┬────────────────────────────────────┘
                               │
┌── 控制层（全部在 AI 侧）──────▼───────────────────────────────────┐
│ 总管终端里的 AI  +  skill 体系  +  MCP 工具面                     │
│   →  supervisor.md / mcp.md                                       │
│   身份来源：GHOSTTY_SURFACE_ID   src/Surface.zig:651-655          │
│   派活注入：Surface.textCallback src/Surface.zig:3308             │
│   终端清单：App.surfaces         src/App.zig:27-28                │
└──────────────────────────────┬────────────────────────────────────┘
                               │ 达到静止阈值 → 通知总管
┌── 感知层（Ghostty 侧）────────▼───────────────────────────────────┐
│ 每个 surface 一个静止采样器，只输出「静止时长」这一个量           │
│   →  sensing.md                                                   │
│   可挂定时器：termio 线程的 libxev 循环 src/termio/Thread.zig:279 │
└───────────────────────────────────────────────────────────────────┘
```

一句话读图：**控制层完全在 AI 侧，Ghostty 侧只有感知层与管道。** 这条分界线决定了改动主要落在新增代码上，与上游 ghostty-org/ghostty 的分叉面可控。

## 各章索引

| 章节                           | 对应修订项 | 一句话内容                                                | 关键取舍                                                                           |
| ------------------------------ | ---------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [sensing.md](sensing.md)       | R1         | 每个 surface 采样屏幕指纹，只输出静止时长                 | 不复用 `Row.dirty`（`src/terminal/page.zig:2004`），因为它被渲染路径消费即清零     |
| [supervisor.md](supervisor.md) | R3、R4、R6 | 监督关系、上班 / 下班、按住、确认策略、停掉监控           | 被按住的终端禁下班，这条约束放程序侧而非提示词                                     |
| [mcp.md](mcp.md)               | R7、R8     | MCP 工具面、sidecar、身份识别、skill 体系、不管任务的边界 | sidecar 而非把 MCP 塞进核心；现成 IPC 不可复用（`src/apprt/embedded.zig:349-360`） |
| [chatui.md](chatui.md)         | R9         | 群聊与私信界面的承载方式                                  | 原生 UI（参照 command palette）对比 imgui（参照 `src/inspector/Inspector.zig`）    |
| [plugins.md](plugins.md)       | R3 的一半  | 插件宿主：进程式插件、两种生命周期、凭据、权限声明         | 进程边界换崩溃隔离与语言无关，代价是每次通知一次 fork/exec |
| [storage.md](storage.md)      | —          | 存档：本地日志是事实来源，插件是它的跟读者              | 常驻进程 + 游标；一个插件多后端；权限声明 |
| [writing-a-plugin.md](writing-a-plugin.md) | — | 照着做的插件开发指南：从零一个 notify、不启动 Polter 怎么自测、archive 的常驻与游标、常见错误 | 自测藏进插件自己（`--self-test`），因为拿到插件的人不该为验它先装一套东西 |
| [surface.md](surface.md)      | —          | 菜单栏逐条盘点：哪些该经 MCP 开放给 AI，哪些故意不给    | 判据是「会不会让读到一段文字变成在这台机器上做一件事」 |
| [gaps.md](gaps.md)            | —          | 作为 AI 原生终端还差什么：感知、记录、双向渠道、成本、注入 | 未实现的设计讨论；记录那一条是重点 |
| [tabs.md](tabs.md)             | R10        | tab 合并与状态标记                                        | macOS 用 NSWindow tabbing，GTK 用 libadwaita，两套各写一份                         |

## 分阶段路线

全部落地。「验证方式」一栏写的是**实际做到的**，不是当初计划的。

| 阶段 | 内容                                    | 验证到哪一步                                                                  |
| ---- | --------------------------------------- | ----------------------------------------------------------------------------- |
| S0   | 静止采样 + 日志，不通知任何人           | 单测覆盖判定逻辑；未在真实长任务上人工核对过静止判定                          |
| S1   | 通知总管                                | 单测覆盖 Bus 与注入守卫；跨线程投递路径只做过编译验证                         |
| S2   | MCP 工具面、socket、sidecar、skill 体系 | **真实 unix socket 端到端测试**（握手 / 多请求 / 停机）；MCP 侧未接过真 agent |
| S3   | 群（模型层）                            | Chat 单测；真机验证了 `history: none` 的隔离                                  |
| S3'  | 界面 `polter +chat`                     | 真机跑通：三栏、成员清单、本地时刻、以「你」发言、落盘                        |
| S4   | tab 状态标记                            | 真机看过：`●` 上班 / `○` 静止 / `💤` 下班 / `⚑` 总管                          |

**共 152 个 poltergeist 单测**，加上 Ghostty 自身 3500+ 个测试的全量回归。

## 验证到什么程度

诚实地讲清楚每一层：

| 层                                                                  | 手段                                | 覆盖到什么             |
| ------------------------------------------------------------------- | ----------------------------------- | ---------------------- |
| 纯逻辑（感知 / Bus / Chat / 权限 / 线协议 / skill）                 | 原生 `zig test`                     | **真跑过**，152 个用例 |
| socket 链路                                                         | 真实 unix socket + 真客户端         | **真跑过**             |
| 全部 Zig 代码                                                       | macOS 原生构建 + GTK 容器构建       | 编译期，两个 apprt 都过 |
| SwiftUI                                                             | `swiftc -typecheck`，部署目标 13.0  | 编译期                 |
| 全量测试套件                                                        | 本机原生 `zig build test`（含 Metal） | **真跑过**             |
| **整条链路（终端里跑 agent → 静止 → 通知总管 → MCP → 群聊 → tab）** | 真实 Claude Code CLI，四个终端        | **真跑过**，见下       |

最后一行**已经跑过了**，而它抓到的东西比前面所有复核加起来都关键。用真实 Claude Code CLI 起了四个终端（一个总管、三个干活），让它们协作写一个命令行工具：

- **三个 agent 通过群聊真的协作完成了任务** —— 8 条消息里定接口、对齐契约、落盘，最后 101 个测试全过。总管写的 `report.md` 明确记着它没有替别的 agent 点权限确认、没改 work mode：硬约束在真实 AI 身上生效。
- **抓到两个致命 bug，都是单元测试结构上不可能发现的**：
  - 静止阈值与重复间隔在从配置到采样器的路上被多除了一次 `ns_per_ms`，双双塌成 1 秒。三个终端就是每秒三行，把总管该处理的信号淹掉。单测直接构造 `Sampler.Config`，从不走这段转换。
  - agent 的 MCP 请求入队后**没有唤醒 app 线程**，要等某个无关事件碰巧把它叫醒。实测响应时间在 50ms 到超时之间随机跳。单测直接调 `dispatch`，从不走 mailbox。修复后稳定在 0.2ms。

S2 那轮的教训因此要改写得更狠：一个致命 bug 可以通过编译、通过 130 个单测、通过双目标类型检查、经过 25 个 agent 的代码审查 —— 而**它所在的那条路径根本没有被执行过**。真实执行不是最后一道保险，它是唯一能覆盖「层与层之间」的手段。

第三栏两处措辞是 S3 复核后改的，因为原来写的**不成立**：

- 「Linux 与 macOS 双目标类型检查」实际跑的是 `-Dapp-runtime=none`，**根本不编译 GTK**。`toggle_poltergeist_chat` 这个 apprt action 加进枚举后，GTK 的穷举 `switch` 少一个分支，GTK 构建从那时起就是坏的 —— 三轮复核都没发现，因为验证命令从来没走过那条路。现在用容器做真实 GTK 构建。
- 「`swiftc -typecheck`」当时没有指定部署目标，于是按 SDK 的最新版本检查，放过了两处 macOS 14 才有的 API（这个 app 部署到 13.0）。现在固定 `-target arm64-apple-macos13.0`。

教训是同一个：**验证命令覆盖不到的地方，等于没验证** —— 而它看起来和验证过一模一样。

### GTK 现在真编过了（S4 补）

在开发机上装了 `gtk4`、`libadwaita`、`blueprint-compiler` 之后：

```
zig build -Dapp-runtime=gtk -Dtarget=x86_64-linux-gnu -Demit-macos-app=false
```

**Zig 侧语义分析全过**，包括所有 apprt action 的穷举 `switch`。只在最后链接 Linux 动态库时失败（Mac 上没有 `.so`），这一步和代码正确性无关。也就是说上面记的那个 GTK 穷举 switch 问题确实已经修好了，而且这次是编译器说的，不是覆盖率脚本猜的。

**注意不要走 `-Dapp-runtime=gtk` 而不带 `-Dtarget`**：那是「macOS 上的 GTK」，上游不支持这个组合，会在 `Surface.encodeKey` 里撞上 `keyboardLayout()`（macOS 分支要的方法 GTK 的 App 没有）。这不是本项目的问题，也不能当成 GTK 构建失败的证据 —— 真实目标是 Linux。

## 怎么试

需要一台装了 **Xcode 26** 的 macOS（构建 app 必需），或者一台 Linux（GTK 侧没有聊天窗口，其余可用）。

```sh
# 1. 构建
zig build -Demit-macos-app=false
macos/build.nu --scheme Ghostty --configuration Debug --action build
open macos/build/Debug/Ghostty.app
```

配置里打开两个开关：

```ini
poltergeist-watch = true
poltergeist-mcp = true
```

然后：

1. 开两个终端，都跑起 agent。
2. 在其中一个上执行命令面板的 **Make This Terminal the Supervisor**。
3. 在另一个上执行 **Toggle Supervision of This Terminal**。
4. 让被监督那个静置超过 `poltergeist-quiescence-after`（默认 3 分钟）。
5. 看总管终端有没有收到 `[poltergeist] terminal 0x... has gone quiet`。

要试 MCP，把 `polter +mcp` 配给总管里的 agent 当 MCP server（socket 与 token 已经在它的环境变量里，不用配）。要试群聊，让总管调 `group_create` / `group_add`，再用命令面板的 **Show Terminal Conversations** 打开窗口。

**没跑通的话**：先看日志（`GHOSTTY_LOG` 的用法见 [preview-manual.md](../preview-manual.md)），`poltergeist:` 前缀的行会说明它认为自己在做什么。

## 安全边界## 安全边界

- **明确不做自动点 yes**（P2）。理由见上：替对方按授权键等于废掉对方的安全模型，且 Claude Code 自己已有自动模式。
- 注入路径复用现有的粘贴通道 `Surface.textCallback`（`src/Surface.zig:3308`）→ `completeClipboardPaste`（`src/Surface.zig:5914`），从而继承 bracketed paste 封装与控制字节剥除（`src/input/paste.zig:46-91`），不另开一条绕过既有编码的旁路。**但继承的不是不安全粘贴确认** —— 调用点传的是 `allow_unsafe = true`（`src/Surface.zig:3313`），确认分支据此直接放行（`src/Surface.zig:5936-5938`），所以长度上限与内容白名单必须由 Poltergeist 自带，见 [mcp.md](mcp.md)。
- 通知要限流。现状代码里已有可直接参照的写法：`showDesktopNotification`（`src/Surface.zig:6038`）用 Wyhash 摘要 + 时间戳做「每秒最多一条」「相同内容短期抑制」。
- 完整的权限矩阵、审计日志、鉴权与竞态守卫展开在 [supervisor.md](supervisor.md) 与 [mcp.md](mcp.md)。

## 与旧文档的关系

`docs/agent-loop-design.md` 是本设计的第一版草案，已被本目录取代并**删除**（该文件未被 git 跟踪）。仍然成立的内容已吸收进本目录，被推翻的部分逐条记录如下，避免日后有人凭记忆把它们改回去。

被推翻的部分：

- **感知层四态推断**（working / thinking / idle / stalled）→ 简化为单一「静止时长」标量。理由见 P1。（[supervisor.md](supervisor.md) 里的上班 / 静止待判 / 等确认 / 下班是另一回事：那是总管侧的簿记状态，不含对屏幕内容的判断。）
- **语义哈希**（剔除 spinner、计时、token 计数）→ 删除。spinner 在转说明对方在思考，正是我们想让总管看见的信号，剔除它反而丢信息。术语「语义哈希」全面废弃，改用「屏幕指纹」。
- **自动回答权限询问的可选设计** → 删除，只保留「我们明确不做这件事」（P2）。
- **急停键 / 全局开关 / `agent_stop_all` 键绑定** → 删除，改为单一的「停掉监控」（P4）。
- **规则引擎 DSL**（`agent-rule = on=... do=...`）→ 大幅收缩。判断转移到 skill，配置只保留静止阈值、确认策略、通知时间段这几项。
- **命名 `Ghostty Agent Loop` / `src/agent/` / `ghostty +agent-mcp`** → 统一改为 Poltergeist / polter。

被继承的部分，各指向新的归属章：

- 注入走 `Surface.textCallback` 复用粘贴路径 → 见上「安全边界」与 [mcp.md](mcp.md)。
- 文本与回车必须分两步（bracketed paste 下换行不提交）→ [mcp.md](mcp.md)。
- 竞态守卫（用户正在打字 / 输入框非空 / 注入回环）→ [supervisor.md](supervisor.md)。
- sidecar 而非把 MCP 塞进核心 → [mcp.md](mcp.md)。
- 消息送达只注入通知、不注入正文 → 机制与限流见 [mcp.md](mcp.md)，界面呈现见 [chatui.md](chatui.md)。
- 权限矩阵与审计日志 → [supervisor.md](supervisor.md)。

## 已定的决策

用户在设计评审中拍板的事项，记录在此以免日后被当作待议项重开：

| 决策         | 内容                                                             | 落点                                           |
| ------------ | ---------------------------------------------------------------- | ---------------------------------------------- |
| 产品名       | 能力名 **Poltergeist**，命令名 **polter**                        | 全目录                                         |
| 聊天界面平台 | **一期只做 macOS 原生 UI**，GTK 推后到二期                       | [chatui.md](chatui.md)「选型结论与分期」       |
| Skill 形态   | **给总管 AI 读的提示词**，不是程序侧状态机；约束部分仍是程序硬闸 | [mcp.md](mcp.md)「skill 是提示词，不是状态机」 |

## 未决问题

1. 静止阈值的默认值取多少，以及是否需要按被监督程序类型给不同预设 —— 待实测数据。默认 3 分钟是猜的。
2. ~~采样来源落在哪一层~~ —— **已定并落地**：termio 线程的 libxev 定时器，每秒一次（`src/termio/Thread.zig`）。选它而不是渲染线程，是因为窗口不可见时渲染线程根本不跑，而挂机过夜正是窗口不可见的时候。
3. 关机/重启后恢复 —— **已定：程序保存材料，总管重建现场**（不做程序自动还原，理由是那要求程序判断「这个终端是不是上次那个」，与 P1 冲突）。设计见 [supervisor.md](supervisor.md)「关掉再打开」与 [mcp.md](mcp.md)「群带什么」。尚未实现。
4. Skill 体系的存放位置与更新方式 —— 已定并落地：内置在 resources 目录，用户副本在配置目录且优先。见 [mcp.md](mcp.md)。
5. ~~GTK 侧的聊天窗口~~ —— **已作废**。界面改成终端内 TUI（`polter +chat`）之后，任何能开终端的平台就有聊天界面，不需要第二份实现。见 [chatui.md](chatui.md)「决策变更」。
6. 确认策略与通知时间段（R3）—— 设计已定，**尚未实现**，见 [supervisor.md](supervisor.md)。其中「通知用户」这一半的送达方式改为插件体系，见 [plugins.md](plugins.md)。
7. 群带任务说明与重建材料 —— 设计已定，**尚未实现**，见 [mcp.md](mcp.md)「群带什么」。
8. 多群并行从未测过。真机两轮都只开了一个群。

## 延伸阅读

- [\_spec.md](_spec.md) — 本批文档的写作规范与统一术语表。
- [README.md](../README.md) — Ghostty 开发文档索引。
- [\_conventions.md](../_conventions.md) — 通用文档规范，本批规范继承自它。
- [architecture.md](../architecture.md) — Ghostty 模块地图与每个 surface 的线程模型。
- [preview-manual.md](../preview-manual.md) — 构建、运行、调试命令的唯一权威。

## 测试为什么会「全绿但没跑」

`src/poltergeist/main.zig` 的 `test {}` 块里必须逐个 `_ = Module;`。**Zig 只分析被引用到的东西**——在 `pub const` 里导出一个模块不算引用它的测试。名字在上面、不在 `test {}` 里的模块，它的测试既不会失败也不会运行，而且没有任何东西会提示你。

`ChatLog`、`Plugin`、`notify`、`secret`、`Session` 五个模块曾经就是这样，加回来之后测试数从 3573 变成 3610。恢复路径的那个 bug 正是躲在一堆「看起来在通过」的测试后面——**它们从来没被编译过**。

在上面加一行 import，就要在 `test {}` 里加一行。
