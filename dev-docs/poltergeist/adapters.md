# CLI 适配器：hook 优先，屏幕兜底

> 状态：**设计，未实现**。分支 `feature/v0.9`，起点 `acb2cd090`。
> 事实源：Claude Code 官方文档 hooks / agent-teams / cross-session-messaging 与
> anthropics/claude-code `CHANGELOG.md`（2026-09-27 取原文）；其它六家见第八节。
> 代码位置取自 `acb2cd090` 这棵树，行号带树名才有意义（见仓根 CLAUDE.md）。

## 本章覆盖什么

- 为什么在「屏幕静止时长」之外再接一路 hook，以及这推翻了 [sensing.md](sensing.md) 的哪一条。
- 底层（与 CLI 无关）和适配器（每家一个）各管什么。
- Claude Code 适配器第一期：最低版本、注入方式、事件词汇、送到总管的形状。
- 其它 CLI 的最低版本与能拿到的事件（只列，不在第一期做）。
- 分期、判据、测试分工。

## 本章不覆盖什么

- 屏幕静止怎么测 —— [sensing.md](sensing.md)，不变，仍是兜底。
- 插件协议与 provision —— [plugins.md](plugins.md)、[provisioning.md](provisioning.md)。
- 角色怎么拼命令行 —— [roles.md](roles.md)；本章只往那条命令行里加东西。

## 一句话概括

**CLI 自己知道它处在什么状态，屏幕只能让人去猜。** 能问 CLI 的就问 CLI（hook），问不到的
（不支持的 CLI、hook 没接通、版本太旧）才看屏幕。每家 CLI 的「怎么问」「怎么开」「怎么用好」
放在那家自己的插件里；Polter 底层只认一套与 CLI 无关的事件词汇。

## 一、为什么要改，改的是哪条旧决定

[sensing.md](sensing.md)「结构化信号只当可选增强，且默认关」那条的三个理由是：覆盖不全、
语义对不上、多一路口径要维护。它说的是 OSC 9 / 133 这类**终端转义序列**，三条对它都成立。

对 hook 它们不成立：

- **语义对得上。** Claude Code 的 `Stop` 就是「一轮结束」，并直接带着最终答案
  （`last_assistant_message`）；`StopFailure` 就是「一轮因 API 错误结束」，带错误类型。
  OSC 133 标的是 shell 命令结束，对长驻的 agent CLI 永远不触发。
- **维护的是对方的接口，不是对方的 UI。** sensing.md 拒绝语义判断的第一理由是
  「模式匹配要跟着对方 UI 版本走」。hook 的字段是各家写进文档、写进 CHANGELOG 的接口。
- **覆盖问题换了形状**：不是「某个信号没人发」，而是「某家 CLI 不支持」——这由屏幕兜底，
  而且可以按 CLI 精确知道缺哪一格（第八节表）。

⇒ sensing.md 那条要改成：「OSC 类信号仍不消费；CLI 的 hook 由适配器接入，见 adapters.md」。
**屏幕静止时钟不关、不降级**，理由见第五节。

还有两件现有机制做不到、hook 直接给的事：

- **「做完了」和「在等后台」分不开。** 两者屏幕都静止。`Stop` 的 `background_tasks` /
  `session_crons` 就是为这个区分设计的（仓根 CLAUDE.md 第 5 条：一个标志同时在说两件事时，加状态位）。
- **重试死循环。** supervising skill 记过一次：CLI 撞网络错误后一直重画倒计时，屏幕永不静止，
  总管等了快一小时，后来补了「多久没调工具」的时钟（#734）去推断它。`StopFailure` 直接说 `rate_limit`。

## 二、分层

```
┌──────────────── 底层（src/poltergeist，与 CLI 无关）────────────────┐
│ 屏幕静止时钟 · 工具调用时钟 · 群 · 任务面板 · terminal_*             │
│ 新增：AgentEvent 词汇 + 每终端的 agent 状态 + `polter +hook` 入口    │
└──────────────────────────────────────────────────────────────────────┘
          ▲ 中立事件（经 socket，以终端自己的 token 认证）
┌──────────────── 适配器（plugins/<cli>/，每家一个）──────────────────┐
│ ① 感知：启动时把 hook 配进那家 CLI，hook 调 `polter +hook`          │
│ ② 驾驶知识：一份给总管的 skill（polter-driving-<cli>）               │
│ ③ 启动：免确认模式、最低版本检查（已有的 adapter launch 扩展）       │
└──────────────────────────────────────────────────────────────────────┘
```

和 provision 同一个原则（[provisioning.md](provisioning.md) 第五节）：**共用的是实现，不是身份。**
每家一个插件、一份声明、一份日志；翻译各家 hook 负载的代码在 `polter +hook` 里按 `--cli`
分支，不在每家插件里各写一份脚本。

## 三、Claude Code 适配器（第一期）

### 3.1 最低版本：**2.1.145**

用户定的规则：不兼容中间版本，选一个版本直接支持 hook 模式。2.1.145 是下表全部就位的第一个版本
（均取自官方 CHANGELOG 原文）：

| 需要的东西 | 起始版本 |
|---|---|
| `PermissionRequest` hook | 2.0.45 |
| `Stop` 输入带 `last_assistant_message` | 2.1.47 |
| `StopFailure` hook | 2.1.78 |
| `Stop` 输入带 `background_tasks` / `session_crons` | **2.1.145** |

低于 2.1.145：adapter **不注入 hook**，终端只有屏幕兜底，并在 launch 回复里带一条 note 说明原因
（启动那个 tab 里看得见）。不做「部分 hook」——那会让同一个状态位在不同终端上意味不同的东西。

版本号从 `claude --version` 取，**在 adapter 的 launch 里取**（它本来就要找 `claude`）。
⚠️ 取不到版本时按「低于」处理，不按「够新」处理。

### 3.2 注入：并进 adapter 已有的那一个 `--settings`

