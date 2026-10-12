# Polter 的 MCP：一个 AI 能对别的终端做什么，不能做什么

这一页给两种读者：想弄清 Polter 的 MCP 接口边界的开发者，和来产品仓读 README 的 AI。

Polter 是一个内置 MCP server 的终端。跑在某个标签页里的 agent 连上它之后，能读别的终端的屏幕、往里打字、按键、开新标签页，还能拉群和派任务。下面每个工具名、参数名都是从源码里抄的，出处写在各节末尾。

核对的是产品仓提交 `42addcf`（2026-10-11 读取，工作区无未提交改动）。接口还在动，要用请以当时的 `src/cli/mcp.zig` 为准。

## 先说结论

- 没有任何标记的终端，谁都能读、能打字、能按键。带标记的（它自己是总管，或者正被人监视），只有总管碰得到。用户屏蔽掉的，谁都碰不到，总管也不行。
- 安排工作的那一半只归总管：开终端、建群、派任务、决定监视谁。
- Polter 只报告一块屏幕多久没动。这算不算卡住，它不回答，由读到这个数的总管自己看屏幕判断。
- 别的终端停在权限确认框上的时候，总管默认只能替自己打开的那些终端回答。其余终端要用户在那个终端的右键菜单里逐个放开，没有任何工具能替用户打开这个开关。
- 只在 Claude Code 上实测过。server 是标准 MCP，别的客户端照理能连，但都没测过。

## 工具清单

`src/cli/mcp.zig` 的 `tools` 表在这个提交上有 60 项。`src/poltergeist/rpc.zig` 的 `Method` 枚举有 63 个方法，多出来的 3 个（`agent_event`、`persona_slot`、`persona_wait`）是给别的进程用的，`offeredAsTool` 把它们排除在工具表之外，agent 看不到。

「谁能调」一栏来自 `rpc.zig` 的 `requiresSupervisor`。「任何终端」只说明这个方法不要求总管身份，目标终端让不让碰是另一回事，看下一节。参数后面带 `?` 的是可选。

### terminal_*：看和操作终端

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `terminal_list` | 无 | 每个终端一行：`cwd`、`title`、`role`、`shielded`、`held`、`window`、`tab`、`agent`。被监视的另有 `quiet_ms`、`rounds`、`sampling`。调用过工具的另有 `call_silent_ms` | 任何终端 |
| `terminal_read` | `id` | 那个终端当前可见的屏幕文字，拿不到滚动回看区 | 任何终端 |
| `terminal_turn` | `id` | 对方 agent 上一轮结束时的完整回答（`turn.text`，最多留 16 KB）和 `agent` 状态。没有 hooks 的终端 `turn` 是 null | 任何终端 |
| `terminal_send` | `id`, `text`, `submit?` | 成功或拒绝码。`submit` 默认 true，打完按回车 | 任何终端 |
| `terminal_key` | `id`, `key` | 成功或拒绝码。`key` 按配置文件里快捷键的写法，如 `ctrl+c`、`escape` | 任何终端 |
| `terminal_keys` | 无 | `terminal_key` 认的修饰键名和键名 | 任何终端 |
| `terminal_action` | `id`, `action` | 成功或拒绝码。`action` 是快捷键动作名，如 `new_tab`、`close_surface`、`new_split:right` | 任何终端 |
| `terminal_actions` | 无 | `terminal_action` 认的全部动作，以及哪些要带冒号后的值 | 任何终端 |
| `terminal_answer_prompt` | `id`, `choice?`, `state_at_ms?`, `event_at_ms?` | 成功、`AuthoriseOff` 或 `PromptGone`。`choice` 从高亮项往下数，默认 1。带上 `terminal_list` 里读到的两个时刻（要么都给要么都不给），你看到的那个提示不在了就一个键都不发 | 仅总管，且目标终端的授权开关要开着（默认开着，除非用户关掉） |
| `terminal_open` | `cwd`, `watch?`, `place?` | `placed`（split 或 tab）、`watch`（not_asked / watching / refused）。新终端已就绪时带 `id`，分屏带 `pending: true` 不带 `id` | 仅总管 |
| `terminal_layout` | `id`, `layout` | 排好之后的布局树，每格带终端 id。Linux 上答 `Unsupported` | 仅总管 |
| `terminal_capabilities` | `id` | 那个终端的 `role`、`started`、`cli`、`polter`、`standing`（含 `watched_by`、`may_authorise`、`shielded`、`held`） | 仅总管 |

