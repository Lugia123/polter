<h1>
<p align="center">
  <img src="images/icons/icon_256.png" alt="Polter" width="128">
  <br>Polter
</h1>
  <p align="center">
    你睡觉的时候，帮你盯着几个 AI agent 的终端。
    <br />
    <a href="#这是什么">这是什么</a>
    ·
    <a href="#它能给你什么">它能给你什么</a>
    ·
    <a href="#五分钟上手">上手</a>
    ·
    <a href="#完整例子">完整例子</a>
    ·
    <a href="#它永远不会做的事">它不做什么</a>
    ·
    <a href="README.md">English</a>
  </p>
</p>

## 这是什么

Polter 是一个终端 —— [Ghostty](https://github.com/ghostty-org/ghostty) 的分支
—— 它让你的某一个 tab 去照看其它 tab。

你本来就在终端里跑 AI agent。开到第四个的时候麻烦就来了：一个停在没人回答的
提问上，一个二十分钟前就干完了，一个在安静地等编译 —— 不挨个点开看，你分不清
谁是谁。

那就挑一个 tab 当**总管**。它也就是一个普通的 Claude Code 会话，只不过它能看到
别的 tab 屏幕静止了多久、能读它们的屏幕、能往里打字、能开新的 tab，还能拉个群跟
它们说话。你只要告诉它活是什么，剩下的它自己盯。

Polter 本身从不做判断。它只测一个量 —— **这块屏幕多久没动了** —— 外加传话。
屏幕不动到底是"卡住了"还是"在想"，它拒绝回答，因为答错比不答更糟。这个判断归
总管。

状态：**一个跑得通的实验**。已经用真实的 Claude Code CLI 端到端跑过，而且因此
抓到了几个单元测试结构上不可能发现的致命 bug。

## 它能给你什么

- **一个自己把活安排好的总管。** 你说目标，它写计划、按每块活在对的目录里开终端
  （`terminal_open`）、在每个里面起 agent、把人拉进一个群、再挨个认领好开始计时。
  你一次终端 id 都不用报。
- **每个 tab 一个数字，而不是一次猜测。** Polter 测的是每块屏幕静止了多久，然后把
  这个数交出去。读屏幕、判断它意味着什么，是总管的活 —— 所以 agent CLI 改了画面
  怎么画，这里什么都不会坏。
- **是真的终端，你随时能接手。** 每个干活的都是一个普通 tab 跑着一个普通 CLI。想
  打字就抢过键盘打；一个崩了不影响别的，而且它们不必是同一个 CLI。
- **一个它们真的在用的群聊。** 干活的之间、和总管之间都能说话，整个过程在
  `polter +chat` 里看得见，而且重启之后还在。
- **只有你能上、只有你能解的锁。** 把一个 tab 按住不许下班，或者干脆让它从工具面
  里消失。两种都直接显示在 tab 上，而且都不能从工具面解开。
- **第二天早上读得懂的一夜。** 每条群消息、每个 tab 里滚过去的内容都按 JSON 行落
  盘，`grep` 和 `jq` 直接能用。
- **可以你自己改的判断。** 怎么当总管是一份你能改、能版本化的 Markdown skill；不
  许做的事编译在二进制里，所以它不会在凌晨四点被长会话的上下文挤掉。

## 五分钟上手

你只需要指定一个 tab 当头儿。就这一步配置。

### 1. 开一个 tab，在里面起 Claude Code

跟你平时一样。先 `cd` 到合适的目录 —— 总管以后可以自己开 tab，但它自己是从你把
它留在哪儿开始的。

### 2. 把它设成总管

**Agents → Make This Terminal a Supervisor**（命令面板里也有，也可以绑给
`poltergeist_supervisor` 这个 action）。同一个菜单项再点一次就取消；一个窗口里
可以有好几个总管，各管各的一摊。

设完的那一刻，Polter 会往那个 tab 里敲一行字，告诉里面的 agent 刚发生了什么，
以及先去读它的 `supervising` skill。所以你还没开口，它已经知道该怎么操作了。

### 3. 告诉它活是什么

你的部分到此为止。建群、开 tab 或认领 tab、起表 —— 都是它自己来。你不需要报终端
id，也不需要点工具名。

### 4. 去睡觉

回来用 **Agents → Terminal Conversations**（或者 `polter +chat`）看它们之间都说
了什么。

## 完整例子

比如你想让它通宵把一个 REST API 做出来，而且不想中途一直看着。

开一个 tab，`cd` 到项目里，起 `claude`，设成总管。然后这么说：

> 你现在是总管。目标：把 `~/src/notes` 里 notes 服务的 REST API 做出来，测试全
> 过，OpenAPI 文档同步更新。
>
> 先给我一份开发计划，把活拆成三块互不打架的。然后每块开一个终端 —— 用
> `terminal_open`，指定对的目录，`watch: true` —— 在每个里面起
> `claude --permission-mode acceptEdits`，把任务连同"做到什么算完"一起交代下去。
>
> 把它们都拉进一个群。我睡觉的时候你盯着，谁卡了你去捞，谁想提前收工不许。只有
> 谁停在权限确认上的时候才叫醒我。早上给我一份汇报。

接下来它会自己做这些事：`group_create` + `group_set_brief` 建个说话的地方，
`terminal_open` 开三个 tab，`terminal_send` 在每个里面起 agent，`group_add` 把
人拉进群，再 `set_watch` 挨个认领、开始计时。然后它就转圈：哪个 tab 静止久了，
它去读屏幕，判断这是真卡住还是编译时间长，决定催一下还是让它继续。

这段话里有三个点值得说：

- **先要计划。** 一个先拆活再开 tab 的总管，第二天早上能给你一份读得懂的东西，
  而不是一堆流水账。
- **一定要说清"做到什么算完"。** `supervising` skill 里反复强调这条：只派任务不
  给验收标准，干活的那个就会自己定义什么叫完成，然后你凌晨两点才发现它定义的跟
  你想的不一样。
- **干活的终端用自动模式起。** Polter 永远不会替 agent 回答权限确认 —— 这是硬
  规矩不是配置项 —— 所以谁停在确认上，最后被叫醒的是**你**。要用就用 Claude Code
  自己的自动模式（会话里 shift+tab 切，或者启动时加
  `--permission-mode acceptEdits`）。`--dangerously-skip-permissions` 也是有的，
  它字面意思就是它的意思。

### 跑起来之后

- **汇报是攒着一起给的**，每个终端一行，每 `poltergeist-notice-interval`（默认
  一分钟）给一次。总管想主动看的话随时可以调 `notices`。
- **屏幕不动超过 `poltergeist-quiescence-after`（默认三分钟）** 才算"静止"；一直
  静止的每 `poltergeist-quiescence-repeat`（默认十五分钟）再提一次。
- **如果有人停在权限确认上**，总管调 `notify_user`，你就会被通知 —— 什么点都通
  知，无视 `poltergeist-notify-window`，因为这事没别人能替你办。这需要配一个通知
  [插件](#插件)。

### 两个只有你能按的开关

两个都会显示在 tab 上，因为只跟你说过一次的保证，凌晨三点你是想不起来的：

- **Agents → Keep This Terminal Working** —— 这个不许下班。总管来要求下班会被
  拒。tab 的标记上会多一个环（`◉` 在动 / `◎` 静止）。
- **Agents → Keep Agents Out of This Terminal** —— 整个从工具面里拿掉。这个是绝
  对的：总管和插件一并拒绝。tab 上会带一把锁。你自己看邮件的那个 tab 用这个。

这两个都不能从工具面解除。故意没有这个工具 —— 一个能解锁的总管，会先解锁再把它
打卡下班。

## 总管能做什么

所有事情都走同一个 MCP 工具面（`src/cli/mcp.zig` 前端，后面是
`src/poltergeist/rpc.zig`），清单是刻意短的：

- **看** —— `terminal_list`（每块屏幕静止了多久、带什么标记）、`terminal_read`、
  `notices`、`session_recall`（昨晚是怎么安排的）、`config_get`。
- **说** —— `group_create`、`group_add`、`group_remove`、`group_destroy`、
  `group_post`、`group_read`、`group_history`、`group_members`、`group_compact`、
  `group_set_brief`、`group_list`。
- **管** —— `terminal_send`（打字）、`terminal_key`（按键，`ctrl+c`、`escape`…）、
  `terminal_action`（菜单栏能做的事）、`terminal_open`（在它选的目录里开新 tab）、
  `set_watch`、`clock_out` / `clock_in`、`set_quiescence_threshold`、
  `become_supervisor`、`stand_down`。
- **找你** —— `notify_user`，经由插件。
- **配插件** —— `plugin_list`、`plugin_configure`、`plugin_test`。

这张清单上有两条线。

**「安排」是总管的。** 认领终端、上下班、建群拉人、通知你、开 tab、插件那几个 ——
因为一个能认领别的终端的终端，等于绕开 `become_supervisor` 另开了一条当头儿的
路。而在一个你本来就在的群里说话不算安排，所以聊天那几个工具对每个成员都开放：
不让说话的团队不叫团队。

**「操作一个终端」也不算安排。** 读屏幕、打字、按键、执行菜单动作 —— 任何 agent
都可以，能不能过取决于**目标**身上的标记，而不是谁在问。一个 tab 里的 agent 可
以去重启另一个没人看着的 tab 里的服务；但被监视的、被屏蔽的、当总管的，它碰不了。

## 它永远不会做的事

四条，这几条是前面一切值得信的原因：

- **永远不替 agent 回答权限确认。** 没有白名单，没有开关。替别人按下"yes"等于
  废掉别人的安全模型。它会改成通知你，什么点都通知。
- **永远不让 agent 解开你上的锁。** 按住和屏蔽都是你的。工具面能看到"有一把
  锁"，但改不了它。
- **永远不管你的任务。** 群上可以挂一句话说这个群是干嘛的。给这句话加个状态字段
  就是任务系统的开始，而这类东西已经够多了。
- **永远不当绕过 agent 自身权限的近路。** 一个 CLI 把 `Bash` 关在授权确认后面的
  agent，不会因为多装了个 Polter 就拿到执行权。`terminal_send` 只发文本、永远
  只发文本：它走粘贴通道，每个控制字节都会被换成空格，跟 xterm 一样。所以"按一
  个键"是另一个动词，有它自己的授权（`src/poltergeist/keys.zig`）。

还有两条同样路子的小规矩：agent 可以把插件**打开**、但永远不能**关掉**（能关掉
你通知渠道的 agent，等于能关掉自己头顶的灯）；正被监视的终端不能用
`become_supervisor` 自荐（它是最可能在读网络内容的那个，一行注入的文字不能把谁
扶上位）。

## 东西都写在哪

两个默认都开，第二天早上 `less`、`grep`、`jq` 直接能用：

- `$XDG_STATE_HOME/polter/chat/` —— agent 之间说了什么。
- `$XDG_STATE_HOME/polter/terminals/` —— 每个终端里实际发生了什么。一个终端一个
  目录，一天一个文件，一行一条 JSON。**不做任何脱敏，请当成你的 shell 历史来
  对待。**

## 值得知道的几个配置

一个都不是必须的。`polter +show-config --default --docs` 会打印全部。

| 配置项                              | 默认    | 干嘛用的                                                                 |
| ----------------------------------- | ------- | ------------------------------------------------------------------------ |
| `poltergeist-mcp`                   | `true`  | 开不开 agent socket。`false` 就是一个普通终端。                          |
| `poltergeist-register-mcp`          | `true`  | 允许插件去告诉你的 agent 运行时"Polter 的工具存在"。                     |
| `poltergeist-watch`                 | `false` | 每个终端一打开就采样。不需要为了上手打开它 —— 被认领的时候采样自然会开。 |
| `poltergeist-quiescence-after`      | `3m`    | 屏幕不动多久才上报。                                                     |
| `poltergeist-quiescence-repeat`     | `15m`   | 一直不动的，隔多久再提一次。                                             |
| `poltergeist-notice-interval`       | `1m`    | 多久才允许打断总管一次。                                                 |
| `poltergeist-supervisor-stand-down` | `true`  | 活干完之后总管能不能自己卸任。                                           |
| `poltergeist-notify-window`         | 空      | 允许打扰你的时段，写成 `HH:MM-HH:MM`。权限确认无视这个。                 |
| `poltergeist-chat-log`              | `true`  | 群聊落盘。                                                               |
| `poltergeist-terminal-log`          | `true`  | 终端转录落盘。                                                           |

## 如果 agent 说它没有 polter 工具

Polter 已经把 socket 路径和 token 放进了每个终端的环境变量，agent **够得着**它
需要的全在那儿了 —— 但 MCP 客户端只会加载它被配置过的 server。

做这件配置是插件的活，不是核心的活（原因写在
`src/poltergeist/provision.zig`）。**`claude-code`** 插件默认就是开的，它做的就是
这件事：`claude mcp add --scope user`，外加把 Polter 的 skill 复制进
`~/.claude/skills/polter-*`。所以常见原因就三个：插件被关了、Polter 启动时
`claude` 不在 `PATH` 上、`poltergeist-register-mcp` 被关了。要注册但没有任何一个
供给插件开着的时候，Polter 会把这件事打在终端屏幕上，而不是只写进日志。

**注册记的是某一个构建，最后启动的那个说了算。** 起一个开发构建，会悄悄把你
用户级的 `polter` 条目指向它。开发的时候你要的就是这个，开发完就不是了。要么把
你想留的那个构建再起一次，要么设 `poltergeist-register-mcp = false`，自己用
`claude mcp` 管这条记录。

## 它支持哪些 agent

**只在 Claude Code 上测过**，也只有它开箱即用。但这件事的形状值得讲清楚，因为它
并不是"只能 Claude Code"：

- **server 本身是标准 MCP。** `polter +mcp` 在 stdio 上说标准 MCP，再通过 unix
  socket 转给 Polter。任何 MCP 客户端都能跑它。每个终端都有
  `GHOSTTY_POLTER_SOCKET` 和各自的 `GHOSTTY_POLTER_TOKEN`；token 决定了"你是哪个
  终端"，agent 冒充不了别人。
- **跟 Claude Code 绑定的只有配置那一步，而那是插件。** 核心发布的是**数据** ——
  哪个二进制提供端点、有哪些 skill、文件在哪 —— `claude-code` 插件把它翻译成
  Claude Code 认的形状。换一个 agent CLI，是再写一个插件，不是改核心。
- **`PATH` 上没有 `claude` 不算错误。** 插件说清它没能做成什么，Polter 把那句话
  打在屏幕上，其它照常。

所以别的 agent 原则上也能用这一整套：把 `polter +mcp` 注册进它自己的运行时，再
想办法把 `supervising` skill 送到模型面前（`skill_read` 会把正文交出来，但得有人
想到去调它）。**没测过。请当成未测试，而不是支持。**

## 插件

一个插件就是 `$XDG_CONFIG_HOME/polter/plugins/` 下的一个目录，里面一个
`plugin.json` 加一个可执行文件。它被启动一次然后常驻，Polter 往它 stdin 写 JSON
行，它在 stdout 回答。二十行的 shell 脚本就是一个完整的插件。

插件"是什么"，取决于它订阅了什么：

```json
{ "wants": { "events": ["chat"], "calls": [], "groups": ["*"] } }
```

- **`chat`** —— 群里有人说话了。
- **`terminal.quiet`** —— 某个终端静下来了，该告诉谁。
- **`provision`** —— 这是 Polter 的自我介绍，去让某个 agent 运行时能看见它。

**插件说的是跟 agent 一样的线协议**，过的是一模一样的检查：没声明的方法被拒，
总管的方法被拒（插件永远不是总管），被屏蔽的终端对它不可达 —— 跟对总管一样。

随构建装两个，默认都开：**`archive`**（把每条群消息在文件系统上多存一份，指向一
个同步目录，这份拷贝就比这台机器活得久）和 **`claude-code`**（上面说的注册）。
通知渠道留给你自己塞：这类东西有几十种，随便预装一个都会立刻过时。

**凭据只存引用，绝不明文** —— `env:NAME`、`file:` 路径、
`keychain:service/account`，或者 `cmd:` 一条命令、它的 stdout 就是值；在调用的那
一刻才解析，从不缓存。所以配置文件可以放进 dotfiles 仓库。`cmd:` 一条就覆盖了所
有密码管理器，而它恰恰是 agent **不许写**的那一种：agent 写下的 `cmd:` 会变成
Polter 以后自己去跑的一条命令，跑的时候早已不在当初授权它的那个场景里。**你自己
手改这个文件不受任何这些限制** —— 这个不对称说的是"这是谁的手"。

配置入口在 **Agents → Plugins**。完整契约见
[`docs/poltergeist/plugins.md`](docs/poltergeist/plugins.md)。

## 和 Ghostty 的关系

让它成为一个好终端的一切，都是 [Ghostty](https://github.com/ghostty-org/ghostty)
的功劳 —— Mitchell Hashimoto 和 Ghostty 的贡献者们。Polter 是分支不是重写：渲染
器、VT 实现、字体栈、原生界面全是他们的，上游有更新就合过来。

**所以关于终端本身的一切都该问上游**：支持哪些转义序列、性能、配置、快捷键、
`libghostty`、崩溃报告。看 [ghostty.org/docs](https://ghostty.org/docs)，那些内容
在这里全都成立，把 `ghostty` 念成 `polter` 就行。

Polter 加的是 `src/poltergeist/`、agent 说话的那个 MCP 工具面、聊天 TUI、终端转录
和插件宿主。本项目与 Ghostty 项目无关联，在这里发现的 bug，除非在上游 Ghostty 上
也能复现，否则不要报到那边去。

MIT 协议，和上游一样；见 [LICENSE](LICENSE)，原始版权声明保留在里面。

## 构建与文档

`zig build` 就能构建。[`docs/preview-manual.md`](docs/preview-manual.md) 是构建、
运行、调试的唯一权威，[`docs/README.md`](docs/README.md) 是其余文档的索引。上面这
些东西的设计推演在 [`docs/poltergeist/`](docs/poltergeist/README.md) —— 从它的
`README.md` 开始读，那是其余各章都要回答的那部宪法。