`plugins/claude-code/adapter.py` 的 `launch()` 已经传一个内联 `--settings`（技能开关用），
并且注释里记着：**第二个 `--settings` 会替换第一个而不是合并**（`split_settings` 把角色 args 里的
`--settings` 并进同一个对象）。所以 hook 必须作为 `"hooks"` 键并进**同一个对象**，
`adapter.ps1` 同步改。现有测试 `agent_cli.zig` 里「恰好一个 `--settings`」那条断言继续成立。

注入的事件与对应的中立事件：

| Claude Code hook | → AgentEvent | 取的字段 |
|---|---|---|
| `SessionStart` | `session_started` | `session_id`、`source`（startup/resume/clear/compact） |
| `UserPromptSubmit` | `turn_started` | —（不取 prompt 正文） |
| `Stop` | `turn_ended` | `last_assistant_message`（截断，见 3.4）、`background_tasks` 非空 → `waiting_on_background` |
| `StopFailure` | `turn_failed` | `error`（rate_limit / overloaded / authentication_failed / …）、`error_details` |
| `PermissionRequest` | `awaiting_approval` | `tool_name`、一行摘要（shell 工具——`Bash`，Windows 上是 `PowerShell`——取 `command` 前 120 字符）；整条 `tool_input` 的紧凑 JSON（`input`，至多 24 KB，`input_bytes` 记原长；请求超过 `Server.max_request_bytes` 时 `+hook` 先对半砍它、再砍 `text`），供 `terminal_turn` 的 `pending_tool`（task 1651）。只存内存，批完即丢，不脱敏。auto 模式的框里有每秒重画的倒计时行（`will automatically deny this request in`，`AgentEvent.volatileRows`）：框画完后第一次心跳把「去掉这些行的屏幕」记成框体指纹，回答时屏幕虽动、只要倒计时行还在且其余行与指纹一致就算同一个框（task 1655） |
| `Notification` matcher `idle_prompt` / `elicitation_dialog` | `awaiting_input` | `notification_type` |
| `PostToolUse` | `turn_resumed` | `tool_name`、`agent_id`（子代理里才有） |
| `PostToolUseFailure` | `turn_resumed` | `tool_name`（工具失败也是结束，task 1625） |
| `PreToolUse` | `tool_started` | `tool_name` |

**`tool_started` 与工具计数（task 1625，#62）**：`PreToolUse` 加一，`PostToolUse`/`PostToolUseFailure`
减一，一轮的边界（`turn_started`/`turn_ended`/`turn_failed`）归零，`session_started` 回到「不知道」（null）。
只动 `Bus.Agent.tools`/`tool`/`tool_ms`，不动 state、时钟和信箱。`no tool call` 那一行在 `in_turn` 时
据此写成 `(in turn 20m, Bash running 16m; …)` 或 `(in turn 20m, no tool running for 16m; …)`；
从没听到过 `PreToolUse` 的 agent（旧的启动、别的 CLI）只写 `(in turn 20m; …)`，不说「没有工具在跑」。
同样同步：异步的 `PreToolUse(A)` 可能晚于它自己的 `PostToolUse(A)` 到达，把一个已经结束的工具算成在跑。
代价是每次工具调用再多起一次 `polter`（约 20ms，见下）。

**`turn_resumed`（task 1561）**：批准或回答之后 agent 接着干活，原来要等这一轮的 `Stop` 才有下一个事件，
「等批准」会一直挂着。`PostToolUse` 每次工具调用都发，所以它只在两种状态下起作用：`awaiting_approval`
且与批准**同一个 agent**（`agent_id` 相同；主线程两边都没有这个字段），或 `awaiting_input` 且不是
`idle_prompt`（那是一轮结束之后）。其余状态一律不动，连「最后听到的时刻」都不动。
- **按 agent 配对，不按工具名**：`PermissionRequest` 不带 `tool_use_id`；按工具名配对挡得住子代理的工具，
  但挡不住「拒绝并附反馈」——那时 Claude Code 不结束这一轮，agent 换个工具接着跑，工具名对不上，
  就只能等 `Stop`。2.1.300 的产物里，两种 hook 的 `tool_name` 都取自工具对象自己的 `name`；不带反馈的拒绝会
  `abort` 这一轮，且不发任何 hook（#879），仍靠屏幕兜底。
- **同步，不设 `async`**：异步的 `PostToolUse(A)` 可能晚于下一个工具的同步 `PermissionRequest` 到达，
  把刚出现的批准误撤。代价是每次工具调用多起一次 `polter`，实测墙钟约 20ms（几乎全是 app 二进制的启动）；
  以后可以给 hook 一个不带 AppKit 的小可执行文件。
- 不复用 `turn_started`：那个从任何状态都进 `in_turn`，并撤掉上一轮还没取走的 notice。

每条 hook 都是 exec form：`{"type":"command","command":"<polter 可执行文件>","args":["+hook","--cli","claude-code","<event>"],"timeout":5}`。
**不经过 shell**（#888）：shell form 在 Windows 上没装 Git Bash 时交给 PowerShell，
sh 的单引号写法在那里是语法错误，而且只出现在 Claude Code 的 debug 日志里，回合照常。
exec form 下 `command` 可以是带空格的绝对路径，`args` 每项就是一个参数，不做任何转义。
可执行文件路径用 adapter 已知的那个（provision 注册 MCP 时用的同一个）。

**不用 `mcp_tool` 类型的 hook**，两个理由：
1. 它走 agent 自己的 MCP 连接，会被 `rpc.noteCall` 记成一次工具调用，**把「多久没调工具」时钟清零**——
   hook 本身会掩盖它要揭示的沉默。
2. 在 `Notification` 这类观察型事件上，MCP 还没连上时它**不等、直接跳过**（官方文档原话），静默丢事件。

**同一个对象里还有一条 `statusLine`**（2026-10-13，[control-room.md](control-room.md) 3.6）：凡是带了 hooks
的启动，并且不在 Windows 上，`statusLine` 被设成 `'<polter>' +statusline --cli claude-code`，为的是读
Claude Code 交给状态栏命令的额度。用户原来的状态栏命令经环境变量 `POLTER_STATUSLINE_CHAIN` 串接，输出
逐字节不变；`launch` 回复里的 `env` 从这一条起不再恒为空。它不是 hook：没有 exec 形式，是交给 shell 的
一行，所以 polter 的路径按 `sh` 的规矩加单引号。额度写进一个文件，写了就经 socket 发一个
`allowance_written` 告诉 Polter 去读。