`place` 的取值是 `auto`、`tab`、`here`，不传等于 `auto`。`terminal_open` 开出来的是一个空 shell，里面要跑什么得另外 `terminal_send`。

### group_*：群聊

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `group_create` | `group` | 建群，建的人自动在群里 | 仅总管 |
| `group_destroy` | `group` | 群从列表里拿掉，磁盘上的记录留着。群里还有开着的终端时答 `GroupActive` | 仅总管（键盘前的用户在对话窗口里也能删） |
| `group_rename` | `group`, `to` | 改名，任务编号和成员不变。失败码有 `NoSuchGroup`、`GroupExists`、`RenameBlocked`、`BadName`、`NotYours` 等 | 仅总管，且只能改自己建的群 |
| `group_add` | `group`, `id`, `history?` | 把终端拉进群。`history` 取 `none`（默认）或 `all` | 仅总管 |
| `group_remove` | `group`, `id` | 把终端请出群 | 仅总管 |
| `group_set_brief` | `group`, `text` | 写下这个群是干什么的，群里所有人都读得到 | 仅总管 |
| `group_compact` | `group`, `through`, `summary` | 把 `through` 之前的消息换成一条摘要 | 仅总管 |
| `group_members` | `group` | 群里有谁，每个终端现在叫什么 | 任何终端 |
| `group_list` | `group?` | 有哪些群。普通终端只看到自己在的，总管看到全部，没加入的带 `joined: false` | 任何终端 |
| `group_post` | `group`, `text`, `mention?` | 发言结果。消息过长被截断时会说写了多少、留了多少。`mention` 里每个 id 在 `deliveries` 里有一行 | 任何终端（得在群里） |
| `group_read` | `group`, `since?` | 没读过的消息，带 `next`。`more: true` 表示还有 | 任何终端 |
| `group_history` | `group`, `before_seq?`, `limit?`, `since_ms?`, `until_ms?`, `match?` | 磁盘日志里更早的消息，包括被 `group_compact` 换掉的 | 任何终端 |

群里发言不会打断任何被监视的终端，对方什么时候读由它自己定。想让某个终端立刻看到，得把它的 id 写进 `mention`，消息会被直接打进那个终端。

### task_*：任务面板

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `task_create` | `group`, `title`, `kind` | 任务编号。`kind` 必填：`feature`、`bug`、`research`、`other` | 仅总管，且只能在自己建的群里 |
| `task_edit` | `task`, `title?`, `kind?` | 改标题或类型，编号不变，历史里记为 `edited` | 仅总管 |
| `task_assign` | `task`, `id` | 先往那个终端里打一行「这个任务归你」，打进去了面板才记。回复里说对方有没有被通知到。`id` 传 0 是收回 | 仅总管 |
| `task_close` | `task` | 关闭，不通知任何人 | 仅总管 |
| `task_cancel` | `task` | 先往负责的终端里打一行让它停，再从它的列表里拿掉 | 仅总管 |
| `task_progress` | `task`, `progress` | 只能动自己名下、还开着的任务。`progress` 取 `queued`、`working`、`blocked`、`done` | 任何终端 |
| `task_list` | `group`, `limit?`, `before?`, `state?`, `owner?`, `match?` | 总管拿到整个面板，其他终端只拿到自己名下还开着的。默认 50 行，`more: true` 表示还有 | 任何终端 |
| `task_history` | `group`, `before_seq?`, `limit?` | 面板上发生过什么，每条带时间 | 任何终端 |

面板只记谁在做什么、做完没有。验收标准之类的细节要总管自己另发给对方。

### 其余

