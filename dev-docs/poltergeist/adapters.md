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
| `PermissionRequest` | `awaiting_approval` | `tool_name`、一行摘要（Bash 取 `command` 前 120 字符） |
| `Notification` matcher `idle_prompt` / `elicitation_dialog` | `awaiting_input` | `notification_type` |

每条 hook 都是 `{"type":"command","command":"<polter 可执行文件> +hook --cli claude-code <event>","timeout":5}`。
可执行文件路径用 adapter 已知的那个（provision 注册 MCP 时用的同一个）。

**不用 `mcp_tool` 类型的 hook**，两个理由：
1. 它走 agent 自己的 MCP 连接，会被 `rpc.noteCall` 记成一次工具调用，**把「多久没调工具」时钟清零**——
   hook 本身会掩盖它要揭示的沉默。
2. 在 `Notification` 这类观察型事件上，MCP 还没连上时它**不等、直接跳过**（官方文档原话），静默丢事件。

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

`expected` 由 launch 设：`agent_cli.parseLaunch` 的回复加一个字段 `hooks: true`，Polter 在
执行那条命令行的终端上记下。

**送到总管**：沿用 notices 盒子（`Bus.zig` 的 `take()`），新增一种 entry，与屏幕静止并列：

```
[poltergeist] 0x…2222 turn ended 12s ago: "已修好 #845，全量 104/104 …" · 0x…4444 failed rate_limit · 0x…6666 awaiting approval Bash: zig build test …
```

最终答案在 notices 里只放前 120 字符；全文由 `terminal_list` 之外的一个新只读工具
`terminal_turn(id)` 取（最后一次 `turn_ended` 的全文、时间、session_id），**上限 16 KB**，超出截断并说明。

**hook `live` 时屏幕静止通知怎么处理**：

| agent state | 屏幕静止时 |
|---|---|
| `ended` / `awaiting_*` / `failed` | 不再单独报「quiet」——事件已经说了为什么静止 |
| `in_turn` | **照报**，并标注「in turn Xm」——在回合中却静止，正是值得看的情形（长构建或挂住） |
| `idle`（`session_started` 后还没第一轮） | 照报 |

「多久没调工具」时钟不受影响。

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
| 3 | Codex、Gemini、Qwen……逐家（第八节） | — |

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
| Codex | hooks（稳定） | 0.124.0 | `Stop` 带答案 | ✗ | `PermissionRequest` | ✗ | command / mcp_tool；**需在 `/hooks` 里批准才运行**，要实测 |
| Gemini | hooks | 0.27.0 | `AfterAgent` 带答案 | ✗ | `Notification` 仅观察 | ✗ | 仅 command |
| Qwen Code | hooks | 0.14.4 | `Stop` 带答案 | `StopFailure` | ✓ | `idle_prompt` | command / http |
| Copilot CLI | hooks | 1.0.18 | `agentStop` 无答案 | `errorOccurred` | ✓ | ✓ | command / http；直接读 `.claude/settings.json` |
| Kimi | hooks（Beta） | 1.28.0 | `Stop` 无答案 | `StopFailure` | ✗（文档示例匹配不到） | ✗ | 仅 command |
| opencode | JS 插件 | 待定 | `session.status` idle 无答案 | `session.error` | `permission.asked` | `question.asked` | 进程内 JS，要单写 |
| DeepSeek-TUI（现名 Codewhale） | hooks | 0.8.54 | `turn_end` 无答案 | `on_error` | ✓ | ✓ | 仅 command |

没有跨家的 hook 标准（Agent Plugins 规范 v1 明确把 hook 排除在外），但 Copilot、Gemini、Qwen、Codex
都在向 Claude Code 的格式靠拢。所以 `+hook` 的翻译表按 `--cli` 分支，其余全部共用。

## 未决问题

- 第二期的手动起终端：写用户级 `~/.claude/settings.json`（替它维护格式，provisioning.md 反对的那条路）
  还是发一个 Claude Code 插件（插件可带 hooks，⚠️ 待核）。
- 角色 args 里的 `--settings` 若是**文件路径**，现有代码无法合并（`split_settings` 留原样并加 note）；
  这种情况下 hook 注入怎么办——先按「不注入、note 说明」处理。
- `idle_prompt` 的「用户 60 秒没打字」是否把 `terminal_send` 算作打字：未测。