**它还读上下文用量**（task 1779）：输入里有 `context_window` 对象时，取 `used_percentage`，经 socket
发 `agent_event: context_reported`，`context_used` 是取整后的百分比；`used_percentage` 为 null 或缺失时
不带 `context_used`，意思是「CLI 说它还没有数」（第一次应答之前），**不是 0**。没有 `context_window`
就什么都不发。bus 把它存进 `Bus.Agent.context`（三态：没人报过 / 还没有数 / 百分比），不动 state、
时钟和信箱；`session_started`（含压缩）把它清回「没人报过」。`me`、`terminal_list` 的 agent 块里
写成 `"context":{"said":"used","used_percent":73,"age_ms":…}` 或 `{"said":"no_number_yet","used_percent":null,…}`，
没人报过时不写这一项。Windows 不设 statusLine，所以那里永远没有这一项。

**压缩前后两条 hook 跑 `+hook-context`**（task 1779，adapter 的 `CONTEXT_HOOKS`）：`PreCompact`（不带
matcher）和 `SessionStart` matcher `compact`，同样是 exec form，`args` 为
`["+hook-context","--cli","claude-code","<event>"]`。在同一事件里排在 `+hook` 那条之前，`+hook` 那条仍是最后一条。
`+hook-context` 是**唯一写 stdout 的 Polter hook**：它经 socket 发 `hook_context`（`moment` 为
`before_compact` / `after_compact`；不是工具、不算工具调用、插件不可调），拿回 Polter 拼好的几行
（以 `[From Polter` 开头：这是哪个终端、在哪些群、是哪些群的总管、该重新读什么），然后
`PreCompact` 原样打印（Claude Code 把它追加进压缩指令），`SessionStart` 打印
`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":…}}`。`source` 不是
`compact`、没有 Polter、被拒绝、读不懂输入：一律什么都不打印、退出 0，压缩照常。

### 3.3 `polter +hook`：底层唯一的入口

新的 CLI 子命令（`src/cli/`），职责只有一件：

1. 从 stdin 读 hook 的 JSON；按 `--cli` 选翻译表，得到一个 AgentEvent。
2. 用**环境里的** `GHOSTTY_POLTER_SOCKET` / `GHOSTTY_POLTER_TOKEN` 连 socket 认证——hook 子进程
   继承 claude 进程的环境，所以它**就是**那个终端，身份不用另外传（与 `+mcp` 相同，`src/cli/mcp.zig`）。
3. 发一个新的 RPC 方法 `agent_event`；**不管结果如何都 exit 0、不向 stdout 写任何东西**。

第 3 条是硬约束：Claude Code 会读 hook 的 stdout 与退出码来决定行为（exit 2 会阻塞、stdout 的 JSON
会被当成决策）。Polter 挂了、socket 不在、token 失效，都不能让 worker 的回合被拦住或被改写。
失败只写 Polter 自己的日志。

`agent_event` **不算 agent 调用**：在 `rpc.zig` 的 `isAgentCall` 里排除，理由同 3.2 第 1 条。
plugin token 调它要被拒（事件只能由终端自己报）。

### 3.4 底层状态与送到总管的形状

每个终端新增：

```
agent: {
  hooks: none | expected | live,      // 见下
  state: idle | in_turn | ended | failed | awaiting_approval | awaiting_input,
  since_ms, session_id?, cli?, detail?   // detail: 错误类型 / 工具名 / 输入类型
  waiting_on_background: bool
}
```

`hooks` 是 CLAUDE.md 第 5 条要求的那个状态位——它把三件看起来一样的事分开：

- `none`：这个终端没配 hook（不是角色启动的、CLI 不支持、版本太低）。**「没有事件」不说明任何事**。
- `expected`：adapter 注入了 hook，但还没收到 `session_started`。停在这里超过 30 秒 = hook 没接通
  （CLI 升级改了字段、`+hook` 路径错了……），要作为一条通知报给总管，而不是静默当成「没事发生」。
- `live`：收到过 `session_started`。之后「没有事件」才有意义。

`expected` 由 launch 设：adapter 的 launch 回复带一个可选字段 `hooks`（缺省 false），
`agent_cli.parseLaunch` 读它；为 true 时 `polter +launch` 在 exec CLI **之前**用本终端的 token
发一条 `agent_event{event:"hooks_expected"}`（尽力发，失败只写日志）。`+launch` 本来就在那个终端里、
带着 socket 与 token，所以不需要新 RPC，1b 只改 adapter 一侧。

`+launch` 没能把 CLI 起起来时再发一条 `agent_event{event:"launch_failed", detail:"not_found"|"failed"}`（同样
尽力发）：找不到程序是 `not_found`，其余——没有适配器、适配器没给出命令、角色不在、程序在但执行失败——是
`failed`；核心对不认识的 `detail` 按 `failed` 读。它撤回上面那句「等 hook」，并让等这个终端里出现 agent 的
两处（角色待认领的身份、总控台正在启动的总管）立刻知道不用等了。有 `exec` 的系统上它只可能在 `exec` 返回
（也就是失败）之后发；没有 `exec` 的系统上，只在系统没能把子进程起起来时发，子进程起来以后怎么退出都不发。

**送到总管**：沿用 notices 盒子（`Bus.zig` 的 `take()`），新增一种 entry，与屏幕静止并列：

```
[poltergeist] 0x…2222 turn ended 12s ago: "已修好 #845，全量 104/104 …" · 0x…4444 failed rate_limit · 0x…6666 awaiting approval Bash: zig build test …
```

最终答案在 notices 里最多放前 120 字符，**且受整行长度限制**：notices 一行经
`apprt.surface.Message` 送出，缓冲区是 255 字节，含 `[poltergeist]` 与每个 18 字符的 id；
120 个中文字符就是 360 字节，一条都放不下。所以写进 `take()` 时按这一行剩余空间在 UTF-8 边界截断并加 `…`，
不扩大 Message。全文由 `terminal_list` 之外的一个新只读工具
`terminal_turn(id)` 取（最后一次 `turn_ended` 的全文、时间、session_id），**上限 16 KB**，超出截断并说明。