**身份和监视**

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `me` | 无 | 自己是哪个终端，是总管还是被监视，以及 `sampling`、`call_silent_ms` | 任何终端 |
| `persona_face` | 无 | 自己现在看得到哪些 Polter 工具 | 任何终端 |
| `skill_read` | `name` | 一份使用说明。源码里列了三份：`supervising`、`operating-a-terminal`、`reading-a-terminal` | 任何终端 |
| `become_supervisor` | 无 | 把自己升为总管。正被监视的终端会被拒 | 任何终端（没人监视它的时候） |
| `stand_down` | 无 | 卸任。手上还监视着终端时答 `StillMinding`，用户不许时答 `StandingInstruction` | 仅总管 |
| `set_watch` | `id`, `watch` | 把终端收归自己监视，或者放掉。别的总管已经收了的答 `NotYours`，没人监视时传 `false` 答 `NotWatched` | 仅总管 |
| `set_quiescence_threshold` | `id`, `ms` | 设这个终端静止多久才上报 | 仅总管 |
| `clock_out` | `id`, `reason?` | 标记这个终端今天收工，之后它静下来不再上报。用户按住的终端答 `TerminalHeld` | 仅总管 |
| `clock_in` | `id` | 让终端回到在岗状态 | 仅总管 |
| `notices` | 无 | 还没看过的上报：哪些终端静了多久，哪些又动了。读一次清一次 | 仅总管 |
| `notify_user` | `reason`, `title`, `body?`, `id?` | 通知有没有真的发出去。`reason` 取 `authorisation` 或 `scheduling`。取 `authorisation` 时还会发一条操作系统自己的通知，返回值里和插件分开说 | 仅总管 |
| `session_recall` | 无 | 重启前记下的安排：有哪些群，各终端当时在哪干活、叫什么 | 仅总管 |
| `config_get` | `key?` | 用户的配置，只读 | 仅总管 |

**角色库**

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `role_list` | 无 | 角色库里的全部角色，形状和 `role_put` 收的一样 | 仅总管 |
| `role_put` | `role` | 新增或覆盖一个角色。改 `supervisor`、`may_authorise`、`shielded` 三项会被 `NotPermitted` 拒掉，内置角色答 `BuiltinRole` | 仅总管 |
| `role_delete` | `key` | 删角色。内置的删不了 | 仅总管 |
| `role_clis` | `refresh?` | 这台机器上角色能启动哪些 agent CLI，各自装了哪些 skill 和 MCP server | 仅总管 |
| `role_launch` | `key`, `cli?`, `cwd?`, `place?` | 开一个终端并按角色启动 agent CLI。`placed` 说落在哪，终端已存在时带 `id` | 仅总管 |

**插件**

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `plugin_list` | `key?` | 装了哪些插件、开没开、收什么参数。明文填的密钥只报「已设置」 | 仅总管 |
| `plugin_configure` | `key`, `enabled?`, `params?` | 开启插件、设参数。关闭会被拒，`cmd:` 引用会被拒 | 仅总管 |
| `plugin_test` | `key` | 通知类插件会真发一条 | 仅总管 |

**截图**

| 工具 | 参数 | 返回 | 谁能调 |
| --- | --- | --- | --- |
| `screenshot_windows` | 无 | 每块显示器和每个窗口：`window_id`、`app`、`title`、`rect` 等 | 任何终端 |
| `screenshot_capture` | `target`, `display?`, `window_id?`, `rect?`, `terminal?`, `annotations?` | PNG 路径、旁边那份 `.json` 的路径、尺寸。`target` 取 `display`、`window`、`region`、`terminal` | 任何终端 |
| `screenshot_annotate` | `path`, `annotations` | 画好标注的新文件，原图不动 | 任何终端 |
| `screenshot_long` | `pages`, `window_id?`, `display?`, `rect?` | 拼好的长图和切片 `tiles`，`stopped` 说为什么停 | 任何终端 |
| `screenshot_interactive` | 无 | 立刻返回 `started`，之后由用户自己框选和标注 | 任何终端 |
| `screenshot_info` | `path?`, `latest?` | 一张截图旁边那份 `.json` 的全部内容 | 任何终端 |
| `screenshot_list` | `limit?` | 最近的截图，新的在前 | 任何终端 |