**hook `live` 时屏幕静止通知怎么处理**：

**原则：事件只解释它之后的那一段静止。** 屏幕自事件之后又变过，事件就不再解释现在的静止，照常报。
判法（`Bus.quietExplained`）：这一段静止的起点 ≤ 事件时刻 + `event_redraw_grace_ms`（3 秒），
事件才算解释了它；更晚开始的静止照报。

| agent state | 屏幕静止时 |
|---|---|
| `ended` / `awaiting_*` / `failed`，静止开始于事件后 3 秒内 | 不再单独报「quiet」——事件已经说了为什么静止 |
| `ended` / `awaiting_*` / `failed`，屏幕在那之后变过 | **照报**，并标注「last event: <事件> Ns ago」 |
| `in_turn` | **照报**，并标注「in turn Xm」——在回合中却静止，正是值得看的情形（长构建或挂住） |
| `idle`（`session_started` 后还没第一轮） | 照报 |

为什么要这样（#879，test-mac 在真机上发现，我用裸 claude 2.1.283 在 pty 里复测过）：在授权框前**按 Esc
或选 No 拒绝，不触发任何 hook**。Stop、PostToolUseFailure、PermissionDenied、Notification
在之后 75 秒内一个都没有；官方文档对 PermissionDenied 的原话是「When auto mode denies a tool
call」，只管 auto mode 的拒绝。于是 state 一直停在 `awaiting_approval`，claude 其实已经回到空输入框；
旧规则只看 state，就把静止通知一并压掉了，总管两路都看不见这个终端。没有能标出「授权结束」的 hook，
只能靠屏幕。3 秒是量出来的：PermissionRequest hook 触发后，授权框还要再画 1.45 秒（Esc 那次）和
1.82 秒（No 那次），再加采样一秒的粒度。代价：在授权框出现后 3 秒内就拒绝的，这一段静止仍会被当成已解释；
再往后屏幕只要变一次就不会了。

「多久没调工具」时钟不受影响。

实现时补定的三条（#866）：

- `awaiting_input` 也进 notices——上表里它会压掉 quiet，不报的话总管什么都听不到。
- 新一轮开始（`turn_started` / `session_started`）撤掉上一轮还没被取走的 notice；上一轮全文仍可用
  `terminal_turn` 取。
- 摘录里的换行等控制字符换成空格：这一行是打进总管终端的，换行会直接提交。
- `terminal_turn` 的可达规则同 `terminal_read`，对插件先关着。

## 四、驾驶知识：`polter-driving-claude-code`

一份给**总管**读的 skill，随 claude-code 插件装（与 polter-* 同路径镜像）。总管用
`terminal_capabilities` 看到某终端是 claude-code 起的，就读这一份。写成 skill 而不写成代码：
各家命令变得快，skill 改一行，代码要发版（与 sensing.md 拒绝匹配 UI 的理由同源）。

第一期内容（每条要写「什么时候用、怎么发、发完怎么核」）：

- **续会话**：`session_started` 记下的 `session_id` → 重启或恢复项目时 `claude --resume <id>`。
- **把验收判据交给 `/goal`**：worker 达不到判据就不停。⚠️ 与 CLAUDE.md「绿不是证据」的关系要写清：
  `/goal` 管「别提前收工」，不管「判据本身对不对」。
- **上下文**：`/context` 看用量；高了 `/compact <重点>`；换任务用 `/clear` + 新交代而不是新开终端。
- **走偏了**：`/rewind`。
- **档位**：`/model`、`/effort`、`/fast` 按任务切。
- **一次性小查询**：`claude -p`（结构化输出、退出码，不用读屏）。
- **隔离**：worktree 启动参数（⚠️ 参数名待按官方文档核实后再写）。

## 五、为什么屏幕时钟必须留着

hook 的沉默有三种来源，其中两种 hook 自己报不出来：

1. 真的没事发生。
2. hook 没接通（`expected` 卡住能抓到这一种）。
3. hook 接通过、后来不发了：CLI 中途被升级、`+hook` 进程被杀、用户中断（`Stop` 在用户中断时**不触发**，
   官方原文；总管 `terminal_key ctrl+c` 打断也是这一种）。

第 3 种只有屏幕时钟能兜住。所以两路同时跑，hook `live` 时按 3.4 的表合并，不是二选一。

## 六、分期

| 期 | 内容 | 谁 |
|---|---|---|
| **1a** | 底层：`polter +hook`、`agent_event`（不计 agent 调用）、每终端 agent 状态、notices 新 entry、`terminal_turn`、`terminal_list` 带 `agent` 字段；Zig 单测 | dev worker |
| **1b** | claude-code adapter（py + ps1）：版本门槛、`hooks` 并进唯一的 `--settings`、launch 回复带 `hooks: true` | dev worker |
| **1c** | `polter-driving-claude-code` skill | 总管起草，dev worker 核事实 |
| **1d** | 真机：mac、Windows 各一轮（第七节） | 两个测试 worker |
| 2 | 手动起的 claude（非角色启动）也接 hook：provision 写用户级 settings 还是做成 Claude Code 插件，待定 | — |
| 2 | 项目恢复时用 session_id 自动续会话 | — |
| 3 | Codex、Qwen……逐家（第八节；Gemini 插件已在 #1681 删除） | — |

## 七、判据

**1a / 1b（dev worker 自证，不上真机）**

- 翻译表：每个 hook 的一份真实形状的样例 JSON → 期望的 AgentEvent；再加一份**字段缺失**的样例，
  期望「丢弃并记日志」而不是崩。地板：把翻译表里 `Stop` 那一行改错，确认红在那一条。
- `+hook` 在 socket 不存在、token 错、stdin 不是 JSON 三种情况下都 **exit 0 且 stdout 为空**。
- `agent_event` 不刷新工具调用时钟：单测里先让时钟走到 N，发一个 `agent_event`，时钟仍 ≥ N。
- `hooks: expected` 30 秒无 `session_started` → notices 里出现那条；收到后不再出现。
- adapter：版本 2.1.144 → 不带 `hooks` 键且有 note；2.1.145 → 恰好一个 `--settings`，里面同时有
  技能开关与 `hooks`；角色 args 自带 `--settings` 时三者合并。
- 全量 `tools/zig-test-watchdog -- zig build test` 带 `--summary all`，报基线。

**1d（真机）**

- mac：在**测试实例**里（不是用户的 Polter）用 dev-worker 角色起一个 claude，量：
  `session_started` 到达、发一轮提问后 `turn_ended` 带着回答原文、触发一次需要授权的工具得到
  `awaiting_approval`、`terminal_turn` 取到全文。负对照：不经角色直接 `claude` 起的终端 `hooks: none`。
- Windows：同样四格，走 adapter.ps1；证据是测试机上的 notices / `terminal_turn` 原文。
- `StopFailure` 真机上难以稳定触发：用单测覆盖，真机写「未触发，未测」，不写通过。

## 八、其它 CLI（只列，后续期做）

2026-09-28 各家原始文档 / CHANGELOG / 源码核过。「带答案」指回合结束事件里有最终回复原文。

| CLI | 机制 | 建议最低版本 | 回合结束 | API 失败 | 等授权 | 等输入 | hook 形态 |
|---|---|---|---|---|---|---|---|
| Codex | hooks（稳定） | 0.124.0 | `Stop` 带答案 | ✗ | `PermissionRequest` | ✗ | command / mcp_tool；要信任才运行。**已接入，见第九节** |
| Gemini | hooks | 0.27.0 | `AfterAgent` 带答案 | ✗ | `Notification` 仅观察 | ✗ | 仅 command |
| Qwen Code | hooks | 0.14.4 | `Stop` 带答案 | `StopFailure` | ✓ | `idle_prompt` | command / http |
| Copilot CLI | hooks | 1.0.18 | `agentStop` 无答案 | `errorOccurred` | ✓ | ✓ | command / http；直接读 `.claude/settings.json` |
| Kimi | hooks（Beta） | 1.28.0 | `Stop` 无答案 | `StopFailure` | ✗（文档示例匹配不到） | ✗ | 仅 command |
| opencode | JS 插件（目录） | 2.0.0 | `session.execution.succeeded`，答案由插件攒 | `session.execution.failed` / `interrupted`；可重试的走 `session.retry.scheduled` | `permission.asked` | `form.created` | 服务进程里的插件，启动加 `--standalone`。**已接入，见第十节** |
| DeepSeek-TUI（现名 Codewhale） | hooks | 0.8.54 | `turn_end` 无答案 | `on_error` | ✓ | ✓ | 仅 command |

没有跨家的 hook 标准（Agent Plugins 规范 v1 明确把 hook 排除在外），但 Copilot、Gemini、Qwen、Codex
都在向 Claude Code 的格式靠拢。所以 `+hook` 的翻译表按 `--cli` 分支，其余全部共用。

## 九、Codex（task 1668，codex 0.163.0）

事实取自 openai/codex 的 `rust-v0.163.0` 源码，下面写到的路径都在 `codex-rs/` 下。

**状态来源用 hooks，不用 `notify` 或 rollout。** hooks 是 Stable、默认开（`features/src/lib.rs` 的 `hooks`），事件名和输入字段与 Claude Code 同形
（`hooks/src/schema.rs`）。`notify` 只报「回合完成」一种；rollout 得另起一个进程跟读文件；标题只能看出等批准（#1656 已做，
hooks `live` 后就不再看标题）。

| Codex hook | → AgentEvent | 说明 |
|---|---|---|
| `SessionStart` | `session_started` | `source`：startup / resume / clear。**第一轮开始时才发**，见下 |
| `UserPromptSubmit` | `turn_started` | |
| `Stop` | `turn_ended` | `last_assistant_message`；没有 `background_tasks` |
| `Interrupt` | `turn_failed`，detail `interrupted` | 回合中途被停（Esc、ctrl+c）。Claude Code 在这种情况下什么都不发 |
| `PermissionRequest` | `awaiting_approval` | shell 是 `Bash`/`command`；改文件是 `apply_patch`，摘要取补丁里第一行 `*** Update/Add/Delete File:`；MCP 工具的批准框也先过这里（`core/src/tools/approvals.rs`） |
| `PreToolUse` / `PostToolUse` | `tool_started` / `turn_resumed` | |

没有 `StopFailure`，也没有「等输入」的通知，所以 API 失败和等输入仍要靠屏幕。`SessionEnd` 不接：退出从进程上看得到。

**注入**：adapter 的 launch 把 `plugins/codex/hooks.py`（PowerShell 版是 `hooks.ps1`，两份逐字节一致）给出的 `-c` 参数接到 codex 命令行上：
每个事件一条 `hooks.<Event>=[{hooks=[{type="command",command="'<polter>' +hook --cli codex <Event>",timeout=3}]}]`。
codex 在 unix 上用 `$SHELL -lc` 跑 command，在 Windows 上用 `powershell.exe -NoProfile -Command`（#1748 在测试机上实测，Codex 0.154；以前这里写的 `cmd /C` 是读源码推的，不对）。所以 unix 上按 sh 的规矩给路径加单引号；Windows 上写成 `& '<polter>' +hook --cli codex <Event>`：开头不加调用运算符 `&` 的话，带引号的路径在 PowerShell 里是个字符串，后面的 `+` 被当成运算符，整行 ParserError、exit 1，Polter 根本没被起起来。单引号让路径里的 `$`、反引号原样保留，路径里的 `'` 写成两个。由 `test/codex-adapter/hook-command-parses.py` 守住（要有 pwsh）：它拿 PowerShell 自己的解析器去读生成的那一行，断言 0 个错误、用 `&` 调用、程序名和路径逐字相同、参数正好是 `+hook --cli codex <Event>`；同时核对 hooks.py 和 hooks.ps1 写出的行和 trusted_hash 一致。旧写法必须解析失败，作为这把尺子的对照。
timeout 取 3，因为 codex 把 `Interrupt` 的超时钳在 3 秒以内，而信任哈希算的是钳过之后的值，各事件取同一个数就不会对不上。