截图这一族不看身份，看用户的 `screenshot-agent-access`。默认是允许，设成 `deny` 之后调用答 `NotPermitted`。被屏蔽的终端不能当截图目标，出现在更大范围的截图里会被涂黑。

出处：`src/cli/mcp.zig` 的 `tools` 表（工具名、参数 schema、返回说明），`src/poltergeist/rpc.zig` 的 `Request`、`requiresSupervisor`、`offeredAsTool`。

## 权限边界

这一节是整页最要紧的部分。规则都在 `rpc.zig` 的 `authorize` 里，按它检查的先后顺序写。

### 一个终端身上可能有的标记

- **总管（supervisor）**：用户从菜单里设的，或者终端自己调 `become_supervisor` 升的。
- **被监视（watched）**：某个总管用 `set_watch` 收了它，或者用户在标签页菜单里手动开了监视。
- **屏蔽（shielded）**：用户设的。工具接口上谁都读不了它、打不进字。
- **按住（held）**：用户设的。这个终端不许被 `clock_out`。
- **授权开关（may_authorise）**：总管能不能替这个终端回答权限确认框。每个终端默认开着，除非用户说了不。

后三个只有用户能设能撤。源码在 `Entry.shielded` 的注释里给了理由：被管的一方自己能撤掉的保证，等于没有保证。工具接口里没有读写「按住」的方法，总管只能在 `terminal_list` 里看到 `held` 这个字段。

### 能不能碰到目标终端

判断看的是目标身上有没有标记，跟调用方和它是什么关系无关。

1. 目标被屏蔽：拒绝，返回 `Shielded`。对总管和插件也一样。这一条排在最前面，因为任何没标记的终端调一次 `become_supervisor` 就成了总管，只挡非总管的屏蔽一步就绕过去了。
2. 调用方是总管：能碰任何没被屏蔽的终端，包括别的总管。
3. 调用方不是总管：只能碰没有标记的终端。目标是总管或者正被监视，返回 `Supervised`。

第 3 条的结果是，两个被监视的 worker 之间不能互相读屏、互相打字。在群里点名对方（`group_post` 的 `mention`）也不直接送达，默认改送到它们的总管那里，除非用户给那个总管开了允许 worker 互相点名的开关。

还有一条跟身份无关：大多数工具不能对准自己。往自己的终端 `terminal_send` 再 `terminal_read` 会转成死循环，所以返回 `SelfTarget`。例外是 `terminal_action` 里那些不会回头影响调用方的动作，比如给自己的标签页再分一屏。

### 方法层面的拒绝

| 拒绝码 | 什么时候出现 |
| --- | --- |
| `NotPermitted` | 方法只归总管，调用方不是总管 |
| `NotDeclared` | 调用方是插件，这个方法没写进它清单的 `wants.calls` |
| `NotATerminal` | 调用方是插件，而这个方法的含义取决于「是哪个终端在问」 |
| `SelfTarget` | 对准了自己，而且这个调用会绕回自己或者让自己消失 |
| `Shielded` | 目标被用户屏蔽 |
| `Supervised` | 目标带监视标记，调用方不是总管 |
| `NotYours` | 东西是别的总管的：它建的群，或者它已经收走的终端 |
| `AuthoriseOff` | 用户把目标终端的授权开关关掉了（只关这一个，或在配置里对全部关掉） |
| `TerminalHeld` | 想让一个被用户按住的终端收工 |
| `AlreadyWatched` | 正被监视的终端想把自己升成总管 |
| `UnknownTerminal` | 没有这个 id 的终端 |

这十一个都在 `rpc.zig` 的 `Error` 集合里，各有一段注释说明来由。

### 权限过了，字还是可能打不进去

`terminal_send` 过了上面的检查之后，宿主那边还有一道。这几种拒绝各有各的应对办法，所以分成了不同的码：