**信任**：用户层和 `-c` 层的 hook 只有在被信任之后才跑；没被信任的不跑，TUI 启动时还会弹出审核框，挡在提示符前面。
所以同一组 `-c` 里还有一条 `hooks.state={…}`，只给我们这几条写上 `trusted_hash`，不用 `--dangerously-bypass-hook-trust`
（那会把用户和项目里没审过的 hook 一起放行）。
- key：`/<session-flags>/config.toml:<event label>:0:0`。key 里有点号，而 `-c` 的键会按点号切开，所以整张表放在 `hooks.state` 的值里。
- hash：`sha256:` 加上对 `{"event_name":…,"hooks":[规范化的 handler]}` 按键排序、紧凑写法的 JSON 求的 SHA-256（`hooks/src/engine/discovery.rs` 的 `hook_hash`）。

实测（task 1668）：codex 0.163.0 的 `app-server` `hooks/list` 读回 7 条，全是 `trusted`。py 和 ps1 生成的参数都核过，路径里带引号和中文的也核过。
把 handler 改一个字段，读回是 `modified`；去掉 state，读回是 `untrusted`。
⚠️ Windows 上 key 的前缀 `C:\<session-flags>\config.toml` 是从源码推出来的（`synthetic_layer_path` 对 `C:\` 取绝对路径），没在 Windows 上量过。

**`hooks_heard: "first_turn"`**：codex 的 `SessionStart` 挂在第一轮开始时才发（`core/src/hook_runtime.rs` 的
`run_pending_session_start_hooks`），所以一个没人打字的 codex 不管坐多久都不会发任何事件。launch 回复带
`"hooks_heard":"first_turn"` 时，`+launch` 发出的 `hooks_expected` 带 detail `first_turn`，`Bus` 只记下「在等」，**不起表**；
等到这个终端里第一次有人敲回车（`Surface.submitsLine` → `Bus.noteLineSubmitted`，不管是人、`terminal_send` 还是送达），
30 秒才开始算。缺省（`startup`）的行为和以前一样，从 launch 起算。

**带时刻回答批准框**：codex 的批准框下面屏幕一直在动（「•」圆点按颜色闪烁，#1653），所以 `promptStanding`
原来的两条判据——「事件之后屏幕静止」和「框指纹」（task 1655，靠 `volatileRows`）——对 codex 都不成立，带时刻的
`terminal_answer_prompt` 一律回 `PromptGone`（c1668-01 实测）。现在 `Bus.Agent.title_waits` 记着「终端标题是不是插件声明的
等批准标题」（`title_says`，#1656）。hooks `live` 时标题不改 state，但仍然记这一位；state、since、event 三者都对得上，并且这一位为真，
就算框还在。框被答掉以后标题会离开，换了一个框则 event 不同，这两种情况都不会误判（c1668-02 实测回答成功）。

**不带时刻的 `terminal_answer_prompt` 不再盲按**（task 1668 B2，#79）：agent 自己有话（hooks live 或声明的标题）时照它的话办——在等批准才按，否则 `PromptGone`；
它没话时看屏幕最底下 16 行有没有它的插件在 `screen_says` 里声明的框（见 [plugins.md](plugins.md)）；没有声明或认不出是哪个 CLI，回 `PromptUnknown`，不发键。

**MCP 连接断了要报**（task 1668 B3，#83）：sidecar 握手时报了它的父进程 pid（`agent_cli.Sighting.pid`，就是 CLI 本身）。
`Bus.noteAgentHere` 记下连着时的 pid，连接从有变无时记下时刻；5 秒（`link_grace_ms`）内没连回来、而那个 pid 还活着，就往总管的盒子里放一行
`lost its Polter connection Ns ago while its program (pid N) still runs`，每次断开只报一次；连回来就收回。pid 已经不在 = agent 退出了，不报（屏幕和 quiet 会说）。
「还活着」不能用 `kill(pid, 0)` 判断（#1669 c1669-12：正常 `/exit` 之后，codex 被报成 40 秒后仍在运行，可那个 pid 在收尾时已经不在了）。实测：
一个已退出、还没被父进程收尸的进程（僵尸），`kill(pid, 0)` 照样返回 0。现在要同时满足三条才算「还在跑」（`App.poltergeistProgramRuns`）：
这个终端的 shell 没有回到提示符（`Surface.shellIdle`）；`process_info.of(pid)` 读得到，并且不是僵尸——macOS 上对僵尸，`proc_pidinfo` 直接返回 ESRCH；
进程的启动时间和连上时记下的一样，防 pid 复用。另外，已经放进盒子、还没被读走的那一条，下次检查时如果不再成立，就收回。
谁连着，原来只在被看着的屏幕报静止或心跳时才去看；agent 断了而屏幕不动，就永远不会被发现（c1668-04 第一轮：修前修后的包都没报，连正例也没报）。
现在 `Server.Submit.agent_gone` 在连接线程关掉一个终端的 agent 连接时通知 App，App 当下记下断开，`link_grace_ms` 之后自己醒来再查。
这一行和等批准一样当场送出（`freshlyWaiting`），不等下一个定时的盒子，因为断了连接的 agent 自己什么都报不出来。
⚠️ Windows 上 sidecar 还不报 pid，所以这条在 Windows 上不会出现。

**fresh（task_assign 带 fresh，task 1668 B4，#80）**：codex 的清上下文命令是 `/clear`（`InitialHistory::Cleared`）。它的 `SessionStart(source=clear)`
和别的 SessionStart 一样，要等下一轮开始才发，而下一轮正是任务那一行开启的，所以在那一行之前没有任何东西可等。
`fresh_clis` 给每个 CLI 标上确认方式（`fresh_assign.Confirm`）：claude-code 是 `session_start`，最多等 10 秒；codex 是 `next_turn`，打完 `/clear`
只等 2 秒（`settle_ms`）让它把命令吃下去，然后打任务那一行，回复写 `cleared: pending`。`session_id` 变了就是清过了，terminal_list 看得到。

## 十、opencode（task 1777 接入，task 1806 改到 opencode 2.0.32）

事实取自 anomalyco/opencode 的 `v2.0.32` 源码（`packages/` 下），并在临时 `HOME` 里对本机
2.0.32 实测：在 pty 里起它的 TUI，配一个替身模型（127.0.0.1 上的假 OpenAI 兼容服务）和一个
替身 polter。实测由 `test/opencode-adapter/hooks-against-opencode.py` 复现；没装 opencode，
或者装的版本低于 2.0 时，它会跳过。1.x 的那一版（task 1777）见 git 历史：2.0 是重写，
1.x 的插件形状、事件名、会话表在 2.0 里都不认了。

**一个 TUI 一个私有服务：`--standalone`**。2.0 的 TUI 默认是一个后台服务
（`opencode serve --service`）的客户端，每个用户只有一个这样的服务。服务由第一个 TUI 拉起，
TUI 退出后它还活着，带的是**第一个** TUI 的环境（地址、pid、密码在
`state/opencode/service.json`）。实测：服务还在时，用另一份 `OPENCODE_CONFIG_CONTENT`
起第二个 TUI，它直接连上了第一个服务，自己那份配置一点都没生效。在服务模式下，Polter 的插件还被
加载了两份：同一个事件的两次 `+hook` 抢同一个记录槽，子代理的一轮结束也被报了两次。所以 adapter 一律加
`--standalone`：TUI 底下起一个私有的 `opencode serve --stdio`，带这次启动的环境，跟着 TUI 一起退出，
不写 service.json。角色自己的参数里写了 `--server` 的，照它的，并留一条 note。
没有让「standalone」变成默认的环境变量；`opencode service set disabled true` 可以，但那是改用户的全局设置，不用。

**hook 是一个插件**。opencode 没有 command hook，只有在它的服务进程里跑的插件。
`plugins/opencode/polter-hooks/` 就是这个插件，**是一个目录**：2.0 把配置成文件的插件路径
直接丢掉（日志原文 `configured plugin path must be a directory`），只加载目录里的 `index.js`，
默认导出 `{id, setup}`；1.x 那种 `async (ctx) => hooks` 没有兼容层。插件订阅
`ctx.event.subscribe()`，用 `ctx.tool.hook` 挂工具的前后。对 Polter 关心的每个事件，它跑一次
`<polter> +hook --cli opencode <type>`，stdin 是 `{"type","data","polter"}`。
`type` 和 `data` 是 opencode 的原样；`polter` 是插件唯一加上去的东西：
`answer`（从 `session.text.ended` 攒下来的、这一轮最后一条 assistant 消息的文字）和 `child`。
事件的含义一律在 `agent_event.zig` 的 `opencode()` 里翻译，插件不做判断。

插件只在 Polter 起的会话里加载：adapter 的 launch 通过 `OPENCODE_CONFIG_CONTENT`
（`"plugin": ["file:///…/polter-hooks"]`）把它加进去，并用 `POLTER_HOOK_EXE` 告诉它跑哪个 Polter。
没有这个变量时，插件什么都不订阅。用户的配置文件一个字都不写；插件目录里也不写东西
（它在签过名的 app 里；测试核过前后目录一样）。工具的 hook 会被 opencode await，
所以插件只负责把事件排进队列就返回；队列一次只跑一个 `+hook`，顺序也就和 opencode 发出的顺序一致。

| opencode 事件（`+hook` 的名字） | → AgentEvent | 说明 |
|---|---|---|
| `session.created` | `session_started` | **第一条消息发出时才建会话**，所以 `hooks_heard: first_turn`；带 `parentID` 的是子代理的会话，插件不转发 |
| `session.execution.started` | `turn_started` | 一轮一次。2.0 没有 `chat.message` |
| `session.execution.succeeded` | `turn_ended` | 答案在 `polter.answer`；一轮里一句话都没说的，`answer` 是 null |
| `session.execution.failed` | `turn_failed` | 按 `error.type`：`provider.rate-limit`→`rate_limit`，`provider.auth`→`authentication_failed`，`provider.quota`→`billing_error`，`provider.internal`/`transport`/`timeout`→`server_error`，`provider.invalid-request`→`invalid_request`，`output-limit`→`max_output_tokens`，其余原样；note 是 `error.message` |
| `session.execution.interrupted` | `turn_failed`，detail `interrupted` | note 是 `reason`（实测 `user`：按两次 Esc） |
| `session.retry.scheduled` | **`turn_retrying`** | 每次重试一条；detail 是 `error.message`，note 是 `attempt N` |
| `permission.asked` | `awaiting_approval` | `action` 做 detail（2.0 的 shell 工具叫 `shell`）；`resources` 一行一个，放进 text，第一行做摘要；整条请求放进 `input` |
| `form.created` | `awaiting_input` | 它的 `question` 工具就是一张表单：detail 是 `metadata.kind`（`question`），note 是第一个字段的 `description`（问题原文）；会话 id 在 `form.sessionID` |
| `permission.replied` / `form.replied` / `form.cancelled` | `turn_resumed` | |
| `tool.execute.before` / `.after`（插件挂的工具 hook） | `tool_started` / `turn_resumed` | |

**一轮就是一组 `session.execution.*`**（实测）：`started`，然后 `succeeded`、`failed`、`interrupted`
三者恰好一个，后面不再跟 idle。2.0 整轮一个 `session.status` 都不发，所以 1.x 那套
「idle 之后等 300ms 读最后一条消息上的错误」不要了。

**`turn_retrying` / `retrying`**：opencode 遇到可重试的错误（限流、过载）时不结束这一轮，
而是无限重试，屏幕一直在动。这正是 #734 那种情况。它是一个独立的状态，
既不是 `failed`（这一轮没结束），也不是 `in_turn`（它没在干活）：
- 进入时往盒子里送一行 `retrying an API error for Ns: <原话> (attempt N)`；同一次重试的后续尝试不再送，`since` 也不动。
- Attention 的分类：T1 之内算 `working`，过了 T1 归到 `suspect_stuck`。
- fresh 派单和回复框都把它当作一轮还在进行。
- 按两次 Esc 能停下正在重试的这一轮，报 `session.execution.interrupted`（实测）。

**adapter**（`plugins/opencode/adapter.py`）：角色的开关全部写进同一个 `OPENCODE_CONFIG_CONTENT`。
2.0 在服务进程里读它，作为高于用户和项目配置文件的一层（只有托管设置比它高），不再是 mergeDeep：
- 关掉一个 skill：`permission.skill.<name> = deny`，它会从模型拿到的 skill 列表里消失（实测，留着的那个在）；
- 关掉一个 MCP server：`permission["<server>_*"] = deny`，它的工具从 `execute` 工具的说明里消失（实测，留着的那个在），server 本身照样启动；
- `polter_*` 一律 `allow`；
- 角色的模型写成 `"model"`：**2.0 的 TUI 没有 `-m`**，传了它会打印帮助直接退出（实测）。

旧的 `permission` 写法 2.0 还认，会转成它自己的规则。另外一个变量：`OPENCODE_DISABLE_AUTOUPDATE=1`。
角色说明走 `--prompt`，作为第一条提示，TUI 自己打出来并发出去（实测）；续会话时不再发。
续会话用 `-s ses_…`，前提是只读打开 `~/.local/share/opencode/opencode.db` 能在 `session_v2`
（没有它时读 1.x 的 `session`，2.0 第一次启动会把那里的行搬过来）里查到这个 id。
**绝不盲传 `-s`**：2.0 的 `-s` 碰到不认识的 id 不报错，而是新建一个叫这个名字的空会话。
实测：续上以后，下一轮的 `session.execution.started` 还是原来那个会话，也没有新的 `session.created`。
identify 认 provision 写进去的标记，或者 sidecar 的父进程叫 `opencode`（2.0 里是私有的
`serve --stdio`，TUI 的子进程，和 TUI 一起起来）；会话是「本目录、根会话、在这个 opencode 启动之后建的」
恰好一个时才给。`quit` 为空：还没读过 opencode 的屏幕，不知道什么时候打 `/exit` 是安全的。
inventory 只读 `opencode.json`：2.0 不读 `config.json`。
**最低版本 2.0.0**：低于它的只给 note、不注入 hook，照 1.x 的方式起（不加 `--standalone`，模型走 `-m`）；
读不出版本时两样都不加（1.x 的命令行是 strict 的，`--standalone` 会让它报 Unknown argument 退出；2.0 收到 `-m` 也一样），模型写进配置——两边都认——不注入 hook，并留一条 note。`opencode --version` 现在输出 `opencode v2.0.32`，
不起服务、不加载插件，但每次都会建目录、往 `log/opencode.log` 追加一行，关了 models fetch 也一样。
**Windows**（task 1781）：`adapter.ps1` 逐项移植 `adapter.py`，`test/opencode-adapter/compare.py` 拿同一组请求和同一份文件喂给两边，逐字节比对输出（mac 上用 pwsh 跑；2.0 和 1.x 各一套）。PowerShell 读不了 SQLite，所以 ps1 通过 Add-Type 用 P/Invoke 调系统自带的 `winsqlite3.dll`（Windows 10 1607 起随系统带），以只读方式打开 `opencode.db`；mac 上同一段代码换成 `libsqlite3`。库不在或者打不开，就不给 id，绝不盲传 `-s`。**不走 `opencode session list`**：实测（1.2.10，临时 HOME、替身插件、只记录 CONNECT 的假代理），它会执行用户的插件、连 npm、改写用户的配置。npm 装的 `opencode.cmd` 不直接起：2.0 的包是 `@opencode/cli`，bin 本身就是 `node_modules\@opencode\cli\bin\opencode.exe`，直接起它；1.x 起 `node.exe` 加 `node_modules\opencode-ai\bin\opencode`。⚠️ 2.0 的这个布局读自它的 `script/publish.ts`，还没在 Windows 上装过量过。Windows 上 identify 拿不到 agent 的 pid，「这个 opencode 何时启动」就用它起的 Polter server（`sidecar_pid`）的启动时间代替，`adapter.py` 在没有 pid 时也一样。

**provision**：`environment` 里写 `POLTER_AGENT_CLI=opencode`；skills 装到
`~/.config/opencode/skills`，**除非 `~/.claude/skills` 里已经有 Polter 的 skill**：2.0 也读那里，
两份同名就成了两个 skill，所以只留 Claude Code 插件那一份，这里之前装过的收回。不用
`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`，那会把用户自己的 Claude skills 也一起藏掉。
规则一律写进 `~/.config/opencode/AGENTS.md`，只动 Polter 那一块：2.0 完全不读 `CLAUDE.md`，
写这个文件不会遮住用户的任何东西。见 [provisioning.md](provisioning.md)。

**fresh**：`/new`，确认方式是 `next_turn`，理由同 codex。不再用 `/clear`：1.x 里它是 `/new` 的别名，
2.0 里是另一个命令，还会关掉会话的标签页。fresh 的回执因此只写「clear sent」，不写具体是哪个词。

**代答**：opencode 的权限框还是「Permission required」，选项「Allow once / Always allow / Reject」横排，←→ 移动。插件声明 `screen_says.awaiting_approval.next_option: arrow_right`，所以 `terminal_answer_prompt` 的 choice 2、3 按 → 走过去（D 期）。其余三家没有声明，照旧按 ↓。选 `Always allow` 时 opencode 还会再弹一个确认框，那一步要另外答（1.x 量的，2.0 没量）。

## 未决问题

- 第二期的手动起终端：写用户级 `~/.claude/settings.json`（替它维护格式，provisioning.md 反对的那条路）
  还是发一个 Claude Code 插件（插件可带 hooks，⚠️ 待核）。
- 角色 args 里的 `--settings` 若是**文件路径**，现有代码无法合并（`split_settings` 留原样并加 note）；
  这种情况下 hook 注入怎么办——先按「不注入、note 说明」处理。
- `idle_prompt` 的「用户 60 秒没打字」是否把 `terminal_send` 算作打字：未测。