| 拒绝码 | 原因 | 该怎么办 |
| --- | --- | --- |
| `UserPresent` | 十秒内有按键到过那个终端。只说明有键到过，不说明有人在 | 自己会消，过一会儿重试 |
| `DraftInLine` | 那个终端的输入行里有打了没提交的字符 | 等不掉。得有人在那边按键，比如 `terminal_key(id, "ctrl+u")` |
| `UnbracketedMultiline` | 文本带换行，而那个终端没开 bracketed paste，换行会被当成一条条命令执行 | 改成一行，或者一行一次分开发 |
| `UnsafeText` | 文本里带「粘贴结束」序列 | 删掉它 |
| `ChildExited` | 那个终端里的进程已经退出 | 换一个终端 |
| `SendFailed` | 以上都不是 | 先 `terminal_read` 看那个终端 |

`group_post` 的 `mention` 走的是同一套检查，结果按 id 逐行写在回复的 `deliveries` 里。被拒时消息仍然留在群里，只是没被打进那个终端。

`terminal_send` 只送文本。走的是粘贴通道，控制字符会被换成空格，所以不管怎么拼写，它都按不出 ctrl+c 或 escape。要打断一个程序得用 `terminal_key`，反过来 `terminal_key` 也不收普通字符。

关闭终端另有两个码。agent 开出来的终端和调用方正在监视的终端可以直接关。用户自己的终端里还跑着东西时答 `UserTerminal`，用户设了只读锁的答 `Locked`。两种情况都不会在用户屏幕上弹确认框，agent 该做的是去问键盘前的人。

出处：`src/poltergeist/rpc.zig` 的 `authorize`、`Error`、`selfPermitted`、`planMention`、`mentionFailure`，以及 `dispatch` 里 `.terminal_send` 和 `.terminal_action` 两个分支。标记的定义在 `src/poltergeist/Bus.zig` 的 `Entry`。

## 它不做什么

### 不判断谁卡住了

Polter 测两个时长：屏幕多久没变（`quiet_ms`），和那个终端里的 agent 多久没调过 Polter 的工具（`call_silent_ms`）。它不解析任何 CLI 的输出格式。

这两个数会进到总管的 `notices` 里。`notices` 的工具说明把话说得很直白：这是算术，不是结论，一个终端二十分钟没调工具不代表它死了。它可能在重试循环里，可能停在一个要人回答的确认框上，也可能在跑一个很长的编译。说明里给总管的做法是先 `terminal_read` 看屏幕，不要只凭这一行就去关它、重启它或者打断它。

`poltergeist-watch` 默认是关的，没人要求的时候什么都不采样。屏幕默认静止 3 分钟上报，agent 默认 15 分钟没调工具上报，两个时长都能在配置里改。

代价是总管每次都得自己读屏、自己判断，Polter 不给现成的状态。想要「忙 / 完成 / 等你」这种直接结论的话，这个工具给不了。

### 用户说了不的地方，不替别人的 agent 点「同意」

`terminal_answer_prompt` 要同时满足两个条件：调用方是总管，目标终端的授权开关开着。

- **每个终端的开关一开始就是开的**，不管是谁开的（2026-10-12 起；此前只有总管自己开出来的终端是开的）。worker 的确认归总管处理：它能判断的自己回答，其余的用 `notify_user` 提到用户面前。
- 用户可以从某个终端自己的右键菜单把它关掉、把那个终端护起来，或者用 `poltergeist-may-authorise = false` 对全部终端关掉默认值。关掉之后只有用户能再打开。它没有快捷键，命令面板里也没有，因为 `terminal_key` 能按任何组合键，有快捷键就等于 agent 能自己开门。
- 单个终端的「关」只到那个终端关闭为止；能跨过重启的是配置那一行。
- 任何终端都不能通过这个工具回答自己的确认框。
- 插件完全调不了这个工具。

开关关着的时候，`terminal_key` 里能在选项列表上移动和确认的六个键也会被拒（回车、小键盘回车、四个方向键），而 ctrl+c 和 escape 照常放行，因为那是救一个卡死的 worker 要用的键。

这里有个缺口，源码自己公开写着。开关关着的时候，`terminal_send` 发一个 `1` 加回车，仍然能把确认框答掉。它堵不上：派任务本身就是「一段文字加一个回车」，拒掉这个就等于总管什么都说不了。源码的说法是，这个开关拦住了专用工具和随手按键，留下一条公开且有日志的旁路。所以它比「做不到」要弱。

开关开着的时候——这是默认状态，对每个没被护住的终端都是——总管两个选项都能选，包括「以后不再询问」。后一个会在那个目录的配置里写下长期许可，之后在那个目录跑的 agent 都不会再被问。Polter 只负责发按键，分不清总管按的是哪一个。

### 不替用户解锁

工具接口里没有解除屏蔽、解除按住的方法，也没有把用户关掉的授权开关重新打开的方法。`role_put` 改角色时动到 `supervisor`、`may_authorise`、`shielded` 三项也会被拒。`config_get` 只读，改配置是用户的事。

### 不隔离文件，不跟模型说话

worker 们共用同一份代码目录，Polter 不给它们各开 worktree。它也不接任何模型、不要 API key，思考的是用户已经装好的那个 agent CLI。

出处：`src/cli/mcp.zig` 的 `tools` 表里 `notices`、`terminal_answer_prompt`、`terminal_open` 三项的说明，`src/poltergeist/rpc.zig` 的 `authorize`、`answersAPrompt`、`promptReach`，`src/poltergeist/Bus.zig` 的 `Entry.may_authorise`，`src/config/Config.zig` 的 `poltergeist-watch`、`poltergeist-quiescence-after`、`poltergeist-calls-silent-after`，产品仓 README「安全护栏」和「竞品对比」两节。

## 怎么接

server 是一个 stdio 的 MCP 进程，协议版本 `2024-11-05`。给 MCP 客户端的配置就这一行：

```json
{"command": "polter", "args": ["+mcp"]}
```

它得从 Polter 的终端里启动。Polter 往每个终端的环境里放了 `GHOSTTY_POLTER_SOCKET` 和 `GHOSTTY_POLTER_TOKEN`，`+mcp` 靠这两个变量找到自己属于哪个终端。身份只来自这个 token，agent 没法声称自己是另一个终端。在 Polter 之外手动跑 `polter +mcp` 会直接退出，并在 stderr 上说明缺哪个变量。

通常不用手配。服务端的总开关 `poltergeist-mcp` 默认开着（设成 `false` 就是一个不开 socket 的普通终端），`poltergeist-register-mcp` 也默认开着，Polter 启动时会替已装的 agent CLI 注册好。接上之后让 agent 调一次 `me`，能答出终端 id 就是通了。答「没有这个工具」的话，README 的 FAQ 列了三个常见原因。

**实测范围要说清楚。** server 是标准 MCP，任何 MCP 客户端照理都能连，发行包里也带了七个注册插件（`claude-code`、`codex`、`deepseek`、`gemini`、`kimi`、`opencode`、`qwen-code`）。但只在 Claude Code 上深度验证过，其余六个请按「没测过」对待。

**hooks 目前只有 Claude Code。** 由角色启动的 Claude Code 会在一轮结束时通过 `polter +hook` 把状态和最后一段回答报给 Polter，总管能在 `notices` 里直接看到「这一轮结束了」，也能用 `terminal_turn` 取全文。别的 CLI 没有这条路，`terminal_list` 里它们的 `agent.hooks` 是 `none`，只能靠屏幕静止时长和 `terminal_read`。

平台方面，macOS 和 Windows 有安装包，Linux 得自己从源码编译，`terminal_layout` 在 Linux 上不可用。

出处：`src/cli/mcp.zig` 的 `run` 上方注释、`Options`、`protocol_version`、`complain`，`src/poltergeist/agent_cli.zig`，产品仓 README 的「核心功能」「下载安装」「常见问题」三节。

## 致谢

终端渲染、VT 和字体这些底层来自 [Ghostty](https://github.com/ghostty-org/ghostty)（MIT 协议），Polter 加的是 `src/poltergeist/` 下的这一套。两个项目没有隶属关系，在这里遇到的 bug 请先别报到上游。
